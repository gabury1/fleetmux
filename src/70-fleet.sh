# ── 함대 스냅샷 / 복원 ──────────────────────────────────────────────────────
# 세션 → claude 대화 id. 소스는 rc 판정부와 같은 ~/.claude/sessions/<pid>.json 의 sessionId
#   (훅 stdin으로 오는 session_id와 같은 값이다). 못 찾으면 rc 1 — 추측하지 않는다.
#   rc_target/rc_read/rc_val을 그대로 재사용한다: PID 재사용·반쪽 파일 방어가 이미 다 들어 있다.
#   대화 홈(claude 프로세스의 cwd)도 같이 돌려준다 — rc_target을 두 번 부르지 않으려는 것이고,
#   그 둘은 애초에 같은 한 프로세스에서 나오는 짝이다. 출력 = "<conv>\t<home>" (없는 쪽은 '-').
#   프로세스 cwd는 /proc/<pid>/cwd 심링크가 정답이다(리눅스). macOS엔 /proc이 없어 홈은 '-'가
#   되는데, 그때는 훅이 stdin JSON의 cwd로 이미 채워둔 옛 값이 보존된다(upsert 규칙 ②).
tt_conv_of() {
    local t pid j v home=""
    t=$(rc_target "$1") || return 1
    pid=${t##* }
    j=$(rc_read "$SESSD/$pid.json") || return 1
    v=$(rc_val "$j" sessionId)
    [ -n "$v" ] || return 1
    home=$(readlink "/proc/$pid/cwd" 2>/dev/null) || home=""
    [ -n "$home" ] && [ -d "$home" ] || home="-"
    printf '%s\t%s' "$v" "$home"
}

# 지금 살아있는 세션 전부를 대장에 새로 쓴다(전체 교체).
#   교체 전 백업 1개(manifest.bak)를 남긴다 — 실수로 빈 함대를 스냅샷해도 되돌릴 수 있게.
#   살아있는 세션이 하나도 없으면 아예 쓰지 않는다: 재부팅 직후 습관적으로 --snapshot을 치면
#   복원표가 그 자리에서 증발한다(가장 필요한 순간에).
if [ "${1:-}" = "--snapshot" ]; then
    mkdir -p "$STATE"
    rows=""; n=0
    while IFS=$'\t' read -r sid name; do
        [ -n "$name" ] || continue
        # zz 접두는 우리 테스트 세션 관례 — 진짜 함대 기록에는 넣지 않는다.
        #   단 TT_MANIFEST로 대장을 딴 데(테스트 경로)로 돌린 경우엔 그 규칙이 테스트 자체를
        #   막아버리므로 적용하지 않는다. 지키려는 대상이 애초에 진짜 대장뿐이다.
        if [ -z "${TT_MANIFEST:-}" ]; then
            case "$name" in zz*) printf '  skip %s — test session\n' "$name"; continue ;; esac
        fi
        info=$(tmux display-message -p -t "=$name:" $'#{pane_current_path}\t#{pane_current_command}' 2>/dev/null) || info=""
        cwd=${info%%$'\t'*}; pcmd=${info#*$'\t'}
        [ -n "$cwd" ] && [ -d "$cwd" ] || cwd="$HOME"
        old=$(tt_mf_row "$name")
        oldcmd=""; oldconv=""; oldhome=""
        if [ -n "$old" ]; then
            # 필드 순서: name·cwd·kind·cmd·conv[·chome] — cmd에 닿으려면 탭 3개를 벗겨야 한다.
            # 2개만 벗기던 시절엔 oldcmd=kind·oldconv=cmd로 한 칸씩 밀려, 스냅샷마다
            # 대화 id 자리에 "claude" 같은 문자열이 눌러앉는 누진 손상이 났다(2026-07-25 사고).
            o=${old#*$'\t'}; o=${o#*$'\t'}; o=${o#*$'\t'}; oldcmd=${o%%$'\t'*}
            o=${o#*$'\t'};   oldconv=${o%%$'\t'*}
            # 6번째는 없을 수 있다(옛 5필드 줄) — 있을 때만 읽는다
            case "$o" in *$'\t'*) o=${o#*$'\t'}; oldhome=${o%%$'\t'*} ;; esac
        fi
        chome=""
        if tt_is_agent "$sid"; then
            kind=agent
            # 시작 명령은 pane에서 실제로 도는 claude|codex를 본다(창이 여럿이어도 훑는다).
            # 못 찾으면(에이전트는 죽고 훅 파일만 남은 세션) 옛 기록 → 그래도 없으면 claude:
            # 이 함대의 기본값이고, codex라면 다음 훅이 자기 이름을 곧 적어준다.
            cmd=$(tmux list-panes -s -t "$sid" -F '#{pane_current_command}' 2>/dev/null | grep -m1 -xE 'claude|codex' || true)
            [ -n "$cmd" ] || cmd="$oldcmd"
            case "$cmd" in ''|-) cmd=claude ;; esac
            ci=$(tt_conv_of "$sid" || true)
            conv=${ci%%$'\t'*}
            case "$ci" in *$'\t'*) chome=${ci##*$'\t'} ;; esac
            # 지금 못 알아냈다고 옛 값을 버리진 않는다 — 버리면 복원이 선택기로 떨어지거나
            # 엉뚱한 cwd에서 resume해 "No conversation found"가 난다
            [ -n "$conv" ] || conv="$oldconv"
            [ -n "$conv" ] || conv="-"
            case "$chome" in ''|-) chome="$oldhome" ;; esac
        else
            kind=tool
            # 도구 세션의 "시작 명령"은 pane_current_command가 근사치다(yazi·lazydocker는 정확).
            # 맨 셸이면 명령 없음으로 기록 — 복원 때 셸만 띄운다.
            case "$pcmd" in ''|bash|-bash|zsh|-zsh|sh|fish|tmux) cmd="-" ;; *) cmd="$pcmd" ;; esac
            # 도구로 판정됐다고 대화 id를 버리지 않는다 — tt_is_agent가 한 번만 false여도
            # (훅 파일이 clear로 지워진 순간 등) 대화가 영구 소실된다. kind가 tool이면
            # 복원은 어차피 conv를 안 쓰니 남겨두는 쪽이 안전하다.
            conv="$oldconv"
            [ -n "$conv" ] || conv="-"
            chome="$oldhome"
        fi
        # 대화 id는 uuid 형식만 인정 — "claude" 같은 문자열이 통과하던 게 사고를 키웠다
        tt_is_uuid "$conv" || conv="-"
        # 대화 홈은 실재하는 디렉토리일 때만 적는다(사라진 경로를 적어두면 복원이 그리로 cd 하려다 실패)
        [ -n "$chome" ] && [ -d "$chome" ] || chome="-"
        [ "$conv" = - ] && chome="-"      # 대화가 없으면 홈도 의미 없다
        # 탭이 든 경로는 형식을 깨뜨린다 — 그 줄만 '없음'으로 접는다(파일 전체를 잃는 것보다 낫다)
        case "$name$cwd$cmd$chome" in *$'\t'*) printf '  skip %s — tab in path/command\n' "$name"; continue ;; esac
        rows="$rows$name"$'\t'"$cwd"$'\t'"$kind"$'\t'"$cmd"$'\t'"$conv"$'\t'"$chome"$'\n'
        n=$((n + 1))
        printf '  %-16s %-5s %-12s %-38s %s\n' "$name" "$kind" "$cmd" "$conv" "$chome"
    done < <(tmux ls -F $'#{session_id}\t#{session_name}' 2>/dev/null || true)
    if [ "$n" = 0 ]; then
        echo "no live sessions — manifest left untouched (nothing to record)"
        exit 1
    fi
    # 쓰기 전 무결성 검사 — 여기서 막지 못한 깨진 줄은 다음 스냅샷의 "옛 값"이 되어 번진다.
    #   거부하면 기존 파일은 손도 안 댄다: 낡은 대장이 깨진 대장보다 언제나 낫다.
    if ! tt_mf_check "$rows"; then
        printf 'snapshot ABORTED — generated rows failed the integrity check; %s left untouched\n' "$MANIFEST" >&2
        exit 1
    fi
    tt_mf_lock || { echo "manifest busy — try again"; exit 1; }
    # 사라진 세션의 줄은 여기서만 없어진다(훅·목록은 절대 안 지운다 — 죽은 걸 살리는 게 목적)
    if [ -f "$MANIFEST" ]; then
        # 백업 3세대 순환. --snapshot은 cron으로 1분마다 돌기 때문에 1세대뿐이면 나쁜 스냅샷을
        # 알아채고 되돌릴 창이 60초다 — 다음 틱이 유일한 백업까지 덮는다. 3세대 = 최소 3분.
        tt_mf_backup
        while IFS=$'\t' read -r on _rest || [ -n "$on" ]; do
            [ -n "$on" ] || continue
            case $'\n'"$rows" in *$'\n'"$on"$'\t'*) ;; *) printf '  dropped %s — no longer running\n' "$on" ;; esac
        done < "$MANIFEST.bak"
    fi
    tt_mf_write "$rows" || { tt_mf_unlock; exit 1; }
    tt_mf_unlock
    printf 'snapshot: %d sessions → %s\n' "$n" "$MANIFEST"
    exit 0
fi

# 대장에서 한 세션을 지운다 — 세션이 죽어도 자동으로는 안 지우니, 진짜 은퇴시킬 때 쓴다
if [ "${1:-}" = "--forget" ]; then
    n="${2:-}"
    [ -n "$n" ] || { echo "usage: tt --forget <session name>"; exit 1; }
    tt_mf_forget "$n" || { echo "manifest busy — try again"; exit 1; }
    if [ "${TT_MF_HITS:-0}" -gt 0 ]; then
        printf 'forgot %s\n' "$n"
    else
        printf 'no manifest entry named %s\n' "$n"
        exit 1
    fi
    exit 0
fi

# 대장대로 함대를 되살린다. 여러 번 돌려도 무해하다(살아있는 세션은 건너뛴다).
#   claude는 반드시 --resume <대화id>. --continue는 "그 폴더의 최신 대화"를 고르는 규칙이라
#   cwd가 같은 세션이 여럿이면 전부 같은 대화에 붙는 도플갱어 사고가 난다(실제로 겪었다 —
#   내 인사말을 그대로 따라 치는 세션이 생겼다). id가 없으면 인자 없는 --resume = 사람이 고른다.
if [ "${1:-}" = "--restore" ]; then
    dry=0; [ "${2:-}" = "--dry" ] && dry=1
    if [ ! -s "$MANIFEST" ]; then
        echo "no manifest at $MANIFEST — run 'tt --snapshot' while the fleet is up"
        exit 1
    fi
    # 재부팅하면 tmux는 세션 id를 $0부터 재발급한다 → 죽은 세션의 hook-* 를 새 세션이 물려받아
    # 도구 세션이 에이전트로 오분류된다(실측). 세션을 만들기 전에 반드시 쓸어낸다.
    if [ "$dry" = 1 ]; then
        echo "[dry] would sweep orphan hook files"
    else
        tt_sweep_hooks
    fi
    made=0; skipped=0; used=""; livec=""
    # 지금 살아있는 claude가 물고 있는 대화 목록을 먼저 모은다.
    #   이름만 보고 "죽었다"고 판단하면 부족하다 — 세션이 개명되면(사람이 ^E로 바꾸거나 claude가
    #   스스로 이름을 갈면) 대장의 옛 이름은 죽은 세션처럼 보이고, 멀쩡히 돌고 있는 대화를 한 번 더
    #   열게 된다. 개발 중에 실제로 그 사고를 냈다: 개명된 세션의 대화를 복원이 다시 열어
    #   같은 대화에 claude가 둘 붙었다(도플갱어). 이름이 아니라 대화 id가 진짜 열쇠다.
    #   판정 소스는 rc와 같은 ~/.claude/sessions/<pid>.json — pid가 실제로 살아있는 것만 인정한다.
    for sf in "$SESSD"/*.json; do
        [ -f "$sf" ] || continue
        spid=${sf##*/}; spid=${spid%.json}
        case "$spid" in ''|*[!0-9]*) continue ;; esac
        [ "$(tt_comm "$spid" || true)" = claude ] || continue
        sj=$(rc_read "$sf") || continue
        sv=$(rc_val "$sj" sessionId)
        [ -n "$sv" ] && livec="$livec $sv"
    done
    # 6번째(대화 홈)가 없는 옛 5필드 줄도 그대로 읽힌다 — read가 남는 변수를 빈 값으로 둔다
    while IFS=$'\t' read -r name cwd kind cmd conv chome || [ -n "$name" ]; do
        [ -n "$name" ] || continue
        case "$name" in \#*) continue ;; esac
        tt_is_uuid "${conv:-}" || conv="-"      # 손상된 줄이 명령줄에 새어들지 않게
        case "${chome:-}" in ''|-) chome="" ;; esac
        # 살아있는 세션도 자기 대화를 "선점"한 것으로 기록해두고 건너뛴다 —
        # 이미 떠 있는 tt-worker와 대장의 worker2가 같은 대화 id를 가리키는 실제 사례가 있었다.
        # 선점을 안 세면 죽은 쪽을 복원할 때 살아있는 세션의 대화에 올라타 도플갱어가 된다.
        if tmux has-session -t "=$name" 2>/dev/null; then
            [ "$conv" = - ] || used="$used $conv"
            printf 'skip   %-16s already running\n' "$name"
            skipped=$((skipped + 1))
            continue
        fi
        # ① 그 대화를 이미 살아있는 claude가 물고 있다 = 이름만 바뀐 채 잘 돌고 있는 세션이다.
        #    되살리면 대화가 둘로 갈라진다 → 아예 건너뛴다(만들 세션이 없는 게 정답).
        if [ "$conv" != - ]; then
            case " $livec " in
                *" $conv "*)
                    printf 'skip   %-16s conversation %s is already open in a live claude\n' "$name" "$conv"
                    skipped=$((skipped + 1))
                    continue ;;
            esac
        fi
        if [ ! -d "$cwd" ]; then
            printf '  note  %s: cwd %s is gone → using %s\n' "$name" "$cwd" "$HOME"
            cwd="$HOME"
        fi
        # ② 대장 안에서 같은 대화 id가 두 줄에 있는 경우(손으로 쓴 대장에 실제로 있었다).
        #    둘 다 죽어 있으니 세션 자체는 되살리되, 두 번째는 선택기로 떨궈 사람이 고르게 한다 —
        #    잘못 이어붙는 것보다 한 번 묻는 게 싸다.
        case " $used " in
            *" $conv "*) [ "$conv" = - ] || { printf '  warn  %s: conversation %s already claimed by another entry → picker instead\n' "$name" "$conv"; conv="-"; } ;;
        esac
        [ "$conv" = - ] || used="$used $conv"
        run=""
        case "$kind" in
            agent)
                a="$cmd"; case "$a" in ''|-) a=claude ;; esac
                case "$a" in
                    claude*)
                        # 대화 파일이 진짜 있는지 확인하고 지목한다. 없는 id로 --resume 하면
                        # "No conversation found with session ID"만 뱉고 셸로 떨어진다(실측:
                        # 메시지를 한 번도 안 주고받은 대화는 transcript 자체가 안 생긴다).
                        # 그럴 땐 인자 없는 --resume = 선택기로 넘겨 사람이 고르게 한다.
                        # 대화 id는 전역 유일하니 프로젝트 폴더 이름을 알아맞힐 필요가 없다(글롭).
                        if [ "$conv" = - ]; then
                            run="claude --resume"
                        elif compgen -G "$HOME/.claude/projects/*/$conv.jsonl" >/dev/null 2>&1; then
                            run="claude --resume $conv"
                        else
                            printf '  note  %s: no transcript for %s → picker instead\n' "$name" "$conv"
                            run="claude --resume"
                        fi
                        # 대화 홈에서 resume — transcript가 글롭으로는 보여도, claude는 '지금 cwd에
                        # 대응하는 프로젝트 폴더'에서만 그 대화를 찾는다. 세션 cwd가 다르면 방금
                        # 찾아낸 id로도 "No conversation found"가 난다(refact-worker 실측).
                        # 서브셸로 감싸는 이유: 세션 자체의 cwd는 대장에 적힌 그대로 두고
                        # resume만 홈에서 돌린다 — claude를 끄면 원래 폴더의 셸로 돌아온다.
                        if [ -n "$chome" ] && [ "$chome" != "$cwd" ]; then
                            if [ -d "$chome" ]; then
                                run="( cd '${chome//\'/\'\\\'\'}' && $run )"
                            else
                                printf '  note  %s: conversation home %s is gone → resuming in %s\n' "$name" "$chome" "$cwd"
                            fi
                        fi ;;
                    codex*)  run="codex" ;;   # codex 대화 재개 방식은 확인되지 않았다 → 단순 기동
                    *)       run="$a" ;;
                esac ;;
            *) case "${cmd:-}" in ''|-) run="" ;; *) run="$cmd" ;; esac ;;
        esac
        if [ "$dry" = 1 ]; then
            printf 'plan   %-16s %-5s %s  @ %s\n' "$name" "$kind" "${run:-<plain shell>}" "$cwd"
            continue
        fi
        if ! tmux new-session -d -s "$name" -c "$cwd" 2>/dev/null; then
            printf 'FAIL   %-16s could not create session\n' "$name"
            continue
        fi
        if [ -n "$run" ]; then
            tmux send-keys -t "=$name:" -l "$run"
            tmux send-keys -t "=$name:" Enter
        fi
        printf 'made   %-16s %-5s %s\n' "$name" "$kind" "${run:-<plain shell>}"
        made=$((made + 1))
        sleep 0.4    # 순차 기동 — claude 열 개를 동시에 띄우면 파이가 무릎을 꿇는다
    done < "$MANIFEST"
    if [ "$dry" = 1 ]; then
        printf 'dry run — %d already running, nothing created\n' "$skipped"
    else
        printf 'restored %d, skipped %d already running\n' "$made" "$skipped"
    fi
    exit 0
fi

