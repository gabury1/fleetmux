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

tt_test_done
