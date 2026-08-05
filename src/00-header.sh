#!/usr/bin/env bash
# fleetmux (tt) — AI 에이전트 함대를 위한 tmux 관제탑
#   claude·codex 세션의 상태를 훅으로 추적하고, 골라 들어가고, 뿌리고, 되살린다
#   →/Enter: 세션 진입   ←/Esc: 닫기   Ctrl-N: 새 세션   Ctrl-E: 이름변경   Ctrl-X: 삭제   Ctrl-R: 갱신   Ctrl-D: tmux 탈출
#   소환키는 설정에서 온다 — 기본은 prefix + F 하나뿐이고, 무prefix 키는 기본값이 비어 있다
#   (아무 키도 안 뺏는다). tt config set key_summon_fast 로 켠다 — 87-tmux-conf.sh 가 스니펫에 박는다.
set -euo pipefail
export LC_ALL=en_US.UTF-8   # cron엔 로케일이 없음 — 유니코드 글리프 정규식 오작동 방지

STATE=~/.cache/tt

# ── 자기 절대경로(SELF) ──────────────────────────────────────────────────────
# 내부에서 자기를 다시 부르는 곳이 20군데가 넘는다(fzf --bind·프리뷰·스냅샷·훅 커맨드).
# 예전엔 전부 PATH의 `tt`에 의존했는데, 짧은 별명을 안 깐 환경·PATH가 다른 cron/GUI에서는
# 그 전부가 조용히 깨진다(팝업이 빈 목록, 훅이 무음 실패).
# `readlink -f`는 GNU 확장이라 옛 macOS엔 없다 → 링크를 한 단계씩 따라가는 POSIX 루프로 직접 푼다.
#   readlink(인자 없는 형태)와 `cd -P`/`pwd -P`는 POSIX라 리눅스·BSD 양쪽에 있다.
tt_self() {
    local p="${BASH_SOURCE[0]:-$0}" d l n=0
    case "$p" in */*) ;; *) p=$(command -v -- "$p" 2>/dev/null || printf '%s' "$p") ;; esac
    while [ -L "$p" ] && [ "$n" -lt 20 ]; do
        l=$(readlink "$p" 2>/dev/null) || break
        case "$l" in
            /*) p="$l" ;;
            *)  d=${p%/*}; p="$d/$l" ;;     # 상대 링크는 "링크가 있던 디렉토리" 기준
        esac
        n=$((n + 1))
    done
    d=${p%/*}; [ "$d" = "$p" ] && d="."
    d=$(cd "$d" 2>/dev/null && pwd -P) || d="."
    printf '%s/%s' "$d" "${p##*/}"
}
SELF=$(tt_self)
[ -x "$SELF" ] || SELF="tt"      # 최후 폴백: 그래도 못 찾으면 예전처럼 PATH에 맡긴다
# 셸 문자열(fzf --bind·훅 커맨드)에 끼워 넣을 안전한 인용형 — 경로에 공백·따옴표가 있어도 안 깨진다
SELFQ="'${SELF//\'/\'\\\'\'}'"

