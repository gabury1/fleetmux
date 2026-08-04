#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
tt_test_sandbox

assert_eq "$(printf 'a')" "a" "assert_eq 가 같은 값을 통과시킨다"
assert_contains "hello world" "lo w" "assert_contains 가 조각을 찾는다"
assert_rc 0 true
assert_rc 1 false
# 샌드박스가 진짜 HOME 이 아니어야 한다
case "$HOME" in */fmux-test.*) printf '  ok   HOME 이 격리됐다\n' ;;
    *) printf '  FAIL HOME 이 격리되지 않았다: %s\n' "$HOME"; TT_FAIL=$((TT_FAIL+1)) ;;
esac

tt_test_done
