# ── Fleet snapshot / restore ────────────────────────────────────────────────
# Session → claude conversation id. Source is sessionId from the same ~/.claude/sessions/<pid>.json
#   that the rc-judgment code uses (the same value that arrives as session_id via hook stdin).
#   If not found, rc 1 — we never guess.
#   Reuses rc_target/rc_read/rc_val as-is: PID-reuse and half-written-file defenses are already
#   all built in.
#   Also returns the conversation home (the claude process's cwd) at the same time — this avoids
#   calling rc_target twice, and the two are a pair that come out of the very same process anyway.
#   Output = "<conv>\t<home>" (missing side is '-').
#   The process cwd's correct answer is the /proc/<pid>/cwd symlink (Linux). macOS has no /proc,
#   so home becomes '-' — in that case the hook's old value, already filled in from the stdin
#   JSON's cwd, is preserved (upsert rule ②).
tt_conv_of() {
    local t pid j v home=""
    t=$(rc_target "$1") || return 1
    pid=${t##* }
    j=$(rc_read "$SESSD/$pid.json") || return 1
    v=$(rc_val "$j" sessionId)
    [ -n "$v" ] || return 1
    home=$(readlink "/proc/$pid/cwd" 2>/dev/null) || home=""
    [ -n "$home" ] && [ -d "$home" ] || home="-"
    printf '%s\t%s' "$v" "$home"
}

# Writes all currently-live sessions into the manifest fresh (full replace).
#   Leaves one backup before replacing (manifest.bak) — so even snapshotting an empty fleet by
#   mistake can be reverted.
#   If there isn't a single live session, it writes nothing at all: if you habitually run
#   --snapshot right after a reboot, the restore table would evaporate right then (at the moment
#   it's needed most).
if [ "${1:-}" = "--snapshot" ]; then
    tt_conf_load                               # bare statement, not a subshell (05-config.sh:53 contract)
    # The instant we enter the while loop below, process substitution forks tmux, and inside the
    # loop display-message gets called again per session — we must bail before that to block
    # 'everything'. No lock is held yet.
    tt_conf_on snapshot || { printf 'snapshot=off — not recording (fmux config set snapshot on)\n'; exit 0; }
    mkdir -p "$STATE"
    rows=""; n=0
    while IFS=$'\t' read -r sid name; do
        [ -n "$name" ] || continue
        # The zz prefix is our test-session convention — never entered into the real fleet manifest.
        #   But if TT_MANIFEST has redirected the manifest elsewhere (a test path), that rule would
        #   block the test itself, so it doesn't apply there. What we're protecting was only ever
        #   the real manifest to begin with.
        if [ -z "${TT_MANIFEST:-}" ]; then
            case "$name" in zz*) printf '  skip %s — test session\n' "$name"; continue ;; esac
        fi
        info=$(tmux display-message -p -t "=$name:" $'#{pane_current_path}\t#{pane_current_command}' 2>/dev/null) || info=""
        cwd=${info%%$'\t'*}; pcmd=${info#*$'\t'}
        [ -n "$cwd" ] && [ -d "$cwd" ] || cwd="$HOME"
        old=$(tt_mf_row "$name")
        oldcmd=""; oldconv=""; oldhome=""; oldkind=""
        if [ -n "$old" ]; then
            # Field order: name·cwd·kind·cmd·conv[·chome] — reaching cmd means stripping 3 tabs.
            # In the days when we stripped only 2, oldcmd=kind and oldconv=cmd shifted by one slot,
            # and each snapshot let a string like "claude" settle into the conversation-id spot —
            # a progressive corruption (2026-07-25 incident).
            o=${old#*$'\t'}; o=${o#*$'\t'}; oldkind=${o%%$'\t'*}
            o=${o#*$'\t'};   oldcmd=${o%%$'\t'*}
            o=${o#*$'\t'};   oldconv=${o%%$'\t'*}
            # The 6th field may not exist (old 5-field lines) — read it only if present
            case "$o" in *$'\t'*) o=${o#*$'\t'}; oldhome=${o%%$'\t'*} ;; esac
        fi
        chome=""
        if tt_is_agent "$sid"; then
            kind=agent
            # For the start command, look at whatever claude|codex is actually running in the pane
            # (scans across windows even if there are several). If not found (the agent died and
            # only the hook file is left) → fall back to the old record → still nothing → claude:
            # this fleet's default, and if it's really codex the next hook will soon write its own name.
            cmd=$(tmux list-panes -s -t "$sid" -F '#{pane_current_command}' 2>/dev/null | grep -m1 -xE 'claude|codex' || true)
            [ -n "$cmd" ] || cmd="$oldcmd"
            case "$cmd" in ''|-) cmd=claude ;; esac
            ci=$(tt_conv_of "$sid" || true)
            conv=${ci%%$'\t'*}
            case "$ci" in *$'\t'*) chome=${ci##*$'\t'} ;; esac
            # Not being able to figure it out right now doesn't mean we throw away the old value —
            # throwing it away means restore falls back to the picker, or resumes in the wrong cwd
            # and hits "No conversation found"
            [ -n "$conv" ] || conv="$oldconv"
            [ -n "$conv" ] || conv="-"
            case "$chome" in ''|-) chome="$oldhome" ;; esac
        else
            kind=tool
            # For a tool session, pane_current_command is an approximation of the "start command"
            # (accurate for yazi/lazydocker). If it's a bare shell, record no command — restore
            # will just launch a shell.
            case "$pcmd" in ''|bash|-bash|zsh|-zsh|sh|fish|tmux) cmd="-" ;; *) cmd="$pcmd" ;; esac
            # Being classified as a tool doesn't mean we drop the conversation id — if tt_is_agent
            # is false even once (e.g. the moment the hook file gets cleared), the conversation would
            # be lost for good. If kind is tool, restore doesn't use conv anyway, so keeping it
            # around is the safe choice.
            conv="$oldconv"
            [ -n "$conv" ] || conv="-"
            chome="$oldhome"
            # ★ Don't demote a dead agent to a tool — secondary damage from the 2026-07-26 incident.
            #   When an agent dies, only a bare shell is left in the pane → tt_is_agent is false →
            #   recorded as kind=tool → restore branches on kind, so it ignores conv and just
            #   launches a bare shell. In other words, exactly when "restore is needed most," the
            #   manifest erases its own ability to restore. --snapshot runs every minute via cron,
            #   so even the three backup generations get overwritten by the demoted copy within
            #   3 minutes (measured in practice).
            #   Verdict: if the old record was agent + the conversation id is alive + the pane is a
            #   bare shell (no replacement tool came up) → treat it as a dead agent. If a human
            #   launched yazi in that session, cmd wouldn't be a bare shell, so it's filtered out by
            #   the case above and correctly falls through to tool.
            if [ "$oldkind" = agent ] && [ "$cmd" = "-" ] && tt_is_uuid "$conv"; then
                kind=agent
                cmd="$oldcmd"; case "$cmd" in ''|-) cmd=claude ;; esac
            fi
        fi
        # Only a uuid-shaped string is accepted as the conversation id — letting a string like
        # "claude" pass through is what let the incident grow
        tt_is_uuid "$conv" || conv="-"
        # Only record the conversation home when it's a directory that actually exists (recording
        # a vanished path makes restore try to cd there and fail)
        [ -n "$chome" ] && [ -d "$chome" ] || chome="-"
        [ "$conv" = - ] && chome="-"      # if there's no conversation, home is meaningless too
        # A path containing a tab breaks the format — fold just that line into 'none' (better
        # than losing the whole file)
        case "$name$cwd$cmd$chome" in *$'\t'*) printf '  skip %s — tab in path/command\n' "$name"; continue ;; esac
        rows="$rows$name"$'\t'"$cwd"$'\t'"$kind"$'\t'"$cmd"$'\t'"$conv"$'\t'"$chome"$'\n'
        n=$((n + 1))
        printf '  %-16s %-5s %-12s %-38s %s\n' "$name" "$kind" "$cmd" "$conv" "$chome"
    done < <(tmux ls -F $'#{session_id}\t#{session_name}' 2>/dev/null || true)
    if [ "$n" = 0 ]; then
        echo "no live sessions — manifest left untouched (nothing to record)"
        exit 1
    fi
    # Integrity check before writing — any broken line not caught here becomes the "old value" of
    #   the next snapshot and spreads. On rejection, we don't touch the existing file at all: a
    #   stale manifest is always better than a corrupt one.
    if ! tt_mf_check "$rows"; then
        printf 'snapshot ABORTED — generated rows failed the integrity check; %s left untouched\n' "$MANIFEST" >&2
        exit 1
    fi
    tt_mf_lock || { echo "manifest busy — try again"; exit 1; }
    # A vanished session's line disappears only here (hooks/listings are never deleted — the
    #   whole point is reviving the dead)
    if [ -f "$MANIFEST" ]; then
        # Rotates three backup generations. --snapshot runs every minute via cron, so with only one
        # generation the window to notice and revert a bad snapshot is 60 seconds — the next tick
        # overwrites the only backup too. Three generations = at least 3 minutes.
        tt_mf_backup
        while IFS=$'\t' read -r on _rest || [ -n "$on" ]; do
            [ -n "$on" ] || continue
            case $'\n'"$rows" in *$'\n'"$on"$'\t'*) ;; *) printf '  dropped %s — no longer running\n' "$on" ;; esac
        done < "$MANIFEST.bak"
    fi
    tt_mf_write "$rows" || { tt_mf_unlock; exit 1; }
    tt_mf_unlock
    printf 'snapshot: %d sessions → %s\n' "$n" "$MANIFEST"
    exit 0
fi

# Removes one session from the manifest — dying doesn't auto-delete an entry, so use this when
#   truly retiring a session
if [ "${1:-}" = "--forget" ]; then
    n="${2:-}"
    [ -n "$n" ] || { echo "usage: fmux --forget <session name>"; exit 1; }
    tt_mf_forget "$n" || { echo "manifest busy — try again"; exit 1; }
    if [ "${TT_MF_HITS:-0}" -gt 0 ]; then
        printf 'forgot %s\n' "$n"
    else
        printf 'no manifest entry named %s\n' "$n"
        exit 1
    fi
    exit 0
fi

# Revives the fleet according to the manifest. Safe to run more than once (live sessions are
#   skipped).
#   claude must always use --resume <conversation-id>. --continue picks "the most recent
#   conversation in that folder," so if several sessions share the same cwd, they all end up
#   attached to the same conversation — a doppelganger incident (we actually hit this: a session
#   showed up that echoed back my own greeting verbatim). If there's no id, --resume with no
#   argument = a human picks.
if [ "${1:-}" = "--restore" ]; then
    dry=0; [ "${2:-}" = "--dry" ] && dry=1
    if [ ! -s "$MANIFEST" ]; then
        echo "no manifest at $MANIFEST — run 'fmux --snapshot' while the fleet is up"
        exit 1
    fi
    # After a reboot, tmux reissues session ids starting from $0 → a new session inherits a dead
    # session's hook-* files, and a tool session gets misclassified as an agent (measured in
    # practice). Must be swept before creating sessions.
    if [ "$dry" = 1 ]; then
        echo "[dry] would sweep orphan hook files"
    else
        tt_sweep_hooks
    fi
    made=0; skipped=0; used=""; livec=""; verify=""
    TT_SH=$(tt_login_shell)
    # First gather the list of conversations that currently-live claude processes are holding.
    #   Judging "dead" by name alone isn't enough — if a session gets renamed (a human uses ^E, or
    #   claude renames itself), the manifest's old name looks like a dead session, and a perfectly
    #   live conversation gets opened a second time. We actually caused that incident during
    #   development: restore reopened the conversation of a renamed session, and two claudes ended
    #   up attached to the same conversation (a doppelganger). The real key isn't the name, it's the
    #   conversation id.
    #   The judgment source is the same ~/.claude/sessions/<pid>.json that rc uses — only pids that
    #   are actually alive are accepted.
    for sf in "$SESSD"/*.json; do
        [ -f "$sf" ] || continue
        spid=${sf##*/}; spid=${spid%.json}
        case "$spid" in ''|*[!0-9]*) continue ;; esac
        [ "$(tt_comm "$spid" || true)" = claude ] || continue
        sj=$(rc_read "$sf") || continue
        sv=$(rc_val "$sj" sessionId)
        [ -n "$sv" ] && livec="$livec $sv"
    done
    # Old 5-field lines missing the 6th field (conversation home) are still read fine — read
    #   leaves the leftover variable empty
    while IFS=$'\t' read -r name cwd kind cmd conv chome || [ -n "$name" ]; do
        [ -n "$name" ] || continue
        case "$name" in \#*) continue ;; esac
        tt_is_uuid "${conv:-}" || conv="-"      # so a corrupted line can't leak into a command line
        case "${chome:-}" in ''|-) chome="" ;; esac
        # Even a live session records its own conversation as "claimed" and gets skipped —
        # there's a real case of an already-running tt-worker and the manifest's worker2 both
        # pointing at the same conversation id. Without counting the claim, restoring the dead one
        # would ride in on the live session's conversation, producing a doppelganger.
        if tmux has-session -t "=$name" 2>/dev/null; then
            [ "$conv" = - ] || used="$used $conv"
            printf 'skip   %-16s already running\n' "$name"
            skipped=$((skipped + 1))
            continue
        fi
        # ① That conversation is already held by a live claude = a session that's running fine,
        #    just under a different name now. Reviving it would split the conversation in two →
        #    skip it entirely (the right answer is that there's no session to create).
        if [ "$conv" != - ]; then
            case " $livec " in
                *" $conv "*)
                    printf 'skip   %-16s conversation %s is already open in a live claude\n' "$name" "$conv"
                    skipped=$((skipped + 1))
                    continue ;;
            esac
        fi
        if [ ! -d "$cwd" ]; then
            printf '  note  %s: cwd %s is gone → using %s\n' "$name" "$cwd" "$HOME"
            cwd="$HOME"
        fi
        # ② The case where the same conversation id appears on two lines within the manifest (this
        #    actually happened with a hand-edited manifest). Both are dead, so we still revive the
        #    session itself, but drop the second one to the picker and let a human choose — asking
        #    once is cheaper than attaching it wrong.
        case " $used " in
            *" $conv "*) [ "$conv" = - ] || { printf '  warn  %s: conversation %s already claimed by another entry → picker instead\n' "$name" "$conv"; conv="-"; } ;;
        esac
        [ "$conv" = - ] || used="$used $conv"
        run=""
        case "$kind" in
            agent)
                a="$cmd"; case "$a" in ''|-) a=claude ;; esac
                case "$a" in
                    claude*)
                        # Check that the conversation file actually exists before pointing to it.
                        # --resume with a nonexistent id just prints "No conversation found with
                        # session ID" and drops to a shell (measured: a conversation that never
                        # exchanged a single message never even gets a transcript). In that case,
                        # --resume with no argument = hand off to the picker and let a human choose.
                        # Conversation ids are globally unique, so there's no need to guess the
                        # project folder name (hence the glob).
                        if [ "$conv" = - ]; then
                            run="claude --resume"
                        elif compgen -G "$HOME/.claude/projects/*/$conv.jsonl" >/dev/null 2>&1; then
                            run="claude --resume $conv"
                        else
                            printf '  note  %s: no transcript for %s → picker instead\n' "$name" "$conv"
                            run="claude --resume"
                        fi
                        # Resume in the conversation home — even though the glob can see the
                        # transcript, claude only looks for that conversation in the "project folder
                        # matching the current cwd." If the session cwd differs, even the id we just
                        # found produces "No conversation found" (measured with refact-worker).
                        # Why wrap it in a subshell: leave the session's own cwd exactly as recorded
                        # in the manifest, and run only the resume in the home — quitting claude
                        # returns to a shell in the original folder.
                        if [ -n "$chome" ] && [ "$chome" != "$cwd" ]; then
                            if [ -d "$chome" ]; then
                                run="( cd '${chome//\'/\'\\\'\'}' && $run )"
                            else
                                printf '  note  %s: conversation home %s is gone → resuming in %s\n' "$name" "$chome" "$cwd"
                            fi
                        fi ;;
                    codex*)  run="codex" ;;   # codex's conversation-resume method is unconfirmed → just launch plainly
                    *)       run="$a" ;;
                esac ;;
            *) case "${cmd:-}" in ''|-) run="" ;; *) run="$cmd" ;; esac ;;
        esac
        if [ "$dry" = 1 ]; then
            printf 'plan   %-16s %-5s %s  @ %s\n' "$name" "$kind" "${run:-<plain shell>}" "$cwd"
            continue
        fi
        # Explicitly specify the shell — even if the server-wide default-shell got stuck at
        # /bin/sh from cron, our session still comes up as a login bash (server option untouched).
        # Primary cause of the 2026-07-26 incident.
        if ! tmux new-session -d -s "$name" -c "$cwd" "$TT_SH" -l 2>/dev/null; then
            printf 'FAIL   %-16s could not create session\n' "$name"
            continue
        fi
        if [ -n "$run" ]; then
            tmux send-keys -t "=$name:" -l "$run"
            tmux send-keys -t "=$name:" Enter
        fi
        printf 'made   %-16s %-5s %s\n' "$name" "$kind" "${run:-<plain shell>}"
        # Queue up verification targets — agents only. Tools carry no conversation-loss risk
        #   whether they come up or not.
        case "$kind" in agent) verify="$verify$name"$'\t'"$run"$'\n' ;; esac
        made=$((made + 1))
        sleep 0.4    # sequential launch — starting ten claudes at once brings the Pi to its knees
    done < "$MANIFEST"
    # ④ Restore verification. Having sent send-keys only means "we sent the characters" — it does
    #   not mean the agent came up. In the 2026-07-26 incident, restore built the exact right
    #   command and typed it exactly right, and the log even recorded it as a success: `made ...
    #   agent claude --resume <id>`. In reality the pane's shell couldn't find claude, five sessions
    #   were left as bare shells, and nobody noticed for 40 minutes. Moving the success criterion
    #   from "typed it" to "it came up" catches this regardless of cause (PATH, shell, a rotted
    #   conversation id, a moved binary). The ①-③ checks above only guard against this one cause.
    if [ "$dry" != 1 ] && [ -n "$verify" ]; then
        sleep 12          # claude takes a few seconds to launch on the Pi — check too soon and even a healthy one reads as a failure
        vbad=""
        while IFS=$'\t' read -r vn vrun || [ -n "$vn" ]; do
            [ -n "$vn" ] || continue
            tt_pane_has_agent "$vn" && continue
            printf '  warn  %-16s agent did not come up — retrying once\n' "$vn"
            tmux send-keys -t "=$vn:" -l "$vrun" 2>/dev/null
            tmux send-keys -t "=$vn:" Enter 2>/dev/null
            vbad="$vbad $vn"
        done <<< "$verify"
        if [ -n "$vbad" ]; then
            sleep 12
            vfail=""
            for vn in $vbad; do
                tt_pane_has_agent "$vn" || vfail="$vfail $vn"
            done
            if [ -n "$vfail" ]; then
                printf 'RESTORE INCOMPLETE — agents still down after retry:%s\n' "$vfail"
                # Leave a trace for a human to see. If it's only in the log, it slips by unnoticed
                #   just like today.
                printf '%s\n' "$(date '+%Y-%m-%d %H:%M:%S')${vfail}" > "$STATE/restore-failed" 2>/dev/null || true
            else
                printf 'verify — all agents up after retry\n'
                rm -f "$STATE/restore-failed" 2>/dev/null || true
            fi
        else
            printf 'verify — all %d agent(s) came up\n' "$(printf '%s' "$verify" | grep -c .)"
            rm -f "$STATE/restore-failed" 2>/dev/null || true
        fi
    fi
    if [ "$dry" = 1 ]; then
        printf 'dry run — %d already running, nothing created\n' "$skipped"
    else
        printf 'restored %d, skipped %d already running\n' "$made" "$skipped"
    fi
    exit 0
fi

# ── Boot-time auto-restore (@reboot cron-only entry point) ───────────────────
# A shell that wraps --restore. Not a single line of restore logic is rewritten (doppelganger
# defense, transcript verification, conversation-home cd, the 0.4s sequential launch — all of it
# already lives inside --restore). The one question this branch answers is exactly one thing —
# "is now a situation where it's OK to restore."
#
# Why not just hang --restore straight off @reboot. Measured from this Pi's past boot journal
# (2026-07-25):
#   12:41:32  kernel boots
#   12:41:35  cron fires the @reboot job        ← at this instant the tailscaled log says
#             "network is unreachable"
#   12:41:39  eth0 carrier + DHCP lease (192.168.0.37)
#   12:41:44  tailscaled secures a DERP home = the first moment name resolution becomes possible
# @reboot is 9-12 seconds faster than the network. Launch ten claudes in that gap and every one
# of them ends up an empty shell.
#
# Placement: right after the --restore branch. All the branches before it are exact
# `[ "$1" = "--xxx" ]` matches, so "--boot-restore" doesn't get swallowed by "--restore" first
# (it isn't prefix matching).
if [ "${1:-}" = "--boot-restore" ]; then
    dry=0; [ "${2:-}" = "--dry" ] && dry=1
    mkdir -p "$STATE"
    BOOTLOG="$STATE/boot.log"
    # This feature runs exactly once, at a time no human is watching, and fails quietly → the log
    # is the only evidence. So every single judgment gets recorded. Rotation reuses the same policy
    # as hook.log.
    blog() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$BOOTLOG"; }
    # Config cache goes at the very top of the entry point, as a bare statement, not a subshell
    #   (05-config.sh's contract).
    #   Rotation (log_max) reads config before the boot_restore switch below, so the load must come
    #   before that too — if it's first read inside a $(...) during rotation, the cache dies along
    #   with that subshell, and one broken line ends up printing the warning twice per boot.
    tt_conf_load
    TT_LOG_FILE="$BOOTLOG" tt_log_rotate
    blog "=== boot-restore start (dry=$dry, pid $$)"

    # ⓪ Config switch. Means the same thing as the ① kill switch, just a different handle (a
    #    single file vs `fmux config`). The placement must match too — exiting here means we don't
    #    touch the PATH fixup, flock, the network wait (up to 120s), or tmux start-server (the spot
    #    where this entry point first calls tmux) below at all.
    #    (The config cache was already set up before the log rotation above — because rotation
    #    reads log_max.)
    if ! tt_conf_on boot_restore; then
        blog "boot_restore=off in config — nothing done"
        printf 'boot_restore=off — skipping boot restore (fmux config set boot_restore on)\n'
        exit 0
    fi

    # ① Kill switch. There are situations where you want "reboot, but don't bring the fleet up"
    #    (observing after a kernel swap or disk cleanup, manually reorganizing the fleet). A human
    #    needs to be able to turn this off with a single file, and deleting it revives it starting
    #    from the next boot. Being switched off isn't a failure, so it exits with a success code.
    if [ -f "$STATE/no-autorestore" ]; then
        blog "kill switch present ($STATE/no-autorestore) — nothing done"
        exit 0
    fi

    # ② PATH fixup. cron's PATH is effectively just /usr/bin:/bin.
    #    Verified directly on this Pi with `env -i PATH=/usr/bin:/bin`:
    #      tmux flock getent jq pgrep awk date → live in /usr/bin. These survive on cron's PATH.
    #      claude codex fzf → missing (claude=~/.npm-global/bin, the hook-injection
    #      wrapper=~/.local/libexec/tt, fzf=~/.local/bin).
    #    The `claude --resume` that restore types into the pane itself actually survives anyway,
    #    because the pane's login shell re-reads .profile→.bashrc and restores PATH (measured on an
    #    isolated socket: PATH was normal inside the pane even for a server launched with a
    #    threadbare PATH). Even so, the reason we fix it here is the tmux **server** — if we launch
    #    the server from a cron environment, that threadbare PATH sets hard as the server's global
    #    environment and stays until the next reboot (measured: show-environment -g PATH =
    #    /usr/bin:/bin). After that, everything tmux runs non-login (run-shell, hooks, --preview)
    #    quietly breaks.
    #    Order matters: since we prepend, the list below is in *reverse* priority order. libexec/tt
    #    must end up first — if it lands behind the others, a bare claude that skips the
    #    hook-injection wrapper comes up, and the fleet status board (hook-*) dies entirely.
    for d in "$HOME/.npm-global/bin" "$HOME/.local/bin" "$HOME/.local/libexec/tt"; do
        [ -d "$d" ] || continue
        case ":$PATH:" in *":$d:"*) ;; *) PATH="$d:$PATH" ;; esac
    done
    export PATH

    # ②-2 SHELL fixup. $SHELL has the exact same trap as PATH — and this one hurt more.
    #   cron's $SHELL is /bin/sh. When we spawn the tmux **server** below at ⑥, that value sets hard
    #   as the server's global default-shell (unchanging until the server dies), and every pane
    #   created after that becomes dash. dash doesn't read .bashrc, so the user's PATH is wiped out
    #   entirely, and every `claude --resume` restore typed falls through to `claude: not found`.
    #   Measured 2026-07-26: on the first real run of auto-recovery, 5 agents came up as bare shells
    #   and the status board stayed green for 40 minutes. Why the PATH loop above can't stop this —
    #   it fixes our own process's PATH, but the pane's login shell re-reads /etc/profile and
    #   overwrites PATH wholesale anyway.
    SHELL=$(tt_login_shell); export SHELL

    # ③ Duplicate-run prevention. Same approach as --cron's rc.lock (flock -n, fd 9).
    #    --restore's "skip if already alive" check is only true *after* the session has been
    #    created. If two instances run side by side, both read "not there" and open the same
    #    conversation twice = a doppelganger.
    #    The network wait below can run up to 120 seconds, so that window is wide open → the lock
    #    is grabbed before the wait, not after.
    #
    #    ★ fd 9 is not passed down to children below (9>&-). This is a trap we actually stepped on
    #      in an isolation test: when `tmux new-session` called by --restore spawns the server, that
    #      **daemon** inherits fd 9, and since the daemon doesn't die until reboot, the lock stays
    #      held forever. Measured —
    #        PID 326033 /usr/bin/tmux -L fmuxtest new-session -d -s zzh-alpha
    #        /proc/326033/fd/9 -> …/state/boot-restore.lock
    #      After that, even a --boot-restore typed by hand got bounced with "already holds the
    #      lock." The mechanism meant to prevent duplication ends up blocking the one manual retry
    #      that could fix things — a mirror image of ⑤'s failure mode.
    if command -v flock >/dev/null 2>&1; then
        exec 9>"$STATE/boot-restore.lock"
        if ! flock -n 9; then
            blog "another boot-restore already holds the lock — exiting"
            exit 0
        fi
    else
        blog "warn: flock not found — running without a duplicate-run guard"
    fi

    # ④ Boot-context check. This is @reboot-only, but a human might run it by hand too, and that's
    #    a legitimate use, so we don't block it. Still, when reading the log later, it should be
    #    possible to tell "was this right after a reboot or not."
    up=$(cut -d' ' -f1 /proc/uptime 2>/dev/null) || up=""
    up=${up%%.*}
    case "${up:-x}" in
        ''|*[!0-9]*) blog "warn: cannot read uptime — proceeding anyway" ;;
        *) if [ "$up" -gt 600 ]; then
               blog "warn: uptime ${up}s > 600s — this is not a fresh boot (manual run?); proceeding"
           else
               blog "uptime ${up}s — fresh boot"
           fi ;;
    esac

    # ⑤ Wait for network/DNS readiness. On timeout, it dies *without* restoring.
    #    Why not "just launch it and see": a claude started without a network fails immediately and
    #    leaves only a shell in the pane. But the tmux session name is still perfectly alive, so if
    #    a human later runs --restore, everything gets filtered out as "skip — already running." In
    #    other words, a failed auto-restore blocks a manual restore that would have succeeded. Dying
    #    without creating anything is far cheaper for a human to fix.
    #
    #    Why name resolution (getent hosts) was picked as the judgment — confirmed directly on this
    #    Pi: /etc/resolv.conf is written by tailscale, and its only nameserver is 100.100.100.100
    #      (MagicDNS). For MagicDNS to resolve a public domain, tailscaled has to be up and actually
    #      reach upstream → success means the link, routing, and DNS are all alive at once. A
    #      stronger signal than a box using plain DNS.
    #      No cache false-positives on a cold boot either: when tailscaled comes up fresh, its
    #      cache is empty.
    #      Measured — success in 6-10ms (54ms across 10 runs) / a nonexistent name fails instantly
    #      with rc=2. The check is cheap, so the 2-second interval isn't wasted.
    #    Still wrapped in timeout: hit an unresponsive resolver and glibc will burn through
    #    5s x 2 tries x server-count entirely.
    #    To cover the gap DNS alone can't (name resolves, but routing isn't up yet), we also probe
    #    TCP 443 once more. /dev/tcp is a bash builtin, so it doesn't pull in a curl dependency
    #    (measured 42ms).
    NETHOST=${TT_BOOT_NETHOST:-api.anthropic.com}
    NETWAIT=${TT_BOOT_NETWAIT:-120}
    t0=$(date +%s); netok=0
    while :; do
        # Pass the hostname as $1 instead of concatenating it into the command string (this keeps
        # quote escaping from being unwound early by the outer shell — the inner bash needs to see
        # it as "$1")
        if timeout 5 getent hosts "$NETHOST" >/dev/null 2>&1 &&
           timeout 5 bash -c "exec 3<>/dev/tcp/\"\$1\"/443" _ "$NETHOST" 2>/dev/null; then
            netok=1; break
        fi
        el=$(( $(date +%s) - t0 ))
        [ "$el" -lt "$NETWAIT" ] || break
        sleep 2
    done
    el=$(( $(date +%s) - t0 ))
    if [ "$netok" != 1 ]; then
        blog "ABORT: no DNS+tcp/443 to $NETHOST after ${el}s (budget ${NETWAIT}s) — refusing to restore"
        blog "       (a fleet of network-less claudes would look 'already running' and block the manual retry)"
        exit 1
    fi
    blog "network ready after ${el}s — $NETHOST resolves and tcp/443 connects"

    # ⑥ tmux server. new-session would launch it on its own, but launching it explicitly lets us
    #    catch a failure right here (socket directory permissions, /tmp not mounted yet — problems
    #    that only happen right after boot). If the server already exists, this is a complete no-op
    #    — it creates no session and no window.
    #    9>&- : keeps the server daemon spawned here from grabbing the lock fd and holding it until
    #    reboot (see ③).
    if ! tmux start-server 9>&- 2>>"$BOOTLOG"; then
        blog "ABORT: tmux start-server failed"
        exit 1
    fi

    # ⑦ Restore spec. If it's missing or empty, there's simply nothing to do — --restore makes the
    #    same judgment too, but filtering it here first is what leaves the reason in the log.
    if [ ! -s "$MANIFEST" ]; then
        blog "ABORT: no manifest at $MANIFEST — nothing to restore"
        exit 1
    fi
    # Staleness is only a warning. --cron runs --snapshot every minute, so a manifest older than
    # 7 days means "fmux cron didn't run at all during that time" (the Pi was off, or fmux was
    # removed). Even so, we don't block on it — a stale spec is still better than none, and
    # --restore re-validates every line anyway (claiming live conversations, checking transcript
    # existence, checking cwd existence). The reason for 7 days: anything shorter would fire a
    # warning every time in the perfectly normal case of the Pi being off for a few days due to
    # travel or a power outage.
    # The reason we don't use stat for the age comparison is the same as tt_log_rotate — GNU and BSD
    # options are exact opposites. `find -mtime +7` is POSIX, so it behaves identically on both.
    if [ -n "$(find "$MANIFEST" -mtime +7 2>/dev/null)" ]; then
        blog "warn: $MANIFEST is older than 7 days — restoring it anyway"
    fi

    # ⑧ This is where the actual restore happens. We keep the entire output of --restore —
    #    what got created and what got skipped and why is the only evidence available later.
    #    Arguments are passed as an array — swapping positional args with `set -- --restore --dry`
    #    would also change the "$1" that the branches still below (--list, the popup entry point)
    #    see. Harmless right now since we exit immediately after, but the day this block moves
    #    further up, it breaks silently.
    rargs=(--restore)
    if [ "$dry" = 1 ]; then rargs+=(--dry); fi
    blog "handing over to: $SELF ${rargs[*]}"
    rc=0
    #    9>&- : doesn't pass the lock fd down to the tmux server daemon that --restore spawns
    #    (see ③). The lock itself stays held until this process ends — only the child's copy of it
    #    gets closed.
    out=$("$SELF" "${rargs[@]}" 9>&- 2>&1) || rc=$?
    printf '%s\n' "$out" | while IFS= read -r l; do blog "  | $l"; done
    printf '%s\n' "$out"
    blog "=== boot-restore done (restore rc=$rc)"
    exit "$rc"
fi

