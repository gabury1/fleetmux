# ── Portability helpers (macOS/BSD ↔ Linux) ─────────────────────────────────
# One process-name field. On macOS, ps gives comm the executable's 'absolute path' (Linux gives
# just the basename) → only the last path segment must be kept so both sides compare equally as
# "claude". -p/-o comm= itself is POSIX.
fmux_comm() {
    local c
    c=$(ps -p "${1:-0}" -o comm= 2>/dev/null) || return 1
    c=${c##*/}
    printf '%s' "$c"
}

# bash 3.2's (macOS's default /bin/bash) read rejects a fractional timeout ("invalid timeout
# specification"). Every place that needs a fractional wait branches in this one spot — absorb it
# on 4.x, give up on 3.2 (to avoid a 1-second stall).
if [ "${BASH_VERSINFO[0]:-3}" -ge 4 ]; then FMUX_TINY_READ=1; else FMUX_TINY_READ=0; fi

# Log rotation — hook.log gets ~1600 lines appended to the SD card per day, constantly. Once it
# crosses the threshold, truncate it to keep only the tail.
#   Size is measured with `wc -c <file` (POSIX) — stat has -c on GNU and -f on BSD, opposite flags.
#   Called only from --cron (every minute), the boot hook, and --boot-restore — calling it on
#   every event would add one more fork to the hook path.
#   The file to rotate is swapped in via FMUX_LOG_FILE (--boot-restore's boot.log). The default
#   stays hook.log as before, so existing call sites don't change a single character — there's no
#   reason to split the rotation policy into two.
#   Passed as an env var prefix rather than an argument, following the same convention as
#   fmux_fin_norm's FMUX_FIN_SKIP.
#
#   The threshold in bytes is the config key log_max. This used to set a global here with
#   `FMUX_LOG_MAX=${FMUX_LOG_MAX:-1048576}`, and that one line broke two things:
#     ① Even if log_max was set in the config file, this global was already established, so it
#        had no effect.
#     ② That global's name happened to be log_max's env var name (FMUX_LOG_MAX), so every lookup
#        afterward was judged as "env wins" — the config screen rejected the log_max toggle
#        outright.
#   So the global is gone, and it's only read at the moment rotation actually needs it. Env var
#   priority is already honored by the lookup function (FMUX_LOG_MAX=… still wins). If the file
#   doesn't exist, there isn't even a lookup, so the fork count on the hook path stays 0 as before.
#   ⚠ The entry point that calls rotation must first establish the config cache as a bare
#      statement, not inside a subshell (the contract in 05-config.sh) — the lookup below is
#      inside $(...), so the cache doesn't escape this function.
FMUX_LOG_KEEP=${FMUX_LOG_KEEP:-2000}
fmux_log_rotate() {
    local f="${FMUX_LOG_FILE:-$STATE/hook.log}" sz max
    [ -f "$f" ] || return 0
    # Repair a log written before the umask policy existed. Only reached from --cron and the boot
    # path, so this is not on the hook hot path. A log that has caught a prompt in its stderr must
    # not be readable by other accounts on the machine.
    chmod 600 "$f" 2>/dev/null || true
    sz=$(wc -c < "$f" 2>/dev/null | tr -d ' ') || return 0
    case "$sz" in ''|*[!0-9]*) return 0 ;; esac
    max=$(fmux_conf_num log_max)
    [ "$sz" -gt "$max" ] || return 0
    if tail -n "$FMUX_LOG_KEEP" "$f" > "$f.tmp" 2>/dev/null; then
        mv -f "$f.tmp" "$f" 2>/dev/null || { rm -f "$f.tmp"; return 0; }
        echo "$(date '+%F %T') - ${f##*/} rotated (was $sz bytes)" >> "$f"
    else
        rm -f "$f.tmp"
    fi
    return 0
}

# The absolute path of a running process's executable.
#   Linux keeps it as the /proc/<pid>/exe symlink. macOS has no /proc, but there its ps reports
#   comm as the full path — the very difference fmux_comm at the top of this file exists to
#   flatten. So the two platforms answer this with one function and no uname branch.
#   FMUX_PROC is the same test-injection door 30-state.sh uses — point it at a fake /proc and the
#   Linux half of this can be exercised anywhere.
fmux_exe_of() {
    local p
    p=$(readlink "${FMUX_PROC:-/proc}/${1:-0}/exe" 2>/dev/null) || p=""
    [ -n "$p" ] || p=$(ps -p "${1:-0}" -o comm= 2>/dev/null) || p=""
    # Only an absolute path is an answer. Linux ps would hand back a bare "tmux" here, which
    # would send the caller straight back to the PATH that already failed it.
    case "$p" in /*) printf '%s' "$p" ;; *) return 1 ;; esac
}

# ── tmux has to be findable from wherever fmux was started ──────────────────
# fmux shells out to tmux from ~150 places, and every one of them goes through PATH. The PATH
# fmux runs with is not the PATH you have:
#   · a popup inherits the **tmux server's** environment, and a server started straight from a
#     terminal app (Ghostty, iTerm) never read your shell rc — so a Homebrew prefix is missing
#   · cron hands you /usr/bin:/bin and nothing else
# On a Mac that leaves `tmux` itself off PATH inside the popup. Every call dies with 127, and
# because the list path discarded stderr, the popup drew an **empty session list** — which reads
# as "you have no sessions", not as a failure (reported 2026-08-14).
#
# It is the same failure as the missing fzf (2026-08-11). That fix was written for fzf alone,
# which is exactly why this one got through: the class is "the popup's PATH is not yours", and
# naming it "fzf is missing" fixed one member of it.
#
# Repairing PATH is what this does — not rewriting the call sites. One export covers all ~150,
# including the calls that live inside strings and that no call-site rewrite could reach: the
# fzf binding `ctrl-d:execute-silent(tmux detach-client)`, and the snippet --tmux-conf emits.
fmux_tmux_find() {
    local p pid
    # ① what someone told us explicitly. An absolute path does not care what any startup file did.
    p=$(fmux_conf_get tmux_path 2>/dev/null) || p=""
    if [ -n "$p" ] && [ -x "$p" ]; then printf '%s' "$p"; return 0; fi
    # ② ask the tmux server we are already running inside. $TMUX is
    #    "<socket>,<server pid>,<session index>", and that pid is a tmux binary by definition —
    #    so in a popup this needs no config and no guessing, which is the case that was broken.
    if [ -n "${TMUX:-}" ]; then
        pid=${TMUX#*,}; pid=${pid%%,*}
        case "$pid" in
            ''|*[!0-9]*) ;;
            *) p=$(fmux_exe_of "$pid") || p=""
               if [ -n "$p" ] && [ -x "$p" ]; then printf '%s' "$p"; return 0; fi ;;
        esac
    fi
    # ③ the usual prefixes. This is the cron case, where ② has no $TMUX to read.
    #    FMUX_TMUX_PROBE is the test-injection door (the same idea as FMUX_PROC in 30-state.sh):
    #    without it, "no tmux anywhere" cannot be staged on a machine that has one at /usr/bin.
    for p in ${FMUX_TMUX_PROBE-/opt/homebrew/bin/tmux /usr/local/bin/tmux /opt/local/bin/tmux \
             /home/linuxbrew/.linuxbrew/bin/tmux /usr/pkg/bin/tmux /usr/bin/tmux /bin/tmux}; do
        if [ -x "$p" ]; then printf '%s' "$p"; return 0; fi
    done
    return 1
}

# Put tmux on PATH if it isn't already. Costs one builtin lookup when things are normal, which
# is every run on every Linux box — nothing below the first line executes there.
fmux_ensure_tmux() {
    command -v tmux >/dev/null 2>&1 && return 0
    # Bare statement, not a subshell — the contract in 05-config.sh. fmux_tmux_find reads the
    # config from inside $( ), and without this the parse (and any warning it prints) would
    # happen there and be thrown away with the subshell.
    fmux_conf_load
    local t
    t=$(fmux_tmux_find) || return 1
    PATH="${t%/*}:$PATH"
    export PATH                                  # children need it: $SELF --list, the fzf bindings
    command -v tmux >/dev/null 2>&1
}

# Runs for every entry point, because every entry point calls tmux. The flag is what the popup
# reads to decide whether to explain itself — the callers that don't need tmux (config, --help)
# never look at it.
FMUX_TMUX_OK=1
fmux_ensure_tmux || FMUX_TMUX_OK=0

# Hold a screen open long enough to be read. A popup is its own window that tmux tears down the
# instant the command returns, so a message printed on the way out is never seen.
#   `: < /dev/tty` is the test, not `[ -c /dev/tty ]`: the device node exists even when the
#   process has no controlling terminal, and opening it is the only thing that tells them apart.
#   The redirect of stderr comes **before** the open, or the shell prints its own failure first.
#   FMUX_TTY=off means "there is no one here", the same switch and the same meaning install.sh
#   has (install.sh:153). Without it these branches cannot be tested at all: a suite run from a
#   terminal can open /dev/tty, so the assertion would sit waiting for a keypress instead of
#   failing — which is why the "fzf is missing" branch went untested until now.
fmux_hold_tty() {
    if [ "${FMUX_TTY:-}" != off ] && : 2>/dev/null < /dev/tty; then
        printf '\n  Press any key to close.' >&2
        read -rsn1 _ </dev/tty 2>/dev/null || read -r _ </dev/tty 2>/dev/null || true
    fi
}

