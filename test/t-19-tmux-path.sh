#!/usr/bin/env bash
# Finding tmux — and saying so when it cannot be found.
#
# Why this test exists: a teammate's popup opened and drew an **empty session list** on a Mac that
# had sessions (2026-08-14). Nothing was printed, no log line was written. The cause was that
# `tmux` was not on PATH inside the popup: a popup inherits the tmux **server's** environment, and
# a server started straight from a terminal app never read the shell rc that adds a Homebrew
# prefix. Every tmux call died with 127, and the list path discarded stderr — so "I could not ask"
# and "there is nothing to show" drew the same screen.
#
# This is the second time the same class landed. The first was fzf, three days earlier
# (2026-08-11), and that fix was written for fzf by name — which is exactly why this one got
# through. The class is "the PATH fmux runs with is not the PATH you have"; naming it "fzf is
# missing" fixes one member and leaves the rest.
#
# So two things are pinned here, and they are different things:
#   ① fmux repairs its own PATH — it can read the tmux binary's path back off the running server,
#     so the reported case needs no configuration at all
#   ② when it genuinely cannot, it says so. An empty list must never again be the way a failure
#     to ask is rendered.
#
# The resolver is sliced out of bin/fmux and evaluated, the way t-03 does it: PATH repair does not
# leave the process, so the only way to observe it is from inside one. Sliced from bin/fmux and
# never src/, so a tree that is fixed but not rebuilt fails here.
set -u
. "$(dirname "$0")/lib.sh"
fmux_test_sandbox

BIN="$FMUXROOT/fake"; mkdir -p "$BIN"
# A stand-in for the tmux binary. Nothing runs it — every check below is `[ -x ]` — but it has to
# be a real executable file for that check to mean anything.
FAKE="$BIN/tmux"; printf '#!/bin/sh\nexit 0\n' > "$FAKE"; chmod +x "$FAKE"

PROC="$FMUXROOT/proc"; mkdir -p "$PROC/4242"
ln -s "$FAKE" "$PROC/4242/exe"

# Every shell below is started with an absolute path. These runs set PATH to a directory that
# holds no tmux, and `env PATH=… bash` would resolve `bash` through that same new PATH and never
# start at all — the failure looks identical to the assertion failing.
BASHBIN=$(command -v bash)

# A PATH that is complete except for tmux. That is the environment being reproduced — a popup
# whose PATH has everything a shell needs and no Homebrew prefix — and it cannot be faked by
# emptying PATH, because fmux needs date/ps/sed/grep to reach the code under test at all.
PUREBIN="$FMUXROOT/purebin"; mkdir -p "$PUREBIN"
for _f in /usr/bin/* /bin/*; do
    case "${_f##*/}" in tmux) continue ;; esac
    [ -e "$PUREBIN/${_f##*/}" ] || ln -s "$_f" "$PUREBIN/" 2>/dev/null || true
done
# If this machine's tmux does not live in /usr/bin, the loop above would have copied it in from
# somewhere else on PATH. Assert the premise instead of trusting it: a test that silently stops
# reproducing the bug is worse than one that fails.
if PATH="$PUREBIN" command -v tmux >/dev/null 2>&1; then
    printf '  FAIL could not build a tmux-free PATH — the popup assertions below would be vacuous\n'
    exit 1
fi

# ── the resolver, in a shell we control completely ──────────────────────────
# fmux_conf_load/fmux_conf_get are stubbed rather than sliced: what is under test is the ladder,
# not the config parser (t-02 owns that). The stub also records that it was **asked**, which is
# how the "costs nothing when things are normal" assertion below is made.
resolve() {              # resolve <env assignments…> → "<rc>|<FMUX_TMUX_OK>|<what command -v finds>"
    local blk
    blk=$(sed -n '/^# The absolute path of a running process/,/^fmux_ensure_tmux || FMUX_TMUX_OK=0$/p' "$FMUXBIN")
    [ -n "$blk" ] || { echo "BLOCK-NOT-FOUND"; return; }
    env -u TMUX "$@" "$BASHBIN" -c '
        fmux_conf_load() { :; }
        fmux_conf_get()  { printf asked >> "$ASKED"; printf %s "${STUB_CONF_TMUX_PATH:-}"; }
        '"$blk"'
        printf "%s|%s|%s" "$?" "$FMUX_TMUX_OK" "$(command -v tmux || printf none)"
    '
}

ASKED="$FMUXROOT/asked"; : > "$ASKED"
export ASKED

# ① the config override — an absolute path, immune to whatever any startup file did.
: > "$ASKED"
got=$(resolve "PATH=$PUREBIN" "ASKED=$ASKED" "STUB_CONF_TMUX_PATH=$FAKE" "FMUX_TMUX_PROBE=")
assert_eq "${got##*|}" "$FAKE" "a configured tmux_path is put on PATH"
assert_eq "${got#*|}" "1|$FAKE" "and the run is marked usable"

# ①' recorded, not trusted. install.sh writes this key at install time, so it long outlives the
# path it names — a tmux that moved must not be able to brick the popup. It falls through instead.
: > "$ASKED"
got=$(resolve "PATH=$PUREBIN" "ASKED=$ASKED" "STUB_CONF_TMUX_PATH=$FMUXROOT/gone/tmux" \
              "FMUX_TMUX_PROBE=$FAKE")
assert_eq "${got##*|}" "$FAKE" "a stale tmux_path is skipped, not obeyed — the search goes on"

# ② the reported case, and the one that needs no configuration: read the path back off the server
#    we are already running inside. $TMUX is "<socket>,<server pid>,<session index>", and that pid
#    is a tmux binary by definition. The probe is emptied so nothing else can be credited.
: > "$ASKED"
got=$(resolve "PATH=$PUREBIN" "ASKED=$ASKED" "FMUX_PROC=$PROC" "FMUX_TMUX_PROBE=" \
              "TMUX=/tmp/sock,4242,0")
assert_eq "${got##*|}" "$FAKE" "★the popup case: tmux is found through the server pid in \$TMUX, with no config at all"

# A $TMUX that is not shaped like one must not be believed. tmux writes it, but a stale export can
# survive into a shell that is not inside tmux at all.
: > "$ASKED"
got=$(resolve "PATH=$PUREBIN" "ASKED=$ASKED" "FMUX_PROC=$PROC" "FMUX_TMUX_PROBE=" \
              "TMUX=/tmp/sock,notapid,0")
assert_eq "${got##*|}" "none" "a \$TMUX whose pid field is not a number is ignored, not fed to readlink"

# ③ the prefix list — this is the cron case, where there is no $TMUX to read and cron has handed
#    over /usr/bin:/bin and nothing else.
: > "$ASKED"
got=$(resolve "PATH=$PUREBIN" "ASKED=$ASKED" "FMUX_TMUX_PROBE=$FMUXROOT/gone/tmux $FAKE")
assert_eq "${got##*|}" "$FAKE" "the prefix probe finds it when there is no \$TMUX — the cron case"

# ④ nothing worked. The point is that this is *reported*, not that it is impossible.
: > "$ASKED"
got=$(resolve "PATH=$PUREBIN" "ASKED=$ASKED" "FMUX_TMUX_PROBE=")
assert_eq "${got%%|*}" "0" "the load-time call never fails the process — fmux config and --help still run"
assert_eq "$(printf '%s' "$got" | cut -d'|' -f2)" "0" "★but it is marked unusable, which is what the popup reads"

# ⑤ the normal case costs nothing. This runs on every hook event and every cron minute, so if the
#    config file were parsed here it would be parsed a few thousand times a day for nothing.
: > "$ASKED"
got=$(resolve "PATH=$BIN" "ASKED=$ASKED" "FMUX_PROC=$PROC" "FMUX_TMUX_PROBE=")
assert_eq "${got##*|}" "$FAKE" "when tmux is already on PATH it is simply used"
assert_eq "$(cat "$ASKED")" "" "★and nothing else is consulted — no config read, no probe, no ps"

# ── fmux_exe_of only answers with an absolute path ──────────────────────────
# Linux ps hands back a bare "tmux" for -o comm=; macOS hands back the full path. Accepting the
# bare name would send the caller back to the PATH that already failed it, and `[ -x tmux ]` is
# false anyway — so the failure would be silent and one step further away from its cause.
exe_of() {               # exe_of <pid> [FMUX_PROC] → what fmux_exe_of prints, or "rc1"
    local blk
    blk=$(sed -n '/^# The absolute path of a running process/,/^}$/p' "$FMUXBIN")
    env "FMUX_PROC=${2:-/nonexistent}" "$BASHBIN" -c "$blk"'; fmux_exe_of "$1" || printf rc1' _ "$1"
}
assert_eq "$(exe_of 4242 "$PROC")" "$FAKE" "on Linux the answer comes from /proc/<pid>/exe"
assert_eq "$(exe_of $$)" "rc1" "a bare process name (what Linux ps gives) is refused, not returned"
assert_eq "$(exe_of 0)" "rc1" "an unknown pid is refused"

# ── --list: "I could not ask" is not "there is nothing" ─────────────────────
# The regression itself. `tmux ls` was piped straight into the loop, so its exit code was gone
# before anyone could look at it, and every way of failing rendered as an empty list.
LSBIN="$FMUXROOT/lsbin"; mkdir -p "$LSBIN"
cat > "$LSBIN/tmux" <<'SHIM'
#!/usr/bin/env bash
case "${1:-}" in
    ls|list-sessions) exit "${FAKE_LS_RC:-1}" ;;
    -V) printf 'tmux 3.5a\n'; exit 0 ;;
esac
exit 1
SHIM
chmod +x "$LSBIN/tmux"

list_with() {            # list_with <rc tmux ls exits with> → "<rc>|<everything printed>"
    local out rc=0
    out=$(FAKE_LS_RC="$1" PATH="$LSBIN:$PATH" "$FMUXBIN" --list 2>&1) || rc=$?
    printf '%s|%s' "$rc" "$out"
}

got=$(list_with 127)
assert_eq "${got%%|*}" "127" "★a tmux that cannot be run exits --list non-zero — it no longer passes for an empty fleet"
assert_contains "${got#*|}" "not on PATH" "and it says which thing could not be found"
assert_contains "${got#*|}" "tmux_path" "and names the one setting that fixes it"

# The other half, and the one that would break every day if it regressed: no server running is an
# ordinary state, not a failure. It has to stay quiet and stay empty.
got=$(list_with 1)
assert_eq "${got%%|*}" "0" "no tmux server is still an ordinary empty list, rc 0"
assert_eq "${got#*|}" "" "and it prints nothing at all"

# rc 0 with no output is the third case: a live server with zero sessions. The value is captured
# into a variable now, and `printf '%s\n' ""` would emit one blank line — which the loop would
# read as a session whose every field is empty.
got=$(list_with 0)
assert_eq "${got%%|*}" "0" "a live server with no sessions is rc 0"
assert_eq "${got#*|}" "" "★and prints no phantom blank row"

# ── the popup explains itself instead of drawing an empty list ──────────────
# The whole reported symptom was that this screen was blank. It is driven with a PATH that has
# everything except tmux — the popup's actual situation on that Mac.
#
# FMUX_TTY=off is what makes it assertable at all. The message is followed by a hold-open read
# (a popup is torn down the instant the command returns, so an unheld message is never seen), and
# a suite run from a terminal can open /dev/tty — without the switch this would sit waiting for a
# keypress instead of passing or failing. That is why the fzf branch next to it went untested.
popup_rc=0
popup=$(env -u TMUX "PATH=$PUREBIN" "FMUX_TMUX_PROBE=" "FMUX_TTY=off" \
        "$FMUXBIN" --from probe-session </dev/null 2>&1) || popup_rc=$?
assert_contains "$popup" "tmux is not on PATH" "★the popup names the cause instead of drawing an empty list"
assert_contains "$popup" "tmux_path" "and gives the setting that fixes it"
assert_eq "$popup_rc" "1" "and refuses, rather than opening on an empty list"

# The other side of that switch, and the reason it is safe to have: with no one to press a key,
# nothing waits. A hold that ignored this would hang the suite rather than fail it — and would
# hang cron and any script driving fmux exactly the same way.
case "$popup" in
    *"Press any key"*)
        FMUX_RUN=$((FMUX_RUN + 1)); FMUX_FAIL=$((FMUX_FAIL + 1))
        printf '  FAIL nothing holds the screen when no one is there to read it\n' ;;
    *)  FMUX_RUN=$((FMUX_RUN + 1))
        printf '  ok   nothing holds the screen when no one is there to read it\n' ;;
esac

fmux_test_done
