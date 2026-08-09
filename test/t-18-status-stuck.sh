#!/usr/bin/env bash
# --status counting — the anti-stuck guards on ✻ and ⏸.
#
# Why this test exists: the status bar used to count a `working` hook forever, as long as the
# hook's pid was alive. That is fine while the agent keeps firing hooks, and it is what stops the
# badge from flickering — a claude waiting on a tool-call response dips below the CPU threshold in
# roughly a quarter of 3-second windows, so subtracting on one window would blink the ✻ of a
# genuinely working session.
#
# It stopped being fine when a turn never ran. Measured in real use (2026-08-09): a prompt was
# submitted to a session and the turn never started, so `UserPromptSubmit` had already written
# `working` and `Stop` never came. `fmux --list`, which has a three-tier anti-stuck guard, showed
# the session correctly with no mark. `fmux --status` held ✻ for it indefinitely. A status bar that
# disagrees with the popup is the one failure this tool cannot afford: the whole claim is that you
# do not have to open anything to trust the badge.
#
# So the guard is asymmetric on purpose, and both halves are pinned here:
#   · a **fresh** hook is counted with no CPU question asked (the flicker guarantee), and
#   · a **stale** hook is dropped only on a *definite* idle verdict — rc 2 (cannot tell) keeps
#     counting, so a session with no sample yet never vanishes from the badge.
# The second half is the one that rots quietly: the day rc 2 starts being read as "idle", every
# freshly started agent disappears from the status bar and nothing here would notice unless it is
# asserted directly.
#
# ⛔ tmux is the sealed stub from lib.sh — it answers every read-only subcommand the way a machine
#    with no server does. /proc is faked through FMUX_PROC, so this gives the same answer on macOS
#    and on a machine whose CPU is pegged.
set -u
. "$(dirname "$0")/lib.sh"
fmux_test_sandbox

STATE="$HOME/.cache/fmux"; mkdir -p "$STATE"
PROC="$FMUXROOT/proc"; export FMUX_PROC="$PROC"

# Same shape as t-09's fake — comm deliberately contains a space and ') ' so a parser that does not
# cut on the right-side longest match lands on the wrong fields.
fake_proc() {                # fake_proc <pid> <utime> <stime>
    mkdir -p "$PROC/$1"
    printf '%s (cl) aude (x)) S 1 %s %s 0 -1 4194304 111 222 0 0 %s %s 0 0 20 0 12 0 999 0 0\n' \
        "$1" "$1" "$1" "$2" "$3" > "$PROC/$1/stat"
}

# The hook pid has to pass a real `kill -0`, so it must be a real live process. This shell is the
# one process guaranteed to outlive every assertion below.
PID=$$
fake_proc "$PID" 1000 0        # 1000 cs of CPU consumed so far

NOW=$(date +%s)
FRESH=$(( NOW - 10 ))          # well inside FMUX_STUCK_AFTER (180s)
STALE=$(( NOW - 600 ))         # well outside it

reset() { rm -f "$STATE"/hook-* "$STATE"/cpu-* "$STATE"/finished; }
hook()  { printf '%s %s %s\n' "$1" "$2" "$PID" > "$STATE/hook-s1"; }
# cpu-<sid> layout: <pid> <ts1> <cs1> <ts2> <cs2>. A 10-second window sits inside MINWIN..MAXWIN,
# so cs1 alone decides the verdict against the 1000 cs in the fake /proc.
cpu_idle() { printf '%s %s 1000 0 0\n' "$PID" "$(( NOW - 10 ))" > "$STATE/cpu-s1"; }   # d=0    → rc 1
cpu_busy() { printf '%s %s 0 0 0\n'    "$PID" "$(( NOW - 10 ))" > "$STATE/cpu-s1"; }   # d=1000 → rc 0
marks()  { "$FMUXBIN" --status 2>/dev/null | grep -o '✻[0-9]*' | head -1; }

# ── ① The flicker guarantee ────────────────────────────────────────────────
# A fresh hook must be counted even when CPU is certain the process is idle. This is the assertion
# that stops someone from "simplifying" the guard into a plain CPU check.
reset; hook working "$FRESH"; cpu_idle
assert_eq "$(marks)" "✻1" 'a fresh working hook is counted even when CPU says definitely idle'

# ── ② The bug this guard was added for ─────────────────────────────────────
reset; hook working "$STALE"; cpu_idle
assert_eq "$(marks)" "" 'a working hook silent past FMUX_STUCK_AFTER is dropped once CPU is certain it is idle'

# ── ③ Still working, just quiet ────────────────────────────────────────────
# A single long tool call fires no hooks, so the hook goes stale while the session genuinely works.
# CPU is the witness that keeps it on the badge.
reset; hook working "$STALE"; cpu_busy
assert_eq "$(marks)" "✻1" 'a stale working hook stays counted while CPU says it is busy'

# ── ④ Ignorance counts as working ──────────────────────────────────────────
# No sample file at all → fmux_cpu_busy rc 2. This is the state every session is in for the first
# few seconds of its life, and reading it as "idle" would empty the badge on exactly the sessions
# that just started.
reset; hook working "$STALE"
assert_eq "$(marks)" "✻1" 'a stale working hook with no CPU sample (rc 2, undecidable) still counts'

# ── ⑤ The pid check still comes first ──────────────────────────────────────
# A dead pid was already excluded before this guard existed; the guard must not have moved that
# check behind the freshness branch.
reset
printf 'working %s 2\n' "$FRESH" > "$STATE/hook-s1"   # pid 2 is kthreadd — never this fleet's agent
if kill -0 2 2>/dev/null; then
    printf '  skip pid-2 liveness case — pid 2 is signalable here\n'
else
    assert_eq "$(marks)" "" 'a working hook whose pid is gone is not counted, freshness notwithstanding'
fi

# ── ⑥ The threshold is a knob, and it is the one being tested ──────────────
# If FMUX_STUCK_AFTER stopped being read, ② would still pass for the wrong reason (any hard-coded
# cutoff under 600s). Pushing the knob past the age proves the branch reads it.
reset; hook working "$STALE"; cpu_idle
assert_eq "$(FMUX_STUCK_AFTER=99999 marks)" "✻1" 'FMUX_STUCK_AFTER is honoured — raising it keeps a stale hook counted'

# ── ⏸ — the same guard, on the other mark ─────────────────────────────────
# `waiting` has no CPU tier: "blocked on a human" and "idle" are both 0% CPU. The screen is the
# only witness, and it is the same WAITING_PAT --list uses.
#
# The case that forced this: `/login` fires a Notification. fmux reads any notification that is
# not the "waiting for your input" idle notice as ⏸ — deliberately, so that a new kind of approval
# prompt is never missed — and /login lands in that net. The payload wording of a notification we
# have never captured cannot be filtered on, so the verdict is taken off the message entirely and
# put on the screen, which either has a dialog on it or does not.
#
# This needs a tmux that answers capture-pane, so the sealed stub is replaced from here on. Its
# refusal log is already asserted above, before the swap.
assert_no_tmux_mutation

SCREEN="$FMUXROOT/screen.txt"
MYBIN="$FMUXROOT/mybin"; mkdir -p "$MYBIN"
cat > "$MYBIN/tmux" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
    list-sessions)  printf '$s1 sess-one\n' ;;
    capture-pane)   cat "$FMUX_TEST_SCREEN" ;;
    *)              exit 1 ;;
esac
STUB
chmod +x "$MYBIN/tmux"
PATH="$MYBIN:$PATH"; export PATH FMUX_TEST_SCREEN="$SCREEN"

wait_hook() { printf 'waiting %s %s\n' "$1" "$PID" > "$STATE/hook-s1"; }
pause()     { "$FMUXBIN" --status 2>/dev/null | grep -o '⏸[^ ]*' | head -1; }

# ⑦ A fresh ⏸ is trusted with no screen check — the badge must appear the instant the hook lands,
#    not one guard later.
reset; wait_hook "$FRESH"; : > "$SCREEN"
assert_eq "$(pause)" "⏸" 'a fresh waiting hook is shown without consulting the screen'

# ⑧ A stale ⏸ whose screen still holds the dialog is a real wait — someone walked away mid-prompt.
#    This is the expensive direction to get wrong: dropping it means an agent waits forever unseen.
reset; wait_hook "$STALE"; printf 'Do you want to proceed?\n' > "$SCREEN"
assert_eq "$(pause)" "⏸" 'a stale waiting hook stays shown while the approval dialog is on screen'

# ⑨ The /login case. Stale, and the screen has no dialog on it.
reset; wait_hook "$STALE"; printf 'Login successful. Remote Control disconnected.\n' > "$SCREEN"
assert_eq "$(pause)" "" 'a stale waiting hook with no dialog on screen is dropped (the /login false positive)'

# ⑩ The decrement must not leak a bare count. w is decremented by ⑨'s path, and the name-less
#    fallback at the end of the block used to print "⏸ $w" unconditionally — with every ⏸ filtered
#    out, that renders "⏸ 0": a badge announcing a wait it just decided was not there.
reset; wait_hook "$STALE"; printf 'nothing here\n' > "$SCREEN"
assert_eq "$("$FMUXBIN" --status 2>/dev/null | grep -c '⏸')" "0" 'filtering every ⏸ out prints no badge at all, not "⏸ 0"'

# ⑪ The threshold is read, not hard-coded.
reset; wait_hook "$STALE"; : > "$SCREEN"
assert_eq "$(FMUX_STALE_WAIT=99999 pause)" "⏸" 'FMUX_STALE_WAIT is honoured — raising it keeps a stale ⏸ shown'

fmux_test_done
