# ── Portability helpers (macOS/BSD ↔ Linux) ─────────────────────────────────
# One process-name field. On macOS, ps gives comm the executable's 'absolute path' (Linux gives
# just the basename) → only the last path segment must be kept so both sides compare equally as
# "claude". -p/-o comm= itself is POSIX.
tt_comm() {
    local c
    c=$(ps -p "${1:-0}" -o comm= 2>/dev/null) || return 1
    c=${c##*/}
    printf '%s' "$c"
}

# bash 3.2's (macOS's default /bin/bash) read rejects a fractional timeout ("invalid timeout
# specification"). Every place that needs a fractional wait branches in this one spot — absorb it
# on 4.x, give up on 3.2 (to avoid a 1-second stall).
if [ "${BASH_VERSINFO[0]:-3}" -ge 4 ]; then TT_TINY_READ=1; else TT_TINY_READ=0; fi

# Log rotation — hook.log gets ~1600 lines appended to the SD card per day, constantly. Once it
# crosses the threshold, truncate it to keep only the tail.
#   Size is measured with `wc -c <file` (POSIX) — stat has -c on GNU and -f on BSD, opposite flags.
#   Called only from --cron (every minute), the boot hook, and --boot-restore — calling it on
#   every event would add one more fork to the hook path.
#   The file to rotate is swapped in via TT_LOG_FILE (--boot-restore's boot.log). The default
#   stays hook.log as before, so existing call sites don't change a single character — there's no
#   reason to split the rotation policy into two.
#   Passed as an env var prefix rather than an argument, following the same convention as
#   tt_fin_norm's TT_FIN_SKIP.
#
#   The threshold in bytes is the config key log_max. This used to set a global here with
#   `TT_LOG_MAX=${TT_LOG_MAX:-1048576}`, and that one line broke two things:
#     ① Even if log_max was set in the config file, this global was already established, so it
#        had no effect.
#     ② That global's name happened to be log_max's env var name (TT_LOG_MAX), so every lookup
#        afterward was judged as "env wins" — the config screen rejected the log_max toggle
#        outright.
#   So the global is gone, and it's only read at the moment rotation actually needs it. Env var
#   priority is already honored by the lookup function (TT_LOG_MAX=… still wins). If the file
#   doesn't exist, there isn't even a lookup, so the fork count on the hook path stays 0 as before.
#   ⚠ The entry point that calls rotation must first establish the config cache as a bare
#      statement, not inside a subshell (the contract in 05-config.sh) — the lookup below is
#      inside $(...), so the cache doesn't escape this function.
TT_LOG_KEEP=${TT_LOG_KEEP:-2000}
tt_log_rotate() {
    local f="${TT_LOG_FILE:-$STATE/hook.log}" sz max
    [ -f "$f" ] || return 0
    # Repair a log written before the umask policy existed. Only reached from --cron and the boot
    # path, so this is not on the hook hot path. A log that has caught a prompt in its stderr must
    # not be readable by other accounts on the machine.
    chmod 600 "$f" 2>/dev/null || true
    sz=$(wc -c < "$f" 2>/dev/null | tr -d ' ') || return 0
    case "$sz" in ''|*[!0-9]*) return 0 ;; esac
    max=$(tt_conf_num log_max)
    [ "$sz" -gt "$max" ] || return 0
    if tail -n "$TT_LOG_KEEP" "$f" > "$f.tmp" 2>/dev/null; then
        mv -f "$f.tmp" "$f" 2>/dev/null || { rm -f "$f.tmp"; return 0; }
        echo "$(date '+%F %T') - ${f##*/} rotated (was $sz bytes)" >> "$f"
    else
        rm -f "$f.tmp"
    fi
    return 0
}

