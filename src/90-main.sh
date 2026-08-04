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
    # ^B 는 fzf {+1} 을 그대로 넘긴다 — Tab 으로 설정 행까지 찍혀 있으면 그것도 섞여 온다.
    # tt_broadcast 안에도 같은 가드가 있지만 여기서 먼저 턴다: 안 그러면 아래 "targets:" 줄이
    # 존재하지도 않는 세션 이름을 사용자에게 보여주고, 하나만 찍은 경우 프롬프트까지 물어본 뒤
    # 아무 데도 안 보내는 헛걸음이 된다.
    bargs=()
    for a in "$@"; do
        case "$a" in "$TT_SETTINGS_ROW") continue ;; esac
        bargs+=("$a")
    done
    set -- ${bargs[@]+"${bargs[@]}"}
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
if [ "${1:-}" = "--preview" ]; then
    n="${2:-}"; [ -n "$n" ] || exit 0
    # 설정 행 위에 커서가 얹히면 tmux 화면 대신 지금 설정을 보여준다. 가드가 없으면
    # capture-pane 이 없는 타깃을 찾다 실패하고 프리뷰 창이 그냥 텅 빈다 — 크래시가 없어서
    # 더 나쁘다. 무엇을 볼 창인지 모른 채 빈 화면만 보게 된다.
    if [ "$n" = "$TT_SETTINGS_ROW" ]; then "$SELF" config list; exit 0; fi
    lines="${FZF_PREVIEW_LINES:-40}"                       # fzf가 프리뷰 창 높이를 넣어준다
    case "$lines" in ''|*[!0-9]*) lines=40 ;; esac
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
    # 설정 행에 커서를 둔 채 ^X — "설정을 죽이나?" 하는 프롬프트를 띄우느니 그냥 말한다.
    if [ "$n" = "$TT_SETTINGS_ROW" ]; then
        echo "설정 행은 세션이 아니다 — Enter 로 설정 화면을 연다"; sleep 1; exit 0
    fi
    read -rp "kill $n? [y/N] " a </dev/tty || exit 0
    [ "$a" = y ] && tmux kill-session -t "=$n"
    exit 0
fi

# 세션 개명 (팝업 ^E): 검증 → tmux 개명 → Claude 세션이면 /rename도 주입해 제목 동기화
if [ "${1:-}" = "--do-rename" ]; then
    old="${2:-}"; [ -n "$old" ] || exit 0
    if [ "$old" = "$TT_SETTINGS_ROW" ]; then
        echo "설정 행은 세션이 아니다 — Enter 로 설정 화면을 연다"; sleep 1; exit 0
    fi
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
    T=$'\033[38;5;73m'; D=$'\033[2m'; R=$'\033[0m'; B=$'\033[1m'
    cat << EOF

  ${B}tt — tmux session manager${R}  ${D}works with claude & codex sessions${R}

  ${T}navigate${R}
    →/Enter    enter session          ←/Esc    close
    Option+←   summon from anywhere   ^D       detach tmux (back to shell)

  ${T}manage${R}
    ^N  new session     ^E  rename     ^X  kill     ^R  refresh

  ${T}settings${R}
    ^O  open settings — or pick the ${D}⚙ settings${R} row at the bottom of the list
    Enter flips a switch on the spot; number/text keys ask for a value and validate it
    ${D}rows marked 미배선 are not wired to any behaviour yet — the toggle would be a lie${R}
    tt config list   ${D}the same table from the shell; tt config path shows the file${R}

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
    ${B}bold name${R}   talked within 6h          ${D}dim name${R}   quiet session
    ${T}teal name${R}   tool session (alphabetical, bottom)
    ● attached    ✻ working    ⏸ awaiting approval    ✓ unseen result
    ⊘ remote control dropped — retried every minute; ${B}red ⊘${R} = gave up after 3 tries

  ${T}status bar${R}
    ⏸n ✻n — fleet tally: sessions awaiting you / working right now
    ✓name — finished while you were away. clears on visit or 10 min

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

# 빈 상태 부트스트랩: 갈 세션이 하나도 없으면 만들어서 바로 진입 — tt가 tmux의 정문
#   설정 행은 무조건 한 줄 붙으니 --list 는 이제 절대 빈 문자열이 될 수 없다. 그대로 두면
#   이 판정이 영영 거짓이 되어, 진짜로 세션이 0개인 함대에서도 온보딩 프롬프트 대신 '⚙ settings'
#   한 줄짜리 피커가 뜬다 — 만들 세션이 없는데 만들 방법도 안 알려주는 화면이다. 그래서 뺀다.
if [ -z "$("$SELF" --list | grep -v "^$TT_SETTINGS_ROW"$'\t' || true)" ]; then
    read -rp "no sessions yet. name for a new one: " n </dev/tty || exit 0
    [ -n "$n" ] || exit 0
    if [ -n "${TMUX:-}" ]; then
        tmux new-session -d -s "$n"
        exec tmux switch-client -t "=$n"
    else
        exec tmux new-session -s "$n"
    fi
fi

# --delimiter/--with-nth: 1번 필드(순수 이름)는 감추고 2번 필드(색칠된 표시줄)만 보여준다.
#   그래서 {1}·{+1}은 공백이 들어간 이름도 잘리지 않은 채로 tt에 전달된다.
# 프리뷰는 tail — 중요한 건 화면 하단(입력창·스피너·승인 프롬프트)인데 전체를 흘려보내면 잘린다.
# ^O(설정 화면)는 아직 리터럴이다 — 단축키 재매핑(tt_key)이 들어오면 key_settings 를 여기로 문다.
session=$("$SELF" --list \
    | fzf --ansi --reverse --cycle --prompt='❯ ' --pointer='▶' --info=hidden --multi \
          --delimiter=$'\t' --with-nth='2..' \
          --footer='? help' \
          --bind "?:execute($SELFQ --help </dev/tty >/dev/tty 2>&1; printf '  press any key to return' >/dev/tty; read -rsn1 </dev/tty)" \
          --color='pointer:#4ec9b0,prompt:#4ec9b0,hl:#56b6c2,hl+:#56b6c2,bg+:#18221e,fg+:regular,footer:#4a5a52,border:#4a5a52,label:#4ec9b0,preview-border:#4a5a52' \
          --preview "$SELFQ --preview {1}" \
          --preview-window 'right,65%,border-rounded' --preview-label=' screen ' \
          --bind 'right:accept' \
          --bind 'left:abort' \
          --bind "ctrl-r:reload($SELFQ --list)" \
          --bind 'ctrl-d:execute-silent(tmux detach-client)+abort' \
          --bind "ctrl-n:execute($SELFQ --do-new </dev/tty >/dev/tty 2>&1)+clear-query+reload($SELFQ --list)" \
          --bind "ctrl-e:execute($SELFQ --do-rename {1} </dev/tty >/dev/tty 2>&1)+clear-query+reload($SELFQ --list)" \
          --bind "ctrl-x:execute($SELFQ --do-kill {1} </dev/tty >/dev/tty 2>&1)+reload($SELFQ --list)" \
          --bind "ctrl-b:execute($SELFQ --do-broadcast {+1} </dev/tty >/dev/tty 2>&1)+deselect-all+clear-query" \
          --bind "ctrl-o:execute($SELFQ --config-view </dev/tty >/dev/tty 2>&1)+reload($SELFQ --list)") || exit 0

session=$(printf '%s\n' "$session" | grep -v '^─' || true)   # 구분선 줄은 선택 불가 취급
[ -z "$session" ] && exit 0

# 설정 행을 골랐다 — 세션 진입 대신 설정 화면을 열고, 닫으면 목록으로 돌아온다.
#   다중선택 카운트를 세기 *전*이어야 한다. 뒤에 두면 head -1 을 지나 tmux switch-client -t
#   '=--settings--' 까지 흘러가고, 이 경로는 stderr 를 안 죽여서 tmux 에러가 화면에 그대로 찍힌다.
#   여기 검사는 첫 줄만 본다 — 설정 행이 다른 세션과 함께 Tab 다중선택된 경우는 아래
#   targets 수집 루프의 가드가 잡는다.
if [ "${session%%$'\t'*}" = "$TT_SETTINGS_ROW" ]; then
    "$SELF" --config-view
    exec "$SELF" --from "$CUR"
fi

# Tab으로 2개 이상 찍고 Enter/→ = 브로드캐스트 (1개 이하 = 평소처럼 진입)
count=$(printf '%s\n' "$session" | grep -c . || true)
if [ "${count:-0}" -ge 2 ]; then
    targets=()
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        # 설정 행에는 프롬프트를 보내지 않는다. grep -v '^─' 는 이걸 못 거른다 — 저건 줄이
        # 박스드로잉 대시로 시작할 때만 걸리는 필터고, 설정 행은 '-' 로 시작한다.
        case "${line%%$'\t'*}" in "$TT_SETTINGS_ROW") continue ;; esac
        targets+=("${line%%$'\t'*}")   # 탭 앞 = 순수 이름 (공백 안전)
    done <<< "$session"
    [ "${#targets[@]}" -ge 1 ] || exit 0   # 걸러내고 나니 보낼 데가 없다 (bash 3.2: 빈 배열 + set -u 방어)
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
