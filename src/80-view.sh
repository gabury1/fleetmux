# ── The real source of truth for "last conversation time": transcript ──────────
# We used to use the hook-<sid> record timestamp as "last conversation time". We measured that
#   this was wrong:
#   2026-07-25 12:41 boot → 13:10 --restore → hook-3/5/8 all updated to 13:10 → the whole fleet went bold.
#   On reboot, tmux reissues session ids starting from 0, so tt_sweep_hooks treats old hook files
#   as ghosts and deletes them, then the boot hook creates new ones — correct as "belongs to this
#   session" but completely wrong as "last conversation".
#
# The transcript file is the real source of truth. Path: $HOME/.claude/projects/*/<conversation-id>.jsonl
#   (the conversation id is globally unique, so there's no need to guess the project folder —
#   the same glob --restore uses).
#
# However, **the file mtime must not be used** (we hit this trap and measured it):
#   claude --resume and the remote-control bridge append a `{"type":"bridge-session",…}` line. This
#   line has no timestamp field. So right after a restore, ULTRACODE's mtime was 13:10:45 while the
#   last real turn was 2026-07-24T16:03:12Z — using mtime would have left the bug in place (confirmed
#   directly).
#   So instead we read the last "timestamp" value within the trailing 64KB. Bridge lines have no
#   timestamp and are filtered out automatically.
#
# Cost: regardless of session count, tail 1 + awk 1 = 2 forks.
#   tail seeks straight to the end for a regular file — even a 58MB transcript measured 1.3ms
#   (batched across 4).
#   Given that a single `stat` fork costs 1.2ms, this is actually cheaper than calling stat per session.
#
# Why we don't hand timestamp conversion to date: it adds one fork per session. We compute it
#   directly in awk (timestamps are always UTC 'Z'). We avoid mktime because mawk doesn't have it
#   (the Pi's default is mawk 1.3.4).
#   We also avoid regex {n} repetition — interval support differs by implementation (same reason as
#   TT_MF_CHECK_AWK).
# Output = one "<path>\t<epoch>" line per file. 0 if no timestamp is found — the caller falls back
#   to the hook timestamp.
TT_ACT_AWK='
    function iso2epoch(s,   y, mo, d, h, mi, se, yy, era, yoe, doy, doe, days) {
        y  = substr(s, 1, 4) + 0;  mo = substr(s, 6, 2) + 0;  d  = substr(s, 9, 2) + 0
        h  = substr(s, 12, 2) + 0; mi = substr(s, 15, 2) + 0; se = substr(s, 18, 2) + 0
        if (y < 1970 || mo < 1 || mo > 12 || d < 1 || d > 31) return 0
        yy  = y - (mo <= 2 ? 1 : 0)          # shifting the year start to March keeps the leap day always at the end
        era = int(yy / 400)
        yoe = yy - era * 400
        doy = int((153 * (mo + (mo > 2 ? -3 : 9)) + 2) / 5) + d - 1
        doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
        days = era * 146097 + doe - 719468   # 146097 = days in 400 years, 719468 = 0000-03-01→1970-01-01
        return days * 86400 + h * 3600 + mi * 60 + se
    }
    /^==> .* <==$/ {
        if (f != "") print f "\t" (best == "" ? 0 : iso2epoch(best))
        f = substr($0, 5, length($0) - 8); best = ""; next
    }
    {
        # A single line can hold multiple entries (a long line can be truncated and reorder them),
        # and ISO strings sort lexicographically = chronologically, so we just take the max.
        # "timestamp":" is 13 chars; the first 19 chars of the value go down to the second.
        s = $0
        while (match(s, /"timestamp":"[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]/)) {
            v = substr(s, RSTART + 13, 19)
            if (v > best) best = v
            s = substr(s, RSTART + RLENGTH)
        }
    }
    END { if (f != "") print f "\t" (best == "" ? 0 : iso2epoch(best)) }'

# List generation: sorted by content-change time (sessions with recent real conversation/work on top)
#   bold session name = a conversation within recent_hours (default 6h), dim = quieter than that  ●=attached  ✻=Claude working
# Output one line = "<name>\t<colored display string>\t<session id>". Why the name is split off by
#   tab and placed first: the value the picker extracts with {1} must stay intact even for names
#   with spaces. It used to be cut to just the first space-separated word, which hit tmux -t prefix
#   matching and killed the wrong session (reproduced on real hardware). fzf shows only field 2 via --with-nth.
#   Field 3 (session id, a number without $) is the key the preview uses to find last-<id>/hook-<id>.
#   {1} is the name, which alone can't find it, and asking again via display-message inside the
#   preview would add one fork every time the cursor moves — this loop already has sid in hand, so
#   we just tack it on (0 forks).
# Note: no parentheses allowed in the list — they collide with fzf --bind's reload(...) delimiter
if [ "${1:-}" = "--list" ]; then
    now=$(date +%s)
    # Config is loaded once at the top of the entry point as a bare statement, not in a subshell
    #   (contract of 05-config.sh).
    #   The two values below are pulled out before the loop — asking again per session would add
    #   a fork per session. Also the display loop runs inside a pipeline (subshell), so reading it
    #   there can't escape outward.
    tt_conf_load
    acc=$(tt_conf_num accent 255)              # accent colour, 256-colour number (goes inside the escape sequence)
    recent_s=$(( $(tt_conf_num recent_hours) * 3600 ))   # bold the name if there was a conversation within this window
    # rc display cache — the judgment is done by --cron (every minute), here we just read one line (0 forks)
    # If the cache is stale by more than 5 minutes = cron isn't running → quietly turn it off instead of scaring with a stale ⊘
    rcoff=""; rcts=0
    [ -f "$STATE/rc-off" ] && read -r rcts rcoff < "$STATE/rc-off" || true
    [ $(( now - ${rcts:-0} )) -lt 300 ] || rcoff=""
    # ── Activity-time pre-survey (exactly once, outside the loop) ─────────────────────
    # Re-reading the manifest per session would be O(session count × manifest lines) — read it once
    # and carry it as a table.
    # We don't use associative arrays (bash 4 only, breaks on the Mac's default 3.2 — same call as
    # tt_sweep_hooks).
    # Instead: a "\n<name>\t<value>" line table + case-glob lookup: safe even when names have
    # spaces, and 0 forks.
    # (the manifest forbids tabs in names, so tab is safe as a field separator)
    acttab=""; actn=(); actp=()
    if [ -s "$MANIFEST" ]; then
        while IFS=$'\t' read -r mname _ mkind _ mconv _ || [ -n "$mname" ]; do
            [ -n "$mname" ] || continue
            [ "$mkind" = agent ] || continue         # tool sessions get ts=0 anyway
            tt_is_uuid "${mconv:-}" || continue      # if we don't know the conversation id, leave it to the fallback
            for tf in "$HOME"/.claude/projects/*/"$mconv".jsonl; do
                [ -f "$tf" ] || continue             # a glob miss leaves the pattern itself unchanged
                actn+=("$mname"); actp+=("$tf")
                break                                # conversation id is globally unique — the first hit is the answer
            done
        done < "$MANIFEST"
    fi
    if [ "${#actp[@]}" -gt 0 ]; then
        # Why we append /dev/null: tail doesn't print the "==> …<==" header when there's only one file.
        # We always force multi-file mode to remove the parsing branch (an empty file, so 0 cost).
        actraw=$'\n'$(tail -c 65536 -- "${actp[@]}" /dev/null 2>/dev/null | awk "$TT_ACT_AWK") || actraw=""
        i=0
        while [ "$i" -lt "${#actp[@]}" ]; do
            # Look it back up by path (don't rely on output order — if a file disappears in
            # between, its header is dropped and everything shifts)
            v=""
            case "$actraw" in
                *$'\n'"${actp[$i]}"$'\t'*) v=${actraw#*$'\n'"${actp[$i]}"$'\t'}; v=${v%%$'\n'*} ;;
            esac
            case "$v" in ''|*[!0-9]*) v=0 ;; esac
            [ "$v" -gt 0 ] && acttab="$acttab"$'\n'"${actn[$i]}"$'\t'"$v"
            i=$((i + 1))
        done
    fi
    # The internal pipe is tab-delimited with the name as the last field — so a name with spaces
    #   doesn't push other fields out of place.
    #   attached uses a '-' sentinel instead of an empty value: tab is IFS whitespace, so read
    #   collapses consecutive tabs into one, which shifts every field for unattached sessions and
    #   drops the name (empty fields are forbidden).
    #   Using a control character like 0x1f as the delimiter is blocked — tmux -F escapes it out
    #   as the literal string \037.
    tmux ls -F $'#{session_id}\t#{session_created}\t#{?session_last_attached,#{session_last_attached},0}\t#{?session_attached,●,-}\t#{session_name}' 2>/dev/null \
        | while IFS=$'\t' read -r sid created la attached name; do
            # Agent sessions (claude/codex, group 1) go on top, tool sessions (yazi/htop etc, group 0) go at the bottom
            grp=0
            # We pass created along too: it's the basis for filtering out inherited stale hook
            # files, and since we already have the value in hand, it doesn't add a tmux call.
            # The judgment lives in exactly one place: tt_is_agent.
            tt_is_agent "$sid" "$created" && grp=1
            # Activity time: for agents = the timestamp of the last turn in the transcript (the
            #   pre-survey table above) — not the hook timestamp.
            #   Fallback ladder: transcript → hook record timestamp → creation time of a fresh
            #   session (under 1h) → 0.
            #   codex can't hand a conversation id to the hook, so it always falls back to the hook
            #   timestamp — this is intended behaviour.
            #   Tool sessions = time-independent, alphabetical (ts fixed at 0 → name becomes the 3rd sort key)
            if [ "$grp" = 1 ]; then
                # Read the hook file with read (used to be cut — 1 fork per session). We need the state too.
                hst=""; hts=0
                read -r hst hts _ 2>/dev/null < "$STATE/hook-${sid#\$}" || true
                case "$hts" in ''|*[!0-9]*) hts=0 ;; esac
                ats=0
                case "$acttab" in
                    *$'\n'"$name"$'\t'*) ats=${acttab#*$'\n'"$name"$'\t'}; ats=${ats%%$'\n'*} ;;
                esac
                case "$ats" in ''|*[!0-9]*) ats=0 ;; esac
                if [ "$ats" -gt 0 ]; then
                    ts="$ats"
                    # We accept exactly one case where the hook is newer than the transcript —
                    #   "a turn is running right now". This covers the few seconds after a prompt
                    #   is sent but before the file has been written yet.
                    #   idle must not be accepted: idle is exactly what the boot hook writes, so
                    #   the restore time would masquerade as "last conversation" — reviving the
                    #   very bug we were fixing.
                    case "$hst" in
                        working|waiting) if [ "$hts" -gt "$ts" ]; then ts="$hts"; fi ;;
                    esac
                elif [ "$hts" -gt 0 ]; then
                    ts="$hts"
                elif [ $(( now - ${created:-0} )) -lt 3600 ]; then
                    ts="$created"
                else
                    ts=0
                fi
            else
                ts=0
            fi
            # Unread flag (finished while away, not yet visited) — promoted to the 2nd sort key:
            #   sessions with something to see go on top.
            #   finished can have old and new formats mixed (mid-migration), and names can contain
            #   spaces → split the format by the ts position and treat the rest as the name, only
            #   accepting an "exact" match
            unread=0
            if [ -s "$STATE/finished" ]; then
                fts=$(TT_FIN_NAME="$name" awk '
                    BEGIN { want = ENVIRON["TT_FIN_NAME"]; r = 0 }
                    {
                        if ($1 ~ /^[0-9]+$/)                  { t = $1;  s = $0; sub(/^[0-9]+[ \t]+/, "", s) }
                        else if (NF > 1 && $NF ~ /^[0-9]+$/)  { t = $NF; s = $0; sub(/[ \t]+[0-9]+[ \t]*$/, "", s) }
                        else next
                        if (s == want && t + 0 > r) r = t + 0
                    }
                    END { print r }' "$STATE/finished")
                [ "${fts:-0}" -gt 0 ] && [ "${la:-0}" -lt "$fts" ] && unread=1
            fi
            printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$grp" "$unread" "${ts:-0}" "${sid#\$}" "$attached" "$name"
        done | sort -t$'\t' -k1,1rn -k2,2rn -k3,3rn -k6,6 \
        | while IFS=$'\t' read -r grp unread ts sid attached name; do
            [ "$name" = "${TT_CUR:-}" ] && continue
            [ "$attached" = - ] && attached=""    # release the sentinel — from here on it's an empty display string
            if [ "$grp" = 0 ]; then   # tool session: teal, bottom group, no state decoration
                printf '%s\t\033[38;5;%sm%s\033[0m \033[36m%s\033[0m\t%s\n' "$name" "$acc" "$name" "$attached" "$sid"
                continue
            fi
            # State: hook record takes priority (accurate); fall back to screen judgment if missing or the hook process is dead
            mark=""; hstate=""
            if [ -f "$STATE/hook-$sid" ]; then
                read -r hstate _hts hpid 2>/dev/null < "$STATE/hook-$sid" || true
                if [ "$hstate" != idle ] && [ "${hpid:-0}" -gt 0 ] && ! kill -0 "$hpid" 2>/dev/null; then hstate=""; fi
            fi
            case "$hstate" in
                working)
                    # Anti-"stuck" guard: if updates have stopped and there's no other evidence,
                    #   treat it as a lost Stop event and turn it off. Cancelling a turn with Esc
                    #   makes Claude Code not fire Stop, so working stays stuck as-is (reported
                    #   from real usage).
                    # The evidence set is stacked with **OR** — the removal condition is unchanged
                    #   from before this was introduced: "none of the three".
                    #   ① Hook is fresh (≤20s) → the agent's own confession, most accurate, 0 forks. Stays priority 1.
                    #   ② CPU delta (30-state.sh) → kernel accounting, independent of TUI wording, 0 forks.
                    #      Placed ahead of the screen check because it's cheap (0 forks vs 3) and
                    #      solid, and when it's wrong it errs toward "unknown", so ③ catches it.
                    #      If positive, tmux is never called, so the popup draws that much faster.
                    #   ③ Screen judgment → it's rendering, so it can break again anytime (this
                    #      very bug), but it's kept as the last line of defense. It's the only
                    #      thing that can rescue the case where the CPU signal errs toward a false
                    #      negative (a session starved under load, or a future TUI that stops
                    #      rendering while waiting).
                    if [ $(( now - ${_hts:-0} )) -le 20 ]; then
                        mark=$'\033[33m✻\033[0m'
                    else
                        cbusy=0; tt_cpu_busy "$sid" "${hpid:-0}" "$now" || cbusy=$?
                        if [ "$cbusy" = 0 ]; then
                            mark=$'\033[33m✻\033[0m'
                        elif tmux capture-pane -p -t "=$name:" 2>/dev/null | tt_working; then
                            mark=$'\033[33m✻\033[0m'
                        else
                            mark=""
                        fi
                    fi
                    # Leave a sample for the next call regardless of the judgment result (untouched if within ROTATE)
                    tt_cpu_sample "$sid" "${hpid:-0}" "$now" ;;
                waiting)
                    # Anti-"stuck" guard: if approval is denied, codex doesn't fire Stop —
                    # if there's been no update for over 60s and the screen shows no approval
                    # prompt, treat it as cancelled.
                    # The witness list is consolidated into a single WAITING_PAT (30-state.sh) —
                    # when it used to live inline here, nobody caught the mismatch where only the
                    # list cleared ⏸ while the status bar kept showing it (measured with AskUserQuestion).
                    if [ $(( now - ${_hts:-0} )) -gt 60 ] \
                        && ! tmux capture-pane -p -t "=$name:" 2>/dev/null \
                             | grep -qaE "$WAITING_PAT"; then
                        mark=""
                    else
                        mark=$'\033[38;5;215m⏸\033[0m'
                    fi ;;
                idle) ;;
                *) if tmux capture-pane -p -t "=$name:" 2>/dev/null | tt_working; then mark=$'\033[33m✻\033[0m'; fi ;;
            esac
            # Unread ✓: a session that finished while away and hasn't been visited yet (disappears once visited)
            umark=""
            [ "$unread" = 1 ] && umark=$'\033[38;5;108m✓\033[0m'
            # rc ⊘: shown only for sessions not visible on the phone (connected is the default, so this should stay quiet). Red = gave up backing off
            rcmark=""
            case " $rcoff " in
                *" $sid=gave "*) rcmark=$'\033[1;38;5;160m⊘\033[0m' ;;
                *" $sid=off "*)  rcmark=$'\033[38;5;245m⊘\033[0m' ;;
            esac
            if [ $(( now - ts )) -lt "$recent_s" ]; then
                printf '%s\t\033[1m%s\033[0m \033[36m%s\033[0m %s %s %s\t%s\n' "$name" "$name" "$attached" "$mark" "$umark" "$rcmark" "$sid"
            else
                printf '%s\t\033[2m%s\033[0m \033[36m%s\033[0m %s %s %s\t%s\n' "$name" "$name" "$attached" "$mark" "$umark" "$rcmark" "$sid"
            fi
        done || true
    # Every line that comes out here is **one real tmux session line** — non-session rows (the old
    #   ⚙ settings row) are never included. Six places consume this list (preview, ^X, ^E, ^B,
    #   multi-select collection, empty-list bootstrap); leaking one non-session row would mean all
    #   six need a "this isn't a session" guard, and missing just one sends it hunting for a tmux
    #   session that doesn't exist (bootstrap judgment actually broke this way once).
    #   The one door to settings is ^O in the popup — the footer at the bottom of the screen always shows that key.
    # `|| true` and exit 0: if there's no tmux server, tmux ls dies and pipefail inherits that.
    #   Zero sessions isn't a failure, it's an "empty list", so we swallow it here and exit cleanly
    #   — the caller (empty-list bootstrap) judges by whether output is empty, not by rc.
    exit 0
fi

