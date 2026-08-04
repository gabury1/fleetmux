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

# 설정 파일에서 한 키를 읽는다. 없으면 rc 1.
#   통과 조건: 키가 알려진 목록에 있고, 줄 모양이 `key=value` 이며,
#   값이 [0-9A-Za-z_./:+ -] 로만 이뤄진다(공백 허용 — key_summon_fast 가 목록이다).
tt_conf_file_get() {
    local want="${1:-}" line k v found=1 out=''
    [ -f "$TT_CONF" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ''|'#'*|' '*'#'*) continue ;; esac
        case "$line" in *=*) ;; *) continue ;; esac
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
        if [ "$k" = "$want" ]; then out=$v; found=0; fi   # 마지막에 쓴 줄이 이긴다
    done < "$TT_CONF"
    [ "$found" = 0 ] || return 1
    printf '%s' "$out"
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

# 설정 조회 진입점(최소). 나머지 하위명령은 85-config-cli.sh 가 맡는다.
if [ "${1:-}" = "config" ] && { [ "${2:-}" = "get" ] || [ "${2:-}" = "source" ]; }; then
    [ -n "${3:-}" ] || { echo "usage: tt config ${2} <key>" >&2; exit 1; }
    if [ "$2" = get ]; then tt_conf_get "$3" || { echo "모르는 키: $3" >&2; exit 1; }
    else                    tt_conf_source "$3" || { echo "모르는 키: $3" >&2; exit 1; }
    fi
    echo
    exit 0
fi
