#!/usr/bin/env bash
# rc · snapshot · boot_restore switches.
#
# What this test has to protect is not just one thing — "turned off, it succeeds quietly." It is
# four:
#   ① off — ends with rc 0, states the reason in one stdout line, and never calls tmux at all.
#   ② on — calls tmux exactly as before (the switch did not kill the feature).
#   ③ even with rc=off, --cron's --snapshot survives (turning it off with exit 0 would get caught
#     here).
#   ④ on, end-to-end — passes the switch and an actual line lands in the manifest (manifest).
#
# All of it is measured with a "fake tmux": a bash script named tmux is placed at the front of
# PATH that
#   (a) records each call, one line at a time, and (b) only answers ls and display-message, faking
#   one session.
# The real tmux binary is never executed in this file, not even once. This is discipline, not
# convenience — the old version of this test spun up a real server to measure ④ and set a
# `tmux kill-server` trap at the end; if socket isolation (TMUX_TMPDIR) leaked even once, that one
# line would kill the developer's live fleet entirely. That incident actually happened. The fake
# tmux even records how many times it was called and with what arguments, so it is more thorough,
# not less. End-to-end against a real tmux server is left out of this suite's scope (a manual
# check).
set -u
. "$(dirname "$0")/lib.sh"
fmux_test_sandbox

CONF="$XDG_CONFIG_HOME/fleetmux/config"
mkdir -p "$(dirname "$CONF")"
STATE="$HOME/.cache/fmux"

# ── fake tmux ────────────────────────────────────────────────────────────────
# Record + minimal response. Unknown subcommands answer with rc 1 (same as real tmux with no
# server).
#   If list-panes comes back empty, rc_target fails and the rc round never reaches send-keys —
#   meaning under this shim, recovery injection never fires (not even the sleep 8).
mkdir -p "$FMUXROOT/bin"
cat > "$FMUXROOT/bin/tmux" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FMUX_TMUX_LOG"
case "$1" in
    ls)
        # The -F format's delimiter differs by entry point (rc=space, snapshot=tab) — mimic it exactly.
        case "$*" in
            *"#{session_id}"$'\t'"#{session_name}"*) printf '$1\tfmuxsw1\n' ;;
            *)                                       printf '$1 fmuxsw1\n' ;;
        esac ;;
    display-message) printf '%s\t%s\n' "$HOME" bash ;;
    *) exit 1 ;;
esac
SHIM
chmod +x "$FMUXROOT/bin/tmux"
export FMUX_TMUX_LOG="$FMUXROOT/tmux-calls.log"
: > "$FMUX_TMUX_LOG"
# The two entry points' tmux ls calls use different format strings — distinguishable in the log.
RC_CALL='ls -F #{session_id} #{session_name}'                 # 60-rc.sh's rc round (space)
SNAP_CALL="ls -F #{session_id}"$'\t'"#{session_name}"         # 70-fleet.sh's snapshot (tab)
export PATH="$FMUXROOT/bin:$PATH"

# Was that call in the log — assert_contains cannot measure "absence," so a dedicated
# absence-only helper is added here
seen_call() { case "$(cat "$FMUX_TMUX_LOG")" in *"$1"*) echo yes ;; *) echo no ;; esac; }

# ── ① everything off ─────────────────────────────────────────────────────────
printf 'rc=off\nsnapshot=off\nboot_restore=off\n' > "$CONF"

assert_rc 0 "$FMUXBIN" --cron
assert_rc 0 "$FMUXBIN" --rc
assert_rc 0 "$FMUXBIN" --boot-restore --dry

out=$("$FMUXBIN" --snapshot 2>&1) || true
assert_contains "$out" "snapshot=off" "if snapshot is off, it says so"
out=$("$FMUXBIN" --rc 2>&1) || true
assert_contains "$out" "rc=off" "if rc is off, it says so"
out=$("$FMUXBIN" --boot-restore --dry 2>&1) || true
assert_contains "$out" "boot_restore=off" "if boot restore is off, it says so"
assert_contains "$(cat "$STATE/boot.log" 2>/dev/null || true)" "boot_restore=off in config" \
    "the reason boot restore was skipped is also recorded in boot.log"

# does not create a manifest when off
assert_rc 1 test -f "$STATE/manifest"
# cron runs every minute — a swallowed spot must not print even one line, or cron mail piles up
assert_eq "$("$FMUXBIN" --cron 2>/dev/null)" "" "the cron path stays silent when redirected"
# and here is the key part: an off entry point never calls tmux, not even once (the early return
#   comes before the first tmux call). meaning it does not call tmux even though a session exists —
#   the shim above always answers with one session, as long as it is asked.
assert_eq "$(cat "$FMUX_TMUX_LOG")" "" "when everything is off, tmux is never called once"

# ── ② everything on — calls tmux as before ──────────────────────────────────
: > "$FMUX_TMUX_LOG"
printf 'rc=on\nsnapshot=on\n' > "$CONF"
"$FMUXBIN" --cron >/dev/null 2>&1 || true
log=$(cat "$FMUX_TMUX_LOG")
assert_contains "$log" "$RC_CALL"   "if rc=on, --cron runs the rc round"
assert_contains "$log" "$SNAP_CALL" "if snapshot=on, --cron also calls the snapshot"

: > "$FMUX_TMUX_LOG"
assert_contains "$("$FMUXBIN" --rc 2>&1)" "SESSION" "if rc=on, --rc draws the status table"
assert_contains "$(cat "$FMUX_TMUX_LOG")" "$RC_CALL" "if rc=on, --rc goes to tmux to draw the status table"

: > "$FMUX_TMUX_LOG"
"$FMUXBIN" --snapshot >/dev/null 2>&1 || true
assert_contains "$(cat "$FMUX_TMUX_LOG")" "$SNAP_CALL" "if snapshot=on, --snapshot scans the sessions"

rm -f "$STATE/boot.log"
printf 'boot_restore=on\n' > "$CONF"
FMUX_BOOT_NETWAIT=0 FMUX_BOOT_NETHOST=fmux-nonexistent.invalid \
    "$FMUXBIN" --boot-restore --dry >/dev/null 2>&1 || true
assert_contains "$(cat "$STATE/boot.log" 2>/dev/null || true)" "no DNS+tcp/443" \
    "if boot_restore=on, it passes the switch and goes all the way to the real boot procedure (network wait)"

# ── ③ only rc is off — the snapshot must survive ────────────────────────────
# if rc is turned off with exit 0, the snapshot vanishes entirely from one --cron tick. caught here.
: > "$FMUX_TMUX_LOG"
printf 'rc=off\nsnapshot=on\n' > "$CONF"
"$FMUXBIN" --cron >/dev/null 2>&1 || true
assert_contains "$(cat "$FMUX_TMUX_LOG")" "$SNAP_CALL" "even with rc=off, --cron still calls the snapshot"
assert_eq "$(seen_call "$RC_CALL")" "no" "with rc=off, the rc round of --cron does not call tmux"

# the flip side — only snapshot is off: the rc round survives and there is no snapshot fork
: > "$FMUX_TMUX_LOG"
printf 'rc=on\nsnapshot=off\n' > "$CONF"
"$FMUXBIN" --cron >/dev/null 2>&1 || true
assert_contains "$(cat "$FMUX_TMUX_LOG")" "$RC_CALL" "even with snapshot=off, the rc round runs"
assert_eq "$(seen_call "$SNAP_CALL")" "no" "with snapshot=off, --cron does not call the snapshot"

# environment variables also work as switches (for one-off experiments — env beats the file)
: > "$FMUX_TMUX_LOG"
printf 'rc=on\nsnapshot=on\n' > "$CONF"
FMUX_RC=off FMUX_SNAPSHOT=off "$FMUXBIN" --cron >/dev/null 2>&1 || true
assert_eq "$(cat "$FMUX_TMUX_LOG")" "" "FMUX_RC=off FMUX_SNAPSHOT=off beats the on in the file"

# ── ③-b a warning for a broken line appears only once per entry point ──────
# If fmux_conf_on is used alone without calling fmux_conf_load as the top-level statement,
# fmux_conf_on forks internally with `$(fmux_conf_get …)`, so the same warning fires again for
# each lookup. --cron looks up both rc and snapshot — breaking the contract turns this into 2.
cat > "$CONF" <<'EOF'
rc=on
snapshot=on
unknown_key=1
EOF
_warn=$("$FMUXBIN" --cron 2>&1 >/dev/null)
_count=$(printf '%s\n' "$_warn" | grep -c "unknown key: unknown_key")
assert_eq "$_count" "1" "--cron looks up the config twice, but the warning appears only once"

# ── ④ on, end-to-end — passes the switch all the way to the manifest ───────
# ①-③ only measure "was tmux called." If the switch let the tmux call through but broke the
# logic after it, that would not get caught there → nail it down once more with the artifact
# (manifest).
rm -f "$STATE/manifest"
printf 'snapshot=on\n' > "$CONF"
out=$("$FMUXBIN" --snapshot 2>&1) || true
assert_contains "$out" "fmuxsw1" "if snapshot=on, it records the live session"
assert_contains "$out" "snapshot: 1 sessions" "when on, it prints the summary line exactly as before"
assert_contains "$(cat "$STATE/manifest" 2>/dev/null || true)" "fmuxsw1" "a line lands in the manifest"

# and when off, it no longer touches that manifest (the file stays put even if a new session appears)
before=$(cat "$STATE/manifest")
printf 'snapshot=off\n' > "$CONF"
"$FMUXBIN" --snapshot >/dev/null 2>&1 || true
assert_eq "$(cat "$STATE/manifest")" "$before" "when off, it does not touch the manifest"

# the end-to-end version of rule ①: even with rc off, one cron tick still rewrites the manifest
printf 'rc=off\nsnapshot=on\n' > "$CONF"
rm -f "$STATE/manifest"
"$FMUXBIN" --cron >/dev/null 2>&1 || true
assert_contains "$(cat "$STATE/manifest" 2>/dev/null || true)" "fmuxsw1" \
    "even with rc=off, one --cron tick rewrites the manifest"

# ── --from with an unexpanded format ────────────────────────────────────────
# The popup is bound as `display-popup … fmux --from '#S'`, and **display-popup does not expand
# formats in its shell-command** (measured 2026-08-10 with a probe bound exactly like the
# installed snippet: the argument arrived as the two characters `#S`). The title, -T, *is*
# expanded, which is why the popup is labelled correctly and this went unnoticed for months.
#
# A literal `#S` is worse than no argument. It filled CUR, so the `-z "$CUR"` guard skipped the
# fallback that asks tmux directly, and FMUX_CUR came out as `#S` — a name no session has, so the
# session you were sitting in was never excluded from its own list. The fix drops any value still
# holding a format placeholder, which hands the job back to the fallback.
#
# FMUX_CUR is the entire observable effect (80-view.sh:201 reads it and nothing else does), so the
# assertion has to see that variable. The list path exports it and then execs fzf, so instead of
# running the whole binary this pulls the eight-line block out of the artifact and evaluates it —
# from bin/fmux, never src/, so a "fixed but not rebuilt" tree fails here.
cur_for() {              # cur_for <args…> → the FMUX_CUR that block would export
    local blk
    blk=$(sed -n '/^# Exclude the current session from the list/,/^export FMUX_CUR/p' "$FMUXBIN")
    [ -n "$blk" ] || { echo "BLOCK-NOT-FOUND"; return; }
    env -u TMUX bash -c "$blk"'; printf %s "$FMUX_CUR"' _ "$@"
}

assert_eq "$(cur_for --from '#S')" "" \
    "a literal '#S' — display-popup does not expand formats — is discarded, not used as a name"
assert_eq "$(cur_for --from '#{session_name}')" "" \
    "any unexpanded format is discarded, not just #S"
assert_eq "$(cur_for --from 'worker-1')" "worker-1" \
    "a real session name passed by --from is kept"
assert_eq "$(cur_for)" "" \
    "no --from and no tmux: FMUX_CUR is empty, so nothing is excluded"

fmux_test_done
