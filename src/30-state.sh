# Claude 작업중 판정 패턴 — 문구 변형이 많다:
#   "(26s · ↓ 763 tokens)" / "(11s · ↓ 347 tokens · thought for 6s)" / "(3s · esc to interrupt)" / "✢ Bunning… (11s"
# 과거형 "✻ Baked for 35s"(완료)는 걸리면 안 됨 — 셋 다 진행형 요소(괄호 타이머·화살표)만 잡는다
WORKING_PAT='esc to interrupt|[0-9]+m?s · [↑↓] [0-9.,]+k? tokens|[✻✶✳✢✽·] [A-Za-z]+… \([0-9]'

# 작업중 판정: 스피너는 항상 "입력창(❯) 위 구분선 바로 위 한 줄"에 뜬다 — 그 한 줄만 검사.
# (하단 N줄 뭉텅이 검사는 화면에 남은 대화 텍스트에 오탐/미탐 — 두 번 데임)
tt_working() {
    awk '
        { L[NR] = $0 }
        /^❯/ { p = NR }
        END {
            if (!p) exit
            i = p - 1
            if (i >= 1 && L[i] ~ /^──/) i--
            while (i >= 1 && L[i] ~ /^[ \t]*$/) i--
            if (i >= 1) print L[i]
        }' | grep -qaE "$WORKING_PAT"
}

# ── 공유 헬퍼 ────────────────────────────────────────────────────────────────
# 세션 이름은 공백·슬래시·정규식 메타를 다 가질 수 있다. 그걸 필드 구분자나 정규식으로 다루면
# 파싱이 깨지거나(상태바 즉사) 엉뚱한 세션이 죽는다 — 아래 헬퍼들이 그 경로를 한 곳에 모은다.
#
# tmux 타깃 표기 규칙 (전 호출부 공통):
#   -t "=이름"    세션 타깃(kill-session·rename-session·switch-client·attach·list-panes -s)
#   -t "=이름:"   pane 타깃(display-message·capture-pane·send-keys) — 콜론이 "그 세션의 현재 창"
#   '='는 정확 일치 요구. 없으면 tmux가 접두 매칭을 해서 'zzhpfx'가 'zzhpfx2'를 집는다(실증) —
#   그 상태로 kill/send-keys가 나가면 엉뚱한 세션이 죽거나 남의 창에 프롬프트가 꽂힌다.
#   pane 타깃에서 콜론을 빼면 '=이름'이 아예 해석되지 않고 조용히 빈 값을 돌려준다(실측).

# finished 변이 직렬화. --status는 상태바가 5초마다 부르는 read-modify-write이고 idle 훅은
# 재작성+append다 — 겹치면 부재중 완료 알림이 조용히 사라진다(lost update, 결정적 재현).
# rc-check와 같은 flock 패턴. fd 9는 프로세스가 죽으면 자동 해제되니 임계구역만 짧게 잡는다.
tt_finished_lock() {
    mkdir -p "$STATE"
    command -v flock >/dev/null 2>&1 || return 0
    exec 9>"$STATE/finished.lock" 2>/dev/null || return 0
    flock 9 2>/dev/null || true
    return 0
}
tt_finished_unlock() { exec 9>&- 2>/dev/null || true; return 0; }

# finished 포맷은 "<ts> <이름>" — ts가 앞, 이름이 마지막 필드다.
#   구포맷("<이름> <ts>")은 `read -r name ts`가 "my proj 1784…"를 name=my/ts=proj로 쪼개
#   $((now-ts))가 set -u/산술 오류로 즉사시켰다. 상태바 뱃지가 통째로 사라지고 poison 라인은
#   파일에 영구 잔존해 다음 실행도 계속 죽었다(치명). 이름을 끝으로 밀면 공백이 몇 개든 안전.
#   읽는 쪽이 구포맷도 받아주도록 여기서 한 번에 정규화하고, 숫자 ts가 없는 줄은 버린다.
#   TT_FIN_SKIP(환경변수)에 이름을 주면 그 세션의 옛 기록을 함께 지운다 — 예전엔 sed 정규식으로
#   지웠는데 이름에 `/`가 있으면 파스 에러(exit 4)가 `|| true`에 삼켜져 중복이 누적됐다.
#   awk 변수 대신 ENVIRON을 쓰는 이유: -v는 값의 백슬래시를 이스케이프로 해석해 이름을 망친다.
TT_FIN_NORM='
    BEGIN { skip = ENVIRON["TT_FIN_SKIP"] }
    {
        if ($1 ~ /^[0-9]+$/)                  { t = $1;  s = $0; sub(/^[0-9]+[ \t]+/, "", s) }
        else if (NF > 1 && $NF ~ /^[0-9]+$/)  { t = $NF; s = $0; sub(/[ \t]+[0-9]+[ \t]*$/, "", s) }
        else next
        if (s != "" && s != skip) print t " " s
    }'

# 정규화(+선택적 제거) 후 제자리 교체. 락을 잡은 쪽에서만 부를 것.
tt_finished_rewrite() {
    local f="$STATE/finished"
    [ -s "$f" ] || return 0
    if TT_FIN_SKIP="${1:-}" awk "$TT_FIN_NORM" "$f" > "$f.tmp" 2>/dev/null; then
        mv -f "$f.tmp" "$f"
    else
        rm -f "$f.tmp"
    fi
    return 0
}

# 훅 파일이 "이 세션의 것"인지 판정. rc 0 = 신뢰 가능, rc 1 = 못 믿음(stale이거나 없음).
#   왜 필요한가: 재부팅하면 tmux는 session id를 $0부터 재발급한다. 죽은 세션의 hook-<id>가 남아
#   있으면 같은 번호를 받은 새 도구 세션이 남의 상태 파일을 물려받아 에이전트로 오분류된다
#   (2026-07-25 실측: lazydocker인 DB·DOCKER가 목록 위쪽 에이전트 그룹에 앉았다).
#   근거는 둘 — 어느 하나만 서면 인정한다:
#     ① 훅이 적어둔 에이전트 pid가 아직 살아 있다 = 그 프로세스가 지금 이 순간의 증거다.
#     ② pid를 못 적었어도(부모 체인 등반 실패 시 0) 기록 시각이 세션 생성 시각 이후다
#        = 이 세션이 생긴 뒤에 쓰인 파일이니 물려받은 게 아니다.
#   세션 생성 시각을 못 얻으면 0으로 접어 예전처럼 관대하게 통과시킨다(판단 근거 없음 → 무해한 쪽).
tt_hook_valid() {
    local hf="$1" created="${2:-0}" hts hpid
    [ -f "$hf" ] || return 1
    hts=0; hpid=0
    # 훅 파일 포맷은 "<상태> <기록시각> <pid>" — 여기서 상태는 안 쓴다(_ 로 버린다)
    read -r _ hts hpid < "$hf" 2>/dev/null || true
    case "${hpid:-0}" in ''|*[!0-9]*) hpid=0 ;; esac
    case "${hts:-0}" in ''|*[!0-9]*) hts=0 ;; esac
    case "${created:-0}" in ''|*[!0-9]*) created=0 ;; esac
    # ① pid를 적었으면 그 생존 여부가 최종 판정이다 — 살았으면 정품, 죽었으면 유령.
    #    시각 비교로 내려가면 안 된다: 재부팅으로 id가 재사용되면 죽은 훅의 기록시각이
    #    그 id를 새로 받은 세션의 생성시각보다 나중일 수 있어, 유령을 정품으로 착각한다
    #    (2026-07-25 hook-6 실측: pid 954169 죽었는데 hts>created라 통과돼 살아남았다).
    if [ "$hpid" -gt 0 ]; then
        kill -0 "$hpid" 2>/dev/null && return 0
        return 1
    fi
    # ② pid를 못 적은 경우(부모 체인 등반 실패 → 0)만 시각으로 폴백한다
    [ "$hts" -ge "$created" ] && return 0
    return 1
}

# 에이전트 세션 판정(claude/codex가 도는 세션). 인자는 세션 id($3…) 또는 세션 이름.
#   두 번째 인자로 session_created를 넘길 수 있다 — 이미 알고 있는 호출부(--list)는 tmux를
#   한 번 덜 부른다. 안 넘기면 여기서 묻는다.
#   기준: 이 세션 것이 확실한 훅 파일 ∨ 어느 pane에든 claude|codex — --list 그룹 판정과 같은 기준.
#   같은 판정이 여러 곳에 흩어져 있으면 "목록엔 도구인데 브로드캐스트 키는 날아가는" 사고가 난다.
tt_is_agent() {
    local t="${1:-}" created="${2:-}" sid c2
    [ -n "$t" ] || return 1
    case "$t" in
        \$[0-9]*)               # 세션 id는 그 자체로 유일 — = 접두 불필요(붙이면 오히려 안 잡힘)
            sid="$t"
            [ -n "$created" ] || created=$(tmux display-message -p -t "$sid" '#{session_created}' 2>/dev/null) || created="" ;;
        *)
            IFS=$'\t' read -r sid c2 < <(tmux display-message -p -t "=$t:" $'#{session_id}\t#{session_created}' 2>/dev/null) || return 1
            [ -n "$created" ] || created="$c2" ;;
    esac
    [ -n "$sid" ] || return 1
    tt_hook_valid "$STATE/hook-${sid#\$}" "${created:-0}" && return 0
    tmux list-panes -s -t "$sid" -F '#{pane_current_command}' 2>/dev/null | grep -qxE 'claude|codex'
}

# 브로드캐스트 실사 — 에이전트 세션에만 주입한다.
#   도구 세션(yazi·lazydocker·맨셸)에 프롬프트를 치면 문장이 셸 명령으로 실행되거나 TUI 단축키로
#   먹힌다(lazydocker에서 r=restart). 안전사고 경로라 조용히 넘기지 말고 스킵 사실을 보여준다.
tt_broadcast() {
    local msg="$1" s sent=0 skipped=0 names=""
    shift
    for s in "$@"; do
        [ -n "$s" ] || continue
        case "$s" in ─*) continue ;; esac
        if ! tt_is_agent "$s"; then
            skipped=$((skipped + 1)); names="$names $s"; continue
        fi
        tmux send-keys -t "=$s:" -l "$msg"
        tmux send-keys -t "=$s:" Enter
        sent=$((sent + 1))
    done
    printf '→ sent to %d sessions\n' "$sent"
    [ "$skipped" -gt 0 ] && printf '  skipped %d tool sessions:%s\n' "$skipped" "$names"
    return 0
}

# 고아·유령 hook 파일 sweep. 두 종류를 다 잡는다:
#   ① 고아  — 이제 존재하지 않는 session id의 파일.
#   ② 유령  — id는 살아있지만 그 파일이 '지금 그 세션의 것이 아닌' 경우.
#      재부팅 후 tmux는 session id를 $0부터 재발급한다 → 새 세션이 죽은 세션의 상태 파일을
#      그대로 물려받는다. ①만 지우던 시절엔 이게 통째로 살아남아 도구 세션이 에이전트로
#      오분류됐다(실측). 판정은 tt_is_agent와 같은 tt_hook_valid 한 곳을 쓴다 —
#      "지우는 기준"과 "믿는 기준"이 갈라지면 지웠는데 또 믿는 모순이 생긴다.
#   살아있는 id 목록을 못 얻으면 sweep 생략(안전). boot 훅과 --restore가 공유한다.
tt_sweep_hooks() {
    local live lsout sid created hf id
    lsout=$(tmux ls -F $'#{session_id}\t#{session_created}' 2>/dev/null) || return 0
    [ -n "$lsout" ] || return 0
    # id → created 조회표를 한 줄 문자열로 (연관배열은 bash 4 전용 — 맥 기본 3.2에서 깨진다)
    live=" "
    while IFS=$'\t' read -r sid created; do
        [ -n "$sid" ] || continue
        live="$live${sid#\$}=${created:-0} "
    done <<< "$lsout"
    for hf in "$STATE"/hook-*; do
        [ -f "$hf" ] || continue
        id=${hf##*/hook-}
        case "$live" in
            *" $id="*)
                created=${live#*" $id="}; created=${created%% *}
                tt_hook_valid "$hf" "${created:-0}" || rm -f "$hf" ;;   # ② 유령
            *) rm -f "$hf" ;;                                           # ① 고아
        esac
    done
    return 0
}

# JSON 얕은 문자열 값 → 전역 TT_JV (rc_val과 같은 규칙, 다만 포크 0).
#   훅 경로에서 $(rc_val …)을 부르면 이벤트마다 서브셸이 더 뜬다 — 훅은 초당 여러 번 불리니
#   여기서만은 표준출력 대신 전역으로 돌려준다. (rc 판정부는 그대로 rc_val을 쓴다)
tt_jv() {
    TT_JV=""
    local re="\"$2\"[[:space:]]*:[[:space:]]*\"([^\"]*)\""
    [[ "$1" =~ $re ]] || return 1
    TT_JV="${BASH_REMATCH[1]}"
    return 0
}

