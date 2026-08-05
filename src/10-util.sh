# ── 이식성 헬퍼 (macOS/BSD ↔ 리눅스) ────────────────────────────────────────
# 프로세스 이름 한 조각. macOS의 ps는 comm에 실행파일 '절대경로'를 준다(리눅스는 basename뿐) →
# 마지막 경로 조각만 남겨야 양쪽에서 똑같이 "claude"로 비교된다. -p/-o comm= 자체는 POSIX.
tt_comm() {
    local c
    c=$(ps -p "${1:-0}" -o comm= 2>/dev/null) || return 1
    c=${c##*/}
    printf '%s' "$c"
}

# bash 3.2(맥 기본 /bin/bash)의 read는 소수점 timeout을 거부한다("invalid timeout specification").
# 소수점 대기가 필요한 곳은 여기 한 곳에서 갈라 쓴다 — 4.x면 흡수, 3.2면 흡수 포기(1초 멈춤 방지).
if [ "${BASH_VERSINFO[0]:-3}" -ge 4 ]; then TT_TINY_READ=1; else TT_TINY_READ=0; fi

# 로그 회전 — hook.log는 하루 ~1600줄이 SD카드에 상시 append된다. 임계 초과 시 꼬리만 남기고 자른다.
#   크기 측정은 `wc -c <파일`(POSIX) — stat은 GNU가 -c, BSD가 -f로 옵션이 정반대다.
#   호출 지점은 --cron(1분)·boot 훅·--boot-restore뿐 — 이벤트마다 부르면 훅 경로에 포크가 하나 더 붙는다.
#   회전할 파일은 TT_LOG_FILE로 갈아끼운다(--boot-restore의 boot.log). 기본값은 예전 그대로
#   hook.log라 기존 호출부는 한 글자도 안 바뀐다 — 회전 정책을 두 벌로 나눌 이유가 없다.
#   인자가 아니라 환경변수 프리픽스로 넘기는 건 tt_fin_norm의 TT_FIN_SKIP과 같은 관례다.
#
#   임계 바이트는 설정 키 log_max 다. 예전엔 여기서 `TT_LOG_MAX=${TT_LOG_MAX:-1048576}` 로
#   전역을 세웠는데, 그 한 줄이 두 가지를 망가뜨렸다:
#     ① 설정 파일에 log_max 를 써도 이 전역이 이미 서 있어 아무 효과가 없었다.
#     ② 하필 그 전역 이름이 log_max 의 환경변수 이름(TT_LOG_MAX)이라, 이후 모든 조회가
#        "env 가 이긴다"로 판정됐다 — 설정 화면이 log_max 토글을 아예 거절했다.
#   그래서 전역을 없애고 회전이 실제로 필요한 순간에만 읽는다. 환경변수 우선순위는
#   조회 함수가 이미 지킨다(TT_LOG_MAX=… 는 여전히 이긴다). 파일이 없으면 조회조차 안 해서
#   훅 경로의 포크는 예전 그대로 0이다.
#   ⚠ 회전을 부르는 진입점은 설정 캐시를 서브셸 아닌 맨 statement 로 먼저 세워둬야 한다
#      (05-config.sh 의 계약) — 아래 조회는 $(...) 안이라 캐시가 이 함수 밖으로 안 나간다.
TT_LOG_KEEP=${TT_LOG_KEEP:-2000}
tt_log_rotate() {
    local f="${TT_LOG_FILE:-$STATE/hook.log}" sz max
    [ -f "$f" ] || return 0
    sz=$(wc -c < "$f" 2>/dev/null | tr -d ' ') || return 0
    case "${sz:-0}" in ''|*[!0-9]*) return 0 ;; esac
    max=$(tt_conf_num log_max)
    [ "$sz" -gt "$max" ] || return 0
    if tail -n "$TT_LOG_KEEP" "$f" > "$f.tmp" 2>/dev/null; then
        mv -f "$f.tmp" "$f" 2>/dev/null || { rm -f "$f.tmp"; return 0; }
        echo "$(date '+%F %T') - ${f##*/} rotated (was $sz bytes)" >> "$f"
    else
        rm -f "$f.tmp"
    fi
    return 0
}

