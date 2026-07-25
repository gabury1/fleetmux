# 목록 생성: 내용 변경 시각 순(진짜 대화·작업이 최근인 세션이 위)
#   세션명 굵게=6시간 내 대화 있음, 흐리게=그 이상 조용  ●=attached  ✻=Claude 작업중
# 출력 한 줄 = "<이름>\t<표시용 색칠 문자열>". 이름을 탭으로 떼어 앞에 두는 이유:
#   picker가 {1}로 뽑는 값이 공백 든 이름에서도 온전해야 한다. 예전엔 공백 기준 첫 단어만 잘려
#   tmux -t 접두 매칭에 걸려 엉뚱한 세션이 죽었다(실기기 재현). fzf는 --with-nth로 1번 필드를 감춘다.
# 주의: 목록에 괄호 금지 — fzf --bind의 reload(...) 구분자와 충돌한다
if [ "${1:-}" = "--list" ]; then
    now=$(date +%s)
    # rc 표시 캐시 — 판정은 --cron(1분)가 해두고 여기선 한 줄 읽어 쓴다(포크 0)
    # 캐시가 5분 넘게 낡았으면 = cron이 안 도는 것 → 낡은 ⊘로 겁주지 말고 조용히 끈다
    rcoff=""; rcts=0
    [ -f "$STATE/rc-off" ] && read -r rcts rcoff < "$STATE/rc-off" || true
    [ $(( now - ${rcts:-0} )) -lt 300 ] || rcoff=""
    # 내부 파이프는 탭 구분 + 이름을 마지막 필드로 — 공백 든 이름이 필드를 밀어내지 않게.
    #   attached는 빈 값 대신 '-' 센티넬을 쓴다: 탭은 IFS 화이트스페이스라 read가 연속 탭을 하나로
    #   합쳐버려, 미접속 세션에서 필드가 통째로 밀리고 이름이 사라진다(빈 필드 금지).
    #   구분자로 0x1f 같은 제어문자를 쓰는 길은 막혀 있다 — tmux -F가 \037 문자열로 이스케이프해 뱉는다.
    tmux ls -F $'#{session_id}\t#{session_created}\t#{?session_last_attached,#{session_last_attached},0}\t#{?session_attached,●,-}\t#{session_name}' 2>/dev/null \
        | while IFS=$'\t' read -r sid created la attached name; do
            # 에이전트 세션(claude·codex, 그룹 1)이 위, 도구 세션(yazi·htop 등, 그룹 0)은 맨 아래
            grp=0
            # created를 같이 넘긴다: 물려받은 stale 훅 파일을 걸러내는 근거이자, 이미 손에
            # 들고 있는 값이라 tmux 호출이 늘지 않는다. 판정 기준은 tt_is_agent 한 곳에만.
            tt_is_agent "$sid" "$created" && grp=1
            # 활동 시각: 에이전트=훅 이벤트 시각 — 기록 없으면 죽은 세션 취급(0, 흐림·맨 아래)
            #   단 신생 세션(1시간 미만)은 생성 시각 인정 — 만들자마자 보여야 함
            #   도구 세션=시각 무관 사전순 (ts 0 고정 → 이름 3차 정렬키가 결정)
            if [ "$grp" = 1 ]; then
                ts=$(cut -d' ' -f2 "$STATE/hook-${sid#\$}" 2>/dev/null) || {
                    if [ $(( now - ${created:-0} )) -lt 3600 ]; then ts="$created"; else ts=0; fi
                }
            else
                ts=0
            fi
            # 안읽음(부재중 완료 후 미방문) 플래그 — 정렬 2순위로 승격: 볼 게 있는 세션이 맨 위
            #   finished는 신·구 포맷이 섞일 수 있고(마이그레이션 중) 이름에 공백이 들어간다 →
            #   ts 위치로 포맷을 가르고 나머지 전체를 이름으로 봐서 "정확히" 일치할 때만 인정
            unread=0
            if [ -s "$STATE/finished" ]; then
                fts=$(TT_FIN_NAME="$name" awk '
                    BEGIN { want = ENVIRON["TT_FIN_NAME"]; r = 0 }
                    {
                        if ($1 ~ /^[0-9]+$/)                  { t = $1;  s = $0; sub(/^[0-9]+[ \t]+/, "", s) }
                        else if (NF > 1 && $NF ~ /^[0-9]+$/)  { t = $NF; s = $0; sub(/[ \t]+[0-9]+[ \t]*$/, "", s) }
                        else next
                        if (s == want && t + 0 > r) r = t + 0
                    }
                    END { print r }' "$STATE/finished")
                [ "${fts:-0}" -gt 0 ] && [ "${la:-0}" -lt "$fts" ] && unread=1
            fi
            printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$grp" "$unread" "${ts:-0}" "${sid#\$}" "$attached" "$name"
        done | sort -t$'\t' -k1,1rn -k2,2rn -k3,3rn -k6,6 \
        | while IFS=$'\t' read -r grp unread ts sid attached name; do
            [ "$name" = "${TT_CUR:-}" ] && continue
            [ "$attached" = - ] && attached=""    # 센티넬 해제 — 여기서부터는 표시용 빈 문자열
            if [ "$grp" = 0 ]; then   # 도구 세션: 청록, 맨 아래 그룹, 상태 장식 없음
                printf '%s\t\033[38;5;73m%s\033[0m \033[36m%s\033[0m\n' "$name" "$name" "$attached"
                continue
            fi
            # 상태: 훅 기록 우선(정확), 없거나 훅 프로세스가 죽었으면 화면 판정 폴백
            mark=""; hstate=""
            if [ -f "$STATE/hook-$sid" ]; then
                read -r hstate _hts hpid < "$STATE/hook-$sid" || true
                if [ "$hstate" != idle ] && [ "${hpid:-0}" -gt 0 ] && ! kill -0 "$hpid" 2>/dev/null; then hstate=""; fi
            fi
            case "$hstate" in
                working)
                    # 박제 방지: 갱신이 끊겼는데 화면에도 스피너가 없으면 Stop 유실로 보고 끈다.
                    #   Esc로 턴을 취소하면 Claude Code가 Stop을 안 쏴서 working이 그대로 박제된다(실사용 제보).
                    #   창을 20초로 좁혀도 진짜 작업 중엔 화면에 스피너가 있어 안 꺼진다 — 화면이 2차 근거라 안전.
                    if [ $(( now - ${_hts:-0} )) -gt 20 ] \
                        && ! tmux capture-pane -p -t "=$name:" 2>/dev/null | tt_working; then
                        mark=""
                    else
                        mark=$'\033[33m✻\033[0m'
                    fi ;;
                waiting)
                    # 박제 방지: 승인을 거부하면 codex는 Stop을 안 쏜다 —
                    # 60초 넘게 갱신 없는데 화면에 승인 프롬프트가 없으면 취소된 것으로 본다
                    if [ $(( now - ${_hts:-0} )) -gt 60 ] \
                        && ! tmux capture-pane -p -t "=$name:" 2>/dev/null \
                             | grep -qaE 'Would you like to run|Press enter to confirm|Yes, proceed|Do you want to'; then
                        mark=""
                    else
                        mark=$'\033[38;5;215m⏸\033[0m'
                    fi ;;
                idle) ;;
                *) if tmux capture-pane -p -t "=$name:" 2>/dev/null | tt_working; then mark=$'\033[33m✻\033[0m'; fi ;;
            esac
            # 안읽음 ✓: 부재중 완료 후 아직 안 들어가본 세션 (들어가면 사라짐)
            umark=""
            [ "$unread" = 1 ] && umark=$'\033[38;5;108m✓\033[0m'
            # rc ⊘: 폰에서 안 보이는 세션만 표시(연결이 기본값이라 조용해야 함). 빨강=백오프 포기
            rcmark=""
            case " $rcoff " in
                *" $sid=gave "*) rcmark=$'\033[1;38;5;160m⊘\033[0m' ;;
                *" $sid=off "*)  rcmark=$'\033[38;5;245m⊘\033[0m' ;;
            esac
            if [ $(( now - ts )) -lt 21600 ]; then
                printf '%s\t\033[1m%s\033[0m \033[36m%s\033[0m %s %s %s\n' "$name" "$name" "$attached" "$mark" "$umark" "$rcmark"
            else
                printf '%s\t\033[2m%s\033[0m \033[36m%s\033[0m %s %s %s\n' "$name" "$name" "$attached" "$mark" "$umark" "$rcmark"
            fi
        done
    exit 0
fi

