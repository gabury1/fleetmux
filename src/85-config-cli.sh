# ── 설정 CLI ────────────────────────────────────────────────────────────────
# 재매핑을 막는 키. 잘못 밟아도 나갈 수 있는 문 하나는 늘 열어둔다.
TT_CONF_RESERVED='esc enter left'

# ── "이 키가 실제 동작에 물려 있나" — 목록에 손으로 적지 않고 코드에서 뽑는다 ──────
# 값은 저장되는데 아무도 안 읽는 키는 **거짓말하는 토글**이다. 사용자는 자기가 끈 기능이
# 꺼진 줄 안다. 그래서 설정을 보여주는 두 화면(`tt config list`·팝업 설정화면)은 그런 키에
# 표시를 붙인다.
#
# 그 목록을 손으로 적으면 반드시 어긋난다 — 키를 코드에 무는 사람과 목록을 고치는 사람이
# 같은 순간에 같은 파일을 열지 않기 때문이다(실제로 T6 이 세 키를 물리며 목록을 따로 고쳐야
# 했다). 그래서 판정 근거를 코드 자체로 옮긴다: 합쳐진 스크립트(=자기 자신)에서
# **키 이름을 리터럴로 넘기는 조회 호출**을 찾는다. 조회 함수에 리터럴 키를 넘기는 곳이
# 있다 = 누군가 그 값을 읽고 행동을 바꾼다.
#
#   찾는 모양: 조회 함수 이름(get/on/num) + 공백 + 소문자 키 이름
#   안 걸리는 것: 루프의 동적 조회("$k" 같은 변수 인자), 키를 그냥 나열하는 case 패턴,
#                한글 주석 안의 함수 이름(뒤따르는 글자가 [a-z] 가 아니라 안 걸린다)
#
# ⚠ 뒤집어 말하면, 주석에 조회 호출을 리터럴 키와 함께 예시로 적으면 그 키가 배선된 것으로
#   보인다. 예시를 적을 땐 키 자리를 <키> 처럼 쓸 것. 이 판정이 실제 배선과 맞는지는
#   test/t-07-config-view.sh 가 키 이름과 개수로 못박아 지킨다.
TT_CONF_WIRED_AWK='
    {
        s = $0
        while (match(s, /tt_conf_(get|on|num)[ \t]+[a-z][a-z0-9_]*/)) {
            t = substr(s, RSTART, RLENGTH)
            sub(/^[a-z_]+[ \t]+/, "", t)
            if (!(t in seen)) { seen[t] = 1; printf "%s ", t }
            s = substr(s, RSTART + RLENGTH)
        }
    }'
TT_CONF_WIRED_LIST=''
TT_CONF_WIRED_SCANNED=0
tt_conf_wired_scan() {
    [ "$TT_CONF_WIRED_SCANNED" = 1 ] && return 0
    TT_CONF_WIRED_SCANNED=1                      # 실패해도 다시 시도하지 않는다 — 포크 1회로 못박는다
    local out=''
    [ -r "$SELF" ] || return 0
    out=$(awk "$TT_CONF_WIRED_AWK" "$SELF" 2>/dev/null) || out=''
    [ -n "$out" ] || return 0
    TT_CONF_WIRED_LIST=" $out"                   # 앞뒤 공백 포함 — case 글롭으로 정확히 한 단어를 본다
    return 0
}
tt_conf_wired() {
    tt_conf_wired_scan
    # 자기 자신을 못 읽었다 = 판정할 근거가 없다. 그럴 땐 아무 표시도 하지 않는다 —
    # 전부 "미배선"으로 칠하는 쪽이 훨씬 큰 거짓말이다.
    [ -n "$TT_CONF_WIRED_LIST" ] || return 0
    case "$TT_CONF_WIRED_LIST" in *" ${1:-} "*) return 0 ;; esac
    return 1
}

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

# 손으로 고친 무효값의 "실제 동작"을 한 줄로. 유효하면 아무것도 안 찍는다.
#   `tt config set` 은 무효값을 거절하지만 README:168 은 파일 손편집도 정상 경로로 안내한다 —
#   그 경로로 들어온 값은 소비자마다 다르게 접힌다(숫자는 기본값으로, 불린은 꺼짐으로,
#   소환키는 스니펫에서 빠짐). 표가 그 값을 실효값처럼 보여주면 두 화면이 서로 다른 진실을
#   말하게 된다(권고 N4). 검증은 이미 있는 tt_conf_validate 를 그대로 쓰고 사유만 삼킨다.
tt_conf_lie() {
    tt_conf_validate "${1:-}" "${2:-}" 2>/dev/null && return 0
    case "${1:-}" in
        rc|snapshot|snapshot_on_exit|boot_restore)  printf '← 무효값 · 꺼짐으로 돈다' ;;
        recent_hours|unseen_minutes|accent|log_max) printf '← 무효값 · 기본값 %s 로 돈다' "$(tt_conf_default "$1")" ;;
        key_summon|key_summon_fast)                 printf '← 무효값 · 스니펫에서 그 키는 빠진다' ;;
        *)                                          printf '← 무효값' ;;
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
            # 팝업 설정화면과 같은 정직함이 여기에도 있어야 한다 — CLI 만 보고 설정하는
            # 사람이 "저장됐다"는 말만 듣고 안 도는 기능을 켠 줄 알면 안 된다.
            printf '%-18s %-14s %s\n' 'KEY' 'VALUE' 'SOURCE'
            unwired=0; bogus=0
            for k in $TT_CONF_KEYS; do
                v=$(tt_conf_get "$k")
                lie=$(tt_conf_lie "$k" "$v")
                [ -n "$lie" ] && bogus=1
                [ -z "$lie" ] || lie=" $lie"
                if tt_conf_wired "$k"; then
                    printf '%-18s %-14s %s%s\n' "$k" "$v" "$(tt_conf_source "$k")" "$lie"
                else
                    unwired=1
                    printf '%-18s %-14s %-9s%s%s\n' "$k" "$v" "$(tt_conf_source "$k")" '← 미배선' "$lie"
                fi
            done
            [ "$unwired" = 1 ] && printf '\n미배선 = 값은 저장되지만 아직 아무 코드도 그 값을 읽지 않는다 — 바꿔도 동작은 그대로다.\n'
            [ "$bogus" = 1 ] && printf '무효값 = 파일에 저장은 돼 있지만 코드가 못 쓰는 값이다 — 위에 적힌 대로 접혀서 돈다.\n'
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
            # 값을 실제로 바꾸는 순간이 가장 속기 쉬운 순간이다 — "저장됐다"만 보고 기능이
            # 켜진 줄 안다. 확인 줄 바로 밑에서 한 번 더 말한다(stdout 의 key=value 는
            # 스크립트가 읽을 수 있게 그대로 두고, 이 안내만 stderr 로 보낸다).
            tt_conf_wired "$k" || printf '  ↑ %s 는 아직 아무 동작에도 안 물렸다 — 저장은 됐지만 지금은 바뀌는 게 없다\n' "$k" >&2
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
