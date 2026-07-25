# ── 함대 매니페스트(스냅샷/복원 대장) ────────────────────────────────────────
# 파이가 죽었다 살아나면 tmux 세션이 통째로 증발한다(실제로 10개를 손으로 재건했다).
# 그래서 "무엇이 어디서 무엇으로 떠 있었는지"를 파일로 남겨두고 --restore로 되살린다.
#
# 형식(탭 6필드. 5필드였던 옛 줄도 그대로 읽힌다 — 마이그레이션 없이 쓸 때 자연히 6필드가 된다):
#   <이름>\t<세션cwd>\t<kind: agent|tool>\t<시작 명령 또는 ->\t<대화id 또는 ->\t<대화 홈 cwd 또는 ->
#   탭인 이유는 --list와 같다: 이름·경로에 공백이 들어가도 필드가 밀리지 않는다.
#   빈 필드 금지 — '-'가 "없음" 센티넬이다(read가 연속 탭을 하나로 합쳐 필드를 밀어낸다).
#
# 6번째 "대화 홈"이 따로 있는 이유(실측):
#   `claude --resume <id>`는 아무 데서나 되지 않는다 — '지금 cwd에 대응하는 프로젝트 폴더'에서만
#   그 대화를 찾는다. 그런데 tmux 세션의 cwd와 대화가 태어난 cwd는 자주 다르다
#   (refact-worker: 세션 cwd=…/_myproject, transcript는 ~/.claude/projects/-home-euns/).
#   세션 cwd만 들고 복원하면 "No conversation found"로 셸에 떨어진다. 그래서 둘을 따로 적고
#   복원은 세션 cwd로 만들되 resume만 대화 홈에서 실행한다.
# TT_MANIFEST로 경로를 갈아끼울 수 있다: 테스트가 진짜 함대 기록을 덮어쓰지 않게 하는 탈출구.
MANIFEST="${TT_MANIFEST:-$STATE/manifest}"

# 대화 id는 uuid다. "uuid 비슷한 것"이 아니라 정확히 uuid만 통과시킨다 —
#   필드가 한 칸 밀려 "claude"·"agent" 같은 문자열이 대화 id 자리에 눌러앉은 채로 스냅샷마다
#   전파된 사고가 실제로 있었다(2026-07-25). 그 줄로 --resume 하면 대화가 통째로 사라진 것처럼 보인다.
#   [[ =~ ]] 대신 case 글롭인 이유: 포크도 정규식 엔진도 없고 셸 구현차가 없다.
tt_is_uuid() {
    case "${1:-}" in
        [0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]) return 0 ;;
    esac
    return 1
}

# 복원이 pane 에 띄울 로그인 셸. tmux 의 서버 전역 default-shell 에 절대 기대지 않는다.
#   default-shell 은 서버가 태어날 때 부모의 $SHELL 로 한 번 굳고 서버가 죽을 때까지 안 바뀐다.
#   @reboot cron 이 서버를 낳으면 $SHELL=/bin/sh → 그 서버가 만드는 모든 pane 이 dash 가 되고,
#   dash 는 .bashrc 를 안 읽어 claude 가 PATH 에서 사라진다(2026-07-26: agent 5개 전멸).
#   set -g default-shell 로 고치면 남의 세션까지 영향이 가므로, 세션마다 명시하는 쪽을 택한다 —
#   서버 전역 상태는 무접촉이고 효과는 우리 세션에만 든다.
tt_login_shell() {
    local s
    s=$(getent passwd "$(id -un 2>/dev/null)" 2>/dev/null | cut -d: -f7)
    case "$s" in */bash|*/zsh|*/fish) [ -x "$s" ] && { printf '%s' "$s"; return 0; } ;; esac
    printf '/bin/bash'
}

# pane 에 에이전트가 실제로 떠 있나 — 복원 검증용. 판정 기준은 tt_is_agent 의 둘째 절과 같다.
tt_pane_has_agent() {
    tmux list-panes -s -t "=${1:-}:" -F '#{pane_current_command}' 2>/dev/null \
        | grep -qxE 'claude|codex'
}

# 쓰기 전 무결성 검사 — 인자로 받은 '파일 전체 내용'의 모든 줄을 본다. 한 줄이라도 어긋나면 rc 1.
#   깨진 매니페스트는 조용히 번진다: 한 번 밀린 필드가 다음 스냅샷의 "옛 값"으로 읽혀 누진 손상이 된다.
#   그래서 규칙은 "의심스러우면 안 쓴다" — 기존 파일이 남아 있는 쪽이 언제나 낫다.
#   검사 항목: 필드 수 5 또는 6 / 빈 필드 없음 / kind는 agent|tool / conv는 '-' 또는 uuid.
#   uuid 판정을 정규식 {n} 반복으로 안 쓰는 이유: interval 지원이 awk 구현마다 다르다(BSD awk).
TT_MF_CHECK_AWK='
    function isuuid(s,   i, c) {
        if (length(s) != 36) return 0
        for (i = 1; i <= 36; i++) {
            c = substr(s, i, 1)
            if (i == 9 || i == 14 || i == 19 || i == 24) { if (c != "-") return 0 }
            else if (c !~ /^[0-9a-fA-F]$/) return 0
        }
        return 1
    }
    $0 == "" { next }
    NF != 5 && NF != 6 { bad = 1; exit }
    { for (i = 1; i <= NF; i++) if ($i == "") { bad = 1; exit } }
    $3 != "agent" && $3 != "tool" { bad = 1; exit }
    $5 != "-" && !isuuid($5) { bad = 1; exit }
    END { exit (bad ? 1 : 0) }'
tt_mf_check() { printf '%s' "${1:-}" | awk -F'\t' "$TT_MF_CHECK_AWK"; }

# 매니페스트 원자적 교체 — 검증을 통과한 내용만 착지시킨다. 실패하면 기존 파일은 무접촉.
#   경고는 stderr로: 훅 경로는 2>/dev/null이라 조용하고, 사람이 친 --snapshot에서는 눈에 띈다.
tt_mf_write() {
    if ! tt_mf_check "${1:-}"; then
        printf 'fmux: manifest write refused — malformed rows; %s left untouched\n' "$MANIFEST" >&2
        return 1
    fi
    if printf '%s' "${1:-}" > "$MANIFEST.tmp" 2>/dev/null; then
        mv -f "$MANIFEST.tmp" "$MANIFEST" 2>/dev/null || { rm -f "$MANIFEST.tmp"; return 1; }
        return 0
    fi
    rm -f "$MANIFEST.tmp"
    return 1
}

# 백업 3세대 순환 (.bak → .bak2 → .bak3). 전체 교체(--snapshot) 직전에만 돈다.
#   1세대뿐이던 시절엔 --snapshot이 1분 cron으로 돌기 때문에 "아차" 하고 복구할 창이 60초였다 —
#   나쁜 스냅샷이 한 번 더 돌면 유일한 백업까지 나쁜 내용으로 덮인다. 3세대면 최소 3분이 생긴다.
tt_mf_backup() {
    [ -f "$MANIFEST" ] || return 0
    [ -f "$MANIFEST.bak2" ] && cp -f "$MANIFEST.bak2" "$MANIFEST.bak3" 2>/dev/null
    [ -f "$MANIFEST.bak" ]  && cp -f "$MANIFEST.bak"  "$MANIFEST.bak2" 2>/dev/null
    cp -f "$MANIFEST" "$MANIFEST.bak" 2>/dev/null
    return 0
}

