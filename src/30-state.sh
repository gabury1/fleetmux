# Claude 작업중 판정 패턴 — 화면 한 줄(❯ 위 구분선 위 한 줄)만 보고 "지금 도는 중인가"를 가른다.
#
# 왜 다시 손댔나(2026-08-05): device-refactor 가 실제로 사고 중인데 목록에 ✻ 가 안 떴다.
#   80-view.sh 의 박제 방지 가드는 "훅 갱신이 20초 넘게 끊겼고 화면에도 스피너가 없으면" ✻ 를 지운다.
#   working 훅은 UserPromptSubmit/PostToolUse 로만 갱신되니 도구를 안 쓰고 20초 넘게 생각하는 턴에서는
#   갱신이 정상적으로 끊긴다 — 그때 2차 근거인 이 패턴이 구해줘야 하는데 못 구했다.
#   증거: .superpowers/sdd/screen-evidence/EVIDENCE.md 와 캡처 7건(test/fixtures/screen 에 복제).
#
# 다섯 대안이 왜 그 모양인지 — 전부 실측이 근거고 test/t-08-working-pat.sh 가 그대로 잰다:
#   ① (\([^()]*|· )[Ee]sc to interrupt
#      옛 패턴은 이걸 맨 리터럴로 뒀다 → 이 저장소 문서가 pane 에 떠 있기만 해도 발사됐다
#      ("코드에 esc to interrupt 라는 문자열을 그냥 적어둔 줄입니다" 가 실측 MATCH).
#      실제 형태는 `(3s · esc to interrupt)` 와 `(esc to interrupt · ctrl+t …)` 둘뿐이라
#      여는 괄호 뒤이거나 중점 뒤일 것을 요구해 산문 에코를 턴다.
#   ② \([^()]*[0-9]+[hms] · (↑|↓) ?[0-9.,]+[kKmM]? ?tokens
#      타이머+토큰 카운터. **괄호 안일 것을 요구하는 게 핵심** — 안 요구하던 옛 패턴은 fmux 자기
#      TUI 진행줄(`3/4 agents done · 17m 52s · ↓ 366.8k tokens`)에 걸려 자신을 작업중으로 읽었다(실측).
#      옛 꼬리 `[0-9]+m?s` 는 끝에 s 를 강제해 `(2m · ↑ 5k tokens)` 를 통째로 놓쳤고, k 만 알아서
#      `1.2M tokens` 도 못 봤다 → [hms] 와 [kKmM] 로 넓혔다.
#   ③ (글리프) [^ ()]*(…|\.\.\.) ?\(?[0-9]
#      스피너 본체. 옛 `[A-Za-z]+…` 는 `✻ Sautéed… (12s` 의 é 에서 끊겨 미탐(실측), 말줄임표도
#      U+2026 만 받아 터미널이 `...` 로 떨어뜨리면 또 미탐. 글리프 교대에 `*` 를 넣은 이유도 실측이다 —
#      `* Deliberating… (11s` 는 토큰 카운터가 없어 ②가 못 구해서 옛 대안 셋 전부 미탐이었다.
#   ④ (글리프) [A-Za-z]*ing for [^ ]
#      `✻ Waiting for 1 dynamic workflow to finish`(WORKING 캡처 9행 실물). 진행형이라 완료줄(과거형)과
#      문법으로 갈린다 — for 형태 중 유일하게 안전한 쪽.
#   ⑤ (글리프) [^ ]+ for [0-9]+h   ← ❌ 있었다가 **뺐다**(2026-08-05, 설치 전 게이트).
#      들어왔던 이유: EVIDENCE.md 가 `✻ Sautéed for 1h 10m 46s` 를 스피너로 지목했다.
#      뺀 이유 — 그 근거가 실측으로 무너졌다:
#        · `grep -al 'Saut' screen-evidence/*.screen test/fixtures/screen/*.screen` = **0건**.
#          "시(h) 단위 진행형 for 줄"이라는 것은 어느 캡처에도 없다. 순이득이 0이다.
#        · 캡처에 실재하는 for 줄은 **전부 과거형 완료줄**이다: `✻ Baked for 11m 42s`(device-refactor
#          의 실제 선택줄) · `✻ Worked for 7m 32s` · `✻ Churned for 13m 39s` · `✻ Brewed for 21s`.
#          시 단위로만 커지면(`✻ Baked for 1h 5m 3s`) 문법이 완전히 같아 글자로는 못 가른다 →
#          ⑤는 이득 0 / 손실 확정인 순수 신규 오탐이었다(옛 패턴 old=no → new=YES 실측).
#        · 그리고 "터지는 자리는 훅 없는 분기뿐"이라던 옛 서술이 **틀렸다**: 80-view.sh:186-197 의
#          working 분기도 훅이 stale(>20초)이고 CPU 가 rc0 이 아니면 화면 판정으로 떨어진다.
#          즉 ⑤는 "한 시간 넘게 돈 턴이 끝난 세션"의 완료줄을 잡아 ✻ 를 다시 켰고, 완료줄은
#          다음 턴까지 화면에 남으므로 **스스로 안 꺼진다** — 이 변경 전체가 지키려던 박제 방지
#          가드를 정면으로 무력화했다. 잃는 건 없다: `✻ Waiting for …` 은 ④가 그대로 받는다.
#      ⛔ "시(h) 단위 for" 를 다시 넣지 마라. 넣으려면 진행형(-ing)을 요구하는 ④를 넓혀라.
#
# 멀티바이트를 브래킷이 아니라 리터럴 교대 (✻|✶|…) 로 쓴 이유: 브래킷 안 3바이트 문자는 C 로케일에서
# 문자 집합이 아니라 **바이트 집합**으로 붕괴한다(✻ 의 세 바이트 중 하나만 맞아도 통과). 교대는
# 로케일·grep 구현과 무관하게 문자 단위로 확정된다. ERE 전용 문법만 쓴다 —
# \d \s \b {n,m} (?:) 역참조는 GNU/PCRE 확장이라 BSD grep 에서 안 돈다.
WORKING_PAT='(\([^()]*|· )[Ee]sc to interrupt|\([^()]*[0-9]+[hms] · (↑|↓) ?[0-9.,]+[kKmM]? ?tokens|(✻|✶|✳|✢|✽|·|\*) [^ ()]*(…|\.\.\.) ?\(?[0-9]|(✻|✶|✳|✢|✽|·|\*) [A-Za-z]*ing for [^ ]'

# 작업중 판정: 스피너는 항상 "입력창(❯) 위 구분선 바로 위 한 줄"에 뜬다 — 그 한 줄만 검사.
# (하단 N줄 뭉텅이 검사는 화면에 남은 대화 텍스트에 오탐/미탐 — 두 번 데임)
tt_working() {
    awk '
        { L[NR] = $0 }
        /^❯/ { p = NR }
        END {
            if (!p) exit
            i = p - 1
            if (i >= 1 && L[i] ~ /^──/) i--
            while (i >= 1 && L[i] ~ /^[ \t]*$/) i--
            if (i >= 1) print L[i]
        }' | grep -qaE "$WORKING_PAT"
}

# ── CPU 델타 기반 작업중 판정 ────────────────────────────────────────────────
# 왜 들어왔나(2026-08-05): 위 화면 판정은 렌더링 산출물을 읽는 일이라 글리프 하나·문구 한 줄이
# 바뀌면 조용히 깨진다 — WORKING_PAT 주석 전체가 그 실증이다. 반면 "그 프로세스가 지금 CPU를
# 태우고 있나"는 커널 회계라 TUI 문구와 무관하다. 그래서 화면을 **대체하지 않고 앞에 끼운다**.
#
# ⚠️ 이 신호는 ✻ 를 **살리는 근거로만** 쓴다. 죽이는 근거로는 절대 쓰지 마라.
#    이번 버그가 "실제로 일하는 세션의 ✻ 를 잘못 지운 것"이라, 새 삭제 경로를 하나도 만들지 않는
#    배치만 안전하다. 그래서 tt_cpu_busy 의 rc 는 3값이다: 0=작업중 / 1=아님 / **2=판정불가**.
#    "모른다"를 "아니다"로 접는 순간 ✻ 가 또 사라진다 — 접는 건 호출부가 자기 맥락에서 정한다.
#
# 설계의 축: --list 는 팝업을 여는 경로라 즉시 그려져야 한다 → 3초를 재는 동기 샘플링은 못 넣는다.
# 그래서 **지난 호출이 남긴 스냅샷과의 델타**를 쓴다(상태를 작은 파일 한 줄에 두는 기존 관례 그대로).
# 샘플러는 상태바다 — .tmux.conf 의 `#(tt --status)` 가 status-interval 5로 5초마다 돌며
# working 세션의 스냅샷을 갱신한다. 그래서 팝업은 언제 열려도 3~10초짜리 신선한 창을 즉시 얻는다.
# 상태바가 없는 환경(붙은 클라이언트 없음)에서는 창이 늘 MAXWIN을 넘어 항상 rc 2 →
# 동작이 도입 전과 정확히 같아진다(화면 판정). 퇴행 경로가 없다.
#
# 단위: 리눅스 /proc 의 USER_HZ 틱(=100Hz 고정)과 macOS `ps -o time=` 의 1/100초가 같은 단위라
# **양 플랫폼이 같은 산술·같은 임계값**을 쓴다. 갈리는 건 "카운터를 읽는 한 줄"뿐이다.
#
# 임계값 근거 — 이 파이에서 직접 잰 것(utime+stime 1Hz, claude 7세션, 총 177초, 훅 상태로 대조):
#   초당 평균: working 15.9 / 23.0 / 23.9 / 25.3 cs/s   idle 1.4 / 1.4 / 1.6 cs/s
#   창 길이별 (min working vs max idle):
#     1s  working 2.00 vs idle 6.00   *** 겹침 ***     ← 1~2초 창은 두 부류를 못 가른다
#     2s  working 5.00 vs idle 5.50   *** 겹침 ***
#     3s  working 4.00~6.00 vs idle 4.00~5.00
#     5s  working 5.20~6.00 vs idle 3.20~4.00
#    20s  working 10.70~12.35 vs idle 2.15~2.85
#   임계값별 오류율: win3 th6 → 미탐 0~2.3% 오탐 0% | win3 th4 → 오탐 0.3~2.9%(유휴 버스트)
#                    win5 th10 → 미탐 26.4%(긴 사고 구간을 놓침)
#   즉 MINWIN=3 은 타협이 아니라 데이터가 그은 선이고, 6 은 미탐·오탐이 동시에 바닥인 유일한 값이다.
#   오차는 비대칭이라 이 좁은 여유가 허용된다 — 미탐은 화면 판정이 3순위로 받아주고,
#   오탐은 훅이 이미 working 이라 새로 생기는 오류가 아니다.
# MAXWIN 이 왜 필요한가: 긴 창은 희석된다. Esc 로 턴을 취소한 박제 케이스를 대입하면
#   10초 일하고 멈춘 뒤 5분 뒤 조회 → (25×10 + 1.5×290)/300 = 9.8 cs/s 로 임계를 넘어
#   **CPU 신호가 박제를 되살리는 흉기가 된다**. 60초로 자르면 그 창이 애초에 성립하지 않는다.
# 환경변수로만 덮어쓰게 두고 TT_CONF_KEYS 화이트리스트에는 넣지 않는다 — 사용자 설정이 아니라
#   튜닝 손잡이다(향후 TUI 렌더 비용이 바뀌면 여기만 만진다).
#   ⚠ 설정 키가 된 값은 이런 `${VAR:-기본}` 전역으로 두면 안 된다: 그 전역 이름이 곧 그 키의
#   환경변수 이름이라, 출처 판정이 영원히 "env 가 이긴다"가 되어 설정 파일이 죽는다
#   (log_max 가 실제로 그랬다 — 10-util.sh 의 회고 참조).
TT_CPU_BUSY=${TT_CPU_BUSY:-6}              # cs/s. 코어 하나의 6%
TT_CPU_MINWIN=${TT_CPU_MINWIN:-3}          # 초. 이보다 짧은 창은 판정불가(1~2초는 유휴와 겹친다)
TT_CPU_MINWIN_COARSE=${TT_CPU_MINWIN_COARSE:-20}  # 초. 카운터 분해능이 1초(=100cs)일 때의 하한
TT_CPU_MAXWIN=${TT_CPU_MAXWIN:-60}         # 초. 이보다 긴 창은 희석돼 못 믿는다 → 판정불가
TT_CPU_ROTATE=${TT_CPU_ROTATE:-3}          # 초. 표본 회전 간격(이보다 이르면 파일을 안 건드린다)

# macOS/BSD 폴백: `ps -p <pid> -o time=` → 센티초. TT_CPU_CS·TT_CPU_Q 를 세팅한다.
#   `ps -o %cpu=` 는 쓰지 않는다 — 리눅스에서는 **생애 평균**이라(실측: 36분 일한 세션이 유휴로
#   돌아선 뒤에도 17.8%) "지금 일하나"를 전혀 못 가르고, BSD 의 감쇠 평균은 상수가 문서화돼 있지
#   않다. 무엇보다 그걸 쓰면 맥과 리눅스가 다른 규칙·다른 임계값·다른 테스트를 갖게 된다 —
#   갈래가 둘이면 한쪽은 반드시 조용히 썩는다. 알고리즘 하나, 임계값 하나로 간다.
#   TIME 포맷은 [[DD-]HH:]MM:SS[.cc] 를 다 받는다. `10#` 접두사가 필수다 — 08·09 를 8진수로
#   해석해 산술이 즉사한다. 소수점이 있으면 분해능 1cs(맥), 없으면 100cs(초 단위 ps) →
#   호출부가 최소 창을 20초로 늘려 양자화 오탐을 막는다. 맥 실기기 확인 없이도 안 깨지는 구조다.
tt_cpu_cs_ps() {
    TT_CPU_CS=""; TT_CPU_Q=100
    local t d=0 h=0 m=0 s=0 frac=0
    t=$(ps -p "${1:-0}" -o time= 2>/dev/null | tr -d ' ') || return 1
    [ -n "$t" ] || return 1
    case "$t" in *-*) d=${t%%-*}; t=${t#*-} ;; esac
    case "$t" in *.*) frac=${t##*.}; t=${t%.*}; TT_CPU_Q=1 ;; esac
    case "$t" in
        *:*:*) h=${t%%:*}; t=${t#*:}; m=${t%%:*}; s=${t##*:} ;;
        *:*)   m=${t%%:*}; s=${t##*:} ;;
        *)     s=$t ;;
    esac
    # 소수부는 정확히 두 자리로 맞춘다(.5 → 50, .123 → 12). 빈 필드는 10#"" 산술 즉사라 다 막는다.
    case "$frac" in '') frac=0 ;; ?) frac="${frac}0" ;; ??) ;; *) frac=${frac%"${frac#??}"} ;; esac
    for t in "$d" "$h" "$m" "$s" "$frac"; do
        case "$t" in ''|*[!0-9]*) return 1 ;; esac
    done
    TT_CPU_CS=$(( ((10#$d * 24 + 10#$h) * 3600 + 10#$m * 60 + 10#$s) * 100 + 10#$frac ))
    return 0
}

# utime+stime 센티초 → 전역 TT_CPU_CS, 분해능 → TT_CPU_Q. rc 1 = 못 읽음(권한·프로세스 소멸).
#   리눅스는 /proc 을 직접 읽어 **포크 0**이다(실측 회당 0.5ms). 화면 판정은 세션당 포크 3개다 —
#   CPU 판정이 한 자릿수 싸다. 그래서 CPU 를 화면보다 앞에 두면 팝업이 오히려 빨라진다.
#   comm 은 괄호 안이고 공백·괄호를 품을 수 있다 → `##*') '` 오른쪽 최장매치로 잘라야 안 깨진다.
#   자른 나머지의 1번째가 state 이므로 utime(원본 14번)=arr[11], stime(15번)=arr[12].
#   ⛔ cutime/cstime(16·17번)은 **절대 더하지 마라**: 자식이 회수되는 순간 그 자식의 생애 CPU 가
#      부모 카운터로 통째로 점프해 한 창에서 수백 cs/s 짜리 가짜 스파이크를 만든다. 맥의
#      `ps -o time=` 도 자식을 안 세니 이렇게 해야 양 플랫폼이 정확히 같은 것을 잰다.
#   USER_HZ 는 100 고정으로 박는다(이 파이 getconf CLK_TCK=100 확인). getconf 를 부르면 포크가
#   하나 늘고, 1024인 alpha/ia64 는 fmux 대상이 아니다.
#   TT_PROC 는 테스트 주입용이다 — 가짜 /proc 을 물려 실제 프로세스 없이 전 경로를 잰다.
tt_cpu_read() {
    TT_CPU_CS=""; TT_CPU_Q=1
    local pid="${1:-0}" f line rest u s g
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    [ "$pid" -gt 0 ] || return 1
    f="${TT_PROC:-/proc}/$pid/stat"
    if [ -r "$f" ]; then
        line=""
        read -r line < "$f" 2>/dev/null || return 1
        rest=${line##*') '}
        [ "$rest" != "$line" ] || return 1        # comm 괄호가 없다 = /proc stat 형식이 아니다
        local arr
        g=0; case $- in *f*) g=1 ;; esac          # 필드는 전부 숫자지만 글롭을 원천 차단한다
        set -f
        arr=( $rest )
        [ "$g" = 1 ] || set +f
        u="${arr[11]:-}"; s="${arr[12]:-}"
        case "$u" in ''|*[!0-9]*) return 1 ;; esac
        case "$s" in ''|*[!0-9]*) return 1 ;; esac
        TT_CPU_CS=$(( u + s ))
        TT_CPU_Q=1                                # 1틱 = 1cs
        return 0
    fi
    tt_cpu_cs_ps "$pid"
}

# 스냅샷 파일 회전. 포맷은 한 줄 5필드 "<pid> <ts1> <cs1> <ts2> <cs2>" (hook-<sid> 와 같은 모양).
#   왜 표본이 **둘**인가 — 이게 설계의 핵심 트릭이다. 하나만 두면 "창 길이 하한(3초)"과
#   "갱신 주기(5초)"가 충돌한다: 상태바가 덮어쓰고 나면 읽는 쪽이 만나는 창이 0~5초라 절반쯤은
#   하한을 못 넘는다. 둘을 들고 있으면 최신 것이 너무 어릴 때 그 이전 것을 쓰면 되고, 어떤
#   호출 타이밍에도 유효한 창이 항상 하나는 있다(실제 궤적: 최신 0~5초 / 이전 5~10초).
#   ROTATE 안에 다시 불리면 파일을 아예 안 건드린다 — 팝업 연타로 창이 0초로 짜부라지지도,
#   SD 카드에 쓰기가 몰리지도 않는다.
#   now 를 인자로 받는 이유: 호출부(--list·--status)는 이미 date 를 한 번 불렀다. 안 넘기면 여기서 부른다.
tt_cpu_sample() {
    local sid="${1:-}" pid="${2:-0}" now="${3:-}" f cpid ts1 cs1 ts2 cs2 tmp d
    [ -n "$sid" ] || return 0
    case "$pid" in ''|*[!0-9]*) return 0 ;; esac
    [ "$pid" -gt 0 ] || return 0
    case "$now" in ''|*[!0-9]*) now=$(date +%s) ;; esac
    f="$STATE/cpu-$sid"
    ts2=0; cs2=0
    if [ -f "$f" ]; then
        cpid=""; ts1=""; cs1=""
        read -r cpid ts1 cs1 _ _ < "$f" 2>/dev/null || true
        case "${cpid:-}" in ''|*[!0-9]*) cpid=0 ;; esac
        case "${ts1:-}" in ''|*[!0-9]*) ts1=0 ;; esac
        case "${cs1:-}" in ''|*[!0-9]*) cs1=0 ;; esac
        # pid 가 다르면 옛 표본을 통째로 버린다(pid 재사용·에이전트 재기동 방어)
        if [ "$cpid" = "$pid" ] && [ "$ts1" -gt 0 ]; then
            # ⛔ 음수 델타를 먼저 턴다. now < ts1(= 미래 시각이 파일에 박혔다)이면 `-lt ROTATE`
            #    가 **영원히 참**이라 여기서 매번 즉시 return 하고, 파일이 다시는 안 갱신된다 →
            #    tt_cpu_busy 는 창이 음수라 계속 rc 2 → CPU 델타 판정이 통째로 죽는다.
            #    NTP 보정·수동 시각 변경·서스펜드로 실제로 벌어진다. 회복 경로가 없는 동결이라
            #    "다음 틱에 정상화"가 성립하지 않는 유일한 자리다.
            d=$(( now - ts1 ))
            if [ "$d" -ge 0 ]; then
                if [ "$d" -lt "$TT_CPU_ROTATE" ]; then return 0; fi
                ts2=$ts1; cs2=$cs1          # 정상 회전
            fi
            # d < 0 이면 옛 표본을 물려주지 않고(ts2=0 유지) 아래에서 새 표본으로 갈아엎는다
        fi
    fi
    tt_cpu_read "$pid" || return 0
    mkdir -p "$STATE" 2>/dev/null || return 0
    # tmp+mv — 읽는 쪽이 반쯤 쓰인 줄을 만나지 않게. $$ 로 갈라 --status 와 --list 가 겹쳐도 안전.
    tmp="$f.$$"
    if printf '%s %s %s %s %s\n' "$pid" "$now" "$TT_CPU_CS" "$ts2" "$cs2" > "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$f" 2>/dev/null || rm -f "$tmp"
    else
        rm -f "$tmp"
    fi
    return 0
}

# CPU 델타 판정. rc 0 = 작업중 / rc 1 = 작업중 아님 / **rc 2 = 판정불가**.
#   rc 2 가 나는 경우를 전부 열거한다 — 파일이 썩어도 옛 값으로 오판하지 않기 위함이다:
#     스냅샷 없음(웜업) · pid 없음/불일치 · 필드가 숫자가 아님 · 창 < 최소 · 창 > MAXWIN ·
#     델타 음수(카운터 리셋) · /proc 도 ps 도 못 읽음(프로세스 소멸·권한).
#   판정은 정수 곱셈뿐이다 — 나눗셈·소수 없음(bash 3.2 안전).
#   창은 벽시계(date)이고 카운터는 CPU 시간이다 → NTP 점프·서스펜드가 창을 왜곡한다.
#   음수 창과 MAXWIN 초과를 둘 다 막아 그 경우 판정불가로 떨어뜨린다.
#   "다음 틱에 정상화"되는 것은 tt_cpu_sample 이 음수 델타에서 파일을 갈아엎어 주기 때문이다 —
#   그 가드가 없으면 여기가 아니라 샘플러가 동결돼 rc 2 가 영구화된다(그래서 둘은 한 쌍이다).
tt_cpu_busy() {
    local sid="${1:-}" pid="${2:-0}" now="${3:-}" f cpid ts1 cs1 ts2 cs2 win minwin oldcs d
    [ -n "$sid" ] || return 2
    case "$pid" in ''|*[!0-9]*) return 2 ;; esac
    [ "$pid" -gt 0 ] || return 2
    f="$STATE/cpu-$sid"
    [ -f "$f" ] || return 2
    cpid=""; ts1=""; cs1=""; ts2=""; cs2=""
    read -r cpid ts1 cs1 ts2 cs2 < "$f" 2>/dev/null || return 2
    case "$cpid" in ''|*[!0-9]*) return 2 ;; esac
    [ "$cpid" = "$pid" ] || return 2
    case "$ts1" in ''|*[!0-9]*) return 2 ;; esac
    case "$cs1" in ''|*[!0-9]*) return 2 ;; esac
    case "${ts2:-}" in ''|*[!0-9]*) ts2=0 ;; esac
    case "${cs2:-}" in ''|*[!0-9]*) cs2=0 ;; esac
    case "$now" in ''|*[!0-9]*) now=$(date +%s) ;; esac
    tt_cpu_read "$pid" || return 2
    # 최소 창 = max(MINWIN, 분해능/임계값). 분해능이 1초(ps)면 유휴 프로세스가 눈금 하나를 넘기는
    # 순간 3초 창에서 33 cs/s 로 읽혀 오탐이 난다 → 그때만 창을 20초로 늘린다.
    minwin=$TT_CPU_MINWIN
    if [ "${TT_CPU_Q:-1}" -gt 1 ] && [ "$TT_CPU_MINWIN_COARSE" -gt "$minwin" ]; then
        minwin=$TT_CPU_MINWIN_COARSE
    fi
    oldcs=""
    win=$(( now - ts1 ))
    if [ "$win" -ge "$minwin" ] && [ "$win" -le "$TT_CPU_MAXWIN" ]; then
        oldcs=$cs1                                  # 최신 표본으로 충분히 긴 창이 선다
    elif [ "$ts2" -gt 0 ]; then
        win=$(( now - ts2 ))                        # 최신이 너무 어리다 → 이전 표본으로 창을 넓힌다
        if [ "$win" -ge "$minwin" ] && [ "$win" -le "$TT_CPU_MAXWIN" ]; then oldcs=$cs2; fi
    fi
    [ -n "$oldcs" ] || return 2
    d=$(( TT_CPU_CS - oldcs ))
    [ "$d" -ge 0 ] || return 2                      # 카운터가 뒤로 갔다 = pid 재사용/리셋
    if [ "$d" -ge $(( TT_CPU_BUSY * win )) ]; then return 0; fi
    return 1
}

# ── 공유 헬퍼 ────────────────────────────────────────────────────────────────
# 세션 이름은 공백·슬래시·정규식 메타를 다 가질 수 있다. 그걸 필드 구분자나 정규식으로 다루면
# 파싱이 깨지거나(상태바 즉사) 엉뚱한 세션이 죽는다 — 아래 헬퍼들이 그 경로를 한 곳에 모은다.
#
# tmux 타깃 표기 규칙 (전 호출부 공통):
#   -t "=이름"    세션 타깃(kill-session·rename-session·switch-client·attach·list-panes -s)
#   -t "=이름:"   pane 타깃(display-message·capture-pane·send-keys) — 콜론이 "그 세션의 현재 창"
#   '='는 정확 일치 요구. 없으면 tmux가 접두 매칭을 해서 'zzhpfx'가 'zzhpfx2'를 집는다(실증) —
#   그 상태로 kill/send-keys가 나가면 엉뚱한 세션이 죽거나 남의 창에 프롬프트가 꽂힌다.
#   pane 타깃에서 콜론을 빼면 '=이름'이 아예 해석되지 않고 조용히 빈 값을 돌려준다(실측).

# finished 변이 직렬화. --status는 상태바가 5초마다 부르는 read-modify-write이고 idle 훅은
# 재작성+append다 — 겹치면 부재중 완료 알림이 조용히 사라진다(lost update, 결정적 재현).
# rc-check와 같은 flock 패턴. fd 9는 프로세스가 죽으면 자동 해제되니 임계구역만 짧게 잡는다.
tt_finished_lock() {
    mkdir -p "$STATE"
    command -v flock >/dev/null 2>&1 || return 0
    exec 9>"$STATE/finished.lock" 2>/dev/null || return 0
    flock 9 2>/dev/null || true
    return 0
}
tt_finished_unlock() { exec 9>&- 2>/dev/null || true; return 0; }

# finished 포맷은 "<ts> <이름>" — ts가 앞, 이름이 마지막 필드다.
#   구포맷("<이름> <ts>")은 `read -r name ts`가 "my proj 1784…"를 name=my/ts=proj로 쪼개
#   $((now-ts))가 set -u/산술 오류로 즉사시켰다. 상태바 뱃지가 통째로 사라지고 poison 라인은
#   파일에 영구 잔존해 다음 실행도 계속 죽었다(치명). 이름을 끝으로 밀면 공백이 몇 개든 안전.
#   읽는 쪽이 구포맷도 받아주도록 여기서 한 번에 정규화하고, 숫자 ts가 없는 줄은 버린다.
#   TT_FIN_SKIP(환경변수)에 이름을 주면 그 세션의 옛 기록을 함께 지운다 — 예전엔 sed 정규식으로
#   지웠는데 이름에 `/`가 있으면 파스 에러(exit 4)가 `|| true`에 삼켜져 중복이 누적됐다.
#   awk 변수 대신 ENVIRON을 쓰는 이유: -v는 값의 백슬래시를 이스케이프로 해석해 이름을 망친다.
TT_FIN_NORM='
    BEGIN { skip = ENVIRON["TT_FIN_SKIP"] }
    {
        if ($1 ~ /^[0-9]+$/)                  { t = $1;  s = $0; sub(/^[0-9]+[ \t]+/, "", s) }
        else if (NF > 1 && $NF ~ /^[0-9]+$/)  { t = $NF; s = $0; sub(/[ \t]+[0-9]+[ \t]*$/, "", s) }
        else next
        if (s != "" && s != skip) print t " " s
    }'

# 정규화(+선택적 제거) 후 제자리 교체. 락을 잡은 쪽에서만 부를 것.
tt_finished_rewrite() {
    local f="$STATE/finished"
    [ -s "$f" ] || return 0
    if TT_FIN_SKIP="${1:-}" awk "$TT_FIN_NORM" "$f" > "$f.tmp" 2>/dev/null; then
        mv -f "$f.tmp" "$f"
    else
        rm -f "$f.tmp"
    fi
    return 0
}

# 훅 파일이 "이 세션의 것"인지 판정. rc 0 = 신뢰 가능, rc 1 = 못 믿음(stale이거나 없음).
#   왜 필요한가: 재부팅하면 tmux는 session id를 $0부터 재발급한다. 죽은 세션의 hook-<id>가 남아
#   있으면 같은 번호를 받은 새 도구 세션이 남의 상태 파일을 물려받아 에이전트로 오분류된다
#   (2026-07-25 실측: lazydocker인 DB·DOCKER가 목록 위쪽 에이전트 그룹에 앉았다).
#   근거는 둘 — 어느 하나만 서면 인정한다:
#     ① 훅이 적어둔 에이전트 pid가 아직 살아 있다 = 그 프로세스가 지금 이 순간의 증거다.
#     ② pid를 못 적었어도(부모 체인 등반 실패 시 0) 기록 시각이 세션 생성 시각 이후다
#        = 이 세션이 생긴 뒤에 쓰인 파일이니 물려받은 게 아니다.
#   세션 생성 시각을 못 얻으면 0으로 접어 예전처럼 관대하게 통과시킨다(판단 근거 없음 → 무해한 쪽).
tt_hook_valid() {
    local hf="$1" created="${2:-0}" hts hpid
    [ -f "$hf" ] || return 1
    hts=0; hpid=0
    # 훅 파일 포맷은 "<상태> <기록시각> <pid>" — 여기서 상태는 안 쓴다(_ 로 버린다)
    read -r _ hts hpid < "$hf" 2>/dev/null || true
    case "${hpid:-0}" in ''|*[!0-9]*) hpid=0 ;; esac
    case "${hts:-0}" in ''|*[!0-9]*) hts=0 ;; esac
    case "${created:-0}" in ''|*[!0-9]*) created=0 ;; esac
    # ① pid를 적었으면 그 생존 여부가 최종 판정이다 — 살았으면 정품, 죽었으면 유령.
    #    시각 비교로 내려가면 안 된다: 재부팅으로 id가 재사용되면 죽은 훅의 기록시각이
    #    그 id를 새로 받은 세션의 생성시각보다 나중일 수 있어, 유령을 정품으로 착각한다
    #    (2026-07-25 hook-6 실측: pid 954169 죽었는데 hts>created라 통과돼 살아남았다).
    if [ "$hpid" -gt 0 ]; then
        kill -0 "$hpid" 2>/dev/null && return 0
        return 1
    fi
    # ② pid를 못 적은 경우(부모 체인 등반 실패 → 0)만 시각으로 폴백한다
    [ "$hts" -ge "$created" ] && return 0
    return 1
}

# 에이전트 세션 판정(claude/codex가 도는 세션). 인자는 세션 id($3…) 또는 세션 이름.
#   두 번째 인자로 session_created를 넘길 수 있다 — 이미 알고 있는 호출부(--list)는 tmux를
#   한 번 덜 부른다. 안 넘기면 여기서 묻는다.
#   기준: 이 세션 것이 확실한 훅 파일 ∨ 어느 pane에든 claude|codex — --list 그룹 판정과 같은 기준.
#   같은 판정이 여러 곳에 흩어져 있으면 "목록엔 도구인데 브로드캐스트 키는 날아가는" 사고가 난다.
tt_is_agent() {
    local t="${1:-}" created="${2:-}" sid c2
    [ -n "$t" ] || return 1
    case "$t" in
        \$[0-9]*)               # 세션 id는 그 자체로 유일 — = 접두 불필요(붙이면 오히려 안 잡힘)
            sid="$t"
            [ -n "$created" ] || created=$(tmux display-message -p -t "$sid" '#{session_created}' 2>/dev/null) || created="" ;;
        *)
            IFS=$'\t' read -r sid c2 < <(tmux display-message -p -t "=$t:" $'#{session_id}\t#{session_created}' 2>/dev/null) || return 1
            [ -n "$created" ] || created="$c2" ;;
    esac
    [ -n "$sid" ] || return 1
    tt_hook_valid "$STATE/hook-${sid#\$}" "${created:-0}" && return 0
    tmux list-panes -s -t "$sid" -F '#{pane_current_command}' 2>/dev/null | grep -qxE 'claude|codex'
}

# 브로드캐스트 실사 — 에이전트 세션에만 주입한다.
#   도구 세션(yazi·lazydocker·맨셸)에 프롬프트를 치면 문장이 셸 명령으로 실행되거나 TUI 단축키로
#   먹힌다(lazydocker에서 r=restart). 안전사고 경로라 조용히 넘기지 말고 스킵 사실을 보여준다.
tt_broadcast() {
    local msg="$1" s sent=0 skipped=0 names=""
    shift
    for s in "$@"; do
        [ -n "$s" ] || continue
        # 구분선 줄은 세션이 아니다 — 마지막 방어선이라 여기서도 턴다.
        case "$s" in ─*) continue ;; esac
        if ! tt_is_agent "$s"; then
            skipped=$((skipped + 1)); names="$names $s"; continue
        fi
        tmux send-keys -t "=$s:" -l "$msg"
        tmux send-keys -t "=$s:" Enter
        sent=$((sent + 1))
    done
    printf '→ sent to %d sessions\n' "$sent"
    [ "$skipped" -gt 0 ] && printf '  skipped %d tool sessions:%s\n' "$skipped" "$names"
    return 0
}

# 고아·유령 hook 파일 sweep. 두 종류를 다 잡는다:
#   ① 고아  — 이제 존재하지 않는 session id의 파일.
#   ② 유령  — id는 살아있지만 그 파일이 '지금 그 세션의 것이 아닌' 경우.
#      재부팅 후 tmux는 session id를 $0부터 재발급한다 → 새 세션이 죽은 세션의 상태 파일을
#      그대로 물려받는다. ①만 지우던 시절엔 이게 통째로 살아남아 도구 세션이 에이전트로
#      오분류됐다(실측). 판정은 tt_is_agent와 같은 tt_hook_valid 한 곳을 쓴다 —
#      "지우는 기준"과 "믿는 기준"이 갈라지면 지웠는데 또 믿는 모순이 생긴다.
#   살아있는 id 목록을 못 얻으면 sweep 생략(안전). boot 훅과 --restore가 공유한다.
tt_sweep_hooks() {
    local live lsout sid created hf id
    lsout=$(tmux ls -F $'#{session_id}\t#{session_created}' 2>/dev/null) || return 0
    [ -n "$lsout" ] || return 0
    # id → created 조회표를 한 줄 문자열로 (연관배열은 bash 4 전용 — 맥 기본 3.2에서 깨진다)
    live=" "
    while IFS=$'\t' read -r sid created; do
        [ -n "$sid" ] || continue
        live="$live${sid#\$}=${created:-0} "
    done <<< "$lsout"
    #   CPU 스냅샷(cpu-<id>)도 같이 지운다 — 훅 파일의 수명에 종속시켜야 "지웠는데 또 믿는"
    #   모순이 안 난다. 접두사가 달라 위 hook-* 글롭에는 안 걸린다.
    for hf in "$STATE"/hook-*; do
        [ -f "$hf" ] || continue
        id=${hf##*/hook-}
        case "$live" in
            *" $id="*)
                created=${live#*" $id="}; created=${created%% *}
                tt_hook_valid "$hf" "${created:-0}" || rm -f "$hf" "$STATE/cpu-$id" ;;   # ② 유령
            *) rm -f "$hf" "$STATE/cpu-$id" ;;                                           # ① 고아
        esac
    done
    # 마지막 프롬프트(last-<id>)도 같이 쓴다. **판정을 따로 만들지 않는다** — 위 루프가 방금
    #   같은 기준으로 훅 파일을 정리했으니, "이 id 의 훅 파일이 아직 서 있나" 한 줄이 곧 같은
    #   판정이다. 두 벌로 나누면 재부팅 후 session id 재사용 때 기준이 어긋나 죽은 세션의
    #   프롬프트가 새 세션 프리뷰 맨 위에 걸린다 — hook-*/cpu-* 에서 이미 겪은 사고다.
    #   (쓰기 중인 tmp 는 .last-<id>.<pid> 라 이 글롭에 안 걸린다)
    for hf in "$STATE"/last-*; do
        [ -f "$hf" ] || continue
        id=${hf##*/last-}
        case "$live" in
            *" $id="*)
                created=${live#*" $id="}; created=${created%% *}
                tt_hook_valid "$STATE/hook-$id" "${created:-0}" || rm -f "$hf" ;;
            *) rm -f "$hf" ;;
        esac
    done
    # 쓰다 만 조각(.last-<id>.<pid>) 회수. 위 글롭이 점 파일을 안 잡으니 여기서 한 번 더 돈다.
    #   조각은 훅이 mv 에 닿기 전에 죽었을 때만 남는다(SIGKILL·디스크 가득). 판정은 이름에
    #   박힌 pid 다 — 그 프로세스가 없으면 이 조각은 영영 완성되지 않는다. **살아있는 pid 는
    #   건드리지 않는다**: 지금 쓰는 중일 수 있고, 지우면 mv 가 실패해 그 프롬프트가 통째로
    #   유실된다. kill -0 은 내장이라 포크가 안 는다.
    for hf in "$STATE"/.last-*; do
        [ -f "$hf" ] || continue
        id=${hf##*.}
        case "$id" in ''|*[!0-9]*) rm -f "$hf"; continue ;; esac   # pid 자리가 아니다 = 우리 것이 아니다
        kill -0 "$id" 2>/dev/null || rm -f "$hf"
    done
    return 0
}

# JSON 얕은 문자열 값 → 전역 TT_JV (rc_val과 같은 규칙, 다만 포크 0).
#   훅 경로에서 $(rc_val …)을 부르면 이벤트마다 서브셸이 더 뜬다 — 훅은 초당 여러 번 불리니
#   여기서만은 표준출력 대신 전역으로 돌려준다. (rc 판정부는 그대로 rc_val을 쓴다)
tt_jv() {
    TT_JV=""
    local re="\"$2\"[[:space:]]*:[[:space:]]*\"([^\"]*)\""
    [[ "$1" =~ $re ]] || return 1
    TT_JV="${BASH_REMATCH[1]}"
    return 0
}

