# ── In-popup settings screen ─────────────────────────────────────────────────
# Change settings without leaving the popup. One way in — ^O in the popup (FMUX_KEY_SETTINGS in 90-main.sh).
#
# A line has the same shape as --list: "<key>\t<human-readable display>". fzf hides field 1 via
# --with-nth, and instead of {1} we cut off everything before the tab of the chosen line ourselves
# (same discipline as --list).

# Boolean keys — keys that can be flipped instantly with Enter. Everything else needs a typed value.
#   This list must stay in sync with the boolean branch of fmux_conf_validate (85-config-cli.sh).
fmux_conf_is_bool() {
    case "${1:-}" in rc|snapshot|snapshot_on_exit|boot_restore|status_badges) return 0 ;; *) return 1 ;; esac
}

# fmux_conf_wired, the basis for the "not wired" marker, lives in 85-config-cli.sh — `fmux config list`
#   uses the same judgment, and since 85 is concatenated before this file we can just call it here.
#   It's pulled from code rather than a hand-written list: there's no longer any need to remember
#   "update the list too when you wire a new key".

# One-line description. Avoid parentheses — if this string ever ends up inside an fzf --bind
# execute/reload argument, a closing paren would truncate the binding (same reason as 80-view.sh:58).
fmux_conf_desc() {
    case "${1:-}" in
        rc)               printf 'auto-recover the remote-control link' ;;
        snapshot)         printf 'record the fleet on every popup/cron tick' ;;
        snapshot_on_exit) printf 'record the fleet on exit' ;;
        status_badges)   printf 'draw ⏸ ✓ ✻ in the tmux status bar' ;;
        boot_restore)     printf 'auto-restore on boot' ;;
        recent_hours)     printf 'time window for bolding a name' ;;
        unseen_minutes)   printf 'minutes to keep status-bar ✓' ;;
        accent)           printf 'accent colour, 256-colour number' ;;
        log_max)          printf 'hook log rotation threshold in bytes' ;;
        key_new)          printf 'popup key — new session' ;;
        key_rename)       printf 'popup key — rename' ;;
        key_kill)         printf 'popup key — kill session' ;;
        key_reload)       printf 'popup key — reload list' ;;
        key_detach)       printf 'popup key — detach from tmux' ;;
        key_broadcast)    printf 'popup key — broadcast' ;;
        key_help)         printf 'popup key — help' ;;
        key_settings)     printf 'popup key — this settings screen' ;;
        key_summon)       printf 'tmux summon key — after prefix' ;;
        key_summon_fast)  printf 'tmux summon key — no prefix, space-separated for multiple' ;;
        *)                printf '' ;;
    esac
}

# One round of the settings screen: draw once, pick once.
#   Returning rc 1 tells the caller to end the loop (Esc/← = back to the session list).
#   The list is regenerated as a fresh child process every time — the value that was just changed
#   needs to show up right away, but this process's fmux_conf_load cache is stuck on the file as it
#   was at start.
fmux_conf_view_once() {
    local line k rc nv
    # The child's stderr goes to a log, not the screen. If the hand-edited config has a broken
    # line, the warning would paint over the screen fzf drew and make the settings screen
    # unreadable. It's not discarded, though — that warning is real information the user needs to
    # see eventually (recommendation N3).
    mkdir -p "$STATE" 2>/dev/null || true
    line=$("$SELF" --config-list 2>>"$STATE/conf.log" \
        | fzf --ansi --reverse --cycle --info=hidden --prompt='settings ❯ ' --pointer='▶' \
              --delimiter=$'\t' --with-nth='2..' \
              --header='Enter change    Esc·← back to session list' \
              --color='pointer:#4ec9b0,prompt:#4ec9b0,hl:#56b6c2,hl+:#56b6c2,bg+:#18221e,fg+:regular,header:#4a5a52,border:#4a5a52,label:#4ec9b0' \
              --bind 'left:abort' \
              --bind 'esc:abort') || return 1
    k=${line%%$'\t'*}
    [ -n "$k" ] || return 1
    rc=0
    "$SELF" --config-toggle "$k" || rc=$?
    [ "$rc" = 0 ] && return 0            # it was a boolean — flipped and saved. Redraw.
    if [ "$rc" != 2 ]; then               # the toggle itself was rejected (the reason already went to stderr)
        printf '  press any key to go back' >/dev/tty
        read -rsn1 </dev/tty 2>/dev/null || true
        return 0
    fi
    # rc 2 = not a boolean → read a typed value. Validation is left entirely to fmux config set.
    printf '\nnew value for %s — currently %s. Enter alone leaves it unchanged: ' \
        "$k" "$("$SELF" config get "$k")" >/dev/tty
    IFS= read -r nv </dev/tty || return 0
    [ -n "$nv" ] || return 0
    if ! "$SELF" config set "$k" "$nv" >/dev/tty 2>&1; then
        printf '  rejected — value left unchanged. Press any key to go back' >/dev/tty
        read -rsn1 </dev/tty 2>/dev/null || true
    fi
    return 0
}

# List for the settings screen. One line = "<key>\t<display>".
if [ "${1:-}" = "--config-list" ]; then
    # Contract (05-config.sh:53): the loop below calls fmux_conf_get/fmux_conf_source via $(...) for
    # every key — all subshells, so unless fmux_conf_load is fired here first as a bare statement, one
    # broken config line repeats its warning once per key. This list runs every time the screen redraws.
    fmux_conf_load
    for k in $FMUX_CONF_KEYS; do
        v=$(fmux_conf_get "$k")
        # An empty value is a valid value too (that's key_summon_fast's default) — leaving the
        # slot blank would collapse the column, so we fill it with '-'. Width alignment is %-16s, so it must be ASCII.
        [ -n "$v" ] || v='-'
        # A key pinned by env doesn't change no matter what's written to the file — flag that next to the value.
        [ "$(fmux_conf_source "$k")" = env ] && v="$v @env"
        d=$(fmux_conf_desc "$k")
        if fmux_conf_wired "$k"; then
            printf '%s\t%-18s %-16s %s\n' "$k" "$k" "$v" "$d"
        else
            printf '%s\t%-18s %-16s \033[2mnot wired · %s\033[0m\n' "$k" "$k" "$v" "$d"
        fi
    done
    exit 0
fi

# If it's a boolean, flip and save it and return rc 0. If not, rc 2 — a signal that "the caller
# should read a value". Any other rejection (unknown key, pinned by env) is rc 1 with the reason on stderr.
if [ "${1:-}" = "--config-toggle" ]; then
    fmux_conf_load
    k="${2:-}"
    fmux_conf_default "$k" >/dev/null 2>&1 || { echo "unknown key: $k" >&2; exit 1; }
    # A key that env wins doesn't change no matter what's written to the file — blocked precisely
    #   because that's the "lying toggle".
    #   This check comes before the boolean check: keys that take a typed value fail the same way,
    #   so it's better not to ask at all than to take input and throw it away.
    #   log_max used to always hit this — 10-util.sh set up the FMUX_LOG_MAX global itself, and that
    #   name is exactly this key's environment variable name, so it always read as "env wins". Once
    #   threshold wiring removed that global, this now only triggers when a real environment
    #   variable is actually set.
    if [ "$(fmux_conf_source "$k")" = env ]; then
        echo "$k is overridden by environment variable $(fmux_conf_envname "$k") — writing to the config file has no effect" >&2
        exit 1
    fi
    fmux_conf_is_bool "$k" || exit 2
    if fmux_conf_on "$k"; then nv=off; else nv=on; fi
    # Validate and write directly in this process (functions from 85-config-cli.sh). Forking via
    # `$SELF config set` would make the child re-parse the config file, turning one broken line into two warnings per toggle.
    fmux_conf_validate "$k" "$nv" || exit 1
    fmux_conf_write "$k" "$nv" set || exit 1
    # snapshot_on_exit is a boolean baked into the tmux snippet — flipping it here must also update
    # the snippet. The value-input path (fmux_conf_view_once) leaves this to `$SELF config set`, which already runs it there.
    fmux_conf_resnip "$k"
    exit 0
fi

# Settings screen. Runs round after round until Esc/← exits.
if [ "${1:-}" = "--config-view" ]; then
    while :; do
        fmux_conf_view_once || break
    done
    exit 0
fi
