# Fleet aggregate for the status bar "⏸2 ✻3" — removes the problem where the most urgent
#   signal (⏸) was only visible by opening the popup.
#   Colors match the --list palette exactly (⏸ orange 215, ✻ yellow 33). Omitted when 0.
#
# This is also the **sampler** for the CPU snapshot. The status bar runs status-interval 5,
# refreshing every 5 seconds (`#(fmux --status)` in .tmux.conf) and refreshes the sample of
# working sessions — thanks to that, the popup (--list) always gets a fresh 3-10 second window
# with sleep 0, no matter when it's opened. Keeping the sampler here is the axis of the design.
#
# Relationship between the verdict rule and --list (EVIDENCE.md: "status bar shows ✻4, list
# shows no marks"):
#   --list stacks three witnesses — (1) hook freshness (<=20s) (2) CPU delta (3) screen
#   (capture-pane). Here, (3) is absent: we don't know the session name, and capture-pane on
#   the entire fleet every 5 seconds is not affordable. If we pretend to "clear" without one
#   witness, we'd clear ✻ **more aggressively** than --list does — that's not matching the
#   rule, it's breaking it. So here, if the hook is working, we count it unconditionally.
#   That leaves the mismatch running in one direction only — **for sessions that have a hook**,
#   status bar ✻n >= popup mark count. (Sessions without a hook file are outside this
#   function's view, so they aren't subject to this inequality. That's a difference in
#   observation scope, not a rule mismatch.)
#   t-10 pins this inequality against the 12-cell grid of expected values for
#   hook fresh/stale x CPU rc0/rc1/rc2 x screen match/mismatch.
# Colours are drawn as **chips** (our own background), not foreground-only.
#   Foreground-only means legibility depends on whichever status-bar theme the user has. Measured
#   2026-08-06: on the stock tmux status bar, which is lime green, the orange (215) and yellow
#   foregrounds were nearly invisible. Choosing the background ourselves guarantees contrast on any
#   theme — a badge is an alarm, not decoration.
#   The foreground colours are the ones this tool always used — ⏸ orange, ✻ yellow, ✓ green.
#   Only the background is new, and it is **one colour for all three** (a dark chip). Recolouring
#   the glyphs would have thrown away the meaning they already carry; the background is the part
#   that was missing.
tt_fleet_agg() {
    local f st ts pid w=0 k=0 out="" now sid wids="" wnames="" wshown=0 nm line
    now=$(date +%s)
    for f in "$STATE"/hook-*; do
        [ -f "$f" ] || continue
        st=""; ts=0; pid=0
        read -r st ts pid < "$f" 2>/dev/null || true
        case "$st" in waiting|working) ;; *) continue ;; esac
        # If the hook process is dead, it's a "stuck" state — don't count it (same criterion as --list's liveness check)
        case "$pid" in ''|*[!0-9]*) pid=0 ;; esac
        [ "$pid" -gt 0 ] && ! kill -0 "$pid" 2>/dev/null && continue
        case "$ts" in ''|*[!0-9]*) ts=0 ;; esac
        case "$st" in
            waiting)
                w=$((w + 1))
                # Remember which session is blocked, too — ⏸ is a state that **only ends when
                # a human touches it**. If we only show a count, you'd have to open the popup
                # to find out "who?", and that one open is itself the delay.
                # (✓ already carries a name. It was backwards that the more urgent ⏸ didn't.)
                wids="$wids ${f##*/hook-}" ;;
            working)
                sid=${f##*/hook-}
                # If the hook is working, **count it unconditionally** — there's no 3rd-tier
                #   witness (screen) here. Even if CPU answers rc1 (definitely idle), we don't
                #   subtract it. Measured: a claude waiting on a tool-call response oscillates
                #   between 3-22 cs/s and keeps crossing the threshold of 6 (24% of a 3-second
                #   window falls below threshold). If the status bar, which runs every 5
                #   seconds, turns the badge off based on one single window, the ✻n of a
                #   genuinely working session flickers — that's the exact bug we were trying to
                #   fix. Un-sticking is left entirely to --list, where the screen witness stands
                #   (false negative > false positive: ✻n is just a count badge, so counting one
                #   extra is cheap, while undercounting can miss an absent fleet entirely).
                k=$((k + 1))
                # *The sampler must stay here* — the status bar rotating the sample here every
                #   5 seconds is the axis of the CPU delta design. Without this line, there
                #   would be no sample at all for the popup (--list) to use when opened,
                #   tt_cpu_busy would be permanently rc2, and criterion C would die entirely.
                tt_cpu_sample "$sid" "$pid" "$now" ;;
        esac
    done
    # Attach names to ⏸. Query tmux **exactly once** — this function is called by the status
    #   bar every 5 seconds. Calling display-message per session would add one fork per
    #   waiting session.
    if [ "$w" -gt 0 ]; then
        wnames=$(tmux list-sessions -F '#{session_id} #{session_name}' 2>/dev/null || true)
        if [ -n "$wnames" ]; then
            for sid in $wids; do
                nm=""
                while read -r line; do
                    case "$line" in "\$$sid "*) nm=${line#* }; break ;; esac
                done <<< "$wnames"
                [ -n "$nm" ] || continue
                # Write up to three, then +n for the rest — the status bar is narrow, and tmux truncates the whole thing if it overflows.
                if [ "$wshown" -lt 3 ]; then
                    out="$out#[fg=colour215,bg=colour235,bold] ⏸ $nm #[default] "
                    wshown=$((wshown + 1))
                fi
            done
            # Only meaningful once at least one name is on screen. Without this guard, a run where
            # no name resolved printed "+1" **and** the count fallback below — the same session
            # counted twice on one line (measured).
            [ "$wshown" -gt 0 ] && [ "$w" -gt "$wshown" ] \
                && out="$out#[fg=colour215,bg=colour235,bold] +$((w - wshown)) #[default] "
        fi
        # If we couldn't get a single name (no server, or the query failed), fall back to showing just the count as before.
        [ "$wshown" = 0 ] && out="$out#[fg=colour215,bg=colour235,bold] ⏸ $w #[default] "
    fi
    [ "$k" -gt 0 ] && out="$out#[fg=yellow,bg=colour235,bold] ✻$k #[default] "
    printf '%s' "$out"
    return 0
}

# Agent hook receiver: called by claude/codex hooks on every event — a more accurate state
#   source than scraping the screen.
#   claude: working(UserPromptSubmit/PostToolUse) / idle(Stop) / waiting(Notification) / clear(SessionEnd)
#   codex : working(UserPromptSubmit/PreToolUse) / idle(Stop) / waiting-codex(PermissionRequest)
# The hook runs inside the agent process's environment, so it knows its own session via
#   $TMUX_PANE (solves the session-mapping problem).
if [ "${1:-}" = "--hook" ]; then
    st="${2:-}"
    [ -n "${TMUX_PANE:-}" ] || exit 0
    # Ask for session info in one shot. The manifest record also needs name/cwd/command, but
    # calling display-message multiple times per event adds that much hook latency — keep the
    # call count the same as before (once), and absorb what the idle/boot branches below used
    # to ask again (#S / session_attached) into this one call too.
    sid=""; sname=""; spath=""; scmd=""; satt=1
    IFS=$'\t' read -r sid sname spath scmd satt < <(tmux display-message -p -t "$TMUX_PANE" \
        $'#{session_id}\t#{session_name}\t#{pane_current_path}\t#{pane_current_command}\t#{session_attached}' 2>/dev/null) || true
    # There is a race where rc=0 but the output is empty (the pane is disappearing right now).
    # If left alone, a "hook-" file with an empty name gets created, and clear only removes
    # that one, leaving the real state file orphaned (measured in practice: hook-21, hook-33).
    [ -n "$sid" ] || exit 0
    # The stdin payload arrives with every event (claude: session_id=conversation id, cwd,
    # hook_event_name). Read it only once — the waiting verdict and the manifest record can't
    # both read the same stream twice.
    # If stdin is a tty (a human typed fmux --hook by hand), don't read it — that would make it
    # wait a full 2 seconds.
    payload=""
    [ -t 0 ] || IFS= read -r -d '' -t 2 payload || true
    mkdir -p "$STATE"
    hf="$STATE/hook-${sid#\$}"
    echo "$(date '+%F %T') $sid $st" >> "$STATE/hook.log"   # event audit log (for tracing false positives)
    # Walk up the parent chain to find the agent's real PID ($PPID may be a throwaway shell)
    #   — used for detecting dead sessions.
    #   Why tt_comm: macOS ps gives an absolute path in comm — a raw comparison would never
    #   match on Mac.
    cpid=$PPID
    while [ "$cpid" -gt 1 ]; do
        case "$(tt_comm "$cpid" || true)" in claude|codex) break ;; esac
        cpid=$(ps -p "$cpid" -o ppid= 2>/dev/null | tr -d ' ') || { cpid=0; break; }
        [ -n "$cpid" ] || { cpid=0; break; }
    done
    case "$(tt_comm "${cpid:-0}" || true)" in claude|codex) ;; *) cpid=0 ;; esac
    case "$st" in
        waiting)
            # Notification payloads fall broadly into two branches:
            #   (1) requires user action — "Claude needs your permission to use Bash", waiting
            #       for plan approval / a question
            #   (2) a plain idle notice — "Claude is waiting for your input" (fires when the
            #       input box has been empty for 60 seconds)
            # Previously only the 'permission' phrase was recognized as ⏸, which missed plan
            # approval and AskUserQuestion waits entirely. So we inverted the whitelist to
            # filter out only (2): it doesn't break when the wording changes, and any new kind
            # of notification is caught as ⏸ by default. Here, a false negative is more
            # expensive than a false positive — a false positive self-corrects immediately on
            # the next working/idle hook, but a false negative means an absent wait is never
            # seen at all.
            # If the payload can't be read (empty stdin), there's no basis for a verdict, so
            # ignore it — the same conservative behavior as before.
            # (payload is read once, above — the manifest record uses the same read.)
            # Lowercasing is done with tr — ${payload,,} is bash-4.0-only syntax, and macOS's
            # stock /bin/bash is 3.2. It parses fine and dies **only at expansion time**, so the
            # symptom is a silent one: "install works, the list shows up, but ⏸ just never
            # appears" (team deploy gate B6).
            # tt_conf_envname in 05-config.sh avoids ${var^^} for the same reason — it's this
            # repo's convention.
            # t-14 catches bash4-only syntax across all of src/*.sh (regression guard).
            case "$(printf '%s' "$payload" | tr '[:upper:]' '[:lower:]')" in
                "") ;;                                                 # no basis -> ignore
                *"waiting for your input"*|*"waiting for input"*) ;;    # plain idle -> not ⏸
                *) echo "waiting $(date +%s) $cpid" > "$hf" ;;
            esac ;;
        waiting-codex)
            # codex PermissionRequest — the event itself means waiting for approval, no need to inspect stdin
            echo "waiting $(date +%s) $cpid" > "$hf" ;;
        working)
            now=$(date +%s)
            echo "$st $now $cpid" > "$hf"
            # Save the last prompt — working is a single branch **shared** by
            #   UserPromptSubmit, PostToolUse, PreCompact, PostCompact (and for codex, also
            #   PreToolUse). So looking at $st alone here can't tell us whether this was a
            #   prompt submission -> gating is done inside the function via the payload's
            #   hook_event_name. If it's not a prompt submission, it returns immediately with
            #   zero forks. Fails silently if it fails — the state file has already been
            #   written above (this is a side-effect-only addition).
            tt_last_prompt_save "$sid" "$payload" "$now" ;;
        idle)
            prev=$(cut -d' ' -f1 "$hf" 2>/dev/null || true)
            echo "idle $(date +%s) $cpid" > "$hf"
            if [ "$prev" = working ] || [ "$prev" = waiting ]; then
                name="$sname"                      # already asked above (fork savings)
                [ -n "$name" ] || exit 0
                att="${satt:-1}"
                if [ "$att" = 0 ]; then
                    # Locking is mandatory: the status bar rewrites this same file wholesale
                    # every 5 seconds — without a lock, this notification would be lost.
                    tt_finished_lock
                    tt_finished_rewrite "$name"   # normalize + drop old entries for the same session (sed replacement)
                    echo "$(date +%s) $name" >> "$STATE/finished"   # status bar badge + list unread marker
                    tt_finished_unlock
                    tmux list-clients -F '#{client_name}' 2>/dev/null | while read -r c; do
                        tmux display-message -c "$c" -d 8000 "✓ $name done"
                    done
                fi
            fi ;;
        clear)
            # The CPU snapshot's lifetime is entirely tied to the hook file's lifetime — if we
            # split the cleanup rule into two separate sets, we get the contradiction of
            # "deleted it, but still trust it" (same reasoning as the existing judgment in the
            # tt_sweep_hooks comment).
            #   The last prompt is removed here too, in the same place — the session is over,
            #   and "what did I ask it to do" shouldn't linger and show up in the next
            #   session's preview (same judgment as sweep).
            rm -f "$hf" "$STATE/cpu-${sid#\$}" "$STATE/last-${sid#\$}" ;;
        boot)
            # Agent boot self-report — immediately classifies this as an agent session +
            #   runs any pending /rename
            #   claude: SessionStart hook   codex: the wrapper fires this directly right before exec
            # Sweep orphans/ghosts first — prevents accidents from session-id reissue after a
            # reboot. --restore uses the same function.
            #   Order matters: if we sweep after creating our own file, we'd never delete the
            #   one we just made; but if we skip sweeping as "already exists" when there's an
            #   inherited ghost file, we'd inherit someone else's state as-is.
            #   Sweep first, then create if missing = either way, a file with this session's
            #   pid is left behind.
            tt_sweep_hooks
            [ -f "$hf" ] || echo "idle $(date +%s) $cpid" > "$hf"
            # The rotation threshold (log_max) is read from config, so load the cache first —
            # as a bare statement, not inside a subshell (the contract in 05-config.sh). This
            # is the only place in the hook path that reads config, so it's placed right before
            # the rotation call rather than at the very top of the entry point: the
            # working/idle path, which runs on every event, reads zero bytes of config.
            tt_conf_load
            tt_log_rotate   # so the audit log doesn't grow unbounded on environments without cron installed
            name="$sname"                          # already asked above (fork savings)
            [ -n "$name" ] || exit 0
            pr="$STATE/pending-rename-$name"
            if [ -f "$pr" ]; then
                # TTL of 5 minutes. There was an incident where a reservation that failed to
                # boot and was never consumed came back to life weeks later against a
                # same-named session and injected /rename (codex doesn't even have that slash
                # command).
                read -r pts _ < "$pr" 2>/dev/null || pts=0
                case "$pts" in ''|*[!0-9]*) pts=0 ;; esac
                rm -f "$pr"
                if [ $(( $(date +%s) - pts )) -le 300 ]; then
                    ( sleep 1
                      tmux send-keys -t "$TMUX_PANE" -l "/rename $name"
                      sleep 0.5
                      tmux send-keys -t "$TMUX_PANE" Enter ) >/dev/null 2>&1 &
                fi
            fi ;;
    esac
    # ── Fleet manifest auto-recording ──────────────────────────────────────
    # The hook is the only point that knows both "which tmux session" (TMUX_PANE) and "which
    # conversation" (stdin's session_id) at the same time — the conversation id falls into our
    # lap for free. If we pick it up here, the restore table stays current even if the user
    # never runs --snapshot even once (zero user intervention required).
    # Cost: zero forks (a global-return tt_jv + string ops) + no file touch if the content is
    # unchanged. Fails silently on failure.
    # The conversation home (6th field) is also only accurate here: stdin's cwd is claude's own
    # cwd, and claude uses exactly that value to compute
    # ~/.claude/projects/<encoded cwd>/ when locating the conversation.
    # That's separate from the session's cwd (pane_current_path) — conflating the two into one
    # field was the cause of restore failures.
    if [ -n "$sname" ]; then
        mconv=""; mhome=""
        if [ -n "$payload" ]; then
            tt_jv "$payload" session_id && mconv="$TT_JV" || true   # conversation id from the claude hook
            # Conversation home: don't just trust cwd as-is. The hook **also fires for
            # subagents**, and that payload's cwd is the directory the subagent was working in.
            # If we record that as the home, restore would run
            #   ( cd '<wrong place>' && claude --resume <id> )
            # and claude would fail to find the conversation in the folder encoded from that
            # cwd.
            # (Measured 2026-08-06: three entries — tui-worker, membership, ops — broke this way
            # and restore died.)
            #
            # transcript_path knows the truth — ~/.claude/projects/<encoded home name>/<id>.jsonl.
            # So we encode cwd and adopt it as the home **only if** it matches that folder name.
            # If it doesn't match, pass an empty value to preserve the existing record (we don't
            # decode — if a directory name contains '-', the encoding can't be reversed:
            # _myproject -> -home-...-_myproject).
            mhome=""
            if tt_jv "$payload" cwd; then
                _hcwd="$TT_JV"
                if tt_jv "$payload" transcript_path; then
                    _hdir=${TT_JV%/*}; _hdir=${_hdir##*/}          # encoded folder name
                    case "$(printf '%s' "$_hcwd" | tr '/' '-')" in
                        "$_hdir") mhome="$_hcwd" ;;                 # match -> this cwd is the real home
                    esac
                fi
            fi
        fi
        # The pane command may not be claude while a tool is running (when a child comes to
        # the tty foreground) -> only record it when certain, otherwise pass an empty value to
        # preserve the existing record.
        case "$scmd" in claude|codex) mcmd="$scmd" ;; *) mcmd="" ;; esac
        tt_mf_upsert "$sname" "$spath" agent "$mcmd" "$mconv" "$mhome" || true
    fi
    exit 0
fi

# Status bar: fleet aggregate (⏸n ✻n) + finished-session ✓name badge
#   The badge disappears once you've visited that session, or after unseen_minutes
#   (10 minutes by default) has passed.
#   Called every 5 seconds by #(fmux --status) in .tmux.conf's status-right.
if [ "${1:-}" = "--status" ]; then
    f="$STATE/finished"
    now=$(date +%s)
    # Load config once at the top of the entry point, as a bare statement, not a subshell
    # (the contract in 05-config.sh). This path is called by the status bar every 5 seconds —
    # a single broken line must not spew warnings once per call.
    tt_conf_load
    unseen_s=$(( $(tt_conf_num unseen_minutes) * 60 ))
    agg=$(tt_fleet_agg)     # unrelated to finished, so compute it first, outside the lock
    out=""
    if [ -s "$f" ]; then
        tt_finished_lock
        tt_finished_rewrite     # migrate old format + strip poison lines
        keep=""
        while read -r ts name; do
            case "$ts" in ''|*[!0-9]*) continue ;; esac   # discard non-numeric lines (prevents permanent lingering)
            [ -n "$name" ] || continue
            # "=" means exact match. A prefix match would let a zzh record clear zzh2's badge.
            #   Why we ask for both fields together: tmux returns rc 0 with empty output even
            #   for a target it can't find (measured) — the liveness verdict must be based on
            #   whether session_id is present, or dead-session entries would sit in the file
            #   forever.
            #   last_attached is empty for a session that was never attached, so we fold that
            #   to 0 (present != attached).
            info=$(tmux display-message -p -t "=$name:" '#{session_id}|#{?session_last_attached,#{session_last_attached},0}' 2>/dev/null) || continue
            [ -n "${info%%|*}" ] || continue        # session_id is empty = session is gone -> discard the entry
            la=${info#*|}
            [ "${la:-0}" -gt "$ts" ] && continue    # already visited = acknowledged -> remove
            keep="$keep$ts $name
"
            [ $(( now - ts )) -le "$unseen_s" ] && out="$out ✓$name"   # status bar shows it only for unseen_minutes; the file keeps it until viewed
        done < "$f"
        printf '%s' "$keep" > "$f"
        tt_finished_unlock
    fi
    badge=""
    [ -n "$out" ] && badge="#[fg=#7fae6e,bg=colour235,bold]$out #[default] "
    printf '%s%s' "$agg" "$badge"
    exit 0
fi

