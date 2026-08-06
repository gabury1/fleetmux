# ── the door to the settings screen ─────────────────────────────────────────
# There is exactly one door: ^O in the popup. There used to be a second one — a
# trailing '⚙ settings' row at the end of the list — but leaking a non-session
# row into the session list forced guards onto every one of the six places that
# consume the list (preview, ^X, ^E, ^B, multi-select collection, empty-list
# bootstrap), and the bootstrap check's guard was actually broken, which turned
# into a "the popup doesn't open at all" bug. Instead of cutting back to one
# door, **discoverability is repaid by the footer** — this key is always
# printed below the list.
#
# So the key name is written in exactly one place: the fzf binding below and
# the footer/help text both derive from the same value. The human-readable
# form (^O) is mechanically extracted from the binding name, so the two can
# never drift apart.
#   (The settings key, key_settings, isn't read by any code yet — remapping is
#    T7's job. Reading that value here would make the screen's "not wired"
#    marker a lie.)
TT_KEY_SETTINGS='ctrl-o'
tt_key_label() {
    case "${1:-}" in
        ctrl-?) printf '^%s' "$(printf %s "${1#ctrl-}" | tr 'a-z' 'A-Z')" ;;
        alt-?)  printf 'M-%s' "${1#alt-}" ;;
        *)      printf '%s' "${1:-}" ;;
    esac
}

# Input prompt: Esc=cancel (rc 1) · Enter=confirm · backspace supported — hand-rolled
# because read can't do Esc-to-cancel
tt_prompt() {
    local p="$1" s="" c
    printf '%s' "$p" >/dev/tty
    while IFS= read -rsn1 c </dev/tty; do
        case "$c" in
            $'\x1b')
                # Absorb the sequence that follows Esc (e.g. arrow keys). A fractional timeout
                # is bash 4+ only — the default mac shell (3.2) rejects it with "invalid timeout
                # specification", and switching to an integer 1s means every Esc press stalls
                # for a full second. So on 3.2 we skip the absorb entirely: Esc-to-cancel still
                # works, arrow keys just get read as cancel too — a small, acceptable cost.
                [ "$TT_TINY_READ" = 1 ] && { read -rsn2 -t 0.01 _ </dev/tty || true; }
                printf '\n' >/dev/tty; return 1 ;;
            "") printf '\n' >/dev/tty; break ;;
            $'\x7f'|$'\x08')
                [ -n "$s" ] && { s=${s%?}; printf '\b \b' >/dev/tty; } ;;
            *) s+="$c"; printf '%s' "$c" >/dev/tty ;;
        esac
    done
    printf '%s' "$s"
}

# New session (popup ^N): asks for name + start command — the command runs on top of
# the shell (the session survives even after the command exits)
if [ "${1:-}" = "--do-new" ]; then
    n=$(tt_prompt "new session name (Esc to cancel): ") || exit 0
    [ -n "$n" ] || exit 0
    printf %s "$n" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1 \
        || { echo "broken bytes in name (IME mid-composition?) — retry in English mode"; sleep 2; exit 0; }
    cmd=$(tt_prompt "start command (empty = plain shell, e.g. claude): ") || exit 0
    tmux new-session -d -s "$n" || exit 0
    if [ -n "$cmd" ]; then
        tmux send-keys -t "=$n:" -l "$cmd"
        tmux send-keys -t "=$n:" Enter
        case "$cmd" in claude*)
            # Reserve a /rename — it actually runs when the SessionStart hook (tt --hook boot)
            # confesses that it booted. The first field stores the reservation time: a TTL cuts
            # off a reservation that never got consumed instead of letting it live forever
            mkdir -p "$STATE"
            echo "$(date +%s) $n" > "$STATE/pending-rename-$n"
            ;;
        esac
    fi
    # Record it into the fleet manifest right away — the moment of creation is the only
    #   time we know "what it was launched with". The conversation id is pinned to '-'
    #   (not "preserve"): if an old line with the same name is still around, the new
    #   session would come back attached to someone else's conversation. The real id gets
    #   filled in a few seconds later, when the boot hook receives it on stdin.
    npath=$(tmux display-message -p -t "=$n:" '#{pane_current_path}' 2>/dev/null || true)
    case "$cmd" in claude*|codex*) nkind=agent ;; *) nkind=tool ;; esac
    case "$cmd" in '') ncmd="-" ;; *) ncmd="$cmd" ;; esac
    tt_mf_upsert "$n" "${npath:-$HOME}" "$nkind" "$ncmd" "-" || true
    exit 0
fi

# Broadcast (popup ^B): injects one prompt into all selected sessions in bulk (tool
# sessions are filtered out by tt_broadcast)
if [ "${1:-}" = "--do-broadcast" ]; then
    shift
    # ^B passes fzf's {+1} through as-is — if nothing was tagged, there are no arguments.
    [ $# -ge 1 ] || exit 0
    echo "targets: $*"
    m=$(tt_prompt "broadcast prompt (Esc to cancel): ") || exit 0
    [ -n "$m" ] || exit 0
    tt_broadcast "$m" "$@"
    sleep 1
    exit 0
fi

# fzf preview: shows the 'bottom' of that session's screen.
#   Streaming the whole screen pushes exactly the urgent part (input box, spinner, approval
#   prompt) at the bottom out past the edge of the preview window. A plain tail doesn't work
#   either — an unattached session's pane is much longer than the preview window (measured
#   43 lines vs 28), so scooping up only trailing blank lines leaves the screen looking
#   entirely empty. So we strip the trailing blank lines first, then tail.
#   Reason it's split into a separate subcommand: it avoids nested quoting inside the
#   fzf --preview string.
#
# At the top we place **the last prompt sent to that session** (3rd argument = session id,
#   the 3rd field of --list). That single line is exactly what scrolls up and disappears
#   from the screen, so the screen tail alone can't answer "what did I even tell it to do".
#   Shape: one `last prompt ❯` label line + body (no prefix, full window width) + a
#   separator line. A boxed / bar-bordered variant was tried and dropped — see the render
#   comment in 35-lastprompt.sh for the full reason.
#   ⚠ This is an add-on — if the file is missing, corrupted, the id wasn't received, or the
#     window is too narrow, it falls back to **the old output, unchanged, with no header**.
#     The preview must never break because of this feature (design doc section 4).
if [ "${1:-}" = "--preview" ]; then
    n="${2:-}"; [ -n "$n" ] || exit 0
    lines="${FZF_PREVIEW_LINES:-40}"                       # fzf supplies the preview window height
    case "$lines" in ''|*[!0-9]*) lines=40 ;; esac
    psid="${3:-}"; psid=${psid#\$}
    hdr=""
    case "$psid" in
        ''|*[!0-9]*) ;;                                    # no id received → no header (old behavior)
        *) if [ -f "$STATE/last-$psid" ]; then
               cols="${FZF_PREVIEW_COLUMNS:-80}"           # fzf supplies the preview window width too
               case "$cols" in ''|*[!0-9]*) cols=80 ;; esac
               # Label/separator color follows the config's accent — hardcoding it would leave
               #   this spot stale whenever the color is changed elsewhere.
               #   Warnings are swallowed: the preview's stderr would render straight into the
               #   preview window and cover the screen.
               acc=$(tt_conf_num accent 255 2>/dev/null) || acc=""
               [ -n "$acc" ] || acc=$(tt_conf_default accent)
               hdr=$(LC_ALL=C awk -v cols="$cols" -v acc="$acc" "$TT_LASTP_VIEW_AWK" \
                       "$STATE/last-$psid" 2>/dev/null) || hdr=""
           fi ;;
    esac
    if [ -n "$hdr" ]; then
        printf '%s\n' "$hdr"
        # Shrink the screen tail by however many lines the header ate — otherwise the preview
        #   overflows and **the top** gets cut off, meaning the header we just drew would be
        #   the first thing pushed out. Count without forking (wc would fork once per preview).
        hl=0
        while IFS= read -r _; do hl=$((hl + 1)); done <<< "$hdr"
        lines=$((lines - hl))
        [ "$lines" -lt 1 ] && lines=1
    fi
    tmux capture-pane -ep -t "=$n:" 2>/dev/null | awk -v n="$lines" '
        { L[NR] = $0 }
        END {
            e = NR
            while (e > 0 && L[e] ~ /^[ \t]*$/) e--        # strip trailing blank lines
            s = e - n + 1; if (s < 1) s = 1
            for (i = s; i <= e; i++) print L[i]
        }'
    exit 0
fi

# Kill session (popup ^X): confirm, then kill by exact match
#   It used to splice the name straight into the bash -c string inside the fzf binding —
#   a name with a space would break the quoting, and -t prefix matching could kill a
#   different session sharing the same prefix. Now the name arrives as a single argument.
if [ "${1:-}" = "--do-kill" ]; then
    n="${2:-}"; [ -n "$n" ] || exit 0
    read -rp "kill $n? [y/N] " a </dev/tty || exit 0
    [ "$a" = y ] && tmux kill-session -t "=$n"
    exit 0
fi

# Rename session (popup ^E): validate → tmux rename → if it's a Claude session, also
# inject /rename to sync the title
if [ "${1:-}" = "--do-rename" ]; then
    old="${2:-}"; [ -n "$old" ] || exit 0
    n=$(tt_prompt "rename $old to (Esc to cancel): ") || exit 0
    [ -n "$n" ] || exit 0
    printf %s "$n" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1 \
        || { echo "broken bytes in name (IME mid-composition?) — retry in English mode"; sleep 2; exit 0; }
    tmux rename-session -t "=$old" "$n" || exit 0
    tt_mf_rename "$old" "$n" || true   # the manifest's key follows too — otherwise the old
                                        # name comes back to life on restore
    # Injecting /rename is claude-only — codex has no such slash command (only when the
    # active pane is exactly claude)
    if [ "$(tmux display-message -p -t "=$n:" '#{pane_current_command}' 2>/dev/null)" = claude ]; then
        tmux send-keys -t "=$n:" -l "/rename $n"
        sleep 0.5
        tmux send-keys -t "=$n:" Enter
        echo "→ renamed + synced Claude title"
        sleep 1
    fi
    exit 0
fi

# Emit hook config JSON — the claude wrapper injects it via --settings (non-invasive to the
#   global settings.json). The command hardcodes this script's absolute path rather than
#   `tt` on PATH — so the hook still attaches in environments without the short alias set
#   up, and under cron/GUI launches with a different PATH. But if the file ever disappears
#   (removed/moved), an already-running session shouldn't spew an error on every event, so
#   `2>/dev/null || true` swallows it quietly. The path is shell-quoted ($SELFQ), so it
#   survives paths with spaces or quotes too.
if [ "${1:-}" = "--hooks-json" ]; then
    # JSON string escaping (backslash and quote only). Putting \" directly into a printf
    # format string is a dead end — backslash interpretation differs by implementation, so
    # the command is fully assembled first and wrapped here in one pass.
    jesc() { local s="$1"; s=${s//\\/\\\\}; s=${s//\"/\\\"}; printf '%s' "$s"; }
    printf '{"hooks":{'
    first=1
    while read -r ev st; do
        [ "$first" = 1 ] || printf ','
        first=0
        printf '"%s":[{"hooks":[{"type":"command","command":"%s","async":true,"timeout":10}]}]' \
            "$ev" "$(jesc "$SELFQ --hook $st 2>/dev/null || true")"
    done << 'EOF'
UserPromptSubmit working
PostToolUse working
PreCompact working
PostCompact working
Stop idle
Notification waiting
SessionStart boot
SessionEnd clear
EOF
    printf '}}\n'
    exit 0
fi

# Emit codex hook injection args — the codex wrapper reads them as an array and passes them
#   straight through (non-invasive to the global ~/.codex/config.toml). Output = one line per
#   argument (alternating "-c" line / TOML inline line). The wrapper reads with mapfile and
#   never evals → the shell never gets a chance to parse this string (zero quote-injection
#   surface). The command value is a fixed literal too. PermissionRequest uses a dedicated
#   state name (waiting-codex) because the event itself means "awaiting approval", so no
#   stdin check is needed.
#   This also uses an absolute path, but unlike the claude side it adds neither shell
#   quoting nor `|| true`: it isn't confirmed whether codex hands this string to a shell or
#   splits argv on whitespace itself. A bare absolute path is the one form that works under
#   both interpretations (assuming the path itself has no spaces).
if [ "${1:-}" = "--codex-hooks" ]; then
    tesc() { local s="$1"; s=${s//\\/\\\\}; s=${s//\"/\\\"}; printf '%s' "$s"; }   # TOML basic string
    while read -r ev st; do
        printf -- '-c\n'
        printf 'hooks.%s=[{hooks=[{type="command",command="%s --hook %s",timeout=5}]}]\n' \
            "$ev" "$(tesc "$SELF")" "$st"
    done << 'EOF'
UserPromptSubmit working
PreToolUse working
PostToolUse working
Stop idle
PermissionRequest waiting-codex
EOF
    if [ "${2:-}" = "--pause" ]; then
        printf '  press any key to return'
        read -rsn1 _ < /dev/tty 2>/dev/null || read -r _ < /dev/tty 2>/dev/null || true
        printf '\n'
    fi
    exit 0
fi

# Help screen (entered via ? in the popup, or `tt --help` on the CLI)
#
# `--pause` prints the screen and then waits for one key. The popup binds ? to
# `--help --pause`, and the waiting **must happen in here**, not in the binding.
#
# Why (measured 2026-08-06, on a Mac): fzf runs an execute(...) body through **$SHELL**, not
# through sh. The binding used to end with an inline `read -rsn1`, which is bash syntax — on a
# machine whose login shell is zsh that read fails instantly, so help flashed up and vanished
# before it could be read. It worked on the author's machine for the single reason that the
# author's $SHELL is bash.
#
# ⛔ Do not put shell syntax inside a --bind body. Anything that needs a shell must run inside
#    this file, which has a bash shebang and therefore a shell we actually chose.
if [ "${1:-}" = "--help" ]; then
    # Config is loaded once, as a bare statement (not in a subshell) at the top of the entry
    # point — the contract of 05-config.sh.
    tt_conf_load
    acc=$(tt_conf_num accent 255)
    T=$'\033[38;5;'"$acc"'m'; D=$'\033[2m'; R=$'\033[0m'; B=$'\033[1m'
    # The first screen speaks from **this machine's current config**. It used to hardcode
    # Option+← and 6h/10 min, but the default config sets no prefix-less key at all
    # (key_summon_fast is empty by default), so right after install a teammate's first-ever
    # screen taught them a key that didn't exist (team rollout gate B7).
    hsum=$(tt_conf_get key_summon)
    hfast=$(tt_conf_get key_summon_fast)
    hrecent=$(tt_conf_num recent_hours)
    hunseen=$(tt_conf_num unseen_minutes)
    hkset=$(tt_key_label "$TT_KEY_SETTINGS")   # display form derived from the same value as the popup binding
    if [ -n "$hsum" ]; then hsummon="prefix + $hsum"; else hsummon="(key_summon is empty)"; fi
    if [ -n "$hfast" ]; then hsummon="$hsummon  ·  $hfast  ${D}prefix-less${R}"
    else hsummon="$hsummon  ${D}· no prefix-less key — tt config set key_summon_fast S-Left${R}"
    fi
    cat << EOF

  ${B}tt — tmux session manager${R}  ${D}works with claude & codex sessions${R}

  ${T}navigate${R}
    →/Enter    enter session          ←/Esc    close    ^D  detach tmux (back to shell)
    summon     $hsummon

  ${T}manage${R}
    ^N  new session     ^E  rename     ^X  kill     ^R  refresh

  ${T}settings${R}
    ${hkset}  open settings — the only door; the popup footer shows this key too
    Enter flips a switch on the spot; number/text keys ask for a value and validate it
    ${D}rows marked "not wired" are not wired to any behaviour yet — the toggle would be a lie${R}
    tt config list   ${D}the same table from the shell; tt config path shows the file${R}

  ${T}tmux binding${R}  ${D}fmux owns one file and borrows one line of your ~/.tmux.conf${R}
    tt --tmux-conf          print the snippet — summon key, and the on-exit snapshot hooks
    tt --tmux-conf --write  write it, then add ${D}source-file <printed path>${R} to ~/.tmux.conf
    ${D}key_summon is pressed after the prefix; key_summon_fast is a space-separated list of${R}
    ${D}prefix-less keys — one physical key arrives under different names per terminal${R}
    ${D}changing either key, or snapshot_on_exit, rewrites the snippet on the spot${R}
    ${D}S-Left is what ./install.sh offers: the one prefix-less single keystroke that reaches${R}
    ${D}tmux on macOS, Linux and Windows Terminal alike. It takes that key from everything in${R}
    ${D}the pane (vim, shell line-editing, fzf) — that is why it is offered, never a default.${R}
    ${D}Some dotfiles bind S-Left/S-Right to window switching; pick another key if yours does.${R}
    ${D}tt config unset key_summon_fast gives the key back — key_summon still summons.${R}

  ${T}broadcast${R}
    Tab-mark multiple sessions, then Enter — send one prompt to all
    ${D}tool sessions are skipped — a prompt typed into a shell or TUI runs as a command${R}
    ${D}^B does the same but keeps the popup open — for repeated sends${R}

  ${T}fleet${R}  ${D}survive a reboot — the manifest remembers what was up${R}
    tt --snapshot           record every live session: cwd, kind, command, conversation
    tt --restore [--dry]    bring them all back — live ones are skipped, --dry just plans
    tt --boot-restore       ${D}[--dry]${R} same, but safe to hang off @reboot cron
    tt --forget ${D}<name>${R}     drop one session from the manifest
    ${D}--boot-restore waits up to 120s for DNS before restoring, and aborts if it never comes —${R}
    ${D}claudes started without a network die into a shell, then look "already running" forever${R}
    ${D}touch ~/.cache/tt/no-autorestore to skip it on the next boot; log is ~/.cache/tt/boot.log${R}
    ${D}agents come back with claude --resume <id>, never --continue —${R}
    ${D}--continue picks "latest chat in this folder", so same-cwd sessions clone each other${R}
    ${D}resume runs in the conversation's own home dir, which is often not the session cwd${R}
    ${D}manifest keeps 3 backup generations: manifest.bak .bak2 .bak3${R}

  ${T}reading the list${R}
    ${B}bold name${R}   talked within ${hrecent}h          ${D}dim name${R}   quiet session
    ${T}teal name${R}   tool session (alphabetical, bottom)
    ● attached    ✻ working    ⏸ awaiting approval    ✓ unseen result
    ⊘ remote control dropped — retried every minute; ${B}red ⊘${R} = gave up after 3 tries

  ${T}status bar${R}  ${D}not wired automatically — fmux never rewrites your status line${R}
    tt --status prints it; nothing shows up until you put it in your own tmux config:
      ${D}set -g status-interval 5${R}
      ${D}set -ag status-right '#($SELF --status)'${R}
    ⏸n ✻n — fleet tally: sessions awaiting you / working right now
    ✓name — finished while you were away. clears on visit or ${hunseen} min

  ${T}korean IME tip${R}
    if keys after tmux prefix get eaten, keep holding Ctrl (^B ^D = detach)

EOF
    exit 0
fi

# Exclude the current session from the list — the popup binding tells us via --from '#S',
# a plain shell run asks tmux directly
CUR=""
[ "${1:-}" = "--from" ] && CUR="${2:-}"
[ -z "$CUR" ] && [ -n "${TMUX:-}" ] && CUR=$(tmux display-message -p '#S' 2>/dev/null || true)
export TT_CUR="$CUR"

# Snapshot the fleet every time the popup opens — this removes "commit" as a separate action
#   (the author's suggestion). Things the hook's auto-recording can't catch (an external
#   /rename, a manually created session, a cwd move) all get cleaned up in one popup open.
#   Reason it's detached to the background: it reads a file per session, and the popup has
#   no reason to wait on that (zero perceived latency).
( "$SELF" --snapshot >/dev/null 2>&1 & ) 2>/dev/null || true

# Empty-state bootstrap: create one and enter it directly, but **only when there are
#   no sessions to go to at all** — tt is tmux's front door.
#   The test is not "does the list have a row" but "**is there at least one session**".
#   The two differ: 80-view.sh drops TT_CUR (the currently attached session) from the list,
#   so **if there is exactly one live session and it is the one we're attached to**, the
#   list comes up empty — the path where the "no sessions yet" onboarding prompt shows up
#   even though a session is alive and well. So if CUR is set (= we were opened from inside
#   some session = at least 1 session exists), we never leak into the bootstrap.
#   No filter is needed here because no non-session row ever ends up in the list — it used
#   to be filtered out with grep -v on a settings row, and that very filter is what broke
#   this check. An empty list means there is no session to go to, plain and simple.
mkdir -p "$STATE" 2>/dev/null || true    # the two spots below send --list's stderr here
if [ -z "$CUR" ] && [ -z "$("$SELF" --list 2>>"$STATE/hook.log" || true)" ]; then
    read -rp "no sessions yet. name for a new one: " n </dev/tty || exit 0
    [ -n "$n" ] || exit 0
    if [ -n "${TMUX:-}" ]; then
        tmux new-session -d -s "$n"
        exec tmux switch-client -t "=$n"
    else
        exec tmux new-session -s "$n"
    fi
fi

# --delimiter/--with-nth: hides field 1 (the plain name) and field 3 (the session id),
#   showing only field 2 (the colored display line). So {1}/{+1} pass a name with spaces
#   through to tt unmangled, and {3} becomes the key the preview uses to find last-<id>
#   (so the preview never has to ask tmux again).
# The preview is a tail — what matters is the bottom of the screen (input box, spinner,
#   approval prompt), and streaming the whole thing would cut it off.
# --preview-label is not ' screen ' — it is **the name of the selected session**. Two
#   things now live inside the window: the last-prompt header above (text we wrote) and the
#   screen tail below it (someone else's output). If the outer label said ' screen ', it
#   would claim the header is screen content too — the label refers to the whole window, so
#   it has to name what the whole window is, i.e. "the selected session". The header already
#   names itself (last prompt), so the screen tail doesn't need its own label.
#   focus fires every time the cursor moves (including the first render), so the label
#   always follows the current row.
#   The ' session ' in --preview-label is the one-moment fallback before that first firing.
#   Why {1} (the plain name): field 2 has color codes baked in, and leaking those into the
#   label as-is would corrupt it.
#   Why transform-preview-label instead of change-preview-label: this was measured directly —
#   the change-* family inserts the argument into the label **literally**, so '{1}' is what
#   gets printed on screen (reproduced 2026-08-05). Only the transform-* family runs the
#   argument as a command and uses its output as the label, so placeholders actually expand.
#   How to check: launch fzf for real inside a sized pty (script + stty) and capture the
#   rendered characters. A successful launch (rc=0) alone won't catch this difference — both
#   forms start up fine.
#   And {1} is substituted **already shell-quoted** ('my-session'). Wrapping it again in " "
#   would leave the literal quote characters on screen — padding comes from printf's format,
#   and {1} is passed as its argument.
# The list producer's stderr goes to hook.log, not the screen — if the config file has a
#   broken line, that warning would paint over the fzf screen and make the control tower
#   unreadable. Not discarding it is the same reasoning as line 86 (recommendation N3).
# The footer prints the settings key — dropping the ⚙ row from the list means discoverability
#   is repaid here instead. Both the binding and the display text come from the same
#   TT_KEY_SETTINGS, so changing the key updates the screen too — the two can never drift.
session=$("$SELF" --list 2>>"$STATE/hook.log" \
    | fzf --ansi --reverse --cycle --prompt='❯ ' --pointer='▶' --info=hidden --multi \
          --delimiter=$'\t' --with-nth=2 \
          --footer="? help · $(tt_key_label "$TT_KEY_SETTINGS") settings" \
          --bind "?:execute($SELFQ --help --pause </dev/tty >/dev/tty 2>&1)" \
          --color='pointer:#4ec9b0,prompt:#4ec9b0,hl:#56b6c2,hl+:#56b6c2,bg+:#18221e,fg+:regular,footer:#4a5a52,border:#4a5a52,label:#4ec9b0,preview-border:#4a5a52' \
          --preview "$SELFQ --preview {1} {3}" \
          --preview-window 'right,65%,border-rounded' --preview-label=' session ' \
          --bind 'focus:transform-preview-label:printf " %s " {1}' \
          --bind 'right:accept' \
          --bind 'left:abort' \
          --bind "ctrl-r:reload($SELFQ --list)" \
          --bind 'ctrl-d:execute-silent(tmux detach-client)+abort' \
          --bind "ctrl-n:execute($SELFQ --do-new </dev/tty >/dev/tty 2>&1)+clear-query+reload($SELFQ --list)" \
          --bind "ctrl-e:execute($SELFQ --do-rename {1} </dev/tty >/dev/tty 2>&1)+clear-query+reload($SELFQ --list)" \
          --bind "ctrl-x:execute($SELFQ --do-kill {1} </dev/tty >/dev/tty 2>&1)+reload($SELFQ --list)" \
          --bind "ctrl-b:execute($SELFQ --do-broadcast {+1} </dev/tty >/dev/tty 2>&1)+deselect-all+clear-query" \
          --bind "$TT_KEY_SETTINGS:execute($SELFQ --config-view </dev/tty >/dev/tty 2>&1)+reload($SELFQ --list)") || exit 0

session=$(printf '%s\n' "$session" | grep -v '^─' || true)   # treat separator lines as unselectable
[ -z "$session" ] && exit 0

# Tab-mark 2 or more, then Enter/→ = broadcast (1 or fewer = enter as usual)
#   Every marked line is a real session — the list never has non-session rows, so there's
#   nothing left to filter out here.
count=$(printf '%s\n' "$session" | grep -c . || true)
if [ "${count:-0}" -ge 2 ]; then
    targets=()
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        targets+=("${line%%$'\t'*}")   # before the tab = plain name (safe with spaces)
    done <<< "$session"
    [ "${#targets[@]}" -ge 1 ] || exit 0   # (bash 3.2: guard against empty array + set -u)
    printf 'targets: %s\n' "${targets[*]}"
    m=$(tt_prompt "broadcast prompt (Esc to cancel): ") || exit 0
    [ -n "$m" ] || exit 0
    tt_broadcast "$m" "${targets[@]}"
    sleep 1
    exit 0
fi
session=$(printf '%s\n' "$session" | head -1)

[ -z "$session" ] && exit 0
session=${session%%$'\t'*}

if [ -n "${TMUX:-}" ]; then
    tmux switch-client -t "=$session"
else
    exec tmux attach -t "=$session"
fi
