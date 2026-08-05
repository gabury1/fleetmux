#!/usr/bin/env bash
# --hook 수신부 — ⏸(승인 대기) 판정과 "훅이 대장을 갱신한다"는 사실.
#
# 이 파일이 지키는 것 둘:
#   ① Notification 페이로드의 갈래 판정이 **대소문자에 안 흔들린다**. 소문자 접기를
#      빠뜨리면 "Claude is WAITING FOR YOUR INPUT"(단순 유휴)이 ⏸ 로 새고, 부재중 함대의
#      급한 신호와 그냥 심심한 세션이 구별되지 않는다. 접기를 bash4 문법으로 하면 맥에서
#      통째로 죽는다 — 그쪽은 t-14 가 문법으로 막는다(게이트 B6).
#   ② snapshot=off 여도 **훅 경로는 대장을 계속 갱신한다**. README 가 "snapshot=off 면
#      매니페스트가 갱신을 멈춰 늙는다"고 적었던 것이 반증된 자리다(게이트 B9) — 문서를
#      실제 동작에 맞춰 다시 썼으니, 그 문장의 근거를 여기 못박는다.
#
# ⛔ tmux 는 PATH 앞의 가짜가 전부 가로챈다. 진짜 바이너리에 절대 안 닿는다.
set -u
. "$(dirname "$0")/lib.sh"
tt_test_sandbox

STATE="$HOME/.cache/tt"
CONF="$XDG_CONFIG_HOME/fleetmux/config"
mkdir -p "$(dirname "$CONF")" "$STATE"
TAB=$'\t'

# ── ⛔ PATH 가드 — 어떤 단언보다 먼저 선다 ─────────────────────────────────
mkdir -p "$TTROOT/bin"
cat > "$TTROOT/bin/tmux" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TT_TMUX_LOG"
case "${1:-}" in
    display-message) printf '%s\n' "$TT_FAKE_DISP" ;;
esac
exit 0
SHIM
chmod +x "$TTROOT/bin/tmux"
export TT_TMUX_LOG="$TTROOT/tmux-calls.log"
: > "$TT_TMUX_LOG"
export PATH="$TTROOT/bin:$PATH"
export TMUX_PANE='%9'
export TT_FAKE_DISP="\$9${TAB}zzhooktest${TAB}$HOME${TAB}claude${TAB}1"
HF="$STATE/hook-9"

hook() {   # $1=상태  $2=페이로드(없으면 빈 stdin)
    printf '%s' "${2:-}" | "$TTBIN" --hook "$1" >/dev/null 2>&1 || true
}
state_of() { cut -d' ' -f1 "$HF" 2>/dev/null || true; }

# ── ① 승인 대기 판정 ───────────────────────────────────────────────────────
rm -f "$HF"
hook waiting '{"hook_event_name":"Notification","message":"Claude needs your permission to use Bash"}'
assert_eq "$(state_of)" "waiting" "권한 요청 알림은 ⏸ 로 잡는다"

rm -f "$HF"
hook waiting '{"hook_event_name":"Notification","message":"Claude is waiting for your input"}'
assert_eq "$(state_of)" "" "단순 유휴 알림은 ⏸ 가 아니다"

# 여기가 소문자 접기의 이빨이다 — 접기를 빼면 같은 문장이 대문자라는 이유만으로 ⏸ 가 된다.
rm -f "$HF"
hook waiting '{"hook_event_name":"Notification","message":"Claude Is WAITING FOR YOUR INPUT"}'
assert_eq "$(state_of)" "" "대문자로 와도 단순 유휴는 ⏸ 가 아니다"

rm -f "$HF"
hook waiting '{"message":"CLAUDE NEEDS YOUR PERMISSION TO USE BASH"}'
assert_eq "$(state_of)" "waiting" "대문자로 온 권한 요청도 ⏸ 로 잡는다"

# 근거가 아예 없으면(빈 stdin) 판단하지 않는다 — 예전과 같은 보수적 동작
rm -f "$HF"
hook waiting ''
assert_eq "$(state_of)" "" "페이로드가 없으면 ⏸ 로 안 친다"

# codex 는 이벤트 자체가 승인 요청이라 페이로드를 안 본다
rm -f "$HF"
hook waiting-codex ''
assert_eq "$(state_of)" "waiting" "codex PermissionRequest 는 그 자체로 ⏸ 다"

# ── ② working/idle ─────────────────────────────────────────────────────────
hook working '{}'
assert_eq "$(state_of)" "working" "working 훅이 상태를 쓴다"
hook idle '{}'
assert_eq "$(state_of)" "idle" "idle 훅이 상태를 쓴다"

# ── ③ snapshot=off 여도 훅은 대장을 갱신한다 (게이트 B9) ────────────────────
printf 'snapshot=off\n' > "$CONF"
rm -f "$STATE/manifest"
out=$("$TTBIN" --snapshot 2>&1) || true
assert_contains "$out" "snapshot=off" "스위치를 껐다 — --snapshot 은 실제로 거부한다"
assert_rc 1 test -f "$STATE/manifest"

hook working '{"session_id":"7f3b1c22-0000-4000-8000-0123456789ab","cwd":"'"$HOME"'"}'
assert_rc 0 test -f "$STATE/manifest"
assert_contains "$(cat "$STATE/manifest")" "zzhooktest" \
    "snapshot=off 여도 훅 경로가 대장에 줄을 넣는다 — 매니페스트는 늙지 않는다"
assert_contains "$(cat "$STATE/manifest")" "7f3b1c22-0000-4000-8000-0123456789ab" \
    "훅이 주워 온 대화 id 까지 들어간다"

# 그 갱신은 계속된다(한 번 생기고 마는 게 아니다) — cwd 를 바꾼 뒤 다시 쳐 본다
before=$(cat "$STATE/manifest")
export TT_FAKE_DISP="\$9${TAB}zzhooktest${TAB}$HOME/moved${TAB}claude${TAB}1"
mkdir -p "$HOME/moved"
hook working '{"session_id":"7f3b1c22-0000-4000-8000-0123456789ab","cwd":"'"$HOME"'"}'
assert_contains "$(cat "$STATE/manifest")" "$HOME/moved" "훅이 올 때마다 다시 쓴다"
assert_eq "$(printf '%s' "$before" | grep -c '/moved' || true)" "0" "그 전에는 없던 값이다"

tt_test_done
