# fleetmux 테스트 공용 — 순수 bash. 의존성 없음.
# 각 테스트 파일은 이 파일을 source 하고 tt_test_sandbox 로 시작한다.

TT_FAIL=0
TT_RUN=0

# 격리된 HOME/XDG 를 만든다. 진짜 ~/.config, ~/.cache 를 절대 건드리지 않기 위함.
tt_test_sandbox() {
    TTROOT=$(mktemp -d "${TMPDIR:-/tmp}/fmux-test.XXXXXX") || exit 1
    export HOME="$TTROOT/home"
    export XDG_CONFIG_HOME="$TTROOT/home/.config"
    mkdir -p "$HOME" "$XDG_CONFIG_HOME"
    # 테스트가 진짜 tmux 서버에 붙지 않도록 소켓 이름을 격리한다
    export TMUX_TMPDIR="$TTROOT"
    trap 'rm -rf "$TTROOT"' EXIT
}

assert_eq() {
    TT_RUN=$((TT_RUN + 1))
    if [ "$1" = "$2" ]; then
        printf '  ok   %s\n' "$3"
    else
        TT_FAIL=$((TT_FAIL + 1))
        printf '  FAIL %s\n       기대: [%s]\n       실제: [%s]\n' "$3" "$2" "$1"
    fi
}

assert_contains() {
    TT_RUN=$((TT_RUN + 1))
    case "$1" in
        *"$2"*) printf '  ok   %s\n' "$3" ;;
        *) TT_FAIL=$((TT_FAIL + 1))
           printf '  FAIL %s\n       [%s] 안에 [%s] 가 없다\n' "$3" "$1" "$2" ;;
    esac
}

# rc 검사 — set -e 아래에서도 죽지 않게 서브셸로 감싼다
assert_rc() {
    local want="$1"; shift
    local got=0
    "$@" >/dev/null 2>&1 || got=$?
    TT_RUN=$((TT_RUN + 1))
    if [ "$got" = "$want" ]; then
        printf '  ok   rc=%s  %s\n' "$want" "$1"
    else
        TT_FAIL=$((TT_FAIL + 1))
        printf '  FAIL rc  %s\n       기대: %s  실제: %s\n' "$*" "$want" "$got"
    fi
}

tt_test_done() {
    printf '  — %d개 중 %d개 실패\n' "$TT_RUN" "$TT_FAIL"
    [ "$TT_FAIL" = 0 ]
}
