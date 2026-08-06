# ── rc (Remote Control) verdict logic ──────────────────────────────────────
# To view a session from the phone, claude needs to be attached to the rc bridge. The bridge
# silently disconnects on a 25-minute timeout, compaction, or idle (an official unresolved
# bug), and recovery is manual /remote-control re-run only — this automates that.
# The source of truth is bridgeSessionId in ~/.claude/sessions/<pid>.json, which claude writes
# directly.
#   null = disconnected / has a value = connected (claude.ai/code/<value>). The file disappears
#   when the session dies.
#   Do not trust the file's name field (different sessions can be stamped with the same name)
#   — mapping must always go through PID.
SESSD=~/.claude/sessions

# Shallow JSON value extraction (strips quotes off strings, empty if key missing) — no jq, no
# fork. This is on the path that walks every session once a minute.
rc_val() {
    local re="\"$2\"[[:space:]]*:[[:space:]]*(\"[^\"]*\"|[^,}]*)"
    [[ "$1" =~ $re ]] || return 0
    printf '%s' "${BASH_REMATCH[1]//\"/}"
}

# Read the entire session file at once. If we read half of a file claude is mid-write on
# (a truncated file) and misjudge it as "rc disconnected", we'd send keys to a perfectly fine
# session -> check completeness (the trailing }) first, and if it's incomplete, give up the
# verdict for this round.
rc_read() {
    local j
    j=$(cat "$1" 2>/dev/null) || return 1
    case "$j" in *'"sessionId":"'*'}') printf '%s' "$j" ;; *) return 1 ;; esac
}

# /proc/<pid>/stat field 22 (starttime) — cross-checked against the json's procStart to guard
# against PID reuse.
rc_procstart() {
    local s
    s=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
    s=${s##*) }                       # start right after comm (field 3, state) -> field 22 is field 20 from here
    printf '%s' "$s" | awk '{print $20}'
}

# Descend below the pane pid to find claude's real PID (the opposite direction of --hook's
#   parent-chain walk).
#   Qualification: has a session file + comm is claude + procStart matches. Even with wrapper
#   or intermediate shells in between, it descends a few levels and catches it.
#   If there are two candidates at the same level, give up — grabbing the wrong PID would show
#   someone else's state (no false positives allowed).
rc_claude_pid() {
    local level="$1" next hits p c n d=0 pst j
    while [ -n "${level// /}" ] && [ "$d" -lt 4 ]; do
        hits=""; next=""; n=0
        for p in $level; do
            if [ -f "$SESSD/$p.json" ] && [ "$(tt_comm "$p" || true)" = claude ]; then
                pst=$(rc_procstart "$p" || true)
                j=$(rc_read "$SESSD/$p.json") || j=""
                if [ -n "$j" ] && [ -n "$pst" ] && [ "$pst" = "$(rc_val "$j" procStart)" ]; then
                    hits="$hits $p"; n=$((n+1))
                fi
            fi
            c=$(pgrep -P "$p" 2>/dev/null | tr '\n' ' ')
            next="$next $c"
        done
        [ "$n" = 1 ] && { printf '%s' "${hits# }"; return 0; }
        [ "$n" -gt 1 ] && return 1
        level="$next"; d=$((d+1))
    done
    return 1
}

# tmux session -> "pane_id claude_pid" (rc 1 if undecidable/ambiguous). Scans panes across any window.
rc_target() {
    local pane ppid pid found=""
    while read -r pane ppid; do
        pid=$(rc_claude_pid "$ppid") || continue
        [ -n "$found" ] && return 1     # two claudes in one session = don't know where to type -> give up
        found="$pane $pid"
    done < <(tmux list-panes -s -t "$1" -F '#{pane_id} #{pane_pid}' 2>/dev/null || true)
    [ -n "$found" ] || return 1
    printf '%s' "$found"
}

# rc auto-recovery (cron, every 1 minute): re-injects /remote-control only into disconnected
#   claude sessions.
#   send-keys only fires when "bridgeSessionId is actually null + not currently working" —
#   injecting while working would pollute the input.
#   Typing /remote-control into an already-connected session doesn't disconnect it, it just
#   opens the modal -> Escape is mandatory after injection.
#   tt --cron <session name> checks only one session (for debugging).
# The display cache for --list ($STATE/rc-off) is swapped at the end of each round — the list
# is a path the user's hand touches often, and running a pgrep fan-out there would make the
# popup noticeably sluggish (measured 0.05s -> 0.4s). The verdict is computed only here.
if [ "${1:-}" = "--cron" ] || [ "${1:-}" = "--rc-check" ]; then   # old name kept for backward compatibility
    # Load config once at the top of the entry point, as a bare statement, not a subshell
    # (the contract in 05-config.sh:53). Calling it inside $(...) would let the cache die with
    # that subshell, and the loop below would re-parse the file per session and fire the
    # broken-line warning that many times, every minute, duplicated.
    tt_conf_load
    # rc switch. Exiting here would also kill the --snapshot at the end of this block (line
    # 142) — since rc and snapshot are separate switches, we only "skip without exiting."
    tt_rc_enabled=1
    tt_conf_on rc || tt_rc_enabled=0
    # cron runs every minute -> stay silent where output is swallowed by a redirect (otherwise
    # cron mail piles up every minute), and only tell the reason on a terminal a human typed
    # into directly.
    if [ "$tt_rc_enabled" = 0 ] && [ -t 1 ]; then
        printf 'rc=off — skipping auto-recovery (tt config set rc on)\n'
    fi
    only="${2:-}"; off=""
    mkdir -p "$STATE"
    tt_log_rotate                              # so the audit log doesn't eat away at the SD card (once per minute)
    # In case a round runs long (~11s per recovered session), don't overlap with the next cron
    # tick and fire twice.
    if command -v flock >/dev/null 2>&1; then
        exec 9>"$STATE/rc.lock"
        flock -n 9 || exit 0
    fi
    # Wraps the entire rc round (the single `while` statement below). `while … done < <(tmux ls
    # …)` is a single statement that can't be split, so the switch must come before the while —
    # the moment we enter it, process substitution has already forked tmux. The inner
    # indentation is left as-is on purpose (re-indenting all 53 lines would bury the real
    # change in the diff).
    if [ "$tt_rc_enabled" = 1 ]; then
    while read -r sid name; do
        [ -z "$only" ] || [ "$name" = "$only" ] || continue
        t=$(rc_target "$sid") || continue          # no claude / ambiguous / suspected PID reuse -> silently skip
        pane=${t%% *}; cpid=${t##* }
        f="$SESSD/$cpid.json"
        ff="$STATE/rc-fail-${sid#\$}"
        # disconnected = bridgeSessionId is null or entirely absent (a session that never turned rc on)
        j=$(rc_read "$f") || continue              # file is half-written -> try again next round
        b=$(rc_val "$j" bridgeSessionId)
        case "$b" in
            ""|null) ;;                            # disconnected -> a recovery candidate
            *) rm -f "$ff"; continue ;;            # connected -> no action + reset the failure count
        esac
        off="$off ${sid#\$}=off"                               # from here it's confirmed disconnected -- ⊘ in the list
        [ "$(rc_val "$j" status)" = busy ] && continue         # working -> defer this round
        hs=$(cut -d' ' -f1 "$STATE/hook-${sid#\$}" 2>/dev/null || true)
        case "$hs" in working|waiting) continue ;; esac        # double safety check via the tt hook state
        # Backoff: give up after 3 consecutive failures for the same claude (same PID) — so we
        # don't keep typing into a dead session.
        n=0; fpid=""; lastok=0
        [ -f "$ff" ] && read -r n fpid lastok < "$ff" || true
        [ "${fpid:-}" = "$cpid" ] || { n=0; lastok=0; }        # if claude has restarted, start a new count
        case "${lastok:-0}" in ''|*[!0-9]*) lastok=0 ;; esac
        # Recurrence brake: it just recovered successfully but disconnected again within 5
        # minutes = a session that won't stay connected no matter how many times we attach it.
        # It used to clear the counter on success, so fails stayed at 0 forever, and the
        # injection repeated every minute indefinitely (measured 2026-07-25: $7 and $8 kept
        # leaving "ok" log entries alternately, 1 minute apart, while /remote-control kept
        # appearing on screen).
        # Sessions like this hit a bridge bug we can't fix ourselves (the CC #34868 family), so
        # we back off.
        if [ "$lastok" -gt 0 ] && [ $(( $(date +%s) - lastok )) -lt 300 ]; then
            n=$((n + 1))
            echo "$n $cpid $lastok" > "$ff"
            echo "$(date '+%F %T') $sid rc-relapse $n" >> "$STATE/hook.log"
            [ "$n" -ge 3 ] && off="${off% *} ${sid#\$}=gave"
            continue                                           # don't inject this round
        fi
        if [ "${n:-0}" -ge 3 ]; then off="${off% *} ${sid#\$}=gave"; continue; fi
        # Recovery -- one session at a time, sequentially (no concurrent send-keys)
        tmux send-keys -t "$pane" -l "/remote-control"
        sleep 0.7
        tmux send-keys -t "$pane" Enter
        sleep 8
        tmux send-keys -t "$pane" Escape                       # close the status panel (modal) -- if not closed, input stays blocked
        sleep 2
        b=$(rc_val "$(rc_read "$f" || true)" bridgeSessionId)
        if [ -n "$b" ] && [ "$b" != null ]; then
            # Don't delete the file even on success -- we need to keep the success time to see
            # a "connected, then disconnected again" recurrence.
            # Reset the failure count to 0 (consecutive failures and recurrence are different axes).
            echo "0 $cpid $(date +%s)" > "$ff"
            off="${off% *}"                                    # came back to life -> cancel the list display
            echo "$(date '+%F %T') $sid rc-recover ok" >> "$STATE/hook.log"
        else
            echo "$((n+1)) $cpid ${lastok:-0}" > "$ff"
            [ $((n+1)) -ge 3 ] && off="${off% *} ${sid#\$}=gave"
            echo "$(date '+%F %T') $sid rc-recover fail" >> "$STATE/hook.log"
        fi
    done < <(tmux ls -F '#{session_id} #{session_name}' 2>/dev/null || true)
    fi                                         # <- end of the rc switch. Below runs even if rc=off.
    # Swap the display cache wholesale -- no dead-session leftovers linger. A round that only
    # checked a single session doesn't touch this.
    #   If rc=off, $off is empty, leaving only the timestamp = every ⊘ badge disappears. If we
    #   didn't write it, the stale badges from right before it was turned off would linger on
    #   screen for up to 5 more minutes (the staleness window in 80-view.sh).
    [ -n "$only" ] || printf '%s%s\n' "$(date +%s)" "$off" > "$STATE/rc-off"
    # Also solidify the fleet snapshot here — since we're already walking every
    # session once a minute anyway.
    # The manifest stays current even without opening the popup, so up to 1 minute of state
    # survives even a sudden reboot.
    #   If snapshot=off, the child would also return early on its own, but we block it here
    #   too, to save the once-a-minute fork itself.
    tt_conf_on snapshot && { [ -n "$only" ] || "$SELF" --snapshot >/dev/null 2>&1 || true; }
    exit 0
fi

# rc status table (read-only, for debugging): session / rc / URL
if [ "${1:-}" = "--rc" ]; then
    tt_conf_load                               # bare statement, not a subshell (the contract in 05-config.sh:53)
    # Bail out before the first tmux call that draws the table (the while below) — for someone
    # who has turned off auto-recovery, the rc status table would just be a table asking "why
    # is everything OFF" right back at them.
    tt_conf_on rc || { printf 'rc=off — auto-recovery is disabled (tt config set rc on)\n'; exit 0; }
    # The entire rc verdict hangs on /proc/<pid>/stat (rc_procstart). On a machine without
    # /proc (macOS), rc_target always fails and the table below becomes **'?' in every row** —
    # that's unsupported, not broken, but looking at the table alone you can't tell the
    # difference. We say that one line here (the same fact as the macOS section in the README).
    [ -d /proc ] || printf 'note: rc auto-recovery needs /proc/<pid>/stat -- this machine has no /proc (macOS unsupported). Every row below will show ?\n'
    printf '%-18s %-5s %s\n' SESSION RC URL
    while read -r sid name; do
        if ! t=$(rc_target "$sid"); then
            printf '%-18s %-5s %s\n' "$name" '?' 'no claude found'
            continue
        fi
        j=$(rc_read "$SESSD/${t##* }.json" || true)
        b=$(rc_val "$j" bridgeSessionId)
        n=0; fpid=""; lastok=0
        [ -f "$STATE/rc-fail-${sid#\$}" ] && read -r n fpid lastok < "$STATE/rc-fail-${sid#\$}" || true
        if [ -n "$b" ] && [ "$b" != null ]; then
            printf '%-18s %-5s %s\n' "$name" 'ON' "https://claude.ai/code/$b"
        else
            printf '%-18s %-5s %s\n' "$name" 'OFF' "pid ${t##* } · $(rc_val "$j" status) · fails ${n:-0}"
        fi
    done < <(tmux ls -F '#{session_id} #{session_name}' 2>/dev/null || true)
    exit 0
fi

