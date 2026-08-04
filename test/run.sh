#!/usr/bin/env bash
# 모든 test/t-*.sh 를 각각 별도 프로세스로 돌린다.
# 한 파일이 죽어도 나머지는 돈다 — 실패를 한 번에 다 보기 위함.
set -u
cd "$(dirname "$0")/.." || exit 1
TTBIN="$PWD/bin/fmux"
[ -x "$TTBIN" ] || { echo "bin/fmux 가 없다 — 먼저 make 를 돌려라"; exit 1; }
export TTBIN

fail=0
for t in test/t-*.sh; do
    [ -f "$t" ] || continue
    printf '%s\n' "$t"
    bash "$t" || fail=1
done
[ "$fail" = 0 ] && echo "테스트 전부 통과" || echo "테스트 실패 있음"
exit "$fail"
