#!/usr/bin/env bash
# WORKING_PAT — a guard on the single-line-screen verdict that decides "is this session actively running right now."
#
# Why this test exists: on 2026-08-05, device-refactor was actually mid-thought but ✻ did not show up
# in the list. 80-view.sh's anti-stuck guard cleared ✻ on "hook update stalled 20s + screen verdict
# failed," but in a long thinking turn that uses no tools, a stalled hook update is normal, so this
# pattern — the secondary evidence — was the only remaining line of defense. It got breached. So what
# this file measures runs in both directions:
#   ① false negative — miss a genuinely running screen and ✻ disappears (the original bug).
#   ② false positive — catch an idle screen and the fleet's idle state gets shown as working (quieter and worse).
#      In particular, this repo's own docs or fmux's own TUI showing in a pane was the actual incident path.
#
# What is being tested is the real pattern and real function pulled straight out of the build artifact
# (bin/fmux) — reading src separately would let a "fixed but not built" state pass.
#
# ⛔ This test never calls tmux. Every screen is a real capture file under test/fixtures/screen.
set -u
. "$(dirname "$0")/lib.sh"
tt_test_sandbox

TESTDIR=$(cd "$(dirname "$0")" && pwd) || exit 1
FIX="$TESTDIR/fixtures/screen"

# ── Pull only the verdict logic out of the build artifact ────────────────────
# Sourcing bin/fmux wholesale runs all the way to the entry point (the fzf popup). Extract just the two
# pieces we need and eval them.
eval "$(sed -n '/^WORKING_PAT=/{p;q;}' "$TTBIN")"
eval "$(sed -n '/^WAITING_PAT=/{p;q;}' "$TTBIN")"
eval "$(awk '/^tt_working\(\) \{/ { f = 1 } f { print } f && /^\}/ { exit }' "$TTBIN")"

assert_rc 0 test -n "${WORKING_PAT:-}"
TT_RUN=$((TT_RUN + 1))
if [ "$(type -t tt_working 2>/dev/null)" = function ]; then
    printf '  ok   extracted tt_working from bin/fmux\n'
else
    TT_FAIL=$((TT_FAIL + 1))
    printf '  FAIL failed to extract tt_working from bin/fmux — the extraction awk cannot follow the function shape\n'
fi

# ── Structural guards ──────────────────────────────────────────────────────
# (a) Never put multibyte glyphs inside a bracket expression. `[✻✶…]` collapses under the C locale
#     from a character set into a byte set — grazing just one of ✻'s three bytes is enough to pass, so
#     there is no telling what BSD grep will match. Only a literal alternation `(✻|✶|…)` is pinned
#     down at the character level regardless of locale or implementation.
for bad in '[✻' '[↑' '[↓' '[·'; do
    case "$WORKING_PAT" in
        *"$bad"*) got=yes ;; *) got=no ;;
    esac
    assert_eq "$got" "no" "does not write a multibyte glyph inside bracket '$bad' (collapses to a byte set under the C locale)"
done
# (b) No syntax outside ERE — the default grep on Mac is BSD grep. If this trips, the verdict dies
#     wholesale on Mac.
for bad in '\d' '\s' '\b' '\w' '(?:' '(?='; do
    case "$WORKING_PAT" in
        *"$bad"*) got=yes ;; *) got=no ;;
    esac
    assert_eq "$got" "no" "does not use PCRE/GNU extension '$bad' (BSD grep portability)"
done

# ── Case-verdict helper ────────────────────────────────────────────────────
# tt_working takes a whole screen blob, but the actual verdict is a grep against just one line of it.
# Feed that one line directly to measure each alternative's responsibility clearly (the full-screen
# path is measured separately in ③ below).
pat_case() {                 # pat_case <MATCH|no> <line> <description>
    local want="$1" line="$2" why="$3" got=no
    printf '%s\n' "$line" | grep -qaE "$WORKING_PAT" && got=MATCH
    assert_eq "$got" "$want" "[$LOCTAG] $why"
}

# ── ① lines that must be caught / ② lines that must not be caught ──────────
# The answer must be the same in both locales — the hook also runs from cron, and there is no locale
# there.
run_cases() {
    # (①) false-negative defense — genuinely running screens
    pat_case MATCH '✻ Choreographing… (43s · ↓ 1.9k tokens)' \
        'baseline: the actual selected line from line 29 of the WORKING capture'
    pat_case MATCH '* Deliberating… (20s · ↓ 499 tokens)' \
        'ASCII glyph variant — the glyph alternation now catches this head-on'
    pat_case MATCH '* Deliberating… (11s' \
        'the shape where the glyph hole actually shows — no token counter, so the timer alternative cannot save it (the old pattern missed all of these)'
    pat_case MATCH '✻ Sautéed… (12s' \
        'non-ASCII verb (é) — the old [A-Za-z]+ broke at é and missed every one of these'
    pat_case MATCH '✻ Choreographing... (43s · ↓ 1.9k tokens)' \
        'case where the ellipsis renders as three ASCII dots — the old pattern only accepted U+2026'
    pat_case MATCH '✶ Sautéeing… (2m · ↑ 5k tokens)' \
        'a timer showing only minutes with no seconds, plus an upward arrow — the old [0-9]+m?s forced an s and missed this entirely'
    pat_case no '✻ Sautéed for 1h 10m 46s' \
        '★the shape EVIDENCE pointed to as a spinner — it does not exist in any capture (0 grep hits). The ⑤ alternative that tried to catch it also caught completion lines and was removed'
    pat_case MATCH '✻ Waiting for 1 dynamic workflow to finish' \
        'the real thing from line 9 of the WORKING capture — present-progressive, so grammar separates it from a completion line'
    pat_case MATCH '✻ Composing… (12s · esc to interrupt · ctrl+t to show todos)' \
        'also accepts the layout where the interrupt hint comes later inside the parens'
    pat_case MATCH '✻ Simmering… (11s · ↓ 347 tokens · thought for 6s)' \
        'the past-failure shape that was frozen into an old comment — regression guard'
    pat_case MATCH '· Puttering... (1s · ↓ 12 tokens)' \
        'middle-dot (·) frame + ASCII ellipsis'

    # (②) false-positive defense — idle screens, and someone else's text that happens to be on screen
    pat_case no '✻ Baked for 11m 42s' \
        '★hard constraint: the actual selected line from the device-refactor capture (idle). Carelessly adding a for-shape dies right here'
    pat_case no '✻ Worked for 7m 32s' \
        '★hard constraint: the actual selected line from the member-refactor capture (idle)'
    pat_case no '✻ Churned for 13m 39s' \
        'a completion line — also confirms it does not trip the hour(h) gate since this is 13 minutes'
    pat_case no '  and the next step is lowering the context to 8k-16k to ease the memory pressure.' \
        'the recap tail of the general capture — must not match even with a k-suffixed number present'
    pat_case no '❯ /remote-control' \
        'a slash-command remnant from the photo capture'
    pat_case no '  this is a line that just writes the string esc to interrupt in code' \
        'a case where the docs of this repo are on screen — the old pattern was a bare literal so it matched unconditionally'
    pat_case no '  ◯ fmux-settings-tui  fmux                           3/4 agents done · 17m 52s · ↓ 366.8k tokens' \
        'the TUI progress line that fmux draws about itself — the old pattern caught this and read itself as working'
    pat_case no '  - the docs note that the spinner shows up like 26s · ↓ 763 tokens' \
        'prose that quotes the token-counter format — solved by pinning the timer inside parens'
    pat_case no '  ✻ investigated why the mark does not show up — it is because of the 20-second guard' \
        'a case where the conversation discussing this very bug is on screen (self-referential false positive)'
    pat_case no '  ● Bash(make verify)' \
        'a tool-call line — glyph-lookalike symbol + parens'
    pat_case no '  ⎿  Read src/30-state.sh (191 lines)' \
        'a tool-result line — even with parens+number, the glyph and ellipsis requirement blocks it'
    pat_case no '  (disable recaps in /config)' \
        'the actual selected line from the lx-notes capture — a line that starts with a paren'
}

LOCTAG='UTF-8'; export LC_ALL=en_US.UTF-8; run_cases
LOCTAG='C';     export LC_ALL=C;           run_cases
export LC_ALL=en_US.UTF-8

# ── ②-b ★closed false positive — hour(h)-unit completion lines ──────────────
# Designer case #24 (`✻ Baked for 1h 5m 3s` must not match) now holds.
# Why it used to match: the ⑤ alternative `(glyph) [^ ]+ for [0-9]+h` was trying to catch
# `✻ Sautéed for 1h 10m 46s` and used the "hour(h) unit" as the discriminator between in-progress
# and completed. That premise collapsed under measurement in practice —
#   · no capture anywhere has an hour-unit present-progressive for-line (`grep -al 'Saut' …` = 0 hits).
#     The gain was zero.
#   · every for-line in the captures is a past-tense completion line (`✻ Baked for 11m 42s` is the
#     actual selected line in device-refactor). If it just grows to hour-scale the grammar is
#     identical, so letters alone cannot tell them apart.
#   · And the old claim that "this only fires on the no-hook branch" was wrong: the working branch of
#     80-view.sh also falls through to the screen verdict when the hook is stale and CPU rc is not 0.
#     A completion line stays on screen until the next turn so ✻ never turns itself off → the
#     anti-stuck guard was neutralized wholesale.
# So ⑤ was removed. The two lines below nail that decision down — reverting to MATCH brings the stuck
# state back.
got=no
printf '%s\n' '✻ Baked for 1h 5m 3s' | grep -qaE "$WORKING_PAT" && got=MATCH
assert_eq "$got" "no" \
    '★a completion line for a turn that ran over an hour is not caught (⑤ alternative removed — reviving it permanently freezes ✻ on idle sessions)'
# The evidence that removing ⑤ loses nothing: the one progressive for-line that actually existed is
# still caught by ④.
got=no
printf '%s\n' '✻ Waiting for 1 dynamic workflow to finish' | grep -qaE "$WORKING_PAT" && got=MATCH
assert_eq "$got" "MATCH" \
    'even after ⑤ is removed, the progressive for-line (the real thing from line 9 of the WORKING capture) is still caught by the ④ alternative'
# Structurally block ⑤ from ever being reintroduced into the pattern itself — the two cases above
# alone could miss a variant that revives "hour unit" in a different shape.
case "$WORKING_PAT" in
    *'for [0-9]+h'*) got=yes ;; *) got=no ;;
esac
assert_eq "$got" "no" '★never puts the hour(h)-unit for-gate back into the pattern (indistinguishable from a completion line)'

# ── ③ real-capture regression — the full tt_working path ────────────────────
# Here it is fed the whole screen blob, not a single line. This is the only place that also measures
# the line-picking awk (skipping separators and blank lines). The captures are the 2026-08-05
# 01:38-01:41 real originals, **structure-preserving anonymized** — the lines the verdict uses
# (spinner, recap tail, separator, ❯ position) are kept verbatim from the original; only the body
# prose was swapped out.
assert_rc 0 test -d "$FIX"
for f in "$FIX"/*.screen; do
    base=${f##*/}
    case "$base" in
        WORKING-*) want=0; label='a working capture must match' ;;
        *)         want=1; label='an idle capture must not match' ;;
    esac
    got=0; tt_working < "$f" || got=$?
    assert_eq "$got" "$want" "$label — $base"
done
# Nail down the capture count too — even if fixtures were wiped out wholesale, the loop above would
# silently pass with 0 hits.
assert_eq "$(ls "$FIX"/*.screen 2>/dev/null | grep -c .)" "8" "all 8 real captures are present (6 idle, 1 working, 1 waiting)"

# ── ④ the line-picking itself ────────────────────────────────────────────────
# Nail down exactly what the pattern saw when it judged. If the awk starts picking a different line,
# ③ above could still pass in a "coincidentally matched on the wrong line" state.
pick_line() {
    awk '{ L[NR] = $0 }
         /^❯/ { p = NR }
         END { if (!p) exit
               i = p - 1
               if (i >= 1 && L[i] ~ /^──/) i--
               while (i >= 1 && L[i] ~ /^[ \t]*$/) i--
               if (i >= 1) print L[i] }' "$1"
}
assert_eq "$(pick_line "$FIX/device-refactor.screen")" '✻ Baked for 11m 42s' \
    'in device-refactor, the line used for the verdict is a past-tense completion line'
assert_eq "$(pick_line "$FIX/WORKING-sample-tui-worker.screen")" '✻ Choreographing… (43s · ↓ 1.9k tokens)' \
    'in the WORKING capture, the line used for the verdict is the spinner line (not a progress line — EVIDENCE wrote this one wrong)'

# ── ⑤ WAITING_PAT — the witness that unfreezes ⏸ ─────────────────────────────
# Bug measured in practice on 2026-08-06: the status bar showed "⏸ tui-worker" but the list had no ⏸.
# The 60-second guard in 80-view.sh could not find a prompt on screen and cleared it, and the reason it
# could not find one is that AskUserQuestion and plan approval were missing from the evidence list.
assert_rc 0 test -n "${WAITING_PAT:-}"

assert_rc 0 grep -qaE "$WAITING_PAT" "$FIX/WAITING-sample-askuserquestion.screen"
# Nail down the very fact that the old pattern missed this screen — otherwise the regression comes
# back quietly.
if grep -qaE 'Would you like to run|Press enter to confirm|Yes, proceed|Do you want to' \
        "$FIX/WAITING-sample-askuserquestion.screen"; then got=yes; else got=no; fi
assert_eq "$got" no '★the old evidence list could not catch the AskUserQuestion screen (the reason this test exists)'

# One line per which alternative catches each UI — delete one and it reveals which screen goes blind.
for probe in \
    'Do you want to proceed?|claude tool approval' \
    'Would you like to proceed?|claude plan approval' \
    'Enter to select · Tab/Arrow keys to navigate · Esc to cancel|AskUserQuestion tail' \
    'Press enter to confirm|codex approval' \
    'Yes, proceed|codex approval choice'
do
    line=${probe%%|*}; what=${probe#*|}
    if printf '%s\n' "  $line" | grep -qaE "$WAITING_PAT"; then got=yes; else got=no; fi
    assert_eq "$got" yes "WAITING_PAT catches it — $what"
done

# The other direction: a running screen must not be frozen as waiting. 'esc to interrupt' is the mark
# of working.
if printf '%s\n' '  ✻ Choreographing… (43s · ↓ 1.9k tokens · esc to interrupt)' \
        | grep -qaE "$WAITING_PAT"; then got=yes; else got=no; fi
assert_eq "$got" no '★a working spinner line does not match WAITING_PAT (matching would freeze a running session as ⏸)'

# Idle captures must not be mistaken for waiting either.
for f in "$FIX"/*.screen; do
    base=${f##*/}
    case "$base" in WAITING-*) continue ;; esac
    if grep -qaE "$WAITING_PAT" "$f"; then got=yes; else got=no; fi
    assert_eq "$got" no "a non-waiting capture does not match WAITING_PAT — $base"
done

tt_test_done
