#!/usr/bin/env bash
# fleetmux (tt) — a tmux control tower for AI agent fleets
#   Tracks claude/codex session state via hooks, lets you pick and jump in, broadcast, and restore
#   →/Enter: enter session   ←/Esc: close   Ctrl-N: new session   Ctrl-E: rename   Ctrl-X: delete   Ctrl-R: refresh   Ctrl-D: detach from tmux
#   The summon key comes from config — the default is only prefix + F, and the no-prefix key
#   defaults to empty (it steals no key). Turn it on with fmux config set key_summon_fast — 87-tmux-conf.sh embeds it in the snippet.
set -euo pipefail
export LC_ALL=en_US.UTF-8   # cron has no locale — prevents unicode glyph regexes from misbehaving

# Everything this tool writes is private to the person running it. The state directory holds the
# prompts you typed (last-*), where every session lives (manifest), and a log that catches the
# stderr of the hook path — which is how a whole prompt ended up in hook.log once, verbatim.
#   last-* was already created 0600 by hand, but hook.log came out 0644 and was readable by
#   anyone with an account on the machine (measured 2026-08-06 on both Linux and macOS). Setting
#   the policy once, here, is what keeps that from drifting per file.
umask 077

# State directory. The name is fmux; ~/.cache/tt is what installs made before 2026-08-06 used.
#   **Nothing is moved.** An existing install keeps running on the directory it already has, and a
#   fresh one is created under the new name. A rename that moves files can fail halfway and leave a
#   fleet without its manifest; a rename that only chooses a path cannot fail at all.
#   Two builtin tests, no fork — this runs on every hook event.
if [ -d ~/.cache/fmux ]; then STATE=~/.cache/fmux
elif [ -d ~/.cache/tt ]; then STATE=~/.cache/tt
else STATE=~/.cache/fmux
fi

# ── Own absolute path (SELF) ─────────────────────────────────────────────────
# There are more than 20 places internally that call itself again (fzf --bind, preview, snapshot,
# hook commands). It used to rely entirely on `tt` from PATH, but in environments without the
# short alias installed, or cron/GUI contexts with a different PATH, all of that silently breaks
# (popup shows an empty list, hooks fail silently).
# `readlink -f` is a GNU extension and doesn't exist on old macOS → resolve it manually with a
# POSIX loop that follows the link one step at a time.
#   readlink (the no-flag form) and `cd -P`/`pwd -P` are POSIX, so they exist on both Linux and BSD.
fmux_self() {
    local p="${BASH_SOURCE[0]:-$0}" d l n=0
    case "$p" in */*) ;; *) p=$(command -v -- "$p" 2>/dev/null || printf '%s' "$p") ;; esac
    while [ -L "$p" ] && [ "$n" -lt 20 ]; do
        l=$(readlink "$p" 2>/dev/null) || break
        case "$l" in
            /*) p="$l" ;;
            *)  d=${p%/*}; p="$d/$l" ;;     # a relative link is resolved against "the directory the link was in"
        esac
        n=$((n + 1))
    done
    d=${p%/*}; [ "$d" = "$p" ] && d="."
    d=$(cd "$d" 2>/dev/null && pwd -P) || d="."
    printf '%s/%s' "$d" "${p##*/}"
}
SELF=$(fmux_self)
[ -x "$SELF" ] || SELF="fmux"      # last-resort fallback: if it still can't be found, defer to PATH as before
# A safely quoted form to embed in shell strings (fzf --bind, hook commands) — doesn't break even if the path has spaces or quotes
SELFQ="'${SELF//\'/\'\\\'\'}'"

