# ── Last prompt (last-<sid>) ────────────────────────────────────────────
# Material for pinning "what did I ask this session to do" at the top of the preview.
# We don't scrape the screen — the UserPromptSubmit hook payload already carries the
# prompt body verbatim. The hook already reads that payload from stdin and parses it,
# so the material is already at hand.
#
# This feature is **an extra**. Whatever fails here must not leak into the preview,
# status judgment, or manifest. So the function below returns 0 on every path, and
# the render side just falls back to the old preview if it can't build a header.
#
# ── Why not tt_jv (measured) ─────────────────────────────────────────────
# tt_jv's regex assumes "no quotes inside the value." That holds for session_id/cwd
# but breaks four ways for prompts. All four reproduced:
#   ① {"prompt":"the \"dependencies\" section of the README"} → the extracted value is
#      just the fragment `the \` before it. The character class [^"]* stops at the "
#      of \". The preview becomes wholesale garbage.
#   ② \n isn't unescaped → it stays as backslash+n, not a newline. The "max 3 lines"
#      calculation no longer holds.
#   ③ \uXXXX isn't unescaped → ESC survives as a literal string. What the hook receives
#      is user input, so actually unescaping control characters would break the preview
#      (which is why we discard them below).
#   ④ There's no notion of depth → it mistakes PostToolUse's tool_input.prompt (the Task
#      tool's subagent instruction) for a prompt. This isn't theoretical: --hooks-json
#      bundles UserPromptSubmit/PostToolUse/PreCompact/PostCompact **all under a single
#      `--hook working`**, and --codex-hooks likewise bundles UserPromptSubmit/PreToolUse/
#      PostToolUse under working. Looking at $2 alone can't tell you whether this is a
#      prompt submission, so every tool call becomes a false positive.
# We leave tt_jv itself untouched — it's fine for its own purpose and keeps the hook
# path's zero-fork rule. Prompts get pulled by a dedicated scanner instead.
#
# ── Why awk instead of jq ────────────────────────────────────────────────
# jq is not a dependency of this repo. install.sh's gate checks only for bash/tmux/fzf/awk
# plus flock/make (optional), and there are zero jq calls anywhere in src/ (60-rc.sh even
# spells out the rule "no jq, no forks"). Using jq would mean **this feature alone silently
# fails to appear** on a machine that lacks it. awk is already a required dependency.
#
# ── awk syntax constraints ──────────────────────────────────────────────────
# The Pi's default is mawk 1.3.4; the Mac uses BSD awk. No gensub, no multi-character RS,
# no match() array argument, no mktime, no hex literals (same rule as TT_ACT_AWK/TT_MF_CHECK_AWK).
# Called with LC_ALL=C — every structural character the scanner deals with is ASCII, and
# non-ASCII text can just pass through as raw bytes. That keeps length/substr behaving
# identically **byte-wise** across every awk, and keeps the 4096-"byte" cap independent
# of the implementation.

TT_LASTP_MAX=4096      # Storage cap (bytes). Keeps a huge pasted instruction from eating disk and preview.
# Cap (bytes) for truncating the payload before handing it to awk.
#   ⚠ Without this line the hook stalls outright. mawk's character-by-character
#     accumulation is O(n²) — measured: 36KB=0.04s, 140KB=0.54s, 420KB=10.3s,
#     1.4MB=120s+. claude's hook timeout is 10s, codex's is 5s. A single paste can kill
#     the hook. Truncating to 16KB brings it down to 0.02s.
#   The prompt comes after the payload's leading fields (session_id, cwd, etc.), and the
#   storage cap is 4096 bytes, so nothing is gained by going past 16KB. If truncation cuts
#   the value off before it closes, the scanner records that as 'truncated' (the cut flag
#   below) — it doesn't give up silently.
TT_LASTP_SCAN=16384

# Extracts just the depth-1 prompt key, unescapes it, and strips control characters.
#   rc 0 = extracted intact / rc 2 = extracted but truncated / rc 1 = absent (writes nothing)
# Tracks in/out-of-string state, escape state, and brace depth by hand, so it
#   · isn't fooled by tool_input.prompt (depth 2)
#   · isn't fooled by a fake {"prompt":"fake"} the user pasted inside the actual prompt value
TT_LASTP_AWK='
    BEGIN { for (i = 1; i < 256; i++) ORD[sprintf("%c", i)] = i }
    { if (length(buf) < lim) buf = buf $0 "\n" }
    END {
        buf = substr(buf, 1, lim)
        n = length(buf); depth = 0; instr = 0; capture = 0; i = 1
        tok = ""; out = ""; found = 0; cut = 0
        while (i <= n) {
            c = substr(buf, i, 1)
            if (instr) {
                # Escapes are passed through as two characters intact — unescaping here would make \" look like the end of the string
                if (c == "\\") { tok = tok "\\" substr(buf, i + 1, 1); i += 2; continue }
                if (c == "\"") {
                    instr = 0
                    if (capture) { out = tok; found = 1; break }
                    last = tok; i++
                    # Whether the string we just closed is a key or a value: check if the next non-blank char is a :
                    j = i; while (j <= n && substr(buf, j, 1) ~ /[ \t\n\r]/) j++
                    if (substr(buf, j, 1) == ":" && depth == 1 && last == "prompt") {
                        k = j + 1; while (k <= n && substr(buf, k, 1) ~ /[ \t\n\r]/) k++
                        if (substr(buf, k, 1) == "\"") { capture = 1; instr = 1; tok = ""; i = k + 1; continue }
                    }
                    continue
                }
                tok = tok c; i++; continue
            }
            if (c == "\"") { instr = 1; tok = ""; i++; continue }
            if (c == "{" || c == "[") { depth++; i++; continue }
            if (c == "}" || c == "]") { depth--; i++; continue }
            i++
        }
        # Hit the input cap and ended without seeing a closing quote = treat EOF as the end of the value
        if (!found && capture && instr) { out = tok; found = 1; cut = 1 }
        if (!found) exit 1
        s = unesc(out)
        if (length(s) > maxb) { s = utf8trim(substr(s, 1, maxb)); cut = 1 }
        if (length(s) == 0) exit 1
        printf "%s", s
        if (cut) exit 2
    }
    # JSON unescape + control-character removal.
    #   Only newline and tab survive. The rest of the control characters (ESC in particular)
    #   are dropped — what the hook receives is user input, and if ESC leaked into the
    #   preview, cursor moves and screen clears would actually execute and wreck the cockpit.
    #   ⚠ Filtering C0 alone is not enough. C1 (U+0080–9F) contains the 8-bit CSI (U+009B),
    #     which moves the cursor on its own without an ESC. In UTF-8 this is the two bytes
    #     c2 80..c2 9f, so it does not trip the ORD[c] < 32 check — measured: `c2 9b` was
    #     found sitting untouched in a saved file. We treat the two bytes as one unit.
    # Codepoint → UTF-8 byte sequence. Under LC_ALL=C, sprintf("%c", big_number) cannot be
    #   trusted (it varies by implementation) — so we assemble the bytes ourselves. Without
    #   this, an escape like 가 turns wholesale into "?", and a Korean prompt becomes a
    #   field of question marks. claude/codex send non-ASCII as raw UTF-8 so this path is not
    #   normally hit, but that is an observation, not a contract.
    function utf8enc(v) {
        if (v < 128)   return sprintf("%c", v)
        if (v < 2048)  return sprintf("%c%c", 192 + int(v / 64), 128 + (v % 64))
        if (v < 65536) return sprintf("%c%c%c", 224 + int(v / 4096), 128 + int(v / 64) % 64, 128 + (v % 64))
        return sprintf("%c%c%c%c", 240 + int(v / 262144), 128 + int(v / 4096) % 64,
                       128 + int(v / 64) % 64, 128 + (v % 64))
    }
    function unesc(s,   r, p, m, c, e, lo, code) {
        r = ""; p = 1; m = length(s)
        while (p <= m) {
            c = substr(s, p, 1)
            if (c != "\\") {
                code = ORD[c]
                if (code == 127 || (code < 32 && c != "\n" && c != "\t")) { p++; continue }
                if (code == 194) {                             # lead byte of C1
                    e = ORD[substr(s, p + 1, 1)]
                    if (e >= 128 && e <= 159) { p += 2; continue }
                }
                r = r c; p++; continue
            }
            e = substr(s, p + 1, 1)
            if (e == "n")      { r = r "\n"; p += 2 }
            else if (e == "t") { r = r "\t"; p += 2 }
            else if (e == "r" || e == "b" || e == "f") { p += 2 }
            else if (e == "\"" || e == "\\" || e == "/") { r = r e; p += 2 }
            else if (e == "u") {
                code = hex4(substr(s, p + 2, 4)); p += 6
                # Surrogate pairs (emoji like 😀) need both halves combined into one character
                if (code >= 55296 && code <= 56319 && substr(s, p, 2) == "\\u") {
                    lo = hex4(substr(s, p + 2, 4))
                    if (lo >= 56320 && lo <= 57343) {
                        code = 65536 + (code - 55296) * 1024 + (lo - 56320); p += 6
                    }
                }
                if (code == 10) r = r "\n"
                else if (code == 9) r = r "\t"
                # Control character — drop it. Both C0+DEL (including ESC) and C1 (including the 8-bit CSI).
                else if (code < 32 || code == 127 || (code >= 128 && code <= 159)) { }
                else r = r utf8enc(code)
            }
            else if (e == "") { p += 2 }
            else { r = r e; p += 2 }
        }
        return r
    }
    function hex4(h,   d, v, q, ch) {
        d = "0123456789abcdef"; v = 0
        for (q = 1; q <= 4; q++) {
            ch = substr(h, q, 1)
            if (ch >= "A" && ch <= "F") ch = substr("abcdef", index("ABCDEF", ch), 1)
            v = v * 16 + (index(d, ch) - 1)
        }
        return v
    }
    # Strips a leftover incomplete UTF-8 sequence at a byte-cut boundary — without this a broken character sits at the end of the preview
    function utf8trim(s,   L, q, c, need) {
        L = length(s)
        for (q = 0; q < 4 && L - q >= 1; q++) {
            c = ORD[substr(s, L - q, 1)]
            if (c < 128) return s                              # ended on ASCII = complete
            if (c >= 192) {                                    # found the lead byte
                need = (c < 224) ? 2 : (c < 240 ? 3 : 4)
                if (q + 1 == need) return s                    # exact match = complete
                return substr(s, 1, L - q - 1)                 # short = drop the whole thing
            }
        }
        return s
    }'

# Called from the hook path. Only actually does work when it's UserPromptSubmit.
#   ⚠ The bash pre-gate is the crux — PostToolUse/PreToolUse/PreCompact bounce back here
#     on a single string comparison, so they add zero forks (keeping the hook path's cost
#     rule). The awk fork happens once per prompt a human types, i.e. independent of the
#     number of tool calls.
#   Safe even if the gate is loose (say, that string happens to appear somewhere else in
#     the payload): the scanner only looks at depth-1 prompt, so other events end quietly
#     with rc 1. Example: a session editing this repo has PostToolUse carry this very
#     source text wholesale inside tool_input, but that's inside a string value, so it
#     never bumps the depth.
tt_last_prompt_save() {
    local sid="$1" payload="$2" now="$3" body rc=0 id f t
    case "$payload" in
        *'"hook_event_name"'*'"UserPromptSubmit"'*) ;;
        *) return 0 ;;
    esac
    # A herestring writes the whole string to a temp file — passing a 3MB paste through
    #   as-is costs 0.4s on that write alone. We shrink it here first. ${v:0:n} counts
    #   **characters** under a UTF-8 locale, so at least n bytes always remain →
    #   awk's byte cap (lim) never trims anything out of the leading part it sees.
    body=$(LC_ALL=C awk -v lim="$TT_LASTP_SCAN" -v maxb="$TT_LASTP_MAX" \
            "$TT_LASTP_AWK" <<< "${payload:0:TT_LASTP_SCAN}" 2>/dev/null) || rc=$?
    case "$rc" in 0|2) ;; *) return 0 ;; esac
    [ -n "$body" ] || return 0
    id=${sid#\$}
    f="$STATE/last-$id"
    # The tmp name starts with a dot — so it doesn't match the last-* glob (sweep, preview).
    t="$STATE/.last-$id.$$"
    # Atomic write: the hook is a short-lived process that runs on every event, and the
    #   preview reads the same file concurrently.
    #   Line 1 = write timestamp (+ trunc if truncated) / line 2 onward = body
    # ── 0600 ───────────────────────────────────────────────────────────────
    # ⚠ This file holds **the user's prompt text verbatim**. This is the first time
    #   conversation content lands in ~/.cache/tt — the equivalent, ~/.claude/projects,
    #   is 0700. Leaving it to umask gives different results per machine: 022 yields
    #   -rw-r--r--, 002 yields -rw-rw-r--. Either way **a different uid on the same
    #   machine can read it** (even this one Pi has both uid 1000 and 1001). So we set
    #   umask directly here — the result must be the same no matter the caller's umask.
    #   What we lock down starts with the tmp file: even before the mv, the body is
    #   already sitting there in full and readable. We don't chmod the destination
    #   separately — mv is a rename, so it carries the tmp file's mode over as-is, and
    #   that means even a loose last-<id> left by an older build gets fixed to 0600 on
    #   the very next write. We use a subshell so we don't have to restore umask — this
    #   path only runs when a human types a prompt (not per tool call), so one extra fork
    #   doesn't break the hook-cost rule.
    #   ⚠ umask only applies to **newly created** files. `> "$t"` just opens and truncates
    #     if that name already exists, leaving the old mode in place — and since mv is a
    #     rename, that loose mode follows it to the destination. A leftover fragment
    #     (.last-<id>.<pid>) can survive if the hook dies before the mv, and pids get
    #     reused, so "the name already exists" really happens. We remove it before
    #     entering the subshell so it's always freshly created.
    rm -f "$t" 2>/dev/null || true
    ( umask 077
      { if [ "$rc" = 2 ]; then echo "$now trunc"; else echo "$now"; fi
        printf '%s\n' "$body"; } > "$t" ) 2>/dev/null || { rm -f "$t" 2>/dev/null; return 0; }
    mv -f "$t" "$f" 2>/dev/null || rm -f "$t" 2>/dev/null
    return 0
}

# Renders the preview header. Args: cols (preview width), acc (accent 256-color number).
#   Input: the last-<sid> file.
#   Output = 1 label line + body up to 3 lines + 1 separator line = 5 lines max.
#   If there's no body, or the width can't even fit the label line, rc 1 and emit nothing.
#
#     last prompt ❯
#     keep refactoring the device domain.
#     based on what got collapsed via Widget.change
#     … +4 lines
#     ──────────────────────────────────────
#     ● Running 1 shell command…              ← the screen tail starts here
#
#   ── Why it looks like this (chosen by the user over three iterations) ──────────
#   ① **The label gets its own line.** `last prompt ❯` reads like a shell prompt — so it
#      says, undecorated, that everything from the next line down is "text a human typed."
#      That's where the sense of separation comes from.
#   ② **The body carries no prefix.** The earlier version put `❯ `/`  ` (two columns) in
#      front, which meant two more columns' worth got clipped. Once the label moves up top,
#      the prefix has nothing left to do — the body uses the full window width.
#   ③ **Boxes, vertical bars, and reverse-video bars were dropped.** All were built and
#      tried in intermediate versions and discarded as "ugly." Don't rebuild them. Bonus:
#      a box needs every line padded to align the right border, so a single-column error
#      in the width calculation immediately turns ragged. Now, even with a width error, the
#      worst case is "one character more/less gets clipped."
#   ④ Color follows the configured accent, but the label and separator are **both dim**.
#      What needs reading is the body, not the decoration — if the decoration is brighter
#      than the body, the eye goes there first.
#
#   ── Why we need width math ──────────────────────────────────────────────────
#   It's not about wrapping — it's about **who does the clipping**. 90-main.sh's
#   --preview-window has no wrap, and fzf's default is nowrap. So a line past the width
#   doesn't wrap (line-count accounting stays intact) — fzf clips it **silently**. The very
#   top line of the preview is the answer to "what did I ask for," and if it's cut off with
#   no sign that more follows, the remainder reads as the end of the instruction. So we clip
#   it ourselves first and append …. Korean characters are two columns wide each, so neither
#   byte count nor character count measures it → we decode UTF-8 directly (if wcw's width
#   table is wrong, our appended … itself gets clipped first, so not even a "this was cut"
#   marker survives — measured: `✅`×30 @cols=20 came out at 37 columns).
#
#   ⚠ We run one more pass through sane() right before clipping. The save side (unesc)
#     already filters, but the render side **doesn't trust the file**: hand-crafted files,
#     files left by an older build, files another uid dropped in — all of these arrive as-is.
#     If one header line breaks, the whole popup looks broken to the user's eye.
TT_LASTP_VIEW_AWK='
    BEGIN {
        for (i = 1; i < 256; i++) ORD[sprintf("%c", i)] = i
        E = sprintf("%c", 27); DIM = E "[2m"; RST = E "[0m"
        # Color follows the configured accent — hardcoding it would leave this the one
        #   spot untouched when a teammate changes their color.
        #   Label and separator both layer on dim: what needs reading is the body, not
        #   the decoration.
        if (acc !~ /^[0-9]+$/ || acc + 0 > 255) acc = "73"
        ACC = E "[2;38;5;" acc "m"
        LABEL = "last prompt ❯"                   # reads like a shell prompt — next line down is my own text
        n = 0
    }
    NR == 1 { trunc = ($2 == "trunc"); next }
    { n++; body[n] = $0 }
    END {
        if (n == 0) exit 1
        cols = cols + 0
        # Better to draw nothing than draw it wrong — this feature is an extra. If we give
        #   up on the header entirely, 90-main.sh falls back to the old preview (screen
        #   tail) **byte for byte**. If the width cannot even fit the label line, the header
        #   would start by clipping the label itself = better to give up.
        if (cols < width(LABEL)) exit 1
        # Line budget: label 1 + body up to 3 + separator 1 = 5. "… +N lines" also eats one
        #   body line, so if we need to show there is more, the body only gets to show 2.
        ell = (n > 3 || trunc)
        m = ell ? ((n > 2) ? 2 : n) : n
        rest = n - m
        print ACC LABEL RST
        # The body has no prefix — it uses the full window width. A two-column prefix would mean two more columns get clipped.
        for (i = 1; i <= m; i++) print clip(sane(body[i]), cols)
        if (ell) {
            t = "…"
            if (rest > 0) t = t " +" rest " lines"
            if (trunc)    t = t " (truncated)"
            print DIM clip(t, cols) RST
        }
        print ACC rep("─", cols) RST
    }
    function rep(c, k,   s) { s = ""; while (k-- > 0) s = s c; return s }
    # Render-side sanitizing. Runs **before** clip — before we count width, only characters
    #   whose width is well-defined should remain.
    #   · Tab → one space. We flatten it rather than counting its width because what sets
    #     the display width of a tab is the tab stops of the terminal, and the preview window
    #     does not start at the left edge of the terminal but wherever fzf placed it
    #     (--preview-window right,65%), so we have no way to know where the stops fall. A
    #     version that counted tab as width 1 was measured to come out at 58 columns
    #     against a 20-column limit — the header got pushed clean out of the preview.
    #     Flattening it makes the width we count and the width the terminal draws equal
    #     by definition.
    #   · C0, DEL, and C1 (U+0080–9F) are dropped. There is no newline inside a single line
    #     to begin with (input is line-based), and ESC (C0) and the 8-bit CSI (C1, U+009B)
    #     move the cursor if drawn as-is.
    #   · Bytes that cannot be read as UTF-8 are also dropped — a lone continuation byte
    #     (0x80–0xBF), an overlong-encoding lead byte (0xC0/0xC1), out of range (0xF5–0xFF),
    #     and a lead byte not followed by a continuation byte. These are broken fragments
    #     whose width is undefined, and the single byte 0x9B reads as CSI on an 8-bit
    #     terminal. decode() consumes **only that one byte** and returns for bytes like
    #     these, so the character after it survives intact (the spot where an earlier
    #     version swallowed the following character too — see the decode() comment).
    function sane(s,   L, p, v, o) {
        L = length(s); p = 1; o = ""
        while (p <= L) {
            v = decode(s, p)
            if (v == 65533 && CPLEN == 1) { p++; continue }        # broken UTF-8 fragment
            if (v == 9) o = o " "
            else if (v < 32 || v == 127 || (v >= 128 && v <= 159)) { }
            else o = o substr(s, p, CPLEN)
            p += CPLEN
        }
        return o
    }
    function width(s,   L, p, t) {
        L = length(s); p = 1; t = 0
        while (p <= L) { t += wcw(decode(s, p)); p += CPLEN }
        return t
    }
    function clip(s, w,   L, p, cw, used, o) {
        if (width(s) <= w) return s
        L = length(s); p = 1; used = 0; o = ""
        while (p <= L) {
            cw = wcw(decode(s, p))
            if (used + cw > w - 1) break          # leave the last column open for the …
            o = o substr(s, p, CPLEN); used += cw; p += CPLEN
        }
        return o "…"
    }
    # Decodes one UTF-8 character to a codepoint. Bytes consumed are returned in the
    #   global CPLEN.
    #   An unreadable byte consumes **only one byte** and returns 65533 — that is what lets
    #   sane() drop just that one byte while keeping the character after it intact.
    #   ⚠ An earlier version accepted 0xC0/0xC1/0xF5–0xFF as valid lead bytes, and in the
    #     multi-byte branch never checked whether the following bytes were continuation
    #     bytes (0x80–0xBF). Two measured cases:
    #       · `0xC2` + "ABCDE" → v = 2*64 + (65 % 64) = 129, which falls in the C1 net
    #         (128–159), and with CPLEN=2 **the A the user typed silently vanished**.
    #       · `0xC0` + "X"     → v = 0*64 + (88 % 64) = 24, treated as C0 and swallowed the X along with it.
    function decode(s, p,   c, need, v, q, b) {
        c = ORD[substr(s, p, 1)]
        if (c < 128) { CPLEN = 1; return c }
        # Values that cannot be a lead byte: a lone continuation byte (128–191), an
        #   overlong encoding (192, 193), or out of range (245–255). All consume one byte.
        if (c < 194 || c > 244) { CPLEN = 1; return 65533 }
        if (c >= 240) { need = 4; v = c - 240 }
        else if (c >= 224) { need = 3; v = c - 224 }
        else { need = 2; v = c - 192 }
        for (q = 1; q < need; q++) {
            b = ORD[substr(s, p + q, 1)]
            # If we run past the end of the string, ORD[""] is undefined = 0, which trips this check (a truncated sequence).
            if (b < 128 || b > 191) { CPLEN = 1; return 65533 }
            v = v * 64 + (b % 64)
        }
        CPLEN = need
        return v
    }
    # East Asian wide characters get two columns. No hex literals (mawk/BSD awk
    #   compatibility). Only the W/F values of EastAsianWidth are included. A (Ambiguous)
    #   is left at 1 column — that is the terminal default.
    #   ⚠ The symbol/emoji ranges of the BMP were entirely missing (measured: `✅`×30 @cols=20
    #     → 37 columns). A single `if (v >= 127744 …)` line only catches U+1F300 and above —
    #     commonly used ones like ✅ (U+2705), ❌ (U+274C), ⭐ (U+2B50), ⛔ (U+26D4) all live
    #     below that. This is not just "the line gets a bit longer": the … we append gets
    #     pushed past the width itself and gets clipped by fzf, so **not even a sign that
    #     it was cut survives**.
    function wcw(v) {
        if (v < 4352)                   return 1      # most of ASCII, Latin, and symbols end here
        if (v <= 4447)                  return 2      # Hangul Jamo
        if (v >= 8986   && v <= 8987)   return 2      # ⌚⌛
        if (v == 9001   || v == 9002)   return 2      # 〈 〉
        if (v >= 9193   && v <= 9196)   return 2      # ⏩⏪⏫⏬
        if (v == 9200   || v == 9203)   return 2      # ⏰ ⏳
        if (v >= 9725   && v <= 9726)   return 2      # ◽◾
        if (v >= 9748   && v <= 9749)   return 2      # ☔☕
        if (v >= 9800   && v <= 9811)   return 2      # ♈–♓ zodiac signs
        if (v == 9855)                  return 2      # ♿
        if (v == 9875)                  return 2      # ⚓
        if (v == 9889)                  return 2      # ⚡
        if (v >= 9898   && v <= 9899)   return 2      # ⚪⚫
        if (v >= 9917   && v <= 9918)   return 2      # ⚽⚾
        if (v >= 9924   && v <= 9925)   return 2      # ⛄⛅
        if (v == 9934)                  return 2      # ⛎
        if (v == 9940)                  return 2      # ⛔
        if (v == 9962)                  return 2      # ⛪
        if (v >= 9970   && v <= 9971)   return 2      # ⛲⛳
        if (v == 9973)                  return 2      # ⛵
        if (v == 9978)                  return 2      # ⛺
        if (v == 9981)                  return 2      # ⛽
        if (v == 9989)                  return 2      # ✅
        if (v >= 9994   && v <= 9995)   return 2      # ✊✋
        if (v == 10024)                 return 2      # ✨
        if (v == 10060)                 return 2      # ❌
        if (v == 10062)                 return 2      # ❎
        if (v >= 10067  && v <= 10069)  return 2      # ❓❔❕
        if (v == 10071)                 return 2      # ❗
        if (v >= 10133  && v <= 10135)  return 2      # ➕➖➗
        if (v == 10160)                 return 2      # ➰
        if (v == 10175)                 return 2      # ➿
        if (v >= 11035  && v <= 11036)  return 2      # ⬛⬜
        if (v == 11088)                 return 2      # ⭐
        if (v == 11093)                 return 2      # ⭕
        if (v >= 11904  && v <= 42191)  return 2      # CJK Radicals ~ Yi
        if (v >= 43360  && v <= 43388)  return 2      # Hangul Jamo Extended-A
        if (v >= 44032  && v <= 55203)  return 2      # Hangul Syllables
        if (v >= 63744  && v <= 64255)  return 2      # CJK Compatibility Ideographs
        if (v >= 65072  && v <= 65135)  return 2      # CJK Compatibility Forms
        if (v >= 65280  && v <= 65376)  return 2      # fullwidth alphanumerics
        if (v >= 65504  && v <= 65510)  return 2
        if (v >= 127744 && v <= 129791) return 2      # emoji
        if (v >= 131072 && v <= 262141) return 2      # SIP
        return 1
    }'

