#!/usr/bin/env bash
# Call-site grid — pins down, wall to wall, what the two places that actually draw "working" on
# screen (the ✻ mark in --list, the ✻n in --status) answer for **the same state**.
#
# Why this file exists (2026-08-05, pre-install gate):
#   t-08 (pattern) and t-09 (CPU delta) measure the **parts**. Nobody measured the two call sites
#   that assemble those parts.
#   As a result, two defects that should have blocked the install existed **while `make check`
#   passed as-is**:
#     ① WORKING_PAT's alternative ⑤ matched the completion line (`✻ Baked for 1h 5m 3s`), so a
#        session whose turn had ended stayed permanently stuck showing ✻ — the part test recorded
#        that line as "MATCH is correct" and passed it.
#     ② --status, citing CPU rc1, would not count a working session, so the status-bar ✻n
#        flickered every 5 seconds — --list drew ✻ for the same state, but only the status bar
#        erased it. The original starting point of this incident was the mismatch "status bar
#        shows ✻4, list shows no mark" — this created a new mismatch running the opposite
#        direction.
#   Both are "the part is right but the assembly is wrong" defects. If this net had been here,
#   both would have been caught.
#
# Grid: hook fresh/stale × CPU rc0/rc1/rc2 (unknown) × screen match/mismatch = 12 cells. Pins each
# cell's expected value down as a table, and nails down **exactly where and in which direction**
# the two call sites' answers diverge.
#
# ⛔ Never calls tmux. No real agent process either:
#    · tmux is intercepted by a shell script placed ahead on PATH (never touches the real binary).
#    · /proc is injected as a fake directory via TT_PROC. The ps fallback is blocked too, with a
#      shim.
#    · The role of "a live agent's pid" is played by this test process itself ($$) — it never
#      spawns a new process or sends a signal to anyone (the code only does a kill -0 existence
#      check).
set -u
. "$(dirname "$0")/lib.sh"
tt_test_sandbox

STATE="$HOME/.cache/tt"; mkdir -p "$STATE"
PROC="$TTROOT/proc"; export TT_PROC="$PROC"
SELFPID=$$                     # a real pid that will pass the code's kill -0 liveness check
SID=1                          # the session_id '$1' the fake tmux hands back → state files are hook-1 / cpu-1
SNAME=w1

# ── ⛔ PATH guard — stands before any assertion ─────────────────────────────
mkdir -p "$TTROOT/bin"
cat > "$TTROOT/bin/tmux" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TT_TMUX_LOG"
case "$1 ${2:-}" in
    "ls -F")
        # --list's session listing. Fields = id / created / last_attached / attached / name
        printf '$1\t1700000000\t0\t-\t%s\n' "${TT_FAKE_NAME:-w1}"; exit 0 ;;
    "capture-pane -p")
        [ -n "${TT_SCREEN:-}" ] && [ -f "${TT_SCREEN:-}" ] && cat "$TT_SCREEN"
        exit 0 ;;
    "list-panes -s")
        # tt_is_agent's 2nd-priority verdict — only reached when there is no hook file
        printf '%s\n' "${TT_FAKE_PANE_CMD:-claude}"; exit 0 ;;
esac
exit 1
SHIM
chmod +x "$TTROOT/bin/tmux"
# Block the ps fallback too — without this, when the fake /proc is empty it reads this test
# process's **real** CPU time, making the test's answer waver with machine load.
cat > "$TTROOT/bin/ps" <<'SHIM'
#!/usr/bin/env bash
printf 'ps %s\n' "$*" >> "$TT_TMUX_LOG"
exit 1
SHIM
chmod +x "$TTROOT/bin/ps"
export TT_TMUX_LOG="$TTROOT/tmux-calls.log"
: > "$TT_TMUX_LOG"
export PATH="$TTROOT/bin:$PATH"

# ── three fake screens ───────────────────────────────────────────────────────
# tt_working's awk only looks at "the line above ❯, skipping the divider, skipping blank lines" —
# build it in exactly that shape.
mkscreen() { printf '%s\n────────────────\n❯ \n' "$2" > "$TTROOT/$1.screen"; }
mkscreen match   '✻ Choreographing… (43s · ↓ 1.9k tokens)'   # the real selected line from a WORKING capture
mkscreen idle    '✻ Baked for 11m 42s'                       # the real selected line from the device-refactor capture
mkscreen done1h  '✻ Baked for 1h 5m 3s'                      # the completion line of a turn that ran over an hour
SC_MATCH="$TTROOT/match.screen"
SC_IDLE="$TTROOT/idle.screen"
SC_DONE1H="$TTROOT/done1h.screen"

# ── planting state ───────────────────────────────────────────────────────────
# Each call site rotates the snapshot via tt_cpu_sample after judging → the file changes on every
# call. So **we replant before every single call**. now is re-read each time too (so a long test
# run does not drift).
fake_proc() {                  # fake_proc <pid> <utime> <stime>
    mkdir -p "$PROC/$1"
    printf '%s (claude) S 1 %s %s 0 -1 4194304 111 222 0 0 %s %s 0 0 20 0 12 0 999 0 0\n' \
        "$1" "$1" "$1" "$2" "$3" > "$PROC/$1/stat"
}
plant() {                      # plant <fresh|stale> <rc0|rc1|rc2|nohook>
    local now hts
    now=$(date +%s)
    case "$1" in
        fresh) hts=$((now - 5))  ;;   # ≤20s = the agent's own confession is still valid
        stale) hts=$((now - 60)) ;;   # >20s = the zone where the stuck-prevention guard kicks in
    esac
    if [ "$2" = nohook ]; then
        rm -f "$STATE/hook-$SID" "$STATE/cpu-$SID"
        return 0
    fi
    printf 'working %s %s\n' "$hts" "$SELFPID" > "$STATE/hook-$SID"
    fake_proc "$SELFPID" 100000 0                     # current counter = 100000 cs
    case "$2" in
        # 5s window. Threshold is 6 cs/s → boundary delta 30. Spread wide enough that a 1s clock
        # slip (4-6s window) does not flip the verdict.
        rc0) printf '%s %s 99960 0 0\n' "$SELFPID" "$((now - 5))" > "$STATE/cpu-$SID" ;;  # Δ40 → 8.0 cs/s
        rc1) printf '%s %s 99980 0 0\n' "$SELFPID" "$((now - 5))" > "$STATE/cpu-$SID" ;;  # Δ20 → 4.0 cs/s
        rc2) rm -f "$STATE/cpu-$SID" ;;                                                   # no snapshot = warmup
    esac
}

# ── actually run the two call sites ─────────────────────────────────────────
list_mark() {                  # did --list attach ✻ to that session → yes/no
    local out
    out=$("$TTBIN" --list 2>/dev/null) || true
    case "$out" in *'✻'*) printf 'yes' ;; *) printf 'no' ;; esac
}
status_count() {               # --status's ✻n → n
    local out n
    out=$("$TTBIN" --status 2>/dev/null) || true
    case "$out" in
        *'✻'*) n=${out#*✻}; n=${n%% *} ;;
        *)     n=0 ;;
    esac
    case "${n:-}" in ''|*[!0-9]*) n=0 ;; esac
    printf '%s' "$n"
}

# ── ① the 12-cell grid ───────────────────────────────────────────────────────
# want_list  : does --list draw ✻ (yes/no)
# want_status: --status's ✻n (0/1)
cell() {                       # cell <fresh|stale> <rc0|rc1|rc2> <screen> <want_list> <want_status> <description>
    local hook="$1" cpu="$2" screen="$3" wl="$4" ws="$5" why="$6" gl gs
    export TT_SCREEN="$screen"
    plant "$hook" "$cpu"; gl=$(list_mark)
    plant "$hook" "$cpu"; gs=$(status_count)
    assert_eq "$gl" "$wl" "[--list  ] hook=$hook × CPU=$cpu × screen=$( [ "$screen" = "$SC_MATCH" ] && echo match || echo mismatch) — $why"
    assert_eq "$gs" "$ws" "[--status] hook=$hook × CPU=$cpu × screen=$( [ "$screen" = "$SC_MATCH" ] && echo match || echo mismatch) — $why"
    # ★invariant: for a session whose hook says working, the status bar **cannot count fewer**
    #   than the popup. The status bar has no 3rd-priority witness (the screen) — erasing on the
    #   basis of a witness that does not exist would make it erase more aggressively than the
    #   popup, which is the exact reversal of this incident's starting point ("status bar shows
    #   ✻4, list shows no mark").
    local lnum=0; [ "$gl" = yes ] && lnum=1
    TT_RUN=$((TT_RUN + 1))
    if [ "$gs" -ge "$lnum" ]; then
        printf '  ok   invariant status-bar(%s) >= popup(%s)\n' "$gs" "$lnum"
    else
        TT_FAIL=$((TT_FAIL + 1))
        printf '  FAIL invariant violated: status-bar(%s) < popup(%s) — %s\n' "$gs" "$lnum" "$why"
    fi
}

# (a) When the hook is fresh, the 1st-priority witness alone settles it — neither CPU nor screen
#     can flip this verdict.
cell fresh rc0 "$SC_MATCH" yes 1 'a fresh hook is a confession from the agent itself — unconditionally working'
cell fresh rc0 "$SC_IDLE"  yes 1 'fresh hook: does not flip even if the screen is idle (rendering cannot beat the confession)'
cell fresh rc1 "$SC_MATCH" yes 1 'fresh hook: does not flip even if CPU says no'
cell fresh rc1 "$SC_IDLE"  yes 1 '★fresh hook + CPU idle + screen idle — still not erased within 20s'
cell fresh rc2 "$SC_MATCH" yes 1 'fresh hook: CPU indeterminate changes nothing'
cell fresh rc2 "$SC_IDLE"  yes 1 'fresh hook: ✻ does not disappear even during the warmup window'

# (b) When the hook is stale, the stuck-prevention guard kicks in — this is the first place the
#     two call sites diverge.
cell stale rc0 "$SC_MATCH" yes 1 'if CPU answers working, the screen is not consulted at all'
cell stale rc0 "$SC_IDLE"  yes 1 '★the original symptom: a long thinking turn with no tool calls — CPU rescues it even when the screen is idle'
cell stale rc1 "$SC_MATCH" yes 1 '★where block #2 stands: when the screen witness stands, --list keeps ✻. The status bar must count it too'
cell stale rc1 "$SC_IDLE"  no  1 '★unstuck — --list only erases when all three witnesses say no'
cell stale rc2 "$SC_MATCH" yes 1 'CPU indeterminate (warmup, detached) → the screen stands as the 3rd-priority backstop'
cell stale rc2 "$SC_IDLE"  no  1 'indeterminate + screen idle → --list erases, and the status bar does not fold "unknown" into "erase"'

# ── ② exactly where the answers diverge, and in which direction ────────────
# Of the 12 cells, the answers diverge in only two (stale×rc1×screen-idle, stale×rc2×screen-idle).
# And the direction is always the one where "the status bar counts more." If the opposite
# direction ever appears, the invariant assertion above fires first.
# Here we pin down, with the reason, that those two cells are **intentional**: the status bar
# does not know session names and cannot capture-pane the whole fleet every 5 seconds, so it has
# no 3rd-priority witness at all.
export TT_SCREEN="$SC_IDLE"
plant stale rc1; assert_eq "$(list_mark)"    "no" 'designed mismatch 1/2 — --list looks at all three witnesses and erases'
plant stale rc1; assert_eq "$(status_count)" "1"  'designed mismatch 1/2 — the status bar has only two witnesses, so it does not erase'

# ── ③ block #2 regression — a single rc1 CPU tick does not turn off the status bar ─────────────
# Measured in practice: claude waiting on a tool-call response swings between 3-22 cs/s, repeatedly
# crossing the threshold of 6. The status bar runs every 5 seconds, so turning the badge off on one
# rc1 would make a genuinely working session's ✻n flicker.
# Measures whether the count stays steady even when three ticks in a row are all rc1 (the spot
# solved with 'always count' instead of hysteresis).
export TT_SCREEN="$SC_MATCH"
n1=0; n2=0; n3=0
plant stale rc1; n1=$(status_count)
plant stale rc1; n2=$(status_count)
plant stale rc1; n3=$(status_count)
assert_eq "$n1$n2$n3" "111" '★status-bar ✻n does not flicker even when CPU is rc1 for three ticks in a row (1 1 1)'

# ── ④ block #1 regression — a completion line must not act as a screen witness ─────────────────
# If WORKING_PAT's alternative ⑤ (`(glyph) [^ ]+ for [0-9]+h`) is still alive, this comes out yes.
# That line means "the turn that ran over an hour has **ended**," and a completion line stays on
# screen until the next turn, so ✻ never turns itself off — the stuck-prevention guard is disabled
# entirely. Blocked at both the part (t-08) and the call site.
export TT_SCREEN="$SC_DONE1H"
plant stale rc1
assert_eq "$(list_mark)" "no" \
    '★the completion line of a turn that ran over an hour cannot revive ✻ (this comes out yes if alternative ⑤ is still alive)'
plant stale rc2
assert_eq "$(list_mark)" "no" \
    '★the completion line is not a witness even when CPU is indeterminate — this is exactly where real stuck cases used to happen'
# And a real spinner still rescues it under the same conditions (evidence that removing ⑤ did not create a false negative)
export TT_SCREEN="$SC_MATCH"
plant stale rc2
assert_eq "$(list_mark)" "yes" 'even with ⑤ removed, a real spinner screen still keeps ✻ up'

# ── ⑤ a session with no hook file at all — the one place the divergence is structural ──────────
# --status counts by scanning hook-*, so it cannot see a hookless session to begin with. --list
# sees it through the screen. This is not a mismatch, it is a **difference in observation scope**.
# Explicitly pins down the fact that the invariant above (status bar >= popup) does not apply
# here — trusting the inequality globally without knowing this leads to fixing the wrong place.
export TT_SCREEN="$SC_MATCH"
plant stale nohook
assert_eq "$(list_mark)"    "yes" 'for a hookless session, --list judges by the screen alone'
assert_eq "$(status_count)" "0"   'a hookless session is outside the field of view of --status (a difference in observation scope, not a rule mismatch)'
export TT_SCREEN="$SC_IDLE"
plant stale nohook
assert_eq "$(list_mark)" "no" 'no hook and an idle screen too → no mark'

# ── ⑥ --status is a sampler ─────────────────────────────────────────────────
# The axis of the C (CPU delta) design: the status bar runs every 5 seconds, rotating the sample,
# so that whenever the popup opens it gets a fresh window with sleep 0. If the tt_cpu_sample call
# is missing here, the popup side's tt_cpu_busy permanently returns rc2 and CPU judging dies
# entirely — if the screen breaks too, ✻ disappears again. Pins down that call.
rm -f "$STATE/cpu-$SID"
now=$(date +%s)
printf 'working %s %s\n' "$((now - 60))" "$SELFPID" > "$STATE/hook-$SID"
fake_proc "$SELFPID" 100000 0
status_count >/dev/null
assert_rc 0 test -f "$STATE/cpu-$SID"
assert_eq "$(cut -d' ' -f1 < "$STATE/cpu-$SID")" "$SELFPID" \
    '★one call to --status leaves a sample behind (the sampler role) — if this line goes missing, CPU judging for the popup stays rc2 forever'
fake_proc "$SELFPID" 100200 0                      # next tick +200cs
sleep 4                                            # push past ROTATE (3s) to actually rotate
status_count >/dev/null
assert_eq "$(awk '{ print ($4 > 0 && $5 > 0) ? "yes" : "no" }' < "$STATE/cpu-$SID")" "yes" \
    '★on the second tick, the slot for the previous sample gets filled — with two samples, the popup gets a window at any timing'
# And with that sample alone, the popup side's judgment actually stands (without a screen)
export TT_SCREEN=""
assert_eq "$(list_mark)" "yes" \
    '★the popup judges working purely from the sample the status bar left behind — it comes up without looking at the screen at all (TT_SCREEN empty)'

# ── ⑦ never touched the real tmux or the real ps ────────────────────────────
assert_eq "$(grep -c '^ps ' "$TT_TMUX_LOG" || true)" "0" \
    'never hit the ps fallback once = CPU judging was decided entirely by the fake /proc (independent of machine load)'
stray=$(grep -vE '^(ps |ls -F|capture-pane -p|list-panes -s|display-message -p)' "$TT_TMUX_LOG" | sort -u || true)
assert_eq "$stray" "" \
    '★the commands the fake tmux received are read-only only — no kill-session, new-session, send-keys, or the like leaked through'

tt_test_done
