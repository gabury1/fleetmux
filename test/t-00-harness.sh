#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
tt_test_sandbox

assert_eq "$(printf 'a')" "a" "assert_eq 가 같은 값을 통과시킨다"
assert_contains "hello world" "lo w" "assert_contains 가 조각을 찾는다"
assert_rc 0 true
assert_rc 1 false

# assert_eq / assert_contains 의 실패 경로도 실제로 실패로 잡히는지 확인한다.
# 서브셸에서 돌려서 일부러 낸 실패가 이 파일의 진짜 TT_FAIL 을 오염시키지 않게 한다.
_neg=$( ( TT_FAIL=0; assert_eq "a" "b" "고의 불일치"; printf 'TT_FAIL=%s' "$TT_FAIL" ) )
case "$_neg" in
    *FAIL*TT_FAIL=1*) printf '  ok   assert_eq 가 다른 값을 실패로 잡는다\n' ;;
    *) printf '  FAIL assert_eq 가 다른 값을 실패로 잡지 못했다: %s\n' "$_neg"; TT_FAIL=$((TT_FAIL+1)) ;;
esac

_neg=$( ( TT_FAIL=0; assert_contains "hello world" "zzz" "고의 불일치"; printf 'TT_FAIL=%s' "$TT_FAIL" ) )
case "$_neg" in
    *FAIL*TT_FAIL=1*) printf '  ok   assert_contains 가 없는 조각을 실패로 잡는다\n' ;;
    *) printf '  FAIL assert_contains 가 없는 조각을 실패로 잡지 못했다: %s\n' "$_neg"; TT_FAIL=$((TT_FAIL+1)) ;;
esac

# 샌드박스가 진짜 HOME 이 아니어야 한다
case "$HOME" in */fmux-test.*) printf '  ok   HOME 이 격리됐다\n' ;;
    *) printf '  FAIL HOME 이 격리되지 않았다: %s\n' "$HOME"; TT_FAIL=$((TT_FAIL+1)) ;;
esac

# tmux 소켓 격리 — $TMUX 가 세팅돼 있으면 bare `tmux` 호출이 TMUX_TMPDIR 을
# 무시하고 진짜 서버로 붙어버린다. tt_test_sandbox 가 지웠는지 확인한다.
if [ -z "${TMUX:-}" ]; then
    printf '  ok   TMUX 가 격리됐다(unset)\n'
else
    printf '  FAIL TMUX 가 여전히 세팅돼 있다: %s\n' "$TMUX"; TT_FAIL=$((TT_FAIL+1))
fi

# tt_test_sandbox 가 TTBIN 을 세팅해야 한다(브리핑 Interfaces 계약) — run.sh 를
# 거치지 않고 이 파일을 단독으로 `bash test/t-00-harness.sh` 실행해도 성립해야 한다.
case "${TTBIN:-}" in
    */bin/fmux) printf '  ok   TTBIN 이 세팅됐다: %s\n' "$TTBIN" ;;
    *) printf '  FAIL TTBIN 이 세팅되지 않았다: %s\n' "${TTBIN:-}"; TT_FAIL=$((TT_FAIL+1)) ;;
esac

# 같은 프로세스에서 두 번째로 부르면 거부해야 한다(첫 TTROOT 가 새지 않도록).
if ( tt_test_sandbox ) >/dev/null 2>&1; then
    printf '  FAIL tt_test_sandbox 재호출이 거부되지 않았다\n'; TT_FAIL=$((TT_FAIL+1))
else
    printf '  ok   tt_test_sandbox 재호출이 거부된다\n'
fi

tt_test_done
