#!/usr/bin/env bash
# rc · snapshot · boot_restore 스위치.
#
# 이 테스트가 지켜야 하는 것은 "꺼지면 조용히 성공한다" 하나가 아니다. 네 가지다:
#   ① 꺼짐 — rc 0 으로 끝나고, 이유를 stdout 한 줄로 말하고, tmux 를 아예 부르지 않는다.
#   ② 켜짐 — 예전 그대로 tmux 를 부른다(스위치가 기능을 죽이지 않았다).
#   ③ rc=off 여도 --cron 의 --snapshot 은 산다(exit 0 으로 끄면 여기서 걸린다).
#   ④ 켜짐 end-to-end — 스위치를 지나 대장(manifest)에 실제로 줄이 들어간다.
#
# 전부 "가짜 tmux"로 잰다: PATH 맨 앞에 tmux 라는 이름의 bash 스크립트를 세워
#   (a) 호출을 한 줄씩 받아 적고  (b) ls·display-message 에만 세션 하나를 흉내 내 답한다.
# 진짜 tmux 바이너리는 이 파일에서 단 한 번도 실행되지 않는다. 이건 편의가 아니라 규율이다 —
# 예전 판은 ④ 를 재려고 진짜 서버를 띄우고 끝에 `tmux kill-server` 를 trap 으로 걸었는데,
# 소켓 격리(TMUX_TMPDIR)가 한 번이라도 새면 그 한 줄이 개발자의 살아있는 함대를 통째로 죽인다.
# 실제로 그 사고가 났다. 가짜 tmux 는 "몇 번 어떤 인자로 불렸나"까지 재므로 오히려 더 촘촘하다.
# 진짜 tmux 서버와의 end-to-end 는 이 스위트의 범위 밖으로 둔다(손으로 확인할 일).
set -u
. "$(dirname "$0")/lib.sh"
tt_test_sandbox

CONF="$XDG_CONFIG_HOME/fleetmux/config"
mkdir -p "$(dirname "$CONF")"
STATE="$HOME/.cache/tt"

# ── 가짜 tmux ──────────────────────────────────────────────────────────────
# 받아 적기 + 최소한의 응답. 모르는 하위명령은 rc 1 로 답한다(진짜 tmux 가 서버 없을 때와 같다).
#   list-panes 가 빈손이면 rc_target 이 실패해 rc 라운드는 send-keys 까지 가지 않는다 —
#   즉 이 shim 아래서는 복구 주입이 절대 발사되지 않는다(sleep 8 도 안 탄다).
mkdir -p "$TTROOT/bin"
cat > "$TTROOT/bin/tmux" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TT_TMUX_LOG"
case "$1" in
    ls)
        # -F 포맷의 구분자가 진입점마다 다르다(rc=공백, 스냅샷=탭) — 그대로 흉내 낸다.
        case "$*" in
            *"#{session_id}"$'\t'"#{session_name}"*) printf '$1\tfmuxsw1\n' ;;
            *)                                       printf '$1 fmuxsw1\n' ;;
        esac ;;
    display-message) printf '%s\t%s\n' "$HOME" bash ;;
    *) exit 1 ;;
esac
SHIM
chmod +x "$TTROOT/bin/tmux"
export TT_TMUX_LOG="$TTROOT/tmux-calls.log"
: > "$TT_TMUX_LOG"
# 두 진입점의 tmux ls 는 포맷 문자열이 다르다 — 로그에서 서로 구분된다.
RC_CALL='ls -F #{session_id} #{session_name}'                 # 60-rc.sh 의 rc 라운드(공백)
SNAP_CALL="ls -F #{session_id}"$'\t'"#{session_name}"         # 70-fleet.sh 의 스냅샷(탭)
export PATH="$TTROOT/bin:$PATH"

# 로그에 그 호출이 있었나 — assert_contains 는 "없음"을 못 재므로 없음 전용 헬퍼를 둔다
seen_call() { case "$(cat "$TT_TMUX_LOG")" in *"$1"*) echo yes ;; *) echo no ;; esac; }

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
# 그리고 이게 핵심: 꺼진 진입점은 tmux 를 단 한 번도 부르지 않는다(조기 return 이 첫 tmux 앞이다).
#   세션이 있는데도 안 부른다는 뜻이다 — 위 shim 은 물어보기만 하면 언제나 세션 하나를 답한다.
assert_eq "$(cat "$TT_TMUX_LOG")" "" "전부 꺼져 있으면 tmux 를 한 번도 부르지 않는다"

# ── ② 전부 켜짐 — 예전처럼 tmux 를 부른다 ──────────────────────────────────
: > "$TT_TMUX_LOG"
printf 'rc=on\nsnapshot=on\n' > "$CONF"
"$TTBIN" --cron >/dev/null 2>&1 || true
log=$(cat "$TT_TMUX_LOG")
assert_contains "$log" "$RC_CALL"   "rc=on 이면 --cron 이 rc 라운드를 돈다"
assert_contains "$log" "$SNAP_CALL" "snapshot=on 이면 --cron 이 스냅샷도 부른다"

: > "$TT_TMUX_LOG"
assert_contains "$("$TTBIN" --rc 2>&1)" "SESSION" "rc=on 이면 --rc 가 현황표를 그린다"
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
assert_contains "$(cat "$TT_TMUX_LOG")" "$SNAP_CALL" "rc=off 여도 --cron 은 스냅샷을 부른다"
assert_eq "$(seen_call "$RC_CALL")" "no" "rc=off 면 --cron 의 rc 라운드는 tmux 를 부르지 않는다"

# 반대쪽 — snapshot 만 꺼짐: rc 라운드는 살고 스냅샷 포크는 없다
: > "$TT_TMUX_LOG"
printf 'rc=on\nsnapshot=off\n' > "$CONF"
"$TTBIN" --cron >/dev/null 2>&1 || true
assert_contains "$(cat "$TT_TMUX_LOG")" "$RC_CALL" "snapshot=off 여도 rc 라운드는 돈다"
assert_eq "$(seen_call "$SNAP_CALL")" "no" "snapshot=off 면 --cron 이 스냅샷을 부르지 않는다"

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

# ── ④ 켜짐 end-to-end — 스위치를 지나 대장까지 간다 ────────────────────────
# ①~③ 은 "tmux 를 불렀나"까지만 잰다. 스위치가 tmux 호출은 통과시키면서 그 뒤 로직을
# 망가뜨렸다면 거기선 안 잡힌다 → 산출물(manifest)로 한 번 더 못을 박는다.
rm -f "$STATE/manifest"
printf 'snapshot=on\n' > "$CONF"
out=$("$TTBIN" --snapshot 2>&1) || true
assert_contains "$out" "fmuxsw1" "snapshot=on 이면 살아있는 세션을 기록한다"
assert_contains "$out" "snapshot: 1 sessions" "켜져 있으면 예전 그대로 요약 줄을 찍는다"
assert_contains "$(cat "$STATE/manifest" 2>/dev/null || true)" "fmuxsw1" "대장에 줄이 들어간다"

# 그리고 꺼면 그 대장을 더 이상 건드리지 않는다(새 세션이 떠도 파일이 그대로다)
before=$(cat "$STATE/manifest")
printf 'snapshot=off\n' > "$CONF"
"$TTBIN" --snapshot >/dev/null 2>&1 || true
assert_eq "$(cat "$STATE/manifest")" "$before" "꺼져 있으면 대장을 안 건드린다"

# 규율 ①의 end-to-end 판: rc 를 꺼도 크론 한 틱이 대장을 새로 쓴다
printf 'rc=off\nsnapshot=on\n' > "$CONF"
rm -f "$STATE/manifest"
"$TTBIN" --cron >/dev/null 2>&1 || true
assert_contains "$(cat "$STATE/manifest" 2>/dev/null || true)" "fmuxsw1" \
    "rc=off 여도 --cron 한 틱이 대장을 새로 쓴다"

tt_test_done
