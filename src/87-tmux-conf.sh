
# ── tmux 스니펫 ─────────────────────────────────────────────────────────────
# fmux 는 사용자의 ~/.tmux.conf 를 편집하지 않는다. 자기 파일 하나를 소유하고, 사용자
# 설정에는 `source-file` 한 줄만 빌린다. 지우면 흔적이 사라진다 — PATH shim 과 같은 철학이다.
# (남의 설정 파일에 우리 블록을 끼워 넣으면, 지울 때 우리가 남의 파일을 편집해야 한다.
#  그 편집이 한 번이라도 어긋나면 사용자의 tmux 가 안 뜬다 — 그 위험을 아예 안 진다.)
TT_TMUX_CONF="$TT_CONF_DIR/tmux.conf"

# 걷어낼 무prefix 키 목록을 stdout 에(공백 구분, 중복 제거).
# tmux 는 "설정에 없으면 알아서 사라지는" 모델이 아니다 — 한 번 bind 하면 서버가 죽을
# 때까지 남는다. 그래서 설정에서 키를 지워도, unbind 를 같이 내지 않으면 지운 키가 계속 산다.
#
# 근거는 딱 둘이다 — 둘 다 "fmux 가 실제로 걸었던 키"다:
#   ① 지금 걸 키(재적용을 멱등하게)  ② 이전 판 스니펫에 남아 있는 `bind -n` 줄
# 예전엔 여기에 정적 후보 목록(C-Left M-Left M-b C-Right M-Right M-f)이 하나 더 있었다.
# 그건 기본(safe) 프리셋 — 우리가 키를 하나도 안 건 상태 — 에서도 그 여섯 개를 unbind 해
# **남이 걸어둔 바인딩을 우리가 지웠다**. README 의 "steals no key until you say so" 와
# 정면으로 어긋나고, 사용자에게 고지된 적도 없다(팀 배포 게이트 B3). 우리가 안 건 키는
# 우리 것이 아니다 — ② 가 있으므로 우리가 걸었던 키는 이름이 무엇이든 스스로 따라 죽는다.
tt_tmux_conf_unbind_list() {
    local seen=' ' k line fast
    fast=$(tt_conf_get key_summon_fast)
    for k in $fast; do
        case "$seen" in *" $k "*) continue ;; esac
        tt_conf_is_tmux_key "$k" || continue
        seen="$seen$k "
    done
    if [ -r "$TT_TMUX_CONF" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in 'bind -n '*) ;; *) continue ;; esac
            line=${line#bind -n }
            k=${line%% *}
            case "$seen" in *" $k "*) continue ;; esac
            tt_conf_is_tmux_key "$k" || continue
            seen="$seen$k "
        done < "$TT_TMUX_CONF"
    fi
    printf '%s' "${seen# }"
}

# 스니펫 내용을 stdout 에. 파일은 안 건드린다 — `tt --tmux-conf` 로 눈으로 먼저 볼 수 있게.
tt_tmux_conf_render() {
    # 팝업 소환 명령. SELFQ 는 경로에 공백이 있어도 안 깨지는 인용형이다(00-header.sh).
    # --from '#S' 로 지금 세션을 알려준다 — 목록에서 자기 자신을 빼기 위함(90-main.sh:251).
    local popup="display-popup -E -w 85% -h 75% -b rounded -T ' tt ' $SELFQ --from '#S'"
    local k fast

    printf '# fleetmux 가 생성한 파일 — 손으로 고치지 마라. tt config set … 이 다시 쓴다.\n'
    printf '# 사용자 설정(~/.tmux.conf)에는 이 한 줄만 넣는다:\n'
    printf '#   source-file %s\n' "$TT_TMUX_CONF"
    printf '\n'

    # 걷기가 먼저다. 지금 걸 키까지 한 번 걷고 다시 걸어야 재적용이 멱등하다.
    # 안 걸려 있는 키를 unbind 하면 tmux 가 에러를 내지만 -q 로 삼킨다 — 첫 소스에서
    # 사용자에게 "unknown key" 를 열 줄 보여줄 이유가 없다.
    for k in $(tt_tmux_conf_unbind_list); do
        printf 'unbind -n -q %s\n' "$k"
    done
    printf '\n'

    # prefix 뒤에 오는 소환키. 빈 값이면 안 건다 — 무prefix 만 쓰고 싶은 사람도 있다.
    k=$(tt_conf_get key_summon)
    if [ -n "$k" ]; then
        # 파서(05-config.sh)가 값 문자셋을 이미 거르지만, 손으로 고친 파일이 여기까지 오는
        # 경로라 렌더도 tmux 키 모양을 한 번 더 본다. 통과 못 하면 그 줄만 조용히 빼고 알린다 —
        # 스니펫 전체를 못 쓰게 만들면 소환키 오타 하나로 관제탑이 통째로 사라진다.
        if tt_conf_is_tmux_key "$k"; then
            printf 'bind %s %s\n' "$k" "$popup"
        else
            printf 'fleetmux: key_summon 이 tmux 키 이름이 아니다 — 건너뛴다: %s\n' "$k" >&2
        fi
    fi

    # 무prefix 소환키 목록. 같은 물리 키가 터미널마다 다른 이름으로 오므로 전부 건다.
    fast=$(tt_conf_get key_summon_fast)
    for k in $fast; do
        if tt_conf_is_tmux_key "$k"; then
            printf 'bind -n %s %s\n' "$k" "$popup"
        else
            printf 'fleetmux: key_summon_fast 의 %s 가 tmux 키 이름이 아니다 — 건너뛴다\n' "$k" >&2
        fi
    done

    if tt_conf_on snapshot_on_exit; then
        printf '\n# 떠날 때 한 번 더 기록한다 — 매니페스트가 마지막 순간을 놓치지 않게.\n'
        # client-detached 는 -b 다. 스냅샷이 떠나는 사람을 붙잡으면 detach 가 눈에 띄게 늦는다.
        printf "set-hook -g client-detached 'run-shell -b \"%s --snapshot >/dev/null 2>&1\"'\n" "$SELF"
        # session-closed 는 동기여야 한다. 마지막 세션이 닫히면 서버가 내려가는 중이라,
        # 백그라운드로 띄운 프로세스는 실행되기 전에 부모와 함께 사라진다(실측).
        printf "set-hook -g session-closed 'run-shell \"%s --snapshot >/dev/null 2>&1\"'\n" "$SELF"
    fi
}

# 사용자 설정이 이 스니펫을 실제로 source 하고 있나 — 살아있는 tmux 서버에 반영해도 되는지의
# 유일한 근거다. "우리 파일을 쓴다"와 "남의 서버에 적용한다"는 서로 다른 동의다(팀 배포 게이트 B4).
#   판정 규칙은 install.sh 의 already_sourced 와 같아야 한다: **줄 앞머리 한정 + 인자 정확 일치**.
#   부분일치로 보면 주석 줄이나 개행 없이 이어붙어 깨진 줄("set -g mouse onsource-file …")까지
#   "연결됨"이 된다. 후보 파일은 install.sh 의 pick_tmux_conf 와 같은 둘이다.
tt_tmux_conf_linked() {
    local f line rest
    for f in "$HOME/.tmux.conf" "${XDG_CONFIG_HOME:-$HOME/.config}/tmux/tmux.conf"; do
        [ -r "$f" ] || continue
        while IFS= read -r line || [ -n "$line" ]; do
            while :; do case "$line" in [[:blank:]]*) line=${line#?} ;; *) break ;; esac; done
            case "$line" in
                'source-file '*) rest=${line#source-file } ;;
                'source '*)      rest=${line#source } ;;
                *) continue ;;
            esac
            # 앞의 플래그(-q 등)를 걷고, 뒤 공백·인용부호를 벗긴 뒤 정확히 비교한다.
            # 낱말 분해($rest 를 for 로 도는 것)는 안 쓴다 — 글롭이 켜진 셸에서 남의 설정
            # 줄에 있는 * 가 파일명으로 펴진다.
            while :; do case "$rest" in '-'*' '*) rest=${rest#* } ;; *) break ;; esac; done
            while :; do case "$rest" in *[[:blank:]]) rest=${rest%?} ;; *) break ;; esac; done
            case "$rest" in '"'*'"'|"'"*"'") rest=${rest#?}; rest=${rest%?} ;; esac
            [ "$rest" = "$TT_TMUX_CONF" ] && return 0
        done < "$f"
    done
    return 1
}

# 스니펫을 원자적으로 쓴다. 사용자가 이 파일을 자기 설정에 걸어뒀고 지금 tmux 안이면 즉시 반영한다.
tt_tmux_conf_write() {
    local tmp
    mkdir -p "$TT_CONF_DIR" 2>/dev/null || true
    tmp="$TT_TMUX_CONF.tmp.$$"
    # 렌더가 이전 판 스니펫을 읽는다(unbind 수집) — 그래서 tmp 에 다 쓴 뒤에 mv 해야 한다.
    # 원본으로 바로 리다이렉트하면 읽는 도중에 잘라먹는다.
    # stderr 는 안 막는다 — 손으로 고친 설정에 이상한 키가 있으면 쓰는 사람이 알아야 한다.
    # 조용해야 하는 호출부(tt_conf_resnip)는 자기가 2>/dev/null 로 감싼다.
    tt_tmux_conf_render > "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$TT_TMUX_CONF" || { rm -f "$tmp"; return 1; }
    # 살아있는 서버에 반영하는 조건은 둘 다 참일 때뿐이다:
    #   ① 지금 tmux 안이다  ② 사용자 설정에 이 파일을 source 하는 줄이 실제로 있다
    # ② 를 안 보면 "아직 연결 안 한 사람"의 서버에까지 우리 바인딩이 들어간다 —
    # 스니펫을 눈으로 보려고 `tt --tmux-conf --write` 를 친 것만으로 키가 바뀌는 셈이다.
    # 연결 안 한 사람에게는 다음 tmux 시작도, 이번 서버도 아무 일이 없다(우리 파일만 최신).
    if [ -n "${TMUX:-}" ] && tt_tmux_conf_linked; then
        tmux source-file "$TT_TMUX_CONF" 2>/dev/null || true
    fi
    return 0
}

if [ "${1:-}" = "--tmux-conf" ]; then
    # 계약(05-config.sh:53): 아래 렌더는 tt_conf_get 을 $(...) 로 여러 번 부른다 — 전부
    # 서브셸이라, 여기서 맨 statement 로 한 번 태워두지 않으면 깨진 설정 줄 하나가
    # 조회한 키 수만큼 같은 경고를 반복한다.
    tt_conf_load
    if [ "${2:-}" = "--write" ]; then
        tt_tmux_conf_write || { echo "스니펫을 쓸 수 없다: $TT_TMUX_CONF" >&2; exit 1; }
        printf '%s\n' "$TT_TMUX_CONF"
    else
        tt_tmux_conf_render
    fi
    exit 0
fi
