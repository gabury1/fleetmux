#!/usr/bin/env bash
# Builds the fleet the five walkthrough screenshots are taken from, on a tmux server that has
# nothing to do with yours, and prints the environment the .tape files must run under.
#
# Why this exists next to fleet.sh instead of reusing it: the screenshots need one thing the GIF
# demo does not — the session that ends up as `parser` has to *start* life called `bash-3`, because
# scene 03 photographs the rename that gives it its name (docs/superpowers/plans/2026-08-10-…).
# tmux will not hold two sessions of one name, so the order is part of the setup, not of the
# shooting.
#
# ⛔ ISOLATION — read this before changing anything here.
#   fmux itself never passes `-S` to tmux (0 occurrences in bin/fmux). It finds a server through
#   $TMUX, or failing that $TMUX_TMPDIR/tmux-$UID/default. So `-S` isolates *this script*, and does
#   nothing at all for the `fmux` the .tape files run. Both are needed:
#
#       unset TMUX                       ← the shell running vhs, too. ttyd inherits it.
#       export TMUX_TMPDIR=<dir>         ← where the socket goes
#       chmod 700 "$TMUX_TMPDIR/tmux-$(id -u)"
#       socket name must be `default`    ← the only name fmux will look for
#
#   Skipping this is not a hypothetical: on 2026-08-10 a verification run trusted `-S` alone and
#   photographed the author's real session list, preview text and all.
set -euo pipefail

TOUCH=0
if [ "${1:-}" = --touch ]; then TOUCH=1; shift; fi
ROOT=${1:?usage: shots.sh [--touch] <root-dir> [fmux-path]}
FMUX=${2:-$(cd "$(dirname "$0")/.." && pwd)/bin/fmux}
[ -x "$FMUX" ] || { echo "not executable: $FMUX" >&2; exit 1; }

HERE=$(cd "$(dirname "$0")" && pwd)

# ── The four isolation lines ─────────────────────────────────────────────────
unset TMUX
export HOME="$ROOT/home"
export TMUX_TMPDIR="$ROOT/tmp"
SOCKDIR="$TMUX_TMPDIR/tmux-$(id -u)"
mkdir -p "$HOME" "$SOCKDIR"
chmod 700 "$SOCKDIR"          # tmux refuses the whole directory otherwise: "unsafe permissions"
SOCK="$SOCKDIR/default"       # the name fmux looks for when $TMUX is unset

STATE="$HOME/.cache/fmux"
mkdir -p "$STATE" "$HOME/.config/fleetmux"
T() { tmux -S "$SOCK" "$@"; }

# ── --touch: re-date the hook records without rebuilding anything ────────────
# The anti-stuck guards added on 8/9 re-check a quiet hook against the screen (60s for waiting,
# 180s for working). The painted fixtures carry the phrases that survive that check, so this is a
# belt-and-braces refresh for takes that come long after setup — and the one thing that must be
# re-run if a fixture is ever replaced with text that lacks them.
if [ "$TOUCH" = 1 ]; then
    [ -S "$SOCK" ] || { echo "no fleet at $SOCK — run without --touch first" >&2; exit 1; }
    now=$(date +%s)
    srv=$(T display-message -p '#{pid}')
    for f in "$STATE"/hook-*; do
        [ -f "$f" ] || continue
        read -r st _ _ < "$f" 2>/dev/null || continue
        printf '%s %s %s\n' "$st" "$now" "$srv" > "$f"
    done
    # `finished` carries a timestamp too — ✓ ages out of the status bar after unseen_minutes.
    for f in "$STATE"/finished; do
        [ -f "$f" ] || continue
        read -r _ nm < "$f" 2>/dev/null || continue
        [ -n "$nm" ] && printf '%s %s\n' "$now" "$nm" > "$f"
    done
    echo "hook timestamps refreshed to $now"
    exit 0
fi

# ── A home with nothing of yours in it ───────────────────────────────────────
# Scene 04 runs a real Claude session. Claude draws its own UI — footer, trust dialog, /mcp list,
# skill list, resume banner — and none of that passes through the tmux-level defences below. An
# unisolated $HOME would put ~/.claude.json's MCP servers (tm-linear, tm-slack, tm-notion) and
# ~/.claude/skills/ on screen. Same class of leak as the test fixtures scrubbed on 8/6.
printf '{"mcpServers":{},"hasCompletedOnboarding":true}\n' > "$HOME/.claude.json"
mkdir -p "$HOME/.claude"
printf '{}\n' > "$HOME/.claude/settings.json"

# A working directory that is not a git repo and not under the real home — otherwise a branch name
# or /home/<user>/… shows up in a prompt or a footer.
WORK="$ROOT/work"
mkdir -p "$WORK"

# key_summon_fast defaults to empty (src/05-config.sh:45) — fmux takes no key until told to. The
# page's scene 01 says Shift+↑, so the fleet has to actually have it bound for text and picture to
# agree.
printf 'key_summon_fast=S-Up\naccent=73\n' > "$HOME/.config/fleetmux/config"
"$FMUX" --tmux-conf --write >/dev/null 2>&1 || true

# ── The fleet ────────────────────────────────────────────────────────────────
# bash-3 is the session scene 03 renames to parser. Everything else is its final name already.
T -f /dev/null new-session -d -s api    -c "$WORK" -x 200 -y 44
T new-session -d -s docs   -c "$WORK" -x 200 -y 44
T new-session -d -s bash-3 -c "$WORK" -x 200 -y 44
T new-session -d -s logs   -c "$WORK" -x 200 -y 44

T set -g status-right ''
T set -g status-left  ''
T set -g status-style 'bg=#1b222b,fg=#8a99a6'
T set -g window-status-current-style 'fg=#4ec9b0,bold'
T set -g automatic-rename off
for _s in api docs bash-3; do T rename-window -t "$_s" claude; done
T rename-window -t logs yazi

for _s in api docs bash-3 logs; do
    T send-keys -t "$_s" "PS1='\$ '; clear" Enter
done

# Painted screens, same as fleet.sh and for the same reasons — four live Claudes would cost tokens
# and give a different screen every take, and what these pictures are of is what fmux draws around
# them. The one exception is scene 04's background; see below.
#   ⚠️ These files are also what keeps ⏸ and ✻ alive past the anti-stuck guards added on 8/9: once
#   a hook goes quiet (60s for waiting, 180s for working) the badge is re-checked against the
#   screen. demo/screens/parser.txt and api.txt already contain WAITING_PAT and WORKING_PAT
#   wording, which is why a shoot that takes minutes still photographs the right badges. Replace
#   these fixtures without those phrases and the badges vanish mid-session.
paint() {  # paint <session> <fixture>
    [ -f "$HERE/screens/$2.txt" ] || return 0
    T send-keys -t "$1" "clear; cat '$HERE/screens/$2.txt'; sleep 3600" Enter
}
paint api    api
paint bash-3 parser
paint docs   docs
T send-keys -t logs "clear; printf '  ~/src\n\n   drwxr-xr-x  limiter\n   drwxr-xr-x  parser\n   -rw-r--r--  README.md\n   -rw-r--r--  Cargo.toml\n'" Enter

sleep 1
T source-file "$HOME/.config/fleetmux/tmux.conf"

# vhs cannot type Shift+Up — its modifiers take a character, not a named key. The popup is what is
# being photographed, not the keystroke that opens it, so the camera gets its own trigger.
#   Typing `tmux display-popup …` at a shell does not work either: these panes are sitting in
#   `sleep 3600`, which never reads stdin. A key binding goes to the server, so it fires whatever
#   the foreground process is doing.
#   The size is not the one fmux installs (85%x75%). At 700px tall the real popup leaves most of
#   the frame empty, and an image that is two-thirds blank reads as a mistake. 72%x34% fills the
#   picture and still shows the session behind it, which is the part scene 04 is about.
T bind -n M-g display-popup -E -w 72% -h 34% -b rounded -S 'fg=colour73' -T ' ⌘ fmux ' "$FMUX" --from '#S'

# ── Hook state ───────────────────────────────────────────────────────────────
now=$(date +%s)
id() { T display-message -p -t "$1" '#{session_id}' | tr -d '$'; }
# The pid must belong to a live process and the timestamp must be newer than the session, or
# fmux_hook_valid discards the record as a ghost from a previous boot. The tmux server is the
# obvious live pid.
srv=$(T display-message -p '#{pid}')
printf 'working %s %s\n' "$now" "$srv" > "$STATE/hook-$(id api)"
printf 'waiting %s %s\n' "$now" "$srv" > "$STATE/hook-$(id bash-3)"
printf 'idle %s %s\n'    "$now" "$srv" > "$STATE/hook-$(id docs)"
printf '%s docs\n' "$now" > "$STATE/finished"

# The preview pane shows these. Neutral wording only — this text ends up in a published image.
printf '%s\nrefactor the token bucket so the limiter is testable without sleeping\n' "$now" \
    > "$STATE/last-$(id api)"; chmod 600 "$STATE/last-$(id api)"
printf '%s\nrun the full suite and tell me which failures are mine\n' "$now" \
    > "$STATE/last-$(id bash-3)"; chmod 600 "$STATE/last-$(id bash-3)"

# ── What the tapes need ──────────────────────────────────────────────────────
cat <<ENV
ready.

  socket   $SOCK
  home     $HOME
  work     $WORK

Every tape must open with these, and the shell you run vhs from needs the same unset:

  unset TMUX
  export HOME=$HOME
  export TMUX_TMPDIR=$TMUX_TMPDIR

Refresh the hook timestamps right before a take (they are what puts ⏸ and ✻ on the bar):

  demo/shots.sh --touch $ROOT

Tear down when finished — this leaves nothing behind:

  tmux -S $SOCK kill-server 2>/dev/null; rm -rf $ROOT
ENV
