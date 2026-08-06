#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
tt_test_sandbox

assert_eq "$(printf 'a')" "a" "assert_eq passes matching values"
assert_contains "hello world" "lo w" "assert_contains finds a substring"
assert_rc 0 true
assert_rc 1 false

# Also verify the failure path of assert_eq / assert_contains actually gets caught as a failure.
# Run it in a subshell so the deliberate failure does not pollute this file's real TT_FAIL.
_neg=$( ( TT_FAIL=0; assert_eq "a" "b" "deliberate mismatch"; printf 'TT_FAIL=%s' "$TT_FAIL" ) )
case "$_neg" in
    *FAIL*TT_FAIL=1*) printf '  ok   assert_eq catches a mismatch as a failure\n' ;;
    *) printf '  FAIL assert_eq did not catch a mismatch as a failure: %s\n' "$_neg"; TT_FAIL=$((TT_FAIL+1)) ;;
esac

_neg=$( ( TT_FAIL=0; assert_contains "hello world" "zzz" "deliberate mismatch"; printf 'TT_FAIL=%s' "$TT_FAIL" ) )
case "$_neg" in
    *FAIL*TT_FAIL=1*) printf '  ok   assert_contains catches a missing substring as a failure\n' ;;
    *) printf '  FAIL assert_contains did not catch a missing substring as a failure: %s\n' "$_neg"; TT_FAIL=$((TT_FAIL+1)) ;;
esac

# The sandbox's HOME must not be the real HOME
case "$HOME" in */fmux-test.*) printf '  ok   HOME is isolated\n' ;;
    *) printf '  FAIL HOME is not isolated: %s\n' "$HOME"; TT_FAIL=$((TT_FAIL+1)) ;;
esac

# tmux socket isolation — if $TMUX is set, a bare `tmux` call ignores TMUX_TMPDIR
# and attaches to the real server. Confirm tt_test_sandbox unset it.
if [ -z "${TMUX:-}" ]; then
    printf '  ok   TMUX is isolated (unset)\n'
else
    printf '  FAIL TMUX is still set: %s\n' "$TMUX"; TT_FAIL=$((TT_FAIL+1))
fi

# ── Sealed fake tmux ─────────────────────────────────────────────────────
# Socket isolation only decides "which server". The real tmux binary running at all is itself a
# hazard, so tt_test_sandbox puts a fake one first on PATH. Measure here that the seal actually held.
_which_tmux=$(command -v tmux 2>/dev/null || true)
case "$_which_tmux" in
    "$TT_TMUX_STUB_DIR/tmux") printf '  ok   the tmux on PATH is the sealed fake: %s\n' "$_which_tmux" ;;
    *) printf '  FAIL the tmux on PATH is not the fake: %s\n' "$_which_tmux"; TT_FAIL=$((TT_FAIL+1)) ;;
esac

# Read-only queries: only -V is answered.
assert_eq "$(tmux -V 2>/dev/null)" "tmux 3.5a" "the fake answers -V"
assert_rc 1 tmux ls
assert_contains "$(tmux ls 2>&1 >/dev/null)" "no server running" \
    "a read-only query gets the same answer as a machine with no server"

# Every state-mutating subcommand must be refused and logged.
# ⛔ This list measures "does the fake refuse when it receives these" — it never calls the real tmux.
for sub in new-session kill-session kill-server send-keys source-file \
           switch-client attach rename-session set-hook bind detach-client run-shell; do
    assert_rc 1 tmux "$sub" -t nope
done
_refused=$(wc -l < "$TT_TMUX_STUB_REFUSED" | tr -d ' ')
assert_eq "$_refused" "12" "all 12 refused subcommands landed in the log"
assert_contains "$(cat "$TT_TMUX_STUB_REFUSED")" "kill-server" "the refusal log records the arguments too"
assert_contains "$(cat "$TT_TMUX_STUB_LOG")" "kill-server -t nope" "it also lands in the full call log"

# And the helper that relies on that log actually catches a failure — right now it holds 12
# entries, so assert_no_tmux_mutation must FAIL (bite check).
_neg=$( ( TT_FAIL=0; assert_no_tmux_mutation "deliberate"; printf 'TT_FAIL=%s' "$TT_FAIL" ) )
case "$_neg" in
    *FAIL*TT_FAIL=1*) printf '  ok   assert_no_tmux_mutation catches the refusal log as a failure\n' ;;
    *) printf '  FAIL assert_no_tmux_mutation did not catch the refusal log: %s\n' "$_neg"; TT_FAIL=$((TT_FAIL+1)) ;;
esac
: > "$TT_TMUX_STUB_REFUSED"
assert_no_tmux_mutation "passes once cleared"

# tt_test_sandbox must set TTBIN (the Interfaces contract in the briefing) — this must hold even
# when this file is run standalone (`bash test/t-00-harness.sh`) without going through run.sh.
case "${TTBIN:-}" in
    */bin/fmux) printf '  ok   TTBIN is set: %s\n' "$TTBIN" ;;
    *) printf '  FAIL TTBIN is not set: %s\n' "${TTBIN:-}"; TT_FAIL=$((TT_FAIL+1)) ;;
esac

# A second call within the same process must be refused (so the first TTROOT does not leak).
if ( tt_test_sandbox ) >/dev/null 2>&1; then
    printf '  FAIL a repeat call to tt_test_sandbox was not refused\n'; TT_FAIL=$((TT_FAIL+1))
else
    printf '  ok   a repeat call to tt_test_sandbox is refused\n'
fi

tt_test_done
