#!/usr/bin/env bash
# 팝업 안 설정 화면 — 백엔드 진입점과 --list 소비 지점의 가드.
#
# 이 테스트가 지켜야 하는 것:
#   ① --config-list 의 계약 — 키마다 한 줄, 현재값, 설명, 그리고 "미배선" 표시가 정직할 것.
#      (거짓말하는 토글을 주지 않는 게 이 표시의 목적이라, 배선된 키에 표시가 붙어도 실패다.)
#   ② --config-toggle 의 계약 — 불린은 rc 0 으로 뒤집고, 아니면 rc 2, 모르는 키는 rc 1.
#      rc 2 일 때 값이 안 바뀌는 것까지 재야 한다(호출자가 값을 입력받는 신호일 뿐이니까).
#   ③ --list 에 설정 행이 **없을 것** — 목록에 나가는 줄은 전부 진짜 tmux 세션이다.
#      (예전엔 맨 끝에 ⚙ 행을 하나 붙였다. 세션이 아닌 걸 세션 목록에 넣은 대가로 목록을
#       먹는 여섯 곳에 가드가 붙었고, 그중 빈 목록 부트스트랩 판정이 실제로 깨졌다.
#       그래서 단언을 지우지 않고 뒤집었다 — 이제 그 행이 있으면 실패다.)
#   ④ 그 가드들이 남아 있지 않을 것, 그리고 설정으로 가는 문(^O)은 그대로일 것.
#
# fzf 대화형 화면은 가짜 fzf 를 PATH 앞에 세워 잰다: 무엇이 fzf 에 들어갔고 몇 번 불렸는지를
# 파일로 받아 적는다. 진짜 키 입력은 흉내 못 내지만 "어느 화면으로 갔나"는 정확히 잴 수 있다.
set -u
. "$(dirname "$0")/lib.sh"
tt_test_sandbox

CONF="$XDG_CONFIG_HOME/fleetmux/config"
mkdir -p "$(dirname "$CONF")"
SENT='--settings--'
TAB=$'\t'
# ANSI 색을 벗기는 sed 스크립트. \x1b 는 GNU 확장이라 맥 기본 sed 에서 안 먹는다 —
# 셸이 미리 진짜 ESC 바이트로 바꿔 넘긴다.
TT_DEANSI=$'s/\033\\[[0-9;]*m//g'

# ── ⛔ PATH 가드 — 이 파일의 어떤 단언보다 먼저 선다 ────────────────────────
# 아래 ③이 진짜 `--list` 를 부른다. 가짜 tmux 를 PATH 앞에 세우는 코드가 그보다 뒤에 있으면
# 그 구간은 개발자 기계의 **진짜 tmux 서버**를 향해 나간다. 오늘은 tt_test_sandbox 의 이중
# 격리(TMUX_TMPDIR 교체 + unset TMUX)가 소켓을 못 찾게 막아 무해하지만, 그건 환경변수 하나가
# 새면 무너지는 방어다 — 이 저장소에서 실제로 kill-server 사고가 났던 계열이라 순서를 못박는다.
# (단언은 하나도 안 바뀌었다. 설치 위치만 위로 올렸다.)
#
# 이 가짜는 `tmux ls -F` 에만 답한다 — TT_FAKE_SESSIONS(줄바꿈으로 구분한 세션 이름 목록)를
# 그대로 세션 목록으로 내준다. 비었으면 "세션 0개"다. 나머지 하위명령은 전부 rc 1 —
# 서버 없는 기계와 같은 답이라 단언을 약하게 만들지 않는다.
mkdir -p "$TTROOT/bin"
cat > "$TTROOT/bin/tmux" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TT_TMUX_LOG"
case "$1 ${2:-}" in
    "ls -F")
        case "$3" in
            *session_created*)
                i=0
                while IFS= read -r s; do
                    [ -n "$s" ] || continue
                    i=$((i + 1))
                    printf '$%s\t1700000000\t0\t-\t%s\n' "$i" "$s"
                done <<< "${TT_FAKE_SESSIONS:-}"
                exit 0 ;;
        esac ;;
esac
exit 1
SHIM
chmod +x "$TTROOT/bin/tmux"
export TT_TMUX_LOG="$TTROOT/tmux-calls.log"
: > "$TT_TMUX_LOG"
REALPATH_SAVED="$PATH"
export PATH="$TTROOT/bin:$PATH"

# ── ① --config-list ────────────────────────────────────────────────────────
: > "$CONF"
out=$("$TTBIN" --config-list)
plain=$(printf '%s\n' "$out" | sed "$TT_DEANSI")

assert_eq "$(printf '%s\n' "$plain" | grep -c .)" "18" "알려진 키 18개가 전부 한 줄씩 나온다"
assert_contains "$plain" "rc${TAB}rc " "1번 필드는 키 이름이다"
assert_contains "$plain" "원격제어" "설명이 붙는다"

# 첫 필드는 fzf 가 감추고 우리가 잘라 쓰는 값 — 정확히 키여야 한다
first=$(printf '%s\n' "$out" | head -1); first=${first%%$'\t'*}
assert_eq "$first" "rc" "첫 줄의 탭 앞은 순수 키다"

# 현재값이 보인다 — 파일 값이 기본값을 이기는 것까지
printf 'accent=99\n' > "$CONF"
plain=$("$TTBIN" --config-list | sed "$TT_DEANSI")
assert_contains "$plain" "accent             99" "파일에 쓴 현재값이 목록에 보인다"
: > "$CONF"
plain=$("$TTBIN" --config-list | sed "$TT_DEANSI")
assert_contains "$plain" "rc                 on" "설정이 없으면 기본값이 보인다"

# ── ①-b "미배선" 표시가 정직한가 ───────────────────────────────────────────
# T4 가 물린 셋(rc·snapshot·boot_restore), T6 이 tmux 스니펫에 물린 셋
# (key_summon·key_summon_fast·snapshot_on_exit), T5 가 물린 넷(recent_hours·unseen_minutes·
# accent·log_max)에는 표시가 없어야 하고, 나머지엔 있어야 한다.
# 이 판정을 뒤집는 순간 설정 화면은 "끈 줄 알았는데 안 꺼진" 토글을 팔게 된다.
for k in rc snapshot boot_restore snapshot_on_exit key_summon key_summon_fast \
         recent_hours unseen_minutes accent log_max; do
    row=$(printf '%s\n' "$plain" | grep "^$k$TAB")
    case "$row" in *미배선*) got=yes ;; *) got=no ;; esac
    assert_eq "$got" "no" "$k 은 실제로 물려 있으니 미배선 표시가 없다"
done
for k in key_new key_settings; do
    row=$(printf '%s\n' "$plain" | grep "^$k$TAB")
    case "$row" in *미배선*) got=yes ;; *) got=no ;; esac
    assert_eq "$got" "yes" "$k 은 아직 안 물렸으니 미배선 표시가 붙는다"
done
# 배선 판정의 근거는 코드다 — tt_conf_wired 가 합쳐진 스크립트에서 "리터럴 키를 넘기는
# 조회 호출"을 직접 긁어 뽑는다. 그래서 새 키를 물리면 이 화면은 저절로 따라온다.
#   이 개수는 그 자동 판정의 **감시자**다: 단축키 재매핑(T7)이 여덟 키를 물리는 날
#   여기가 먼저 터져야 한다 — "물렸는데 표시가 안 바뀐"도, "안 물렸는데 표시가 사라진"도
#   둘 다 이 한 줄에 걸린다.
assert_eq "$(printf '%s\n' "$plain" | grep -vc 미배선)" "10" "지금 배선된 키는 정확히 10개다"

# ── ② --config-toggle ──────────────────────────────────────────────────────
: > "$CONF"
assert_rc 0 "$TTBIN" --config-toggle rc
assert_eq "$("$TTBIN" config get rc)" "off" "토글이 값을 뒤집는다"
assert_rc 0 "$TTBIN" --config-toggle rc
assert_eq "$("$TTBIN" config get rc)" "on" "다시 토글하면 돌아온다"
assert_contains "$(cat "$CONF")" "rc=on" "토글은 설정 파일에 남는다"

# 불린이 아닌 키는 rc 2 — "값을 입력받아라"는 신호다. 값은 절대 안 건드린다.
assert_rc 2 "$TTBIN" --config-toggle accent
assert_eq "$("$TTBIN" config get accent)" "73" "rc 2 일 때 값이 안 바뀐다"
assert_rc 2 "$TTBIN" --config-toggle key_new
case "$(cat "$CONF")" in *accent*|*key_new*) got=yes ;; *) got=no ;; esac
assert_eq "$got" "no" "rc 2 는 설정 파일에 아무것도 쓰지 않는다"

# 모르는 키·빈 키는 rc 1 이고 사유를 말한다
assert_rc 1 "$TTBIN" --config-toggle nope
assert_rc 1 "$TTBIN" --config-toggle
assert_contains "$("$TTBIN" --config-toggle nope 2>&1)" "모르는 키" "모르는 키면 그렇게 말한다"

# env 로 고정된 키를 토글하면 파일만 바뀌고 화면 값은 안 바뀐다 — 그 거짓말을 미리 막는다
out=$(TT_RC=on "$TTBIN" --config-toggle rc 2>&1) || rc=$?
assert_eq "${rc:-0}" "1" "env 가 이기는 키는 토글을 거절한다"
assert_contains "$out" "TT_RC" "거절 사유로 그 환경변수 이름을 말한다"

# log_max 는 예전엔 **항상** 이 거절에 걸렸다 — 10-util.sh 가 TT_LOG_MAX 전역을 스스로
# 세웠고 그 이름이 곧 이 키의 환경변수 이름이라, 진짜 환경변수가 없어도 늘 env 로 읽혔다.
# 임계값 배선(T5)이 그 전역을 없앴다. 이제는 다른 값 키와 똑같이 rc 2(값을 입력받아라)이고,
# 진짜 환경변수를 걸었을 때만 거절된다.
assert_rc 2 "$TTBIN" --config-toggle log_max
assert_rc 1 env TT_LOG_MAX=4096 "$TTBIN" --config-toggle log_max
assert_contains "$(TT_LOG_MAX=4096 "$TTBIN" --config-toggle log_max 2>&1)" "TT_LOG_MAX" \
    "진짜 환경변수가 걸렸을 때만 그 이름을 대며 거절한다"

# 진입점당 설정 파일은 한 번만 읽는다(05-config.sh:53 계약) — --config-list 는 키마다
# tt_conf_get/tt_conf_source 를 서브셸로 부르므로, 계약을 어기면 경고가 36번 나온다.
printf 'rc=on\nunknown_key=1\n' > "$CONF"
warn=$("$TTBIN" --config-list 2>&1 >/dev/null)
assert_eq "$(printf '%s\n' "$warn" | grep -c '모르는 키: unknown_key')" "1" \
    "--config-list 는 키를 36번 조회해도 경고는 한 번만"
warn=$("$TTBIN" --config-toggle rc 2>&1 >/dev/null)
assert_eq "$(printf '%s\n' "$warn" | grep -c '모르는 키: unknown_key')" "1" \
    "--config-toggle 도 경고는 한 번만"
: > "$CONF"

# ── ③ --list 에는 세션만 나간다 ────────────────────────────────────────────
# (가) 세션이 0개면 목록도 비어 있다. 예전엔 여기서 ⚙ 행 한 줄이 나갔고, 그래서 "목록이
#      비었나"로 하던 부트스트랩 판정이 통째로 깨졌다. 이제 빈 건 빈 거다.
list=$(TT_FAKE_SESSIONS="" "$TTBIN" --list 2>/dev/null) || true
assert_eq "$list" "" "세션이 0개면 --list 는 한 줄도 안 낸다"
case "$list" in *settings*) got=yes ;; *) got=no ;; esac
assert_eq "$got" "no" "설정 행이 목록에 없다"
case "$list" in *⚙*) got=yes ;; *) got=no ;; esac
assert_eq "$got" "no" "⚙ 로 칠한 행도 없다"

# (나) ★회귀 방지 — **목록의 모든 행이 실제 tmux 세션 이름이어야 한다.**
#   가짜 목록을 주입해 1번 필드를 하나씩 대조한다. 앞으로 누가 또 세션 아닌 행(설정·구분선·
#   광고 배너 무엇이든)을 흘리면 여기서 잡힌다 — 그 순간 목록을 먹는 여섯 곳에 가드가
#   필요해지고, 한 곳만 빠뜨리면 tt 가 없는 세션을 찾아 헤매기 때문이다.
#   일부러 어려운 이름을 섞는다 — 공백 든 이름이 한 행으로 온전한지도 같이 본다.
#   주입한 이름 중에 옛 센티넬은 넣지 않는다: 그 이름을 섞으면 되살아난 설정 행이 "주입한
#   세션"과 이름이 같아 대조를 통과해 버린다. 회귀는 이름 대조에서 잡혀야 한다.
FAKE=$'alpha\nbra vo\nzulu'
list=$(TT_FAKE_SESSIONS="$FAKE" "$TTBIN" --list 2>/dev/null) || true
bad=""
while IFS= read -r line; do
    [ -n "$line" ] || continue
    nm=${line%%$'\t'*}
    case $'\n'"$FAKE"$'\n' in
        *$'\n'"$nm"$'\n'*) ;;
        *) bad="$bad[$nm]" ;;
    esac
done <<< "$list"
assert_eq "$bad" "" "★--list 의 모든 행이 실제 tmux 세션 이름이다"
assert_eq "$(printf '%s\n' "$list" | grep -c .)" "3" "행 수도 세션 수와 정확히 같다 — 덤으로 붙는 줄이 없다"
assert_contains "$list" "bra vo" "공백 든 이름도 한 행으로 온전하다"

# (다) 옛 센티넬과 똑같은 이름의 **진짜 세션**도 그냥 한 행이다 — 예약어가 없어졌으니
#      특별대우도 없다. 예전엔 이 이름이 목록의 UI 행과 충돌해 tt 로 죽일 수도 개명할 수도
#      없는 세션이 됐다.
list=$(TT_FAKE_SESSIONS="$SENT" "$TTBIN" --list 2>/dev/null) || true
assert_eq "${list%%$'\t'*}" "$SENT" "그 이름의 세션도 1번 필드가 이름 그대로다"
assert_eq "$(printf '%s\n' "$list" | grep -c .)" "1" "그리고 딱 한 행이다"

# ── ④ 가드가 남아 있지 않다 ────────────────────────────────────────────────
# 옛 센티넬 문자열은 코드 어디에도 없어야 한다. 하나라도 남으면 "이건 세션이 아니다"라는
# 특례가 아직 살아 있다는 뜻이고, 그 특례가 붙은 자리마다 진짜 세션을 오판할 수 있다.
assert_eq "$(grep -c "TT_SETTINGS_ROW" "$TTBIN" || true)" "0" "센티넬 상수가 코드에 없다"
assert_eq "$(grep -c "tt_name_reserved" "$TTBIN" || true)" "0" "예약 이름 판정 함수도 없다"

# 프리뷰: 예전엔 이 이름을 받으면 tmux 대신 설정표를 그렸다. 이제는 그냥 세션 이름이라
# capture-pane 으로 나간다 — 특례가 사라졌다는 걸 가짜 tmux 로 잰다.
: > "$TT_TMUX_LOG"
out=$("$TTBIN" --preview "$SENT" 2>/dev/null) || true
case "$out" in *KEY*SOURCE*) got=yes ;; *) got=no ;; esac
assert_eq "$got" "no" "프리뷰는 더 이상 설정표를 그리지 않는다"
assert_contains "$(cat "$TT_TMUX_LOG")" "capture-pane" "그냥 그 이름의 세션 화면을 뜨러 간다"

# ── ④ 부트스트랩 — 세션 0개면 온보딩, 하나라도 있으면 피커 ─────────────────
# 이 판정이 가장 파괴적인 회귀 지점이었다(설정 행을 걸러내는 grep -v 가 여기 있었다).
# 진짜 팝업을 돌려서 잰다: 가짜 fzf 가 불렸으면 피커로 샜다는 뜻이고, 안 불렸으면
# 진짜 팝업을 돌려서 잰다: 가짜 fzf 가 불렸으면 피커로 샜다는 뜻이고, 안 불렸으면
# 부트스트랩으로 갔다는 뜻이다. 부트스트랩의 read 는 /dev/tty 를 여는데, setsid 로
# 제어 터미널을 떼면 그게 실패해 조용히 끝난다 — 사람이 make check 를 돌려도 안 멈춘다.
cat > "$TTROOT/bin/fzf" <<'SHIM'
#!/usr/bin/env bash
n=$(cat "$TT_FZF_DIR/count" 2>/dev/null || echo 0); n=$((n + 1))
printf '%s' "$n" > "$TT_FZF_DIR/count"
printf '%s\n' "$@" > "$TT_FZF_DIR/argv.$n"   # 바인딩·footer 도 받아 적는다(화면 배선의 증거)
cat > "$TT_FZF_DIR/in.$n"
# 1번째 호출에서만 고른 척한다 — 그래야 경로가 한 바퀴 돌고 멈춘다(무한 재진입 방지)
if [ "$n" = 1 ]; then
    case "${TT_FZF_PICK:-}" in
        multi) cat "$TT_FZF_DIR/in.$n" && exit 0 ;;   # Tab 으로 전부 찍은 척
    esac
fi
exit 130
SHIM
chmod +x "$TTROOT/bin/fzf"
export TT_FZF_DIR="$TTROOT/fzf"
mkdir -p "$TT_FZF_DIR"
printf 'snapshot=off\n' > "$CONF"     # 팝업이 백그라운드로 떼는 스냅샷을 조용히 시킨다

if command -v setsid >/dev/null 2>&1; then
    # (가) 세션 0개 — 목록이 통째로 비었다. 부트스트랩으로 가야 하고 fzf 로 새면 안 된다.
    rm -f "$TT_FZF_DIR/count"
    TT_FAKE_SESSIONS="" setsid "$TTBIN" --from "" </dev/null >/dev/null 2>&1 || true
    assert_eq "$(cat "$TT_FZF_DIR/count" 2>/dev/null || echo 0)" "0" \
        "세션이 0개면 부트스트랩으로 간다"

    # (나) 세션 1개 — 이제는 피커가 떠야 한다(판정이 과하게 걸러내지 않았다)
    rm -f "$TT_FZF_DIR/count"
    TT_FAKE_SESSIONS="fmuxcv1" setsid "$TTBIN" --from "" </dev/null >/dev/null 2>&1 || true
    assert_eq "$(cat "$TT_FZF_DIR/count" 2>/dev/null || echo 0)" "1" \
        "세션이 하나라도 있으면 피커가 뜬다"
    assert_contains "$(cat "$TT_FZF_DIR/in.1" 2>/dev/null || true)" "fmuxcv1" "그 피커에 세션이 들어 있다"
    case "$(cat "$TT_FZF_DIR/in.1" 2>/dev/null || true)" in *"$SENT"*) got=yes ;; *) got=no ;; esac
    assert_eq "$got" "no" "그 피커에 설정 행은 없다 — 세션만 들어간다"

    # (다) ★M2 — 살아 있는 세션이 딱 하나이고 그게 **지금 붙어 있는 세션**인 경우.
    #   80-view.sh 가 TT_CUR 을 목록에서 빼므로 --list 가 빈다. 판정을 "목록에 행이 있나"로
    #   하면 여기서 부트스트랩으로 새어 "no sessions yet" 온보딩이 뜬다 — 세션이 멀쩡히 있는데.
    #   기준은 "세션이 하나라도 있나"다: CUR 이 있으면 세션이 최소 하나이므로 피커를 띄운다.
    #   (예전에는 여기에 설정 행을 걸러내는 grep -v 가 있었고, 그게 이 판정을 깨뜨렸다.)
    rm -f "$TT_FZF_DIR/count" "$TT_FZF_DIR"/in.*    # in.* 도 지운다 — 앞 케이스의 잔존물로 통과하면 안 된다
    TT_FAKE_SESSIONS="" setsid "$TTBIN" --from "cur1" </dev/null >/dev/null 2>&1 || true
    assert_eq "$(cat "$TT_FZF_DIR/count" 2>/dev/null || echo 0)" "1" \
        "★붙어 있는 세션이 유일해 목록이 비어도 피커를 띄운다(부트스트랩으로 안 샌다)"
else
    printf '  --   setsid 없음 — 부트스트랩 판정은 건너뜀\n'
fi

# ── ⑤ 설정으로 가는 문은 ^O 하나 — 그 문이 실제로 열려 있다 ────────────────
# 목록에서 ⚙ 행을 뺐으니 발견성은 footer 가 갚는다. 바인딩과 footer 표기가 같은 값에서
# 나오는지(어긋나면 화면이 없는 키를 가르친다), 그리고 그 키가 설정 화면으로 가는지 잰다.
rm -f "$TT_FZF_DIR/count" "$TT_FZF_DIR"/in.* "$TT_FZF_DIR"/argv.*
TT_FAKE_SESSIONS="fmuxcv1" "$TTBIN" --from "" </dev/null >/dev/null 2>&1 || true
argv=$(cat "$TT_FZF_DIR/argv.1" 2>/dev/null || true)
assert_contains "$argv" "ctrl-o:execute" "^O 가 팝업에 실제로 바인딩된다"
assert_contains "$argv" "--config-view" "그 바인딩이 여는 것은 설정 화면이다"
assert_contains "$argv" "? help · ^O settings" "footer 가 그 키를 화면 아래에 적는다"

# 그리고 --config-view 는 여전히 설정 목록을 그린다(진입로만 줄었지 화면은 그대로다).
rm -f "$TT_FZF_DIR/count" "$TT_FZF_DIR"/in.*
"$TTBIN" --config-view </dev/null >/dev/null 2>&1 || true
in1=$(cat "$TT_FZF_DIR/in.1" 2>/dev/null || true)
assert_contains "$in1" "미배선" "^O 가 부르는 화면은 설정 목록이다"
assert_contains "$in1" "accent" "설정 목록에 키들이 들어 있다"
case "$in1" in *fmuxcv1*) got=yes ;; *) got=no ;; esac
assert_eq "$got" "no" "설정 화면에는 세션 목록이 섞이지 않는다"

# ── ⑥ Tab 다중선택 → 브로드캐스트 대상은 고른 세션 그대로다 ────────────────
# 예전엔 목록 맨 끝의 설정 행이 다른 세션과 함께 찍혀 들어와, 대상 수집 루프에서 또 한 번
# 걸러내야 했다. 이제 목록에 세션밖에 없으니 고른 것이 곧 대상이다 — 덤도 누락도 없어야 한다.
#   가짜 fzf 가 목록 전체를 고른 척하면 세션 2개 → count=2 → 브로드캐스트 경로다.
#   targets 줄이 stdout 으로 먼저 나오고 그 다음 프롬프트에서 멈춘다.
if command -v setsid >/dev/null 2>&1; then
    rm -f "$TT_FZF_DIR/count" "$TT_FZF_DIR"/in.*
    out=$(TT_FAKE_SESSIONS=$'fmuxcv1\nfmuxcv2' TT_FZF_PICK=multi \
        setsid "$TTBIN" --from "" </dev/null 2>/dev/null) || true
    assert_contains "$out" "targets: fmuxcv1 fmuxcv2" "고른 세션이 그대로 브로드캐스트 대상이다"
    case "$out" in *"$SENT"*|*settings*) got=yes ;; *) got=no ;; esac
    assert_eq "$got" "no" "대상 줄에 세션 아닌 것이 섞이지 않는다"
fi

# ── ⑦ 예약 이름은 이제 없다 — '--settings--' 도 그냥 세션 이름이다 ─────────
# 예전엔 이 이름이 예약어였다. 목록에 섞인 설정 행을 "1번 필드가 --settings-- 면 세션이
# 아니다"로 판정했으니, 진짜 세션이 그 이름을 가지면 가드가 전부 그 세션을 오판했기 때문이다
# (프리뷰는 설정표를 그리고 ^X·^E 는 거절해서, tt 로는 죽일 수도 개명할 수도 없는 세션이 생겼다).
# 설정 행이 사라지면서 그 오판의 근거도 사라졌다 — 그래서 단언을 지우지 않고 뒤집는다:
# 이름을 받는 문 셋(^N·^E·빈 목록 부트스트랩)이 이 이름을 **평범한 이름으로** 받아야 한다.
#
# 이 문 셋은 전부 /dev/tty 에서 읽는다(tt_prompt·read -rp) — 파이프로는 못 민다. 진짜 pty 를
# 붙여 흉내낸다. script 의 문법이 리눅스(util-linux)와 맥(BSD)이 달라 둘 다 시도하고,
# 어느 쪽도 안 되면 건너뛴다(setsid 와 같은 규율).
#   가드가 깨졌을 때 프롬프트가 다음 입력을 계속 기다리면 pty 가 안 닫혀 영영 멈춘다.
#   회귀가 make check 를 통째로 멎게 하는 건 실패로 떨어지는 것보다 나쁘다 — 그래서
#   ① 가드가 없을 때도 끝까지 흘러갈 만큼 입력을 넉넉히 먹이고 ② timeout 이 있으면 덧씌운다.
tt_pty() {                      # tt_pty <먹일입력> <명령문자열>
    local run="$2"
    command -v timeout >/dev/null 2>&1 && run="timeout 10 $run"
    if [ "${TT_PTY:-}" = util-linux ]; then
        printf '%s' "$1" | script -qec "$run" /dev/null 2>&1
    else
        printf '%s' "$1" | script -q /dev/null /usr/bin/env bash -c "$run" 2>&1
    fi
}
TT_PTY=""
if command -v script >/dev/null 2>&1; then
    if printf 'x\n' | script -qec 'read -r c </dev/tty' /dev/null >/dev/null 2>&1; then
        TT_PTY=util-linux
    elif printf 'x\n' | script -q /dev/null /usr/bin/env bash -c 'read -r c </dev/tty' >/dev/null 2>&1; then
        TT_PTY=bsd
    fi
fi

if [ -n "$TT_PTY" ]; then
    TTQ="'${TTBIN//\'/\'\\\'\'}'"

    # (가) ^N 으로 그 이름을 주면 거절 없이 그냥 만든다 — 두 줄을 먹인다(이름, 시작 명령).
    : > "$TT_TMUX_LOG"
    out=$(tt_pty "$SENT"$'\n\n' "$TTQ --do-new") || true
    case "$out" in *"예약 이름"*) got=yes ;; *) got=no ;; esac
    assert_eq "$got" "no" "^N 은 더 이상 이 이름을 예약어라며 거절하지 않는다"
    case "$(cat "$TT_TMUX_LOG")" in *"new-session -d -s $SENT"*) got=yes ;; *) got=no ;; esac
    assert_eq "$got" "yes" "그냥 그 이름의 세션을 만든다"

    # (나) 멀쩡한 이름도 물론 그대로다 — 반대편도 잰다
    : > "$TT_TMUX_LOG"
    tt_pty $'fmuxok1\n\n' "$TTQ --do-new" >/dev/null 2>&1 || true
    case "$(cat "$TT_TMUX_LOG")" in *"new-session -d -s fmuxok1"*) got=yes ;; *) got=no ;; esac
    assert_eq "$got" "yes" "멀쩡한 이름도 그대로 만들어진다"

    # (다) ^E 개명도 마찬가지 — 거절 없이 tmux 까지 간다
    : > "$TT_TMUX_LOG"
    out=$(tt_pty "$SENT"$'\n' "$TTQ --do-rename fmuxcv1") || true
    case "$out" in *"예약 이름"*) got=yes ;; *) got=no ;; esac
    assert_eq "$got" "no" "^E 도 이 이름을 거절하지 않는다"
    case "$(cat "$TT_TMUX_LOG")" in *"rename-session -t =fmuxcv1 $SENT"*) got=yes ;; *) got=no ;; esac
    assert_eq "$got" "yes" "개명이 tmux 까지 간다"

    # (라) ^X 로 그 이름의 세션을 집으면 "세션이 아니다"가 아니라 평소의 확인 프롬프트다.
    #      n 을 답해 실제 kill 까지는 가지 않는다 — 물어봤다는 사실만으로 특례 제거가 증명된다.
    : > "$TT_TMUX_LOG"
    out=$(tt_pty $'n\n' "$TTQ --do-kill $SENT") || true
    assert_contains "$out" "kill $SENT?" "^X 는 그 이름을 평범한 세션으로 보고 확인을 묻는다"
    case "$out" in *"세션이 아니다"*) got=yes ;; *) got=no ;; esac
    assert_eq "$got" "no" "'세션이 아니다' 라는 특례 문구는 사라졌다"
    case "$(cat "$TT_TMUX_LOG")" in *kill-session*) got=yes ;; *) got=no ;; esac
    assert_eq "$got" "no" "n 이라고 답했으니 kill 까지는 안 간다"

    # (마) 빈 목록 부트스트랩도 같은 문이다 — 첫 세션 이름을 여기서 받는다
    : > "$TT_TMUX_LOG"
    export TT_FAKE_SESSIONS=""      # 함수 호출 앞 대입은 자식에게 안 나갈 수 있다 — 명시적으로 내보낸다
    out=$(tt_pty "$SENT"$'\n' "$TTQ --from ''") || true
    case "$out" in *"예약 이름"*) got=yes ;; *) got=no ;; esac
    assert_eq "$got" "no" "부트스트랩도 거절하지 않는다"
    case "$(cat "$TT_TMUX_LOG")" in *"new-session -s $SENT"*) got=yes ;; *) got=no ;; esac
    assert_eq "$got" "yes" "받은 이름 그대로 첫 세션을 만든다"
else
    printf '  --   pty 를 붙일 script 가 없다 — 이 구간은 건너뜀\n'
fi

export PATH="$REALPATH_SAVED"
tt_test_done
