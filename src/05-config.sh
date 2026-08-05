# ── 설정 ────────────────────────────────────────────────────────────────────
# 우선순위: 환경변수 > 설정 파일 > 코드 기본값.
#
# 이 파일을 절대 `source` 하지 않는 이유: 훅이 이벤트마다, cron 이 1분마다 읽는 경로다.
# source 라면 사용자가 오타 한 줄만 넣어도 그 순간부터 함대 관제 전체가 조용히 죽는다.
# 그래서 화이트리스트 파서로만 읽는다 — 아는 키의, 아는 모양의 줄만 통과시킨다.
TT_CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/fleetmux"
TT_CONF="${TT_CONF_FILE:-$TT_CONF_DIR/config}"

# 알려진 키. 이 순서가 곧 `tt config` 목록 출력 순서다.
TT_CONF_KEYS='rc snapshot snapshot_on_exit boot_restore recent_hours unseen_minutes accent log_max key_new key_rename key_kill key_reload key_detach key_broadcast key_help key_settings key_summon key_summon_fast'

# 기본값. 모르는 키면 rc 1 — "알려진 키인가" 판정도 이 함수가 겸한다.
tt_conf_default() {
    case "${1:-}" in
        rc|snapshot|snapshot_on_exit|boot_restore) printf 'on' ;;
        recent_hours)    printf '6' ;;
        unseen_minutes)  printf '10' ;;
        accent)          printf '73' ;;
        log_max)         printf '1048576' ;;
        key_new)         printf 'ctrl-n' ;;
        key_rename)      printf 'ctrl-e' ;;
        key_kill)        printf 'ctrl-x' ;;
        key_reload)      printf 'ctrl-r' ;;
        key_detach)      printf 'ctrl-d' ;;
        key_broadcast)   printf 'ctrl-b' ;;
        key_help)        printf '?' ;;
        key_settings)    printf 'ctrl-o' ;;
        key_summon)      printf 'F' ;;
        key_summon_fast) printf '' ;;
        *) return 1 ;;
    esac
    return 0
}

# 키 → 환경변수 이름. bash 3.2 에는 ${var^^} 가 없다 → tr 로 올린다.
tt_conf_envname() {
    printf 'TT_%s' "$(printf '%s' "${1:-}" | tr '[:lower:]' '[:upper:]')"
}

# 설정 파일을 프로세스당 한 번만 읽는다 — 매 조회마다 통째로 다시 훑으면, 훅이 이벤트마다
# cron 이 1분마다 도는 이 경로에서 깨진 줄 하나가 조회한 키 수만큼 같은 경고를 반복해
# hook.log 를 계속 채운다(고침 라운드 1 지적: 4개 키 조회 = 같은 경고 4번). 그래서
# 두 번째 호출부터는 즉시 반환한다 — 디자인 문서의 "읽기는 매 진입점 시작 시 1회
# (tt_conf_load)" 를 그대로 구현한 것. ("파일은 열 줄 미만이라 캐시하지 않는다"는 디스크에
# 캐시 파일을 만들지 않는다는 뜻이지, 프로세스 안에서 값을 기억하지 말라는 뜻이 아니다.)
#
#   알려진 키마다 TT_CONF_V_<key>(값)·TT_CONF_S_<key>(파일에 있었다는 표식, 빈 값과 구분
#   하기 위해 값과 별도로 둔다)에 담는다. bash 3.2 엔 연관 배열이 없어 변수명을 동적으로
#   조립한다(eval) — 그래서 이 변수명 자리에 들어가는 키는 반드시 tt_conf_default 화이트
#   리스트를 통과한 것만 써야 한다(그 앞단인 tt_conf_file_get 이 검사한다).
#
#   주의(중요 — 호출부 계약): 이 함수는 명령치환(subshell) 안에서 부르면 캐시가 그
#   subshell 안에서만 세워지고 밖으로 못 나온다 — bash 는 subshell 의 변수 변경을 부모
#   프로세스로 절대 되돌리지 않는다. 그래서 "한 프로세스 안 여러 조회에 경고가 한 번만"을
#   보장하려면, 그 프로세스의 진입점이 `v=$(...)` 로 감싸지 않은 맨 statement 로
#   tt_conf_load 를 한 번 불러둬야 한다 — 아래 `config get/source` 진입점이 그렇게 한다.
#   (단일 조회만 하는 호출부는 이 걱정을 할 필요 없다 — tt_conf_get/tt_conf_source 가
#   내부에서 알아서 한 번 부른다.)
TT_CONF_LOADED=0
tt_conf_load() {
    [ "$TT_CONF_LOADED" = 1 ] && return 0
    TT_CONF_LOADED=1
    # -r 이지 -f 가 아니다. 파일이 있는데 못 읽으면(퍼미션·ACL) 아래 `done < "$TT_CONF"` 의
    # 리다이렉트가 실패하고, set -e 가 그걸 물어 프로세스가 통째로 죽는다 — 크론(매분)과
    # @reboot 부팅복원이 이유도 안 남기고 즉사한다. 못 읽으면 그냥 기본값으로 간다.
    [ -r "$TT_CONF" ] || return 0
    local line k v
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ''|'#'*|' '*'#'*) continue ;; esac
        # key=value 모양인가 — '=' 이 아예 없는 줄도 무시하되, 예전엔 여기서 경고 없이
        # 조용히 넘어갔다(고침 라운드 1 지적 2). 다른 무시 사유처럼 한 줄 경고를 낸다.
        case "$line" in
            *=*) ;;
            *) printf 'fleetmux: %s 의 줄 무시 — key=value 모양이 아니다: %s\n' "$TT_CONF" "$line" >&2; continue ;;
        esac
        k=${line%%=*}
        v=${line#*=}
        # 키 모양 검사
        case "$k" in
            ''|*[!a-z0-9_]*) printf 'fleetmux: %s 의 줄 무시 — 키 모양이 아니다: %s\n' "$TT_CONF" "$line" >&2; continue ;;
        esac
        # 알려진 키인가
        if ! tt_conf_default "$k" >/dev/null 2>&1; then
            printf 'fleetmux: %s 의 줄 무시 — 모르는 키: %s\n' "$TT_CONF" "$k" >&2
            continue
        fi
        # 값 문자셋 검사
        case "$v" in
            *[!0-9A-Za-z_./:+\ -]*) printf 'fleetmux: %s 의 줄 무시 — 값에 허용 안 된 글자: %s\n' "$TT_CONF" "$line" >&2; continue ;;
        esac
        eval "TT_CONF_V_$k=\$v"   # 마지막에 쓴 줄이 이긴다 — 그냥 덮어쓴다
        eval "TT_CONF_S_$k=1"
    done < "$TT_CONF"
    return 0
}

# 캐시(tt_conf_load)에서 한 키를 읽는다. 없으면 rc 1.
tt_conf_file_get() {
    local want="${1:-}" have
    tt_conf_default "$want" >/dev/null 2>&1 || return 1   # eval에 꽂기 전 화이트리스트 재확인(주입 방지)
    tt_conf_load
    eval "have=\${TT_CONF_S_$want+set}"
    [ "${have:-}" = set ] || return 1
    eval "printf '%s' \"\$TT_CONF_V_$want\""
    return 0
}

# 유효값. 모르는 키면 rc 1.
tt_conf_get() {
    local k="${1:-}" envn v
    tt_conf_default "$k" >/dev/null 2>&1 || return 1
    envn=$(tt_conf_envname "$k")
    eval "v=\${$envn+set}"
    if [ "${v:-}" = set ]; then eval "printf '%s' \"\$$envn\""; return 0; fi
    if v=$(tt_conf_file_get "$k"); then printf '%s' "$v"; return 0; fi
    tt_conf_default "$k"
}

# 수를 쓰는 키를 산술에 넣어도 안전한 형태로 읽는다. 모르는 키면 rc 1.
#   왜 따로 두나: 위 화이트리스트 파서는 값의 **문자셋**만 본다. `recent_hours=6h` 는 통과한다.
#   그 값이 그대로 $(( … )) 로 들어가면 산술 구문 오류가 나고, set -e 가 그걸 물어 --list 나
#   --status 를 통째로 죽인다 — 손으로 고친 설정 한 줄이 관제탑을 못 뜨게 하면 안 된다.
#   또 하나: `08` 은 문자셋 검사를 통과하지만 bash 산술에선 8진수라 "value too great for base"
#   로 즉사한다. 그래서 통과한 값도 10#… 으로 한 번 정규화해서 내보낸다.
#   두 번째 인자는 상한(선택) — accent 처럼 값이 이스케이프 시퀀스 안으로 들어가는 키에 쓴다.
#   기본값으로 돌아갈 땐 조용히 넘어가지 않고 한 줄 말한다(파서의 무시 경고와 같은 규율).
tt_conf_num() {
    local k="${1:-}" max="${2:-}" v ok=1
    v=$(tt_conf_get "$k") || return 1
    case "$v" in ''|*[!0-9]*) ok=0 ;; esac
    if [ "$ok" = 1 ] && [ -n "$max" ] && [ "$(( 10#$v ))" -gt "$max" ]; then ok=0; fi
    if [ "$ok" = 0 ]; then
        printf 'fleetmux: %s 의 값을 쓸 수 없다 — 기본값으로 간다: %s\n' "$k" "$v" >&2
        v=$(tt_conf_default "$k")
    fi
    printf '%s' "$(( 10#$v ))"
    return 0
}

# 값이 어디서 왔나 — env | file | default
tt_conf_source() {
    local k="${1:-}" envn v
    tt_conf_default "$k" >/dev/null 2>&1 || return 1
    envn=$(tt_conf_envname "$k")
    eval "v=\${$envn+set}"
    if [ "${v:-}" = set ]; then printf 'env'; return 0; fi
    if tt_conf_file_get "$k" >/dev/null 2>&1; then printf 'file'; return 0; fi
    printf 'default'
}

# 불린 키가 켜져 있나. on/1/true/yes 를 켜짐으로 본다(대소문자 무시).
tt_conf_on() {
    local v
    v=$(tt_conf_get "${1:-}") || return 1
    case "$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')" in
        on|1|true|yes) return 0 ;;
        *) return 1 ;;
    esac
}
