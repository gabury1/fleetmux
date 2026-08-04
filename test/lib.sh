# fleetmux 테스트 공용 — 순수 bash. 의존성 없음.
# 각 테스트 파일은 이 파일을 source 하고 tt_test_sandbox 로 시작한다.

TT_FAIL=0
TT_RUN=0

# 격리된 HOME/XDG 를 만든다. 진짜 ~/.config, ~/.cache 를 절대 건드리지 않기 위함.
# 파일당 한 번만 불러라 — 두 번째 호출은 trap 을 덮어써 첫 TTROOT 를 새게 만들므로 거부한다.
tt_test_sandbox() {
    if [ "${TT_SANDBOX_DONE:-0}" = 1 ]; then
        echo "tt_test_sandbox: 이미 이 프로세스에서 한 번 호출됐다 — 파일당 한 번만 불러라" >&2
        exit 1
    fi
    TT_SANDBOX_DONE=1

    TTROOT=$(mktemp -d "${TMPDIR:-/tmp}/fmux-test.XXXXXX") || exit 1
    export HOME="$TTROOT/home"
    export XDG_CONFIG_HOME="$TTROOT/home/.config"
    mkdir -p "$HOME" "$XDG_CONFIG_HOME"
    # 테스트가 진짜 tmux 서버에 붙지 않도록 소켓 이름을 격리한다.
    # TMUX_TMPDIR 만으론 부족하다 — 이 셸이 이미 tmux 클라이언트 안이면 bare `tmux`
    # 호출은 TMUX_TMPDIR 이 아니라 $TMUX(소켓 경로가 박혀 있음)로 서버를 찾는다.
    # $TMUX 를 지우지 않으면 fleetmux 의 ~20개 무옵션 tmux 호출부가 개발자의
    # 진짜 tmux 서버로 새어나간다.
    export TMUX_TMPDIR="$TTROOT"
    unset TMUX

    # 브리핑의 Interfaces 계약: tt_test_sandbox 가 TTBIN 을 세팅한다.
    # run.sh 가 이미 내보낸 값이 있으면 그대로 두고, 없으면(단독 `bash test/t-0N.sh`
    # 실행 등) lib.sh 자기 자신의 위치에서 역산한다 — $PWD 에 기대지 않는다.
    if [ -z "${TTBIN:-}" ]; then
        local _lib_dir
        _lib_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd) || exit 1
        export TTBIN="$_lib_dir/bin/fmux"
    fi

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
