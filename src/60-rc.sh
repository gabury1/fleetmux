# ── rc(Remote Control) 판정부 ───────────────────────────────────────────────
# 폰에서 세션을 보려면 claude가 rc 브리지에 붙어 있어야 한다. 브리지는 25분 타임아웃·
# 컴팩션·유휴로 조용히 끊기고(공식 미해결 버그) 복구는 수동 /remote-control 재실행뿐 — 그걸 자동화한다.
# 판정 소스는 claude가 직접 쓰는 ~/.claude/sessions/<pid>.json 의 bridgeSessionId
#   null = 끊김 / 값 있음 = 연결(claude.ai/code/<값>).  세션이 죽으면 파일도 사라진다.
#   파일의 name 필드는 신뢰 금지(서로 다른 세션이 같은 이름으로 찍힌다) — 매핑은 반드시 PID로.
SESSD=~/.claude/sessions

# 얕은 JSON 값 뽑기 (문자열은 따옴표 벗김, 키 없으면 빈값) — jq도 포크도 없이. 1분마다 전 세션을 도는 경로다
rc_val() {
    local re="\"$2\"[[:space:]]*:[[:space:]]*(\"[^\"]*\"|[^,}]*)"
    [[ "$1" =~ $re ]] || return 0
    printf '%s' "${BASH_REMATCH[1]//\"/}"
}

# 세션 파일 통째 읽기. claude가 쓰는 도중(잘린 파일)을 반쪽 읽고 "rc 끊김"으로 오판하면
# 멀쩡한 세션에 키를 치게 된다 → 완결성(마지막 })부터 확인하고, 아니면 이번 라운드는 판정 포기
rc_read() {
    local j
    j=$(cat "$1" 2>/dev/null) || return 1
    case "$j" in *'"sessionId":"'*'}') printf '%s' "$j" ;; *) return 1 ;; esac
}

# /proc/<pid>/stat 22번 필드(starttime) — json의 procStart와 대조해 PID 재사용을 막는다
rc_procstart() {
    local s
    s=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
    s=${s##*) }                       # comm 뒤(3번 필드 state)부터 → 22번 필드는 여기서 20번째
    printf '%s' "$s" | awk '{print $20}'
}

# pane pid 아래로 내려가며 claude 본체 PID를 찾는다 (--hook의 부모 체인 등반과 반대 방향)
#   자격: 세션 파일 보유 + comm이 claude + procStart 일치.  wrapper·중간 셸이 껴도 몇 단계 내려가 잡는다.
#   같은 층에 후보가 둘이면 포기 — 엉뚱한 PID를 잡으면 남의 상태를 보게 된다(오탐 금지)
rc_claude_pid() {
    local level="$1" next hits p c n d=0 pst j
    while [ -n "${level// /}" ] && [ "$d" -lt 4 ]; do
        hits=""; next=""; n=0
        for p in $level; do
            if [ -f "$SESSD/$p.json" ] && [ "$(tt_comm "$p" || true)" = claude ]; then
                pst=$(rc_procstart "$p" || true)
                j=$(rc_read "$SESSD/$p.json") || j=""
                if [ -n "$j" ] && [ -n "$pst" ] && [ "$pst" = "$(rc_val "$j" procStart)" ]; then
                    hits="$hits $p"; n=$((n+1))
                fi
            fi
            c=$(pgrep -P "$p" 2>/dev/null | tr '\n' ' ')
            next="$next $c"
        done
        [ "$n" = 1 ] && { printf '%s' "${hits# }"; return 0; }
        [ "$n" -gt 1 ] && return 1
        level="$next"; d=$((d+1))
    done
    return 1
}

# tmux 세션 → "pane_id claude_pid" (판정 불가·모호하면 rc 1). 어느 창의 pane이든 훑는다
rc_target() {
    local pane ppid pid found=""
    while read -r pane ppid; do
        pid=$(rc_claude_pid "$ppid") || continue
        [ -n "$found" ] && return 1     # 한 세션에 claude 둘 = 어디에 칠지 모름 → 포기
        found="$pane $pid"
    done < <(tmux list-panes -s -t "$1" -F '#{pane_id} #{pane_pid}' 2>/dev/null || true)
    [ -n "$found" ] || return 1
    printf '%s' "$found"
}

# rc 자동 복구 (cron 1분): 끊긴 claude 세션에만 /remote-control을 재주입한다
#   send-keys는 "bridgeSessionId가 실제로 null + 작업중이 아님"일 때만 — 작업중 주입은 입력 오염
#   이미 연결된 세션에서 /remote-control을 치면 끊기진 않고 모달만 열린다 → 주입 후 Escape 필수
#   tt --cron <세션명> 으로 한 세션만 검사 (디버깅용)
# 라운드 끝에 --list용 표시 캐시($STATE/rc-off)를 갈아끼운다 — 목록은 손이 자주 타는 경로라
# 거기서 pgrep 팬아웃을 돌리면 팝업이 눈에 띄게 굼떠진다(0.05s → 0.4s 실측). 판정은 여기서만 한다.
if [ "${1:-}" = "--cron" ] || [ "${1:-}" = "--rc-check" ]; then   # 옛 이름은 하위호환
    only="${2:-}"; off=""
    mkdir -p "$STATE"
    tt_log_rotate                              # 감사 로그가 SD카드를 갉아먹지 않게 (1분 1회)
    # 라운드가 길어져도(복구 세션당 ~11초) cron 다음 틱과 겹쳐 두 번 치지 않게
    if command -v flock >/dev/null 2>&1; then
        exec 9>"$STATE/rc.lock"
        flock -n 9 || exit 0
    fi
    while read -r sid name; do
        [ -z "$only" ] || [ "$name" = "$only" ] || continue
        t=$(rc_target "$sid") || continue          # claude 없음·모호·PID 재사용 의심 → 조용히 스킵
        pane=${t%% *}; cpid=${t##* }
        f="$SESSD/$cpid.json"
        ff="$STATE/rc-fail-${sid#\$}"
        # 끊김 = bridgeSessionId가 null 이거나 아예 없음(rc를 한 번도 안 켠 세션)
        j=$(rc_read "$f") || continue              # 쓰는 중이라 반쪽인 파일 → 다음 라운드에
        b=$(rc_val "$j" bridgeSessionId)
        case "$b" in
            ""|null) ;;                            # 끊김 → 복구 대상
            *) rm -f "$ff"; continue ;;            # 연결됨 → 무개입 + 실패 카운트 리셋
        esac
        off="$off ${sid#\$}=off"                               # 여기부터는 확정 끊김 — 목록에 ⊘
        [ "$(rc_val "$j" status)" = busy ] && continue         # 작업중 → 이번 라운드 유예
        hs=$(cut -d' ' -f1 "$STATE/hook-${sid#\$}" 2>/dev/null || true)
        case "$hs" in working|waiting) continue ;; esac        # tt 훅 상태로 이중 안전
        # 백오프: 같은 claude(PID 동일)에 3회 연속 실패하면 포기 — 죽은 세션에 계속 치지 않게
        n=0; fpid=""; lastok=0
        [ -f "$ff" ] && read -r n fpid lastok < "$ff" || true
        [ "${fpid:-}" = "$cpid" ] || { n=0; lastok=0; }        # claude가 새로 떴으면 새 판
        case "${lastok:-0}" in ''|*[!0-9]*) lastok=0 ;; esac
        # 재발 브레이크: 방금 복구에 성공했는데 5분도 안 돼 또 끊겼다 = 붙여도 유지가 안 되는 세션.
        # 예전엔 성공하면 카운터를 지워서 fails가 영원히 0이었고, 매분 주입이 무한 반복됐다
        # (2026-07-25 실측: $7·$8이 1분 간격으로 번갈아 ok 로그를 남기며 화면에 계속 /remote-control).
        # 이런 세션은 우리가 못 고치는 브리지 버그(CC #34868 계열)이므로 손을 뗀다.
        if [ "$lastok" -gt 0 ] && [ $(( $(date +%s) - lastok )) -lt 300 ]; then
            n=$((n + 1))
            echo "$n $cpid $lastok" > "$ff"
            echo "$(date '+%F %T') $sid rc-relapse $n" >> "$STATE/hook.log"
            [ "$n" -ge 3 ] && off="${off% *} ${sid#\$}=gave"
            continue                                           # 이번 라운드는 주입하지 않는다
        fi
        if [ "${n:-0}" -ge 3 ]; then off="${off% *} ${sid#\$}=gave"; continue; fi
        # 복구 — 세션 하나씩 순차 (동시 다발 send-keys 금지)
        tmux send-keys -t "$pane" -l "/remote-control"
        sleep 0.7
        tmux send-keys -t "$pane" Enter
        sleep 8
        tmux send-keys -t "$pane" Escape                       # 상태 패널(모달) 닫기 — 안 닫으면 입력이 막힌다
        sleep 2
        b=$(rc_val "$(rc_read "$f" || true)" bridgeSessionId)
        if [ -n "$b" ] && [ "$b" != null ]; then
            # 성공해도 파일을 지우지 않는다 — 성공 시각을 남겨야 "붙였다 또 끊기는" 재발을 볼 수 있다.
            # 실패 카운트는 0으로 리셋(연속 실패와 재발은 다른 축).
            echo "0 $cpid $(date +%s)" > "$ff"
            off="${off% *}"                                    # 되살아났다 → 목록 표시 취소
            echo "$(date '+%F %T') $sid rc-recover ok" >> "$STATE/hook.log"
        else
            echo "$((n+1)) $cpid ${lastok:-0}" > "$ff"
            [ $((n+1)) -ge 3 ] && off="${off% *} ${sid#\$}=gave"
            echo "$(date '+%F %T') $sid rc-recover fail" >> "$STATE/hook.log"
        fi
    done < <(tmux ls -F '#{session_id} #{session_name}' 2>/dev/null || true)
    # 표시 캐시 통째 교체 — 죽은 세션 찌꺼기가 남지 않는다. 세션 하나만 검사한 라운드는 건드리지 않음
    [ -n "$only" ] || printf '%s%s\n' "$(date +%s)" "$off" > "$STATE/rc-off"
    # 함대 스냅샷도 여기서 굳힌다(maintainer 제안) — 어차피 1분마다 전 세션을 훑는 김에.
    # 팝업을 안 열어도 매니페스트가 최신이라, 갑작스런 재부팅에도 최대 1분 전 상태가 남는다.
    [ -n "$only" ] || "$SELF" --snapshot >/dev/null 2>&1 || true
    exit 0
fi

# rc 현황표 (읽기 전용, 디버깅용): 세션 / rc / URL
if [ "${1:-}" = "--rc" ]; then
    printf '%-18s %-5s %s\n' SESSION RC URL
    while read -r sid name; do
        if ! t=$(rc_target "$sid"); then
            printf '%-18s %-5s %s\n' "$name" '?' 'no claude found'
            continue
        fi
        j=$(rc_read "$SESSD/${t##* }.json" || true)
        b=$(rc_val "$j" bridgeSessionId)
        n=0; fpid=""; lastok=0
        [ -f "$STATE/rc-fail-${sid#\$}" ] && read -r n fpid lastok < "$STATE/rc-fail-${sid#\$}" || true
        if [ -n "$b" ] && [ "$b" != null ]; then
            printf '%-18s %-5s %s\n' "$name" 'ON' "https://claude.ai/code/$b"
        else
            printf '%-18s %-5s %s\n' "$name" 'OFF' "pid ${t##* } · $(rc_val "$j" status) · fails ${n:-0}"
        fi
    done < <(tmux ls -F '#{session_id} #{session_name}' 2>/dev/null || true)
    exit 0
fi

