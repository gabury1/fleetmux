#!/usr/bin/env bash
# 팝업 안 설정 화면 — 백엔드 진입점과 --list 소비 지점의 가드.
#
# 이 테스트가 지켜야 하는 것:
#   ① --config-list 의 계약 — 키마다 한 줄, 현재값, 설명, 그리고 "미배선" 표시가 정직할 것.
#      (거짓말하는 토글을 주지 않는 게 이 표시의 목적이라, 배선된 키에 표시가 붙어도 실패다.)
#   ② --config-toggle 의 계약 — 불린은 rc 0 으로 뒤집고, 아니면 rc 2, 모르는 키는 rc 1.
#      rc 2 일 때 값이 안 바뀌는 것까지 재야 한다(호출자가 값을 입력받는 신호일 뿐이니까).
#   ③ --list 맨 끝에 ⚙ 행이 붙을 것 — 세션이 0개일 때도.
#   ④ 그 행을 먹는 곳들의 가드가 실제로 도는 것 — 프리뷰·브로드캐스트·빈 목록 판정.
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
mkdir -p "$TTROOT/bin"
cat > "$TTROOT/bin/tmux" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TT_TMUX_LOG"
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
# T4 가 물린 세 키(rc·snapshot·boot_restore)에는 표시가 없어야 하고, 나머지엔 있어야 한다.
# 이 판정을 뒤집는 순간 설정 화면은 "끈 줄 알았는데 안 꺼진" 토글을 팔게 된다.
for k in rc snapshot boot_restore; do
    row=$(printf '%s\n' "$plain" | grep "^$k$TAB")
    case "$row" in *미배선*) got=yes ;; *) got=no ;; esac
    assert_eq "$got" "no" "$k 은 실제로 물려 있으니 미배선 표시가 없다"
done
for k in snapshot_on_exit recent_hours unseen_minutes accent log_max key_new key_settings key_summon; do
    row=$(printf '%s\n' "$plain" | grep "^$k$TAB")
    case "$row" in *미배선*) got=yes ;; *) got=no ;; esac
    assert_eq "$got" "yes" "$k 은 아직 안 물렸으니 미배선 표시가 붙는다"
done
# 배선 판정의 근거는 코드다 — tt_conf_on 을 실제로 부르는 키만 배선된 것으로 친다.
# 이 개수가 늘면 tt_conf_wired 도 같이 늘어야 한다는 뜻이다.
assert_eq "$(printf '%s\n' "$plain" | grep -vc 미배선)" "3" "지금 배선된 키는 정확히 3개다"

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

# log_max 는 지금 항상 이 거절에 걸린다 — 10-util.sh:21 이 TT_LOG_MAX 를 스스로 세워서,
# 설정 파일에 쓴 값이 실제로 안 먹기 때문이다. rc 2 로 값을 받아 저장해봐야 거짓말이 된다.
# 임계값 배선(10-util.sh 를 tt_conf_get 경유로)이 들어오면 이 줄이 rc 2 로 바뀌어야 한다.
assert_rc 1 "$TTBIN" --config-toggle log_max
assert_contains "$("$TTBIN" --config-toggle log_max 2>&1)" "TT_LOG_MAX" \
    "log_max 는 아직 파일로 못 바꾼다는 사실을 그대로 말한다"

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

# ── ③ --list 맨 끝의 ⚙ 행 ─────────────────────────────────────────────────
# 이 샌드박스엔 tmux 서버가 없다 → 세션 0개. 그래도 설정 행은 나와야 한다.
# 세션이 0개일 때야말로 설정으로 갈 문이 필요하기 때문이다.
list=$("$TTBIN" --list 2>/dev/null) || true
assert_contains "$list" "settings" "세션 목록 끝에 settings 항목이 있다"
assert_eq "${list%%$'\t'*}" "$SENT" "설정 행의 1번 필드는 ASCII 센티넬이다"
assert_contains "$list" "⚙" "사람에게 보이는 쪽은 ⚙ 로 칠해진다"
assert_eq "$(printf '%s\n' "$list" | grep -c .)" "1" "세션이 없으면 설정 행 딱 한 줄"

# ── ④ 가드 — 프리뷰 ────────────────────────────────────────────────────────
# 설정 행 위에 커서가 얹히면 tmux 화면 대신 지금 설정을 보여준다.
out=$("$TTBIN" --preview "$SENT" 2>/dev/null)
assert_contains "$out" "KEY" "프리뷰가 설정 행을 받으면 설정표를 그린다"
assert_contains "$out" "rc" "프리뷰에 키가 들어 있다"
assert_contains "$out" "SOURCE" "값이 어디서 왔는지도 같이 보여준다"

# ── ④ 가드 — 브로드캐스트 ──────────────────────────────────────────────────
# 설정 행만 찍고 ^B: 보낼 데가 없으니 프롬프트조차 묻지 않고 조용히 끝난다.
# (묻고 나서 안 보내면 사용자는 자기 프롬프트가 어디론가 갔다고 믿는다.)
out=$("$TTBIN" --do-broadcast "$SENT" 2>/dev/null) || true
assert_eq "$out" "" "설정 행만 찍힌 ^B 는 아무 말 없이 끝난다"
assert_rc 0 "$TTBIN" --do-broadcast "$SENT"
# 그리고 그 사이 tmux 를 한 번도 부르지 않는다 — 가짜 tmux 로 잰다(설치는 파일 맨 위에서 끝냈다).
: > "$TT_TMUX_LOG"
"$TTBIN" --do-broadcast "$SENT" >/dev/null 2>&1 || true
assert_eq "$(cat "$TT_TMUX_LOG")" "" "설정 행 브로드캐스트는 tmux 를 부르지 않는다"
: > "$TT_TMUX_LOG"
"$TTBIN" --preview "$SENT" >/dev/null 2>&1 || true
assert_eq "$(cat "$TT_TMUX_LOG")" "" "설정 행 프리뷰도 tmux 를 부르지 않는다"

# ^E/^X 로 설정 행을 집어도 세션 조작으로 새지 않는다
: > "$TT_TMUX_LOG"
out=$("$TTBIN" --do-kill "$SENT" 2>&1) || true
assert_contains "$out" "세션이 아니다" "^X 는 설정 행을 죽이려 들지 않는다"
out=$("$TTBIN" --do-rename "$SENT" 2>&1) || true
assert_contains "$out" "세션이 아니다" "^E 는 설정 행을 개명하려 들지 않는다"
assert_eq "$(cat "$TT_TMUX_LOG")" "" "둘 다 tmux 를 부르지 않는다"

# ── ④ 가드 — 빈 목록 부트스트랩 ────────────────────────────────────────────
# 설정 행이 무조건 한 줄 붙으니 --list 는 절대 비지 않는다. 판정에서 그 행을 빼지 않으면
# "세션이 0개면 하나 만들어 들어간다"는 온보딩이 영영 안 돈다 — 가장 파괴적인 회귀다.
# 진짜 팝업을 돌려서 잰다: 가짜 fzf 가 불렸으면 피커로 샜다는 뜻이고, 안 불렸으면
# 부트스트랩으로 갔다는 뜻이다. 부트스트랩의 read 는 /dev/tty 를 여는데, setsid 로
# 제어 터미널을 떼면 그게 실패해 조용히 끝난다 — 사람이 make check 를 돌려도 안 멈춘다.
cat > "$TTROOT/bin/fzf" <<'SHIM'
#!/usr/bin/env bash
n=$(cat "$TT_FZF_DIR/count" 2>/dev/null || echo 0); n=$((n + 1))
printf '%s' "$n" > "$TT_FZF_DIR/count"
cat > "$TT_FZF_DIR/in.$n"
# 1번째 호출에서만 고른 척한다 — 그래야 경로가 한 바퀴 돌고 멈춘다(무한 재진입 방지)
if [ "$n" = 1 ]; then
    case "${TT_FZF_PICK:-}" in
        settings) grep '^--settings--' "$TT_FZF_DIR/in.$n" && exit 0 ;;
        multi)    cat "$TT_FZF_DIR/in.$n" && exit 0 ;;   # Tab 으로 전부 찍은 척
    esac
fi
exit 130
SHIM
chmod +x "$TTROOT/bin/fzf"
export TT_FZF_DIR="$TTROOT/fzf"
mkdir -p "$TT_FZF_DIR"

# 세션이 있는 것처럼 보이는 가짜 tmux — --list 의 ls 포맷에만 답한다
cat > "$TTROOT/bin/tmux" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TT_TMUX_LOG"
case "$1 ${2:-}" in
    "ls -F")
        case "$3" in
            *session_created*) [ -n "${TT_FAKE_SESSION:-}" ] && printf '$1\t1700000000\t0\t-\t%s\n' "$TT_FAKE_SESSION"; exit 0 ;;
        esac ;;
esac
exit 1
SHIM
chmod +x "$TTROOT/bin/tmux"
printf 'snapshot=off\n' > "$CONF"     # 팝업이 백그라운드로 떼는 스냅샷을 조용히 시킨다

if command -v setsid >/dev/null 2>&1; then
    # (가) 세션 0개 — 설정 행뿐이다. fzf 로 새면 안 된다.
    rm -f "$TT_FZF_DIR/count"
    TT_FAKE_SESSION="" setsid "$TTBIN" --from "" </dev/null >/dev/null 2>&1 || true
    assert_eq "$(cat "$TT_FZF_DIR/count" 2>/dev/null || echo 0)" "0" \
        "세션이 0개면 설정 행이 있어도 부트스트랩으로 간다"

    # (나) 세션 1개 — 이제는 피커가 떠야 한다(가드가 과하게 걸러내지 않았다)
    rm -f "$TT_FZF_DIR/count"
    TT_FAKE_SESSION="fmuxcv1" setsid "$TTBIN" --from "" </dev/null >/dev/null 2>&1 || true
    assert_eq "$(cat "$TT_FZF_DIR/count" 2>/dev/null || echo 0)" "1" \
        "세션이 하나라도 있으면 피커가 뜬다"
    assert_contains "$(cat "$TT_FZF_DIR/in.1" 2>/dev/null || true)" "fmuxcv1" "그 피커에 세션이 들어 있다"
    assert_contains "$(cat "$TT_FZF_DIR/in.1" 2>/dev/null || true)" "$SENT" "그리고 설정 행도 같이 들어 있다"

    # (다) ★M2 — 살아 있는 세션이 딱 하나이고 그게 **지금 붙어 있는 세션**인 경우.
    #   80-view.sh 가 TT_CUR 을 목록에서 빼므로 --list 에는 설정 행만 남는다. 판정을
    #   "행이 있나"로 하면 여기서 부트스트랩으로 새어 "no sessions yet" 온보딩이 뜬다 —
    #   세션이 멀쩡히 있는데. maintainer가 세션 하나만 켠 채 ^O 로 설정 화면을 보러 갈 때의
    #   경로가 정확히 이것이라, 설정으로 갈 문이 하필 그때 사라진다.
    #   기준은 "세션이 하나라도 있나"다: CUR 이 있으면 세션이 최소 하나이므로 피커를 띄운다.
    rm -f "$TT_FZF_DIR/count" "$TT_FZF_DIR"/in.*    # in.* 도 지운다 — 앞 케이스의 잔존물로 통과하면 안 된다
    TT_FAKE_SESSION="" setsid "$TTBIN" --from "cur1" </dev/null >/dev/null 2>&1 || true
    assert_eq "$(cat "$TT_FZF_DIR/count" 2>/dev/null || echo 0)" "1" \
        "★붙어 있는 세션이 유일해 목록이 설정 행뿐이어도 피커를 띄운다(부트스트랩으로 안 샌다)"
    assert_contains "$(cat "$TT_FZF_DIR/in.1" 2>/dev/null || true)" "$SENT" \
        "그 피커에는 설정 행이 들어 있다 — 설정으로 갈 문이 남는다"
else
    printf '  --   setsid 없음 — 부트스트랩 판정은 건너뜀\n'
fi

# ── ⑤ 설정 행을 고르면 설정 화면으로 간다 ──────────────────────────────────
# 가짜 fzf 가 1번째 호출에서 설정 행을 고른 척한다. 그러면
#   1) 팝업  2) 설정 화면(--config-view 가 다시 fzf 를 부른다)  3) exec 로 돌아온 팝업
# 이 순서로 fzf 가 세 번 불려야 한다. 2번째로 들어간 stdin 이 설정 목록이면 배선이 맞다.
if command -v setsid >/dev/null 2>&1; then
    rm -f "$TT_FZF_DIR/count" "$TT_FZF_DIR"/in.*
    TT_FAKE_SESSION="fmuxcv1" TT_FZF_PICK=settings \
        setsid "$TTBIN" --from "" </dev/null >/dev/null 2>&1 || true
    assert_eq "$(cat "$TT_FZF_DIR/count" 2>/dev/null || echo 0)" "3" \
        "설정 행 선택 → 설정 화면 → 목록 복귀로 fzf 가 세 번 뜬다"
    in2=$(cat "$TT_FZF_DIR/in.2" 2>/dev/null || true)
    assert_contains "$in2" "미배선" "두 번째 화면은 설정 목록이다"
    assert_contains "$in2" "accent" "설정 목록에 키들이 들어 있다"
    case "$in2" in *"$SENT"*) got=yes ;; *) got=no ;; esac
    assert_eq "$got" "no" "설정 화면에는 세션 목록이 섞이지 않는다"
fi

# ── ⑥ Tab 다중선택에 설정 행이 섞여 들어와도 대상에서 빠진다 ────────────────
# 첫 줄 검사(⑤)로는 못 잡는 경우다: 설정 행은 목록 맨 끝이라 다른 세션과 함께 찍히면
# 첫 줄이 세션이라 그냥 지나가고, 대상 수집 루프까지 흘러간다. 거기 가드가 실제로 도는지 잰다.
#   가짜 fzf 가 목록 전체를 고른 척하면 --list 는 "세션 1개 + 설정 행" 이므로 count=2 →
#   브로드캐스트 경로다. targets 줄이 stdout 으로 먼저 나오고 그 다음 프롬프트에서 멈춘다.
if command -v setsid >/dev/null 2>&1; then
    rm -f "$TT_FZF_DIR/count" "$TT_FZF_DIR"/in.*
    out=$(TT_FAKE_SESSION="fmuxcv1" TT_FZF_PICK=multi \
        setsid "$TTBIN" --from "" </dev/null 2>/dev/null) || true
    assert_contains "$out" "targets: fmuxcv1" "다중선택 브로드캐스트 대상에 세션은 들어간다"
    case "$out" in *"$SENT"*) got=yes ;; *) got=no ;; esac
    assert_eq "$got" "no" "설정 행은 브로드캐스트 대상에서 빠진다"
fi

# ── ⑦ 센티넬은 예약 이름이다 — 세션을 만드는 문에서 미리 막는다 ────────────
# 위 ④ 가드들은 "1번 필드가 --settings-- 면 세션이 아니다"로 판정한다. 그래서 진짜 세션이
# 그 이름을 가지면 가드가 전부 그 세션을 오판한다 — 프리뷰는 설정표를 그리고 ^X·^E 는
# "세션이 아니다"라며 거절해, tt 로는 죽일 수도 개명할 수도 없는 세션이 하나 생긴다.
# 그래서 이름을 받는 문 셋(^N·^E·빈 목록 부트스트랩)에서 예약어를 막는다.
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

    # (가) ^N 으로 예약어를 새 세션 이름으로 주면 거절하고 tmux 를 부르지 않는다
    #      빈 줄을 하나 더 먹인다 — 가드가 깨졌을 때 뒤따르는 "시작 명령" 프롬프트가
    #      입력을 기다리며 멈추지 않고 끝까지 흘러가 실패로 잡히게 하려는 것이다.
    : > "$TT_TMUX_LOG"
    out=$(tt_pty "$SENT"$'\n\n' "$TTQ --do-new") || true
    assert_contains "$out" "예약 이름" "^N 은 예약 이름으로 세션을 만들지 않는다"
    case "$(cat "$TT_TMUX_LOG")" in *new-session*) got=yes ;; *) got=no ;; esac
    assert_eq "$got" "no" "거절했으니 tmux new-session 까지 가지 않는다"

    # (나) 그렇다고 멀쩡한 이름까지 막으면 안 된다 — 가드가 과한지 반대편도 잰다
    #      두 줄을 먹인다: 이름, 그리고 시작 명령(빈 줄 = 그냥 셸).
    : > "$TT_TMUX_LOG"
    tt_pty $'fmuxok1\n\n' "$TTQ --do-new" >/dev/null 2>&1 || true
    case "$(cat "$TT_TMUX_LOG")" in *"new-session -d -s fmuxok1"*) got=yes ;; *) got=no ;; esac
    assert_eq "$got" "yes" "멀쩡한 이름은 그대로 만들어진다"

    # (다) ^E 로 예약어로 개명하는 것도 막는다 — 개명은 살아 있는 세션을 삼키는 경로다
    : > "$TT_TMUX_LOG"
    out=$(tt_pty "$SENT"$'\n' "$TTQ --do-rename fmuxcv1") || true
    assert_contains "$out" "예약 이름" "^E 는 예약 이름으로 개명하지 않는다"
    case "$(cat "$TT_TMUX_LOG")" in *rename-session*) got=yes ;; *) got=no ;; esac
    assert_eq "$got" "no" "거절했으니 tmux rename-session 까지 가지 않는다"

    # (라) 빈 목록 부트스트랩도 같은 문이다 — 첫 세션 이름을 여기서 받는다
    : > "$TT_TMUX_LOG"
    out=$(TT_FAKE_SESSION="" tt_pty "$SENT"$'\n' "$TTQ --from ''") || true
    assert_contains "$out" "예약 이름" "부트스트랩도 예약 이름을 거절한다"
    case "$(cat "$TT_TMUX_LOG")" in *new-session*) got=yes ;; *) got=no ;; esac
    assert_eq "$got" "no" "그 자리에서 멈추고 세션을 만들지 않는다"
else
    printf '  --   pty 를 붙일 script 가 없다 — 예약 이름 가드는 건너뜀\n'
fi

export PATH="$REALPATH_SAVED"
tt_test_done
