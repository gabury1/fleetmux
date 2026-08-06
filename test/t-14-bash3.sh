#!/usr/bin/env bash
# The bash 3.2 contract — if even one piece of syntax that dies on macOS's default /bin/bash
# slips in, it blows up right here.
#
# Why this file exists (2026-08-05, team deploy gate B6):
#   src/50-hook.sh had `${payload,,}`. That's bash-4.0-only syntax, and macOS's default shell
#   is 3.2. **It parses fine and dies at expansion time**, so the symptom is quiet — the
#   install succeeds, the list shows up, and only the pause badge (⏸, waiting for approval)
#   never appears, ever. README and SKILL both pin that exact signal down as "the one that
#   matters," and it vanishes with no error at all. On this machine (Linux, bash 5) every
#   behavioural test passes, so **behavioural tests alone can never catch it.** So instead we
#   scan the syntax statically.
#
# What gets scanned is everything that "runs on a teammate's machine": the ingredients of
# bin/fmux (src/*.sh), the installer, the PATH shim. Whole-line comments (^#) are excluded —
# 05-config.sh is right to **write down** "${var^^} does not exist," and if that sentence can't
# be written, the next person makes the same mistake without knowing why.
set -u
. "$(dirname "$0")/lib.sh"
tt_test_sandbox
cd "$(dirname "$0")/.." || exit 1

# Forbidden syntax -> human-readable name. All three exist for the same reason: "dies on 3.2."
#   ${v,,} ${v^^}  case conversion      -> written as tr '[:upper:]' '[:lower:]' (05-config.sh convention)
#   declare -A     associative array    -> "\n<key>\t<value>" line table + case-glob (80-view.sh convention)
#   mapfile/readarray                   -> a while IFS= read -r loop
PAT_LOWER='\$\{[A-Za-z_][A-Za-z0-9_]*,,'
PAT_UPPER='\$\{[A-Za-z_][A-Za-z0-9_]*\^\^'
PAT_ASSOC='(declare|typeset|local)[[:space:]]+-[A-Za-z]*A'
PAT_MAPF='(^|[^-A-Za-z_])(mapfile|readarray)[[:space:]]'

# Scan only the body, with whole-line comments stripped out.
code_of() { grep -v '^[[:space:]]*#' "$1"; }

scan() {   # $1=file  $2=regex  -> matching lines (with file:line prefix)
    code_of "$1" | grep -nE "$2" | sed "s|^|$1: |" || true
}

FILES=$(ls src/*.sh install.sh libexec/claude libexec/codex 2>/dev/null)

for f in $FILES; do
    assert_eq "$(scan "$f" "$PAT_LOWER")" "" "$f has no bash4-only \${v,,}"
    assert_eq "$(scan "$f" "$PAT_UPPER")" "" "$f has no bash4-only \${v^^}"
    assert_eq "$(scan "$f" "$PAT_ASSOC")" "" "$f has no associative-array declaration"
    assert_eq "$(scan "$f" "$PAT_MAPF")"  "" "$f has no mapfile/readarray"
done

# Check the build output too — if src is fixed but make wasn't rerun, what a teammate gets is
# still the old syntax.
for p in "$PAT_LOWER" "$PAT_UPPER" "$PAT_ASSOC" "$PAT_MAPF"; do
    assert_eq "$(scan bin/fmux "$p")" "" "bin/fmux has no bash4-only syntax"
done

# ── self-test: is the net actually catching anything ───────────────────────────────────────
# If one typo in a regex turns it into a net that catches nothing, this file stays green
# forever. So we deliberately manufacture "something that should get caught" and catch it once.
BAIT="$TTROOT/bait.sh"
cat > "$BAIT" <<'EOF'
# this line is a comment and must NOT be caught: ${v,,} ${v^^} declare -A mapfile
x=${payload,,}
y=${name^^}
declare -A tbl
mapfile -t lines < f
EOF
assert_contains "$(scan "$BAIT" "$PAT_LOWER")" 'x=${payload,,}' "the net actually catches \${v,,}"
assert_contains "$(scan "$BAIT" "$PAT_UPPER")" 'y=${name^^}'    "the net actually catches \${v^^}"
assert_contains "$(scan "$BAIT" "$PAT_ASSOC")" 'declare -A tbl' "the net actually catches an associative array"
assert_contains "$(scan "$BAIT" "$PAT_MAPF")"  'mapfile -t'     "the net actually catches mapfile"
# And it does not catch the comment line — otherwise nobody could write down why it's forbidden.
assert_eq "$(scan "$BAIT" "$PAT_LOWER" | grep -c 'this line is a comment' || true)" "0" "a whole-line comment is not caught by the net"

# ── fzf --bind bodies must not contain shell syntax ─────────────────────────
# fzf runs an execute(...) body through **$SHELL**, not through sh — so a bind body is not our
# shell, it is whatever the user happens to log in with.
#
# Measured 2026-08-06: the ? binding ended with an inline `read -rsn1`, which is bash syntax.
# On a Mac whose login shell is zsh, that read failed instantly and the help screen flashed up
# and vanished. It had worked for months for the single reason that the author's $SHELL is bash
# — the bug was invisible on the machine it was written on.
#
# The rule that came out of it: a bind body may invoke a command, and nothing else. Anything
# that needs a shell goes inside bin/fmux, which has a bash shebang and therefore a shell we
# chose. This measures the rule on the build artifact.
# Only the text *inside* execute(...)/execute-silent(...)/reload(...) is the bind body. The rest
# of the line is our own script and may use whatever bash syntax it likes — matching the whole
# line would flag the `) || exit 0` that closes the command substitution.
BINDS=$(grep -a -o -E '(execute|execute-silent|reload)\([^)]*\)' "$TTBIN" || true)
assert_rc 0 test -n "$BINDS"
assert_rc 0 test "$(printf '%s\n' "$BINDS" | grep -c .)" -ge 6

assert_eq "$(printf '%s\n' "$BINDS" | grep -c 'read -' || true)" "0" \
    "★no --bind body uses the read builtin (it runs under \$SHELL, which may not be bash)"
assert_eq "$(printf '%s\n' "$BINDS" | grep -c ';' || true)" "0" \
    "★no --bind body chains commands with ';' — chaining is shell syntax, so it belongs in bin/fmux"
for bad in '&&' '||' '$(' '`'; do
    assert_eq "$(printf '%s\n' "$BINDS" | grep -cF "$bad" || true)" "0" \
        "no --bind body uses shell construct '$bad'"
done

# And the help screen must actually be able to wait, or ? is useless: the pause lives in the
# entry point now, so the binding has to ask for it.
assert_contains "$BINDS" '--help --pause' "the ? binding delegates the wait to fmux itself"
assert_contains "$(grep -a -A3 'if \[ "\${2:-}" = "--pause" \]' "$TTBIN" || true)" 'read -' \
    "and fmux is where the waiting actually happens"

# ── a sanitizer that does not sanitize ──────────────────────────────────────
# Measured 2026-08-06 on a Mac, from the hook log:
#   fmux: line 2851: [: : integer expected
#
# The guard meant to make a value safe for arithmetic was written as
#     case "${v:-0}" in ''|*[!0-9]*) v=0 ;; esac
# which tests the **substituted** value: when v is empty, `${v:-0}` is already "0", so no branch
# matches, nothing is assigned, and v stays empty — straight into `[ "$v" -gt 0 ]`. The guard read
# as if it worked and never did. There were eleven of them.
#
# The value has to be tested as it is: case "$v" in ''|*[!0-9]*) v=0 ;; esac
assert_eq "$(grep -c ':-0}" in .*\[!0-9\]' "$TTBIN" || true)" "0" \
    "★no numeric guard tests \${x:-0} — that substitutes the default before testing, so an empty value slips through"

# And a missing file must not print. Redirections are applied left to right, so a trailing
# 2>/dev/null cannot suppress an error the shell reports while opening the input — measured:
#   fmux: line 2880: ~/.cache/tt/hook-0: No such file or directory
# for a session that simply never had a hook, which is an ordinary state, not an error.
assert_eq "$(grep -cE 'read [^|;]*< "\$STATE/[^"]*" 2>/dev/null' "$TTBIN" || true)" "0" \
    "★no read puts 2>/dev/null after the input redirect (too late to catch a failed open)"

tt_test_done