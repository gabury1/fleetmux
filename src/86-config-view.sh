# ── 팝업 안 설정 화면 ────────────────────────────────────────────────────────
# 팝업을 벗어나지 않고 설정을 바꾼다. 진입로는 둘 — 팝업의 ^O, 그리고 목록 맨 끝의 ⚙ 행.
#
# 한 줄의 모양은 --list 와 똑같이 "<키>\t<사람이 보는 표시>" 다. fzf 가 --with-nth 로 1번
# 필드를 감추고, 우리는 {1} 대신 고른 줄의 탭 앞을 직접 잘라 쓴다(--list 와 같은 규율).

# 불린 키 — Enter 로 즉시 뒤집을 수 있는 키. 나머지는 값을 입력받아야 한다.
#   목록은 tt_conf_validate 의 불린 분기(85-config-cli.sh)와 반드시 같아야 한다.
tt_conf_is_bool() {
    case "${1:-}" in rc|snapshot|snapshot_on_exit|boot_restore) return 0 ;; *) return 1 ;; esac
}

# 이 키가 실제 동작에 물려 있나 — "(미배선)" 표시의 근거다.
#   거짓말하는 토글을 주지 않기 위한 장치다: 켜고 꺼도 아무 일이 안 일어나는 키를 아무 표시
#   없이 늘어놓으면, 사용자는 자기가 끈 기능이 꺼진 줄 안다. 그건 설정 화면이 할 수 있는
#   가장 나쁜 거짓말이다.
#   여기 적힌 세 키는 60-rc.sh:83/164/173 · 70-fleet.sh:29/346 이 tt_conf_on 으로 실제 판정한다.
#   ★ 새 키를 코드에 물릴 때 이 목록에 같이 넣어라. 안 넣으면 표시가 거짓이 된다.
tt_conf_wired() {
    case "${1:-}" in rc|snapshot|boot_restore) return 0 ;; *) return 1 ;; esac
}

# 한 줄 설명. 괄호를 피한다 — 이 문자열이 언젠가 fzf --bind 의 execute/reload 인자 안으로
# 들어가면 닫는 괄호가 바인딩을 잘라먹는다(80-view.sh:58 과 같은 이유).
tt_conf_desc() {
    case "${1:-}" in
        rc)               printf '원격제어 링크 자동복구' ;;
        snapshot)         printf '팝업·크론마다 함대 기록' ;;
        snapshot_on_exit) printf '떠날 때 함대 기록' ;;
        boot_restore)     printf '부팅 시 자동 복원' ;;
        recent_hours)     printf '이름을 굵게 쓰는 기준 시간' ;;
        unseen_minutes)   printf '상태바 ✓ 유지 분' ;;
        accent)           printf '강조색 256색 번호' ;;
        log_max)          printf '훅 로그 회전 임계 바이트' ;;
        key_new)          printf '팝업 키 — 새 세션' ;;
        key_rename)       printf '팝업 키 — 이름 변경' ;;
        key_kill)         printf '팝업 키 — 세션 삭제' ;;
        key_reload)       printf '팝업 키 — 목록 갱신' ;;
        key_detach)       printf '팝업 키 — tmux 탈출' ;;
        key_broadcast)    printf '팝업 키 — 브로드캐스트' ;;
        key_help)         printf '팝업 키 — 도움말' ;;
        key_settings)     printf '팝업 키 — 이 설정 화면' ;;
        key_summon)       printf 'tmux 소환키 — prefix 뒤' ;;
        key_summon_fast)  printf 'tmux 소환키 — 무prefix, 공백으로 여러 개' ;;
        *)                printf '' ;;
    esac
}

# 설정 화면 한 판: 한 번 그리고 한 번 고른다.
#   rc 1 로 돌아오면 호출자가 루프를 끝낸다(Esc/← = 세션 목록으로).
#   목록은 매번 자식 프로세스로 새로 뽑는다 — 방금 바꾼 값이 그 자리에서 보여야 하는데,
#   이 프로세스의 tt_conf_load 캐시는 시작 시점의 파일에 멈춰 있기 때문이다.
tt_conf_view_once() {
    local line k rc nv
    line=$("$SELF" --config-list \
        | fzf --ansi --reverse --cycle --info=hidden --prompt='설정 ❯ ' --pointer='▶' \
              --delimiter=$'\t' --with-nth='2..' \
              --header='Enter 바꾸기    Esc·← 세션 목록으로' \
              --color='pointer:#4ec9b0,prompt:#4ec9b0,hl:#56b6c2,hl+:#56b6c2,bg+:#18221e,fg+:regular,header:#4a5a52,border:#4a5a52,label:#4ec9b0' \
              --bind 'left:abort' \
              --bind 'esc:abort') || return 1
    k=${line%%$'\t'*}
    [ -n "$k" ] || return 1
    rc=0
    "$SELF" --config-toggle "$k" || rc=$?
    [ "$rc" = 0 ] && return 0            # 불린이었다 — 뒤집어 저장했다. 다시 그린다.
    if [ "$rc" != 2 ]; then               # 토글 자체를 거절했다(사유는 이미 stderr 로 나갔다)
        printf '  아무 키나 누르면 돌아간다' >/dev/tty
        read -rsn1 </dev/tty 2>/dev/null || true
        return 0
    fi
    # rc 2 = 불린이 아니다 → 값을 입력받는다. 검증은 tt config set 에 그대로 맡긴다.
    printf '\n%s 의 새 값 — 지금은 %s. 그냥 Enter 면 안 바꾼다: ' \
        "$k" "$("$SELF" config get "$k")" >/dev/tty
    IFS= read -r nv </dev/tty || return 0
    [ -n "$nv" ] || return 0
    if ! "$SELF" config set "$k" "$nv" >/dev/tty 2>&1; then
        printf '  거절됐다 — 값은 그대로 둔다. 아무 키나 누르면 돌아간다' >/dev/tty
        read -rsn1 </dev/tty 2>/dev/null || true
    fi
    return 0
}

# 설정 화면용 목록. 한 줄 = "<키>\t<표시>".
if [ "${1:-}" = "--config-list" ]; then
    # 계약(05-config.sh:53): 아래 루프는 키마다 tt_conf_get/tt_conf_source 를 $(...) 로 부른다 —
    # 전부 서브셸이라, 여기서 맨 statement 로 한 번 태워두지 않으면 깨진 설정 줄 하나가
    # 키 개수만큼 경고를 반복한다. 이 목록은 화면을 다시 그릴 때마다 도는 경로다.
    tt_conf_load
    for k in $TT_CONF_KEYS; do
        v=$(tt_conf_get "$k")
        # 빈 값도 유효한 값이다(key_summon_fast 의 기본값이 그렇다) — 자리를 비워두면 열이
        # 무너지니 '-' 로 채운다. 폭 맞춤은 %-16s 라 ASCII 로 써야 한다.
        [ -n "$v" ] || v='-'
        # env 로 고정된 키는 파일에 뭘 써도 안 먹는다 — 그 사실을 값 옆에 붙인다.
        [ "$(tt_conf_source "$k")" = env ] && v="$v @env"
        d=$(tt_conf_desc "$k")
        if tt_conf_wired "$k"; then
            printf '%s\t%-18s %-16s %s\n' "$k" "$k" "$v" "$d"
        else
            printf '%s\t%-18s %-16s \033[2m미배선 · %s\033[0m\n' "$k" "$k" "$v" "$d"
        fi
    done
    exit 0
fi

# 불린이면 뒤집어 저장하고 rc 0. 불린이 아니면 rc 2 — "호출자가 값을 입력받아라"는 신호다.
# 그 밖의 거절(모르는 키·env 고정)은 rc 1 이고 사유가 stderr 로 나간다.
if [ "${1:-}" = "--config-toggle" ]; then
    tt_conf_load
    k="${2:-}"
    tt_conf_default "$k" >/dev/null 2>&1 || { echo "모르는 키: $k" >&2; exit 1; }
    # env 가 이기는 키는 파일에 뭘 써도 값이 안 바뀐다 — 딱 그 "거짓말하는 토글"이라 막는다.
    #   불린 판정보다 먼저다: 값을 입력받는 키도 마찬가지로 안 먹으니, 입력을 받아놓고
    #   버리느니 애초에 묻지 않는 게 맞다.
    #   log_max 가 지금 항상 여기 걸린다 — 10-util.sh:21 이 TT_LOG_MAX 를 스스로 세우기
    #   때문이다. 그 키를 tt_conf_get 경유로 바꾸는 순간(임계값 배선) 여기서 풀린다.
    if [ "$(tt_conf_source "$k")" = env ]; then
        echo "$k 는 환경변수 $(tt_conf_envname "$k") 가 이긴다 — 설정 파일에 써도 안 먹는다" >&2
        exit 1
    fi
    tt_conf_is_bool "$k" || exit 2
    if tt_conf_on "$k"; then nv=off; else nv=on; fi
    # 검증·쓰기를 이 프로세스에서 직접 한다(85-config-cli.sh 의 함수들). `$SELF config set` 으로
    # 포크하면 그 자식이 설정 파일을 한 번 더 파싱해, 깨진 줄 하나가 토글 한 번에 경고 두 번이 된다.
    tt_conf_validate "$k" "$nv" || exit 1
    tt_conf_write "$k" "$nv" set || exit 1
    exit 0
fi

# 설정 화면. 한 판씩 돌다가 Esc/← 로 빠져나온다.
if [ "${1:-}" = "--config-view" ]; then
    while :; do
        tt_conf_view_once || break
    done
    exit 0
fi
