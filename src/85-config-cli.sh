# ── 설정 CLI ────────────────────────────────────────────────────────────────
# 재매핑을 막는 키. 잘못 밟아도 나갈 수 있는 문 하나는 늘 열어둔다.
TT_CONF_RESERVED='esc enter left'

# 팝업 안에서 fzf 가 받는 키 이름인가(부분집합 화이트리스트).
# 여기 없는 이름을 넘기면 fzf 가 기동 자체를 거부해 관제탑이 안 뜬다 — 그래서 미리 막는다.
tt_conf_is_fzf_key() {
    case "${1:-}" in
        ctrl-[a-z]|alt-[a-z0-9]) return 0 ;;
        f[1-9]|f1[0-2]) return 0 ;;
        tab|btab|home|end|pgup|pgdn|del|ins|up|down|left|right|enter|esc|space) return 0 ;;
        ?) return 0 ;;      # '?' 같은 출력 가능한 한 글자
        *) return 1 ;;
    esac
}

# tmux 가 받는 키 이름인가. key_summon(한 개)·key_summon_fast(공백 목록)에 쓴다.
tt_conf_is_tmux_key() {
    case "${1:-}" in
        ''|*[!A-Za-z0-9C\-M\ ]*) return 1 ;;
    esac
    return 0
}

# 유효성 검사. rc 1 이면 stderr 에 사유가 찍힌다.
tt_conf_validate() {
    local k="${1:-}" v="${2:-}" other ov
    tt_conf_default "$k" >/dev/null 2>&1 || { echo "모르는 키: $k" >&2; return 1; }
    case "$k" in
        rc|snapshot|snapshot_on_exit|boot_restore)
            case "$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')" in
                on|off|1|0|true|false|yes|no) ;;
                *) echo "$k 는 on|off 여야 한다 (받은 값: $v)" >&2; return 1 ;;
            esac ;;
        recent_hours|unseen_minutes|log_max)
            case "$v" in ''|*[!0-9]*) echo "$k 는 양의 정수여야 한다 (받은 값: $v)" >&2; return 1 ;; esac
            [ "$v" -gt 0 ] || { echo "$k 는 0보다 커야 한다" >&2; return 1; } ;;
        accent)
            case "$v" in ''|*[!0-9]*) echo "accent 는 0~255 정수여야 한다 (받은 값: $v)" >&2; return 1 ;; esac
            [ "$v" -le 255 ] || { echo "accent 는 0~255 여야 한다 (받은 값: $v)" >&2; return 1; } ;;
        key_summon)
            tt_conf_is_tmux_key "$v" || { echo "key_summon 은 tmux 키 이름이어야 한다 (예: F, C-Left)" >&2; return 1; } ;;
        key_summon_fast)
            for ov in $v; do
                tt_conf_is_tmux_key "$ov" || { echo "key_summon_fast 의 '$ov' 는 tmux 키 이름이 아니다" >&2; return 1; }
            done ;;
        key_*)
            for ov in $TT_CONF_RESERVED; do
                [ "$v" = "$ov" ] && { echo "$v 는 예약키라 재매핑할 수 없다 (닫기·진입은 늘 열려 있어야 한다)" >&2; return 1; }
            done
            tt_conf_is_fzf_key "$v" || { echo "fzf 가 아는 키 이름이 아니다: $v (예: ctrl-n, alt-x, f2)" >&2; return 1; }
            # 충돌 — 같은 키를 이미 쓰는 다른 액션이 있나
            for other in $TT_CONF_KEYS; do
                case "$other" in key_summon|key_summon_fast|"$k") continue ;; key_*) ;; *) continue ;; esac
                if [ "$(tt_conf_get "$other")" = "$v" ]; then
                    echo "$v 는 이미 $other 가 쓰고 있다" >&2; return 1
                fi
            done ;;
    esac
    return 0
}

# 원자적 쓰기. 있는 줄은 값만 교체하고, 없으면 끝에 붙인다(주석·순서 보존).
tt_conf_write() {
    local k="${1:-}" v="${2:-}" mode="${3:-set}" tmp line seen=0
    mkdir -p "${TT_CONF%/*}" 2>/dev/null || true
    tmp="$TT_CONF.tmp.$$"
    : > "$tmp" || { echo "설정 파일을 쓸 수 없다: $TT_CONF" >&2; return 1; }
    if [ -f "$TT_CONF" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in
                "$k"=*)
                    seen=1
                    [ "$mode" = set ] && printf '%s=%s\n' "$k" "$v" >> "$tmp"
                    ;;
                *) printf '%s\n' "$line" >> "$tmp" ;;
            esac
        done < "$TT_CONF"
    fi
    if [ "$mode" = set ] && [ "$seen" = 0 ]; then printf '%s=%s\n' "$k" "$v" >> "$tmp"; fi
    mv -f "$tmp" "$TT_CONF" || { rm -f "$tmp"; return 1; }
    return 0
}

# 값이 바뀐 키가 tmux 스니펫에 박히는 키면 스니펫을 다시 쓴다.
#   왜 자기 자신을 다시 부르나: 렌더 함수는 87-tmux-conf.sh 에 있고 그 파일은 이 파일보다
#   뒤에 이어붙는다. 게다가 `tt config …` 는 아래 블록에서 exit 하므로 87 까지 실행이 가지
#   않는다 — 이 프로세스에는 tt_tmux_conf_write 라는 이름이 아예 없다. 파일 순서를 뒤집는
#   것보다 이미 20군데에서 쓰는 $SELF 재호출 관례를 따르는 편이 안전하다.
#   실패해도 삼킨다: 스니펫을 못 썼다고 설정 저장까지 실패로 만들면, 이미 파일에 들어간
#   값과 종료코드가 어긋난다. 설정은 저장됐고 스니펫은 다음 --tmux-conf 때 따라잡는다.
tt_conf_resnip() {
    case "${1:-}" in
        key_summon|key_summon_fast|snapshot_on_exit)
            "$SELF" --tmux-conf --write >/dev/null 2>&1 || true ;;
    esac
    return 0
}

if [ "${1:-}" = "config" ]; then
    # 아래 각 하위명령은 TT_CONF_KEYS 를 훑으며 tt_conf_get/tt_conf_source 를 여러 번
    # $(...) 로 감싸 부른다 — 각 호출이 서브셸이라, 여기서 tt_conf_load 를 맨 statement 로
    # 먼저 태워두지 않으면 매 서브셸이 TT_CONF_LOADED=0 을 새로 물려받아 설정 파일을 키
    # 개수만큼 다시 파싱하고 깨진 줄 경고도 그만큼 반복한다(고침 라운드 1이 잡았던 바로 그 버그).
    tt_conf_load
    case "${2:-}" in
        ''|list)
            printf '%-18s %-14s %s\n' 'KEY' 'VALUE' 'SOURCE'
            for k in $TT_CONF_KEYS; do
                printf '%-18s %-14s %s\n' "$k" "$(tt_conf_get "$k")" "$(tt_conf_source "$k")"
            done
            exit 0 ;;
        get|source)
            [ -n "${3:-}" ] || { echo "usage: tt config $2 <key>" >&2; exit 1; }
            if [ "$2" = get ]; then tt_conf_get "$3" || { echo "모르는 키: $3" >&2; exit 1; }
            else                    tt_conf_source "$3" || { echo "모르는 키: $3" >&2; exit 1; }
            fi
            echo
            exit 0 ;;
        set)
            [ -n "${3:-}" ] || { echo "usage: tt config set <key> <value>" >&2; exit 1; }
            shift 2; k=$1; shift
            v="$*"
            tt_conf_validate "$k" "$v" || exit 1
            tt_conf_write "$k" "$v" set || exit 1
            tt_conf_resnip "$k"
            printf '%s=%s\n' "$k" "$v"
            exit 0 ;;
        unset)
            [ -n "${3:-}" ] || { echo "usage: tt config unset <key>" >&2; exit 1; }
            tt_conf_default "$3" >/dev/null 2>&1 || { echo "모르는 키: $3" >&2; exit 1; }
            tt_conf_write "$3" '' unset || exit 1
            tt_conf_resnip "$3"
            printf '%s → 기본값 %s\n' "$3" "$(tt_conf_default "$3")"
            exit 0 ;;
        path)
            printf '%s\n' "$TT_CONF"; exit 0 ;;
        *)
            echo "usage: tt config [list|get|source|set|unset|path]" >&2; exit 1 ;;
    esac
fi
