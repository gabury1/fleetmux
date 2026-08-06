#!/usr/bin/env bash
# Runs every test/t-*.sh, each in its own process.
# If one file dies, the rest still run — so we see every failure in one pass.
set -u
cd "$(dirname "$0")/.." || exit 1
FMUXBIN="$PWD/bin/fmux"
[ -x "$FMUXBIN" ] || { echo "bin/fmux is missing — run make first"; exit 1; }
export FMUXBIN

fail=0
for t in test/t-*.sh; do
    [ -f "$t" ] || continue
    printf '%s\n' "$t"
    bash "$t" || fail=1
done
[ "$fail" = 0 ] && echo "all tests passed" || echo "some tests failed"
exit "$fail"
