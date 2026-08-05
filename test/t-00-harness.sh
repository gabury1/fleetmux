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

# ── 봉인된 가짜 tmux ───────────────────────────────────────────────────────
# 소켓 격리는 "어느 서버냐"만 가른다. 진짜 tmux 바이너리가 실행되는 것 자체가 위험이라
# tt_test_sandbox 는 PATH 맨 앞에 가짜를 세운다. 여기서 그 봉인이 실제로 섰는지 잰다.
_which_tmux=$(command -v tmux 2>/dev/null || true)
case "$_which_tmux" in
    "$TT_TMUX_STUB_DIR/tmux") printf '  ok   PATH 의 tmux 가 봉인된 가짜다: %s\n' "$_which_tmux" ;;
    *) printf '  FAIL PATH 의 tmux 가 가짜가 아니다: %s\n' "$_which_tmux"; TT_FAIL=$((TT_FAIL+1)) ;;
esac

# 읽기 전용 질의: -V 만 답한다.
assert_eq "$(tmux -V 2>/dev/null)" "tmux 3.5a" "가짜가 -V 에는 답한다"
assert_rc 1 tmux ls
assert_contains "$(tmux ls 2>&1 >/dev/null)" "no server running" \
    "읽기 전용 질의는 서버 없는 기계와 같은 답을 한다"

# 상태를 바꾸는 하위명령은 전부 거부하고 로그에 남긴다.
# ⛔ 이 목록은 "가짜가 받았을 때 거부하는가"를 재는 것이지 진짜 tmux 를 부르는 게 아니다.
for sub in new-session kill-session kill-server send-keys source-file \
           switch-client attach rename-session set-hook bind detach-client run-shell; do
    assert_rc 1 tmux "$sub" -t nope
done
_refused=$(wc -l < "$TT_TMUX_STUB_REFUSED" | tr -d ' ')
assert_eq "$_refused" "12" "거부한 하위명령이 12건 전부 로그에 남았다"
assert_contains "$(cat "$TT_TMUX_STUB_REFUSED")" "kill-server" "거부 로그가 인자까지 받아 적는다"
assert_contains "$(cat "$TT_TMUX_STUB_LOG")" "kill-server -t nope" "전체 호출 로그에도 남는다"

# 그리고 그 로그를 근거로 삼는 헬퍼가 실제로 실패를 잡는지 — 지금은 12건이 들어 있으니
# assert_no_tmux_mutation 이 반드시 FAIL 을 내야 한다(이빨 확인).
_neg=$( ( TT_FAIL=0; assert_no_tmux_mutation "고의"; printf 'TT_FAIL=%s' "$TT_FAIL" ) )
case "$_neg" in
    *FAIL*TT_FAIL=1*) printf '  ok   assert_no_tmux_mutation 이 거부 로그를 실패로 잡는다\n' ;;
    *) printf '  FAIL assert_no_tmux_mutation 이 거부 로그를 못 잡았다: %s\n' "$_neg"; TT_FAIL=$((TT_FAIL+1)) ;;
esac
: > "$TT_TMUX_STUB_REFUSED"
assert_no_tmux_mutation "비운 뒤에는 통과한다"

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
