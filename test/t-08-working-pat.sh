#!/usr/bin/env bash
# WORKING_PAT — "이 세션 지금 도는 중인가"를 화면 한 줄로 가르는 판정의 가드.
#
# 왜 이 테스트가 있나: 2026-08-05, device-refactor 가 실제로 사고 중인데 목록에 ✻ 가 안 떴다.
# 80-view.sh 의 박제 방지 가드가 "훅 갱신 20초 끊김 + 화면 판정 실패" 로 ✻ 를 지웠는데,
# 도구를 안 쓰는 긴 사고 턴에서는 훅 갱신이 끊기는 게 정상이라 2차 근거인 이 패턴이
# 유일한 방어선이었다. 그게 뚫렸다. 그래서 여기서 재는 것은 두 방향 전부다:
#   ① 미탐 — 진짜 도는 화면을 놓치면 ✻ 가 사라진다(원래 버그).
#   ② 오탐 — 노는 화면을 잡으면 함대가 노는 걸 일하는 것으로 보이게 한다(더 조용하고 더 나쁘다).
#      특히 이 저장소 문서·fmux 자기 TUI 가 pane 에 떠 있는 경우가 실제 사고 경로였다.
#
# 판정 대상은 빌드 산출물(bin/fmux)에서 뽑아낸 진짜 패턴·진짜 함수다 — src 를 따로 읽으면
# "고쳤는데 안 빌드한" 상태를 통과시킨다.
#
# ⛔ 이 테스트는 tmux 를 부르지 않는다. 화면은 전부 test/fixtures/screen 의 실캡처 파일이다.
set -u
. "$(dirname "$0")/lib.sh"
tt_test_sandbox

TESTDIR=$(cd "$(dirname "$0")" && pwd) || exit 1
FIX="$TESTDIR/fixtures/screen"

# ── 산출물에서 판정부만 떼어온다 ─────────────────────────────────────────────
# bin/fmux 는 통째로 source 하면 진입점(fzf 팝업)까지 돈다. 필요한 두 조각만 뽑아 eval 한다.
eval "$(sed -n '/^WORKING_PAT=/{p;q;}' "$TTBIN")"
eval "$(awk '/^tt_working\(\) \{/ { f = 1 } f { print } f && /^\}/ { exit }' "$TTBIN")"

assert_rc 0 test -n "${WORKING_PAT:-}"
TT_RUN=$((TT_RUN + 1))
if [ "$(type -t tt_working 2>/dev/null)" = function ]; then
    printf '  ok   bin/fmux 에서 tt_working 을 떼어왔다\n'
else
    TT_FAIL=$((TT_FAIL + 1))
    printf '  FAIL bin/fmux 에서 tt_working 을 못 떼어왔다 — 추출 awk 가 함수 모양을 못 따라간다\n'
fi

# ── 구조 가드 ────────────────────────────────────────────────────────────────
# (가) 멀티바이트를 브래킷에 넣지 마라. `[✻✶…]` 는 C 로케일에서 문자 집합이 아니라 바이트 집합으로
#      붕괴한다 — ✻ 의 세 바이트 중 하나만 스쳐도 통과하는 식이라 BSD grep 에서 무엇이 걸릴지 모른다.
#      리터럴 교대 `(✻|✶|…)` 만 로케일·구현과 무관하게 문자 단위로 확정된다.
for bad in '[✻' '[↑' '[↓' '[·'; do
    case "$WORKING_PAT" in
        *"$bad"*) got=yes ;; *) got=no ;;
    esac
    assert_eq "$got" "no" "멀티바이트를 브래킷 '$bad' 로 쓰지 않는다(C 로케일에서 바이트 집합으로 붕괴)"
done
# (나) ERE 밖 문법 금지 — 맥 기본 grep 은 BSD 다. 여기 걸리면 맥에서 판정이 통째로 죽는다.
for bad in '\d' '\s' '\b' '\w' '(?:' '(?='; do
    case "$WORKING_PAT" in
        *"$bad"*) got=yes ;; *) got=no ;;
    esac
    assert_eq "$got" "no" "PCRE/GNU 확장 '$bad' 를 쓰지 않는다(BSD grep 이식성)"
done

# ── 케이스 판정 헬퍼 ─────────────────────────────────────────────────────────
# tt_working 은 화면 뭉치를 받지만, 실제 판정은 그중 딱 한 줄에 대한 grep 이다.
# 그 한 줄을 직접 먹여 대안별 책임을 또렷하게 잰다(화면 전체 경로는 아래 ③에서 따로 잰다).
pat_case() {                 # pat_case <MATCH|no> <줄> <설명>
    local want="$1" line="$2" why="$3" got=no
    printf '%s\n' "$line" | grep -qaE "$WORKING_PAT" && got=MATCH
    assert_eq "$got" "$want" "[$LOCTAG] $why"
}

# ── ① 잡아야 하는 줄 / ② 잡으면 안 되는 줄 ─────────────────────────────────
# 두 로케일에서 같은 답이 나와야 한다 — 훅은 cron 에서도 돌고, 거기엔 로케일이 없다.
run_cases() {
    # (①) 미탐 방어 — 진짜 도는 화면
    pat_case MATCH '✻ Choreographing… (43s · ↓ 1.9k tokens)' \
        '기준선: WORKING 캡처 29행의 실제 선택줄'
    pat_case MATCH '* Deliberating… (20s · ↓ 499 tokens)' \
        'ASCII 글리프 변종 — 이제 글리프 교대가 정면에서 잡는다'
    pat_case MATCH '* Deliberating… (11s' \
        '글리프 구멍이 실제로 드러나는 형태 — 토큰 카운터가 없어 타이머 대안이 못 구한다(옛 패턴 전부 미탐)'
    pat_case MATCH '✻ Sautéed… (12s' \
        '비ASCII 동사(é) — 옛 [A-Za-z]+ 가 é 에서 끊겨 전부 미탐이었다'
    pat_case MATCH '✻ Choreographing... (43s · ↓ 1.9k tokens)' \
        '말줄임표가 ASCII 세 점으로 떨어진 경우 — 옛 패턴은 U+2026 만 받았다'
    pat_case MATCH '✶ Sautéeing… (2m · ↑ 5k tokens)' \
        '초 없이 분만 뜨는 타이머 + 상향 화살표 — 옛 [0-9]+m?s 가 s 를 강제해 통째로 놓쳤다'
    pat_case MATCH '✻ Sautéed for 1h 10m 46s' \
        'EVIDENCE 가 지목한 괄호 없는 형태 — 시(h) 단위가 유일한 판별자다(⑤ 대안, 고위험)'
    pat_case MATCH '✻ Waiting for 1 dynamic workflow to finish' \
        'WORKING 캡처 9행 실물 — 진행형이라 완료줄과 문법으로 갈린다'
    pat_case MATCH '✻ Composing… (12s · esc to interrupt · ctrl+t to show todos)' \
        '인터럽트 힌트가 괄호 안 뒤쪽에 오는 배치도 받는다'
    pat_case MATCH '✻ Simmering… (11s · ↓ 347 tokens · thought for 6s)' \
        '옛 주석에 박제돼 있던 과거 실패 형태 — 회귀 방지'
    pat_case MATCH '· Puttering... (1s · ↓ 12 tokens)' \
        '중점(·) 프레임 + ASCII 말줄임표'

    # (②) 오탐 방어 — 노는 화면, 그리고 화면에 떠 있는 남의 텍스트
    pat_case no '✻ Baked for 11m 42s' \
        '★하드 제약: device-refactor 캡처의 실제 선택줄(유휴). for 형태를 무분별하게 넣으면 여기서 즉사한다'
    pat_case no '✻ Worked for 7m 32s' \
        '★하드 제약: member-refactor 캡처의 실제 선택줄(유휴)'
    pat_case no '✻ Churned for 13m 39s' \
        '완료줄 — 13분이라 시(h) 게이트에 안 걸린다는 것까지 확인'
    pat_case no '  다음 할 일은 Qwen3-Next-80B의 컨텍스트를 8k~16k로 낮춰 메모리 압박을 줄이는 것입니다.' \
        'general 캡처의 recap 꼬리 — k 접미 숫자가 있어도 안 걸려야 한다'
    pat_case no '❯ /remote-control' \
        'photo 캡처의 슬래시 명령 잔상'
    pat_case no '  코드에 esc to interrupt 라는 문자열을 그냥 적어둔 줄입니다' \
        '이 저장소 문서가 화면에 떠 있는 경우 — 옛 패턴은 맨 리터럴이라 무조건 걸렸다'
    pat_case no '  ◯ fmux-settings-tui  fmux                           3/4 agents done · 17m 52s · ↓ 366.8k tokens' \
        'fmux 자기 TUI 진행줄 — 옛 패턴은 이걸 잡아 자신을 작업중으로 읽었다'
    pat_case no '  - 스피너는 26s · ↓ 763 tokens 처럼 뜬다고 문서에 적어뒀다' \
        '토큰 카운터 형식을 인용한 산문 — 타이머를 괄호 안으로 못박아 해결'
    pat_case no '  ✻ 표시가 왜 안 뜨는지 조사했습니다 — 20초 가드 때문입니다' \
        '이 버그를 논하는 대화 자체가 화면에 있는 경우(자기참조 오탐)'
    pat_case no '  ● Bash(make verify)' \
        '도구 호출 줄 — 글리프 유사 기호 + 괄호'
    pat_case no '  ⎿  Read src/30-state.sh (191 lines)' \
        '도구 결과 줄 — 괄호+숫자가 있어도 글리프·말줄임표 요구가 막는다'
    pat_case no '  (disable recaps in /config)' \
        'lx-notes 캡처의 실제 선택줄 — 괄호로 시작하는 줄'
}

LOCTAG='UTF-8'; export LC_ALL=en_US.UTF-8; run_cases
LOCTAG='C';     export LC_ALL=C;           run_cases
export LC_ALL=en_US.UTF-8

# ── ②-b ★알려진 미해결 오탐 (닫히지 않았다) ────────────────────────────────
# 설계자 케이스 24번은 `✻ Baked for 1h 5m 3s` 를 "안 걸려야 한다"로 냈다. 지금은 걸린다.
# 글자만으로는 못 가른다 — 유휴 캡처의 `✻ Baked for 11m 42s` 와 문법이 완전히 같고, ⑤ 대안이
# `✻ Sautéed for 1h 10m 46s`(EVIDENCE 가 스피너로 지목)를 잡으려고 시(h) 단위를 판별자로 쓰기 때문이다.
# 그래서 여기서는 "고쳐졌다"고 거짓말하지 않고 **현재 동작을 못박는다**.
#   터지는 경로: 한 시간 넘게 돈 턴이 끝나 노는 세션에 80-view.sh 가 ✻ 를 새로 붙인다.
#   닫는 방법: 패턴으로는 못 닫는다. CPU 델타 판정(t-09)이 들어왔지만 이것도 못 닫는다 —
#   ⑤가 터지는 자리는 80-view.sh 의 훅 없는 분기라 잴 pid 가 없고, CPU 는 훅이 working 인
#   경로에만 선다. 닫으려면 그 분기에 pane pid → 에이전트 pid 해석을 먼저 붙여야 한다.
#   그 작업이 끝나면 이 단언이 실패한다 — 실패하면 그게 정답이니 아래 두 줄을 no 로 뒤집어라.
got=no
printf '%s\n' '✻ Baked for 1h 5m 3s' | grep -qaE "$WORKING_PAT" && got=MATCH
assert_eq "$got" "MATCH" \
    '★알려진 구멍: 1시간 넘게 돈 턴의 완료줄은 아직 오탐이다(CPU 델타 도입 시 ⑤ 대안 제거·AND 로 닫을 것)'

# ── ③ 실캡처 회귀 — tt_working 전 경로 ──────────────────────────────────────
# 여기서는 한 줄이 아니라 화면 뭉치를 통째로 먹인다. 줄 고르는 awk(구분선·빈 줄 건너뛰기)까지
# 같이 재는 유일한 자리다. 캡처는 2026-08-05 01:38~01:41 컨트롤러 실측 원본이다.
assert_rc 0 test -d "$FIX"
for f in "$FIX"/*.screen; do
    base=${f##*/}
    case "$base" in
        WORKING-*) want=0; label='작업중 캡처는 걸려야 한다' ;;
        *)         want=1; label='유휴 캡처는 안 걸려야 한다' ;;
    esac
    got=0; tt_working < "$f" || got=$?
    assert_eq "$got" "$want" "$label — $base"
done
# 캡처 개수도 못박는다 — fixtures 가 통째로 비어도 위 루프는 조용히 0건으로 통과한다.
assert_eq "$(ls "$FIX"/*.screen 2>/dev/null | grep -c .)" "7" "실캡처 7건이 다 있다(유휴 6 · 작업중 1)"

# ── ④ 줄 고르기 자체 ────────────────────────────────────────────────────────
# 패턴이 무엇을 보고 판단했는지를 못박는다. awk 가 다른 줄을 집기 시작하면 위 ③은
# "엉뚱한 줄로 우연히 맞는" 상태로도 통과할 수 있다.
pick_line() {
    awk '{ L[NR] = $0 }
         /^❯/ { p = NR }
         END { if (!p) exit
               i = p - 1
               if (i >= 1 && L[i] ~ /^──/) i--
               while (i >= 1 && L[i] ~ /^[ \t]*$/) i--
               if (i >= 1) print L[i] }' "$1"
}
assert_eq "$(pick_line "$FIX/device-refactor.screen")" '✻ Baked for 11m 42s' \
    'device-refactor 에서 판정에 쓰이는 줄은 과거형 완료줄이다'
assert_eq "$(pick_line "$FIX/WORKING-sample-tui-worker.screen")" '✻ Choreographing… (43s · ↓ 1.9k tokens)' \
    'WORKING 캡처에서 판정에 쓰이는 줄은 스피너 줄이다(진행줄이 아니라 — EVIDENCE 는 여기를 틀리게 적었다)'

tt_test_done
