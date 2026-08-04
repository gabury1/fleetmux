#!/usr/bin/env bash
# rc · snapshot · boot_restore 스위치.
#
# 이 테스트가 지켜야 하는 것은 "꺼지면 조용히 성공한다" 하나가 아니다. 세 가지다:
#   ① 꺼짐 — rc 0 으로 끝나고, 이유를 stdout 한 줄로 말하고, tmux 를 아예 부르지 않는다.
#   ② 켜짐 — 예전 그대로 tmux 를 부르고 대장을 쓴다(스위치가 기능을 죽이지 않았다).
#   ③ rc=off 여도 --cron 의 --snapshot 은 산다(exit 0 으로 끄면 여기서 걸린다).
# ①·③ 의 "tmux 를 부르지 않는다/부른다"는 가짜 tmux 를 PATH 앞에 세워 호출을 받아 적어 잰다.
# ② 는 격리된 소켓 디렉토리($TMUX_TMPDIR=$TTROOT)에 진짜 tmux 서버를 띄워 end-to-end 로 잰다 —
# 사용자의 진짜 서버에는 닿지 않고, 아래 trap 이 끝날 때 죽인다.
set -u
. "$(dirname "$0")/lib.sh"
tt_test_sandbox

CONF="$XDG_CONFIG_HOME/fleetmux/config"
mkdir -p "$(dirname "$CONF")"
STATE="$HOME/.cache/tt"

# ── 가짜 tmux: 호출을 받아 적기만 하고 아무것도 하지 않는다 ──────────────────
mkdir -p "$TTROOT/bin"
cat > "$TTROOT/bin/tmux" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TT_TMUX_LOG"
exit 1
SHIM
chmod +x "$TTROOT/bin/tmux"
export TT_TMUX_LOG="$TTROOT/tmux-calls.log"
: > "$TT_TMUX_LOG"
# 두 진입점의 tmux ls 는 포맷 문자열이 다르다 — 로그에서 서로 구분된다.
RC_CALL='ls -F #{session_id} #{session_name}'                 # 60-rc.sh 의 rc 라운드(공백)
SNAP_CALL="ls -F #{session_id}"$'\t'"#{session_name}"         # 70-fleet.sh 의 스냅샷(탭)
REALPATH_SAVED="$PATH"
export PATH="$TTROOT/bin:$PATH"

# ── ① 전부 꺼짐 ────────────────────────────────────────────────────────────
printf 'rc=off\nsnapshot=off\nboot_restore=off\n' > "$CONF"

assert_rc 0 "$TTBIN" --cron
assert_rc 0 "$TTBIN" --rc
assert_rc 0 "$TTBIN" --boot-restore --dry

out=$("$TTBIN" --snapshot 2>&1) || true
assert_contains "$out" "snapshot=off" "스냅샷이 꺼져 있으면 그렇게 말한다"
out=$("$TTBIN" --rc 2>&1) || true
assert_contains "$out" "rc=off" "rc 가 꺼져 있으면 그렇게 말한다"
out=$("$TTBIN" --boot-restore --dry 2>&1) || true
assert_contains "$out" "boot_restore=off" "부팅 복원이 꺼져 있으면 그렇게 말한다"
assert_contains "$(cat "$STATE/boot.log" 2>/dev/null || true)" "boot_restore=off in config" \
    "부팅 복원을 건너뛴 이유가 boot.log 에도 남는다"

# 껐을 때 매니페스트를 만들지 않는다
assert_rc 1 test -f "$STATE/manifest"
# 크론은 1분마다 돈다 — 삼켜지는 자리에선 한 줄도 뱉지 않아야 cron 메일이 안 쌓인다
assert_eq "$("$TTBIN" --cron 2>/dev/null)" "" "크론 경로는 리다이렉트될 때 침묵한다"
# 그리고 이게 핵심: 꺼진 진입점은 tmux 를 단 한 번도 부르지 않는다(조기 return 이 첫 tmux 앞이다)
assert_eq "$(cat "$TT_TMUX_LOG")" "" "전부 꺼져 있으면 tmux 를 한 번도 부르지 않는다"

# ── ② 전부 켜짐 — 예전처럼 tmux 를 부른다 ──────────────────────────────────
: > "$TT_TMUX_LOG"
printf 'rc=on\nsnapshot=on\n' > "$CONF"
"$TTBIN" --cron >/dev/null 2>&1 || true
log=$(cat "$TT_TMUX_LOG")
assert_contains "$log" "$RC_CALL"   "rc=on 이면 --cron 이 rc 라운드를 돈다"
assert_contains "$log" "$SNAP_CALL" "snapshot=on 이면 --cron 이 스냅샷도 부른다"

: > "$TT_TMUX_LOG"
"$TTBIN" --rc >/dev/null 2>&1 || true
assert_contains "$(cat "$TT_TMUX_LOG")" "$RC_CALL" "rc=on 이면 --rc 가 현황표를 그리러 tmux 에 간다"

: > "$TT_TMUX_LOG"
"$TTBIN" --snapshot >/dev/null 2>&1 || true
assert_contains "$(cat "$TT_TMUX_LOG")" "$SNAP_CALL" "snapshot=on 이면 --snapshot 이 세션을 훑는다"

rm -f "$STATE/boot.log"
printf 'boot_restore=on\n' > "$CONF"
TT_BOOT_NETWAIT=0 TT_BOOT_NETHOST=fmux-nonexistent.invalid \
    "$TTBIN" --boot-restore --dry >/dev/null 2>&1 || true
assert_contains "$(cat "$STATE/boot.log" 2>/dev/null || true)" "no DNS+tcp/443" \
    "boot_restore=on 이면 스위치를 지나 실제 부팅 절차(네트워크 대기)까지 간다"

# ── ③ rc 만 꺼짐 — 스냅샷은 살아야 한다 ────────────────────────────────────
# exit 0 으로 rc 를 끄면 --cron 한 틱에서 스냅샷이 통째로 사라진다. 여기서 잡는다.
: > "$TT_TMUX_LOG"
printf 'rc=off\nsnapshot=on\n' > "$CONF"
"$TTBIN" --cron >/dev/null 2>&1 || true
log=$(cat "$TT_TMUX_LOG")
assert_contains "$log" "$SNAP_CALL" "rc=off 여도 --cron 은 스냅샷을 부른다"
case "$log" in *"$RC_CALL"*) seen=yes ;; *) seen=no ;; esac
assert_eq "$seen" "no" "rc=off 면 --cron 의 rc 라운드는 tmux 를 부르지 않는다"

# 반대쪽 — snapshot 만 꺼짐: rc 라운드는 살고 스냅샷 포크는 없다
: > "$TT_TMUX_LOG"
printf 'rc=on\nsnapshot=off\n' > "$CONF"
"$TTBIN" --cron >/dev/null 2>&1 || true
log=$(cat "$TT_TMUX_LOG")
assert_contains "$log" "$RC_CALL" "snapshot=off 여도 rc 라운드는 돈다"
case "$log" in *"$SNAP_CALL"*) seen=yes ;; *) seen=no ;; esac
assert_eq "$seen" "no" "snapshot=off 면 --cron 이 스냅샷을 부르지 않는다"

# 환경변수도 스위치로 쓰인다(일회성 실험용 — env > 파일)
: > "$TT_TMUX_LOG"
printf 'rc=on\nsnapshot=on\n' > "$CONF"
TT_RC=off TT_SNAPSHOT=off "$TTBIN" --cron >/dev/null 2>&1 || true
assert_eq "$(cat "$TT_TMUX_LOG")" "" "TT_RC=off TT_SNAPSHOT=off 가 파일의 on 을 이긴다"

# ── ③-b 깨진 줄 경고는 진입점당 한 번만 ────────────────────────────────────
# tt_conf_load 를 맨 statement 로 안 부르고 tt_conf_on 만 쓰면, tt_conf_on 이 내부에서
# `$(tt_conf_get …)` 로 포크하기 때문에 조회 횟수만큼 같은 경고가 다시 나온다.
# --cron 은 rc 와 snapshot 을 둘 다 조회한다 — 계약을 깨면 여기서 2가 된다.
cat > "$CONF" <<'EOF'
rc=on
snapshot=on
unknown_key=1
EOF
_warn=$("$TTBIN" --cron 2>&1 >/dev/null)
_count=$(printf '%s\n' "$_warn" | grep -c "모르는 키: unknown_key")
assert_eq "$_count" "1" "--cron 은 설정을 두 번 조회해도 경고는 한 번만"

# ── ④ 진짜 tmux 로 end-to-end ──────────────────────────────────────────────
export PATH="$REALPATH_SAVED"
if command -v tmux >/dev/null 2>&1; then
    # 격리 소켓($TMUX_TMPDIR=$TTROOT)에 우리 서버를 띄우고, 끝나면 반드시 죽인다.
    trap 'tmux kill-server >/dev/null 2>&1; rm -rf "$TTROOT"' EXIT
    if tmux new-session -d -s fmuxsw1 2>/dev/null; then
        printf 'rc=on\nsnapshot=on\n' > "$CONF"
        out=$("$TTBIN" --snapshot 2>&1) || true
        assert_contains "$out" "fmuxsw1" "snapshot=on 이면 살아있는 세션을 기록한다"
        assert_contains "$(cat "$STATE/manifest" 2>/dev/null || true)" "fmuxsw1" "대장에 줄이 들어간다"
        assert_contains "$("$TTBIN" --rc 2>&1)" "SESSION" "rc=on 이면 현황표를 그린다"

        before=$(cat "$STATE/manifest")
        tmux new-session -d -s fmuxsw2 2>/dev/null || true
        printf 'rc=off\nsnapshot=off\n' > "$CONF"
        out=$("$TTBIN" --snapshot 2>&1) || true
        assert_contains "$out" "snapshot=off" "꺼짐 메시지는 진짜 tmux 가 있어도 같다"
        assert_eq "$(cat "$STATE/manifest")" "$before" "꺼져 있으면 새 세션이 떠도 대장을 안 건드린다"
        case "$("$TTBIN" --rc 2>&1)" in *SESSION*) seen=yes ;; *) seen=no ;; esac
        assert_eq "$seen" "no" "rc=off 면 현황표를 그리지 않는다"

        # 규율 ①의 end-to-end 판: rc 를 꺼도 크론 한 틱이 대장을 새로 쓴다
        printf 'rc=off\nsnapshot=on\n' > "$CONF"
        rm -f "$STATE/manifest"
        "$TTBIN" --cron >/dev/null 2>&1 || true
        assert_contains "$(cat "$STATE/manifest" 2>/dev/null || true)" "fmuxsw2" \
            "rc=off 여도 --cron 한 틱이 대장을 새로 쓴다"
    fi
    tmux kill-server >/dev/null 2>&1 || true
else
    printf '  --   tmux 없음 — end-to-end 판정은 건너뜀\n'
fi

tt_test_done
