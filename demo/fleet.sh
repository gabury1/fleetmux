#!/usr/bin/env bash
# Builds a small, fake fleet on an isolated tmux socket so the demo is reproducible and never
# touches a real one. Hook state is written by hand — the demo shows what fmux draws, and the
# states it draws are the point, so they are set rather than waited for.
set -euo pipefail
SOCK=${1:?socket}
HOME_DIR=${2:?home}
FMUX=${3:?fmux path}
export HOME="$HOME_DIR"
STATE="$HOME/.cache/fmux"; mkdir -p "$STATE" "$HOME/.config/fleetmux"
T() { tmux -S "$SOCK" "$@"; }

printf 'key_summon_fast=S-Up\naccent=73\n' > "$HOME/.config/fleetmux/config"
"$FMUX" --tmux-conf --write >/dev/null 2>&1 || true

T -f /dev/null new-session -d -s api    -x 200 -y 44
T new-session -d -s docs   -x 200 -y 44
T new-session -d -s parser -x 200 -y 44
T new-session -d -s files  -x 200 -y 44
T set -g status-right ''
T set -g status-left  ''
# A recording is published; a real hostname and home directory are not part of the demo.
# Each pane gets a bare prompt, and the status line gets a dark style so the badges — which draw
# their own dark chips — are not sitting on tmux's default lime green.
T set -g status-style 'bg=#1b222b,fg=#8a99a6'
T set -g window-status-current-style 'fg=#4ec9b0,bold'
for _s in api docs parser files; do
    T send-keys -t "$_s" "PS1='\$ '; clear" Enter
done

# What the preview shows is the tail of a session's screen, so the panes have to look like
# agents. These are painted, not run: launching four real Claude sessions would cost tokens,
# need an account, and give a different screen every take — and the demo is about what fmux
# draws around them. Same reasoning as writing the hook state directly.
#   The screens are representative, not captured from a real conversation.
HERE=$(cd "$(dirname "$0")" && pwd)
for _s in api parser docs; do
    [ -f "$HERE/screens/$_s.txt" ] || continue
    T send-keys -t "$_s" "clear; cat '$HERE/screens/$_s.txt'" Enter
done
# The tool session is a file manager, not an agent — it should read as one.
T send-keys -t files "clear; printf '  ~/src\n\n   drwxr-xr-x  limiter\n   drwxr-xr-x  parser\n   -rw-r--r--  README.md\n   -rw-r--r--  Cargo.toml\n'" Enter
sleep 1
T source-file "$HOME/.config/fleetmux/tmux.conf"

# A trigger the recorder can actually send. vhs cannot type Shift+Up (its modifiers take a
# character, not a named key), and the recording shows the popup appearing, not the keystroke —
# so binding one extra key for the camera changes nothing about what the demo claims.
T bind -n M-g display-popup -E -w 85% -h 75% -b rounded -S 'fg=colour73' -T ' ⌘ fmux ' "$FMUX" --from '#S'

now=$(date +%s)
id() { T display-message -p -t "$1" '#{session_id}' | tr -d '$'; }
# The pid has to be a live process and the timestamp has to be **after** the session was created —
# fmux_hook_valid throws out a record older than its session as a ghost from a previous boot, which
# is exactly what a hand-written demo file looks like unless you get this right. The tmux server
# itself is the obvious live pid.
srv=$(T display-message -p '#{pid}')
# api is working · parser wants you · docs finished while you were away · files is a tool session
printf 'working %s %s\n'  "$now" "$srv" > "$STATE/hook-$(id api)"
printf 'waiting %s %s\n'  "$now" "$srv" > "$STATE/hook-$(id parser)"
printf 'idle %s %s\n'     "$now" "$srv" > "$STATE/hook-$(id docs)"
printf '%s docs\n' "$now" > "$STATE/finished"
printf '%s\nrefactor the token bucket so the limiter is testable without sleeping\n' "$now" \
    > "$STATE/last-$(id api)"; chmod 600 "$STATE/last-$(id api)"
printf '%s\nrun the full suite and tell me which failures are mine\n' "$now" \
    > "$STATE/last-$(id parser)"; chmod 600 "$STATE/last-$(id parser)"
