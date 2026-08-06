#!/usr/bin/env bash
# CPU-delta-based working verdict — fmux_cpu_read / fmux_cpu_cs_ps / fmux_cpu_sample / fmux_cpu_busy.
#
# Why this test exists: the screen verdict (t-08) reads a rendering artifact, so it breaks quietly
# whenever the TUI wording changes. CPU delta is the insurance for that, but if this side wrongly
# answers "no," the very incident t-08 was built to block (deleting ✻ on a genuinely working session)
# happens again. So what is measured most heavily here is **the distinction between rc 2 (cannot
# tell) and rc 1 (not working)** — the moment "unknown" collapses into "no," ✻ disappears again.
#
# ⛔ Never calls tmux. Does not depend on real processes either:
#    /proc is faked by injecting a directory through FMUX_PROC, and the macOS fallback is reproduced by
#    shadowing ps with a shell function. So this test gives the same answer on Mac too, whether the
#    CPU is idle or pegged.
set -u
. "$(dirname "$0")/lib.sh"
fmux_test_sandbox

# ── Pull only the verdict logic out of the build artifact ────────────────────
# Sourcing bin/fmux wholesale runs all the way to the entry point (the fzf popup). Extract just the
# pieces we need and eval them. Reading src directly would let a "fixed but not built" state pass, so
# this must always be pulled from bin/fmux.
eval "$(sed -n '/^FMUX_CPU_[A-Z_]*=/p' "$FMUXBIN")"
for fn in fmux_cpu_cs_ps fmux_cpu_read fmux_cpu_sample fmux_cpu_busy; do
    eval "$(awk -v n="$fn" 'index($0, n "() {") == 1 { f = 1 } f { print } f && /^\}$/ { exit }' "$FMUXBIN")"
    FMUX_RUN=$((FMUX_RUN + 1))
    if [ "$(type -t "$fn" 2>/dev/null)" = function ]; then
        printf '  ok   extracted %s from bin/fmux\n' "$fn"
    else
        FMUX_FAIL=$((FMUX_FAIL + 1))
        printf '  FAIL failed to extract %s from bin/fmux — the extraction awk cannot follow the function shape\n' "$fn"
    fi
done

# Whether the constants actually got loaded — if even one is empty, all the arithmetic below becomes
# meaningless
assert_eq "$FMUX_CPU_BUSY:$FMUX_CPU_MINWIN:$FMUX_CPU_MINWIN_COARSE:$FMUX_CPU_MAXWIN:$FMUX_CPU_ROTATE" \
    "6:3:20:60:3" 'the five threshold constants are carried in the build artifact exactly as measured in practice'

STATE="$HOME/.cache/fmux"; mkdir -p "$STATE"
PROC="$FMUXROOT/proc"; export FMUX_PROC="$PROC"

# ── Fake /proc ─────────────────────────────────────────────────────────────
# Deliberately puts a space and ') ' inside comm — this breaks unless the parser uses a right-side
# longest match (##*') '). The first field of what is left after cutting is state, so the values land
# at the positions for utime=arr[11], stime=arr[12].
fake_proc() {                # fake_proc <pid> <utime> <stime>
    mkdir -p "$PROC/$1"
    printf '%s (cl) aude (x)) S 1 %s %s 0 -1 4194304 111 222 0 0 %s %s 0 0 20 0 12 0 999 0 0\n' \
        "$1" "$1" "$1" "$2" "$3" > "$PROC/$1/stat"
}
snap() { printf '%s\n' "$*" > "$STATE/cpu-s1"; }     # plant one snapshot line
rc_of() { local r=0; "$@" >/dev/null 2>&1 || r=$?; printf '%s' "$r"; }

NOW=1800000000

# ── ① fmux_cpu_read — /proc parsing ────────────────────────────────────────
fake_proc 4242 1000 234
FMUX_CPU_CS=""; FMUX_CPU_Q=""
assert_eq "$(rc_of fmux_cpu_read 4242)" "0" 'fmux_cpu_read: reads the fake /proc'
fmux_cpu_read 4242
assert_eq "$FMUX_CPU_CS" "1234" 'adds utime+stime (never adds cutime/cstime — reap spikes)'
assert_eq "$FMUX_CPU_Q" "1" '/proc resolution is 1cs (USER_HZ=100 fixed)'
assert_eq "$(rc_of fmux_cpu_read 0)" "1" 'pid 0 cannot be read'
assert_eq "$(rc_of fmux_cpu_read abc)" "1" 'cannot be read if pid is not numeric'
printf 'garbage without parens\n' > "$PROC/4242/stat"
assert_eq "$(rc_of fmux_cpu_read 4242)" "1" 'cannot be read if /proc stat is not the right format (does not leave a stale value behind)'
fake_proc 4242 1000 234

# ── ② fmux_cpu_cs_ps — the macOS/BSD fallback parser ──────────────────────────
# Shadowed with a shell function so it never calls the real ps. A function in the same shell is picked
# up before an external command.
PS_OUT=""; PS_RC=0
ps() { [ "$PS_RC" = 0 ] || return "$PS_RC"; printf '%s\n' "$PS_OUT"; }
ps_cs() { PS_OUT="$1"; PS_RC=0; FMUX_CPU_CS=""; fmux_cpu_cs_ps 1 >/dev/null 2>&1 || true; printf '%s' "$FMUX_CPU_CS"; }
assert_eq "$(ps_cs '  0:44.00')" "4400" 'Darwin MM:SS.cc'
assert_eq "$(ps_cs '00:07:48')" "46800" 'Linux ps HH:MM:SS (second resolution) — reference value measured in practice'
assert_eq "$(ps_cs '1-02:03:04.5')" "9378450" 'DD-HH:MM:SS.c — a session that ran over a day'
assert_eq "$(ps_cs '0:08.09')" "809" 'does not read 08/09 as octal (dies instantly without the 10# prefix)'
PS_OUT="1:00.00"; PS_RC=0; fmux_cpu_cs_ps 1 >/dev/null 2>&1 || true
assert_eq "$FMUX_CPU_Q" "1" 'resolution is 1cs when there is a decimal point — the normal Mac path'
PS_OUT="00:07:48"; PS_RC=0; fmux_cpu_cs_ps 1 >/dev/null 2>&1 || true
assert_eq "$FMUX_CPU_Q" "100" 'resolution is 100cs when there is no decimal point → the caller extends the minimum window to 20 seconds'
PS_RC=1
assert_eq "$(rc_of fmux_cpu_cs_ps 1)" "1" 'cannot be read if ps fails'
PS_OUT=""; PS_RC=0
assert_eq "$(rc_of fmux_cpu_cs_ps 1)" "1" 'cannot be read if ps gives an empty line (not fooled by a pipe rc of 0)'
PS_RC=1

# ── ③ fmux_cpu_busy — the verdict ─────────────────────────────────────────────
# The 3-valued rc is the heart of this design: 0=working / 1=not working / 2=cannot tell.
rm -f "$STATE/cpu-s1"
assert_eq "$(rc_of fmux_cpu_busy s1 4242 "$NOW")" "2" \
    '★the first call with no snapshot yet (warmup) cannot be judged — collapsing it to idle makes ✻ disappear'
assert_eq "$(rc_of fmux_cpu_busy '' 4242 "$NOW")" "2" 'cannot be judged if sid is empty'
assert_eq "$(rc_of fmux_cpu_busy s1 0 "$NOW")" "2" 'cannot be judged if pid is unknown (hook failed to climb the parent chain)'

# Above/below threshold — 5-second window, threshold 6 cs/s → the boundary is delta 30
fake_proc 4242 1000 234                                  # cs = 1234
snap 4242 $((NOW - 5)) 1194 0 0                          # Δ40 / 5s = 8.0 cs/s
assert_eq "$(rc_of fmux_cpu_busy s1 4242 "$NOW")" "0" 'above threshold (8.0 cs/s): working'
snap 4242 $((NOW - 5)) 1214 0 0                          # Δ20 / 5s = 4.0 cs/s
assert_eq "$(rc_of fmux_cpu_busy s1 4242 "$NOW")" "1" 'below threshold (4.0 cs/s): not working — the idle max range measured in practice'
snap 4242 $((NOW - 5)) 1204 0 0                          # Δ30 / 5s = exactly 6.0
assert_eq "$(rc_of fmux_cpu_busy s1 4242 "$NOW")" "0" 'the boundary value 6.0 cs/s is inclusive (>=)'
snap 4242 $((NOW - 5)) $((1204 + 1)) 0 0                 # Δ29 → 5.8
assert_eq "$(rc_of fmux_cpu_busy s1 4242 "$NOW")" "1" 'just below the boundary is excluded'

# Window length — measured in practice, a 1-2 second window overlaps between working and idle. An
# overlapping range must not be judged.
snap 4242 $((NOW - 2)) 0 0 0                             # Δ1234 / 2s = 617 cs/s, and yet
assert_eq "$(rc_of fmux_cpu_busy s1 4242 "$NOW")" "2" \
    '★if the window is under MINWIN (3 seconds), cannot be judged no matter how large the delta (a 1-2 second window overlaps with idle)'
snap 4242 $((NOW - 3)) 1216 0 0                          # Δ18 / 3s = 6.0
assert_eq "$(rc_of fmux_cpu_busy s1 4242 "$NOW")" "0" 'judges when the window is exactly MINWIN (3 seconds)'
snap 4242 $((NOW - 61)) 0 0 0                            # a huge delta, but the window is 61 seconds
assert_eq "$(rc_of fmux_cpu_busy s1 4242 "$NOW")" "2" \
    '★if the window exceeds MAXWIN (60 seconds), cannot be judged — a long window dilutes the signal and becomes a weapon that revives stuck state'
snap 4242 $((NOW + 10)) 1234 0 0                         # the clock jumped backward (NTP · suspend)
assert_eq "$(rc_of fmux_cpu_busy s1 4242 "$NOW")" "2" 'cannot be judged if the window is negative (NTP jump, suspend/resume)'

# Two samples — if the newest one is too young, widen the window using the previous one. This
# resolves the conflict between the 5-second refresh cycle and the 3-second floor.
snap 4242 $((NOW - 1)) 1230 $((NOW - 6)) 1194            # newest 1s (too short) / previous 6s Δ40 = 6.7
assert_eq "$(rc_of fmux_cpu_busy s1 4242 "$NOW")" "0" \
    '★if the newest sample is under MINWIN, widen the window using the previous sample to judge (why there are two samples)'
snap 4242 $((NOW - 1)) 1230 $((NOW - 6)) 1214            # previous 6s Δ20 = 3.3
assert_eq "$(rc_of fmux_cpu_busy s1 4242 "$NOW")" "1" 'not working if even the previous sample is below threshold'
snap 4242 $((NOW - 1)) 1230 0 0                          # no previous sample
assert_eq "$(rc_of fmux_cpu_busy s1 4242 "$NOW")" "2" 'cannot be judged if there is no previous sample and the newest one is too young'

# Self-invalidation — even if the file rots, it does not misjudge using a stale value
snap 9999 $((NOW - 5)) 0 0 0
assert_eq "$(rc_of fmux_cpu_busy s1 4242 "$NOW")" "2" '★pid mismatch (number reused after a reboot/restart) → the snapshot is discarded'
snap 4242 $((NOW - 5)) 99999 0 0                         # the counter went backward
assert_eq "$(rc_of fmux_cpu_busy s1 4242 "$NOW")" "2" 'cannot be judged if the delta is negative (counter reset)'
snap 4242 abc 1194 0 0
assert_eq "$(rc_of fmux_cpu_busy s1 4242 "$NOW")" "2" 'a rotten line cannot be judged (an arithmetic error does not kill the list)'
printf '' > "$STATE/cpu-s1"
assert_eq "$(rc_of fmux_cpu_busy s1 4242 "$NOW")" "2" 'an empty file also cannot be judged'

# When the process has died — the /proc entry is gone and ps also fails
snap 4242 $((NOW - 5)) 0 0 0                             # even in a situation where the delta ought to be huge
rm -rf "$PROC/4242"
assert_eq "$(rc_of fmux_cpu_busy s1 4242 "$NOW")" "2" \
    '★cannot be judged if the process has died (/proc missing + ps fails) → the caller falls through to the screen verdict'
fake_proc 4242 1000 234

# When resolution is coarse (second-granularity ps), the minimum window rises to 20 seconds —
# blocking a quantization false positive. Remove /proc to fall through to the ps path, and have ps
# give a decimal-free, second-granularity value.
rm -rf "$PROC/4242"
PS_OUT="00:00:12"; PS_RC=0                               # 1200 cs, resolution 100cs
snap 4242 $((NOW - 5)) 1100 0 0                          # Δ100 / 5s = 20 cs/s — a value produced by a single tick
assert_eq "$(rc_of fmux_cpu_busy s1 4242 "$NOW")" "2" \
    '★when resolution is 1 second, a 5-second window cannot be judged — if idle crosses one tick it reads as 33 cs/s and false-positives'
snap 4242 $((NOW - 25)) 1100 0 0                         # Δ100 / 25s = 4.0 cs/s
assert_eq "$(rc_of fmux_cpu_busy s1 4242 "$NOW")" "1" 'judges even at 1-second resolution once the window exceeds 20 seconds'
snap 4242 $((NOW - 25)) 1000 0 0                         # Δ200 / 25s = 8.0 cs/s
assert_eq "$(rc_of fmux_cpu_busy s1 4242 "$NOW")" "0" 'above threshold is working even at coarse resolution'
PS_RC=1
fake_proc 4242 1000 234

# ── ④ fmux_cpu_sample — rotation ────────────────────────────────────────────
rm -f "$STATE/cpu-s1"
fmux_cpu_sample s1 4242 "$NOW"
assert_eq "$(cat "$STATE/cpu-s1")" "4242 $NOW 1234 0 0" 'first sample: the previous slot is 0 0'
# If called again within ROTATE (3 seconds), the file is not touched at all — so mashing the popup
# does not crush the window down to 0 seconds
fake_proc 4242 2000 234
fmux_cpu_sample s1 4242 $((NOW + 2))
assert_eq "$(cat "$STATE/cpu-s1")" "4242 $NOW 1234 0 0" '★if called again within ROTATE, the file is not touched (so the window does not get crushed down to 0 seconds)'
fmux_cpu_sample s1 4242 $((NOW + 3))
assert_eq "$(cat "$STATE/cpu-s1")" "4242 $((NOW + 3)) 2234 $NOW 1234" 'after ROTATE has elapsed: the old sample gets pushed into the previous slot'
# ★clock-regression freeze — the one place with no recovery path, so it is measured most heavily
#   here. If a future timestamp gets planted in the file (NTP correction, manual clock change,
#   suspend), now-ts1 goes negative, and a negative value makes `-lt ROTATE` **forever true**, so the
#   sampler returns immediately every time → the file never updates again, and fmux_cpu_busy keeps
#   returning rc 2 because the window is negative → the CPU-delta verdict dies wholesale.
#   The guard is: "if it is negative, discard the old sample and overwrite it with the current value."
rm -f "$STATE/cpu-s1"
fake_proc 4242 1000 234                                  # cs = 1234
snap 4242 $((NOW + 3600)) 9999 $((NOW + 3500)) 8888      # an hour into the future got planted
fmux_cpu_sample s1 4242 "$NOW"
assert_eq "$(cat "$STATE/cpu-s1")" "4242 $NOW 1234 0 0" \
    '★on clock regression (a future timestamp got planted), the sampler does not freeze and overwrites with the current value'
assert_eq "$(rc_of fmux_cpu_busy s1 4242 $((NOW + 5)))" "1" \
    '★the overwritten sample lets a verdict stand immediately — if it had frozen, the future timestamp would remain forever and rc 2 would never end'
fake_proc 4242 1100 234                                  # +100cs
fmux_cpu_sample s1 4242 $((NOW + 5))                       # ROTATE (3s) has elapsed → rotates
assert_eq "$(cat "$STATE/cpu-s1")" "4242 $((NOW + 5)) 1334 $NOW 1234" \
    '★on the tick after the regression, normal rotation returns (if frozen, the file would stay unchanged here)'
fake_proc 4242 1500 234                                  # +400cs again
assert_eq "$(rc_of fmux_cpu_busy s1 4242 $((NOW + 10)))" "0" \
    '★and even the working verdict returns — 400cs/5s = 80 cs/s'

# When the pid changes, the old sample is not carried over
rm -f "$STATE/cpu-s1"
fake_proc 4242 1000 234
fmux_cpu_sample s1 4242 "$NOW"
fake_proc 4242 2000 234
fmux_cpu_sample s1 4242 $((NOW + 3))
fake_proc 777 50 0
fmux_cpu_sample s1 777 $((NOW + 10))
assert_eq "$(cat "$STATE/cpu-s1")" "777 $((NOW + 10)) 50 0 0" '★when the pid changes, the old sample is not carried over (blocks a counter-reset misjudgment)'
# An unreadable pid does not corrupt the file
fmux_cpu_sample s1 4444 $((NOW + 20))
assert_eq "$(cat "$STATE/cpu-s1")" "777 $((NOW + 10)) 50 0 0" 'if the counter cannot be read, the existing file is left untouched'
assert_eq "$(ls "$STATE" | grep -c '^cpu-s1\.' || true)" "0" 'no tmp file is left behind (tmp+mv atomic write)'
# Sample → verdict round trip: with no planted value, just two calls are enough for a verdict to stand
rm -f "$STATE/cpu-s1"
fake_proc 555 0 0
fmux_cpu_sample s1 555 "$NOW"
fake_proc 555 100 0                                       # 100cs over 5 seconds = 20 cs/s
assert_eq "$(rc_of fmux_cpu_busy s1 555 $((NOW + 5)))" "0" 'sample→verdict round trip: leaves a sample and the delta stands on the next call'

fmux_test_done
