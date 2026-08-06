#!/usr/bin/env bash
# --hook receiver — the waiting (approval-pending) verdict, and the fact that "the hook updates
# the manifest".
#
# Two things this file guards:
#   ① The branch verdict on a Notification payload is **case-insensitive**. Skip the lowercase
#      fold and "Claude is WAITING FOR YOUR INPUT" (plain idle) leaks into waiting, and an absent
#      fleet's urgent signal becomes indistinguishable from a session that is simply idle. Folding
#      case with bash4 syntax kills the whole process on macOS — that side is blocked by syntax in
#      t-14 (gate B6).
#   ② Even when snapshot=off, **the hook path still keeps the manifest updated**. This is the spot
#      that disproved the README's claim that "when snapshot=off the manifest stops updating and
#      goes stale" (gate B9) — the doc has since been rewritten to match actual behavior, and this
#      pins down the evidence for that sentence.
#
# ⛔ tmux is fully intercepted by the fake at the front of PATH. The real binary is never reached.
set -u
. "$(dirname "$0")/lib.sh"
tt_test_sandbox

STATE="$HOME/.cache/tt"
CONF="$XDG_CONFIG_HOME/fleetmux/config"
mkdir -p "$(dirname "$CONF")" "$STATE"
TAB=$'\t'

# ── ⛔ PATH guard — stands before any assertion ─────────────────────────────
mkdir -p "$TTROOT/bin"
cat > "$TTROOT/bin/tmux" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TT_TMUX_LOG"
case "${1:-}" in
    display-message) printf '%s\n' "$TT_FAKE_DISP" ;;
esac
exit 0
SHIM
chmod +x "$TTROOT/bin/tmux"
export TT_TMUX_LOG="$TTROOT/tmux-calls.log"
: > "$TT_TMUX_LOG"
export PATH="$TTROOT/bin:$PATH"
export TMUX_PANE='%9'
export TT_FAKE_DISP="\$9${TAB}zzhooktest${TAB}$HOME${TAB}claude${TAB}1"
HF="$STATE/hook-9"

hook() {   # $1=state  $2=payload (empty stdin if omitted)
    printf '%s' "${2:-}" | "$TTBIN" --hook "$1" >/dev/null 2>&1 || true
}
state_of() { cut -d' ' -f1 "$HF" 2>/dev/null || true; }

# ── ① Approval-pending verdict ───────────────────────────────────────────────
rm -f "$HF"
hook waiting '{"hook_event_name":"Notification","message":"Claude needs your permission to use Bash"}'
assert_eq "$(state_of)" "waiting" "a permission-request notification is caught as waiting"

rm -f "$HF"
hook waiting '{"hook_event_name":"Notification","message":"Claude is waiting for your input"}'
assert_eq "$(state_of)" "" "a plain idle notification is not waiting"

# This is the bite of the lowercase fold — drop the fold and the same sentence becomes waiting
# purely because it is uppercase.
rm -f "$HF"
hook waiting '{"hook_event_name":"Notification","message":"Claude Is WAITING FOR YOUR INPUT"}'
assert_eq "$(state_of)" "" "plain idle in uppercase is still not waiting"

rm -f "$HF"
hook waiting '{"message":"CLAUDE NEEDS YOUR PERMISSION TO USE BASH"}'
assert_eq "$(state_of)" "waiting" "a permission request in uppercase is still caught as waiting"

# With no evidence at all (empty stdin), do not make a verdict — the same conservative behavior as before
rm -f "$HF"
hook waiting ''
assert_eq "$(state_of)" "" "no payload means it is not marked waiting"

# codex has the event itself be the approval request, so it does not look at the payload
rm -f "$HF"
hook waiting-codex ''
assert_eq "$(state_of)" "waiting" "codex's PermissionRequest is itself waiting"

# ── ② working/idle ─────────────────────────────────────────────────────────
hook working '{}'
assert_eq "$(state_of)" "working" "the working hook writes the state"
hook idle '{}'
assert_eq "$(state_of)" "idle" "the idle hook writes the state"

# ── ③ the hook keeps updating the manifest even with snapshot=off (gate B9) ────
printf 'snapshot=off\n' > "$CONF"
rm -f "$STATE/manifest"
out=$("$TTBIN" --snapshot 2>&1) || true
assert_contains "$out" "snapshot=off" "the switch is off — --snapshot actually refuses"
assert_rc 1 test -f "$STATE/manifest"

hook working '{"session_id":"7f3b1c22-0000-4000-8000-0123456789ab","cwd":"'"$HOME"'"}'
assert_rc 0 test -f "$STATE/manifest"
assert_contains "$(cat "$STATE/manifest")" "zzhooktest" \
    "even with snapshot=off, the hook path writes a line into the manifest — it never goes stale"
assert_contains "$(cat "$STATE/manifest")" "7f3b1c22-0000-4000-8000-0123456789ab" \
    "the conversation id the hook picked up lands in it too"

# And that update keeps happening (it is not a one-time thing) — change cwd and hook again
before=$(cat "$STATE/manifest")
export TT_FAKE_DISP="\$9${TAB}zzhooktest${TAB}$HOME/moved${TAB}claude${TAB}1"
mkdir -p "$HOME/moved"
hook working '{"session_id":"7f3b1c22-0000-4000-8000-0123456789ab","cwd":"'"$HOME"'"}'
assert_contains "$(cat "$STATE/manifest")" "$HOME/moved" "it is rewritten on every hook call"
assert_eq "$(printf '%s' "$before" | grep -c '/moved' || true)" "0" "that value was not there before"

assert_no_tmux_mutation "the hook path did not touch a live server"

tt_test_done
