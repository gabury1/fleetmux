# 상태바용 함대 집계 "⏸2 ✻3" — 가장 급한 신호(⏸)가 팝업을 열어야만 보이던 문제를 없앤다.
#   색은 --list 팔레트 그대로(⏸ 주황 215, ✻ 노랑 33). 0이면 생략.
#
# 여기가 CPU 스냅샷의 **샘플러**이기도 하다. 상태바는 status-interval 5로 5초마다 돌아
# (.tmux.conf 의 `#(tt --status)`) working 세션의 표본을 갱신한다 — 덕분에 팝업(--list)은
# 언제 열려도 3~10초짜리 신선한 창을 sleep 0으로 얻는다. 샘플러를 여기 두는 것이 설계의 축이다.
#
# 판정 규칙과 --list 의 관계(EVIDENCE.md: "상태바엔 ✻4, 목록엔 마크 없음"):
#   --list 는 증인을 셋 쌓는다 — ①훅 신선(≤20초) ②CPU 델타 ③화면(capture-pane). 여기는
#   ③이 없다: 세션 이름을 모르고, 5초마다 함대 전체를 capture-pane 하는 건 비용상 불가다.
#   증인이 하나 없는 채로 "지운다"를 흉내내면 --list 보다 **더 공격적으로** ✻ 를 지우게 된다 —
#   그건 규칙을 맞추는 게 아니라 어긋나게 하는 것이다. 그래서 여기서는 훅이 working 이면
#   무조건 센다. 그러면 불일치가 한 방향으로만 남는다 — **훅이 있는 세션에 한해**
#   상태바 ✻n ≥ 팝업 마크 개수. (훅 파일이 없는 세션은 여기 시야 밖이라 이 부등식의 대상이
#   아니다. 그건 규칙 불일치가 아니라 관측 범위 차이다.)
#   t-10 이 훅 신선/낡음 × CPU rc0/rc1/rc2 × 화면 매치/불일치 12칸의 기대값과 이 부등식을
#   격자로 못박는다.
tt_fleet_agg() {
    local f st ts pid w=0 k=0 out="" now sid wids="" wnames="" wshown=0 nm line
    now=$(date +%s)
    for f in "$STATE"/hook-*; do
        [ -f "$f" ] || continue
        st=""; ts=0; pid=0
        read -r st ts pid < "$f" 2>/dev/null || true
        case "$st" in waiting|working) ;; *) continue ;; esac
        # 훅 프로세스가 죽었으면 박제된 상태 — 세지 않는다(--list의 생존 판정과 같은 기준)
        case "${pid:-0}" in ''|*[!0-9]*) pid=0 ;; esac
        [ "$pid" -gt 0 ] && ! kill -0 "$pid" 2>/dev/null && continue
        case "${ts:-0}" in ''|*[!0-9]*) ts=0 ;; esac
        case "$st" in
            waiting)
                w=$((w + 1))
                # 어느 세션이 막혀 있는지까지 기억한다 — ⏸ 는 **사람이 손대야 끝나는** 상태다.
                # 개수만 띄우면 "누구야?"를 알려고 팝업을 열어야 하는데, 그 한 번이 곧 지연이다.
                # (✓ 는 이미 이름을 단다. 더 급한 ⏸ 가 이름이 없던 게 거꾸로였다.)
                wids="$wids ${f##*/hook-}" ;;
            working)
                sid=${f##*/hook-}
                # 훅이 working 이면 **무조건 센다** — 여기엔 3순위 증인(화면)이 없다.
                #   CPU 가 rc1(확실히 유휴)이라고 답해도 빼지 않는다. 실측: 도구 호출 응답을
                #   기다리는 claude 는 3~22 cs/s 사이를 오가며 임계 6 을 계속 가로지른다
                #   (3초 창의 24% 가 임계 미달). 5초마다 도는 상태바에서 단발 창 하나로 뱃지를
                #   끄면 진짜 일하는 세션의 ✻n 이 깜빡인다 — 고치려던 병 그 자체다.
                #   박제 해제는 화면 증인이 서는 --list 에만 맡긴다(미탐 > 오탐: ✻n 은 개수
                #   뱃지라 하나 더 세는 건 싸고, 덜 세면 부재중 함대를 통째로 놓친다).
                k=$((k + 1))
                # ★샘플러는 반드시 남는다 — 상태바가 5초마다 여기서 표본을 회전시키는 것이
                #   CPU 델타 설계의 축이다. 이 줄이 없으면 팝업(--list)이 열릴 때 쓸 표본이
                #   아예 없어 tt_cpu_busy 가 영구 rc2 가 되고 C 전체가 죽는다.
                tt_cpu_sample "$sid" "$pid" "$now" ;;
        esac
    done
    # ⏸ 이름 붙이기. tmux 조회는 **딱 한 번** — 이 함수는 상태바가 5초마다 부른다.
    #   세션당 display-message 를 부르면 대기 세션 수만큼 포크가 는다.
    if [ "$w" -gt 0 ]; then
        wnames=$(tmux list-sessions -F '#{session_id} #{session_name}' 2>/dev/null || true)
        if [ -n "$wnames" ]; then
            for sid in $wids; do
                nm=""
                while read -r line; do
                    case "$line" in "\$$sid "*) nm=${line#* }; break ;; esac
                done <<< "$wnames"
                [ -n "$nm" ] || continue
                # 셋까지만 적고 나머지는 +n — 상태바는 폭이 좁고, 넘치면 tmux 가 통째로 자른다.
                if [ "$wshown" -lt 3 ]; then
                    out="$out#[fg=colour215,bold]⏸ $nm #[default]"
                    wshown=$((wshown + 1))
                fi
            done
            [ "$w" -gt "$wshown" ] && out="$out#[fg=colour215,bold]+$((w - wshown)) #[default]"
        fi
        # 이름을 하나도 못 얻었으면(서버가 없거나 조회 실패) 예전처럼 개수만이라도 띄운다.
        [ "$wshown" = 0 ] && out="$out#[fg=colour215,bold]⏸ $w #[default]"
    fi
    [ "$k" -gt 0 ] && out="$out#[fg=yellow,bold]✻$k #[default]"
    printf '%s' "$out"
    return 0
}

# 에이전트 훅 수신부: claude/codex 훅이 이벤트마다 호출 — 화면 긁기보다 정확한 상태 소스
#   claude: working(UserPromptSubmit/PostToolUse) / idle(Stop) / waiting(Notification) / clear(SessionEnd)
#   codex : working(UserPromptSubmit/PreToolUse) / idle(Stop) / waiting-codex(PermissionRequest)
# 훅은 에이전트 프로세스 환경에서 돌아 $TMUX_PANE으로 자기 세션을 안다 (세션 매핑 문제 해결)
if [ "${1:-}" = "--hook" ]; then
    st="${2:-}"
    [ -n "${TMUX_PANE:-}" ] || exit 0
    # 세션 정보를 한 번에 묻는다. 매니페스트 기록엔 이름·cwd·명령도 필요한데 display-message를
    # 이벤트마다 여러 번 부르면 훅 지연이 그만큼 늘어난다 — 호출 횟수는 예전(1회)과 똑같이 유지하고
    # 아래 idle/boot 분기가 다시 묻던 것(#S·session_attached)까지 여기서 흡수했다.
    sid=""; sname=""; spath=""; scmd=""; satt=1
    IFS=$'\t' read -r sid sname spath scmd satt < <(tmux display-message -p -t "$TMUX_PANE" \
        $'#{session_id}\t#{session_name}\t#{pane_current_path}\t#{pane_current_command}\t#{session_attached}' 2>/dev/null) || true
    # rc=0인데 빈 출력이 나오는 경합이 있다(pane이 막 사라지는 중). 그냥 두면 "hook-"이라는 빈 이름
    # 파일이 생기고 clear는 그것만 지운 채 끝나 진짜 상태 파일이 고아로 남는다(hook-21·33 실측).
    [ -n "$sid" ] || exit 0
    # stdin 페이로드는 이벤트마다 온다(claude: session_id=대화 id, cwd, hook_event_name).
    # 한 번만 읽는다 — waiting 판정과 매니페스트 기록이 같은 스트림을 두 번 읽을 수는 없다.
    # stdin이 tty면(사람이 손으로 tt --hook을 친 경우) 읽지 않는다 — 통째로 2초를 기다리게 된다.
    payload=""
    [ -t 0 ] || IFS= read -r -d '' -t 2 payload || true
    mkdir -p "$STATE"
    hf="$STATE/hook-${sid#\$}"
    echo "$(date '+%F %T') $sid $st" >> "$STATE/hook.log"   # 이벤트 감사 로그 (오탐 추적용)
    # 부모 체인을 올라가 에이전트 본체 PID를 찾는다 ($PPID는 일회용 셸일 수 있음) — 죽은 세션 감지용
    #   tt_comm을 쓰는 이유: macOS ps는 comm에 절대경로를 준다 — 생짜 비교면 맥에서 영영 안 걸린다
    cpid=$PPID
    while [ "$cpid" -gt 1 ]; do
        case "$(tt_comm "$cpid" || true)" in claude|codex) break ;; esac
        cpid=$(ps -p "$cpid" -o ppid= 2>/dev/null | tr -d ' ') || { cpid=0; break; }
        [ -n "$cpid" ] || { cpid=0; break; }
    done
    case "$(tt_comm "${cpid:-0}" || true)" in claude|codex) ;; *) cpid=0 ;; esac
    case "$st" in
        waiting)
            # Notification 페이로드는 크게 두 갈래다:
            #   ① 사용자 조작 요구 — "Claude needs your permission to use Bash", 플랜 승인·질문 대기
            #   ② 단순 유휴 알림 — "Claude is waiting for your input" (입력창이 60초 비면 발화)
            # 예전엔 'permission' 문구만 ⏸로 인정해서 플랜 승인·AskUserQuestion 대기를 통째로 놓쳤다.
            # 그래서 화이트리스트를 뒤집어 ②만 걸러낸다: 문구가 바뀌어도 안 깨지고, 새로 생기는
            # 알림 종류는 기본적으로 ⏸로 잡힌다. 여기선 미탐이 오탐보다 비싸다 —
            # 오탐은 다음 working/idle 훅이 즉시 자기교정하지만, 미탐은 부재중 대기를 영영 못 본다.
            # 페이로드를 못 읽으면(빈 stdin) 판단 근거가 없으니 무시 — 예전과 같은 보수적 동작.
            # (payload는 위에서 한 번만 읽어둔다 — 매니페스트 기록도 같은 걸 쓴다)
            # 소문자 접기는 tr 로 한다 — ${payload,,} 는 bash 4.0 전용 문법이고, 맥 기본
            # /bin/bash 는 3.2 다. 파싱은 통과하고 **확장 시점에** 죽어서, 증상이
            # "설치도 되고 목록도 뜨는데 ⏸ 만 영영 안 뜬다" 라는 침묵이 된다(팀 배포 게이트 B6).
            # 05-config.sh 의 tt_conf_envname 이 같은 이유로 ${var^^} 를 피한다 — 이 레포의 관례다.
            # t-14 가 src/*.sh 전체에서 bash4 전용 문법을 다시 잡는다(재발 방지).
            case "$(printf '%s' "$payload" | tr '[:upper:]' '[:lower:]')" in
                "") ;;                                                 # 근거 없음 → 무시
                *"waiting for your input"*|*"waiting for input"*) ;;    # 단순 유휴 → ⏸ 아님
                *) echo "waiting $(date +%s) $cpid" > "$hf" ;;
            esac ;;
        waiting-codex)
            # codex PermissionRequest는 이벤트 자체가 승인 대기 — stdin 판별 불필요
            echo "waiting $(date +%s) $cpid" > "$hf" ;;
        working)
            now=$(date +%s)
            echo "$st $now $cpid" > "$hf"
            # 마지막 프롬프트 적재 — working 은 UserPromptSubmit·PostToolUse·PreCompact·
            #   PostCompact(codex 는 PreToolUse 까지)가 **공유하는** 한 갈래다. 그래서 여기서
            #   $st 만 보고는 프롬프트 제출인지 알 수 없다 → 게이팅은 payload 의
            #   hook_event_name 으로 함수 안에서 한다. 프롬프트 제출이 아니면 포크 0으로 즉시 반환.
            #   실패해도 조용히 통과한다 — 상태 파일은 이미 위에서 써 뒀다(부가물 원칙).
            tt_last_prompt_save "$sid" "$payload" "$now" ;;
        idle)
            prev=$(cut -d' ' -f1 "$hf" 2>/dev/null || true)
            echo "idle $(date +%s) $cpid" > "$hf"
            if [ "$prev" = working ] || [ "$prev" = waiting ]; then
                name="$sname"                      # 위에서 이미 물어봤다(포크 절약)
                [ -n "$name" ] || exit 0
                att="${satt:-1}"
                if [ "$att" = 0 ]; then
                    # 락 필수: 상태바가 5초마다 같은 파일을 통째로 재작성한다 — 안 잡으면 이 알림이 유실
                    tt_finished_lock
                    tt_finished_rewrite "$name"   # 정규화 + 같은 세션의 옛 기록 제거(sed 대체)
                    echo "$(date +%s) $name" >> "$STATE/finished"   # 상태바 뱃지 + 목록 안읽음 표시
                    tt_finished_unlock
                    tmux list-clients -F '#{client_name}' 2>/dev/null | while read -r c; do
                        tmux display-message -c "$c" -d 8000 "✓ $name done"
                    done
                fi
            fi ;;
        clear)
            # CPU 스냅샷은 훅 파일의 수명에 완전히 종속된다 — 정리 규칙을 두 벌로 나누면
            # "지웠는데 또 믿는" 모순이 난다(tt_sweep_hooks 주석의 기존 판단과 같은 결).
            #   마지막 프롬프트도 같은 자리에서 지운다 — 세션이 끝났는데 "내가 뭘 시켰지"만
            #   남아 다음 세션 프리뷰에 걸리면 안 된다(sweep 과 같은 판단).
            rm -f "$hf" "$STATE/cpu-${sid#\$}" "$STATE/last-${sid#\$}" ;;
        boot)
            # 에이전트 부팅 자백 — 즉시 에이전트 세션으로 분류 + 예약된 /rename 실행
            #   claude: SessionStart 훅   codex: wrapper가 exec 직전에 직접 발신
            # 고아·유령 sweep 먼저 — 재부팅 후 세션 id 재발급 사고 방지. --restore도 같은 함수를 쓴다.
            #   순서가 중요하다: 내 파일을 만든 뒤에 쓸면 방금 만든 걸 지울 일은 없지만,
            #   물려받은 유령 파일이 있을 때 "이미 있음"으로 건너뛰면 남의 상태를 그대로 입는다.
            #   쓸고 나서 없으면 만든다 = 어느 쪽이든 이 세션의 pid가 박힌 파일이 남는다.
            tt_sweep_hooks
            [ -f "$hf" ] || echo "idle $(date +%s) $cpid" > "$hf"
            # 회전 임계(log_max)를 설정에서 읽으므로 캐시를 먼저 세운다 — 서브셸 아닌 맨
            # statement (05-config.sh 의 계약). 훅 경로에서 설정을 읽는 곳은 여기 하나뿐이라
            # 진입점 맨 위가 아니라 회전 바로 앞에 둔다: 이벤트마다 도는 working/idle 경로는
            # 설정을 한 글자도 안 읽는다.
            tt_conf_load
            tt_log_rotate   # cron이 안 깔린 환경에서도 감사 로그가 무한히 자라지 않게
            name="$sname"                          # 위에서 이미 물어봤다(포크 절약)
            [ -n "$name" ] || exit 0
            pr="$STATE/pending-rename-$name"
            if [ -f "$pr" ]; then
                # TTL 5분. 기동에 실패해 소비되지 않은 예약이 몇 주 뒤 동명 세션에 되살아나
                # /rename을 주입하는 사고가 있었다(codex엔 그런 슬래시 명령도 없다).
                read -r pts _ < "$pr" 2>/dev/null || pts=0
                case "${pts:-0}" in ''|*[!0-9]*) pts=0 ;; esac
                rm -f "$pr"
                if [ $(( $(date +%s) - pts )) -le 300 ]; then
                    ( sleep 1
                      tmux send-keys -t "$TMUX_PANE" -l "/rename $name"
                      sleep 0.5
                      tmux send-keys -t "$TMUX_PANE" Enter ) >/dev/null 2>&1 &
                fi
            fi ;;
    esac
    # ── 함대 대장 자동 기록 ──────────────────────────────────────────────────
    # 훅은 "어느 tmux 세션"(TMUX_PANE)과 "어느 대화"(stdin의 session_id)를 동시에 아는 유일한
    # 지점이다 — 대화 id가 공짜로 굴러들어온다. 여기서 주워 담아두면 사용자가 --snapshot을
    # 한 번도 안 쳐도 복원표가 항상 최신이다(사용자 개입 0).
    # 비용: 포크 0(전역 반환 tt_jv + 문자열 연산) + 내용이 같으면 파일 미접촉. 실패해도 조용히 통과.
    # 대화 홈(6번째 필드)도 여기서만 정확하다: stdin의 cwd는 claude 자신의 cwd이고,
    # claude는 바로 그 값으로 ~/.claude/projects/<인코딩된 cwd>/ 를 계산해 대화를 찾는다.
    # 세션 cwd(pane_current_path)와는 별개다 — 둘을 한 필드에 뭉개던 게 복원 실패의 원인이었다.
    if [ -n "$sname" ]; then
        mconv=""; mhome=""
        if [ -n "$payload" ]; then
            tt_jv "$payload" session_id && mconv="$TT_JV" || true   # claude 훅의 대화 id
            # 대화 홈: cwd 를 그대로 믿으면 안 된다. 훅은 **서브에이전트도 쏘고**, 그 payload 의
            # cwd 는 서브에이전트가 일하던 디렉토리다. 그걸 홈으로 적으면 복원이
            #   ( cd '<엉뚱한 곳>' && claude --resume <id> )
            # 를 돌리고, claude 는 그 cwd 로 인코딩된 폴더에서 대화를 못 찾아 실패한다.
            # (2026-08-06 실측: tui-worker·membership·ops 세 줄이 이렇게 깨져 복원이 죽었다.)
            #
            # transcript_path 가 진실을 안다 — ~/.claude/projects/<홈을 인코딩한 이름>/<id>.jsonl.
            # 그래서 cwd 를 인코딩해 그 폴더 이름과 **같을 때만** 홈으로 채택한다.
            # 어긋나면 빈 값으로 넘겨 기존 기록을 보존한다(디코딩은 안 한다 — '-' 가 든 디렉토리
            # 이름이 있으면 인코딩이 되돌릴 수 없다: _myproject → -home-...-_myproject).
            mhome=""
            if tt_jv "$payload" cwd; then
                _hcwd="$TT_JV"
                if tt_jv "$payload" transcript_path; then
                    _hdir=${TT_JV%/*}; _hdir=${_hdir##*/}          # 인코딩된 폴더 이름
                    case "$(printf '%s' "$_hcwd" | tr '/' '-')" in
                        "$_hdir") mhome="$_hcwd" ;;                 # 일치 → 이 cwd 가 진짜 홈이다
                    esac
                fi
            fi
        fi
        # pane 명령은 도구 실행 중엔 claude가 아닐 수 있다(자식이 tty 전면에 올 때) →
        # 확실할 때만 적고 아니면 빈 값으로 넘겨 기존 기록을 보존한다.
        case "$scmd" in claude|codex) mcmd="$scmd" ;; *) mcmd="" ;; esac
        tt_mf_upsert "$sname" "$spath" agent "$mcmd" "$mconv" "$mhome" || true
    fi
    exit 0
fi

# 상태바: 함대 집계(⏸n ✻n) + 끝난 세션 ✓이름 뱃지
#   뱃지는 그 세션에 들어가보거나 unseen_minutes(기본 10분) 지나면 소멸.
#   .tmux.conf status-right의 #(tt --status)가 5초마다 호출
if [ "${1:-}" = "--status" ]; then
    f="$STATE/finished"
    now=$(date +%s)
    # 설정은 진입점 맨 위에서 서브셸 아닌 맨 statement 로 한 번만 (05-config.sh 의 계약).
    # 이 경로는 상태바가 5초마다 부른다 — 깨진 줄 하나가 조회 횟수만큼 경고를 뿜으면 안 된다.
    tt_conf_load
    unseen_s=$(( $(tt_conf_num unseen_minutes) * 60 ))
    agg=$(tt_fleet_agg)     # finished와 무관한 집계라 락 밖에서 먼저
    out=""
    if [ -s "$f" ]; then
        tt_finished_lock
        tt_finished_rewrite     # 구포맷 마이그레이션 + poison 라인 제거
        keep=""
        while read -r ts name; do
            case "$ts" in ''|*[!0-9]*) continue ;; esac   # 숫자 아닌 줄은 버린다(영구 잔존 차단)
            [ -n "$name" ] || continue
            # "=" = 정확 일치. 접두 매칭이면 zzh 기록이 zzh2를 보고 뱃지를 지운다.
            #   두 필드를 같이 묻는 이유: tmux는 못 찾는 타깃에도 rc 0에 빈 출력을 준다(실측) —
            #   생존 판정을 session_id 유무로 해야 죽은 세션 엔트리가 파일에 영원히 눌러앉지 않는다.
            #   last_attached는 한 번도 접속 안 한 세션에서 빈 값이라 0으로 접어준다(있음≠접속함).
            info=$(tmux display-message -p -t "=$name:" '#{session_id}|#{?session_last_attached,#{session_last_attached},0}' 2>/dev/null) || continue
            [ -n "${info%%|*}" ] || continue        # session_id가 비었다 = 세션 사라짐 → 엔트리 폐기
            la=${info#*|}
            [ "${la:-0}" -gt "$ts" ] && continue    # 이미 들어가봄 = 확인 완료 → 제거
            keep="$keep$ts $name
"
            [ $(( now - ts )) -le "$unseen_s" ] && out="$out ✓ $name"   # 상태바엔 unseen_minutes 만큼만, 파일은 볼 때까지 유지
        done < "$f"
        printf '%s' "$keep" > "$f"
        tt_finished_unlock
    fi
    badge=""
    [ -n "$out" ] && badge="#[fg=#7fae6e,bold]$out #[default] "
    printf '%s%s' "$agg" "$badge"
    exit 0
fi

