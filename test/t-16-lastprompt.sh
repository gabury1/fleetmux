#!/usr/bin/env bash
# Last prompt (last-<sid>) — save, cleanup, render.
#
# What this file guarantees:
#   ① **Add-on principle.** If the file is missing, corrupted, or the session id cannot be
#      obtained, the preview falls back to the old output **byte for byte**. There must be no
#      path where this feature breaks the control tower.
#   ② **Event gating.** --hooks-json bundles UserPromptSubmit/PostToolUse/PreCompact/PostCompact,
#      and --codex-hooks bundles UserPromptSubmit/PreToolUse/PostToolUse, all under a single
#      `--hook working`. So looking at $2 alone cannot tell whether it is a prompt submission.
#      Without gating, PostToolUse's tool_input.prompt (the Task tool's instruction) would
#      masquerade as the user prompt on every tool call.
#   ③ **The parser reads real JSON.** Quotes, newlines, \u escapes, depth — the four places
#      where fmux_jv's regex used to break are all pinned down here.
#   ④ **Line accounting.** If the screen tail is not shrunk by however many lines the header
#      ate, the preview overflows and the top gets clipped — meaning the prompt we just drew
#      disappears first.
#
# ⛔ tmux is entirely intercepted by the fake ahead of it on PATH. It never touches the real binary.
set -u
. "$(dirname "$0")/lib.sh"
fmux_test_sandbox

STATE="$HOME/.cache/fmux"
mkdir -p "$STATE"
TAB=$'\t'
ESC=$'\033'
CSI=$'\302\233'          # U+009B — 8-bit CSI. Moves the cursor on its own, without ESC.
BS='\'                   # Used when writing a JSON escape into the source ("${BS}u009b" = six characters)

# ── ⛔ PATH guard — comes before any assertion ─────────────────────────────
mkdir -p "$FMUXROOT/bin"
cat > "$FMUXROOT/bin/tmux" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FMUX_TMUX_LOG"
case "${1:-}" in
    ls)
        # Split the call site by format string: 5 fields = --list, 2 fields = fmux_sweep_hooks
        case "${3:-}" in
            *session_name*) [ -n "${FMUX_FAKE_LS5:-}" ] && printf '%s\n' "$FMUX_FAKE_LS5" ;;
            *)              [ -n "${FMUX_FAKE_LS2:-}" ] && printf '%s\n' "$FMUX_FAKE_LS2" ;;
        esac
        exit 0 ;;
    display-message) [ -n "${FMUX_FAKE_DISP:-}" ] && printf '%s\n' "$FMUX_FAKE_DISP"; exit 0 ;;
    capture-pane)    [ -n "${FMUX_FAKE_PANE:-}" ] && printf '%s\n' "$FMUX_FAKE_PANE"; exit 0 ;;
    list-panes)      printf '%s\n' "${FMUX_FAKE_PANECMD:-claude}"; exit 0 ;;
esac
exit 1
SHIM
chmod +x "$FMUXROOT/bin/tmux"
export FMUX_TMUX_LOG="$FMUXROOT/tmux-calls.log"
: > "$FMUX_TMUX_LOG"

# A fake that counts awk calls — passes straight through to the real awk. The claim that
#   "gating actually saves forks" is measured by this, not by reading the code (see ② below).
REALAWK=$(PATH=/usr/bin:/bin:/usr/local/bin command -v awk) || REALAWK=""
[ -n "$REALAWK" ] || { echo "could not find awk"; exit 1; }
export FMUX_AWK_LOG="$FMUXROOT/awk-calls.log"
: > "$FMUX_AWK_LOG"
cat > "$FMUXROOT/bin/awk" <<SHIM
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$FMUX_AWK_LOG"
exec $REALAWK "\$@"
SHIM
chmod +x "$FMUXROOT/bin/awk"
export PATH="$FMUXROOT/bin:$PATH"
awk_calls() { grep -c 'utf8trim' "$FMUX_AWK_LOG" 2>/dev/null || true; }
export TMUX_PANE='%9'
export FMUX_FAKE_DISP="\$9${TAB}zz${TAB}$HOME${TAB}claude${TAB}1"
LF="$STATE/last-9"

hook() {   # $1=state  $2=payload
    printf '%s' "${2:-}" | "$FMUXBIN" --hook "$1" >/dev/null 2>&1 || true
}
ups() {    # One UserPromptSubmit payload. $1 = prompt value (the string exactly as it goes into the JSON)
    printf '{"session_id":"7f3b1c22-0000-4000-8000-0123456789ab","cwd":"%s",%s"prompt":"%s"}' \
        "$HOME" '"hook_event_name":"UserPromptSubmit",' "$1"
}
body() { tail -n +2 "$LF" 2>/dev/null || true; }
head1() { head -1 "$LF" 2>/dev/null || true; }

# ── Display-width oracle ────────────────────────────────────────────────────
# ★The header's width assertions must be measured in **display width, not character count**.
#   What decides where to clip is the number of columns the terminal draws, not the number of
#   characters, and if we count width wrong, the … we appended can itself get clipped by fzf,
#   leaving not even a "this was truncated" marker behind.
#   ⚠ Measuring with src's wcw() would be **circular reasoning** — if the width table is wrong,
#   both the render and the check are wrong the same way and it passes anyway (that is the bug
#   being fixed right now). So this test carries its own separate width table: a standalone
#   implementation transcribed from EastAsianWidth, covering **only the characters this file
#   actually uses**.
#     Separator ─(U+2500), ❯(U+276F), …(U+2026), ASCII = 1 column
#     Hangul syllables, Hangul Jamo Extended-A (U+A960–U+A97C), ✅(U+2705), ❌(U+274C),
#     ⭐(U+2B50), ⏰(U+23F0) = 2 columns
DISPW_AWK='
    BEGIN { for (i = 1; i < 256; i++) O[sprintf("%c", i)] = i }
    {
        gsub(/\033\[[0-9;]*m/, "")
        L = length($0); p = 1; t = 0
        while (p <= L) {
            c = O[substr($0, p, 1)]
            if (c < 128)       { n = 1; v = c }
            else if (c >= 240) { n = 4; v = c - 240 }
            else if (c >= 224) { n = 3; v = c - 224 }
            else if (c >= 192) { n = 2; v = c - 192 }
            else               { n = 1; v = -1 }
            for (q = 1; q < n; q++) v = v * 64 + (O[substr($0, p + q, 1)] % 64)
            t += w(v); p += n
        }
        print t
    }
    function w(v) {
        if (v >= 44032 && v <= 55203) return 2      # Hangul syllable
        if (v >= 43360 && v <= 43388) return 2      # Hangul Jamo Extended-A
        if (v == 9989  || v == 10060) return 2      # ✅ ❌
        if (v == 11088 || v == 9200)  return 2      # ⭐ ⏰
        return 1
    }'
dispw()      { LC_ALL=C awk "$DISPW_AWK"; }
strip_ansi() { LC_ALL=C awk '{ gsub(/\033\[[0-9;]*m/, ""); print }'; }
# Display width of the Nth line — strips color escapes and **actually counts columns** (not character count).
wof()     { printf '%s\n' "$1" | sed -n "${2}p" | dispw; }
# The widest display width among the lines. If even one line exceeds cols, it shows up here.
maxw()    { printf '%s\n' "$1" | dispw | sort -n | tail -1; }
# The characters of the Nth line. Strips only color — the body has no prefix, so there is nothing else to strip.
rowtext() { printf '%s\n' "$1" | strip_ansi | sed -n "${2}p"; }

# ── ① Save ───────────────────────────────────────────────────────────────
rm -f "$LF"
hook working "$(ups 'first instruction')"
assert_rc 0 test -f "$LF"
assert_eq "$(body)" "first instruction" "UserPromptSubmit's prompt goes into the body"
case "$(head1)" in
    ''|*[!0-9]*) got=no ;;
    *) got=yes ;;
esac
assert_eq "$got" "yes" "line 1 is the recorded timestamp (epoch)"

# ★The spot where fmux_jv's regex used to break completely — a quote inside the value.
#   Measured in practice: for {"prompt":"the \"dependencies\" section of the README"}, fmux_jv
#   extracted only the fragment `the \`.
hook working "$(ups 'Fix the \"dependencies\" section of the README')"
assert_eq "$(body)" 'Fix the "dependencies" section of the README' "★does not get cut off at a quote inside the value"

# ★Unescapes \n into a real newline — without this, the "max 3 lines" calculation would forever see 1 line
hook working "$(ups 'line1\nline2\nline3')"
assert_eq "$(body | grep -c .)" "3" "★\\n becomes a real newline, giving 3 lines"

# Tab and backslash
hook working "$(ups 'C:\\tmp\tdelete')"
assert_eq "$(body)" "C:\\tmp${TAB}delete" "unescapes \\\\ and \\t"

# ★Control characters (terminal escapes) are dropped — if they flowed into the preview the screen would break
hook working "$(ups '\u001b[31mred\u001b[0m delete this')"
case "$(body)" in *"$ESC"*) got=yes ;; *) got=no ;; esac
assert_eq "$got" "no" "★ESC does not remain in the body"
assert_contains "$(body)" "red" "only ESC drops out, the characters remain"

# Hangul and emoji that arrive as \u escapes are restored exactly as in the original (must not
#   turn into a field of question marks). Uses the same 가(U+AC00) reference glyph the source
#   uses to illustrate this exact failure mode.
hook working "$(ups '\uac00 \ud83d\ude00')"
assert_eq "$(body)" "가 😀" "\\u escapes are correctly restored to UTF-8"

# ★Only look at depth 1 — do not get fooled by fake JSON pasted inside the prompt value
hook working "$(ups 'look at this payload: {\"prompt\": \"fake\"}')"
assert_eq "$(body)" 'look at this payload: {"prompt": "fake"}' "★does not get fooled by a fake prompt key inside the value"

# ★Only look at depth 1 — even if the prompt inside a nested object comes **first**, the real
#   one wins. It must win by depth, not by order. Remove the depth limit and whichever comes
#   first wins instead.
hook working '{"hook_event_name":"UserPromptSubmit","meta":{"prompt":"wrong one"},"prompt":"real instruction"}'
assert_eq "$(body)" "real instruction" "★even with a nested prompt appearing first, the depth-1 one is chosen"

# Filters it out even when a raw control character rides along inside the value as-is (invalid
#   JSON per spec, but the hook accepts whatever it gets)
hook working "$(ups "$ESC[31mrawESC$ESC[0m")"
case "$(body)" in *"$ESC"*) got=yes ;; *) got=no ;; esac
assert_eq "$got" "no" "★a raw ESC byte does not remain in the body either"
assert_contains "$(body)" "rawESC" "the characters still remain"

# ★C1 (U+0080–9F) is dropped too. Filtering only ESC is not enough — the 8-bit CSI (U+009B)
#   moves the cursor on its own, without ESC. In UTF-8 it is the two bytes c2 9b, so it did not
#   trip the "code < 32" check (measured lingering in practice).
hook working "$(ups "${BS}u009b31mred${BS}u009b0m")"
case "$(body)" in *"$CSI"*) got=yes ;; *) got=no ;; esac
assert_eq "$got" "no" "★\\u009b (8-bit CSI) does not remain in the body"
assert_contains "$(body)" "red" "only C1 drops out, the characters remain"
hook working "$(ups "${CSI}31mrawCSI${CSI}0m")"
case "$(body)" in *"$CSI"*) got=yes ;; *) got=no ;; esac
assert_eq "$got" "no" "★a raw C1 byte (c2 9b) does not remain in the body either"
assert_contains "$(body)" "rawCSI" "the characters still remain"

# ── ①-b Permissions ─────────────────────────────────────────────────────────
# ★This file holds **the raw prompt text the user typed** — this is the first time conversation
#   content is placed under ~/.cache/fmux, and ~/.claude/projects, which holds the same kind of
#   thing, is 0700. This machine has two uids (1000 and 1001). Leaving it to umask gives
#   -rw-r--r-- under 022 and -rw-rw-r-- under 002 — the result would differ machine to machine.
#   It must be 0600 no matter what umask the hook runs under.
mode_of() { ls -ld "$1" 2>/dev/null | awk '{ printf "%s", substr($1, 1, 10) }'; }
oldmask=$(umask)
umask 000
rm -f "$LF"
hook working "$(ups 'instruction nobody else should read')"
assert_eq "$(mode_of "$LF")" "-rw-------" "★even running the hook with umask 000, it is 0600"
# A loose file left behind by an older build also gets tightened on the next write.
#   mv is a rename, so it carries the tmp file's mode over as-is — so this assertion is also
#   evidence that **the tmp file was 0600 too** (the tmp file already has the full body before
#   the mv, so it can be read as-is).
chmod 666 "$LF"
hook working "$(ups 'second instruction')"
assert_eq "$(mode_of "$LF")" "-rw-------" "★even an already-loose file gets tightened on the next write"
umask 022
hook working "$(ups 'third instruction')"
assert_eq "$(mode_of "$LF")" "-rw-------" "the result is the same under umask 022 too"
umask "$oldmask"

# ── ①-c Leftover tmp fragments ──────────────────────────────────────────────
# ★umask only applies to files being **newly created**. `> "$t"` just opens and truncates if
#   that name already exists, leaving the old mode untouched — mv is a rename, so that loose
#   mode follows it all the way to the destination. A fragment (.last-<id>.<pid>) is left behind
#   if the hook dies before the mv, and pids get reused, so "a name that already exists" really
#   does happen.
#
#   The fragment name has the hook process's $$ baked in, and we cannot know that pid from
#   outside. So we **pull the save function into this shell** and call it here ($$ = this
#   shell). What gets pulled in is bin/fmux verbatim — from FMUX_LASTP_MAX through the closing
#   brace of fmux_last_prompt_save is a pure definition with no side effects.
eval "$(sed -n '/^FMUX_LASTP_MAX=/,/^}$/p' "$FMUXBIN")"
assert_eq "$(command -v fmux_last_prompt_save)" "fmux_last_prompt_save" "the save function was pulled into this shell"
rm -f "$LF"
frag="$STATE/.last-9.$$"
printf 'x' > "$frag"; chmod 666 "$frag"
oldmask=$(umask); umask 000
fmux_last_prompt_save '$9' "$(ups 'write over the leftover fragment')" 1700000000
umask "$oldmask"
assert_eq "$(mode_of "$LF")" "-rw-------" \
    "★★even reusing a leftover fragment, it is 0600 — unlinked before the subshell"
assert_eq "$(body)" "write over the leftover fragment" "the content goes in correctly too"
assert_rc 1 test -e "$frag"
unset -f fmux_last_prompt_save

# ── ② Event gating ──────────────────────────────────────────────────────────
# ★PostToolUse's tool_input.prompt = the Task tool's subagent instruction text. The hook state
#   is the same working, so $2 alone cannot tell them apart. Without gating, this would overwrite
#   the real one on every tool call.
hook working "$(ups 'the real last instruction')"
hook working '{"hook_event_name":"PostToolUse","tool_name":"Task","tool_input":{"prompt":"subagent instruction text"}}'
assert_eq "$(body)" "the real last instruction" "★PostToolUse's tool_input.prompt is not the last prompt"

# codex's PreToolUse is the same working branch too
hook working '{"hook_event_name":"PreToolUse","tool_name":"shell","tool_input":{"prompt":"shell command"}}'
assert_eq "$(body)" "the real last instruction" "PreToolUse does not touch the last prompt either"

# Does not create the file even when it did not exist at all
rm -f "$LF"
hook working '{"hook_event_name":"PostToolUse","tool_input":{"prompt":"subagent instruction text"}}'
assert_rc 1 test -f "$LF"

# The hook state itself must stay correct regardless of the payload — the add-on must not break the core job
assert_eq "$(cut -d' ' -f1 "$STATE/hook-9" 2>/dev/null || true)" "working" \
    "the hook state stays correct even when the prompt is not extracted"
hook working ''
assert_eq "$(cut -d' ' -f1 "$STATE/hook-9" 2>/dev/null || true)" "working" \
    "the hook does not die even with empty stdin"
assert_rc 1 test -f "$LF"

# ★Gating is not just about correctness, it is also about **cost**. working is the branch that
#   arrives on every tool call, so calling awk when it is not a prompt submission would grow the
#   hook path's forks by the number of tool calls. Measured by the actual awk call count, not by
#   reading the code.
: > "$FMUX_AWK_LOG"
hook working '{"hook_event_name":"PostToolUse","tool_input":{"prompt":"x"}}'
hook working '{"hook_event_name":"PreToolUse","tool_input":{"prompt":"x"}}'
hook working '{"hook_event_name":"PreCompact"}'
assert_eq "$(awk_calls)" "0" "★when it is not a prompt submission, the extractor awk is never called at all — zero forks"
: > "$FMUX_AWK_LOG"
hook working "$(ups 'invoke it')"
assert_eq "$([ "$(awk_calls)" -gt 0 ] && echo yes || echo no)" "yes" \
    "it is called when it is a prompt submission"

# ── ③ The 4096-byte cap ─────────────────────────────────────────────────────
big=$(awk 'BEGIN { s = ""; for (i = 0; i < 3000; i++) s = s "가"; printf "%s", s }')
hook working "$(ups "$big")"
n=$(body | wc -c | tr -d ' ')
assert_eq "$([ "${n:-0}" -le 4096 ] && echo ok || echo "too big: $n")" "ok" \
    "★a prompt over the cap is cut off at 4096 bytes"
assert_contains "$(head1)" "trunc" "★the fact that it was truncated is recorded in the file"
# Even after cutting, it does not end on a broken byte (incomplete UTF-8 sequences are removed)
assert_rc 0 sh -c 'iconv -f UTF-8 -t UTF-8 < "$1" > /dev/null' _ "$LF"

# ── ④ Cleanup ────────────────────────────────────────────────────────────────
hook working "$(ups 'to be deleted')"
assert_rc 0 test -f "$LF"
hook clear ''
assert_rc 1 test -f "$LF"

# sweep: keeps alive sessions' files and removes dead sessions' files.
#   The check must be **the same one** hook-* uses — after a reboot, tmux reissues session ids
#   starting from $0, so if the criteria diverge, a dead session's prompt would hang at the top
#   of a new session's preview.
export FMUX_FAKE_LS2="\$9${TAB}1"
echo "idle 1 $$" > "$STATE/hook-9"           # the pid is alive = genuine
printf '1\nalive session\n' > "$LF"
echo "idle 1 $$" > "$STATE/hook-77"          # id 77 is not in the live list = orphan
printf '1\ndead session\n' > "$STATE/last-77"
hook boot ''
assert_rc 0 test -f "$LF"
assert_rc 1 test -f "$STATE/last-77"

# ghost: the id is alive but the hook file is not that session's own (dead pid) → removed together
echo "idle 1 999999" > "$STATE/hook-9"       # nonexistent pid
printf '1\nghost\n' > "$LF"
hook boot ''
assert_rc 1 test -f "$LF"

# ★Reclaiming a half-written fragment (.last-<id>.<pid>). It is left behind if the hook dies
#   before reaching the mv. The check is the pid baked into the name — if that process does not
#   exist, this fragment will never be completed. A live pid is left untouched: if it is being
#   written right now, deleting it would make the mv fail the moment we remove it, leaking the
#   prompt.
echo "idle 1 $$" > "$STATE/hook-9"
printf '1\nalive session\n' > "$LF"
printf 'x' > "$STATE/.last-9.999999"      # nonexistent pid = a fragment that will never be completed
printf 'x' > "$STATE/.last-9.$$"          # live pid = might be writing right now
printf 'x' > "$STATE/.last-9.nopid"       # not our format
hook boot ''
assert_rc 1 test -f "$STATE/.last-9.999999"      # a dead pid's fragment → reclaimed
assert_rc 0 test -f "$STATE/.last-9.$$"          # a live pid's fragment → left alone
assert_rc 1 test -f "$STATE/.last-9.nopid"       # outside the format → reclaimed
assert_rc 0 test -f "$LF"                        # sweeping fragments leaves the real file alone
rm -f "$STATE/.last-9.$$"
unset FMUX_FAKE_LS2

# ── ⑤ Render ─────────────────────────────────────────────────────────────────
PANE=$'pane one\npane two\npane three'
export FMUX_FAKE_PANE="$PANE"
pv() { FZF_PREVIEW_LINES="${2:-40}" FZF_PREVIEW_COLUMNS="${3:-60}" "$FMUXBIN" --preview zz "$1" 2>/dev/null || true; }

# ★★If the file does not exist, it is **byte-identical to before this feature was added**. No
#   header, not even a blank line, gets appended.
rm -f "$LF"
assert_eq "$(pv 9)" "$PANE" "★if the file does not exist, the preview is exactly the screen tail — byte identical"
assert_eq "$("$FMUXBIN" --preview zz 2>/dev/null || true)" "$PANE" "★it stays the same even without a session id argument"
assert_eq "$(pv 'not-a-number')" "$PANE" "it stays the same even given a non-numeric id"
# A corrupted file — even if it only has line 1, or is garbage, the preview does not break
printf '1234567890\n' > "$LF"
assert_eq "$(pv 9)" "$PANE" "a file with no body stays the same, without a header"

# ── ⑤-a Header structure ─────────────────────────────────────────────────────
# ★The shape the user settled on after three rounds. This order and this line count are the
#   contract:
#     last prompt ❯     ← the label line. Reads like a shell prompt (dim + accent)
#     first line        ← the body starts on the **next line, with no prefix**, using the full
#                          window width
#     second line
#     ──────────        ← a single separator line (dim + accent, width = cols)
#     pane one          ← the existing screen tail starts here
#   The box and vertical bar from a mid-round design were explicitly thrown out as "ugly". The
#   discard assertions below prevent them from coming back.
printf '1\nfirst line\nsecond line\n' > "$LF"
out=$(pv 9 40 44)
assert_eq "$(rowtext "$out" 1)" "last prompt ❯" "★line 1 is the label line — it reads like a shell prompt"
assert_eq "$(rowtext "$out" 2)" "first line"   "★the body starts at line 2 — no prefix, starting flush left"
assert_eq "$(rowtext "$out" 3)" "second line" "second body line"
assert_eq "$(rowtext "$out" 4)" \
    "$(awk 'BEGIN { s = ""; for (i = 0; i < 44; i++) s = s "─"; print s }')" \
    "★there is a single horizontal separator below the body"
assert_eq "$(wof "$out" 4)" "44" "★★measuring the separator's actual display width gives exactly cols (44)"
assert_eq "$(wof "$out" 1)" "13" "the label line's display width = 13 columns including ❯"
assert_eq "$(printf '%s\n' "$out" | sed -n 5p)" "pane one" "★the screen tail is left untouched — byte for byte"
assert_contains "$out" "pane three" "the screen tail continues below the header"

# ★If a discarded design comes back, it gets caught here — box, vertical bar, reverse-video bar.
hdr4=$(printf '%s\n' "$out" | head -4)
for ch in '╭' '╮' '╰' '╯' '│' '┃' '▌' '█'; do
    case "$hdr4" in *"$ch"*) got=yes ;; *) got=no ;; esac
    assert_eq "$got" "no" "no discarded decoration [$ch]"
done
case "$hdr4" in *"$ESC[7m"*) got=yes ;; *) got=no ;; esac
assert_eq "$got" "no" "reverse video (ESC[7m) is not used either"

# Color: follows the accent setting, and the label and separator are **both** dim (the body needs to stay readable)
case "$(printf '%s\n' "$out" | sed -n 1p)" in "$ESC[2;38;5;73m"*) got=yes ;; *) got=no ;; esac
assert_eq "$got" "yes" "★the label starts with dim(2) + the default accent (73)"
case "$(printf '%s\n' "$out" | sed -n 4p)" in "$ESC[2;38;5;73m"*) got=yes ;; *) got=no ;; esac
assert_eq "$got" "yes" "★the separator is also dim + accent — decoration must not be brighter than the body"
case "$(printf '%s\n' "$out" | sed -n 2p)" in *"$ESC["*) got=yes ;; *) got=no ;; esac
assert_eq "$got" "no" "we do not apply color to the body"
FMUX_ACCENT=200; export FMUX_ACCENT
out200=$(pv 9 40 44)
unset FMUX_ACCENT
assert_contains "$out200" "$ESC[2;38;5;200m" "★changing accent makes the label and separator colors follow along"
case "$out200" in *"$ESC[2;38;5;73m"*) got=yes ;; *) got=no ;; esac
assert_eq "$got" "no" "the default 73 is not left hardcoded"

# With 3 lines, there is no "… +N lines" line at all — the body uses up the entire 3-line budget
printf '1\nline1\nline2\nline3\n' > "$LF"
out=$(pv 9)
case "$out" in *"…"*) got=yes ;; *) got=no ;; esac
assert_eq "$got" "no" "with 3 lines there is no remaining-lines indicator at all"
assert_eq "$(printf '%s\n' "$out" | sed -n 6p)" "pane one" "the header is label 1 + body 3 + separator 1 = 5 lines"

# Once it exceeds 3 lines, "… +N lines" appears — that line also eats one body-budget line, so the body only gets 2
printf '1\na\nb\nc\nd\ne\nf\n' > "$LF"
out=$(pv 9 40 44)
assert_eq "$(rowtext "$out" 4)" "… +4 lines" "★once it exceeds 3 lines, it writes body 2 lines + the remaining line count"
assert_eq "$(rowtext "$out" 5)" \
    "$(awk 'BEGIN { s = ""; for (i = 0; i < 44; i++) s = s "─"; print s }')" \
    "the separator is still the very last line"
assert_eq "$(printf '%s\n' "$out" | head -6 | tail -1)" "pane one" "label 1 + body 3 + separator 1 = exactly 5 lines"
case "$(printf '%s\n' "$out" | sed -n 4p)" in "$ESC[2m"*) got=yes ;; *) got=no ;; esac
assert_eq "$got" "yes" "'… +N lines' is dim — it is an indicator, not body text"

# A truncated case shows up in the same spot too
printf '1 trunc\na\nb\nc\nd\n' > "$LF"
assert_eq "$(rowtext "$(pv 9 40 44)" 4)" "… +2 lines (truncated)" "★the fact it was truncated shows up in the render"
printf '1 trunc\na\nb\n' > "$LF"
out=$(pv 9 40 44)
assert_eq "$(rowtext "$out" 4)" "… (truncated)" "★hitting the 4096 cap shows up in the same spot too"
assert_eq "$(printf '%s\n' "$out" | head -6 | tail -1)" "pane one" "even with a truncation marker, the header never exceeds 5 lines"

# ★Width — a line that exceeds the preview width, we clip first. If we do not, fzf clips it
#   **silently**, and even the … we appended disappears = not even a "there is more" marker is
#   left behind.
long=$(awk 'BEGIN { s = ""; for (i = 0; i < 200; i++) s = s "x"; printf "%s", s }')
printf '1\n%s\n' "$long" > "$LF"
# cols=30, no prefix → the last column is reserved for … → 29 x's + … = exactly 30 columns
x29=$(awk 'BEGIN { s = ""; for (i = 0; i < 29; i++) s = s "x"; printf "%s", s }')
out=$(pv 9 40 30)
assert_eq "$(rowtext "$out" 2)" "$x29…" "★a long line is clipped to fit within the preview width"
assert_eq "$(wof "$out" 2)" "30" "★★the clipped body line's display width is exactly cols (30)"
assert_eq "$(maxw "$hdr4")" "44" "no header line exceeds cols"

# Hangul is two columns per character — clipping by byte count or character count throws the
#   width off. cols=20, no prefix → subtracting one column for … leaves 19 → nine 가's (18
#   columns) + … = 19 columns. A wide character cannot be split across a single column, so it
#   falls one column short of 20 — not exceeding it is the contract.
k=$(awk 'BEGIN { s = ""; for (i = 0; i < 20; i++) s = s "가"; printf "%s", s }')
printf '1\n%s\n' "$k" > "$LF"
out=$(pv 9 40 20)
assert_eq "$(rowtext "$out" 2)" "가가가가가가가가가…" "★Hangul is counted as two columns when clipping"
assert_eq "$(wof "$out" 2)" "19" "★★measuring the Hangul line's actual display width gives 19 columns — it does not exceed cols (20)"

# ★If it is too narrow, the header is given up on entirely — better none than a broken render
#   (the add-on principle). The boundary is the label width (13). A header that starts by
#   clipping the label cannot do its job as a header.
export FMUX_FAKE_PANE="$PANE"
printf '1\nshort instruction\n' > "$LF"
assert_eq "$(pv 9 40 12)" "$PANE" "★when cols<13, the header is not drawn and the old preview is output as-is"
assert_eq "$(pv 9 40 0)" "$PANE" "it does not break even when cols is 0"
out=$(pv 9 40 13)
assert_eq "$(rowtext "$out" 1)" "last prompt ❯" "cols=13 draws it — right above the boundary"
assert_eq "$(wof "$out" 1)" "13" "at that width the label fits exactly"

# ── ⑤-b Render sanitizing — the header does not break even given a file that never went through save ─
# A hand-crafted file, or one left by an old build, never went through save's sanitizing. The
#   render does not trust the file.
#
# ★Tabs. Measured in practice: a build that counted width as 1 produced 58 columns against a
#   20-column limit — because the terminal expands a tab out to the next tab stop while we
#   counted it as 1 column. Flattening it to a space makes the counted width match the drawn width.
printf '1\na%sb%sc\n' "$TAB" "$TAB" > "$LF"
assert_eq "$(rowtext "$(pv 9 40 20)" 2)" "a b c" "★the render flattens a tab to a single space"
tabline=$(awk -v t="$TAB" 'BEGIN { s = ""; for (i = 0; i < 40; i++) s = s t "x"; printf "%s", s }')
printf '1\n%s\n' "$tabline" > "$LF"
out=$(pv 9 40 20)
assert_eq "$(wof "$out" 2)" "20" "★★a line containing a tab also has a display width of exactly cols (20)"
case "$(printf '%s\n' "$out" | head -3)" in *"$TAB"*) got=yes ;; *) got=no ;; esac
assert_eq "$got" "no" "the tab itself does not go out into the preview"

# ★C1 (U+0080–9F). The 8-bit CSI (U+009B) moves the cursor without ESC — if the preview breaks,
#   to the user it looks like the entire popup is broken. Blocked even for a file that never
#   went through save's sanitizing.
printf '1\n%s31mred%s0m\n' "$CSI" "$CSI" > "$LF"
out=$(pv 9 40 60)
case "$out" in *"$CSI"*) got=yes ;; *) got=no ;; esac
assert_eq "$got" "no" "★the render strips out C1 (c2 9b)"
assert_contains "$out" "red" "only C1 drops out, the characters remain"
assert_eq "$(rowtext "$out" 2)" "31mred0m" "only the two C1 bytes drop out, the rest is untouched"
assert_eq "$(wof "$out" 2)" "8" "★the display width of the line with C1 stripped = \"31m\" 3 + red 3 + \"0m\" 2 = 8 columns"
# The label and separator are drawn using color escapes, so the overall output legitimately
#   contains ESC — we only look at the body with escapes stripped
printf '1\n%s[31mrawESC\n' "$ESC" > "$LF"
out=$(pv 9 40 60)
case "$(printf '%s\n' "$out" | sed -n 2p | strip_ansi)" in *"$ESC"*) got=yes ;; *) got=no ;; esac
assert_eq "$got" "no" "★the render strips out a raw ESC too"
assert_eq "$(rowtext "$out" 2)" "[31mrawESC" "only ESC drops out, the rest is untouched"

# ── ⑤-c Width table — wide characters that were missing ─────────────────────
# ★Measured in practice: `✅`×30 @cols=20 came out to 37 columns. wcw()'s emoji range starts
#   at `v >= 127744` (U+1F300), so ✅(U+2705), ❌(U+274C), ⭐(U+2B50), ⏰(U+23F0), which live in
#   the BMP, and Hangul Jamo Extended-A (U+A960–U+A97C) were all counted as 1 column across the
#   board. This is not just a "the line gets longer" problem — the … we appended itself gets
#   pushed outside the width and clipped by fzf, so **not even a "this was truncated" marker
#   remains**.
#   Written as raw bytes — bash 3.2 does not have $'\uXXXX' (the default shell on Mac).
EMO_OK='\342\234\205'      # ✅ U+2705
EMO_X='\342\235\214'       # ❌ U+274C
EMO_STAR='\342\255\220'    # ⭐ U+2B50
EMO_CLOCK='\342\217\260'   # ⏰ U+23F0
JAMO_A='\352\245\240'      # ꥠ U+A960 — Hangul Jamo Extended-A
for pair in "$EMO_OK ✅ U+2705" "$EMO_X ❌ U+274C" "$EMO_STAR ⭐ U+2B50" \
            "$EMO_CLOCK ⏰ U+23F0" "$JAMO_A ꥠ U+A960"; do
    set -- $pair
    oct="$1"; sym="$2"; cp="$3"
    line=$(awk -v c="$(printf "$oct")" 'BEGIN { s = ""; for (i = 0; i < 30; i++) s = s c; printf "%s", s }')
    printf '1\n%s\n' "$line" > "$LF"
    out=$(pv 9 40 20)
    # nine 2-column characters (18 columns) + … = 19 columns. If the width table counts them as
    #   1 column, it comes out to 39.
    assert_eq "$(wof "$out" 2)" "19" \
        "★★$sym($cp)×30 @cols=20 — measuring the first body line's actual display width gives 19 columns (does not exceed cols)"
    assert_eq "$(rowtext "$out" 2)" \
        "$(awk -v c="$(printf "$oct")" 'BEGIN { s = ""; for (i = 0; i < 9; i++) s = s c; print s "…" }')" \
        "$sym only fits 9 of them, then … is appended"
done
# The same holds even when mixed together — if the clip position does not line up with a
#   character boundary, it shows up immediately. A wide character cannot be split across one
#   column, so it can fall one column short of cols. The contract is "does not exceed cols, and
#   fills to within one column of it" — if the width table is wrong, it overflows by nearly
#   double right away.
fits() {   # $1=preview output  $2=cols
    _w=$(wof "$1" 2)
    if [ "$_w" -le "$2" ] && [ "$_w" -ge $(($2 - 1)) ]; then echo ok; else echo "$_w vs cols=$2"; fi
}
mixed=$(awk -v a="$(printf "$EMO_OK")" -v b="$(printf "$EMO_X")" -v c="$(printf "$JAMO_A")" \
    'BEGIN { s = ""; for (i = 0; i < 12; i++) s = s a "가" b "x" c; printf "%s", s }')
printf '1\n%s\n' "$mixed" > "$LF"
for c in 20 21 33 44 80; do
    assert_eq "$(fits "$(pv 9 40 "$c")" "$c")" "ok" \
        "★even mixing wide characters with Hangul and ASCII, it does not exceed cols=$c and fills to within one column"
done

# ── ⑤-d decode — an unreadable byte consumes only one byte ──────────────────
# ★If a character the user typed follows right after `0xC2`, an older build swallowed that
#   character too (measured in practice). v = 2*64 + (65 % 64) = 129 → caught in the C1 net
#   (128–159), and with CPLEN=2, the A disappears.
printf '1\n\302ABCDE\n' > "$LF"
assert_eq "$(rowtext "$(pv 9 40 40)" 2)" "ABCDE" \
    "★★the A after 0xC2 does not disappear — only the broken lead byte is dropped"
# Invalid lead bytes — 0xC0, 0xC1 (overlong encoding), 0xF5–0xFF (out of range). Treating them
#   as a normal multi-byte lead drags 1–3 trailing characters along with it (0xC0 + "X" →
#   treated as C0 with v=24 → X vanishes too).
printf '1\n\300X\301Y\365Z\377W\n' > "$LF"
assert_eq "$(rowtext "$(pv 9 40 40)" 2)" "XYZW" \
    "★★0xC0, 0xC1, 0xF5, 0xFF are not valid lead bytes — they do not drag the following character along"
# ★The single line above alone cannot measure the **lead-byte check** — since what follows is
#   not a continuation byte, the continuation-byte check catches it first (confirmed by mutation
#   testing: even reverting to `c < 192`, the assertion above still passed).
#   Only appending a real continuation byte afterward isolates the lead-byte check alone.
#     0xC0 0xA0 → overlong encoding. An older build computed v=32 (space) and **emitted the two
#     broken bytes as-is**.
#     0xC1 0xA0 → computed as v=96 ('`'), also emitted as-is.
#     0xF5 0x80 0x80 0x80 → computed as v=1310720 (exceeds U+10FFFF), and the four bytes came
#     out as-is.
for bad in '\300\240' '\301\240' '\365\200\200\200'; do
    printf "1\nA${bad}B\n" > "$LF"
    out=$(pv 9 40 40)
    assert_eq "$(rowtext "$out" 2)" "AB" \
        "★★even when what follows is a continuation byte, an invalid lead byte is dropped [$bad]"
done
# If what follows a 3-byte lead is not a continuation byte, it is treated as 1 byte
printf '1\n\340AB\n' > "$LF"
out=$(pv 9 40 40)
assert_eq "$(rowtext "$out" 2)" "AB" "★an 0xE0 not followed by a continuation byte is dropped on its own"
case "$(printf '%s\n' "$out" | sed -n 2p)" in *$'\340'*) got=yes ;; *) got=no ;; esac
assert_eq "$got" "no" "a broken lead byte does not leak into the preview"
# A truncated sequence (a lead byte cut off at the end of a line) is caught by the same net
printf '1\nOK\342\234\n' > "$LF"
out=$(pv 9 40 40)
assert_eq "$(rowtext "$out" 2)" "OK" "a truncated UTF-8 tail is dropped whole"
assert_eq "$(wof "$out" 2)" "2" "a broken byte does not leave a phantom column in the width calculation"
assert_eq "$(maxw "$(printf '%s\n' "$out" | head -3)")" "40" "the separator is still exactly cols"
# A genuine U+FFFD is intact as 3 bytes, so it survives — must not be confused with a broken-fragment judgment
printf '1\nA\357\277\275B\n' > "$LF"
assert_eq "$(rowtext "$(pv 9 40 40)" 2)" "$(printf 'A\357\277\275B')" "an intact U+FFFD remains as a character"

# ★Line accounting — the screen tail shrinks by however much the header ate
export FMUX_FAKE_PANE=$(awk 'BEGIN { for (i = 1; i <= 20; i++) print "screen line " i }')
printf '1\na\nb\nc\nd\ne\n' > "$LF"
out=$(pv 9 10 60)
assert_eq "$(printf '%s\n' "$out" | grep -c .)" "10" "★the preview's total line count does not exceed FZF_PREVIEW_LINES"
assert_contains "$out" "screen line 20" "the screen tail still shows the 'very bottom'"
assert_eq "$(rowtext "$out" 2)" "a" "the header is still alive too"
# ★Budget: label 1 + body 3 (= body 2 + "… +N lines") + separator 1 = 5 lines come out of the
#   screen's share. 5+5=10.
assert_eq "$(printf '%s\n' "$out" | sed -n 6p)" "screen line 16" \
    "★the header eats exactly 5 lines and the screen uses the remaining 5"
# When there is no header, the entire 20-line window is used (evidence that the accounting only reacts to the header)
rm -f "$LF"
assert_eq "$(pv 9 10 60 | grep -c .)" "10" "when there is no header, the screen uses the whole window"

# ── ⑥ Wiring — the field --list provides and the field the preview receives must be the same one ──
# If these diverge, the preview can never find the file (a hole the design doc missed).
export FMUX_FAKE_LS5="\$42${TAB}1700000000${TAB}0${TAB}-${TAB}zz"
row=$("$FMUXBIN" --list 2>/dev/null | head -1) || row=""
assert_eq "${row%%$TAB*}" "zz" "--list's field 1 is still the session name"
assert_eq "${row##*$TAB}" "42" "★--list's field 3 is the session id — agent session"
assert_eq "$(printf '%s' "$row" | tr -cd "$TAB" | wc -c | tr -d ' ')" "2" "there are exactly three fields"
# A tool session goes through a different printf — that path needs to carry it too, so the preview works on any row
FMUX_FAKE_PANECMD=bash
export FMUX_FAKE_PANECMD
row=$("$FMUXBIN" --list 2>/dev/null | head -1) || row=""
assert_eq "${row##*$TAB}" "42" "★a tool session row also carries the session id in field 3"
unset FMUX_FAKE_PANECMD FMUX_FAKE_LS5
assert_contains "$(cat "$FMUXBIN")" "--preview {1} {3}" "★fzf passes that field 3 to the preview"
assert_contains "$(cat "$FMUXBIN")" "--with-nth=2" "only field 2 is displayed — the id does not leak onto the screen"

assert_no_tmux_mutation "this file did not touch a live tmux server"

fmux_test_done
