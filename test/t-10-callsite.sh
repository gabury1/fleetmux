#!/usr/bin/env bash
# 호출부 격자 — "작업중이다"를 실제로 화면에 그리는 두 곳(--list 의 ✻ 마크, --status 의 ✻n)이
# **같은 상태에 대해 무엇을 답하는가**를 통째로 못박는다.
#
# 왜 이 파일이 생겼나(2026-08-05, 설치 전 게이트):
#   t-08(패턴)·t-09(CPU 델타)는 **부품**을 잰다. 그 부품을 조립한 두 호출부는 아무도 안 쟀다.
#   그 결과 설치를 막을 결함 둘이 `make check` 를 **그대로 통과한 채** 실재했다:
#     ① WORKING_PAT 의 ⑤ 대안이 완료줄(`✻ Baked for 1h 5m 3s`)을 잡아, 일 끝난 세션에
#        ✻ 가 영구 박제됐다 — 부품 테스트는 그 줄을 "MATCH 가 정답"이라고 적고 통과시켰다.
#     ② --status 가 CPU rc1 을 이유로 working 세션을 안 세, 상태바 ✻n 이 5초마다 깜빡였다 —
#        --list 는 같은 상태를 ✻ 로 그리는데 상태바만 지웠다. 애초에 이 사고의 출발점이
#        "상태바엔 ✻4, 목록엔 마크 없음"이라는 불일치였는데, 반대 방향 불일치를 새로 만든 것이다.
#   둘 다 "부품은 맞는데 조립이 틀린" 결함이다. 그물이 여기 있었으면 둘 다 잡혔다.
#
# 격자: 훅 신선/낡음 × CPU rc0/rc1/rc2(모름) × 화면 매치/불일치 = 12칸. 각 칸의 기대값을
# 표로 고정하고, 두 호출부의 답이 갈리는 칸이 **어디이고 어느 방향인지**까지 못박는다.
#
# ⛔ tmux 를 부르지 않는다. 실제 에이전트 프로세스도 없다:
#    · tmux 는 PATH 앞의 셸 스크립트가 가로챈다(진짜 바이너리에 절대 안 닿는다).
#    · /proc 은 TT_PROC 로 가짜 디렉토리를 주입한다. ps 폴백도 셰임으로 막는다.
#    · "살아 있는 에이전트 pid" 자리는 이 테스트 프로세스 자신($$)이 맡는다 — 새 프로세스를
#      띄우지도, 아무에게도 신호를 보내지도 않는다(kill -0 존재 확인만 코드가 한다).
set -u
. "$(dirname "$0")/lib.sh"
tt_test_sandbox

STATE="$HOME/.cache/tt"; mkdir -p "$STATE"
PROC="$TTROOT/proc"; export TT_PROC="$PROC"
SELFPID=$$                     # 코드의 kill -0 생존 검사를 통과할 진짜 pid
SID=1                          # 가짜 tmux 가 주는 session_id '$1' → 상태 파일은 hook-1 / cpu-1
SNAME=w1

# ── ⛔ PATH 가드 — 어떤 단언보다 먼저 선다 ─────────────────────────────────
mkdir -p "$TTROOT/bin"
cat > "$TTROOT/bin/tmux" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TT_TMUX_LOG"
case "$1 ${2:-}" in
    "ls -F")
        # --list 의 세션 목록. 필드 = id / created / last_attached / attached / name
        printf '$1\t1700000000\t0\t-\t%s\n' "${TT_FAKE_NAME:-w1}"; exit 0 ;;
    "capture-pane -p")
        [ -n "${TT_SCREEN:-}" ] && [ -f "${TT_SCREEN:-}" ] && cat "$TT_SCREEN"
        exit 0 ;;
    "list-panes -s")
        # tt_is_agent 의 2순위 판정 — 훅 파일이 없을 때만 여기까지 온다
        printf '%s\n' "${TT_FAKE_PANE_CMD:-claude}"; exit 0 ;;
esac
exit 1
SHIM
chmod +x "$TTROOT/bin/tmux"
# ps 폴백까지 막는다 — 이게 없으면 가짜 /proc 이 비었을 때 이 테스트 프로세스의 **진짜** CPU
# 시간을 읽어, 기계 부하에 따라 답이 흔들리는 테스트가 된다.
cat > "$TTROOT/bin/ps" <<'SHIM'
#!/usr/bin/env bash
printf 'ps %s\n' "$*" >> "$TT_TMUX_LOG"
exit 1
SHIM
chmod +x "$TTROOT/bin/ps"
export TT_TMUX_LOG="$TTROOT/tmux-calls.log"
: > "$TT_TMUX_LOG"
export PATH="$TTROOT/bin:$PATH"

# ── 가짜 화면 세 장 ─────────────────────────────────────────────────────────
# tt_working 의 awk 는 "❯ 위, 구분선 건너뛰고, 빈 줄 건너뛴 한 줄"만 본다 — 그 모양 그대로 만든다.
mkscreen() { printf '%s\n────────────────\n❯ \n' "$2" > "$TTROOT/$1.screen"; }
mkscreen match   '✻ Choreographing… (43s · ↓ 1.9k tokens)'   # WORKING 캡처의 실제 선택줄
mkscreen idle    '✻ Baked for 11m 42s'                       # device-refactor 캡처의 실제 선택줄
mkscreen done1h  '✻ Baked for 1h 5m 3s'                      # 한 시간 넘게 돈 턴의 완료줄
SC_MATCH="$TTROOT/match.screen"
SC_IDLE="$TTROOT/idle.screen"
SC_DONE1H="$TTROOT/done1h.screen"

# ── 상태 심기 ───────────────────────────────────────────────────────────────
# 호출부는 판정 뒤 tt_cpu_sample 로 스냅샷을 회전시킨다 → 파일이 매 호출마다 바뀐다.
# 그래서 **호출 하나마다 새로 심는다**. now 도 그때그때 다시 읽는다(테스트가 오래 돌아도 안 밀리게).
fake_proc() {                  # fake_proc <pid> <utime> <stime>
    mkdir -p "$PROC/$1"
    printf '%s (claude) S 1 %s %s 0 -1 4194304 111 222 0 0 %s %s 0 0 20 0 12 0 999 0 0\n' \
        "$1" "$1" "$1" "$2" "$3" > "$PROC/$1/stat"
}
plant() {                      # plant <fresh|stale> <rc0|rc1|rc2|nohook>
    local now hts
    now=$(date +%s)
    case "$1" in
        fresh) hts=$((now - 5))  ;;   # ≤20초 = 에이전트 본인의 자백이 아직 유효
        stale) hts=$((now - 60)) ;;   # >20초 = 박제 방지 가드가 서는 구간
    esac
    if [ "$2" = nohook ]; then
        rm -f "$STATE/hook-$SID" "$STATE/cpu-$SID"
        return 0
    fi
    printf 'working %s %s\n' "$hts" "$SELFPID" > "$STATE/hook-$SID"
    fake_proc "$SELFPID" 100000 0                     # 현재 카운터 = 100000 cs
    case "$2" in
        # 창 5초. 임계는 6 cs/s → 경계 델타 30. 시각이 1초 밀려도(창 4~6초) 판정이 안 뒤집히게 벌린다.
        rc0) printf '%s %s 99960 0 0\n' "$SELFPID" "$((now - 5))" > "$STATE/cpu-$SID" ;;  # Δ40 → 8.0 cs/s
        rc1) printf '%s %s 99980 0 0\n' "$SELFPID" "$((now - 5))" > "$STATE/cpu-$SID" ;;  # Δ20 → 4.0 cs/s
        rc2) rm -f "$STATE/cpu-$SID" ;;                                                   # 스냅샷 없음 = 웜업
    esac
}

# ── 두 호출부를 실제로 돌린다 ───────────────────────────────────────────────
list_mark() {                  # --list 가 그 세션에 ✻ 를 붙였나 → yes/no
    local out
    out=$("$TTBIN" --list 2>/dev/null) || true
    case "$out" in *'✻'*) printf 'yes' ;; *) printf 'no' ;; esac
}
status_count() {               # --status 의 ✻n → n
    local out n
    out=$("$TTBIN" --status 2>/dev/null) || true
    case "$out" in
        *'✻'*) n=${out#*✻}; n=${n%% *} ;;
        *)     n=0 ;;
    esac
    case "${n:-}" in ''|*[!0-9]*) n=0 ;; esac
    printf '%s' "$n"
}

# ── ① 격자 12칸 ────────────────────────────────────────────────────────────
# want_list  : --list 가 ✻ 를 그리나 (yes/no)
# want_status: --status 의 ✻n (0/1)
cell() {                       # cell <fresh|stale> <rc0|rc1|rc2> <screen> <want_list> <want_status> <설명>
    local hook="$1" cpu="$2" screen="$3" wl="$4" ws="$5" why="$6" gl gs
    export TT_SCREEN="$screen"
    plant "$hook" "$cpu"; gl=$(list_mark)
    plant "$hook" "$cpu"; gs=$(status_count)
    assert_eq "$gl" "$wl" "[--list  ] 훅$hook × CPU$cpu × 화면$( [ "$screen" = "$SC_MATCH" ] && echo 매치 || echo 불일치) — $why"
    assert_eq "$gs" "$ws" "[--status] 훅$hook × CPU$cpu × 화면$( [ "$screen" = "$SC_MATCH" ] && echo 매치 || echo 불일치) — $why"
    # ★불변식: 훅이 working 인 세션에 대해 상태바는 팝업보다 **적게 셀 수 없다**.
    #   상태바에는 3순위 증인(화면)이 없다 — 없는 증인을 근거로 지우면 팝업보다 공격적으로
    #   지우게 되고, 그게 이번 사고의 출발점("상태바엔 ✻4, 목록엔 마크 없음")의 정확한 뒤집힘이다.
    local lnum=0; [ "$gl" = yes ] && lnum=1
    TT_RUN=$((TT_RUN + 1))
    if [ "$gs" -ge "$lnum" ]; then
        printf '  ok   불변식 상태바(%s) ≥ 팝업(%s)\n' "$gs" "$lnum"
    else
        TT_FAIL=$((TT_FAIL + 1))
        printf '  FAIL 불변식 위반: 상태바(%s) < 팝업(%s) — %s\n' "$gs" "$lnum" "$why"
    fi
}

# (가) 훅이 신선하면 1순위 증인만으로 끝난다 — CPU 도 화면도 이 판정을 못 뒤집는다.
cell fresh rc0 "$SC_MATCH" yes 1 '훅 신선은 에이전트 본인의 자백 — 무조건 작업중'
cell fresh rc0 "$SC_IDLE"  yes 1 '훅 신선: 화면이 유휴여도 안 뒤집힌다(렌더링이 자백을 못 이긴다)'
cell fresh rc1 "$SC_MATCH" yes 1 '훅 신선: CPU 가 아니라고 해도 안 뒤집힌다'
cell fresh rc1 "$SC_IDLE"  yes 1 '★훅 신선 + CPU 유휴 + 화면 유휴 — 그래도 20초 안엔 안 지운다'
cell fresh rc2 "$SC_MATCH" yes 1 '훅 신선: CPU 판정불가는 아무것도 안 바꾼다'
cell fresh rc2 "$SC_IDLE"  yes 1 '훅 신선: 웜업 구간에서도 ✻ 가 안 사라진다'

# (나) 훅이 낡으면 박제 방지 가드가 선다 — 여기서 두 호출부가 처음으로 갈린다.
cell stale rc0 "$SC_MATCH" yes 1 'CPU 가 작업중이라고 답하면 화면을 아예 안 본다'
cell stale rc0 "$SC_IDLE"  yes 1 '★원래 증상: 도구 없이 긴 사고 턴 — 화면이 유휴여도 CPU 가 구한다'
cell stale rc1 "$SC_MATCH" yes 1 '★차단2 의 자리: 화면 증인이 서면 --list 는 ✻ 를 유지한다. 상태바도 같이 세야 한다'
cell stale rc1 "$SC_IDLE"  no  1 '★박제 해제 — 증인 셋이 다 아니라고 할 때만 --list 가 지운다'
cell stale rc2 "$SC_MATCH" yes 1 'CPU 판정불가(웜업·detached) → 화면이 3순위 보험으로 선다'
cell stale rc2 "$SC_IDLE"  no  1 '판정불가 + 화면 유휴 → --list 는 지우고, 상태바는 모름을 지움으로 접지 않는다'

# ── ② 갈리는 칸이 정확히 어디인지, 그리고 그 방향 ──────────────────────────
# 12칸 중 두 곳(stale×rc1×화면유휴, stale×rc2×화면유휴)에서만 답이 갈린다. 그리고 방향이
# 항상 "상태바가 더 센다" 한쪽이다. 반대 방향이 생기면 위 불변식 단언이 먼저 터진다.
# 여기서는 그 두 칸이 **의도된 것**임을 이유와 함께 못박는다: 상태바는 세션 이름을 모르고
# 5초마다 함대 전체를 capture-pane 할 수도 없어 3순위 증인 자체가 없다.
export TT_SCREEN="$SC_IDLE"
plant stale rc1; assert_eq "$(list_mark)"    "no" '설계상 불일치 1/2 — --list 는 세 증인을 다 보고 지운다'
plant stale rc1; assert_eq "$(status_count)" "1"  '설계상 불일치 1/2 — 상태바는 증인이 둘뿐이라 안 지운다'

# ── ③ 차단2 회귀 — CPU rc1 단발로 상태바를 끄지 않는다 ─────────────────────
# 실측: 도구 호출 응답을 기다리는 claude 는 3~22 cs/s 를 오가며 임계 6 을 계속 가로지른다.
# 상태바는 5초마다 도니, rc1 한 번으로 뱃지를 끄면 진짜 일하는 세션의 ✻n 이 깜빡인다.
# 연속 세 틱이 전부 rc1 이어도 개수가 안 흔들리는지 잰다(히스테리시스 없이 '항상 센다'로 푼 자리).
export TT_SCREEN="$SC_MATCH"
n1=0; n2=0; n3=0
plant stale rc1; n1=$(status_count)
plant stale rc1; n2=$(status_count)
plant stale rc1; n3=$(status_count)
assert_eq "$n1$n2$n3" "111" '★CPU 가 세 틱 연속 rc1 이어도 상태바 ✻n 은 안 깜빡인다(1 1 1)'

# ── ④ 차단1 회귀 — 완료줄이 화면 증인 노릇을 하면 안 된다 ──────────────────
# WORKING_PAT 의 ⑤ 대안(`(글리프) [^ ]+ for [0-9]+h`)이 살아 있으면 여기가 yes 가 된다.
# 그 줄은 "한 시간 넘게 돈 턴이 **끝났다**"는 뜻이고, 완료줄은 다음 턴까지 화면에 남으므로
# ✻ 가 스스로 안 꺼진다 — 박제 방지 가드가 통째로 무력화된다. 부품(t-08)과 호출부 양쪽에서 막는다.
export TT_SCREEN="$SC_DONE1H"
plant stale rc1
assert_eq "$(list_mark)" "no" \
    '★한 시간 넘게 돈 턴의 완료줄은 ✻ 를 되살리지 못한다(⑤ 대안이 살아 있으면 여기서 yes 가 난다)'
plant stale rc2
assert_eq "$(list_mark)" "no" \
    '★CPU 가 판정불가일 때도 완료줄은 증인이 아니다 — 여기가 진짜 박제가 나던 자리다'
# 그리고 진짜 스피너는 같은 조건에서 여전히 구해준다(⑤ 제거가 미탐을 만들지 않았다는 증거)
export TT_SCREEN="$SC_MATCH"
plant stale rc2
assert_eq "$(list_mark)" "yes" '⑤ 를 빼도 진짜 스피너 화면은 그대로 ✻ 를 세운다'

# ── ⑤ 훅 파일이 아예 없는 세션 — 구조적으로 갈리는 유일한 자리 ─────────────
# --status 는 hook-* 를 훑어 세므로 훅이 없는 세션을 애초에 못 본다. --list 는 화면으로 본다.
# 이건 불일치가 아니라 **관측 범위 차이**다. 위 불변식(상태바 ≥ 팝업)이 여기엔 적용되지 않는다는
# 사실을 명시적으로 못박는다 — 모르고 부등식을 전역으로 믿으면 엉뚱한 곳을 고치게 된다.
export TT_SCREEN="$SC_MATCH"
plant stale nohook
assert_eq "$(list_mark)"    "yes" '훅 없는 세션은 --list 가 화면만으로 판정한다'
assert_eq "$(status_count)" "0"   '훅 없는 세션은 --status 의 시야 밖이다(관측 범위 차이 — 규칙 불일치가 아니다)'
export TT_SCREEN="$SC_IDLE"
plant stale nohook
assert_eq "$(list_mark)" "no" '훅도 없고 화면도 유휴면 마크가 없다'

# ── ⑥ --status 는 샘플러다 ─────────────────────────────────────────────────
# C(CPU 델타) 설계의 축: 상태바가 5초마다 돌며 표본을 회전시켜, 팝업이 언제 열려도 신선한 창을
# sleep 0 으로 얻는다. 여기서 tt_cpu_sample 호출이 빠지면 팝업 쪽 tt_cpu_busy 가 영구 rc2 가 되고
# CPU 판정이 통째로 죽는다 — 화면이 깨지면 다시 ✻ 가 사라진다. 그 호출을 못박는다.
rm -f "$STATE/cpu-$SID"
now=$(date +%s)
printf 'working %s %s\n' "$((now - 60))" "$SELFPID" > "$STATE/hook-$SID"
fake_proc "$SELFPID" 100000 0
status_count >/dev/null
assert_rc 0 test -f "$STATE/cpu-$SID"
assert_eq "$(cut -d' ' -f1 < "$STATE/cpu-$SID")" "$SELFPID" \
    '★--status 한 번이 표본을 남긴다(샘플러 역할) — 이 줄이 빠지면 팝업의 CPU 판정이 영구 rc2 다'
fake_proc "$SELFPID" 100200 0                      # 다음 틱에 +200cs
sleep 4                                            # ROTATE(3초) 를 넘겨 실제로 회전시킨다
status_count >/dev/null
assert_eq "$(awk '{ print ($4 > 0 && $5 > 0) ? "yes" : "no" }' < "$STATE/cpu-$SID")" "yes" \
    '★두 번째 틱에서 이전 표본 자리가 채워진다 — 표본이 둘이어야 팝업이 어느 타이밍에도 창을 얻는다'
# 그리고 그 표본만으로 팝업 쪽 판정이 실제로 선다(화면 없이)
export TT_SCREEN=""
assert_eq "$(list_mark)" "yes" \
    '★상태바가 남긴 표본만으로 팝업이 작업중을 판정한다 — 화면을 아예 안 보고(TT_SCREEN 빈 값) 뜬다'

# ── ⑦ 진짜 tmux·진짜 ps 에 한 번도 안 닿았다 ───────────────────────────────
assert_eq "$(grep -c '^ps ' "$TT_TMUX_LOG" || true)" "0" \
    'ps 폴백을 한 번도 안 탔다 = CPU 판정이 전부 가짜 /proc 으로 결정됐다(기계 부하와 무관)'
stray=$(grep -vE '^(ps |ls -F|capture-pane -p|list-panes -s|display-message -p)' "$TT_TMUX_LOG" | sort -u || true)
assert_eq "$stray" "" \
    '★가짜 tmux 가 받은 명령은 읽기 전용뿐이다 — kill-session·new-session·send-keys 류가 새지 않았다'

tt_test_done
