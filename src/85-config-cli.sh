# ── Config CLI ──────────────────────────────────────────────────────────────
# Keys that remapping can't touch. One door out always stays open even if you fumble.
FMUX_CONF_RESERVED='esc enter left'

# ── "Is this key actually wired to a real action?" — pulled from code, not hand-written ──────
# A key whose value is saved but that nobody reads is a **lying toggle**. The user believes the
# feature they turned off is actually off. So the two screens that display config (`fmux config
# list` and the in-popup settings screen) mark such keys.
#
# Writing that list by hand always drifts — the person who wires a key into the code and the
# person who updates the list don't open the same file at the same moment (in practice, T6 had to
# fix the list separately after wiring three keys). So we move the basis for that judgment into the
# code itself: we scan the concatenated script (= ourselves) for **lookup calls that pass a key
# name as a literal**. Somewhere passing a literal key to a lookup function = someone reads that
# value and changes behaviour based on it.
#
#   Shape we look for: lookup function name (get/on/num) + space + lowercase key name
#   Not matched: dynamic lookups in a loop (a variable argument like "$k"), case patterns that just
#                enumerate keys, function names inside Korean-language comments (the character that
#                follows isn't [a-z], so it doesn't match)
#
# ⚠ The flip side: if a comment writes out a lookup call together with a literal key as an example,
#   that key will look wired. When writing an example, use a placeholder like <key> for the key
#   slot. Whether this judgment matches the real wiring is pinned down by test/t-07-config-view.sh
#   via key names and count.
FMUX_CONF_WIRED_AWK='
    {
        s = $0
        while (match(s, /fmux_conf_(get|on|num)[ \t]+[a-z][a-z0-9_]*/)) {
            t = substr(s, RSTART, RLENGTH)
            sub(/^[a-z_]+[ \t]+/, "", t)
            if (!(t in seen)) { seen[t] = 1; printf "%s ", t }
            s = substr(s, RSTART + RLENGTH)
        }
    }'
FMUX_CONF_WIRED_LIST=''
FMUX_CONF_WIRED_SCANNED=0
fmux_conf_wired_scan() {
    [ "$FMUX_CONF_WIRED_SCANNED" = 1 ] && return 0
    FMUX_CONF_WIRED_SCANNED=1                      # don't retry even on failure — pin it to a single fork
    local out=''
    [ -r "$SELF" ] || return 0
    out=$(awk "$FMUX_CONF_WIRED_AWK" "$SELF" 2>/dev/null) || out=''
    [ -n "$out" ] || return 0
    FMUX_CONF_WIRED_LIST=" $out"                   # includes leading/trailing space — case-glob sees exactly one word
    return 0
}
fmux_conf_wired() {
    fmux_conf_wired_scan
    # Couldn't read ourselves = no basis for a judgment. In that case show no marker at all —
    # painting everything "not wired" would be the far bigger lie.
    [ -n "$FMUX_CONF_WIRED_LIST" ] || return 0
    case "$FMUX_CONF_WIRED_LIST" in *" ${1:-} "*) return 0 ;; esac
    return 1
}

# Is this a key name fzf accepts inside the popup (a subset whitelist)?
# Passing a name that isn't here makes fzf refuse to start at all and the cockpit never shows — so we block it up front.
fmux_conf_is_fzf_key() {
    case "${1:-}" in
        ctrl-[a-z]|alt-[a-z0-9]) return 0 ;;
        f[1-9]|f1[0-2]) return 0 ;;
        tab|btab|home|end|pgup|pgdn|del|ins|up|down|left|right|enter|esc|space) return 0 ;;
        ?) return 0 ;;      # a single printable character like '?'
        *) return 1 ;;
    esac
}

# Is this a key name tmux accepts? Used for key_summon (one key) and key_summon_fast (space-separated list).
fmux_conf_is_tmux_key() {
    case "${1:-}" in
        ''|*[!A-Za-z0-9C\-M\ ]*) return 1 ;;
    esac
    return 0
}

# Validation. On rc 1 the reason is printed to stderr.
fmux_conf_validate() {
    local k="${1:-}" v="${2:-}" other ov
    fmux_conf_default "$k" >/dev/null 2>&1 || { echo "unknown key: $k" >&2; return 1; }
    case "$k" in
        rc|snapshot|snapshot_on_exit|boot_restore)
            case "$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')" in
                on|off|1|0|true|false|yes|no) ;;
                *) echo "$k must be on|off (got: $v)" >&2; return 1 ;;
            esac ;;
        recent_hours|unseen_minutes|log_max)
            case "$v" in ''|*[!0-9]*) echo "$k must be a positive integer (got: $v)" >&2; return 1 ;; esac
            [ "$v" -gt 0 ] || { echo "$k must be greater than 0" >&2; return 1; } ;;
        accent)
            case "$v" in ''|*[!0-9]*) echo "accent must be an integer 0-255 (got: $v)" >&2; return 1 ;; esac
            [ "$v" -le 255 ] || { echo "accent must be 0-255 (got: $v)" >&2; return 1; } ;;
        key_summon)
            fmux_conf_is_tmux_key "$v" || { echo "key_summon must be a tmux key name (e.g. F, C-Left)" >&2; return 1; } ;;
        key_summon_fast)
            for ov in $v; do
                fmux_conf_is_tmux_key "$ov" || { echo "'$ov' in key_summon_fast is not a tmux key name" >&2; return 1; }
            done ;;
        key_*)
            for ov in $FMUX_CONF_RESERVED; do
                [ "$v" = "$ov" ] && { echo "$v is a reserved key and can't be remapped (close/enter must always stay open)" >&2; return 1; }
            done
            fmux_conf_is_fzf_key "$v" || { echo "not a key name fzf knows: $v (e.g. ctrl-n, alt-x, f2)" >&2; return 1; }
            # Conflict — is the same key already used by another action?
            for other in $FMUX_CONF_KEYS; do
                case "$other" in key_summon|key_summon_fast|"$k") continue ;; key_*) ;; *) continue ;; esac
                if [ "$(fmux_conf_get "$other")" = "$v" ]; then
                    echo "$v is already used by $other" >&2; return 1
                fi
            done ;;
    esac
    return 0
}

# The "actual runtime behaviour" of a hand-edited invalid value, in one line. Prints nothing if valid.
#   `fmux config set` rejects invalid values, but README:168 also documents hand-editing the file as a
#   normal path — a value that comes in that way folds differently per consumer (numbers fall back
#   to the default, booleans fall back to off, a summon key just drops out of the snippet). If the
#   table showed that value as if it were in effect, the two screens would tell different truths
#   (recommendation N4). Validation reuses the existing fmux_conf_validate and just swallows the reason.
fmux_conf_lie() {
    fmux_conf_validate "${1:-}" "${2:-}" 2>/dev/null && return 0
    case "${1:-}" in
        rc|snapshot|snapshot_on_exit|boot_restore)  printf '← invalid value · falls back to off' ;;
        recent_hours|unseen_minutes|accent|log_max) printf '← invalid value · falls back to default %s' "$(fmux_conf_default "$1")" ;;
        key_summon|key_summon_fast)                 printf '← invalid value · that key drops out of the snippet' ;;
        *)                                          printf '← invalid value' ;;
    esac
    return 0
}

# Atomic write. Replaces the value in place for an existing line, appends at the end if not found
# (preserves comments and ordering).
fmux_conf_write() {
    local k="${1:-}" v="${2:-}" mode="${3:-set}" tmp line seen=0
    mkdir -p "${FMUX_CONF%/*}" 2>/dev/null || true
    tmp="$FMUX_CONF.tmp.$$"
    : > "$tmp" || { echo "cannot write config file: $FMUX_CONF" >&2; return 1; }
    if [ -f "$FMUX_CONF" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in
                "$k"=*)
                    seen=1
                    [ "$mode" = set ] && printf '%s=%s\n' "$k" "$v" >> "$tmp"
                    ;;
                *) printf '%s\n' "$line" >> "$tmp" ;;
            esac
        done < "$FMUX_CONF"
    fi
    if [ "$mode" = set ] && [ "$seen" = 0 ]; then printf '%s=%s\n' "$k" "$v" >> "$tmp"; fi
    mv -f "$tmp" "$FMUX_CONF" || { rm -f "$tmp"; return 1; }
    return 0
}

# If the key whose value just changed is one that's baked into the tmux snippet, re-render the snippet.
#   Why we call ourselves again: the render function lives in 87-tmux-conf.sh, and that file is
#   concatenated after this one. On top of that, `fmux config …` exits in the block below, so
#   execution never reaches 87 — this process never even has a function named fmux_tmux_conf_write.
#   Following the $SELF re-invocation convention already used in ~20 other places is safer than
#   flipping the file order.
#   We swallow failure here too: if failing to write the snippet also failed the config save, the
#   value already written to the file would disagree with the exit code. The config is saved, and
#   the snippet catches up on the next --tmux-conf.
fmux_conf_resnip() {
    case "${1:-}" in
        key_summon|key_summon_fast|snapshot_on_exit)
            "$SELF" --tmux-conf --write >/dev/null 2>&1 || true ;;
    esac
    return 0
}

if [ "${1:-}" = "config" ]; then
    # Each subcommand below walks FMUX_CONF_KEYS and calls fmux_conf_get/fmux_conf_source many times
    # wrapped in $(...) — each call is a subshell, so unless fmux_conf_load is fired here first as a
    # bare statement, every subshell re-inherits FMUX_CONF_LOADED=0 and re-parses the config file once
    # per key, repeating broken-line warnings just as many times (the exact bug fix round 1 caught).
    fmux_conf_load
    case "${2:-}" in
        ''|list)
            # The same honesty as the in-popup settings screen belongs here too — someone
            # configuring from the CLI alone must not hear only "saved" and believe they turned on
            # a feature that doesn't actually do anything.
            printf '%-18s %-14s %s\n' 'KEY' 'VALUE' 'SOURCE'
            unwired=0; bogus=0
            for k in $FMUX_CONF_KEYS; do
                v=$(fmux_conf_get "$k")
                lie=$(fmux_conf_lie "$k" "$v")
                [ -n "$lie" ] && bogus=1
                [ -z "$lie" ] || lie=" $lie"
                if fmux_conf_wired "$k"; then
                    printf '%-18s %-14s %s%s\n' "$k" "$v" "$(fmux_conf_source "$k")" "$lie"
                else
                    unwired=1
                    printf '%-18s %-14s %-9s%s%s\n' "$k" "$v" "$(fmux_conf_source "$k")" '← not wired' "$lie"
                fi
            done
            [ "$unwired" = 1 ] && printf '\nnot wired = the value is saved but no code reads it yet — changing it does nothing.\n'
            [ "$bogus" = 1 ] && printf 'invalid value = saved to the file but not something the code can use — it folds as noted above.\n'
            exit 0 ;;
        get|source)
            [ -n "${3:-}" ] || { echo "usage: fmux config $2 <key>" >&2; exit 1; }
            if [ "$2" = get ]; then fmux_conf_get "$3" || { echo "unknown key: $3" >&2; exit 1; }
            else                    fmux_conf_source "$3" || { echo "unknown key: $3" >&2; exit 1; }
            fi
            echo
            exit 0 ;;
        set)
            [ -n "${3:-}" ] || { echo "usage: fmux config set <key> <value>" >&2; exit 1; }
            shift 2; k=$1; shift
            v="$*"
            fmux_conf_validate "$k" "$v" || exit 1
            fmux_conf_write "$k" "$v" set || exit 1
            fmux_conf_resnip "$k"
            printf '%s=%s\n' "$k" "$v"
            # The moment a value actually changes is the easiest moment to be misled — hearing only
            # "saved" and believing the feature is now on. Say it again right under the confirmation
            # line (the key=value on stdout stays as-is for scripts to read; this notice alone goes
            # to stderr).
            fmux_conf_wired "$k" || printf '  ↑ %s is not wired to any action yet — saved, but nothing changes right now\n' "$k" >&2
            exit 0 ;;
        unset)
            [ -n "${3:-}" ] || { echo "usage: fmux config unset <key>" >&2; exit 1; }
            fmux_conf_default "$3" >/dev/null 2>&1 || { echo "unknown key: $3" >&2; exit 1; }
            fmux_conf_write "$3" '' unset || exit 1
            fmux_conf_resnip "$3"
            printf '%s → default %s\n' "$3" "$(fmux_conf_default "$3")"
            exit 0 ;;
        path)
            printf '%s\n' "$FMUX_CONF"; exit 0 ;;
        *)
            echo "usage: fmux config [list|get|source|set|unset|path]" >&2; exit 1 ;;
    esac
fi
