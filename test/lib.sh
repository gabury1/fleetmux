# fleetmux test common — pure bash. No dependencies.
# Each test file sources this file and starts with fmux_test_sandbox.

FMUX_FAIL=0
FMUX_RUN=0

# Builds an isolated HOME/XDG so we never touch the real ~/.config, ~/.cache.
# Call it once per file — a second call would overwrite the trap and leak the first FMUXROOT, so it refuses.
fmux_test_sandbox() {
    if [ "${FMUX_SANDBOX_DONE:-0}" = 1 ]; then
        echo "fmux_test_sandbox: already called once in this process — call it once per file" >&2
        exit 1
    fi
    FMUX_SANDBOX_DONE=1

    FMUXROOT=$(mktemp -d "${TMPDIR:-/tmp}/fmux-test.XXXXXX") || exit 1
    export HOME="$FMUXROOT/home"
    export XDG_CONFIG_HOME="$FMUXROOT/home/.config"
    # install.sh asks the controlling terminal through /dev/tty when stdin is a pipe. A test
    # run from a terminal can open /dev/tty too, so without this the suite would answer
    # questions differently depending on whether a human happened to be watching it.
    export FMUX_TTY=off
    mkdir -p "$HOME" "$XDG_CONFIG_HOME"
    # Isolate the socket name so tests never attach to a real tmux server.
    # TMUX_TMPDIR alone isn't enough — if this shell is already inside a tmux client, a bare
    # `tmux` call finds the server via $TMUX (which has a socket path baked in), not
    # TMUX_TMPDIR. If we don't unset $TMUX, fleetmux's ~20 no-option tmux call sites leak
    # through to the developer's real tmux server.
    export TMUX_TMPDIR="$FMUXROOT"
    unset TMUX

    # Interfaces contract from the briefing: fmux_test_sandbox sets FMUXBIN.
    # If run.sh already exported a value, keep it; otherwise (e.g. a standalone
    # `bash test/t-0N.sh` run) derive it from lib.sh's own location — never rely on $PWD.
    if [ -z "${FMUXBIN:-}" ]; then
        local _lib_dir
        _lib_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd) || exit 1
        export FMUXBIN="$_lib_dir/bin/fmux"
    fi

    fmux_test_seal_tmux

    # To pull the seal log out for inspection: run with FMUX_TMUX_STUB_KEEP=<dir> and it
    # leaves the full transcript of what the fake tmux received, per file (as verification
    # evidence). Nothing is kept by default.
    trap 'fmux_test_keep_stub_log; rm -rf "$FMUXROOT"' EXIT
}

fmux_test_keep_stub_log() {
    [ -n "${FMUX_TMUX_STUB_KEEP:-}" ] || return 0
    mkdir -p "$FMUX_TMUX_STUB_KEEP" 2>/dev/null || return 0
    local tag
    tag=$(basename "${0:-unknown}")
    cp "$FMUX_TMUX_STUB_LOG"     "$FMUX_TMUX_STUB_KEEP/$tag.calls"   2>/dev/null || true
    cp "$FMUX_TMUX_STUB_REFUSED" "$FMUX_TMUX_STUB_KEEP/$tag.refused" 2>/dev/null || true
}

# ── sealed fake tmux ────────────────────────────────────────────────────────
# Socket isolation alone (TMUX_TMPDIR + unset TMUX) wasn't enough. That only decides "which
# server does it attach to" — **the real tmux binary still runs**. So for two full rounds
# nobody could run `make check` — a suite that calls the real tmux can't be run on a machine
# with a live fleet on it. A harness that can't verify is a verification hole.
#
# So we plant a script named tmux at the front of PATH to seal the binary itself:
#   ① Every call is recorded, one line each, in FMUX_TMUX_STUB_LOG (evidence of what went out).
#   ② Read-only queries get the same answer as "no server on this machine" — rc 1 + one
#      stderr line. That matches what this suite actually saw before the seal existed (the
#      isolated TMUX_TMPDIR has no server), so it doesn't weaken any assertion.
#   ③ Subcommands that mutate state (new-session · kill-* · send-keys · source-file …) are
#      **refused** and logged separately to FMUX_TMUX_STUB_REFUSED. Tests check that file is
#      empty to confirm "did we almost touch someone else's server."
#   ④ Only -V gets a real-looking answer (the only read query the dependency check needs).
#
# Tests that need their own fake tmux (t-03 · t-11 · t-12) can stack their own ahead of this
# on PATH, or replace PATH outright, after this runs — the seal only guarantees "safe by default."
fmux_test_seal_tmux() {
    FMUX_TMUX_STUB_DIR="$FMUXROOT/sealbin"
    FMUX_TMUX_STUB_LOG="$FMUXROOT/tmux-stub.log"
    FMUX_TMUX_STUB_REFUSED="$FMUXROOT/tmux-stub-refused.log"
    export FMUX_TMUX_STUB_DIR FMUX_TMUX_STUB_LOG FMUX_TMUX_STUB_REFUSED
    mkdir -p "$FMUX_TMUX_STUB_DIR" || exit 1
    : > "$FMUX_TMUX_STUB_LOG"
    : > "$FMUX_TMUX_STUB_REFUSED"
    cat > "$FMUX_TMUX_STUB_DIR/tmux" <<'FMUX_TMUX_STUB'
#!/usr/bin/env bash
# fake tmux for fleetmux tests — the real tmux never runs in this suite.
printf '%s\n' "$*" >> "${FMUX_TMUX_STUB_LOG:-/dev/null}"
case "${1:-}" in
    -V)
        printf 'tmux 3.5a\n'; exit 0 ;;
    ls|list-sessions|list-panes|list-windows|list-clients|list-keys|\
    display-message|display|capture-pane|show-options|show|show-environment|has-session)
        # read-only — same answer as a machine with no server. Changes nothing.
        printf 'no server running on %s/default\n' "${TMUX_TMPDIR:-/tmp}" >&2
        exit 1 ;;
esac
printf '%s\n' "$*" >> "${FMUX_TMUX_STUB_REFUSED:-/dev/null}"
printf 'fleetmux test stub: refused a state-mutating tmux subcommand: %s\n' "${1:-<none>}" >&2
exit 1
FMUX_TMUX_STUB
    chmod +x "$FMUX_TMUX_STUB_DIR/tmux" || exit 1
    PATH="$FMUX_TMUX_STUB_DIR:$PATH"
    export PATH
}

# Asserts the sealed fake tmux never received a state-mutating subcommand.
# (Tests that stack their own PATH don't use this log, so they check their own instead.)
assert_no_tmux_mutation() {
    FMUX_RUN=$((FMUX_RUN + 1))
    if [ ! -s "$FMUX_TMUX_STUB_REFUSED" ]; then
        printf '  ok   %s\n' "${1:-sealed fake tmux never received a state-mutating subcommand}"
    else
        FMUX_FAIL=$((FMUX_FAIL + 1))
        printf '  FAIL %s\n       refused log:\n%s\n' \
            "${1:-sealed fake tmux never received a state-mutating subcommand}" \
            "$(sed 's/^/         /' "$FMUX_TMUX_STUB_REFUSED")"
    fi
}

assert_eq() {
    FMUX_RUN=$((FMUX_RUN + 1))
    if [ "$1" = "$2" ]; then
        printf '  ok   %s\n' "$3"
    else
        FMUX_FAIL=$((FMUX_FAIL + 1))
        printf '  FAIL %s\n       expected: [%s]\n       actual:   [%s]\n' "$3" "$2" "$1"
    fi
}

assert_contains() {
    FMUX_RUN=$((FMUX_RUN + 1))
    case "$1" in
        *"$2"*) printf '  ok   %s\n' "$3" ;;
        *) FMUX_FAIL=$((FMUX_FAIL + 1))
           printf '  FAIL %s\n       [%s] does not contain [%s]\n' "$3" "$1" "$2" ;;
    esac
}

# rc check — wrapped so it doesn't die under set -e
assert_rc() {
    local want="$1"; shift
    local got=0
    "$@" >/dev/null 2>&1 || got=$?
    FMUX_RUN=$((FMUX_RUN + 1))
    if [ "$got" = "$want" ]; then
        printf '  ok   rc=%s  %s\n' "$want" "$1"
    else
        FMUX_FAIL=$((FMUX_FAIL + 1))
        printf '  FAIL rc  %s\n       expected: %s  actual: %s\n' "$*" "$want" "$got"
    fi
}

fmux_test_done() {
    printf '  — %d of %d failed\n' "$FMUX_FAIL" "$FMUX_RUN"
    [ "$FMUX_FAIL" = 0 ]
}
