# fleetmux test common — pure bash. No dependencies.
# Each test file sources this file and starts with tt_test_sandbox.

TT_FAIL=0
TT_RUN=0

# Builds an isolated HOME/XDG so we never touch the real ~/.config, ~/.cache.
# Call it once per file — a second call would overwrite the trap and leak the first TTROOT, so it refuses.
tt_test_sandbox() {
    if [ "${TT_SANDBOX_DONE:-0}" = 1 ]; then
        echo "tt_test_sandbox: already called once in this process — call it once per file" >&2
        exit 1
    fi
    TT_SANDBOX_DONE=1

    TTROOT=$(mktemp -d "${TMPDIR:-/tmp}/fmux-test.XXXXXX") || exit 1
    export HOME="$TTROOT/home"
    export XDG_CONFIG_HOME="$TTROOT/home/.config"
    mkdir -p "$HOME" "$XDG_CONFIG_HOME"
    # Isolate the socket name so tests never attach to a real tmux server.
    # TMUX_TMPDIR alone isn't enough — if this shell is already inside a tmux client, a bare
    # `tmux` call finds the server via $TMUX (which has a socket path baked in), not
    # TMUX_TMPDIR. If we don't unset $TMUX, fleetmux's ~20 no-option tmux call sites leak
    # through to the developer's real tmux server.
    export TMUX_TMPDIR="$TTROOT"
    unset TMUX

    # Interfaces contract from the briefing: tt_test_sandbox sets TTBIN.
    # If run.sh already exported a value, keep it; otherwise (e.g. a standalone
    # `bash test/t-0N.sh` run) derive it from lib.sh's own location — never rely on $PWD.
    if [ -z "${TTBIN:-}" ]; then
        local _lib_dir
        _lib_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd) || exit 1
        export TTBIN="$_lib_dir/bin/fmux"
    fi

    tt_test_seal_tmux

    # To pull the seal log out for inspection: run with TT_TMUX_STUB_KEEP=<dir> and it
    # leaves the full transcript of what the fake tmux received, per file (as verification
    # evidence). Nothing is kept by default.
    trap 'tt_test_keep_stub_log; rm -rf "$TTROOT"' EXIT
}

tt_test_keep_stub_log() {
    [ -n "${TT_TMUX_STUB_KEEP:-}" ] || return 0
    mkdir -p "$TT_TMUX_STUB_KEEP" 2>/dev/null || return 0
    local tag
    tag=$(basename "${0:-unknown}")
    cp "$TT_TMUX_STUB_LOG"     "$TT_TMUX_STUB_KEEP/$tag.calls"   2>/dev/null || true
    cp "$TT_TMUX_STUB_REFUSED" "$TT_TMUX_STUB_KEEP/$tag.refused" 2>/dev/null || true
}

# ── sealed fake tmux ────────────────────────────────────────────────────────
# Socket isolation alone (TMUX_TMPDIR + unset TMUX) wasn't enough. That only decides "which
# server does it attach to" — **the real tmux binary still runs**. So for two full rounds
# nobody could run `make check` — a suite that calls the real tmux can't be run on a machine
# with a live fleet on it. A harness that can't verify is a verification hole.
#
# So we plant a script named tmux at the front of PATH to seal the binary itself:
#   ① Every call is recorded, one line each, in TT_TMUX_STUB_LOG (evidence of what went out).
#   ② Read-only queries get the same answer as "no server on this machine" — rc 1 + one
#      stderr line. That matches what this suite actually saw before the seal existed (the
#      isolated TMUX_TMPDIR has no server), so it doesn't weaken any assertion.
#   ③ Subcommands that mutate state (new-session · kill-* · send-keys · source-file …) are
#      **refused** and logged separately to TT_TMUX_STUB_REFUSED. Tests check that file is
#      empty to confirm "did we almost touch someone else's server."
#   ④ Only -V gets a real-looking answer (the only read query the dependency check needs).
#
# Tests that need their own fake tmux (t-03 · t-11 · t-12) can stack their own ahead of this
# on PATH, or replace PATH outright, after this runs — the seal only guarantees "safe by default."
tt_test_seal_tmux() {
    TT_TMUX_STUB_DIR="$TTROOT/sealbin"
    TT_TMUX_STUB_LOG="$TTROOT/tmux-stub.log"
    TT_TMUX_STUB_REFUSED="$TTROOT/tmux-stub-refused.log"
    export TT_TMUX_STUB_DIR TT_TMUX_STUB_LOG TT_TMUX_STUB_REFUSED
    mkdir -p "$TT_TMUX_STUB_DIR" || exit 1
    : > "$TT_TMUX_STUB_LOG"
    : > "$TT_TMUX_STUB_REFUSED"
    cat > "$TT_TMUX_STUB_DIR/tmux" <<'TT_TMUX_STUB'
#!/usr/bin/env bash
# fake tmux for fleetmux tests — the real tmux never runs in this suite.
printf '%s\n' "$*" >> "${TT_TMUX_STUB_LOG:-/dev/null}"
case "${1:-}" in
    -V)
        printf 'tmux 3.5a\n'; exit 0 ;;
    ls|list-sessions|list-panes|list-windows|list-clients|list-keys|\
    display-message|display|capture-pane|show-options|show|show-environment|has-session)
        # read-only — same answer as a machine with no server. Changes nothing.
        printf 'no server running on %s/default\n' "${TMUX_TMPDIR:-/tmp}" >&2
        exit 1 ;;
esac
printf '%s\n' "$*" >> "${TT_TMUX_STUB_REFUSED:-/dev/null}"
printf 'fleetmux test stub: refused a state-mutating tmux subcommand: %s\n' "${1:-<none>}" >&2
exit 1
TT_TMUX_STUB
    chmod +x "$TT_TMUX_STUB_DIR/tmux" || exit 1
    PATH="$TT_TMUX_STUB_DIR:$PATH"
    export PATH
}

# Asserts the sealed fake tmux never received a state-mutating subcommand.
# (Tests that stack their own PATH don't use this log, so they check their own instead.)
assert_no_tmux_mutation() {
    TT_RUN=$((TT_RUN + 1))
    if [ ! -s "$TT_TMUX_STUB_REFUSED" ]; then
        printf '  ok   %s\n' "${1:-sealed fake tmux never received a state-mutating subcommand}"
    else
        TT_FAIL=$((TT_FAIL + 1))
        printf '  FAIL %s\n       refused log:\n%s\n' \
            "${1:-sealed fake tmux never received a state-mutating subcommand}" \
            "$(sed 's/^/         /' "$TT_TMUX_STUB_REFUSED")"
    fi
}

assert_eq() {
    TT_RUN=$((TT_RUN + 1))
    if [ "$1" = "$2" ]; then
        printf '  ok   %s\n' "$3"
    else
        TT_FAIL=$((TT_FAIL + 1))
        printf '  FAIL %s\n       expected: [%s]\n       actual:   [%s]\n' "$3" "$2" "$1"
    fi
}

assert_contains() {
    TT_RUN=$((TT_RUN + 1))
    case "$1" in
        *"$2"*) printf '  ok   %s\n' "$3" ;;
        *) TT_FAIL=$((TT_FAIL + 1))
           printf '  FAIL %s\n       [%s] does not contain [%s]\n' "$3" "$1" "$2" ;;
    esac
}

# rc check — wrapped so it doesn't die under set -e
assert_rc() {
    local want="$1"; shift
    local got=0
    "$@" >/dev/null 2>&1 || got=$?
    TT_RUN=$((TT_RUN + 1))
    if [ "$got" = "$want" ]; then
        printf '  ok   rc=%s  %s\n' "$want" "$1"
    else
        TT_FAIL=$((TT_FAIL + 1))
        printf '  FAIL rc  %s\n       expected: %s  actual: %s\n' "$*" "$want" "$got"
    fi
}

tt_test_done() {
    printf '  — %d of %d failed\n' "$TT_FAIL" "$TT_RUN"
    [ "$TT_FAIL" = 0 ]
}
