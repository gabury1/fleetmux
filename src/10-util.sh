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
TT_LOG_MAX=${TT_LOG_MAX:-1048576}
TT_LOG_KEEP=${TT_LOG_KEEP:-2000}
tt_log_rotate() {
    local f="${TT_LOG_FILE:-$STATE/hook.log}" sz
    [ -f "$f" ] || return 0
    sz=$(wc -c < "$f" 2>/dev/null | tr -d ' ') || return 0
    case "${sz:-0}" in ''|*[!0-9]*) return 0 ;; esac
    [ "$sz" -gt "$TT_LOG_MAX" ] || return 0
    if tail -n "$TT_LOG_KEEP" "$f" > "$f.tmp" 2>/dev/null; then
        mv -f "$f.tmp" "$f" 2>/dev/null || { rm -f "$f.tmp"; return 0; }
        echo "$(date '+%F %T') - ${f##*/} rotated (was $sz bytes)" >> "$f"
    else
        rm -f "$f.tmp"
    fi
    return 0
}

