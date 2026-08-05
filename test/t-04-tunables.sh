#!/usr/bin/env bash
# 임계값·색 배선(T5) — 설정 네 키(recent_hours·unseen_minutes·accent·log_max)가 **실제로
# 동작을 바꾸는가**, 그리고 "미배선" 표시가 지금 배선 현황과 일치하는가.
#
# 이 파일이 지켜야 하는 것:
#   ① 네 키는 값을 바꾸면 출력이 바뀐다. "설정 파일에 저장됐다"는 조회로는 아무것도 증명
#      되지 않는다 — 저장은 되는데 아무도 안 읽는 상태가 정확히 이 태스크가 없앤 문제다.
#   ② 손으로 고친 설정 파일의 이상한 값이 관제탑을 죽이면 안 된다. 화이트리스트 파서는 값의
#      문자셋만 보므로 `recent_hours=6h`·`accent=999`·`08` 같은 값이 그대로 들어온다.
#      그 값이 $(( … )) 로 들어가면 산술 오류 + set -e 로 --list 가 통째로 죽는다.
#   ③ "미배선" 표시가 팝업과 CLI 양쪽에 있고, 둘의 판정이 같고, 실제 배선과 맞는다.
#
# tmux 는 한 번도 실행하지 않는다 — 가짜 tmux 를 PATH 앞에 세워 무엇이 오갔는지만 잰다.
set -u
. "$(dirname "$0")/lib.sh"
tt_test_sandbox

CONF="$XDG_CONFIG_HOME/fleetmux/config"
mkdir -p "$(dirname "$CONF")"
STATE="$HOME/.cache/tt"
mkdir -p "$STATE"
TAB=$'\t'
ESC=$'\033'

# ── ⛔ PATH 가드 — 이 파일의 어떤 단언보다 먼저 선다 ────────────────────────
# 아래에서 진짜 `--list`·`--status`·`--cron` 을 부른다. 가짜 tmux 를 세우는 코드가 그보다
# 뒤에 있으면 그 구간이 개발자 기계의 진짜 tmux 서버로 나간다(이 저장소에서 kill-server
# 사고가 났던 계열이라 순서를 못박는다).
mkdir -p "$TTROOT/bin"
cat > "$TTROOT/bin/tmux" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TT_TMUX_LOG"
case "${1:-}" in
    ls)              [ -n "${TT_FAKE_LS:-}" ] && printf '%s\n' "$TT_FAKE_LS"; exit 0 ;;
    list-panes)      printf '%s\n' "${TT_FAKE_PANE:-claude}"; exit 0 ;;
    display-message) [ -n "${TT_FAKE_DISP:-}" ] && printf '%s\n' "$TT_FAKE_DISP"; exit 0 ;;
esac
exit 1
SHIM
chmod +x "$TTROOT/bin/tmux"
export TT_TMUX_LOG="$TTROOT/tmux-calls.log"
: > "$TT_TMUX_LOG"
export PATH="$TTROOT/bin:$PATH"

now=$(date +%s)

# --list 한 행의 "표시 부분"(탭 뒤)을 준다. 색 코드는 벗기지 않는다 — 이 테스트가 재는 게
# 바로 그 색과 굵기다.
list_row() {
    "$TTBIN" --list 2>/dev/null | grep -a "^$1$TAB" || true
}

# ── ① accent — 강조색 256색 번호 ────────────────────────────────────────────
# --help 는 tmux 없이도 보이는 표면이라 색 배선의 가장 싼 증거다.
printf 'accent=200\n' > "$CONF"
assert_contains "$("$TTBIN" --help 2>/dev/null)" "$ESC[38;5;200m" "accent 가 --help 색에 반영된다"
: > "$CONF"
assert_contains "$("$TTBIN" --help 2>/dev/null)" "$ESC[38;5;73m" "기본 accent 도 그대로 동작한다"

# --list 의 도구 세션 줄도 같은 색을 쓴다(그쪽이 진짜 화면이다).
export TT_FAKE_LS="\$0${TAB}1000${TAB}0${TAB}-${TAB}alpha"
export TT_FAKE_PANE=bash          # claude 도 codex 도 아니다 → 도구 세션(그룹 0)
rm -f "$STATE/hook-0"
printf 'accent=200\n' > "$CONF"
assert_contains "$(list_row alpha)" "$ESC[38;5;200m" "accent 가 --list 도구 세션 색에 반영된다"

# 손으로 고친 범위 밖 값 — 이스케이프 시퀀스 안으로 들어가는 자리라 반드시 걸러야 한다.
printf 'accent=999\n' > "$CONF"
assert_contains "$("$TTBIN" --help 2>/dev/null)" "$ESC[38;5;73m" "범위 밖 accent 는 기본값으로 돌아간다"
assert_contains "$("$TTBIN" --help 2>&1 >/dev/null)" "accent" "그때 이유를 한 줄 말한다"
assert_rc 0 "$TTBIN" --help
# 앞의 0 은 8진수가 아니다 — 그냥 73 이어야 한다(bash 산술이었다면 여기서 죽는다).
printf 'accent=073\n' > "$CONF"
assert_contains "$("$TTBIN" --help 2>/dev/null)" "$ESC[38;5;73m" "앞자리 0 이 붙어도 10진수로 읽는다"

# ── ② recent_hours — 이름을 굵게 쓰는 기준 ──────────────────────────────────
# 에이전트 세션 하나를 세워 "2시간 전 대화" 상태로 만든다. 훅 파일의 pid 0 + 기록시각이
# 세션 생성시각보다 뒤 = 이 세션의 것으로 인정된다(tt_hook_valid ②).
export TT_FAKE_PANE=claude
printf 'idle %s 0\n' "$(( now - 7200 ))" > "$STATE/hook-0"

: > "$CONF"
row=$(list_row alpha)
case "$row" in *"$ESC[1m"*) got=bold ;; *"$ESC[2m"*) got=dim ;; *) got=none ;; esac
assert_eq "$got" "bold" "기본 recent_hours=6 이면 2시간 전 세션은 굵다"

printf 'recent_hours=1\n' > "$CONF"
row=$(list_row alpha)
case "$row" in *"$ESC[1m"*) got=bold ;; *"$ESC[2m"*) got=dim ;; *) got=none ;; esac
assert_eq "$got" "dim" "recent_hours=1 이면 같은 세션이 흐려진다"

printf 'recent_hours=3\n' > "$CONF"
row=$(list_row alpha)
case "$row" in *"$ESC[1m"*) got=bold ;; *"$ESC[2m"*) got=dim ;; *) got=none ;; esac
assert_eq "$got" "bold" "recent_hours=3 이면 다시 굵어진다 — 경계가 값을 따라 움직인다"

# 정수가 아닌 값은 기본값으로 접고 목록은 계속 뜬다(산술 오류로 죽지 않는다).
printf 'recent_hours=6h\n' > "$CONF"
row=$(list_row alpha)
case "$row" in *"$ESC[1m"*) got=bold ;; *"$ESC[2m"*) got=dim ;; *) got=none ;; esac
assert_eq "$got" "bold" "정수가 아닌 recent_hours 는 기본값 6 으로 접힌다"
assert_rc 0 "$TTBIN" --list
# 8진수 함정: `08` 은 문자셋 검사를 통과하지만 bash 산술에선 즉사한다.
printf 'recent_hours=08\n' > "$CONF"
assert_rc 0 "$TTBIN" --list
assert_contains "$(list_row alpha)" "$ESC[1m" "recent_hours=08 은 8시간으로 읽힌다"

# ── ③ unseen_minutes — 상태바 ✓ 유지 시간 ───────────────────────────────────
# finished 대장에 "6분 40초 전에 끝난 세션"을 하나 둔다. 세션은 살아 있고(=session_id 가
# 나온다) 아직 안 들어가봤다(last_attached=0 < ts) → 뱃지 조건은 오직 경과 시간뿐이다.
export TT_FAKE_DISP='$0|0'
fin_ts=$(( now - 400 ))
: > "$CONF"
printf '%s alpha\n' "$fin_ts" > "$STATE/finished"
assert_contains "$("$TTBIN" --status 2>/dev/null)" "✓alpha" "기본 unseen_minutes=10 이면 400초 전 완료는 아직 보인다"

printf 'unseen_minutes=5\n' > "$CONF"
printf '%s alpha\n' "$fin_ts" > "$STATE/finished"
out=$("$TTBIN" --status 2>/dev/null)
case "$out" in *✓alpha*) got=yes ;; *) got=no ;; esac
assert_eq "$got" "no" "unseen_minutes=5 면 400초 전 완료는 상태바에서 사라진다"
# 사라진 건 뱃지뿐 — 대장에는 남아야 한다(들어가볼 때까지 유지가 원래 계약이다).
assert_contains "$(cat "$STATE/finished")" "alpha" "뱃지가 꺼져도 finished 기록은 남는다"
rm -f "$STATE/finished"

# ── ④ log_max — 훅 로그 회전 임계 ───────────────────────────────────────────
# 회전은 --cron 이 부른다. rc·snapshot 을 꺼두면 그 진입점에서 tmux 로 나가는 길이 전부
# 닫혀, 이 단언은 회전 하나만 잰다.
mklog() { i=0; : > "$STATE/hook.log"; while [ "$i" -lt 300 ]; do printf 'line %s ----------\n' "$i" >> "$STATE/hook.log"; i=$((i + 1)); done; }

printf 'rc=off\nsnapshot=off\nlog_max=200\n' > "$CONF"
mklog
"$TTBIN" --cron >/dev/null 2>&1 || true
assert_contains "$(cat "$STATE/hook.log")" "rotated" "log_max=200 이면 로그가 회전한다"

printf 'rc=off\nsnapshot=off\n' > "$CONF"      # 기본 1MB
mklog
"$TTBIN" --cron >/dev/null 2>&1 || true
case "$(cat "$STATE/hook.log")" in *rotated*) got=yes ;; *) got=no ;; esac
assert_eq "$got" "no" "기본 log_max 면 같은 로그가 회전하지 않는다"

printf 'rc=off\nsnapshot=off\nlog_max=200\n' > "$CONF"
mklog
TT_LOG_MAX=1048576 "$TTBIN" --cron >/dev/null 2>&1 || true
case "$(cat "$STATE/hook.log")" in *rotated*) got=yes ;; *) got=no ;; esac
assert_eq "$got" "no" "TT_LOG_MAX 환경변수가 설정 파일을 이긴다"
rm -f "$STATE/hook.log"

# 그리고 그 하위호환의 대가였던 거짓말이 없어졌다 — 예전엔 10-util.sh 가 TT_LOG_MAX 전역을
# 스스로 세워서, 진짜 환경변수가 없는데도 출처가 늘 env 로 보였다(그래서 토글이 거절됐다).
printf 'log_max=4096\n' > "$CONF"
assert_eq "$("$TTBIN" config get log_max)" "4096" "log_max 를 설정 파일에서 읽는다"
assert_eq "$("$TTBIN" config source log_max)" "file" "출처도 file 이라고 말한다"
assert_eq "$(TT_LOG_MAX=999 "$TTBIN" config get log_max)" "999" "TT_LOG_MAX 환경변수가 이긴다"
assert_eq "$(TT_LOG_MAX=999 "$TTBIN" config source log_max)" "env" "그땐 출처가 env 다"

# ── ⑤ "미배선" 표시가 배선 현황과 일치하는가 ────────────────────────────────
: > "$CONF"
cli=$("$TTBIN" config list)

# 배선된 열 키 — T4(rc·snapshot·boot_restore) + T6(tmux 스니펫 셋) + T5(이 태스크의 넷).
# 이 목록이 늘어야 할 때 안 늘면 화면이 거짓말을 한다. 반대로 아직 안 문 키에 표시가
# 빠져도 거짓말이다 — 그래서 양쪽을 다 잰다.
for k in rc snapshot boot_restore snapshot_on_exit key_summon key_summon_fast \
         recent_hours unseen_minutes accent log_max; do
    row=$(printf '%s\n' "$cli" | grep -a "^$k ")
    case "$row" in *미배선*) got=yes ;; *) got=no ;; esac
    assert_eq "$got" "no" "config list: $k 은 물려 있으니 표시가 없다"
done
# 아직 안 물린 여덟 — 단축키 재매핑(T7)이 아직 없다.
for k in key_new key_rename key_kill key_reload key_detach key_broadcast key_help key_settings; do
    row=$(printf '%s\n' "$cli" | grep -a "^$k ")
    case "$row" in *미배선*) got=yes ;; *) got=no ;; esac
    assert_eq "$got" "yes" "config list: $k 은 아직 안 물렸으니 표시가 붙는다"
done
assert_eq "$(printf '%s\n' "$cli" | grep -c '← 미배선')" "8" "지금 미배선인 키는 정확히 여덟이다"
assert_contains "$cli" "값은 저장되지만" "표시가 무슨 뜻인지 표 밑에 한 줄로 설명한다"

# 값을 실제로 바꾸는 순간에도 말한다 — 목록을 안 보고 바로 set 하는 사람이 제일 잘 속는다.
: > "$CONF"
assert_contains "$("$TTBIN" config set key_new ctrl-y 2>&1)" "아직 아무 동작에도 안 물렸다" \
    "미배선 키를 set 하면 그 사실을 그 자리에서 말한다"
assert_eq "$("$TTBIN" config set key_new ctrl-y 2>/dev/null)" "key_new=ctrl-y" \
    "그 안내는 stderr 로만 간다 — stdout 의 key=value 는 그대로다"
out=$("$TTBIN" config set accent 200 2>&1)
case "$out" in *물렸다*) got=yes ;; *) got=no ;; esac
assert_eq "$got" "no" "배선된 키를 set 할 땐 아무 말도 덧붙이지 않는다"
: > "$CONF"

# 팝업 설정화면과 CLI 의 판정은 같은 함수에서 나온다 — 어느 한쪽만 보고 설정하는 사람이
# 다른 결론을 얻으면 안 된다. 키 이름을 손으로 적지 않고 두 출력을 맞대어 잰다.
pop=$("$TTBIN" --config-list)
mismatch=""
for k in $(printf '%s\n' "$cli" | sed -n '2,$p' | awk '{ print $1 }'); do
    case "$k" in ''|미배선*) continue ;; esac
    a=no; b=no
    case "$(printf '%s\n' "$cli" | grep -a "^$k ")" in *미배선*) a=yes ;; esac
    case "$(printf '%s\n' "$pop" | grep -a "^$k$TAB")" in *미배선*) b=yes ;; esac
    [ "$a" = "$b" ] || mismatch="$mismatch $k"
done
assert_eq "$mismatch" "" "CLI 와 팝업의 미배선 판정이 키마다 일치한다"

# 표시가 우연이 아니라 **코드에서 뽑은** 것인지, 그리고 근거를 못 얻었을 때의 처신.
# 스크립트를 stdin 으로 먹이면 자기 절대경로 해석이 bash 실행파일로 떨어져 스캔이 아무것도
# 못 찾는다 — 근거 0인 상황이 실제로 만들어진다. 그때는 아무 표시도 하지 않아야 한다:
# 전부 "미배선"으로 칠하는 쪽이 훨씬 큰 거짓말이다.
out=$(bash -s -- config list < "$TTBIN" 2>/dev/null) || out=''
case "$out" in *미배선*) got=yes ;; *) got=no ;; esac
assert_eq "$got" "no" "배선 근거를 못 얻으면 미배선 표시를 아예 안 붙인다"
assert_contains "$out" "key_new" "그래도 표 자체는 정상으로 나온다"

# ── ⑥ --help 첫 화면은 지금 이 기계의 설정을 말한다 (게이트 B7) ─────────────
# installer 가 마지막에 "tt --help 가 전부 설명한다"로 팀원을 보낸다 — 설치 직후 가장 먼저
# 읽는 화면이다. 예전엔 여기가 Option+← 와 6h/10 min 을 하드코딩했다. 기본값은 무prefix 키를
# 하나도 안 걸므로(key_summon_fast 가 빈 값) 그 첫 줄은 **없는 키를 가르치는 거짓말**이었다.
: > "$CONF"
h=$("$TTBIN" --help 2>/dev/null)
assert_eq "$(printf '%s' "$h" | grep -c 'Option+←' || true)" "0" "안 걸린 키를 가르치지 않는다"
assert_contains "$h" "prefix + F"          "기본 소환키를 설정에서 읽어 보여준다"
assert_contains "$h" "no prefix-less key"  "무prefix 키가 없으면 없다고 말한다"
assert_contains "$h" "key_summon_fast"     "켜는 방법을 그 자리에 적는다"
assert_contains "$h" "talked within 6h"    "기본 recent_hours 를 읽어 쓴다"
assert_contains "$h" "or 10 min"           "기본 unseen_minutes 를 읽어 쓴다"

printf 'key_summon=T\nkey_summon_fast=C-Left M-Left\nrecent_hours=3\nunseen_minutes=45\n' > "$CONF"
h=$("$TTBIN" --help 2>/dev/null)
assert_contains "$h" "prefix + T"      "바꾼 key_summon 이 화면에 나온다"
assert_contains "$h" "C-Left M-Left"   "바꾼 key_summon_fast 가 화면에 나온다"
assert_eq "$(printf '%s' "$h" | grep -c 'no prefix-less key' || true)" "0" "걸렸으면 없다고 안 한다"
assert_contains "$h" "talked within 3h" "바꾼 recent_hours 가 화면에 나온다"
assert_contains "$h" "or 45 min"        "바꾼 unseen_minutes 가 화면에 나온다"
assert_eq "$(printf '%s' "$h" | grep -c 'talked within 6h' || true)" "0" "옛 하드코딩 값이 남아 있지 않다"

# 소환키를 아예 다 비운 사람에게도 정직해야 한다
printf 'key_summon=\nkey_summon_fast=\n' > "$CONF"
h=$("$TTBIN" --help 2>/dev/null)
assert_contains "$h" "key_summon is empty" "prefix 키까지 비면 그 사실을 말한다"

tt_test_done
