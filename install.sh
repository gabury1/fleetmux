#!/usr/bin/env bash
# fleetmux installer — teammates run this once to put fmux on their machine.
#
#   ./install.sh              install with prompts
#   ./install.sh --dry-run    change nothing, just print what would be done
#   ./install.sh --yes        yes to every prompt (accepts the suggested defaults as-is)
#                             the summon key is the one exception — it goes to safe (steals no
#                             key). Stealing a no-prefix key globally only happens when you
#                             spell it out with --preset.
#                             (The suggestion when we can ask is shift = S-Up. The reasoning
#                              for that key is written at the top of the "5) summon key preset"
#                              section below.)
#   curl -fsSL <URL> | bash   install without a repo (remote mode) — fetches the release archive
#
# There are two modes. Which one is decided by **whether the files exist**, and a line at the
# top of the screen says which:
#   local  — a repo sits next to this script (Makefile, src/, bin/fmux are visible). Install that.
#   remote — none of that is there (you came in via `curl | bash`). Fetch the release archive,
#            unpack it into a temp directory, and treat it as the repo through the same eight
#            steps below. Deleted when it finishes or fails either way.
#
# Four disciplines — for whoever edits this file next:
#   1) Idempotent. Safe to run twice; anything already present is announced before being
#      overwritten.
#   2) --dry-run creates zero files. Don't miss this fork when adding a new step.
#      (--dry-run in remote mode does fetch the archive — there's no way to say what would be
#       installed without fetching it. But **not one byte leaves the temp directory**, and it's
#       deleted when done.)
#   3) Other people's files are never changed without consent. ~/.tmux.conf gets one line, and
#      only after asking; crontab is never touched at all — we only show what would go there
#      (a project principle).
#   4) On failure, say how far we got and stop. No silent half-installs.
#
# Portability: bash 3.2 compatible (no associative arrays, no ${v^^}, no fractional read -t),
#   no GNU-only flags (no stat -c, readlink -f, sed -i, sort -V). Must run on both macOS and
#   Linux.
# No color, no emoji — we don't know what a teammate's terminal supports.

set -u

REPO=$(cd "$(dirname "$0")" 2>/dev/null && pwd -P) || { echo "could not find the directory install.sh is in" >&2; exit 1; }

PREFIX="${PREFIX:-$HOME/.local}"
DRY=0
ASSUME_YES=0
PRESET=""
REF=""

usage() {
    cat << 'EOF'
usage: ./install.sh [options]
       curl -fsSL <URL> | bash              (remote mode — no repo needed)
       curl -fsSL <URL> | bash -s -- --ref v1.2.3

  -n, --dry-run       change nothing, just print what would be done
  -y, --yes           yes to every prompt (accepts the suggested defaults as-is)
                      except the summon key, which goes to safe — no no-prefix key is stolen
      --prefix DIR    install location (default ~/.local — bin/ and libexec/fmux/ go under it)
      --preset NAME   summon key preset: shift | safe | mac | linux | wsl
                      when we can ask, we suggest shift (S-Up) — the only no-prefix single
                      keystroke that reaches all three of macOS, Linux, and Windows Terminal.
                      In exchange it takes that key away from every app in that pane. --yes
                      never steals it — stealing a no-prefix key only happens when you spell
                      it out here.
      --ref TAG       tag (or branch) to fetch in remote mode. Default is the **latest
                      release tag**. Not used in local mode.
  -h, --help          this help

What it does: (in remote mode, fetch the release archive first →) check dependencies →
install the binary → place the hook shim → tmux snippet → summon key preset → agent skill →
cron guidance → summary.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -n|--dry-run) DRY=1 ;;
        -y|--yes)     ASSUME_YES=1 ;;
        --prefix)     [ $# -ge 2 ] || { echo "--prefix needs a directory" >&2; exit 2; }; PREFIX="$2"; shift ;;
        --prefix=*)   PREFIX="${1#--prefix=}" ;;
        --preset)     [ $# -ge 2 ] || { echo "--preset needs a name" >&2; exit 2; }; PRESET="$2"; shift ;;
        --preset=*)   PRESET="${1#--preset=}" ;;
        --ref)        [ $# -ge 2 ] || { echo "--ref needs a tag" >&2; exit 2; }; REF="$2"; shift ;;
        --ref=*)      REF="${1#--ref=}" ;;
        -h|--help)    usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; echo >&2; usage >&2; exit 2 ;;
    esac
    shift
done

# A relative PREFIX is resolved to an absolute path. `make -C "$REPO" install PREFIX=./x`
# resolves relative to the repo, so it would install somewhere other than where the person
# typed it — this removes that surprise.
case "$PREFIX" in
    /*) ;;
    *)  PREFIX="$PWD/$PREFIX" ;;
esac

BINDIR="$PREFIX/bin"
# PATH shim location. Must match the path used in README and 70-fleet.sh's PATH correction.
#   The name is fmux; libexec/tt is what installs made before 2026-08-06 used.
#   **An existing shim directory is kept.** That path is written into the user's shell rc as a
#   PATH entry, so moving it would leave the rc pointing at nothing — and the failure is silent:
#   the shim stops being found, hooks stop attaching, and the tool still looks installed. Only a
#   fresh install gets the new name.
if [ -d "$PREFIX/libexec/tt" ]; then LIBEXEC="$PREFIX/libexec/tt"
else LIBEXEC="$PREFIX/libexec/fmux"
fi

# ── output ──────────────────────────────────────────────────────────────────
# Tags are all 4-column ASCII. Non-ASCII tags render at different widths in different
# terminals, which throws the table's alignment off.
step() { printf '\n[%s] %s\n' "$1" "$2"; }
ok()   { printf '  ok   %s\n' "$*"; }
note() { printf '  note %s\n' "$*"; }
skip() { printf '  skip %s\n' "$*"; }
plan() { printf '  dry  %s\n' "$*"; }        # "would have done this" under --dry-run
warn() { printf '  warn %s\n' "$*" >&2; }

# List of what was done — told even on failure (discipline 4).
DID=''
did() { DID="$DID  - $1"$'\n'; }

die() {
    printf '\nstopping the install: %s\n' "$1" >&2
    if [ -n "$DID" ]; then
        printf '\nGot this far — the rest was not done:\n%s' "$DID" >&2
        printf 'To undo it, remove the items in the list above.\n' >&2
    else
        printf '\nNothing was changed.\n' >&2
    fi
    exit 1
}

is_dry() { [ "$DRY" = 1 ]; }

# ── asking ──────────────────────────────────────────────────────────────────
# Anything that needs consent doesn't happen without it — silence is not consent.
#
# But "stdin is not a terminal" is NOT the same as "no human is here, so answer no",
# and treating them as the same broke the documented install path. Measured 2026-08-06:
# with `curl … | bash`, stdin is the pipe carrying the script, so every question
# auto-answered "no" — the tmux snippet was never linked, no summon key was bound, and the
# agent skill was never installed. The user was left with a binary and no way to open the
# popup, and nothing about the output said that had happened. **The headline install path
# silently produced a half install.**
#
# So when stdin is not a terminal, ask the controlling terminal directly through /dev/tty
# and read answers from fd 3. If there is no controlling terminal either (cron, CI, a test
# harness), there really is no one to ask, and only then do questions answer themselves
# with "no".
#
# FMUX_TTY=off forces that no-one-is-here path. Tests need it: a test run from a terminal
# can still open /dev/tty, so without this the suite's behaviour would depend on whether a
# human happened to be watching.
ASK_TTY=0
TTY_FD=''
if [ -t 0 ]; then
    ASK_TTY=1
elif [ "${FMUX_TTY:-}" != off ] && exec 3< /dev/tty 2>/dev/null; then
    ASK_TTY=1
    TTY_FD=3
fi

# read a line from wherever the human actually is
ask_read() {   # $1=variable name
    if [ -n "$TTY_FD" ]; then read -r "$1" <&3; else read -r "$1"; fi
}

ask_yn() {   # $1=question  → rc 0 means yes
    local q="$1" ans=''
    if [ "$ASSUME_YES" = 1 ]; then
        printf '  %s [y/n] y  (--yes)\n' "$q"
        return 0
    fi
    if [ "$ASK_TTY" = 0 ]; then
        printf '  %s [y/n] n  (not a terminal, so we did not ask — nothing without consent)\n' "$q"
        return 1
    fi
    printf '  %s [y/N] ' "$q"
    ask_read ans || ans=''
    case "$ans" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

ask_word() {   # $1=question  $2=default  → answer on stdout
    local q="$1" def="$2" ans=''
    if [ "$ASSUME_YES" = 1 ] || [ "$ASK_TTY" = 0 ]; then printf '%s' "$def"; return 0; fi
    printf '  %s [%s] ' "$q" "$def" >&2
    ask_read ans || ans=''
    [ -n "$ans" ] || ans="$def"
    printf '%s' "$ans"
}

# ── version comparison ─────────────────────────────────────────────────────
# Doesn't rely on GNU `sort -V` — macOS's BSD sort doesn't have it.
# Strips off just the leading digits-and-dots and compares component by component:
# "3.5a"→3.5, "0.65.2 (brew)"→0.65.2, "5.2.37(1)-release"→5.2.37. If it doesn't start with a
# digit ("next-3.6", "master"), empty value = unreadable.
ver_num() {
    local v="${1:-}"
    v=${v%%[!0-9.]*}
    while [ -n "$v" ] && [ "${v%.}" != "$v" ]; do v=${v%.}; done
    printf '%s' "$v"
}

# rc 0 = $1 >= $2, rc 1 = lower, rc 2 = unreadable (doesn't block when it can't tell)
ver_ge() {
    local a b ai bi
    a=$(ver_num "${1:-}"); b=$(ver_num "${2:-}")
    [ -n "$a" ] || return 2
    [ -n "$b" ] || return 2
    while [ -n "$a" ] || [ -n "$b" ]; do
        ai=${a%%.*}; bi=${b%%.*}
        case "$a" in *.*) a=${a#*.} ;; *) a='' ;; esac
        case "$b" in *.*) b=${b#*.} ;; *) b='' ;; esac
        # A leading 0 is octal in bash arithmetic → normalize with 10# (same reason as
        # fmux_conf_num in 05-config.sh)
        case "$ai" in ''|*[!0-9]*) ai=0 ;; *) ai=$((10#$ai)) ;; esac
        case "$bi" in ''|*[!0-9]*) bi=0 ;; *) bi=$((10#$bi)) ;; esac
        [ "$ai" -gt "$bi" ] && return 0
        [ "$ai" -lt "$bi" ] && return 1
    done
    return 0
}

# ── PATH scan ───────────────────────────────────────────────────────────────
# `for d in $PATH` needs IFS changed, which easily leaks out of the function. Sliced with
# parameter expansion instead. An empty component means the current directory (.) under POSIX.
path_index() {   # $1=directory → its position in PATH (1-based). 0 if absent.
    local want="${1:-}" rest="$PATH:" d i=0
    want=${want%/}
    while [ -n "$rest" ]; do
        d=${rest%%:*}; rest=${rest#*:}
        i=$((i + 1))
        [ -n "$d" ] || d=.
        [ "${d%/}" = "$want" ] && { printf '%s' "$i"; return 0; }
    done
    printf '0'
}

first_real_index() {   # $1=command name → its first position in PATH excluding LIBEXEC. 0 if absent.
    local want="${1:-}" rest="$PATH:" d i=0
    while [ -n "$rest" ]; do
        d=${rest%%:*}; rest=${rest#*:}
        i=$((i + 1))
        [ -n "$d" ] || d=.
        [ "${d%/}" = "${LIBEXEC%/}" ] && continue
        [ -x "$d/$want" ] && { printf '%s' "$i"; return 0; }
    done
    printf '0'
}

rc_hint() {   # Guesses the shell startup file name — doesn't edit it, just says which to open.
    case "$(basename "${SHELL:-sh}")" in
        zsh)  printf '~/.zshrc' ;;
        bash) if [ "$(uname -s)" = Darwin ]; then printf '~/.bash_profile'; else printf '~/.bashrc'; fi ;;
        fish) printf '~/.config/fish/config.fish' ;;
        *)    printf 'your shell startup file' ;;
    esac
}

path_line() {   # The one line that adds to PATH — fish has different syntax
    if [ "$(basename "${SHELL:-sh}")" = fish ]; then
        printf 'fish_add_path %s %s' "$LIBEXEC" "$BINDIR"
    else
        printf 'export PATH="%s:%s:$PATH"' "$LIBEXEC" "$BINDIR"
    fi
}

# Uses the installed fmux if there is one; falls back to the repo's copy when there isn't yet
# (dry-run).
FMUX="$REPO/bin/fmux"

# ── the name "tt" ───────────────────────────────────────────────────────────
# The shim (libexec/claude) confirms we exist via `command -v tt`, so this name is required.
# But the most common way to hang a personal tool off ~/.local/bin is a **symlink** — a
# teammate may already be using tt for something else. The old guard was `[ -e ] && [ ! -L ]`,
# which protected regular files but replaced someone else's symlink with no warning and no
# backup (team deploy gate I2). The original target is left nowhere, so it's unrecoverable, and
# the screen only printed `ok …/tt → fmux`.
# Rule: only hang it **when the spot is empty or already ours**. Otherwise show what's there and
# let the person decide.
fmux_link_absent() {   # rc 0 = the spot is empty (a broken symlink does not count as empty)
    [ ! -e "$BINDIR/tt" ] && [ ! -L "$BINDIR/tt" ]
}

fmux_link_ours() {     # rc 0 = it's our symlink (fine to hang again — reruns must be idempotent)
    local t
    [ -L "$BINDIR/tt" ] || return 1
    t=$(readlink "$BINDIR/tt" 2>/dev/null) || return 1
    [ "$t" = fmux ] || [ "$t" = "$BINDIR/fmux" ]
}

fmux_link_what() {     # What's actually there — the person needs to see this before deciding
    if [ -L "$BINDIR/tt" ]; then
        printf 'symlink → %s' "$(readlink "$BINDIR/tt" 2>/dev/null || printf '?')"
    elif [ -d "$BINDIR/tt" ]; then printf 'a directory'
    elif [ -e "$BINDIR/tt" ]; then printf 'a regular file'
    else printf 'nothing'
    fi
}

# ── remote mode ─────────────────────────────────────────────────────────────
# Coming in via `curl -fsSL … | bash`, $0 is 'bash' and dirname is '.', so the REPO captured
# above is just "the current directory". Our files can't possibly be there — so the split is
# **by file existence**. (Conversely, piping the script from inside a clone still sees the
# files, so it goes local. That's correct.)
REMOTE=0
[ -f "$REPO/bin/fmux" ] && [ -d "$REPO/src" ] && [ -f "$REPO/Makefile" ] || REMOTE=1

# Public distribution address. **This is a placeholder because the repo is still private.**
# Forks, private mirrors, and testing override it with FMUX_SLUG (FMUX_SLUG=owner/repo ./install.sh).
SLUG="${FMUX_SLUG:-gabury1/fleetmux}"

DL=''        # download tool: curl | wget
SHA_CMD=''   # checksum tool: sha256sum (Linux) | shasum -a 256 (macOS). Empty if neither exists.
TMPD=''      # remote mode's temp directory. Deleted on EXIT whether it succeeded or failed.

# Cleanup is left to a single trap — code that only cleans up on the success path will
# eventually leak on a failure path. die() also exits, so it passes through this trap too.
cleanup_tmpd() {
    [ -n "$TMPD" ] || return 0
    if [ -d "$TMPD" ]; then
        rm -rf "$TMPD" && printf '  ok   deleted the temp directory: %s\n' "$TMPD"
    fi
    TMPD=''
}
trap 'cleanup_tmpd' EXIT
trap 'cleanup_tmpd; exit 130' INT
trap 'cleanup_tmpd; exit 143' TERM

# curl first, wget as fallback. If neither exists, say what's needed and stop.
pick_downloader() {
    if command -v curl > /dev/null 2>&1; then DL=curl; ok "downloading with curl"
    elif command -v wget > /dev/null 2>&1; then DL=wget; ok "downloading with wget (no curl)"
    else
        warn "neither curl nor wget is present — nothing can be downloaded."
        warn "     install one of them:  apt install curl  /  dnf install curl  /  brew install curl"
        warn "     or clone the repo and run ./install.sh from inside it (local mode)."
        die "no download tool available"
    fi
}

# $1=URL $2=destination file. rc 0 means it was fetched. A 404 or network failure returns
# rc≠0 and leaves no file behind (wget -O creates a file even on failure — the next step must
# not mistake that husk for a successful fetch).
fetch() {
    local rc=0
    case "$DL" in
        curl) curl -fsSL --max-time 60 -o "$2" "$1" || rc=$? ;;
        wget) wget -q -T 60 -O "$2" "$1" || rc=$? ;;
        *)    rc=1 ;;
    esac
    if [ "$rc" != 0 ] || [ ! -s "$2" ]; then rm -f "$2"; return 1; fi
    return 0
}

# The latest release tag. rc 1 if it cannot be determined — **it never falls back to main.**
# The moment main is broken, every new install breaking along with it is exactly why a tag is
# the default.
#
# Two ways, in this order, and the order is the point:
#   ① the /releases/latest redirect. Plain HTTPS: GitHub answers with a redirect to
#      /releases/tag/<tag>, so the tag is in the final URL. No API, and **no rate limit.**
#   ② the API, as a fallback.
#
# ① is first because ② has a hard ceiling: the GitHub API allows 60 unauthenticated calls
# per hour **per IP**, and returns 403 once that is spent. Measured 2026-08-06 — a macOS
# machine got 403 on its first install while another host on a different IP got 200 at the
# same moment. Behind a corporate NAT one busy colleague can burn the quota for everyone,
# and the failure looks like a broken release rather than a spent quota. An install path
# must not depend on a shared, invisible budget.
# A User-Agent is sent on ② because the GitHub API rejects requests without one.
latest_tag() {
    local f="$TMPD/latest.json" t='' url=''
    # ① redirect — no API, no rate limit
    case "$DL" in
        curl) url=$(curl -fsSLI -o /dev/null -w '%{url_effective}' --max-time 60 \
                    "https://github.com/$SLUG/releases/latest" 2>/dev/null) || url='' ;;
        wget) url=$(wget -q -S --max-redirect 10 -O /dev/null \
                    "https://github.com/$SLUG/releases/latest" 2>&1 \
                    | sed -n 's/^[[:space:]]*Location:[[:space:]]*\([^[:space:]]*\).*/\1/p' \
                    | tail -1) || url='' ;;
    esac
    case "$url" in
        */releases/tag/*)
            t=${url##*/releases/tag/}
            t=${t%%[?#]*}
            ;;
    esac
    if [ -n "$t" ]; then printf '%s' "$t"; return 0; fi

    # ② API fallback. The parser is a single sed (many machines do not have jq): split on
    #    commas, pull "tag_name":"…" out of the line.
    case "$DL" in
        curl) curl -fsSL --max-time 60 -A 'fleetmux-install' -o "$f" \
                   "https://api.github.com/repos/$SLUG/releases/latest" 2>/dev/null || return 1 ;;
        wget) wget -q -T 60 --user-agent='fleetmux-install' -O "$f" \
                   "https://api.github.com/repos/$SLUG/releases/latest" 2>/dev/null || return 1 ;;
        *)    return 1 ;;
    esac
    [ -s "$f" ] || return 1
    t=$(tr ',' '\n' < "$f" \
        | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
        | head -1)
    [ -n "$t" ] || return 1
    printf '%s' "$t"
}

pick_sha() {
    if command -v sha256sum > /dev/null 2>&1; then SHA_CMD='sha256sum'
    elif command -v shasum > /dev/null 2>&1; then SHA_CMD='shasum -a 256'
    else SHA_CMD=''
    fi
}

# A situation where verification is impossible. Checksum verification is the only defence a
# piped install has, so this **never passes through quietly**.
#   - --yes: halt. An unattended run must not install unverified.
#   - if we can ask: ask. Only continue once a human has looked and consented.
#   - if we can't ask (a piped install always lands here — stdin is the script itself):
#     ask_yn defaults to 'no' → halt.
no_verify_gate() {   # $1=why verification is impossible
    warn "$1"
    warn "     Checksum verification is the only defence a piped install (curl | bash) has —"
    warn "     we do not install unverified."
    if [ "$ASSUME_YES" = 1 ]; then
        die "--yes does not authorize an unverified install (only a human answering directly can continue)"
    fi
    ask_yn "Continue anyway, without SHA256 verification?" || die "not installing without verification"
    note "a human approved an unverified install — continuing"
}

# SHA256SUMS verification. On a mismatch, halt **immediately** (there is no warn-and-continue option).
verify_sums() {   # $1=downloaded archive  $2=SHA256SUMS
    local name want got
    name=$(basename "$1")
    pick_sha
    if [ -z "$SHA_CMD" ]; then
        no_verify_gate "neither sha256sum nor shasum is present — this machine has no tool to verify the downloaded file."
        return 0
    fi
    # format: '<hash>  <filename>' (a binary-mode '*' marker sometimes prefixes the filename)
    want=$(awk -v f="$name" '{ n=$2; sub(/^\*/, "", n); if (n == f) { print $1; exit } }' "$2")
    [ -n "$want" ] || die "no entry for $name in SHA256SUMS — this archive cannot be verified"
    got=$($SHA_CMD "$1" 2>/dev/null | awk 'NR==1{print $1}')
    [ -n "$got" ] || die "$SHA_CMD produced no hash — cannot verify"
    if [ "$want" = "$got" ]; then
        ok "SHA256 matches — $name"
        return 0
    fi
    warn "expected: $want"
    warn "actual:   $got"
    die "SHA256 mismatch — the downloaded file does not match the release. Not installing."
}

# ── step 0: fetch here first if remote (this precedes the eight steps) ─────
remote_fetch() {
    step 0/8 "remote — fetching the release archive"
    local asset root d

    pick_downloader
    command -v tar > /dev/null 2>&1 || die "tar is not present — cannot unpack the archive"

    TMPD=$(mktemp -d "${TMPDIR:-/tmp}/fmux-install.XXXXXX") || die "could not create a temp directory"
    ok "temp directory: $TMPD  (deleted when this finishes or fails)"

    if [ -n "$REF" ]; then
        note "fetching --ref: $REF"
    else
        REF=$(latest_tag) || REF=''
        if [ -z "$REF" ]; then
            warn "could not determine the latest release tag (https://api.github.com/repos/$SLUG/releases/latest)."
            warn "     not falling back to main — the day main is broken, every new install breaks with it."
            warn "     specify what to fetch directly:  ... | bash -s -- --ref v1.2.3"
            die "could not decide what to fetch"
        fi
        ok "latest release tag: $REF"
    fi

    asset="fleetmux-$REF.tar.gz"
    if fetch "https://github.com/$SLUG/releases/download/$REF/$asset" "$TMPD/$asset"; then
        ok "downloaded: $asset"
        if fetch "https://github.com/$SLUG/releases/download/$REF/SHA256SUMS" "$TMPD/SHA256SUMS"; then
            verify_sums "$TMPD/$asset" "$TMPD/SHA256SUMS"
        else
            no_verify_gate "this release ($REF) has no SHA256SUMS — nothing to verify the downloaded file against."
        fi
    elif fetch "https://github.com/$SLUG/archive/$REF.tar.gz" "$TMPD/src-$REF.tar.gz"; then
        # A branch or tag with no release. Source archives don't come with SHA256SUMS.
        asset="src-$REF.tar.gz"
        note "no release asset — fell back to the source archive: $REF"
        no_verify_gate "source archives don't come with SHA256SUMS — nothing to verify against."
    else
        warn "could not download: https://github.com/$SLUG/releases/download/$REF/$asset"
        warn "     check that the tag actually exists, and that the network is reachable."
        die "could not download the archive ($REF)"
    fi

    mkdir -p "$TMPD/x" || die "could not create $TMPD/x"
    tar -xzf "$TMPD/$asset" -C "$TMPD/x" || die "could not unpack the archive: $asset"

    # Doesn't rely on the top-level directory name inside the archive — finds wherever bin/fmux is.
    root=''
    for d in "$TMPD"/x/*/; do
        [ -f "${d}bin/fmux" ] || continue
        root=${d%/}; break
    done
    [ -n "$root" ] || { [ -f "$TMPD/x/bin/fmux" ] && root="$TMPD/x"; }
    [ -n "$root" ] || die "no bin/fmux inside the archive — this is not a fleetmux archive"

    REPO="$root"
    FMUX="$REPO/bin/fmux"       # every step below looks at these two
    ok "unpacked — treating this as the repo: $REPO"
    is_dry && note "--dry-run still fetches. Not one byte leaves the temp directory."
    return 0
}

# ── 1) dependencies ─────────────────────────────────────────────────────────
DEP_FAIL=''
dep_fail() { DEP_FAIL="$DEP_FAIL  - $1"$'\n'; }

HAVE_MAKE=0

check_deps() {
    step 1/8 "dependencies"
    local v rc

    # bash — the shell running this script itself. fmux only uses bash 3.2 syntax.
    if [ -z "${BASH_VERSION:-}" ]; then
        dep_fail "running under a non-bash shell — rerun with 'bash ./install.sh'"
    else
        ver_ge "$BASH_VERSION" 3.2; rc=$?
        if [ "$rc" = 0 ]; then ok "bash $BASH_VERSION"
        elif [ "$rc" = 1 ]; then dep_fail "bash $BASH_VERSION — 3.2 or newer is required"
        else ok "bash $BASH_VERSION (couldn't read the version string — not blocking on it)"
        fi
    fi

    # tmux — fmux opens as a tmux popup (display-popup). That command arrived in 3.2.
    if ! command -v tmux > /dev/null 2>&1; then
        dep_fail "tmux is not present — fmux is a tmux session cockpit. 3.2 or newer (popup display-popup)"
    else
        v=$(tmux -V 2>/dev/null | awk 'NR==1{print $2}') || v=''
        ver_ge "$v" 3.2; rc=$?
        if [ "$rc" = 0 ]; then ok "tmux $v"
        elif [ "$rc" = 1 ]; then dep_fail "tmux $v — 3.2 or newer is required (popup display-popup arrived in 3.2)"
        else warn "couldn't read the tmux version ('${v:-empty}') — check yourself that it's 3.2 or newer"
        fi
    fi

    # fzf — the list UI. --footer arrived in 0.64 and fmux uses it (90-main.sh).
    if ! command -v fzf > /dev/null 2>&1; then
        dep_fail "fzf is not present — the session list is fzf. 0.64 or newer (list footer --footer)"
    else
        v=$(fzf --version 2>/dev/null | awk 'NR==1{print $1}') || v=''
        ver_ge "$v" 0.64; rc=$?
        if [ "$rc" = 0 ]; then ok "fzf $v"
        elif [ "$rc" = 1 ]; then dep_fail "fzf $v — 0.64 or newer is required (fmux uses --footer)"
        else warn "couldn't read the fzf version ('${v:-empty}') — check yourself that it's 0.64 or newer"
        fi
    fi

    # awk — manifest integrity checks, list sorting, and wiring checks are all awk.
    if command -v awk > /dev/null 2>&1; then ok "awk"
    else dep_fail "awk is not present — manifest checks and list sorting are awk"
    fi

    # flock — nice to have. Nothing breaks without it: fmux exits early with
    #   `command -v flock || return 0` in all three places it's used (40-mfops.sh:9, 60-rc.sh:93,
    #   70-fleet.sh:406). macOS doesn't ship it by default — blocking on it here would mean no
    #   macOS user could install at all. So it doesn't block, it just says what gets weaker.
    if command -v flock > /dev/null 2>&1; then
        ok "flock"
    else
        warn "flock is not present — runs without duplicate-run protection (overlapping cron rounds, boot-restore doppelgangers)."
        warn "     install continues anyway. On macOS, get it with 'brew install flock'."
    fi

    # make — if present, uses make install; if not, copies the committed bin/fmux directly.
    if command -v make > /dev/null 2>&1; then HAVE_MAKE=1; ok "make"
    else warn "make is not present — copying the committed bin/fmux as-is (skipping the build)"
    fi

    if [ -n "$DEP_FAIL" ]; then
        printf '\nmissing or too old:\n%s' "$DEP_FAIL" >&2
        die "dependencies not satisfied"
    fi
}

# ── 2) binary ────────────────────────────────────────────────────────────
install_bin() {
    step 2/8 "binary — $BINDIR"

    [ -f "$REPO/bin/fmux" ] || die "$REPO/bin/fmux is missing — check that the repo is intact"

    # Build comes first, so the cmp below compares against "what would actually be installed".
    #   Remote mode does not build — **it installs exactly the bytes that were SHA256-verified.**
    #   Re-linking here could make what's installed differ from what was verified, which would
    #   defeat the point of verifying at all.
    if [ "$HAVE_MAKE" = 1 ] && [ "$REMOTE" = 0 ] && ! is_dry; then
        if ! make -C "$REPO" > /dev/null; then
            die "make failed — run 'make' directly to see why"
        fi
    fi

    if [ -e "$BINDIR/fmux" ]; then
        if cmp -s "$REPO/bin/fmux" "$BINDIR/fmux"; then
            ok "$BINDIR/fmux is already identical — leaving it as is"
        else
            note "$BINDIR/fmux already exists and differs → overwriting"
        fi
    fi

    if is_dry; then
        plan "mkdir -p $BINDIR && cp bin/fmux $BINDIR/fmux (make install PREFIX=$PREFIX)"
        if fmux_link_absent || fmux_link_ours; then
            plan "ln -sf fmux $BINDIR/tt   (symlink — the shim looks for 'tt' on PATH)"
        else
            plan "$BINDIR/tt is not ours ($(fmux_link_what)) → leaving it untouched (hook injection won't attach)"
        fi
    else
        if [ "$HAVE_MAKE" = 1 ] && [ "$REMOTE" = 0 ]; then
            # The Makefile's install target does both the fmux copy and the tt symlink together
            # — `make install` alone has to leave the tool usable. Here we just confirm the result.
            # (Remote mode never reaches here — it copies the verified bytes as-is. The else
            #  branch below is that path, and its tt symlink logic follows the same rule as the
            #  Makefile.)
            make -C "$REPO" install PREFIX="$PREFIX" > /dev/null || die "make install failed (PREFIX=$PREFIX)"
        else
            mkdir -p "$BINDIR" || die "could not create $BINDIR"
            cp "$REPO/bin/fmux" "$BINDIR/fmux" || die "could not write $BINDIR/fmux"
            chmod +x "$BINDIR/fmux" || die "could not make $BINDIR/fmux executable"
            if fmux_link_absent || fmux_link_ours; then ln -sf fmux "$BINDIR/tt"; fi
        fi
        [ -x "$BINDIR/fmux" ] || die "$BINDIR/fmux was not installed"
        did "$BINDIR/fmux"
        ok "$BINDIR/fmux"
        FMUX="$BINDIR/fmux"

        # The tt symlink. The shim no longer needs it — it looks for `fmux` on PATH now — so this
        # is kept only as a convenience alias, and only where the spot is free or already ours.
        # Someone else's tt is never touched.
        # If that name belongs to something else, it's left alone — **show what's there and let
        # the person decide**. An installer does not make an unrecoverable call on its own
        # (gate I2).
        if fmux_link_ours; then
            did "$BINDIR/tt → fmux"
            ok "$BINDIR/tt → fmux"
        elif fmux_link_absent; then
            warn "could not create the $BINDIR/tt symlink — run 'ln -sf fmux $BINDIR/tt' yourself"
        else
            warn "$BINDIR/tt is not ours — left untouched."
            warn "     currently there: $(fmux_link_what)"
            warn "     someone else's tt is never silently taken over. Decide what to do:"
            warn "       1) keep using that tool — fmux still works fine under the name 'fmux'."
            warn "          but the shim looks for 'tt' on PATH, so hook injection won't attach (no status marker)."
            warn "       2) give fmux this name — clear the spot yourself first:"
            warn "          mv $BINDIR/tt $BINDIR/tt.yours && ln -sf fmux $BINDIR/tt"
            warn "       3) hang 'tt' in a different PATH directory instead — the shim will find it there too."
        fi

        # Ask the installed binary a question that doesn't call tmux, to confirm it actually runs.
        "$BINDIR/fmux" config path > /dev/null 2>&1 || warn "the installed fmux does not respond to 'config path' — run it yourself to check"
    fi

    case ":$PATH:" in
        *":$BINDIR:"*) ok "$BINDIR is on PATH" ;;
        *) note "$BINDIR is not on PATH. Add this line to $(rc_hint) (not done automatically):"
           note "    $(path_line)" ;;
    esac
}

# ── 3) hook shim ─────────────────────────────────────────────────────────
install_shims() {
    step 3/8 "hook shim — $LIBEXEC"
    note "the shim attaches hooks via --settings only to claude/codex launched inside tmux —"
    note "  it never touches the global config (~/.claude/settings.json), and deleting this file removes all trace."

    local f name real_i shim_i
    for name in claude codex; do
        f="$REPO/libexec/$name"
        [ -f "$f" ] || die "$f is missing — check that the repo is intact"
    done

    for name in claude codex; do
        if [ -e "$LIBEXEC/$name" ]; then
            if cmp -s "$REPO/libexec/$name" "$LIBEXEC/$name"; then
                ok "$LIBEXEC/$name is already identical — leaving it as is"
                continue
            fi
            note "$LIBEXEC/$name already exists and differs → overwriting"
        fi
        if is_dry; then
            plan "cp libexec/$name $LIBEXEC/$name"
        else
            mkdir -p "$LIBEXEC" || die "could not create $LIBEXEC"
            cp "$REPO/libexec/$name" "$LIBEXEC/$name" || die "could not write $LIBEXEC/$name"
            chmod +x "$LIBEXEC/$name" || die "could not make $LIBEXEC/$name executable"
            did "$LIBEXEC/$name"
            ok "$LIBEXEC/$name"
        fi
    done

    # PATH order — the shim must come **before** the real claude. If it comes after, the real
    # claude launches, no hooks ever arrive, and the fleet status board silently dies whole
    # (the most common install failure).
    shim_i=$(path_index "$LIBEXEC")
    if [ "$shim_i" = 0 ]; then
        note "$LIBEXEC is not on PATH — hooks won't attach right now. Add to $(rc_hint):"
        note "    $(path_line)"
    else
        for name in claude codex; do
            real_i=$(first_real_index "$name")
            if [ "$real_i" = 0 ]; then
                note "could not find $name on PATH — if installed later, the shim will still come first (as long as PATH order stays the same)"
            elif [ "$shim_i" -lt "$real_i" ]; then
                ok "PATH order is good — shim ($shim_i) comes before the real $name ($real_i)"
            else
                warn "on PATH, the real $name ($real_i) comes before the shim ($shim_i) — hooks won't attach."
                warn "     move $LIBEXEC to the front of PATH: $(path_line)"
            fi
        done
    fi
}

# ── 4) tmux snippet ─────────────────────────────────────────────────────
SNIP=''
TMUXCONF=''

snip_path() {
    # Not reassembled here from scratch — reads the value fmux itself prints in its own header.
    # (Falls back to the same rule as 05-config.sh if that still can't be read.)
    local p=''
    p=$("$FMUX" --tmux-conf 2>/dev/null | awk '$1=="#" && $2=="source-file" {print $3; exit}') || p=''
    [ -n "$p" ] || p="${XDG_CONFIG_HOME:-$HOME/.config}/fleetmux/tmux.conf"
    printf '%s' "$p"
}

# Picks the user config file tmux reads. If a file already exists, uses that one — appending a
# line to the ~/.tmux.conf of someone who actually uses ~/.config/tmux/tmux.conf would mean
# "the line went in, but nothing happens." If neither exists, falls back to the conventional
# spot (~/.tmux.conf).
pick_tmux_conf() {
    local x="${XDG_CONFIG_HOME:-$HOME/.config}/tmux/tmux.conf"
    if [ -f "$HOME/.tmux.conf" ]; then printf '%s' "$HOME/.tmux.conf"
    elif [ -f "$x" ]; then printf '%s' "$x"
    else printf '%s' "$HOME/.tmux.conf"
    fi
}

# Is it already sourced? Comment lines don't count.
#   The check must be **line-start-anchored + exact argument match**. It used to be a partial
#   match on `*source*<path>*`, so appending to a file that didn't end in a newline produced a
#   corrupted line ("set -g mouse onsource-file …") that still passed as "already configured" —
#   a rerun couldn't self-heal, and the damage stayed permanently hidden (gate B2). Must follow
#   the same rule fmux itself uses (fmux_tmux_conf_linked in 87-tmux-conf.sh).
already_sourced() {   # $1=config file  $2=snippet path
    local line rest
    [ -r "$1" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        while :; do case "$line" in [[:blank:]]*) line=${line#?} ;; *) break ;; esac; done
        case "$line" in
            'source-file '*) rest=${line#source-file } ;;
            'source '*)      rest=${line#source } ;;
            *) continue ;;
        esac
        # Strips leading flags (like -q), trims trailing whitespace and quotes, then compares
        # exactly. Not split into words: a * in someone else's config line would expand into
        # filenames.
        while :; do case "$rest" in '-'*' '*) rest=${rest#* } ;; *) break ;; esac; done
        while :; do case "$rest" in *[[:blank:]]) rest=${rest%?} ;; *) break ;; esac; done
        case "$rest" in '"'*'"'|"'"*"'") rest=${rest#?}; rest=${rest%?} ;; esac
        # Tildes (~/…) are expanded before comparing — that's the form README teaches and how
        # tmux itself reads it (gate I1). Without expanding, a rerun appends a **duplicate
        # source line** for anyone who followed the docs and typed it by hand.
        # The pattern quotes \~ because bash also expands tildes in the word of ${var#word}.
        case "$rest" in
            '~')   rest="$HOME" ;;
            '~/'*) rest="$HOME/${rest#\~/}" ;;
        esac
        [ "$rest" = "$2" ] && return 0
    done < "$1"
    return 1
}

# The one place a line gets appended to someone else's file — extra care applies here (gate B1).
#   1) Before editing, back up the entire original and tell the person its path.
#   2) If the last byte isn't a newline, add one first. Using `>>` alone would glue our line
#      onto the user's last line, corrupting it (and still be reported as rc 0 "success").
#   `tail -c 1` is POSIX (not GNU-only). Command substitution strips the trailing newline, so
#   an empty result means the last byte already was a newline.
append_source_line() {   # $1=config file  $2=snippet path  → rc 0 means it was added
    local f="$1" snip="$2" last
    if [ -s "$f" ]; then
        cp "$f" "$f.fmux-bak" || { warn "could not back up $f — nothing was changed"; return 1; }
        ok "backed up: $f.fmux-bak  (restore this file to undo)"
        last=$(tail -c 1 "$f" 2>/dev/null) || last=''
        if [ -n "$last" ]; then
            note "$f does not end in a newline — adding one first so the last line isn't corrupted"
            printf '\n' >> "$f" || return 1
        fi
    fi
    printf 'source-file %s\n' "$snip" >> "$f" || return 1
    return 0
}

# Order is the discipline here (gate B5): **consent → the line in someone else's file → writing
# our own snippet**.
#   It used to write the snippet first. That write, if inside tmux, fires source-file at the
#   live server immediately, so it was already applied before "add this line?" was even asked —
#   and even answering n still left the message saying "not added." fmux itself now has a gate
#   too (fmux_tmux_conf_linked) — it only takes effect when the line is actually present in the
#   user's config. With this order, "only someone who consented gets it applied to this server
#   too" holds on both sides.
install_snippet() {
    step 4/8 "tmux snippet"
    SNIP=$(snip_path)          # only asks for the path, doesn't write the file (not --write)
    TMUXCONF=$(pick_tmux_conf)
    local linked=0 out

    if already_sourced "$TMUXCONF" "$SNIP"; then
        linked=1
        ok "$TMUXCONF already sources this file — adding nothing"
    else
        printf '  line to add: source-file %s\n' "$SNIP"
        printf '  target:      %s\n' "$TMUXCONF"
        if ask_yn "Add this one line to $TMUXCONF?"; then
            if is_dry; then
                plan "back up $TMUXCONF to $TMUXCONF.fmux-bak, then add one line: source-file $SNIP"
            else
                append_source_line "$TMUXCONF" "$SNIP" || die "could not write to $TMUXCONF"
                linked=1
                did "one line source-file added to $TMUXCONF"
                ok "added a line to $TMUXCONF"
                note "if already inside tmux, run prefix + : then 'source-file $TMUXCONF' once (or start a new tmux server)"
            fi
        else
            note "not added. Add the line above to $TMUXCONF yourself to bring the summon key to life."
            note "  until it's added, our snippet isn't applied to any tmux server — only the file itself gets created."
        fi
    fi

    # Now write the snippet. This file is ours, so it's fine to create without consent, but it
    # only takes effect on a live server for whoever ended up linked above (fmux's own gate
    # makes the same call).
    if is_dry; then
        plan "$FMUX --tmux-conf --write   → $SNIP"
    else
        out=$("$FMUX" --tmux-conf --write) || die "could not write the snippet: $SNIP"
        [ -n "$out" ] && SNIP="$out"
        did "$SNIP (tmux snippet)"
        ok "$SNIP"
    fi
    note "this file belongs to fmux — it holds the summon key and the on-detach snapshot hook, and gets rewritten when config changes."
    [ "$linked" = 1 ] || note "no tmux config reads this file yet — the summon key comes alive once it's linked."
    return 0
}

# ── 5) summon key preset ─────────────────────────────────────────────────
# A single physical key arrives under a different name on each terminal — hence the list
# (87-tmux-conf.sh).
#
# ── why the suggestion is S-Up (the reasoning is recorded here) ───────────
# The prefix approach was rejected: "having to press twice is annoying." What's wanted is a
# single no-prefix keystroke. Scanning the combinations, **Shift+arrow is the only single
# keystroke that gets through on all three platforms**:
#
#   C-arrow   : macOS Mission Control takes it (space switching, window overview)
#   M-arrow   : macOS sends Option as ESC b, and Windows Terminal eats Alt+arrow itself first
#   Ctrl+key  : almost always already used by shell line editing, vim, emacs, fzf widgets
#   S-arrow   : gets through on all three platforms. Not a stretch either (Shift sits right next
#               to the arrows)
#
# The direction is **up**, and that is the one part that changed with use:
#   - S-Up and S-Down are the arrows dotfiles most often bind to tmux window switching. The
#     summon key should not be the one arrow pair people have already spent.
#   - S-Up / S-Down are free in stock tmux — the defaults use M-arrow for resize and C-arrow for
#     pane selection, and neither touches Shift.
#   - Up reads as "raise the cockpit over what I am doing", which is what the popup does. Inside
#     the popup the horizontal pair keeps its own meaning: → enters, ← closes — the convention
#     ranger, lf, nnn and vifm all use.
#
# One risk remains, stated honestly: a Shift+arrow bound to *pane* navigation would collide.
# preset_conflicts below reads config files first and warns; anyone in that situation should pick
# a different preset at install time.
#
# The policy splits in two (paired with the key_summon_fast default comment in 05-config.sh):
#   config default = empty (steals no key)  ·  installer's suggestion = shift (S-Up)
# The suggestion is only valid when there's a place for a human to look at it and say "yes."
# So --yes and non-terminal contexts still go to safe — automatic approval must never take
# someone else's key.
preset_value() {
    case "${1:-}" in
        safe)  printf '' ;;
        shift) printf 'S-Up' ;;
        mac)   printf 'M-b' ;;
        linux) printf 'C-Left M-Left' ;;
        wsl)   printf 'C-Left' ;;
        *)     return 1 ;;
    esac
    return 0
}

preset_why() {
    case "${1:-}" in
        safe)  printf 'uses only the summon key behind prefix — steals no one else key' ;;
        shift) printf 'the only no-prefix single keystroke that reaches macOS, Linux, and Windows Terminal all three' ;;
        mac)   printf "macOS's Option+Left arrives as M-b because the terminal sends it as ESC b" ;;
        linux) printf 'arrives as C-Left or M-Left depending on the terminal — binds both' ;;
        wsl)   printf 'Windows Terminal eats Alt+arrow itself first — only C-Left is left' ;;
    esac
}

# The preset the prompt defaults to. Not the platform-detected value — it defaults to the one
# key (S-Up) that works across all three platforms. The detected value is still shown on
# screen, but that's information about "this machine looks like X," not the suggestion itself.
PRESET_SUGGEST=shift

# Whether the user's own config already binds the key a preset would claim — so they're warned
# before it's overwritten. Doesn't ask a live tmux server (list-keys): the installer must work
# even with no server running, and talking to someone else's live server is exactly the kind of
# thing this project doesn't do. So it reads **only config files**.
# That makes this detection incomplete — it can't see a binding that isn't in the file (sourced
# from another snippet, or typed by hand elsewhere). Because of that limit, the suggestion text
# also says "pick a different key if you're already using this one."
preset_conflicts() {   # $1=space-separated key list → one line per hit: "key  file:line  full line"
    local keys="${1:-}" f line k n raw
    [ -n "$keys" ] || return 0
    for f in "$HOME/.tmux.conf" "${XDG_CONFIG_HOME:-$HOME/.config}/tmux/tmux.conf"; do
        [ -r "$f" ] || continue
        # Our own snippet is not a candidate — calling what we bound last time "someone else's
        # key" would be false.
        [ "$f" = "${SNIP:-}" ] && continue
        n=0
        while IFS= read -r line || [ -n "$line" ]; do
            n=$((n + 1))
            raw="$line"
            while :; do case "$line" in [[:blank:]]*) line=${line#?} ;; *) break ;; esac; done
            case "$line" in 'bind '*|'bind-key '*) ;; *) continue ;; esac
            for k in $keys; do
                # Checked on word boundaries — padding both sides with a space blocks a partial
                # match (Left inside C-Left).
                case " $line " in *" $k "*) printf '%s  %s:%s  %s\n' "$k" "$f" "$n" "$raw" ;; esac
            done
        done < "$f"
    done
    return 0
}

detect_preset() {
    case "$(uname -s 2>/dev/null || echo unknown)" in
        Darwin) printf 'mac'; return 0 ;;
    esac
    if [ -n "${WSL_DISTRO_NAME:-}" ] || [ -n "${WSLENV:-}" ]; then printf 'wsl'; return 0; fi
    if [ -r /proc/version ]; then
        case "$(cat /proc/version 2>/dev/null)" in
            *[Mm]icrosoft*|*WSL*) printf 'wsl'; return 0 ;;
        esac
    fi
    printf 'linux'
}

install_preset() {
    step 5/8 "summon key"
    local guess want cur v clash sug line

    guess=$(detect_preset)
    sug=$(preset_value "$PRESET_SUGGEST")

    # The suggestion appears **first, identically** no matter which branch is taken. Someone
    # running under --yes or CI still needs to see right there "what wasn't taken and how to
    # get it" — only the decision itself branches.
    note "suggested: $PRESET_SUGGEST — key_summon_fast='$sug' ($(preset_why "$PRESET_SUGGEST"))"
    note "  this takes the key away from every app in the pane — vim, shell line editing, and fzf won't see S-Up in that pane."
    note "  dotfiles that bind S-Up/S-Down to tmux window switching are common. Pick a different key if you're already using it."
    clash=$(preset_conflicts "$sug")
    if [ -n "$clash" ]; then
        warn "found a line in your config already binding that key — our binding wins if you pick this preset:"
        printf '%s\n' "$clash" | while IFS= read -r line; do printf '      %s\n' "$line"; done
    fi

    if [ -n "$PRESET" ]; then
        preset_value "$PRESET" > /dev/null 2>&1 || die "unknown preset: $PRESET (safe|shift|mac|linux|wsl)"
        want="$PRESET"
        note "preset given as an argument: $want"
    elif [ "$ASSUME_YES" = 1 ]; then
        # --yes goes to **safe** (team deploy gate I3). It used to auto-adopt the detected
        # preset — on Linux, `./install.sh --yes` would silently steal two no-prefix keys
        # (C-Left M-Left) globally, while the README was promising "steals no key until you say
        # so." Taking a key is a global change that's a pain to undo, so it doesn't belong in
        # the category of "accepting a default" — it's only taken when a human **explicitly**
        # specifies --preset. This rule holds even after the suggestion became S-Up — the
        # suggestion getting better and it being fine to take without consent are different
        # statements.
        want=safe
        note "--yes goes to safe, stealing no key — a no-prefix key is only taken when explicitly specified"
        note "  for a single keystroke: ./install.sh --yes --preset $PRESET_SUGGEST   (this machine looks like $guess)"
    elif [ "$ASK_TTY" = 0 ]; then
        # A no-prefix binding steals someone's key. Where we can't ask, default to not stealing.
        want=safe
        note "not a terminal, so we did not ask — going with safe, which steals no key"
        note "  for a single keystroke: ./install.sh --preset $PRESET_SUGGEST   (this machine looks like $guess)"
    else
        note "choices:"
        note "shift  S-Up — the suggestion above (default)"
        note "safe   no no-prefix key — $(preset_why safe)"
        note "mac    M-b — $(preset_why mac)"
        note "linux  C-Left M-Left — $(preset_why linux)"
        note "wsl    C-Left — $(preset_why wsl)"
        note "detected: $(uname -s 2>/dev/null || echo unknown) → $guess. Still, the suggestion is $PRESET_SUGGEST —"
        note "  the mac/linux/wsl presets each only work on their own platform; S-Up is the only one that works on all three."
        note "  declining (safe) goes with the prefix approach — press prefix, then the summon key. Steals no key."
        want=$(ask_word "preset (shift|safe|mac|linux|wsl)" "$PRESET_SUGGEST")
        if ! preset_value "$want" > /dev/null 2>&1; then
            warn "unknown preset '$want' — going with safe"
            want=safe
        fi
    fi
    v=$(preset_value "$want")
    note "$want: key_summon_fast='$v' — $(preset_why "$want")"
    # If a key other than the suggestion was picked, check it again — the check above was for S-Up.
    if [ "$want" != "$PRESET_SUGGEST" ] && [ -n "$v" ]; then
        clash=$(preset_conflicts "$v")
        if [ -n "$clash" ]; then
            warn "found a line in your config already binding the key you picked — our binding wins:"
            printf '%s\n' "$clash" | while IFS= read -r line; do printf '      %s\n' "$line"; done
        fi
    fi
    note "the summon key behind prefix (key_summon) is left as-is — to change it: fmux config set key_summon <key>"

    cur=$("$FMUX" config get key_summon_fast 2>/dev/null) || cur=''
    if [ "$cur" = "$v" ]; then
        ok "key_summon_fast is already '$v' — leaving it as is"
        return 0
    fi

    if is_dry; then
        if [ -z "$v" ]; then plan "fmux config unset key_summon_fast   (currently: '$cur')"
        else plan "fmux config set key_summon_fast '$v'   (currently: '$cur')"; fi
        return 0
    fi

    # config set/unset rewrite the snippet themselves (fmux_conf_resnip in 85-config-cli.sh).
    if [ -z "$v" ]; then
        "$FMUX" config unset key_summon_fast > /dev/null || die "could not clear key_summon_fast"
        did "removed config key_summon_fast (safe)"
    else
        "$FMUX" config set key_summon_fast "$v" > /dev/null || die "could not set key_summon_fast"
        did "config key_summon_fast='$v'"
    fi
    ok "key_summon_fast='$v' (the snippet was rewritten too)"
}

# ── 6) agent skill ────────────────────────────────────────────────────────
SKILL_SRC=''
SKILL_DST=''
SKILL_BAK=''

# One line per file that our copy (cp -R "$SKILL_SRC/." "$SKILL_DST/") would **overwrite
# content that isn't ours**. Empty means nothing would be lost — in which case there's no
# reason to back up either.
#   Why check this instead of just "the directory differs": cp merges, so a file not present in
#   SRC (a note the user left alongside, say) was never at risk to begin with. Counting that as
#   'different' would pile up a backup on every rerun.
skill_clobber_list() {
    local f rel
    [ -n "$SKILL_SRC" ] && [ -e "$SKILL_DST" ] || return 0
    if [ ! -d "$SKILL_DST" ]; then printf '%s\n' "$SKILL_DST"; return 0; fi
    # find is POSIX. Directories aren't counted — cp -R never deletes a directory.
    find "$SKILL_SRC" -type f 2>/dev/null | while IFS= read -r f; do
        rel=${f#"$SKILL_SRC"/}
        [ -e "$SKILL_DST/$rel" ] || continue
        cmp -s "$f" "$SKILL_DST/$rel" || printf '%s\n' "$rel"
    done
}

install_skill() {
    step 6/8 "agent skill"
    local clob=''
    SKILL_SRC="$REPO/skills/fleetmux"
    SKILL_DST="$HOME/.claude/skills/fleetmux"

    if [ ! -f "$SKILL_SRC/SKILL.md" ]; then
        skip "this repo has no skills/fleetmux/SKILL.md — skipping"
        SKILL_SRC=''
        SKILL_DST=''      # if it wasn't installed, it must not show up in the 'to remove' list either
        return 0
    fi

    if [ -e "$SKILL_DST" ]; then
        note "$SKILL_DST already exists → will overwrite (only the files we place)"
        note "  if there's content of yours that would be overwritten, it's backed up whole to $SKILL_DST.fmux-bak first"
        note "  if that backup already exists, it's your original — left untouched, this run's backup gets a timestamp instead"
    fi
    if ask_yn "Install the agent skill to $SKILL_DST?"; then
        if is_dry; then
            plan "mkdir -p $SKILL_DST && cp -R skills/fleetmux/. $SKILL_DST/"
        else
            # Someone else's files are never overwritten in a way that can't be undone — for
            # anyone already using a skill with our same name, --yes means "accept the
            # suggested defaults," not "throw away your skill" (recommendation N1).
            #
            # WARNING: **once a backup exists, it is never overwritten** (team deploy gate C3).
            #   This used to start with `rm -rf "$SKILL_DST.fmux-bak"` — a second run would
            #   delete the **user's original** left by the first run, then back up the
            #   directory that was already overwritten with our files into that same spot. The
            #   screen printed "backed up" both times, yet the user's original ends up nowhere
            #   on the machine. This directly broke README's promise that reruns are safe.
            #   Current rule: 1) if our copy would overwrite none of someone else's content, no
            #   backup is made (a copy piling up on every rerun is itself an incident) 2) if
            #   .fmux-bak already exists, that's the original — leave it untouched and give
            #   this run's backup a timestamp instead.
            clob=$(skill_clobber_list)
            if [ -e "$SKILL_DST" ] && [ -z "$clob" ]; then
                ok "nothing at $SKILL_DST that our copy would overwrite — nothing to back up"
            elif [ -e "$SKILL_DST" ]; then
                note "files to be overwritten: $(printf '%s' "$clob" | tr '\n' ' ')"
                SKILL_BAK="$SKILL_DST.fmux-bak"
                if [ -e "$SKILL_BAK" ]; then
                    note "$SKILL_BAK already exists — that's your original from the first run. Not overwriting it."
                    # If two runs land in the same second, the backup would nest inside the
                    # backup. $$ separates them per run.
                    SKILL_BAK="$SKILL_DST.fmux-bak.$(date +%Y%m%d-%H%M%S).$$"
                fi
                cp -R "$SKILL_DST" "$SKILL_BAK" \
                    || die "could not back up $SKILL_DST — stopping without overwriting"
                did "$SKILL_BAK (backup before overwrite)"
                ok "backed up: $SKILL_BAK"
            fi
            mkdir -p "$SKILL_DST" || die "could not create $SKILL_DST"
            cp -R "$SKILL_SRC/." "$SKILL_DST/" || die "could not copy to $SKILL_DST"
            did "$SKILL_DST/"
            ok "$SKILL_DST/"
        fi
    else
        SKILL_DST=''
        note "not installed. Later: cp -R $SKILL_SRC/. ~/.claude/skills/fleetmux/"
    fi
}

# ── 7) cron guidance (display only) ──────────────────────────────────────
show_cron() {
    step 7/8 "cron — display only"
    note "this script never touches crontab. Add these yourself with 'crontab -e' if you want them:"
    printf '\n'
    printf '    * * * * * %s/fmux --cron >/dev/null 2>&1\n' "$BINDIR"
    printf '    @reboot %s/fmux --boot-restore >/dev/null 2>&1\n' "$BINDIR"
    printf '\n'
    note "first line: rc auto-recovery + fleet snapshot every minute (the manifest stays under a minute stale)"
    note "second line: session and conversation restore after boot. To turn it off some day: touch ~/.cache/fmux/no-autorestore"
    note "both can also be turned off with fmux config: fmux config set rc off / snapshot off / boot_restore off"
}

# ── 8) summary ────────────────────────────────────────────────────────────
summary() {
    step 8/8 "summary"
    local fastnow
    if is_dry; then
        printf '  this was --dry-run — created zero files. The dry lines above are what would be done.\n'
        printf '  to actually do it: ./install.sh\n'
        return 0
    fi

    printf '\nwhat is where\n'
    printf '%s' "$DID"

    printf '\nnext step\n'
    case ":$PATH:" in
        *":$BINDIR:"*) printf '  - try tt in a new tmux session (or prefix + %s)\n' "$("$FMUX" config get key_summon 2>/dev/null || echo F)" ;;
        *) printf '  - fix PATH first: %s\n' "$(path_line)" ;;
    esac
    # If a no-prefix key was actually bound, name it. If not, say how to get one — the screen
    # and the docs must not contradict each other, and "we took nothing" is part of the result too.
    fastnow=$("$FMUX" config get key_summon_fast 2>/dev/null) || fastnow=''
    if [ -n "$fastnow" ]; then
        printf '  - a no-prefix single keystroke is also bound: %s  (to undo: fmux config unset key_summon_fast)\n' "$fastnow"
    else
        printf '  - no no-prefix single keystroke was bound — if you want one: fmux config set key_summon_fast %s\n' "$(preset_value "$PRESET_SUGGEST")"
    fi
    printf '  - fmux --help explains keys, config, and restore in full. fmux config list shows the config.\n'

    printf '\nto remove\n'
    printf '  rm -f  %s/fmux %s/tt\n' "$BINDIR" "$BINDIR"
    printf '  rm -rf %s\n' "$LIBEXEC"
    printf '  rm -f  %s\n' "$SNIP"
    printf '  rm -rf %s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/fleetmux"
    printf '  rm -rf %s/.cache/fmux   (state and logs — deleting only loses history)\n' "$HOME"
    printf "  delete the 'source-file %s' line in %s\n" "$SNIP" "$TMUXCONF"
    [ -n "$SKILL_DST" ] && printf '  rm -rf %s\n' "$SKILL_DST"
    printf '  if you added lines to crontab, remove them yourself with crontab -e\n'
    printf '  note: before running the lines above as-is, check that none of your own files ended up mixed in there.\n'
    printf '    every backup we left before overwriting something is named <original>.fmux-bak.\n'
}

# ── main ────────────────────────────────────────────────────────────────────
# The user needs to know what's about to happen before anything happens — announce which mode
# this run is in, in one line, before starting.
printf 'fleetmux install\n'
if [ "$REMOTE" = 1 ]; then
    printf '  mode   remote — no repo here (%s). Fetching and installing the release archive.\n' "$REPO"
    printf '         fetching: %s\n' "${REF:-latest release tag (will be determined)}"
else
    printf '  mode   local — a repo is right here. Installing its bin/fmux.\n'
    printf '  repo   %s\n' "$REPO"
    [ -n "$REF" ] && printf '  note   --ref %s is not used in local mode — installing this repo as-is\n' "$REF"
fi
printf '  prefix %s\n' "$PREFIX"
is_dry && printf '  mode   --dry-run — changing nothing\n'
[ "$ASSUME_YES" = 1 ] && printf '  mode   --yes — yes to every prompt\n'

[ "$REMOTE" = 1 ] && remote_fetch

check_deps
install_bin
install_shims
install_snippet
install_preset
install_skill
show_cron
summary

printf '\ndone.\n'
exit 0
