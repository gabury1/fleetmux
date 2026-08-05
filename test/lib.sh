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

    tt_test_seal_tmux

    # 봉인 로그를 밖으로 꺼내 보고 싶을 때: TT_TMUX_STUB_KEEP=<디렉토리> 로 돌리면
    # 파일별로 가짜 tmux 가 받은 명령 전문을 남긴다(검증 증거용). 기본은 안 남긴다.
    trap 'tt_test_keep_stub_log; rm -rf "$TTROOT"' EXIT
}

tt_test_keep_stub_log() {
    [ -n "${TT_TMUX_STUB_KEEP:-}" ] || return 0
    mkdir -p "$TT_TMUX_STUB_KEEP" 2>/dev/null || return 0
    local tag
    tag=$(basename "${0:-unknown}")
    cp "$TT_TMUX_STUB_LOG"     "$TT_TMUX_STUB_KEEP/$tag.calls"   2>/dev/null || true
    cp "$TT_TMUX_STUB_REFUSED" "$TT_TMUX_STUB_KEEP/$tag.refused" 2>/dev/null || true
}

# ── 봉인된 가짜 tmux ────────────────────────────────────────────────────────
# 소켓 격리(TMUX_TMPDIR + unset TMUX)만으로는 부족했다. 그건 "어느 서버에 붙나"만
# 가르는 장치이고, **진짜 tmux 바이너리는 그대로 실행된다**. 그래서 두 라운드 내내
# 아무도 `make check` 를 못 돌렸다 — 살아있는 함대가 있는 기계에서 진짜 tmux 를
# 부르는 스위트는 돌릴 수 없기 때문이다. 검증을 못 하는 하네스는 검증 구멍이다.
#
# 그래서 PATH 맨 앞에 tmux 라는 이름의 스크립트를 세워 바이너리 자체를 봉인한다:
#   ① 모든 호출을 TT_TMUX_STUB_LOG 에 한 줄씩 받아 적는다(무엇이 나갔나의 증거).
#   ② 읽기 전용 질의는 "서버가 없는 기계"와 똑같이 답한다 — rc 1 + stderr 한 줄.
#      이건 봉인 전 이 스위트가 실제로 보던 답과 같다(격리된 TMUX_TMPDIR 에는
#      서버가 없으므로). 즉 단언을 약화시키지 않는다.
#   ③ 상태를 바꾸는 하위명령(new-session·kill-*·send-keys·source-file …)은
#      **거부**하고 TT_TMUX_STUB_REFUSED 에 따로 적는다. 테스트는 그 파일이 비었는지
#      로 "우리가 남의 서버를 건드릴 뻔했나"를 잰다.
#   ④ -V 만 진짜처럼 답한다(의존성 검사가 유일하게 필요로 하는 읽기 질의다).
#
# 자기 가짜 tmux 가 필요한 테스트(t-03·t-11·t-12)는 이 뒤에 자기 것을 PATH 앞에
# 더 세우거나 PATH 를 통째로 갈면 된다 — 봉인은 "기본이 안전하다"를 보장할 뿐이다.
tt_test_seal_tmux() {
    TT_TMUX_STUB_DIR="$TTROOT/sealbin"
    TT_TMUX_STUB_LOG="$TTROOT/tmux-stub.log"
    TT_TMUX_STUB_REFUSED="$TTROOT/tmux-stub-refused.log"
    export TT_TMUX_STUB_DIR TT_TMUX_STUB_LOG TT_TMUX_STUB_REFUSED
    mkdir -p "$TT_TMUX_STUB_DIR" || exit 1
    : > "$TT_TMUX_STUB_LOG"
    : > "$TT_TMUX_STUB_REFUSED"
    cat > "$TT_TMUX_STUB_DIR/tmux" <<'TT_TMUX_STUB'
#!/usr/bin/env bash
# fleetmux 테스트용 가짜 tmux — 진짜 tmux 는 이 스위트에서 절대 돌지 않는다.
printf '%s\n' "$*" >> "${TT_TMUX_STUB_LOG:-/dev/null}"
case "${1:-}" in
    -V)
        printf 'tmux 3.5a\n'; exit 0 ;;
    ls|list-sessions|list-panes|list-windows|list-clients|list-keys|\
    display-message|display|capture-pane|show-options|show|show-environment|has-session)
        # 읽기 전용 — 서버 없는 기계와 같은 답. 상태를 아무것도 안 바꾼다.
        printf 'no server running on %s/default\n' "${TMUX_TMPDIR:-/tmp}" >&2
        exit 1 ;;
esac
printf '%s\n' "$*" >> "${TT_TMUX_STUB_REFUSED:-/dev/null}"
printf 'fleetmux test stub: 상태를 바꾸는 tmux 하위명령을 거부했다: %s\n' "${1:-<없음>}" >&2
exit 1
TT_TMUX_STUB
    chmod +x "$TT_TMUX_STUB_DIR/tmux" || exit 1
    PATH="$TT_TMUX_STUB_DIR:$PATH"
    export PATH
}

# 봉인된 가짜 tmux 가 상태를 바꾸는 하위명령을 한 번도 안 받았음을 단언한다.
# (자기 PATH 를 따로 세운 테스트는 이 로그를 안 쓰므로 각자 자기 로그로 잰다.)
assert_no_tmux_mutation() {
    TT_RUN=$((TT_RUN + 1))
    if [ ! -s "$TT_TMUX_STUB_REFUSED" ]; then
        printf '  ok   %s\n' "${1:-봉인된 가짜 tmux 가 상태변경 하위명령을 받은 적이 없다}"
    else
        TT_FAIL=$((TT_FAIL + 1))
        printf '  FAIL %s\n       거부 로그:\n%s\n' \
            "${1:-봉인된 가짜 tmux 가 상태변경 하위명령을 받은 적이 없다}" \
            "$(sed 's/^/         /' "$TT_TMUX_STUB_REFUSED")"
    fi
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
