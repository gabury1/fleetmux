# ── 마지막 대화 시각의 진짜 출처: transcript ────────────────────────────────
# 원래는 hook-<sid>의 기록 시각을 "마지막 대화 시각"으로 썼다. 그게 틀렸다는 걸 실측했다:
#   2026-07-25 12:41 부팅 → 13:10 --restore → hook-3/5/8이 전부 13:10으로 갱신 → 함대가 통째로 굵어짐.
#   재부팅하면 tmux가 session id를 0번부터 재발급해서 tt_sweep_hooks가 옛 훅 파일을 유령으로
#   지우고 boot 훅이 새로 만든다 — "이 세션의 것"으로는 맞지만 "마지막 대화"로는 완전히 틀린 값이다.
#
# 대화 기록 파일이 진짜 출처다. 경로는 $HOME/.claude/projects/*/<대화id>.jsonl
#   (대화 id는 전역 유일하니 프로젝트 폴더를 알아맞힐 필요가 없다 — --restore와 같은 글롭).
#
# 단, **파일 mtime은 쓰면 안 된다**(실측으로 함정을 밟았다):
#   claude --resume과 원격제어 브리지가 `{"type":"bridge-session",…}` 줄을 덧붙인다. 이 줄엔
#   timestamp 필드가 없다. 그래서 복원 직후 ULTRACODE의 mtime은 13:10:45인데 마지막 진짜 턴은
#   2026-07-24T16:03:12Z였다 — mtime을 썼으면 버그가 그대로 남는다(직접 확인함).
#   그래서 꼬리 64KB 안의 마지막 "timestamp" 값을 읽는다. 브리지 줄은 timestamp가 없어 저절로 걸러진다.
#
# 비용: 세션 수와 무관하게 tail 1 + awk 1 = 포크 2개.
#   tail은 정규 파일이면 끝으로 seek한다 — 58MB짜리 대화도 실측 1.3ms(4개 묶어서).
#   `stat` 포크 하나가 1.2ms인 걸 감안하면 세션마다 stat을 부르는 것보다 오히려 싸다.
#
# 시각 변환을 date에 안 맡기는 이유: 세션마다 포크가 하나씩 는다. awk에서 직접 계산한다
#   (타임스탬프는 항상 UTC 'Z'). mktime을 안 쓰는 건 mawk에 없어서다(파이 기본이 mawk 1.3.4).
#   정규식 {n} 반복도 피한다 — 구현마다 interval 지원이 다르다(TT_MF_CHECK_AWK과 같은 이유).
# 출력 = "<경로>\t<epoch>" 한 줄씩. timestamp를 못 찾으면 0 — 호출부가 훅 시각으로 폴백한다.
TT_ACT_AWK='
    function iso2epoch(s,   y, mo, d, h, mi, se, yy, era, yoe, doy, doe, days) {
        y  = substr(s, 1, 4) + 0;  mo = substr(s, 6, 2) + 0;  d  = substr(s, 9, 2) + 0
        h  = substr(s, 12, 2) + 0; mi = substr(s, 15, 2) + 0; se = substr(s, 18, 2) + 0
        if (y < 1970 || mo < 1 || mo > 12 || d < 1 || d > 31) return 0
        yy  = y - (mo <= 2 ? 1 : 0)          # 3월을 한 해의 시작으로 옮기면 윤일이 항상 맨 끝
        era = int(yy / 400)
        yoe = yy - era * 400
        doy = int((153 * (mo + (mo > 2 ? -3 : 9)) + 2) / 5) + d - 1
        doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
        days = era * 146097 + doe - 719468   # 146097 = 400년의 일수, 719468 = 0000-03-01→1970-01-01
        return days * 86400 + h * 3600 + mi * 60 + se
    }
    /^==> .* <==$/ {
        if (f != "") print f "\t" (best == "" ? 0 : iso2epoch(best))
        f = substr($0, 5, length($0) - 8); best = ""; next
    }
    {
        # 한 줄에 여러 개가 들어있을 수 있고(긴 줄이 잘려 순서가 뒤집힐 수도 있다) ISO 문자열은
        # 사전순 = 시간순이라 그냥 최대값을 잡는다. "timestamp":" 는 13글자, 값 앞 19글자가 초 단위까지다.
        s = $0
        while (match(s, /"timestamp":"[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]/)) {
            v = substr(s, RSTART + 13, 19)
            if (v > best) best = v
            s = substr(s, RSTART + RLENGTH)
        }
    }
    END { if (f != "") print f "\t" (best == "" ? 0 : iso2epoch(best)) }'

# 목록 생성: 내용 변경 시각 순(진짜 대화·작업이 최근인 세션이 위)
#   세션명 굵게=recent_hours(기본 6시간) 내 대화 있음, 흐리게=그 이상 조용  ●=attached  ✻=Claude 작업중
# 출력 한 줄 = "<이름>\t<표시용 색칠 문자열>". 이름을 탭으로 떼어 앞에 두는 이유:
#   picker가 {1}로 뽑는 값이 공백 든 이름에서도 온전해야 한다. 예전엔 공백 기준 첫 단어만 잘려
#   tmux -t 접두 매칭에 걸려 엉뚱한 세션이 죽었다(실기기 재현). fzf는 --with-nth로 1번 필드를 감춘다.
# 주의: 목록에 괄호 금지 — fzf --bind의 reload(...) 구분자와 충돌한다
if [ "${1:-}" = "--list" ]; then
    now=$(date +%s)
    # 설정은 진입점 맨 위에서 서브셸 아닌 맨 statement 로 한 번만 (05-config.sh 의 계약).
    #   아래 두 값은 루프 밖에서 미리 뽑는다 — 세션마다 다시 물으면 포크가 세션 수만큼 는다.
    #   게다가 표시 루프는 파이프라인(서브셸) 안이라 거기서 읽어봐야 밖으로 못 나온다.
    tt_conf_load
    acc=$(tt_conf_num accent 255)              # 강조색 256색 번호 (이스케이프 안으로 들어간다)
    recent_s=$(( $(tt_conf_num recent_hours) * 3600 ))   # 이 안에 대화가 있으면 이름을 굵게
    # rc 표시 캐시 — 판정은 --cron(1분)가 해두고 여기선 한 줄 읽어 쓴다(포크 0)
    # 캐시가 5분 넘게 낡았으면 = cron이 안 도는 것 → 낡은 ⊘로 겁주지 말고 조용히 끈다
    rcoff=""; rcts=0
    [ -f "$STATE/rc-off" ] && read -r rcts rcoff < "$STATE/rc-off" || true
    [ $(( now - ${rcts:-0} )) -lt 300 ] || rcoff=""
    # ── 활동 시각 사전조사(루프 밖에서 딱 한 번) ─────────────────────────────
    # 대장을 세션마다 다시 읽으면 O(세션수 × 대장줄수)가 된다 — 한 번 읽어 표로 들고 간다.
    # 연관배열은 안 쓴다(bash 4 전용, 맥 기본 3.2에서 깨진다 — tt_sweep_hooks와 같은 판단).
    # 대신 "\n<이름>\t<값>" 줄 표 + case 글롭 조회: 이름에 공백이 있어도 안전하고 포크가 0이다.
    # (매니페스트는 이름에 탭을 금지하므로 탭이 필드 구분자로 안전하다)
    acttab=""; actn=(); actp=()
    if [ -s "$MANIFEST" ]; then
        while IFS=$'\t' read -r mname _ mkind _ mconv _ || [ -n "$mname" ]; do
            [ -n "$mname" ] || continue
            [ "$mkind" = agent ] || continue         # 도구 세션은 어차피 ts=0
            tt_is_uuid "${mconv:-}" || continue      # 대화 id를 모르면 폴백에 맡긴다
            for tf in "$HOME"/.claude/projects/*/"$mconv".jsonl; do
                [ -f "$tf" ] || continue             # 글롭 미스는 패턴 자신이 그대로 남는다
                actn+=("$mname"); actp+=("$tf")
                break                                # 대화 id는 전역 유일 — 첫 놈이 정답
            done
        done < "$MANIFEST"
    fi
    if [ "${#actp[@]}" -gt 0 ]; then
        # /dev/null을 덧붙이는 이유: tail은 파일이 하나뿐이면 "==> …<==" 헤더를 안 찍는다.
        # 항상 다중 파일 모드로 만들어 파싱 분기를 없앤다(빈 파일이라 비용 0).
        actraw=$'\n'$(tail -c 65536 -- "${actp[@]}" /dev/null 2>/dev/null | awk "$TT_ACT_AWK") || actraw=""
        i=0
        while [ "$i" -lt "${#actp[@]}" ]; do
            # 경로로 되찾는다(출력 순서에 기대지 않는다 — 파일이 그 사이에 사라지면 헤더가 빠져 밀린다)
            v=""
            case "$actraw" in
                *$'\n'"${actp[$i]}"$'\t'*) v=${actraw#*$'\n'"${actp[$i]}"$'\t'}; v=${v%%$'\n'*} ;;
            esac
            case "${v:-0}" in ''|*[!0-9]*) v=0 ;; esac
            [ "$v" -gt 0 ] && acttab="$acttab"$'\n'"${actn[$i]}"$'\t'"$v"
            i=$((i + 1))
        done
    fi
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
            # 활동 시각: 에이전트=대화 기록의 마지막 턴 시각(위 사전조사 표) — 훅 시각이 아니다.
            #   폴백 사다리: transcript → 훅 기록 시각 → 신생 세션(1시간 미만)의 생성 시각 → 0.
            #   codex는 대화 id를 훅으로 못 주므로 항상 훅 시각 폴백을 탄다 — 의도한 동작이다.
            #   도구 세션=시각 무관 사전순 (ts 0 고정 → 이름 3차 정렬키가 결정)
            if [ "$grp" = 1 ]; then
                # 훅 파일은 read로 읽는다(예전엔 cut — 세션마다 포크 1개였다). 상태도 같이 필요하다.
                hst=""; hts=0
                read -r hst hts _ < "$STATE/hook-${sid#\$}" 2>/dev/null || true
                case "${hts:-0}" in ''|*[!0-9]*) hts=0 ;; esac
                ats=0
                case "$acttab" in
                    *$'\n'"$name"$'\t'*) ats=${acttab#*$'\n'"$name"$'\t'}; ats=${ats%%$'\n'*} ;;
                esac
                case "${ats:-0}" in ''|*[!0-9]*) ats=0 ;; esac
                if [ "$ats" -gt 0 ]; then
                    ts="$ats"
                    # 훅이 transcript보다 최신인 경우는 딱 하나만 인정한다 — '지금 턴이 도는 중'.
                    #   프롬프트를 막 보냈는데 아직 파일이 안 써진 몇 초를 메운다.
                    #   idle까지 인정하면 안 된다: boot 훅이 쓰는 게 바로 idle이라 복원 시각이
                    #   그대로 "마지막 대화"로 둔갑한다 — 고치려던 버그가 통째로 되살아난다.
                    case "$hst" in
                        working|waiting) if [ "$hts" -gt "$ts" ]; then ts="$hts"; fi ;;
                    esac
                elif [ "$hts" -gt 0 ]; then
                    ts="$hts"
                elif [ $(( now - ${created:-0} )) -lt 3600 ]; then
                    ts="$created"
                else
                    ts=0
                fi
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
                printf '%s\t\033[38;5;%sm%s\033[0m \033[36m%s\033[0m\n' "$name" "$acc" "$name" "$attached"
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
                    # 박제 방지: 갱신이 끊겼는데 다른 근거도 없으면 Stop 유실로 보고 끈다.
                    #   Esc로 턴을 취소하면 Claude Code가 Stop을 안 쏴서 working이 그대로 박제된다(실사용 제보).
                    # 증거 셋을 **OR** 로 쌓는다 — 삭제 조건은 도입 전과 똑같이 "셋 다 아닐 때"뿐이다.
                    #   ① 훅이 신선(≤20초) → 에이전트 본인의 자백이라 가장 정확하고 포크 0. 순서 1위 유지.
                    #   ② CPU 델타(30-state.sh) → 커널 회계라 TUI 문구와 무관하고 포크 0.
                    #      화면보다 앞에 두는 이유: 싸고(포크 0 vs 3) 단단하고, 틀릴 때 "모른다"로 틀려서
                    #      ③이 받아준다. 긍정이면 tmux를 아예 안 불러 팝업이 그만큼 빨리 그려진다.
                    #   ③ 화면 판정 → 렌더링이라 언제든 또 깨지지만(이번 버그) 마지막 보험으로 남긴다.
                    #      CPU 신호가 미탐 쪽으로 틀리는 경우(부하로 굶은 세션·향후 TUI가 대기 중 렌더를
                    #      멈추는 경우)를 여기서만 구할 수 있다.
                    if [ $(( now - ${_hts:-0} )) -le 20 ]; then
                        mark=$'\033[33m✻\033[0m'
                    else
                        cbusy=0; tt_cpu_busy "$sid" "${hpid:-0}" "$now" || cbusy=$?
                        if [ "$cbusy" = 0 ]; then
                            mark=$'\033[33m✻\033[0m'
                        elif tmux capture-pane -p -t "=$name:" 2>/dev/null | tt_working; then
                            mark=$'\033[33m✻\033[0m'
                        else
                            mark=""
                        fi
                    fi
                    # 다음 호출을 위한 표본은 판정 결과와 무관하게 항상 남긴다(ROTATE 안이면 미접촉)
                    tt_cpu_sample "$sid" "${hpid:-0}" "$now" ;;
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
            if [ $(( now - ts )) -lt "$recent_s" ]; then
                printf '%s\t\033[1m%s\033[0m \033[36m%s\033[0m %s %s %s\n' "$name" "$name" "$attached" "$mark" "$umark" "$rcmark"
            else
                printf '%s\t\033[2m%s\033[0m \033[36m%s\033[0m %s %s %s\n' "$name" "$name" "$attached" "$mark" "$umark" "$rcmark"
            fi
        done || true
    # 설정 행 — 항상 목록 맨 끝의 한 줄.
    #   위 파이프라인 *밖*에 둔다. 안에 끼워 넣으면 중간 포맷(grp\tunread\tts\tsid\tattached\tname)의
    #   필드 수가 안 맞아 sort 키와 두 번째 while 의 read 가 통째로 밀린다.
    #   파이프라인에 `|| true` 를 붙인 이유: tmux 서버가 없으면 tmux ls 가 죽고 pipefail 이
    #   그걸 그대로 물려받아 set -e 가 여기까지 오기 전에 스크립트를 끝낸다 — 그러면 세션이
    #   0개일 때 설정 행도 같이 사라진다. 목록이 비었을 때야말로 설정으로 갈 문이 필요하다.
    #   1번 필드가 ASCII '--settings--' 인 이유: 이 값은 --preview·브로드캐스트·부트스트랩
    #   판정에서 문자열 그대로 비교된다. 표시용 이모지를 그 자리에 쓰면 비교하는 곳마다
    #   유니코드 바이트열을 정확히 맞춰야 한다 — 보이는 것과 비교하는 것을 분리한다.
    printf '%s\t%s\n' "$TT_SETTINGS_ROW" $'\033[2m⚙ settings\033[0m'
    exit 0
fi

