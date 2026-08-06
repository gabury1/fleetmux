# ── Config ──────────────────────────────────────────────────────────────────
# Priority: env var > config file > code default.
#
# Why this file is never `source`d: it's a path hooks read on every event, and cron reads every
# minute. If it were sourced, a single typo the user adds would silently kill fleet control
# entirely from that moment on. So it's read only through a whitelist parser — only lines with
# a known key and a known shape are let through.
FMUX_CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/fleetmux"
FMUX_CONF="${FMUX_CONF_FILE:-$FMUX_CONF_DIR/config}"

# Known keys. This order is exactly the order `fmux config` lists them in.
FMUX_CONF_KEYS='rc snapshot snapshot_on_exit boot_restore status_badges recent_hours unseen_minutes accent log_max key_new key_rename key_kill key_reload key_detach key_broadcast key_help key_settings key_summon key_summon_fast'

# Defaults. Unknown key → rc 1 — this function also doubles as the "is this a known key" check.
fmux_conf_default() {
    case "${1:-}" in
        rc|snapshot|snapshot_on_exit|boot_restore|status_badges) printf 'on' ;;
        recent_hours)    printf '1' ;;
        unseen_minutes)  printf '10' ;;
        accent)          printf '73' ;;
        log_max)         printf '1048576' ;;
        key_new)         printf 'ctrl-n' ;;
        key_rename)      printf 'ctrl-e' ;;
        key_kill)        printf 'ctrl-x' ;;
        key_reload)      printf 'ctrl-r' ;;
        key_detach)      printf 'ctrl-d' ;;
        key_broadcast)   printf 'ctrl-b' ;;
        key_help)        printf '?' ;;
        key_settings)    printf 'ctrl-o' ;;
        key_summon)      printf 'F' ;;
        # The default for the no-prefix summon key **stays empty**. With only the config file
        # installed, it must not silently steal someone else's key — a no-prefix binding grabs
        # that key from every app in that pane (vim, shell, fzf). That must only happen after a
        # human has said "yes" once.
        #   So policy splits in two: **the config default is empty, the installer's suggestion is
        #   S-Left**. (The install.sh preset section writes at length on why S-Left. Summary:
        #   Shift+arrow is the only no-prefix single keystroke that passes through all three of
        #   macOS, Linux, and Windows Terminal.)
        key_summon_fast) printf '' ;;
        *) return 1 ;;
    esac
    return 0
}

# Key → env var name. bash 3.2 has no ${var^^} → uppercase with tr instead.
fmux_conf_envname() {
    printf 'FMUX_%s' "$(printf '%s' "${1:-}" | tr '[:lower:]' '[:upper:]')"
}

# Read the config file only once per process — if the whole thing were rescanned on every lookup,
# on this path where hooks fire on every event and cron runs every minute, a single broken line
# would repeat the same warning once per key looked up and keep filling up hook.log (fix round 1
# finding: 4 key lookups = the same warning 4 times). So from the second call onward it returns
# immediately — this is a direct implementation of the design doc's "read once at the start of
# each entry point (fmux_conf_load)". ("The file is under ten lines so it isn't cached" means it
# doesn't get written to a cache file on disk — it does NOT mean values shouldn't be remembered
# within the process.)
#
#   Each known key is stored into FMUX_CONF_V_<key> (the value) and FMUX_CONF_S_<key> (a marker that
#   it was present in the file, kept separate from the value to distinguish it from an empty
#   value). bash 3.2 has no associative arrays, so variable names are assembled dynamically
#   (eval) — which means any key that lands in that variable-name slot must have already passed
#   the fmux_conf_default whitelist (the caller in front of it, fmux_conf_file_get, checks this).
#
#   Caution (important — contract for callers): if this function is called inside a command
#   substitution (subshell), the cache is only established inside that subshell and never makes
#   it back out — bash never propagates a subshell's variable changes back to the parent process.
#   So to guarantee "only one warning per multiple lookups within one process", that process's
#   entry point must call fmux_conf_load once as a bare statement, not wrapped in `v=$(...)` — the
#   `config get/source` entry points below do exactly that.
#   (Callers that only do a single lookup don't need to worry about this — fmux_conf_get/
#   fmux_conf_source already call it once internally.)
FMUX_CONF_LOADED=0
fmux_conf_load() {
    [ "$FMUX_CONF_LOADED" = 1 ] && return 0
    FMUX_CONF_LOADED=1
    # -r, not -f. If the file exists but can't be read (permissions, ACL), the redirect on
    # `done < "$FMUX_CONF"` below fails, and set -e catches that and kills the whole process — cron
    # (every minute) and @reboot boot-restore die instantly with no reason left behind. If it
    # can't be read, just fall through to defaults.
    [ -r "$FMUX_CONF" ] || return 0
    local line k v
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ''|'#'*|' '*'#'*) continue ;; esac
        # Is it key=value shaped — also ignore a line with no '=' at all, though this used to
        # pass through silently with no warning (fix round 1 finding 2). Emit a one-line warning
        # like every other ignore reason.
        case "$line" in
            *=*) ;;
            *) printf 'fleetmux: ignoring line in %s — not key=value shape: %s\n' "$FMUX_CONF" "$line" >&2; continue ;;
        esac
        k=${line%%=*}
        v=${line#*=}
        # check key shape
        case "$k" in
            ''|*[!a-z0-9_]*) printf 'fleetmux: ignoring line in %s — not a valid key shape: %s\n' "$FMUX_CONF" "$line" >&2; continue ;;
        esac
        # is it a known key
        if ! fmux_conf_default "$k" >/dev/null 2>&1; then
            printf 'fleetmux: ignoring line in %s — unknown key: %s\n' "$FMUX_CONF" "$k" >&2
            continue
        fi
        # check value charset
        case "$v" in
            *[!0-9A-Za-z_./:+\ -]*) printf 'fleetmux: ignoring line in %s — disallowed character in value: %s\n' "$FMUX_CONF" "$line" >&2; continue ;;
        esac
        eval "FMUX_CONF_V_$k=\$v"   # last line written wins — just overwrite
        eval "FMUX_CONF_S_$k=1"
    done < "$FMUX_CONF"
    return 0
}

# Read one key from the cache (fmux_conf_load). rc 1 if absent.
fmux_conf_file_get() {
    local want="${1:-}" have
    fmux_conf_default "$want" >/dev/null 2>&1 || return 1   # re-check the whitelist before feeding into eval (injection prevention)
    fmux_conf_load
    eval "have=\${FMUX_CONF_S_$want+set}"
    [ "${have:-}" = set ] || return 1
    eval "printf '%s' \"\$FMUX_CONF_V_$want\""
    return 0
}

# Effective value. Unknown key → rc 1.
fmux_conf_get() {
    local k="${1:-}" envn v
    fmux_conf_default "$k" >/dev/null 2>&1 || return 1
    envn=$(fmux_conf_envname "$k")
    eval "v=\${$envn+set}"
    if [ "${v:-}" = set ]; then eval "printf '%s' \"\$$envn\""; return 0; fi
    if v=$(fmux_conf_file_get "$k"); then printf '%s' "$v"; return 0; fi
    fmux_conf_default "$k"
}

# Reads a numeric key in a form that's safe to feed into arithmetic. Unknown key → rc 1.
#   Why this is separate: the whitelist parser above only checks the value's **charset**.
#   `recent_hours=6h` passes it. If that value went straight into $(( … )), it would be an
#   arithmetic syntax error, and set -e would catch that and kill --list or --status entirely —
#   one hand-edited config line must never be able to keep the control tower from coming up.
#   One more thing: `08` passes the charset check, but in bash arithmetic it's octal and dies
#   instantly with "value too great for base". So even a value that passed is normalized once
#   more through 10#… before being emitted.
#   The second argument is an (optional) upper bound — used for keys like accent whose value goes
#   into an escape sequence.
#   Falling back to the default is not silent — it says one line (the same discipline as the
#   parser's ignore warnings).
fmux_conf_num() {
    local k="${1:-}" max="${2:-}" v ok=1
    v=$(fmux_conf_get "$k") || return 1
    case "$v" in ''|*[!0-9]*) ok=0 ;; esac
    if [ "$ok" = 1 ] && [ -n "$max" ] && [ "$(( 10#$v ))" -gt "$max" ]; then ok=0; fi
    if [ "$ok" = 0 ]; then
        printf 'fleetmux: cannot use value of %s — falling back to default: %s\n' "$k" "$v" >&2
        v=$(fmux_conf_default "$k")
    fi
    printf '%s' "$(( 10#$v ))"
    return 0
}

# Where did the value come from — env | file | default
fmux_conf_source() {
    local k="${1:-}" envn v
    fmux_conf_default "$k" >/dev/null 2>&1 || return 1
    envn=$(fmux_conf_envname "$k")
    eval "v=\${$envn+set}"
    if [ "${v:-}" = set ]; then printf 'env'; return 0; fi
    if fmux_conf_file_get "$k" >/dev/null 2>&1; then printf 'file'; return 0; fi
    printf 'default'
}

# Is a boolean key on. on/1/true/yes count as on (case-insensitive).
fmux_conf_on() {
    local v
    v=$(fmux_conf_get "${1:-}") || return 1
    case "$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')" in
        on|1|true|yes) return 0 ;;
        *) return 1 ;;
    esac
}
