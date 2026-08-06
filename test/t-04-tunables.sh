#!/usr/bin/env bash
# Threshold & color wiring (T5) — do the four config keys (recent_hours, unseen_minutes, accent,
# log_max) **actually change behavior**, and does the "not wired" marker match the current wiring?
#
# What this file must guarantee:
#   ① Changing the value of any of the four keys changes the output. A query that only confirms
#      "it was saved to the config file" proves nothing — saved-but-nobody-reads-it is exactly the
#      problem this task eliminated.
#   ② A weird value in a hand-edited config file must not kill the control tower. The whitelist
#      parser only checks the value's character set, so values like `recent_hours=6h`, `accent=999`,
#      `08` pass through as-is. If that value flows into $(( … )), an arithmetic error plus set -e
#      would kill --list outright.
#   ③ The "not wired" marker is shown in both the popup and the CLI, the two agree, and it matches
#      the actual wiring.
#
# tmux is never actually run — a fake tmux sits at the front of PATH, and we only measure what
# passed through it.
set -u
. "$(dirname "$0")/lib.sh"
tt_test_sandbox

CONF="$XDG_CONFIG_HOME/fleetmux/config"
mkdir -p "$(dirname "$CONF")"
STATE="$HOME/.cache/tt"
mkdir -p "$STATE"
TAB=$'\t'
ESC=$'\033'

# ── ⛔ PATH guard — comes before any assertion in this file ──────────────────
# The lines below call the real `--list`, `--status`, `--cron`. If the code that sets up the fake
# tmux runs any later than this, that stretch would reach the developer machine's real tmux server
# (this repo has a kill-server incident in its history, so the order is pinned down here).
mkdir -p "$TTROOT/bin"
cat > "$TTROOT/bin/tmux" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TT_TMUX_LOG"
case "${1:-}" in
    ls)              [ -n "${TT_FAKE_LS:-}" ] && printf '%s\n' "$TT_FAKE_LS"; exit 0 ;;
    list-panes)      printf '%s\n' "${TT_FAKE_PANE:-claude}"; exit 0 ;;
    display-message) [ -n "${TT_FAKE_DISP:-}" ] && printf '%s\n' "$TT_FAKE_DISP"; exit 0 ;;
esac
exit 1
SHIM
chmod +x "$TTROOT/bin/tmux"
export TT_TMUX_LOG="$TTROOT/tmux-calls.log"
: > "$TT_TMUX_LOG"
export PATH="$TTROOT/bin:$PATH"

now=$(date +%s)

# Returns one --list row's "display part" (after the tab). Color codes are not stripped — this
# test's whole point is measuring exactly that color and weight.
list_row() {
    "$TTBIN" --list 2>/dev/null | grep -a "^$1$TAB" || true
}

# ── ① accent — the accent color's 256-color number ───────────────────────────
# --help is a surface visible even without tmux, so it's the cheapest evidence of color wiring.
printf 'accent=200\n' > "$CONF"
assert_contains "$("$TTBIN" --help 2>/dev/null)" "$ESC[38;5;200m" "accent is reflected in the --help color"
: > "$CONF"
assert_contains "$("$TTBIN" --help 2>/dev/null)" "$ESC[38;5;73m" "the default accent works the same way"

# --list's tool-session row uses the same color too (that's the real screen).
export TT_FAKE_LS="\$0${TAB}1000${TAB}0${TAB}-${TAB}alpha"
export TT_FAKE_PANE=bash          # neither claude nor codex → tool session (group 0)
rm -f "$STATE/hook-0"
printf 'accent=200\n' > "$CONF"
assert_contains "$(list_row alpha)" "$ESC[38;5;200m" "accent is reflected in the --list tool-session color"

# A hand-edited out-of-range value — this lands inside an escape sequence, so it must be filtered.
printf 'accent=999\n' > "$CONF"
assert_contains "$("$TTBIN" --help 2>/dev/null)" "$ESC[38;5;73m" "an out-of-range accent falls back to the default"
assert_contains "$("$TTBIN" --help 2>&1 >/dev/null)" "accent" "and states the reason in one line at that point"
assert_rc 0 "$TTBIN" --help
# The leading 0 is not octal — it must read as plain 73 (if this were bash arithmetic, it would die here).
printf 'accent=073\n' > "$CONF"
assert_contains "$("$TTBIN" --help 2>/dev/null)" "$ESC[38;5;73m" "a leading zero is still read as decimal"

# ── ② recent_hours — the threshold for showing a name in bold ────────────────
# Sets up one agent session in a "talked 2 hours ago" state. The hook file's pid 0 plus a recorded
# time later than the session's creation time = recognized as belonging to this session
# (tt_hook_valid ②).
export TT_FAKE_PANE=claude
printf 'idle %s 0\n' "$(( now - 7200 ))" > "$STATE/hook-0"

: > "$CONF"
row=$(list_row alpha)
case "$row" in *"$ESC[1m"*) got=bold ;; *"$ESC[2m"*) got=dim ;; *) got=none ;; esac
assert_eq "$got" "dim" "with the default recent_hours=1, a session from 2 hours ago is already dim"

printf 'recent_hours=6\n' > "$CONF"
row=$(list_row alpha)
case "$row" in *"$ESC[1m"*) got=bold ;; *"$ESC[2m"*) got=dim ;; *) got=none ;; esac
assert_eq "$got" "bold" "raising it to 6 brings the same session back to bold"

printf 'recent_hours=3\n' > "$CONF"
row=$(list_row alpha)
case "$row" in *"$ESC[1m"*) got=bold ;; *"$ESC[2m"*) got=dim ;; *) got=none ;; esac
assert_eq "$got" "bold" "with recent_hours=3 it goes bold again — the boundary moves with the value"

# A non-integer value folds to the default and the list still renders (no death from an arithmetic error).
printf 'recent_hours=6h\n' > "$CONF"
row=$(list_row alpha)
case "$row" in *"$ESC[1m"*) got=bold ;; *"$ESC[2m"*) got=dim ;; *) got=none ;; esac
assert_eq "$got" "dim" "a non-integer recent_hours folds to the default 1 — the 2-hour-old session dims"
assert_rc 0 "$TTBIN" --list
# The octal trap: `08` passes the character-set check but dies instantly in bash arithmetic.
printf 'recent_hours=08\n' > "$CONF"
assert_rc 0 "$TTBIN" --list
assert_contains "$(list_row alpha)" "$ESC[1m" "recent_hours=08 is read as 8 hours"

# ── ③ unseen_minutes — how long the status bar keeps the ✓ badge ─────────────
# Puts one "session that finished 6 min 40 sec ago" into the finished ledger. The session is alive
# (session_id comes back) and hasn't been attached to yet (last_attached=0 < ts) → the badge
# condition is elapsed time alone.
export TT_FAKE_DISP='$0|0'
fin_ts=$(( now - 400 ))
: > "$CONF"
printf '%s alpha\n' "$fin_ts" > "$STATE/finished"
assert_contains "$("$TTBIN" --status 2>/dev/null)" "✓alpha" "with the default unseen_minutes=10, a finish from 400 seconds ago is still visible"

printf 'unseen_minutes=5\n' > "$CONF"
printf '%s alpha\n' "$fin_ts" > "$STATE/finished"
out=$("$TTBIN" --status 2>/dev/null)
case "$out" in *✓alpha*) got=yes ;; *) got=no ;; esac
assert_eq "$got" "no" "with unseen_minutes=5, a finish from 400 seconds ago disappears from the status bar"
# Only the badge disappears — it must remain in the ledger (the contract is to keep it until someone attaches).
assert_contains "$(cat "$STATE/finished")" "alpha" "the finished record remains even after the badge turns off"
rm -f "$STATE/finished"

# ── ④ log_max — the hook-log rotation threshold ──────────────────────────────
# Rotation is triggered by --cron. With rc and snapshot turned off, every path from that entry
# point out to tmux is closed, so this assertion measures rotation alone.
mklog() { i=0; : > "$STATE/hook.log"; while [ "$i" -lt 300 ]; do printf 'line %s ----------\n' "$i" >> "$STATE/hook.log"; i=$((i + 1)); done; }

printf 'rc=off\nsnapshot=off\nlog_max=200\n' > "$CONF"
mklog
"$TTBIN" --cron >/dev/null 2>&1 || true
assert_contains "$(cat "$STATE/hook.log")" "rotated" "with log_max=200, the log rotates"

printf 'rc=off\nsnapshot=off\n' > "$CONF"      # default 1MB
mklog
"$TTBIN" --cron >/dev/null 2>&1 || true
case "$(cat "$STATE/hook.log")" in *rotated*) got=yes ;; *) got=no ;; esac
assert_eq "$got" "no" "with the default log_max, the same log does not rotate"

printf 'rc=off\nsnapshot=off\nlog_max=200\n' > "$CONF"
mklog
TT_LOG_MAX=1048576 "$TTBIN" --cron >/dev/null 2>&1 || true
case "$(cat "$STATE/hook.log")" in *rotated*) got=yes ;; *) got=no ;; esac
assert_eq "$got" "no" "the TT_LOG_MAX environment variable overrides the config file"
rm -f "$STATE/hook.log"

# And the lie that was the price of that backward compatibility is gone — 10-util.sh used to set
# the TT_LOG_MAX global itself, so the source always showed as env even when no real environment
# variable was set (which is why the toggle used to be rejected).
printf 'log_max=4096\n' > "$CONF"
assert_eq "$("$TTBIN" config get log_max)" "4096" "reads log_max from the config file"
assert_eq "$("$TTBIN" config source log_max)" "file" "and reports the source as file too"
assert_eq "$(TT_LOG_MAX=999 "$TTBIN" config get log_max)" "999" "the TT_LOG_MAX environment variable wins"
assert_eq "$(TT_LOG_MAX=999 "$TTBIN" config source log_max)" "env" "then the source is env"

# ── ⑤ Does the "not wired" marker match the actual wiring? ───────────────────
: > "$CONF"
cli=$("$TTBIN" config list)

# Wired keys — T4 (rc, snapshot, boot_restore) + T6 (the tmux snippet set) + T5 (this task's four).
# If this list should grow and doesn't, the screen lies. Conversely, if a marker is missing on a
# key that isn't wired yet, that's a lie too — so both directions are measured.
for k in rc snapshot boot_restore snapshot_on_exit key_summon key_summon_fast \
         recent_hours unseen_minutes accent log_max; do
    row=$(printf '%s\n' "$cli" | grep -a "^$k ")
    case "$row" in *"not wired"*) got=yes ;; *) got=no ;; esac
    assert_eq "$got" "no" "config list: $k is wired, so it shows no marker"
done
# The eight not yet wired — key rebinding (T7) doesn't exist yet.
for k in key_new key_rename key_kill key_reload key_detach key_broadcast key_help key_settings; do
    row=$(printf '%s\n' "$cli" | grep -a "^$k ")
    case "$row" in *"not wired"*) got=yes ;; *) got=no ;; esac
    assert_eq "$got" "yes" "config list: $k is not wired yet, so it carries a marker"
done
assert_eq "$(printf '%s\n' "$cli" | grep -c '← not wired')" "8" "exactly eight keys are currently not wired"
assert_contains "$cli" "value is saved but no code reads it yet" "explains what the marker means in one line below the table"

# It says so at the moment a value is actually changed too — someone who sets a value without ever
# looking at the list is the easiest to mislead.
: > "$CONF"
assert_contains "$("$TTBIN" config set key_new ctrl-y 2>&1)" "is not wired to any action yet" \
    "setting a not-wired key states that fact right there"
assert_eq "$("$TTBIN" config set key_new ctrl-y 2>/dev/null)" "key_new=ctrl-y" \
    "that notice goes to stderr only — stdout's key=value stays unchanged"
out=$("$TTBIN" config set accent 200 2>&1)
case "$out" in *"not wired"*) got=yes ;; *) got=no ;; esac
assert_eq "$got" "no" "setting a wired key adds no extra remark"
: > "$CONF"

# The popup settings screen and the CLI both draw their verdict from the same function — someone
# who only looks at one of them must not reach a different conclusion. Rather than hand-writing key
# names, this compares the two outputs against each other.
pop=$("$TTBIN" --config-list)
mismatch=""
for k in $(printf '%s\n' "$cli" | sed -n '2,$p' | awk '{ print $1 }'); do
    case "$k" in ''|"not"*) continue ;; esac
    a=no; b=no
    case "$(printf '%s\n' "$cli" | grep -a "^$k ")" in *"not wired"*) a=yes ;; esac
    case "$(printf '%s\n' "$pop" | grep -a "^$k$TAB")" in *"not wired"*) b=yes ;; esac
    [ "$a" = "$b" ] || mismatch="$mismatch $k"
done
assert_eq "$mismatch" "" "the CLI's and popup's not-wired verdicts agree key by key"

# Whether the marker is **pulled from code** rather than coincidental, and how it behaves when it
# can't get evidence. Feeding the script in via stdin makes its own absolute-path resolution
# collapse to the bash executable, so the scan finds nothing — a genuine zero-evidence situation.
# In that case it must show no marker at all: painting everything as "not wired" would be the far
# bigger lie.
out=$(bash -s -- config list < "$TTBIN" 2>/dev/null) || out=''
case "$out" in *"not wired"*) got=yes ;; *) got=no ;; esac
assert_eq "$got" "no" "when wiring evidence can't be obtained, no not-wired marker is attached at all"
assert_contains "$out" "key_new" "the table itself still renders normally"

# ── ⑥ The --help first screen states this machine's current config (gate B7) ─
# The installer sends teammates off with "fmux --help explains everything" at the end — it's the
# first screen read right after install. This used to hardcode Option+← and 6h/10 min here. The
# default binds no prefix-less key at all (key_summon_fast is empty), so that first line was
# **a lie teaching a key that doesn't exist**.
: > "$CONF"
h=$("$TTBIN" --help 2>/dev/null)
assert_eq "$(printf '%s' "$h" | grep -c 'Option+←' || true)" "0" "it doesn't teach a key that isn't bound"
# The help screen shows the fast summon key only — prefix + <key> still works and is still in
# `fmux config list`, but it is deliberately off this screen so the one keystroke that matters is
# not competing with a two-keystroke alternative.
assert_eq "$(printf '%s' "$h" | grep -c 'prefix + ' || true)" "0" \
    "★the help screen does not teach the prefix route — one summon key, stated once"
assert_contains "$h" "not set"             "says so when no prefix-less key is bound"
assert_contains "$h" "key_summon_fast"     "writes how to turn it on right there"
assert_contains "$h" "talked within 1h"    "reads and prints the default recent_hours"
assert_contains "$h" "or 10 min"           "reads and prints the default unseen_minutes"

printf 'key_summon=T\nkey_summon_fast=C-Left M-Left\nrecent_hours=3\nunseen_minutes=45\n' > "$CONF"
h=$("$TTBIN" --help 2>/dev/null)
assert_contains "$h" "C-Left M-Left"   "the changed key_summon_fast shows up on screen"
assert_eq "$(printf '%s' "$h" | grep -c 'not set' || true)" "0" "when a key is bound, it does not say there is none"
assert_contains "$h" "talked within 3h" "the changed recent_hours shows up on screen"
assert_contains "$h" "or 45 min"        "the changed unseen_minutes shows up on screen"
assert_eq "$(printf '%s' "$h" | grep -c 'talked within 6h' || true)" "0" "the old hardcoded value is not left behind"

# Must be honest even to someone who empties out every summon key
printf 'key_summon=\nkey_summon_fast=\n' > "$CONF"
h=$("$TTBIN" --help 2>/dev/null)
assert_contains "$h" "not set" "with every summon key emptied, the screen says so instead of showing a blank"
assert_contains "$h" "key_summon_fast" "and tells you the one command that fixes it"

# ── Seal check ────────────────────────────────────────────────────────────
# This file actually calls --list, --status, --cron. All of them passed through the sealed fake
# tmux, and not one of them should have been a state-mutating subcommand.
assert_no_tmux_mutation "every tmux call this file made was read-only"

tt_test_done
