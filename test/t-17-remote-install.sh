#!/usr/bin/env bash
# install.sh remote mode — runs an install that came in via `curl | bash` all the way through
# **with no network**.
#
# ⛔ Never uses the real network. Puts fake curl/wget at the front of PATH, and unfolds each URL
#    into a local file path under $SRV, then hands over that file. Missing means 404 (rc 22).
#    Every requested URL is logged, so it can be measured what was actually fetched (did it hit
#    the tag API · did it fall through to main).
# ⛔ Never calls the real tmux either. Uses the same shape of fake tmux as t-12, and if it is
#    called with any argument other than -V, a LEAK file is left — at the end of the file it
#    asserts that file is empty.
#
# The release asset is **actually built** with `make dist` (from a repo copy). So this file
# measures the entire release pipeline at once: make dist → the two assets → the installer fetches
# and verifies them → install.
#
# TT_INSTALL_SH can point at a different install.sh — used to confirm the assertions have teeth by
# running against a reverted copy (e.g. running against a copy with the SHA check stripped out
# should flip ④ below to FAIL).
set -u
. "$(dirname "$0")/lib.sh"

ORIGPATH="$PATH"
REPO=$(cd "$(dirname "$0")/.." && pwd -P) || exit 1
tt_test_sandbox

INST="${TT_INSTALL_SH:-$REPO/install.sh}"
SLUG='fleetmux-test/fleetmux'
TAG='v9.9.9'

export TMPDIR="$TTROOT/tmp"        # keeps the installer's temp directory inside the sandbox too
mkdir -p "$TMPDIR"

CALLS="$TTROOT/tmux-calls.log"
LEAK="$TTROOT/tmux-LEAK.log"
NETLOG="$TTROOT/net.log"
SRV="$TTROOT/srv"

has() { case "$1" in *"$2"*) printf 'yes' ;; *) printf 'no' ;; esac; }
ex()  { if [ -e "$1" ]; then printf 'yes'; else printf 'no'; fi; }
cnt() { grep -c "$2" "$1" 2>/dev/null || true; }

# ── PATH seal ────────────────────────────────────────────────────────────────
# The test must not depend on what is installed on this machine. Builds a directory that symlinks
# only the needed tools and makes PATH out of that alone. curl/wget are **not here** — only fakes
# are used.
SEAL="$TTROOT/seal"
mkdir -p "$SEAL"
for c in sh bash env cat cp mv rm mkdir rmdir chmod ln cmp uname make awk sed grep tr cut \
         date ls dirname basename readlink sort head tail wc id touch find mktemp diff expr \
         tar gzip gunzip sha256sum shasum od printf; do
    p=$(PATH="$ORIGPATH" command -v "$c" 2>/dev/null) || continue
    ln -sf "$p" "$SEAL/$c"
done
for c in bash awk make cmp tar; do
    [ -e "$SEAL/$c" ] || { echo "  FAIL $c is missing from the sealed PATH — this test cannot run on this machine"; exit 1; }
done
if [ ! -e "$SEAL/sha256sum" ] && [ ! -e "$SEAL/shasum" ]; then
    echo "  FAIL this machine has neither sha256sum nor shasum — verification cannot be measured"; exit 1
fi

# A PATH with no hash tool — to actually walk the "no tool to verify with" branch.
SEAL_NOSHA="$TTROOT/seal-nosha"
mkdir -p "$SEAL_NOSHA"
for f in "$SEAL"/*; do
    case "$(basename "$f")" in sha256sum|shasum) continue ;; esac
    ln -sf "$f" "$SEAL_NOSHA/$(basename "$f")"
done

# ── fake tmux/fzf ─────────────────────────────────────────────────────────────
STUB="$TTROOT/stub"
mkdir -p "$STUB"
{
    printf '#!/usr/bin/env bash\n'
    printf 'printf "%%s\\n" "tmux $*" >> "%s"\n' "$CALLS"
    printf 'if [ "${1:-}" = "-V" ]; then echo "tmux 3.5a"; exit 0; fi\n'
    printf 'printf "%%s\\n" "LEAK: tmux $*" >> "%s"\n' "$LEAK"
    printf 'exit 1\n'
} > "$STUB/tmux"
{
    printf '#!/usr/bin/env bash\n'
    printf 'if [ "${1:-}" = "--version" ]; then echo "0.65.2 (test)"; exit 0; fi\n'
    printf 'printf "%%s\\n" "LEAK: fzf $*" >> "%s"\n' "$LEAK"
    printf 'exit 1\n'
} > "$STUB/fzf"
chmod +x "$STUB/tmux" "$STUB/fzf"

# ── fake server ─────────────────────────────────────────────────────────────
# URL → file path. https://a/b/c is $SRV/a/b/c. Missing means rc≠0, like a 404.
NET="$TTROOT/net"          # PATH slice with only curl
NETW="$TTROOT/netw"        # PATH slice with only wget
NONET="$TTROOT/nonet"      # PATH slice with neither (empty directory)
mkdir -p "$NET" "$NETW" "$NONET" "$SRV"

{
    printf '#!/usr/bin/env bash\n'
    printf '# fake curl — uses no network. Unfolds the URL into a local file.\n'
    printf 'url=""; out=""; head=0\n'
    printf 'while [ $# -gt 0 ]; do\n'
    printf '  case "$1" in\n'
    printf '    -o) out="$2"; shift ;;\n'
    printf '    --max-time) shift ;;\n'
    printf '    -A) shift ;;\n'
    printf '    -w) shift ;;\n'
    printf '    -fsSLI) head=1 ;;\n'
    printf '    -I) head=1 ;;\n'
    printf '    http://*|https://*) url="$1" ;;\n'
    printf '  esac\n'
    printf '  shift\n'
    printf 'done\n'
    printf 'printf "curl %%s\\n" "$url" >> "%s"\n' "$NETLOG"
    printf 'p=${url#https://}; p=${p#http://}\n'
    printf 'f="%s/$p"\n' "$SRV"
    printf 'if [ ! -f "$f" ]; then echo "curl: (22) The requested URL returned error: 404" >&2; exit 22; fi\n'
    # -I is the redirect probe: the file holds the final URL, which is what -w %%{url_effective}
    # prints. This is how the real /releases/latest answers — a redirect, not an API document.
    printf 'if [ "${head:-0}" = 1 ]; then cat "$f"; exit 0; fi\n'
    printf 'if [ -n "$out" ]; then cp "$f" "$out"; else cat "$f"; fi\n'
} > "$NET/curl"
{
    printf '#!/usr/bin/env bash\n'
    printf '# fake wget — same rule. Receives via -O.\n'
    printf 'url=""; out=""; head=0\n'
    printf 'while [ $# -gt 0 ]; do\n'
    printf '  case "$1" in\n'
    printf '    -O) out="$2"; shift ;;\n'
    printf '    -T) shift ;;\n'
    printf '    -S) head=1 ;;\n'
    printf '    --max-redirect) shift ;;\n'
    printf '    --user-agent=*) : ;;\n'
    printf '    http://*|https://*) url="$1" ;;\n'
    printf '  esac\n'
    printf '  shift\n'
    printf 'done\n'
    printf 'printf "wget %%s\\n" "$url" >> "%s"\n' "$NETLOG"
    printf 'p=${url#https://}; p=${p#http://}\n'
    printf 'f="%s/$p"\n' "$SRV"
    # The real wget creates the -O file even on a 404. Mimics that same husk — if the installer
    # believes an empty file was "received," this is where it should get caught.
    printf 'if [ ! -f "$f" ]; then : > "$out"; echo "wget: 404" >&2; exit 8; fi\n'
    # -S is the redirect probe: real wget prints the hop on stderr as "  Location: <url>".
    printf 'if [ "${head:-0}" = 1 ]; then printf "  Location: %%s\\n" "$(cat "$f")" >&2; exit 0; fi\n'
    printf 'if [ -n "$out" ]; then cp "$f" "$out"; else cat "$f"; fi\n'
} > "$NETW/wget"
chmod +x "$NET/curl" "$NETW/wget"

# ── build the release assets for real with make dist ────────────────────────
# Runs from a repo copy — nothing is written to the real repo.
REPOC="$TTROOT/repoc"
mkdir -p "$REPOC"
cp -R "$REPO/bin" "$REPO/libexec" "$REPO/src" "$REPO/skills" "$REPOC/"
cp "$REPO/Makefile" "$REPO/install.sh" "$REPO/README.md" "$REPO/LICENSE" "$REPOC/"
cp "$INST" "$REPOC/install.sh"
DIST="$TTROOT/dist"
DISTOUT=$(PATH="$SEAL" make -C "$REPOC" dist DISTDIR="$DIST" VERSION="$TAG" 2>&1) || DISTOUT="MAKE-FAILED
$DISTOUT"

assert_eq "$(ex "$DIST/fleetmux-$TAG.tar.gz")" "yes" "make dist creates the release tarball"
assert_eq "$(ex "$DIST/SHA256SUMS")" "yes" "make dist creates SHA256SUMS alongside it"
assert_eq "$(cnt "$DIST/SHA256SUMS" "fleetmux-$TAG.tar.gz")" "1" "SHA256SUMS points at that tarball"
assert_eq "$(has "$DISTOUT" 'MAKE-FAILED')" "no" "make dist succeeded"

# Does a person not have to type the hash by hand — is the generated SHA256SUMS the same as the real hash.
if [ -e "$SEAL/sha256sum" ]; then REALSHA=$(PATH="$SEAL" sha256sum "$DIST/fleetmux-$TAG.tar.gz" | awk '{print $1}')
else REALSHA=$(PATH="$SEAL" shasum -a 256 "$DIST/fleetmux-$TAG.tar.gz" | awk '{print $1}'); fi
assert_eq "$(awk '{print $1}' "$DIST/SHA256SUMS")" "$REALSHA" "the hash in SHA256SUMS matches the actual file's hash"

# Does the archive hold everything needed for install — missing any of it, a remote install ends up half-done.
TARLIST=$(PATH="$SEAL" tar -tzf "$DIST/fleetmux-$TAG.tar.gz")
for want in "fleetmux-$TAG/bin/fmux" "fleetmux-$TAG/libexec/claude" "fleetmux-$TAG/libexec/codex" \
            "fleetmux-$TAG/skills/fleetmux/SKILL.md"; do
    assert_eq "$(has "$TARLIST" "$want")" "yes" "the archive contains $want"
done

# ── upload the fake release to the server ────────────────────────────────────
API="$SRV/api.github.com/repos/$SLUG/releases"
DLD="$SRV/github.com/$SLUG/releases/download/$TAG"
REL="$SRV/github.com/$SLUG/releases"
mkdir -p "$API" "$DLD" "$REL"
printf '{"url":"x","tag_name": "%s", "name":"%s","draft":false}\n' "$TAG" "$TAG" > "$API/latest"
# The redirect target of /releases/latest. This is the path the installer takes first, because
# the API is capped at 60 unauthenticated calls per hour per IP (measured 403 on 2026-08-06).
printf 'https://github.com/%s/releases/tag/%s\n' "$SLUG" "$TAG" > "$REL/latest"
cp "$DIST/fleetmux-$TAG.tar.gz" "$DLD/fleetmux-$TAG.tar.gz"
cp "$DIST/SHA256SUMS"           "$DLD/SHA256SUMS"

# Leaves the installer alone, outside the repo — this is the situation `curl | bash` creates
# (there is no repo sitting next to it).
ALONE="$TTROOT/alone"
mkdir -p "$ALONE"
cp "$INST" "$ALONE/install.sh"

OUT=''; RC=0
run_remote() {   # $1=PATH slice (network), the rest=install.sh args
    local net="$1"; shift
    RC=0
    OUT=$(PATH="$STUB:$net:$SEAL" FMUX_SLUG="$SLUG" bash "$ALONE/install.sh" "$@" < /dev/null 2>&1) || RC=$?
}
tmpd_of() { printf '%s\n' "$1" | sed -n 's/^  ok   temp directory: \([^ ]*\).*/\1/p' | head -1; }

# ── ① mode detection ─────────────────────────────────────────────────────────
: > "$NETLOG"
run_remote "$NET" --prefix "$TTROOT/p1" --preset safe
assert_eq "$RC" "0" "a remote install ends with rc 0"
assert_eq "$(has "$OUT" 'mode   remote')" "yes" "states in one line on screen which mode it is"
assert_eq "$(has "$OUT" 'no repo here')" "yes" "says why it is remote"
assert_eq "$(ex "$TTROOT/p1/bin/fmux")" "yes" "fmux gets installed to the prefix under the fake HOME"
assert_rc 0 test -x "$TTROOT/p1/bin/fmux"
assert_eq "$(readlink "$TTROOT/p1/bin/tt")" "fmux" "the tt symlink gets hung too"
assert_eq "$(ex "$TTROOT/p1/libexec/tt/claude")" "yes" "the hook shim gets installed too"
assert_eq "$(ex "$XDG_CONFIG_HOME/fleetmux/tmux.conf")" "yes" "the tmux snippet is created too"
# Is what got installed the exact bytes inside the archive — the comparison only means something
# if what was verified and what was installed are the same.
assert_rc 0 cmp -s "$REPOC/bin/fmux" "$TTROOT/p1/bin/fmux"

# What did it go fetch — the default is the latest release tag. It does not fall through to main.
assert_eq "$(cnt "$NETLOG" 'github.com/'"$SLUG"'/releases/latest')" "1" "by default it resolves the latest release tag"
assert_eq "$(cnt "$NETLOG" 'api.github.com')" "0" \
    "★it does not touch the GitHub API — that path is capped at 60 calls/hour per IP and 403s once spent"
assert_eq "$(cnt "$NETLOG" "releases/download/$TAG/fleetmux-$TAG.tar.gz")" "1" "it fetches that tag's release asset"
assert_eq "$(cnt "$NETLOG" "releases/download/$TAG/SHA256SUMS")" "1" "it fetches SHA256SUMS too"
assert_eq "$(cnt "$NETLOG" 'main')" "0" "main is never fetched from anywhere"
assert_eq "$(has "$OUT" "latest release tag: $TAG")" "yes" "says which tag it picked"
assert_eq "$(has "$OUT" 'SHA256 matches')" "yes" "says it verified"

# The temp directory does not survive success
T1=$(tmpd_of "$OUT")
assert_eq "$(has "$T1" 'fmux-install.')" "yes" "shows the temp directory path on screen"
assert_eq "$(ex "$T1")" "no" "★the temp directory does not survive even on success"
assert_eq "$(has "$OUT" 'deleted the temp directory')" "yes" "says it deleted it"

# ── ②  the exact shape of `curl … | bash` ────────────────────────────────────
# stdin is the script — so it cannot ask, and when it cannot ask, no consent is assumed.
# Runs at a place with no repo (typing one line from the home directory is what it actually looks
# like).
ELSEWHERE="$TTROOT/elsewhere"
mkdir -p "$ELSEWHERE"
: > "$NETLOG"
RC=0
OUT=$(cd "$ELSEWHERE" && PATH="$STUB:$NET:$SEAL" FMUX_SLUG="$SLUG" \
        bash -s -- --prefix "$TTROOT/p2" --preset safe < "$ALONE/install.sh" 2>&1) || RC=$?
assert_eq "$RC" "0" "still rc 0 when sent in through a pipe"
assert_eq "$(has "$OUT" 'mode   remote')" "yes" "detects remote even coming in through a pipe"
assert_eq "$(has "$OUT" "latest release tag: $TAG")" "yes" "a piped install also picks the latest tag"
assert_eq "$(ex "$TTROOT/p2/bin/fmux")" "yes" "fmux also gets installed via a piped install"
assert_eq "$(ex "$HOME/.tmux.conf")" "no" "it cannot ask, so it does not touch someone else's tmux config"

# The reverse — piping it from **inside** a clone uses that clone (local). Detection is by file, not by $0.
: > "$NETLOG"
RC=0
OUT=$(cd "$REPOC" && PATH="$STUB:$NET:$SEAL" FMUX_SLUG="$SLUG" \
        bash -s -- --prefix "$TTROOT/p2b" --preset safe < "$ALONE/install.sh" 2>&1) || RC=$?
assert_eq "$(has "$OUT" 'mode   local')" "yes" "piping it from inside the repo uses that repo"
assert_eq "$(cnt "$NETLOG" '.')" "0" "in that case it uses no network"

# ── ③ giving --ref means it does not check the tag API ──────────────────────
: > "$NETLOG"
run_remote "$NET" --ref "$TAG" --prefix "$TTROOT/p3" --preset safe
assert_eq "$RC" "0" "a --ref install is rc 0"
assert_eq "$(cnt "$NETLOG" 'api.github.com')" "0" "with --ref given, it does not ask for the latest tag"
assert_eq "$(has "$OUT" "fetching --ref: $TAG")" "yes" "says what it is fetching"
assert_eq "$(ex "$TTROOT/p3/bin/fmux")" "yes" "installs via --ref too"

# ── ④ a SHA mismatch halts ───────────────────────────────────────────────────
# Builds a tampered copy. It **must unpack cleanly** — a corrupted file would make tar die first,
# so the failure would read as "it never unpacked anyway" rather than "the SHA check caught it,"
# and that net would have no teeth. So a file is genuinely slipped in like a real attack, and
# re-packed.
BADTAG='v8.8.8'
BADD="$SRV/github.com/$SLUG/releases/download/$BADTAG"
mkdir -p "$BADD" "$TTROOT/tam"
PATH="$SEAL" tar -xzf "$DIST/fleetmux-$TAG.tar.gz" -C "$TTROOT/tam"
mv "$TTROOT/tam/fleetmux-$TAG" "$TTROOT/tam/fleetmux-$BADTAG"
printf '#!/bin/sh\n# a slipped-in file\n' > "$TTROOT/tam/fleetmux-$BADTAG/EVIL.sh"
PATH="$SEAL" tar -czf "$TTROOT/tampered.tar.gz" -C "$TTROOT/tam" "fleetmux-$BADTAG"
assert_rc 0 env PATH="$SEAL" tar -tzf "$TTROOT/tampered.tar.gz"
cp "$TTROOT/tampered.tar.gz" "$BADD/fleetmux-$BADTAG.tar.gz"
{
    printf '%s  fleetmux-%s.tar.gz\n' "$REALSHA" "$BADTAG"      # ← the original's hash (= does not match)
} > "$BADD/SHA256SUMS"

: > "$NETLOG"
run_remote "$NET" --ref "$BADTAG" --prefix "$TTROOT/p4" --preset safe
assert_eq "$RC" "1" "★a SHA mismatch halts it"
assert_eq "$(has "$OUT" 'SHA256 mismatch')" "yes" "says why it halted"
assert_eq "$(has "$OUT" "$REALSHA")" "yes" "shows the hash it expected"
assert_eq "$(ex "$TTROOT/p4")" "no" "★not one byte of the tampered copy is installed"
T4=$(tmpd_of "$OUT")
assert_eq "$(ex "$T4")" "no" "★the temp directory does not survive on failure either"

# If the hash is made to match at the same spot it must pass — otherwise the assertion above would
# always fail regardless of content.
if [ -e "$SEAL/sha256sum" ]; then BADSHA=$(PATH="$SEAL" sha256sum "$TTROOT/tampered.tar.gz" | awk '{print $1}')
else BADSHA=$(PATH="$SEAL" shasum -a 256 "$TTROOT/tampered.tar.gz" | awk '{print $1}'); fi
printf '%s  fleetmux-%s.tar.gz\n' "$BADSHA" "$BADTAG" > "$BADD/SHA256SUMS"
run_remote "$NET" --ref "$BADTAG" --prefix "$TTROOT/p4b" --preset safe
assert_eq "$RC" "0" "when the hash matches, the same archive passes (verification checks the hash, not the content)"
assert_eq "$(ex "$TTROOT/p4b/bin/fmux")" "yes" "in that case it installs"

# SHA256SUMS has no entry at all for our file — must not claim it "verified"
printf '%s  something-else.tar.gz\n' "$BADSHA" > "$BADD/SHA256SUMS"
run_remote "$NET" --ref "$BADTAG" --prefix "$TTROOT/p4c" --preset safe
assert_eq "$RC" "1" "no entry in SHA256SUMS for that file halts it"
assert_eq "$(has "$OUT" 'no entry for')" "yes" "says what is missing"
assert_eq "$(ex "$TTROOT/p4c")" "no" "nothing gets installed then either"

# ── ⑤ a release with no SHA256SUMS ───────────────────────────────────────────
NOSUM='v7.7.7'
NOSUMD="$SRV/github.com/$SLUG/releases/download/$NOSUM"
mkdir -p "$NOSUMD"
cp "$DIST/fleetmux-$TAG.tar.gz" "$NOSUMD/fleetmux-$NOSUM.tar.gz"      # SHA256SUMS is not uploaded

run_remote "$NET" --ref "$NOSUM" --prefix "$TTROOT/p5" --preset safe
assert_eq "$RC" "1" "★with no SHA256SUMS (and nowhere it can ask), it halts"
assert_eq "$(has "$OUT" 'has no SHA256SUMS')" "yes" "says it is missing"
assert_eq "$(has "$OUT" 'the only defence')" "yes" "says why it cannot just skip past this"
assert_eq "$(ex "$TTROOT/p5")" "no" "it does not install unverified"

run_remote "$NET" --yes --ref "$NOSUM" --prefix "$TTROOT/p5b" --preset safe
assert_eq "$RC" "1" "★--yes does not authorize an unverified install"
assert_eq "$(has "$OUT" '--yes does not authorize an unverified install')" "yes" "names --yes and refuses it"
assert_eq "$(ex "$TTROOT/p5b")" "no" "does not install even with --yes"

# ── ⑥ a machine with no verification tool ────────────────────────────────────
RC=0
OUT=$(PATH="$STUB:$NET:$SEAL_NOSHA" FMUX_SLUG="$SLUG" bash "$ALONE/install.sh" \
        --ref "$TAG" --prefix "$TTROOT/p6" --preset safe < /dev/null 2>&1) || RC=$?
assert_eq "$RC" "1" "★with neither sha256sum nor shasum (it cannot ask), it halts"
assert_eq "$(has "$OUT" 'neither sha256sum nor shasum is present')" "yes" "names which tool is missing"
assert_eq "$(ex "$TTROOT/p6")" "no" "with no way to verify, it does not install"
RC=0
OUT=$(PATH="$STUB:$NET:$SEAL_NOSHA" FMUX_SLUG="$SLUG" bash "$ALONE/install.sh" \
        --yes --ref "$TAG" --prefix "$TTROOT/p6b" --preset safe < /dev/null 2>&1) || RC=$?
assert_eq "$RC" "1" "--yes also halts when the tool is missing"
assert_eq "$(ex "$TTROOT/p6b")" "no" "does not install even with --yes"

# ── ⑦ if it cannot determine the tag, it halts — it does not fall through to main ──
# Both sources have to be taken down: the redirect (primary) and the API (fallback). Taking
# down only one proves nothing, because the other still answers.
mv "$REL/latest" "$REL/latest.off"
: > "$NETLOG"
run_remote "$NET" --prefix "$TTROOT/p7r" --preset safe
assert_eq "$RC" "0" "★with the redirect down it falls back to the API and still installs"
assert_eq "$(cnt "$NETLOG" 'api.github.com')" "1" "the fallback is what answered"
assert_eq "$(ex "$TTROOT/p7r/bin/fmux")" "yes" "the fallback path installs a real binary"

mv "$API/latest" "$API/latest.off"
: > "$NETLOG"
run_remote "$NET" --prefix "$TTROOT/p7" --preset safe
assert_eq "$RC" "1" "★it halts when it cannot get the latest tag"
assert_eq "$(has "$OUT" 'not falling back to main')" "yes" "says it is not going to main"
assert_eq "$(has "$OUT" '--ref')" "yes" "says what to do instead"
assert_eq "$(cnt "$NETLOG" 'main')" "0" "★it genuinely never went to fetch main"
assert_eq "$(cnt "$NETLOG" 'releases/download')" "0" "no archive was fetched at all"
assert_eq "$(ex "$TTROOT/p7")" "no" "nothing gets installed"

# A response missing the tag name must land on the same verdict (200, but a useless answer)
printf '{"message":"Not Found"}\n' > "$API/latest"
: > "$NETLOG"
run_remote "$NET" --prefix "$TTROOT/p7b" --preset safe
assert_eq "$RC" "1" "it also halts on a response with no tag_name"
assert_eq "$(cnt "$NETLOG" 'releases/download')" "0" "it fetches nothing there either"
printf '{"url":"x","tag_name": "%s", "name":"%s"}\n' "$TAG" "$TAG" > "$API/latest"
mv "$REL/latest.off" "$REL/latest"

# ── ⑧ the fetch tool — falls back to wget, halts if neither exists ──────────
: > "$NETLOG"
run_remote "$NETW" --prefix "$TTROOT/p8" --preset safe
assert_eq "$RC" "0" "it fetches with wget when curl is missing"
assert_eq "$(has "$OUT" 'downloading with wget')" "yes" "says what it is fetching with"
assert_eq "$(cnt "$NETLOG" '^wget ')" "3" "wget actually went out three times (tag, asset, SHA)"
assert_eq "$(cnt "$NETLOG" '^curl ')" "0" "curl was not used"
assert_eq "$(ex "$TTROOT/p8/bin/fmux")" "yes" "it installs via the wget path too"

: > "$NETLOG"
run_remote "$NONET" --prefix "$TTROOT/p9" --preset safe
assert_eq "$RC" "1" "it halts with neither curl nor wget"
assert_eq "$(has "$OUT" 'neither curl nor wget is present')" "yes" "says both are missing"
assert_eq "$(has "$OUT" 'brew install curl')" "yes" "says what to install"
assert_eq "$(ex "$TTROOT/p9")" "no" "nothing gets installed"

# It does not trust the empty husk wget leaves on a 404 as "received" — confirmed with a tag that does not exist.
: > "$NETLOG"
run_remote "$NETW" --ref v0.0.0-none --prefix "$TTROOT/p9b" --preset safe
assert_eq "$RC" "1" "a nonexistent tag halts it"
assert_eq "$(has "$OUT" 'could not download the archive')" "yes" "says it could not fetch it"
assert_eq "$(ex "$TTROOT/p9b")" "no" "does not mistake an empty file for an archive and install it"

# ── ⑨ with no FMUX_SLUG it uses the real published address ───────────────────
# The repo went public on 2026-08-06, so the default is a real slug, not a placeholder.
# What is measured here is that the default is actually wired: with FMUX_SLUG unset the
# request must go to that address and to nothing else. The stub network only serves the
# test slug, so the run still fails — the point is *where* it knocked, not that it succeeded.
: > "$NETLOG"
RC=0
OUT=$(PATH="$STUB:$NET:$SEAL" bash "$ALONE/install.sh" --prefix "$TTROOT/p10" < /dev/null 2>&1) || RC=$?
assert_eq "$RC" "1" "with the stub network serving only the test slug, the default-slug run fails rather than installing something bogus"
assert_eq "$(cnt "$NETLOG" 'github.com/gabury1/fleetmux/releases/latest')" "1" \
    "★the default slug is wired — with FMUX_SLUG unset the redirect probe goes to the published repo"
assert_eq "$(cnt "$NETLOG" 'api.github.com/repos/gabury1/fleetmux')" "1" \
    "and the API fallback goes to that same repo, not somewhere else"
assert_eq "$(cnt "$NETLOG" 'OWNER')" "0" "no placeholder address survives anywhere in the installer"
assert_eq "$(ex "$TTROOT/p10")" "no" "nothing is installed when the fetch fails"

# ── ⑩ --dry-run — it fetches but changes not one user file ───────────────────
: > "$NETLOG"
run_remote "$NET" --dry-run --prefix "$TTROOT/p11" --preset safe
assert_eq "$RC" "0" "a remote --dry-run is rc 0"
assert_eq "$(has "$OUT" 'dry  ')" "yes" "shows what would be done as dry lines"
assert_eq "$(ex "$TTROOT/p11")" "no" "★dry-run installs nothing"
T11=$(tmpd_of "$OUT")
assert_eq "$(ex "$T11")" "no" "the temp directory dry-run fetched into does not survive either"
assert_eq "$(has "$OUT" 'Not one byte leaves the temp directory')" "yes" "explains why it fetched"

# ── ⑪ local mode regression — inside a repo it behaves exactly as before ────
: > "$NETLOG"
RC=0
OUT=$(PATH="$STUB:$NET:$SEAL" bash "$REPOC/install.sh" --prefix "$TTROOT/p12" --preset safe \
        < /dev/null 2>&1) || RC=$?
assert_eq "$RC" "0" "a local mode install is rc 0"
assert_eq "$(has "$OUT" 'mode   local')" "yes" "states local in one line"
assert_eq "$(has "$OUT" 'mode   remote')" "no" "does not mistake it for remote"
assert_eq "$(cnt "$NETLOG" '.')" "0" "★local mode never touches the network at all"
assert_eq "$(ex "$TTROOT/p12/bin/fmux")" "yes" "local mode installs it as before"
assert_eq "$(readlink "$TTROOT/p12/bin/tt")" "fmux" "the tt symlink is the same too"
assert_eq "$(has "$OUT" '0/8')" "no" "step 0 does not appear in local mode"

# In local mode --ref is ignored, and it says it ignored it (not silently swallowed)
RC=0
OUT=$(PATH="$STUB:$NET:$SEAL" bash "$REPOC/install.sh" --ref v1.2.3 --prefix "$TTROOT/p13" --preset safe \
        < /dev/null 2>&1) || RC=$?
assert_eq "$RC" "0" "still rc 0 giving --ref in local mode"
assert_eq "$(has "$OUT" 'not used in local mode')" "yes" "says it ignored --ref"
assert_eq "$(cnt "$NETLOG" '.')" "0" "it uses no network there either"

# ── ⑫ docs and usage ──────────────────────────────────────────────────────────
USAGE=$(PATH="$SEAL" bash "$INST" --help 2>&1) || USAGE=''
assert_eq "$(has "$USAGE" '--ref')" "yes" "install.sh --help documents --ref"
assert_eq "$(has "$USAGE" 'curl -fsSL')" "yes" "--help also shows the remote one-liner"
RM=$(cat "$REPO/README.md")
assert_eq "$(has "$RM" 'curl -fsSL')" "yes" "README writes the one-line install"
assert_eq "$(has "$RM" '| bash')" "yes" "README writes the pipe form"
assert_eq "$(has "$RM" '-o install.sh')" "yes" "README also writes the fetch-then-read-then-run two-step version"
assert_eq "$(has "$RM" 'less install.sh')" "yes" "that two-step version includes the eyeball-it-first step"
assert_eq "$(has "$RM" '--ref')" "yes" "README writes --ref"
assert_eq "$(has "$RM" 'SHA256SUMS')" "yes" "README writes SHA256SUMS verification"
assert_eq "$(has "$RM" 'make dist')" "yes" "README writes how to make a release"
MK=$(cat "$REPO/Makefile")
assert_eq "$(has "$MK" 'dist:')" "yes" "the Makefile has a dist target"
assert_eq "$(has "$MK" 'shasum -a 256')" "yes" "dist also looks for macOS's hash tool"
INSTSH=$(cat "$INST")
assert_eq "$(has "$INSTSH" 'shasum -a 256')" "yes" "the installer also looks for macOS's hash tool"
assert_eq "$(has "$INSTSH" 'sha256sum')" "yes" "the installer looks for Linux's hash tool too"

# ── ⑬ did the real tmux leak ─────────────────────────────────────────────────
assert_eq "$(ex "$LEAK")" "no" "the fake tmux/fzf was never called with anything but -V"
assert_rc 0 test -s "$CALLS"

tt_test_done
