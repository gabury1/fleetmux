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
        oldcmd=""; oldconv=""; oldhome=""; oldkind=""
        if [ -n "$old" ]; then
            # 필드 순서: name·cwd·kind·cmd·conv[·chome] — cmd에 닿으려면 탭 3개를 벗겨야 한다.
            # 2개만 벗기던 시절엔 oldcmd=kind·oldconv=cmd로 한 칸씩 밀려, 스냅샷마다
            # 대화 id 자리에 "claude" 같은 문자열이 눌러앉는 누진 손상이 났다(2026-07-25 사고).
            o=${old#*$'\t'}; o=${o#*$'\t'}; oldkind=${o%%$'\t'*}
            o=${o#*$'\t'};   oldcmd=${o%%$'\t'*}
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
            # ★ 죽은 에이전트를 도구로 강등하지 않는다 — 2026-07-26 사고의 2차 피해.
            #   에이전트가 죽으면 pane 에 맨 셸만 남는다 → tt_is_agent 가 false →
            #   kind=tool 로 기록 → 복원은 kind 로 분기하므로 conv 를 무시하고 맨 셸만 띄운다.
            #   즉 "복원이 가장 필요한 상태"에서 대장이 스스로 복원 능력을 지운다. 1분 cron 이
            #   스냅샷을 돌리므로 백업 3세대도 3분이면 전부 강등본으로 덮인다(실측).
            #   판정: 옛 기록이 agent + 대화 id 살아있음 + pane 이 맨 셸(대체 도구가 안 떴음)
            #   → 죽은 에이전트로 본다. 사람이 그 세션에서 yazi 를 띄웠다면 cmd 가 맨 셸이
            #   아니므로 위 case 에서 걸러져 정상적으로 tool 로 내려간다.
            if [ "$oldkind" = agent ] && [ "$cmd" = "-" ] && tt_is_uuid "$conv"; then
                kind=agent
                cmd="$oldcmd"; case "$cmd" in ''|-) cmd=claude ;; esac
            fi
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
    made=0; skipped=0; used=""; livec=""; verify=""
    TT_SH=$(tt_login_shell)
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
        # 셸을 명시한다 — 서버 전역 default-shell 이 cron 에서 /bin/sh 로 굳어 있어도
        # 우리 세션만은 로그인 bash 로 뜬다(서버 옵션은 무접촉). 2026-07-26 사고의 1차 원인.
        if ! tmux new-session -d -s "$name" -c "$cwd" "$TT_SH" -l 2>/dev/null; then
            printf 'FAIL   %-16s could not create session\n' "$name"
            continue
        fi
        if [ -n "$run" ]; then
            tmux send-keys -t "=$name:" -l "$run"
            tmux send-keys -t "=$name:" Enter
        fi
        printf 'made   %-16s %-5s %s\n' "$name" "$kind" "${run:-<plain shell>}"
        # 검증 대상 적재 — 에이전트만. 도구는 뜨든 말든 대화 유실 위험이 없다.
        case "$kind" in agent) verify="$verify$name"$'\t'"$run"$'\n' ;; esac
        made=$((made + 1))
        sleep 0.4    # 순차 기동 — claude 열 개를 동시에 띄우면 파이가 무릎을 꿇는다
    done < "$MANIFEST"
    # ④ 복원 검증. send-keys 를 쳤다는 건 "글자를 보냈다"는 뜻일 뿐 에이전트가 떴다는 뜻이 아니다.
    #   2026-07-26 사고에서 복원은 커맨드를 정확히 만들어 정확히 쳤고, 로그에도 `made ... agent
    #   claude --resume <id>` 라고 성공으로 찍혔다. 실제로는 pane 셸이 claude 를 못 찾아 5개가
    #   빈 셸로 남았고 아무도 40분간 몰랐다. 성공 판정을 "쳤다"에서 "떴다"로 옮기면 원인이
    #   무엇이든(PATH·셸·대화 id 썩음·바이너리 이동) 걸린다. 위 ①~③은 이번 원인 하나를 막을 뿐이다.
    if [ "$dry" != 1 ] && [ -n "$verify" ]; then
        sleep 12          # 파이에서 claude 기동에 몇 초 걸린다 — 성급히 보면 멀쩡한 것도 실패로 읽는다
        vbad=""
        while IFS=$'\t' read -r vn vrun || [ -n "$vn" ]; do
            [ -n "$vn" ] || continue
            tt_pane_has_agent "$vn" && continue
            printf '  warn  %-16s agent did not come up — retrying once\n' "$vn"
            tmux send-keys -t "=$vn:" -l "$vrun" 2>/dev/null
            tmux send-keys -t "=$vn:" Enter 2>/dev/null
            vbad="$vbad $vn"
        done <<< "$verify"
        if [ -n "$vbad" ]; then
            sleep 12
            vfail=""
            for vn in $vbad; do
                tt_pane_has_agent "$vn" || vfail="$vfail $vn"
            done
            if [ -n "$vfail" ]; then
                printf 'RESTORE INCOMPLETE — agents still down after retry:%s\n' "$vfail"
                # 사람이 볼 흔적을 남긴다. 로그만 남기면 오늘처럼 아무도 모른 채 지나간다.
                printf '%s\n' "$(date '+%Y-%m-%d %H:%M:%S')${vfail}" > "$STATE/restore-failed" 2>/dev/null || true
            else
                printf 'verify — all agents up after retry\n'
                rm -f "$STATE/restore-failed" 2>/dev/null || true
            fi
        else
            printf 'verify — all %d agent(s) came up\n' "$(printf '%s' "$verify" | grep -c .)"
            rm -f "$STATE/restore-failed" 2>/dev/null || true
        fi
    fi
    if [ "$dry" = 1 ]; then
        printf 'dry run — %d already running, nothing created\n' "$skipped"
    else
        printf 'restored %d, skipped %d already running\n' "$made" "$skipped"
    fi
    exit 0
fi

# ── 부팅 자동 복원 (@reboot cron 전용 진입점) ────────────────────────────────
# --restore 를 감싸는 껍데기다. 복원 로직은 한 줄도 다시 쓰지 않는다(도플갱어 방어·transcript
# 확인·대화 홈 cd·0.4초 순차 기동은 전부 --restore 안에 이미 있다). 이 분기가 답하는 질문은
# 딱 하나 — "지금 복원해도 되는 상황인가".
#
# 왜 @reboot 에 --restore 를 그냥 걸면 안 되나. 이 파이의 지난 부팅 journal 실측(2026-07-25):
#   12:41:32  커널 부팅
#   12:41:35  cron 이 @reboot 잡 발사        ← 이 순간 tailscaled 로그가 "network is unreachable"
#   12:41:39  eth0 캐리어 + DHCP 리스(192.168.0.37)
#   12:41:44  tailscaled DERP home 확보 = 이름 해석이 처음 가능해지는 시점
# @reboot 은 네트워크보다 9~12초 빠르다. 그 틈에 claude 10개를 띄우면 전부 껍데기가 된다.
#
# 배치: --restore 분기 바로 뒤. 앞의 분기들은 전부 `[ "$1" = "--xxx" ]` 완전일치라
# "--boot-restore" 가 "--restore" 에 먼저 잡아먹히지 않는다(접두사 매칭이 아니다).
if [ "${1:-}" = "--boot-restore" ]; then
    dry=0; [ "${2:-}" = "--dry" ] && dry=1
    mkdir -p "$STATE"
    BOOTLOG="$STATE/boot.log"
    # 이 기능은 사람이 안 보는 시각에 딱 한 번 돌고, 실패해도 조용하다 → 로그가 유일한 증거다.
    # 그래서 판정 하나하나를 다 남긴다. 회전은 hook.log 와 같은 정책을 재사용한다.
    blog() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$BOOTLOG"; }
    TT_LOG_FILE="$BOOTLOG" tt_log_rotate
    blog "=== boot-restore start (dry=$dry, pid $$)"

    # ① 킬 스위치. "재부팅은 하되 함대는 안 떴으면" 하는 상황이 있다(커널 교체·디스크 정리 뒤
    #    관찰, 손으로 함대를 재편하는 중). 사람이 파일 하나로 끌 수 있어야 하고, 지우면 다음
    #    부팅부터 다시 산다. 끈 것은 고장이 아니므로 성공 코드로 나간다.
    if [ -f "$STATE/no-autorestore" ]; then
        blog "kill switch present ($STATE/no-autorestore) — nothing done"
        exit 0
    fi

    # ② PATH 보정. cron 의 PATH 는 사실상 /usr/bin:/bin 뿐이다.
    #    이 파이에서 `env -i PATH=/usr/bin:/bin` 으로 직접 확인한 결과:
    #      tmux flock getent jq pgrep awk date → /usr/bin 에 있다. 여기까진 cron PATH 로도 산다.
    #      claude codex fzf → 없다(claude=~/.npm-global/bin, 훅주입 wrapper=~/.local/libexec/tt,
    #      fzf=~/.local/bin).
    #    복원이 pane 에 치는 `claude --resume` 자체는 사실 pane 의 로그인 셸이 .profile→.bashrc 를
    #    다시 읽어 PATH 를 복구하므로 살아난다(격리 소켓에서 실측: 빈약한 PATH 로 띄운 서버의
    #    pane 안에서도 PATH 가 정상이었다). 그럼에도 여기서 고치는 이유는 tmux **서버**다 —
    #    서버를 우리가 cron 환경에서 띄우면 그 빈약한 PATH 가 서버 전역 환경으로 굳어 다음
    #    재부팅까지 남는다(실측: show-environment -g PATH = /usr/bin:/bin). 그 뒤 tmux 가
    #    비로그인으로 돌리는 것들(run-shell·훅·--preview)이 조용히 깨진다.
    #    순서 주의: 앞에 붙이므로 아래 나열은 우선순위의 '역순'이다. 최종적으로 libexec/tt 가
    #    맨 앞이어야 한다 — 그게 뒤로 가면 훅 주입 wrapper 를 건너뛴 맨 claude 가 떠서
    #    함대 상태판(hook-*)이 통째로 죽는다.
    for d in "$HOME/.npm-global/bin" "$HOME/.local/bin" "$HOME/.local/libexec/tt"; do
        [ -d "$d" ] || continue
        case ":$PATH:" in *":$d:"*) ;; *) PATH="$d:$PATH" ;; esac
    done
    export PATH

    # ②-2 SHELL 보정. PATH 와 똑같은 함정이 $SHELL 에도 있다 — 그리고 이쪽이 더 아팠다.
    #   cron 의 $SHELL 은 /bin/sh 다. 아래 ⑥에서 우리가 tmux **서버**를 낳으면 그 값이
    #   서버 전역 default-shell 로 굳어(서버가 죽을 때까지 불변) 이후 만들어지는 모든 pane 이
    #   dash 가 된다. dash 는 .bashrc 를 안 읽으므로 사용자 PATH 가 통째로 날아가고,
    #   복원이 친 `claude --resume` 이 전부 `claude: not found` 로 떨어진다.
    #   2026-07-26 실측: 자동복구 첫 실전에서 agent 5개가 빈 셸로 떴고 상태판은 40분간 초록이었다.
    #   위 PATH 루프가 이걸 못 막는 이유 — 우리 프로세스의 PATH 는 고쳤지만 pane 은 로그인 셸이
    #   /etc/profile 을 다시 읽으면서 PATH 를 통째로 덮어쓰기 때문이다.
    SHELL=$(tt_login_shell); export SHELL

    # ③ 중복 실행 방지. --cron 의 rc.lock 과 같은 방식(flock -n, fd 9).
    #    --restore 의 "이미 살아있으면 skip" 검사는 세션이 *만들어진 뒤에야* 참이다.
    #    두 인스턴스가 나란히 돌면 둘 다 "없다"고 읽고 같은 대화를 두 번 연다 = 도플갱어.
    #    아래 네트워크 대기가 최대 120초라 그 창이 활짝 열려 있다 → 락은 대기보다 먼저 잡는다.
    #
    #    ★ fd 9 는 아래에서 자식에게 물려주지 않는다(9>&-). 격리 시험에서 실제로 밟은 함정이다:
    #      --restore 가 부른 `tmux new-session` 이 서버를 띄우면 그 **데몬**이 fd 9 를 상속하고,
    #      데몬은 재부팅까지 안 죽으니 락이 영원히 잡힌 채로 남는다. 실측 —
    #        PID 326033 /usr/bin/tmux -L fmuxtest new-session -d -s zzh-alpha
    #        /proc/326033/fd/9 -> …/state/boot-restore.lock
    #      그 뒤로는 사람이 손으로 친 --boot-restore 까지 전부 "already holds the lock" 으로
    #      튕겼다. 중복을 막으려던 장치가 유일한 수동 재시도를 막는 꼴 — ⑤의 실패 모드와 판박이다.
    if command -v flock >/dev/null 2>&1; then
        exec 9>"$STATE/boot-restore.lock"
        if ! flock -n 9; then
            blog "another boot-restore already holds the lock — exiting"
            exit 0
        fi
    else
        blog "warn: flock not found — running without a duplicate-run guard"
    fi

    # ④ 부팅 맥락 확인. @reboot 전용이지만 사람이 손으로 칠 수도 있고 그건 정당한 용법이라
    #    막지 않는다. 다만 나중에 로그를 읽을 때 "재부팅 직후였나 아니었나"를 구분할 수 있어야 한다.
    up=$(cut -d' ' -f1 /proc/uptime 2>/dev/null) || up=""
    up=${up%%.*}
    case "${up:-x}" in
        ''|*[!0-9]*) blog "warn: cannot read uptime — proceeding anyway" ;;
        *) if [ "$up" -gt 600 ]; then
               blog "warn: uptime ${up}s > 600s — this is not a fresh boot (manual run?); proceeding"
           else
               blog "uptime ${up}s — fresh boot"
           fi ;;
    esac

    # ⑤ 네트워크·DNS 준비 대기. 타임아웃이면 복원하지 '않고' 죽는다.
    #    왜 "일단 띄우고 보자"가 아닌가: 네트워크 없이 뜬 claude 는 즉시 실패하고 pane 에 셸만
    #    남긴다. 그런데 tmux 세션 이름은 멀쩡히 살아있으므로, 나중에 사람이 --restore 를 쳐도
    #    전부 "skip — already running" 으로 걸러진다. 즉 실패한 자동복원이 성공할 수동복원을
    #    막아버린다. 아무것도 안 만든 채 죽는 편이 사람이 고치기 훨씬 싸다.
    #
    #    판정으로 이름 해석(getent hosts)을 고른 근거 — 이 파이에서 직접 확인:
    #      /etc/resolv.conf 는 tailscale 이 쓴 것이고 nameserver 가 100.100.100.100(MagicDNS)뿐이다.
    #      MagicDNS 로 공인 도메인이 풀리려면 tailscaled 가 떠 있고 업스트림까지 실제로 닿아야 한다
    #      → 성공 = 링크·라우팅·DNS 가 전부 살아있다는 뜻. 평범한 DNS 를 쓰는 박스보다 강한 신호다.
    #      캐시 오탐도 콜드부트에선 없다: tailscaled 가 새로 뜨면 캐시가 비어 있다.
    #      실측 — 성공 6~10ms(10회 54ms) / 없는 이름은 즉시 rc=2. 판정이 싸서 2초 간격이 아깝지 않다.
    #    그래도 timeout 으로 감싼다: 응답 없는 리졸버를 만나면 glibc 는 5초×2회×서버수를 통째로 끈다.
    #    DNS 만으로는 부족한 구멍(이름은 풀리는데 라우팅이 아직)을 위해 443 TCP 로 한 번 더 본다.
    #    /dev/tcp 는 bash 내장이라 curl 의존이 안 붙는다(실측 42ms).
    NETHOST=${TT_BOOT_NETHOST:-api.anthropic.com}
    NETWAIT=${TT_BOOT_NETWAIT:-120}
    t0=$(date +%s); netok=0
    while :; do
        # 호스트명을 명령 문자열에 이어붙이지 않고 $1 로 넘긴다(따옴표 escape 는 바깥 셸이
        # 미리 풀어버리지 않게 하려는 것 — 안쪽 bash 가 볼 때 "$1" 형태여야 한다)
        if timeout 5 getent hosts "$NETHOST" >/dev/null 2>&1 &&
           timeout 5 bash -c "exec 3<>/dev/tcp/\"\$1\"/443" _ "$NETHOST" 2>/dev/null; then
            netok=1; break
        fi
        el=$(( $(date +%s) - t0 ))
        [ "$el" -lt "$NETWAIT" ] || break
        sleep 2
    done
    el=$(( $(date +%s) - t0 ))
    if [ "$netok" != 1 ]; then
        blog "ABORT: no DNS+tcp/443 to $NETHOST after ${el}s (budget ${NETWAIT}s) — refusing to restore"
        blog "       (a fleet of network-less claudes would look 'already running' and block the manual retry)"
        exit 1
    fi
    blog "network ready after ${el}s — $NETHOST resolves and tcp/443 connects"

    # ⑥ tmux 서버. new-session 이 알아서 띄우긴 하지만, 명시적으로 띄워야 여기서 실패를 잡는다
    #    (소켓 디렉토리 권한·/tmp 미마운트 등 부팅 직후에만 나는 문제들). 서버가 이미 있으면
    #    완전한 no-op 다 — 세션도 윈도도 만들지 않는다.
    #    9>&- : 여기서 뜨는 서버 데몬이 락 fd 를 물고 재부팅까지 안 놓는 사고를 막는다(③ 참조).
    if ! tmux start-server 9>&- 2>>"$BOOTLOG"; then
        blog "ABORT: tmux start-server failed"
        exit 1
    fi

    # ⑦ 복원 명세. 없거나 비었으면 할 일 자체가 없다 — --restore 도 같은 판정을 하지만
    #    여기서 먼저 걸러야 로그에 이유가 남는다.
    if [ ! -s "$MANIFEST" ]; then
        blog "ABORT: no manifest at $MANIFEST — nothing to restore"
        exit 1
    fi
    # 낡음은 경고만. --cron 이 1분마다 --snapshot 을 돌리므로 7일보다 오래된 대장은
    # "그동안 fmux cron 이 아예 안 돌았다"는 뜻이다(파이가 꺼져 있었거나 fmux 가 빠졌거나).
    # 그래도 막지 않는다 — 낡은 명세라도 없는 것보다 낫고, 줄 하나하나는 --restore 가 다시
    # 검증한다(살아있는 대화 선점·transcript 존재·cwd 존재). 7일인 이유는 그보다 짧으면
    # 여행·정전으로 파이가 며칠 꺼져 있던 정상 상황에서 매번 경고가 뜨기 때문.
    # 기간 비교에 stat 을 안 쓰는 이유는 tt_log_rotate 와 같다 — GNU 와 BSD 의 옵션이 정반대다.
    # `find -mtime +7` 은 POSIX 라 양쪽에서 똑같이 돈다.
    if [ -n "$(find "$MANIFEST" -mtime +7 2>/dev/null)" ]; then
        blog "warn: $MANIFEST is older than 7 days — restoring it anyway"
    fi

    # ⑧ 여기부터가 실제 복원. --restore 의 출력을 통째로 남긴다 —
    #    무엇을 만들고 무엇을 왜 건너뛰었는지가 나중에 유일한 증거다.
    #    인자는 배열로 넘긴다 — `set -- --restore --dry` 로 위치인자를 갈아끼우면 이 아래에
    #    남은 분기들(--list·팝업 진입점)이 보는 "$1" 까지 바뀐다. 지금은 바로 exit 하니 무해하지만
    #    이 블록이 언젠가 위로 올라가면 그날 조용히 터진다.
    rargs=(--restore)
    if [ "$dry" = 1 ]; then rargs+=(--dry); fi
    blog "handing over to: $SELF ${rargs[*]}"
    rc=0
    #    9>&- : --restore 가 띄우는 tmux 서버 데몬에게 락 fd 를 물려주지 않는다(③ 참조).
    #    락 자체는 이 프로세스가 끝날 때까지 그대로 유지된다 — 닫는 건 자식 쪽 사본뿐이다.
    out=$("$SELF" "${rargs[@]}" 9>&- 2>&1) || rc=$?
    printf '%s\n' "$out" | while IFS= read -r l; do blog "  | $l"; done
    printf '%s\n' "$out"
    blog "=== boot-restore done (restore rc=$rc)"
    exit "$rc"
fi

