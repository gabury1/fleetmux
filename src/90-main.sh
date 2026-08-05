# ── 설정 화면으로 가는 문 ────────────────────────────────────────────────────
# 문은 하나다: 팝업의 ^O. 예전엔 목록 맨 끝의 '⚙ settings' 행이 두 번째 문이었는데,
# 세션이 아닌 행을 세션 목록에 흘린 대가로 목록을 먹는 여섯 곳(프리뷰·^X·^E·^B·다중선택
# 수집·빈 목록 부트스트랩)에 전부 가드가 붙었고, 그중 부트스트랩 판정이 실제로 깨져
# "팝업이 아예 안 뜨는" 버그가 됐다. 문을 하나로 줄이는 대신 **발견성은 footer 가 갚는다** —
# 목록 아래에 이 키가 늘 적혀 있다.
#
# 그래서 키 이름은 여기 한 곳에만 적는다: 아래 fzf 바인딩과 footer·도움말 표기가 같은
# 값에서 나온다. 사람이 읽는 표기(^O)는 바인딩 이름에서 기계적으로 뽑으므로 둘이 어긋날 수 없다.
#   (설정 키 key_settings 는 아직 아무 코드도 읽지 않는다 — 재매핑은 T7 의 몫이다.
#    여기서 그 값을 읽으면 화면의 '미배선' 표시가 거짓말이 된다.)
TT_KEY_SETTINGS='ctrl-o'
tt_key_label() {
    case "${1:-}" in
        ctrl-?) printf '^%s' "$(printf %s "${1#ctrl-}" | tr 'a-z' 'A-Z')" ;;
        alt-?)  printf 'M-%s' "${1#alt-}" ;;
        *)      printf '%s' "${1:-}" ;;
    esac
}

# 입력 프롬프트: Esc=취소(rc 1) · Enter=확정 · 백스페이스 지원 — read는 Esc 취소가 안 돼서 자작
tt_prompt() {
    local p="$1" s="" c
    printf '%s' "$p" >/dev/tty
    while IFS= read -rsn1 c </dev/tty; do
        case "$c" in
            $'\x1b')
                # 화살표 등 Esc 뒤에 따라오는 시퀀스를 흡수한다. 소수점 timeout은 bash 4+ 전용 —
                # 맥 기본 셸(3.2)은 "invalid timeout specification"으로 거부하고, 정수 1초로 바꾸면
                # Esc 한 번에 1초씩 멈춘다. 그래서 3.2에서는 흡수를 아예 건너뛴다:
                # Esc 취소는 그대로 되고, 화살표가 취소로 해석될 뿐이라 손해가 작다.
                [ "$TT_TINY_READ" = 1 ] && { read -rsn2 -t 0.01 _ </dev/tty || true; }
                printf '\n' >/dev/tty; return 1 ;;
            "") printf '\n' >/dev/tty; break ;;
            $'\x7f'|$'\x08')
                [ -n "$s" ] && { s=${s%?}; printf '\b \b' >/dev/tty; } ;;
            *) s+="$c"; printf '%s' "$c" >/dev/tty ;;
        esac
    done
    printf '%s' "$s"
}

# 새 세션 (팝업 ^N): 이름 + 시작 명령 질문 — 명령은 셸 위에 얹어 실행(명령 종료돼도 세션 생존)
if [ "${1:-}" = "--do-new" ]; then
    n=$(tt_prompt "new session name (Esc to cancel): ") || exit 0
    [ -n "$n" ] || exit 0
    printf %s "$n" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1 \
        || { echo "broken bytes in name (IME mid-composition?) — retry in English mode"; sleep 2; exit 0; }
    cmd=$(tt_prompt "start command (empty = plain shell, e.g. claude): ") || exit 0
    tmux new-session -d -s "$n" || exit 0
    if [ -n "$cmd" ]; then
        tmux send-keys -t "=$n:" -l "$cmd"
        tmux send-keys -t "=$n:" Enter
        case "$cmd" in claude*)
            # /rename 예약 — 실행은 SessionStart 훅(tt --hook boot)이 부팅 자백할 때.
            # 첫 필드에 예약 시각을 남긴다: 소비되지 않은 예약이 영원히 살아 남는 걸 TTL로 끊는다
            mkdir -p "$STATE"
            echo "$(date +%s) $n" > "$STATE/pending-rename-$n"
            ;;
        esac
    fi
    # 함대 대장에 즉시 기록 — 만든 그 순간이 "무엇으로 띄웠는지"를 아는 유일한 시점이다.
    #   대화 id는 '-'로 못박는다(보존 아님): 같은 이름의 옛 줄이 남아 있으면 새 세션이 남의
    #   대화를 물고 되살아난다. 진짜 id는 몇 초 뒤 boot 훅이 stdin에서 받아 채워준다.
    npath=$(tmux display-message -p -t "=$n:" '#{pane_current_path}' 2>/dev/null || true)
    case "$cmd" in claude*|codex*) nkind=agent ;; *) nkind=tool ;; esac
    case "$cmd" in '') ncmd="-" ;; *) ncmd="$cmd" ;; esac
    tt_mf_upsert "$n" "${npath:-$HOME}" "$nkind" "$ncmd" "-" || true
    exit 0
fi

# 브로드캐스트 (팝업 ^B): 선택 세션들에게 프롬프트 일괄 주입 (도구 세션은 tt_broadcast가 걸러낸다)
if [ "${1:-}" = "--do-broadcast" ]; then
    shift
    # ^B 는 fzf {+1} 을 그대로 넘긴다 — 아무것도 안 찍혔으면 인자가 없다.
    [ $# -ge 1 ] || exit 0
    echo "targets: $*"
    m=$(tt_prompt "broadcast prompt (Esc to cancel): ") || exit 0
    [ -n "$m" ] || exit 0
    tt_broadcast "$m" "$@"
    sleep 1
    exit 0
fi

# fzf 프리뷰: 그 세션 화면의 '하단'을 보여준다.
#   화면 전체를 흘려보내면 정작 급한 아래쪽(입력창·스피너·승인 프롬프트)이 프리뷰 창 밖으로 밀린다.
#   단순 tail은 안 된다 — 미접속 세션의 pane은 프리뷰 창보다 훨씬 길어서(실측 43줄 vs 28줄)
#   꼬리 빈 줄만 퍼올려 화면이 통째로 비어 보인다. 그래서 꼬리 공백을 먼저 걷어내고 tail 한다.
#   별도 서브커맨드로 뺀 이유: fzf --preview 문자열 안에서 인용을 겹치지 않아도 된다.
#
# 맨 위에는 **그 세션에 마지막으로 보낸 프롬프트**를 얹는다(3번 인자 = 세션 id, --list 의 3번 필드).
#   화면 위로 밀려 사라지는 게 바로 그 한 줄이라, 화면 꼬리만으로는 "내가 뭘 시켰더라"에 답이 없다.
#   모양은 `last prompt ❯` 라벨 한 줄 + 본문(접두 없이 창 폭 전체) + 구분선이다. 박스·세로선은
#   중간 판으로 만들어 봤다가 버려졌다 — 자세한 이유는 35-lastprompt.sh 의 렌더 주석에 있다.
#   ⚠ 이건 부가물이다 — 파일이 없거나 깨졌거나 id를 못 받거나 창이 너무 좁으면
#     **헤더 없이 예전 출력 그대로** 나간다. 프리뷰가 이 기능 때문에 깨지는 일은 없어야 한다(설계 4절).
if [ "${1:-}" = "--preview" ]; then
    n="${2:-}"; [ -n "$n" ] || exit 0
    lines="${FZF_PREVIEW_LINES:-40}"                       # fzf가 프리뷰 창 높이를 넣어준다
    case "$lines" in ''|*[!0-9]*) lines=40 ;; esac
    psid="${3:-}"; psid=${psid#\$}
    hdr=""
    case "$psid" in
        ''|*[!0-9]*) ;;                                    # id를 못 받았다 → 헤더 없음(예전 그대로)
        *) if [ -f "$STATE/last-$psid" ]; then
               cols="${FZF_PREVIEW_COLUMNS:-80}"           # fzf가 프리뷰 창 폭도 넣어준다
               case "$cols" in ''|*[!0-9]*) cols=80 ;; esac
               # 라벨·구분선 색은 설정의 accent 를 따른다 — 하드코딩하면 색을 바꿔도 여기만 남는다.
               #   경고는 삼킨다: 프리뷰의 stderr 는 그대로 프리뷰 창에 그려져 화면을 덮는다.
               acc=$(tt_conf_num accent 255 2>/dev/null) || acc=""
               [ -n "$acc" ] || acc=$(tt_conf_default accent)
               hdr=$(LC_ALL=C awk -v cols="$cols" -v acc="$acc" "$TT_LASTP_VIEW_AWK" \
                       "$STATE/last-$psid" 2>/dev/null) || hdr=""
           fi ;;
    esac
    if [ -n "$hdr" ]; then
        printf '%s\n' "$hdr"
        # 헤더가 먹은 줄 수만큼 화면 꼬리를 줄인다 — 안 그러면 프리뷰가 넘쳐 **위가** 잘린다.
        #   즉 방금 그린 헤더가 제일 먼저 밀려 나간다. 포크 없이 센다(wc는 프리뷰마다 포크 하나).
        hl=0
        while IFS= read -r _; do hl=$((hl + 1)); done <<< "$hdr"
        lines=$((lines - hl))
        [ "$lines" -lt 1 ] && lines=1
    fi
    tmux capture-pane -ep -t "=$n:" 2>/dev/null | awk -v n="$lines" '
        { L[NR] = $0 }
        END {
            e = NR
            while (e > 0 && L[e] ~ /^[ \t]*$/) e--        # 꼬리 빈 줄 제거
            s = e - n + 1; if (s < 1) s = 1
            for (i = s; i <= e; i++) print L[i]
        }'
    exit 0
fi

# 세션 삭제 (팝업 ^X): 확인 후 정확 일치로 kill
#   예전엔 fzf 바인딩 안 bash -c 문자열에 이름을 끼워 넣어, 공백 든 이름이 인용을 깨뜨리고
#   -t 접두 매칭으로 같은 접두의 다른 세션이 죽을 수 있었다 — 이름을 인자 하나로 받는다
if [ "${1:-}" = "--do-kill" ]; then
    n="${2:-}"; [ -n "$n" ] || exit 0
    read -rp "kill $n? [y/N] " a </dev/tty || exit 0
    [ "$a" = y ] && tmux kill-session -t "=$n"
    exit 0
fi

# 세션 개명 (팝업 ^E): 검증 → tmux 개명 → Claude 세션이면 /rename도 주입해 제목 동기화
if [ "${1:-}" = "--do-rename" ]; then
    old="${2:-}"; [ -n "$old" ] || exit 0
    n=$(tt_prompt "rename $old to (Esc to cancel): ") || exit 0
    [ -n "$n" ] || exit 0
    printf %s "$n" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1 \
        || { echo "broken bytes in name (IME mid-composition?) — retry in English mode"; sleep 2; exit 0; }
    tmux rename-session -t "=$old" "$n" || exit 0
    tt_mf_rename "$old" "$n" || true   # 대장의 키도 따라간다 — 안 그러면 복원 때 옛 이름이 부활한다
    # /rename 주입은 claude 전용 — codex엔 해당 슬래시 명령이 없다 (활성 pane이 정확히 claude일 때만)
    if [ "$(tmux display-message -p -t "=$n:" '#{pane_current_command}' 2>/dev/null)" = claude ]; then
        tmux send-keys -t "=$n:" -l "/rename $n"
        sleep 0.5
        tmux send-keys -t "=$n:" Enter
        echo "→ renamed + synced Claude title"
        sleep 1
    fi
    exit 0
fi

# 훅 설정 JSON 출력 — claude wrapper가 --settings로 주입 (전역 settings.json 무침습)
#   커맨드는 PATH의 `tt`가 아니라 이 스크립트의 절대경로를 박는다 — 짧은 별명을 안 깐 환경,
#   PATH가 다른 cron·GUI 실행에서도 훅이 붙는다. 대신 파일이 사라졌을 때(제거·이동) 이미 떠 있는
#   세션이 이벤트마다 에러를 뱉으면 안 되니 `2>/dev/null || true`로 조용히 무시하게 만든다.
#   경로는 셸 인용형($SELFQ)이라 공백·따옴표가 든 경로에서도 안 깨진다.
if [ "${1:-}" = "--hooks-json" ]; then
    # JSON 문자열 이스케이프(백슬래시·따옴표만). printf 포맷에 \" 를 직접 넣는 길은 막혀 있다 —
    # 백슬래시 해석이 구현마다 달라서, 커맨드를 먼저 완성한 뒤 여기서 한 번에 감싼다.
    jesc() { local s="$1"; s=${s//\\/\\\\}; s=${s//\"/\\\"}; printf '%s' "$s"; }
    printf '{"hooks":{'
    first=1
    while read -r ev st; do
        [ "$first" = 1 ] || printf ','
        first=0
        printf '"%s":[{"hooks":[{"type":"command","command":"%s","async":true,"timeout":10}]}]' \
            "$ev" "$(jesc "$SELFQ --hook $st 2>/dev/null || true")"
    done << 'EOF'
UserPromptSubmit working
PostToolUse working
PreCompact working
PostCompact working
Stop idle
Notification waiting
SessionStart boot
SessionEnd clear
EOF
    printf '}}\n'
    exit 0
fi

# codex 훅 주입 인자 출력 — codex wrapper가 배열로 읽어 그대로 넘긴다 (전역 ~/.codex/config.toml 무침습)
#   출력 = 인자 하나당 한 줄 ("-c" 줄 / TOML 인라인 줄 교대). wrapper는 mapfile로 읽고 eval 안 함
#   → 셸이 이 문자열을 파싱할 일이 전혀 없다(인용부호 injection 여지 0). command 값도 고정 리터럴뿐
#   PermissionRequest는 이벤트 자체가 승인 대기라 stdin 판별이 필요 없어 전용 상태명(waiting-codex)을 쓴다
#   여기도 절대경로를 쓰지만 claude 쪽과 달리 셸 인용도 `|| true`도 붙이지 않는다:
#   codex가 이 문자열을 셸에 넘기는지 공백으로 argv 분해하는지 확인된 바가 없어서다.
#   생짜 절대경로는 두 해석 모두에서 동작하는 유일한 형태다(경로에 공백이 없다는 전제).
if [ "${1:-}" = "--codex-hooks" ]; then
    tesc() { local s="$1"; s=${s//\\/\\\\}; s=${s//\"/\\\"}; printf '%s' "$s"; }   # TOML 기본 문자열
    while read -r ev st; do
        printf -- '-c\n'
        printf 'hooks.%s=[{hooks=[{type="command",command="%s --hook %s",timeout=5}]}]\n' \
            "$ev" "$(tesc "$SELF")" "$st"
    done << 'EOF'
UserPromptSubmit working
PreToolUse working
PostToolUse working
Stop idle
PermissionRequest waiting-codex
EOF
    exit 0
fi

# 도움말 화면 (팝업에서 ? 로 진입, CLI에서 tt --help)
if [ "${1:-}" = "--help" ]; then
    # 설정은 진입점 맨 위에서 서브셸 아닌 맨 statement 로 한 번만 (05-config.sh 의 계약).
    tt_conf_load
    acc=$(tt_conf_num accent 255)
    T=$'\033[38;5;'"$acc"'m'; D=$'\033[2m'; R=$'\033[0m'; B=$'\033[1m'
    # 첫 화면은 **지금 이 기계의 설정**을 읽어서 말한다. 예전엔 Option+← 와 6h/10 min 이
    # 하드코딩이었는데, 기본값은 무prefix 키를 하나도 안 걸므로(key_summon_fast 가 빈 값)
    # 설치 직후 팀원이 가장 먼저 읽는 화면이 없는 키를 가르쳤다(팀 배포 게이트 B7).
    hsum=$(tt_conf_get key_summon)
    hfast=$(tt_conf_get key_summon_fast)
    hrecent=$(tt_conf_num recent_hours)
    hunseen=$(tt_conf_num unseen_minutes)
    hkset=$(tt_key_label "$TT_KEY_SETTINGS")   # 팝업 바인딩과 같은 값에서 뽑은 표기
    if [ -n "$hsum" ]; then hsummon="prefix + $hsum"; else hsummon="(key_summon is empty)"; fi
    if [ -n "$hfast" ]; then hsummon="$hsummon  ·  $hfast  ${D}prefix-less${R}"
    else hsummon="$hsummon  ${D}· no prefix-less key — tt config set key_summon_fast S-Left${R}"
    fi
    cat << EOF

  ${B}tt — tmux session manager${R}  ${D}works with claude & codex sessions${R}

  ${T}navigate${R}
    →/Enter    enter session          ←/Esc    close    ^D  detach tmux (back to shell)
    summon     $hsummon

  ${T}manage${R}
    ^N  new session     ^E  rename     ^X  kill     ^R  refresh

  ${T}settings${R}
    ${hkset}  open settings — the only door; the popup footer shows this key too
    Enter flips a switch on the spot; number/text keys ask for a value and validate it
    ${D}rows marked 미배선 are not wired to any behaviour yet — the toggle would be a lie${R}
    tt config list   ${D}the same table from the shell; tt config path shows the file${R}

  ${T}tmux binding${R}  ${D}fmux owns one file and borrows one line of your ~/.tmux.conf${R}
    tt --tmux-conf          print the snippet — summon key, and the on-exit snapshot hooks
    tt --tmux-conf --write  write it, then add ${D}source-file <printed path>${R} to ~/.tmux.conf
    ${D}key_summon is pressed after the prefix; key_summon_fast is a space-separated list of${R}
    ${D}prefix-less keys — one physical key arrives under different names per terminal${R}
    ${D}changing either key, or snapshot_on_exit, rewrites the snippet on the spot${R}
    ${D}S-Left is what ./install.sh offers: the one prefix-less single keystroke that reaches${R}
    ${D}tmux on macOS, Linux and Windows Terminal alike. It takes that key from everything in${R}
    ${D}the pane (vim, shell line-editing, fzf) — that is why it is offered, never a default.${R}
    ${D}Some dotfiles bind S-Left/S-Right to window switching; pick another key if yours does.${R}
    ${D}tt config unset key_summon_fast gives the key back — key_summon still summons.${R}

  ${T}broadcast${R}
    Tab-mark multiple sessions, then Enter — send one prompt to all
    ${D}tool sessions are skipped — a prompt typed into a shell or TUI runs as a command${R}
    ${D}^B does the same but keeps the popup open — for repeated sends${R}

  ${T}fleet${R}  ${D}survive a reboot — the manifest remembers what was up${R}
    tt --snapshot           record every live session: cwd, kind, command, conversation
    tt --restore [--dry]    bring them all back — live ones are skipped, --dry just plans
    tt --boot-restore       ${D}[--dry]${R} same, but safe to hang off @reboot cron
    tt --forget ${D}<name>${R}     drop one session from the manifest
    ${D}--boot-restore waits up to 120s for DNS before restoring, and aborts if it never comes —${R}
    ${D}claudes started without a network die into a shell, then look "already running" forever${R}
    ${D}touch ~/.cache/tt/no-autorestore to skip it on the next boot; log is ~/.cache/tt/boot.log${R}
    ${D}agents come back with claude --resume <id>, never --continue —${R}
    ${D}--continue picks "latest chat in this folder", so same-cwd sessions clone each other${R}
    ${D}resume runs in the conversation's own home dir, which is often not the session cwd${R}
    ${D}manifest keeps 3 backup generations: manifest.bak .bak2 .bak3${R}

  ${T}reading the list${R}
    ${B}bold name${R}   talked within ${hrecent}h          ${D}dim name${R}   quiet session
    ${T}teal name${R}   tool session (alphabetical, bottom)
    ● attached    ✻ working    ⏸ awaiting approval    ✓ unseen result
    ⊘ remote control dropped — retried every minute; ${B}red ⊘${R} = gave up after 3 tries

  ${T}status bar${R}  ${D}not wired automatically — fmux never rewrites your status line${R}
    tt --status prints it; nothing shows up until you put it in your own tmux config:
      ${D}set -g status-interval 5${R}
      ${D}set -ag status-right '#($SELF --status)'${R}
    ⏸n ✻n — fleet tally: sessions awaiting you / working right now
    ✓name — finished while you were away. clears on visit or ${hunseen} min

  ${T}korean IME tip${R}
    if keys after tmux prefix get eaten, keep holding Ctrl (^B ^D = detach)

EOF
    exit 0
fi

# 현재 세션은 목록에서 제외 — 팝업 바인딩은 --from '#S'로 알려주고, 셸 실행은 tmux에 직접 물음
CUR=""
[ "${1:-}" = "--from" ] && CUR="${2:-}"
[ -z "$CUR" ] && [ -n "${TMUX:-}" ] && CUR=$(tmux display-message -p '#S' 2>/dev/null || true)
export TT_CUR="$CUR"

# 팝업 열 때마다 함대 스냅샷 — "굳히기"라는 별도 행위를 없앤다(maintainer 제안).
#   훅 자동기록이 못 잡는 것들(외부 /rename·수동 생성 세션·cwd 이동)이 팝업 한 번에 정리된다.
#   백그라운드로 떼는 이유: 세션마다 파일을 읽으니 팝업이 그걸 기다릴 이유가 없다(체감 지연 0).
( "$SELF" --snapshot >/dev/null 2>&1 & ) 2>/dev/null || true

# 빈 상태 부트스트랩: 갈 세션이 **하나도 없을 때만** 만들어서 바로 진입 — tt가 tmux의 정문
#   판정 기준은 "목록에 행이 있나"가 아니라 "**세션이 하나라도 있나**"다. 둘은 다르다:
#   80-view.sh 가 TT_CUR(지금 붙어 있는 세션)을 목록에서 빼므로, **살아 있는 세션이 딱 하나이고
#   그게 지금 붙어 있는 세션이면** 목록이 빈다 — 세션이 멀쩡히 있는데 "no sessions yet"
#   온보딩 프롬프트가 뜨는 경로다. 그래서 CUR 이 있으면(= 우리가 어떤 세션 안에서 열렸다 =
#   세션 ≥ 1) 부트스트랩으로 안 샌다.
#   목록에 세션 아닌 행이 섞이지 않으니 여기 필터는 없다 — 예전엔 설정 행을 grep -v 로 걷어냈고,
#   그 필터가 이 판정을 깨뜨린 장본인이었다. 목록이 비었다 = 갈 세션이 없다, 그대로다.
mkdir -p "$STATE" 2>/dev/null || true    # 아래 두 곳이 --list 의 stderr 를 여기 흘린다
if [ -z "$CUR" ] && [ -z "$("$SELF" --list 2>>"$STATE/hook.log" || true)" ]; then
    read -rp "no sessions yet. name for a new one: " n </dev/tty || exit 0
    [ -n "$n" ] || exit 0
    if [ -n "${TMUX:-}" ]; then
        tmux new-session -d -s "$n"
        exec tmux switch-client -t "=$n"
    else
        exec tmux new-session -s "$n"
    fi
fi

# --delimiter/--with-nth: 1번 필드(순수 이름)와 3번 필드(세션 id)는 감추고 2번 필드(색칠된
#   표시줄)만 보여준다. 그래서 {1}·{+1}은 공백이 들어간 이름도 잘리지 않은 채로 tt에 전달되고,
#   {3}은 프리뷰가 last-<id> 를 찾는 열쇠가 된다(프리뷰 안에서 tmux에 되묻지 않아도 된다).
# 프리뷰는 tail — 중요한 건 화면 하단(입력창·스피너·승인 프롬프트)인데 전체를 흘려보내면 잘린다.
# --preview-label 은 ' screen ' 이 아니라 **고른 세션의 이름**이다. 창 안에 이제 두 가지가 산다:
#   위의 last prompt 헤더(우리가 쓴 글)와 그 아래 화면 꼬리(남의 출력). 바깥 라벨이 ' screen '
#   이면 헤더까지 화면인 것처럼 말한다 — 라벨은 창 전체를 가리키므로 창 전체가 무엇인지,
#   즉 "고른 세션"을 말해야 맞다. 헤더가 자기 이름(last prompt)을 스스로 대므로
#   화면 꼬리에는 따로 이름표가 필요 없다.
#   focus 는 커서가 옮겨질 때마다(첫 렌더 포함) 발화하므로 라벨이 늘 현재 행을 따라간다.
#   --preview-label 의 ' session ' 은 그 첫 발화 전 한 순간의 폴백이다.
#   {1}(순수 이름)을 쓰는 이유: 2번 필드는 색코드가 박혀 있어 라벨에 그대로 새면 깨진다.
#   change-preview-label 이 아니라 transform-preview-label 인 이유는 실측이다 —
#   change 계열은 인자를 **문자 그대로** 라벨에 넣어 화면에 '{1}' 이 찍힌다(2026-08-05 재현).
#   transform 계열만 인자를 명령으로 돌려 그 출력을 라벨로 쓰므로 placeholder 가 확장된다.
#   확인 방법: 크기를 준 pty(script + stty)에서 fzf 를 실제로 띄우고 그려진 글자를 잡는다.
#   기동 성공(rc=0)만 보면 이 차이를 못 잡는다 — 둘 다 기동은 된다.
#   그리고 {1} 은 **셸 인용된 채로** 치환된다('my-session'). 그걸 다시 " " 로 감싸면
#   인용부호가 화면에 문자로 남는다 — 여백은 printf 의 포맷으로 주고 {1} 은 인자로 넘긴다.
# 목록 생산자의 stderr 는 화면이 아니라 hook.log 로 간다 — 설정 파일에 깨진 줄이 있으면
# 그 경고가 fzf 화면 위에 덧칠돼 관제탑을 못 읽게 만든다. 버리지 않는 이유는 86 과 같다(권고 N3).
# footer 가 설정 키를 적는다 — 목록에서 ⚙ 행을 뺀 대신 여기서 발견성을 갚는다. 바인딩과 표기가
# 같은 TT_KEY_SETTINGS 에서 나오므로, 키를 바꾸면 화면도 같이 바뀐다(어긋날 수가 없다).
session=$("$SELF" --list 2>>"$STATE/hook.log" \
    | fzf --ansi --reverse --cycle --prompt='❯ ' --pointer='▶' --info=hidden --multi \
          --delimiter=$'\t' --with-nth=2 \
          --footer="? help · $(tt_key_label "$TT_KEY_SETTINGS") settings" \
          --bind "?:execute($SELFQ --help </dev/tty >/dev/tty 2>&1; printf '  press any key to return' >/dev/tty; read -rsn1 </dev/tty)" \
          --color='pointer:#4ec9b0,prompt:#4ec9b0,hl:#56b6c2,hl+:#56b6c2,bg+:#18221e,fg+:regular,footer:#4a5a52,border:#4a5a52,label:#4ec9b0,preview-border:#4a5a52' \
          --preview "$SELFQ --preview {1} {3}" \
          --preview-window 'right,65%,border-rounded' --preview-label=' session ' \
          --bind 'focus:transform-preview-label:printf " %s " {1}' \
          --bind 'right:accept' \
          --bind 'left:abort' \
          --bind "ctrl-r:reload($SELFQ --list)" \
          --bind 'ctrl-d:execute-silent(tmux detach-client)+abort' \
          --bind "ctrl-n:execute($SELFQ --do-new </dev/tty >/dev/tty 2>&1)+clear-query+reload($SELFQ --list)" \
          --bind "ctrl-e:execute($SELFQ --do-rename {1} </dev/tty >/dev/tty 2>&1)+clear-query+reload($SELFQ --list)" \
          --bind "ctrl-x:execute($SELFQ --do-kill {1} </dev/tty >/dev/tty 2>&1)+reload($SELFQ --list)" \
          --bind "ctrl-b:execute($SELFQ --do-broadcast {+1} </dev/tty >/dev/tty 2>&1)+deselect-all+clear-query" \
          --bind "$TT_KEY_SETTINGS:execute($SELFQ --config-view </dev/tty >/dev/tty 2>&1)+reload($SELFQ --list)") || exit 0

session=$(printf '%s\n' "$session" | grep -v '^─' || true)   # 구분선 줄은 선택 불가 취급
[ -z "$session" ] && exit 0

# Tab으로 2개 이상 찍고 Enter/→ = 브로드캐스트 (1개 이하 = 평소처럼 진입)
#   고른 줄은 전부 진짜 세션이다 — 목록에 세션 아닌 행이 없으니 여기서 걸러낼 것도 없다.
count=$(printf '%s\n' "$session" | grep -c . || true)
if [ "${count:-0}" -ge 2 ]; then
    targets=()
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        targets+=("${line%%$'\t'*}")   # 탭 앞 = 순수 이름 (공백 안전)
    done <<< "$session"
    [ "${#targets[@]}" -ge 1 ] || exit 0   # (bash 3.2: 빈 배열 + set -u 방어)
    printf 'targets: %s\n' "${targets[*]}"
    m=$(tt_prompt "broadcast prompt (Esc to cancel): ") || exit 0
    [ -n "$m" ] || exit 0
    tt_broadcast "$m" "${targets[@]}"
    sleep 1
    exit 0
fi
session=$(printf '%s\n' "$session" | head -1)

[ -z "$session" ] && exit 0
session=${session%%$'\t'*}

if [ -n "${TMUX:-}" ]; then
    tmux switch-client -t "=$session"
else
    exec tmux attach -t "=$session"
fi
