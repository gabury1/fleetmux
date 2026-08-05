#!/usr/bin/env bash
# 문서와 코드가 갈라지면 여기서 터진다.
#
# README 와 스킬은 팀원이 처음 읽는 것이고, 거기 적힌 명령·경로가 실재하지 않으면
# "설치가 안 된다"가 아니라 "이 도구는 거짓말을 한다"가 된다. 그래서 문서를 검사한다:
#   ① README 가 안내하는 파일·경로가 실재하는가 (install.sh, libexec 경로, 스킬)
#   ② README 의 설정 표가 실제 기본값·배선 상태와 같은가 (거짓말하는 표 금지)
#   ③ 스킬이 안내하는 tt 진입점이 실제 src 에 있는가
#
# tmux 는 단 한 줄도 부르지 않는다. 여기서 쓰는 `tt config …` 는 tmux 를 안 타는 문이다.
set -u
. "$(dirname "$0")/lib.sh"
tt_test_sandbox
cd "$(dirname "$0")/.." || exit 1

README=README.md
SKILL=skills/fleetmux/SKILL.md
SRC=$(cat src/*.sh)
RM=$(cat "$README")

# ── ① README 가 안내하는 것이 실재하는가 ───────────────────────────────────
assert_rc 0 test -f "$README"
assert_contains "$RM" './install.sh' "README 가 install.sh 를 안내한다"
assert_rc 0 test -x install.sh

# 안내한 옵션이 실제로 있는 옵션이어야 한다. --help 는 의존성 검사 전에 exit 하므로
# 아무것도 설치하지 않고 tmux 도 안 부른다.
usage=$(./install.sh --help 2>&1) || usage=''
for opt in --dry-run --yes --prefix --preset; do
    assert_contains "$RM"    "$opt" "README 가 $opt 를 안내한다"
    assert_contains "$usage" "$opt" "install.sh 가 $opt 를 실제로 받는다"
done

# ── ①-b libexec 경로 오기 ──────────────────────────────────────────────────
# shim 자리는 ~/.local/libexec/tt/ 다. 옛 README 는 libexec/fleetmux 라고 적었고,
# 그 경로로 PATH 를 잡은 사람은 훅이 하나도 안 붙는 채로 조용히 산다.
assert_eq "$(grep -c 'libexec/fleetmux' "$README" || true)" "0" \
    "README 에 옛 경로 libexec/fleetmux 가 남아 있지 않다"
assert_contains "$RM" '~/.local/libexec/tt/' "README 가 실제 shim 경로를 적는다"
assert_contains "$(cat install.sh)" 'libexec/tt' "install.sh 도 같은 경로를 쓴다"
assert_contains "$SRC" 'libexec/tt' "복원 PATH 보정도 같은 경로를 쓴다"

# ── ①-c 크론 안내가 실재하는 진입점인가 ────────────────────────────────────
for flag in --cron --boot-restore; do
    assert_contains "$RM"  "$flag" "README 의 크론 안내가 $flag 를 쓴다"
    assert_contains "$SRC" "\"\${1:-}\" = \"$flag\"" "$flag 진입점이 실제로 있다"
done

# ── ①-d Scripting surface 에 적은 문이 전부 실재하는가 ─────────────────────
for flag in --list --status --preview --rc --snapshot --restore --forget \
            --hook --hooks-json --codex-hooks --tmux-conf --do-broadcast --help; do
    assert_contains "$RM"  "$flag" "README 가 $flag 를 안내한다"
    assert_contains "$SRC" "\"\${1:-}\" = \"$flag\"" "$flag 진입점이 실제로 있다"
done
assert_contains "$SRC" '"${1:-}" = "config"' "tt config 진입점이 실제로 있다"

# ── ② 설정 표가 정직한가 ───────────────────────────────────────────────────
# README 는 "물린 키"와 "저장만 되는 키"를 나눠 적는다. 그 분류가 코드 판정
# (tt config list 의 미배선 표시)과 어긋나면, 문서가 안 도는 토글을 파는 것이다.
WIRED='rc snapshot snapshot_on_exit boot_restore recent_hours unseen_minutes accent log_max key_summon key_summon_fast'
UNWIRED='key_new key_rename key_kill key_reload key_detach key_broadcast key_help key_settings'

list=$("$TTBIN" config list 2>/dev/null) || list=''
assert_contains "$list" "KEY" "tt config list 가 표를 낸다"

for k in $WIRED; do
    row=$(printf '%s\n' "$list" | grep "^$k ") || row=''
    case "$row" in *미배선*) got=unwired ;; *) got=wired ;; esac
    assert_eq "$got" "wired" "$k 은 코드에서 물려 있다 (README 의 배선 표와 일치)"
    assert_contains "$RM" "\`$k\`" "README 가 $k 를 적는다"
done
for k in $UNWIRED; do
    row=$(printf '%s\n' "$list" | grep "^$k ") || row=''
    case "$row" in *미배선*) got=unwired ;; *) got=wired ;; esac
    assert_eq "$got" "unwired" "$k 은 아직 안 물렸다 (README 의 미배선 목록과 일치)"
    assert_contains "$RM" "\`$k\`" "README 가 미배선 키 $k 를 적는다"
done

# 알려진 키 전부가 README 의 둘 중 한 목록에 있어야 한다 — 새 키를 추가하고 문서를
# 안 고치면 여기서 걸린다.
keys=$(grep -m1 '^TT_CONF_KEYS=' src/05-config.sh | sed "s/^TT_CONF_KEYS='//; s/'$//")
for k in $keys; do
    got=no
    case " $WIRED $UNWIRED " in *" $k "*) got=yes ;; esac
    assert_eq "$got" "yes" "$k 이 README 의 설정 표에 분류돼 있다"
done

# ②-b 표에 적은 기본값이 진짜 기본값인가. README 행 모양: | `key` | `value` | … |
#      key_summon_fast 만 빈 값이라 *(empty)* 로 적는다.
for k in $WIRED; do
    want=$("$TTBIN" config get "$k" 2>/dev/null) || want=''
    doc=$(grep "^| \`$k\` |" "$README" | head -1 | awk -F'|' '{print $3}' \
          | sed 's/^ *//; s/ *$//; s/^`//; s/`$//') || doc=''
    case "$doc" in '*(empty)*') doc='' ;; esac
    assert_eq "$doc" "$want" "README 가 적은 $k 기본값이 코드 기본값과 같다"
done

# ②-c "끄기의 의미" 가 실제 동작과 붙어 있는가 — 문서가 근거로 든 문자열이 코드에 있다.
assert_contains "$RM"  'no-autorestore' "README 가 한 번만 건너뛰는 방법을 적는다"
assert_contains "$SRC" 'no-autorestore' "no-autorestore 를 실제로 코드가 읽는다"
assert_contains "$RM"  'older than 7 days' "README 가 매니페스트 낡음 경고 문구를 적는다"
assert_contains "$SRC" 'older than 7 days' "그 경고 문구가 실제 코드에 있다"
assert_contains "$SRC" 'rc=off' "rc=off 안내가 실제 코드에 있다"

# ── ③ 스킬 ─────────────────────────────────────────────────────────────────
assert_rc 0 test -f "$SKILL"
SK=$(cat "$SKILL")
FM=$(sed -n '1,8p' "$SKILL")
assert_eq "$(head -1 "$SKILL")" "---" "프론트매터로 시작한다"
assert_contains "$FM" "name: fleetmux" "name 필드가 있다"
assert_contains "$FM" "description:" "description 필드가 있다"
assert_eq "$(sed -n '2,8p' "$SKILL" | grep -c '^---$' || true)" "1" "프론트매터가 닫힌다"

# 스킬이 안내하는 명령이 실제로 존재하는 진입점이어야 한다.
for cmd in --status --list --preview --do-broadcast; do
    assert_contains "$SK"  "tt $cmd" "스킬이 tt $cmd 를 안내한다"
    assert_contains "$SRC" "\"\${1:-}\" = \"$cmd\"" "$cmd 진입점이 실제로 있다"
done

# 상태 파일 경로도 실재해야 한다 — 스킬이 없는 파일을 cat 하게 만들면 안 된다.
assert_contains "$SK"  '~/.cache/tt/hook-' "스킬이 훅 상태 파일을 안내한다"
assert_contains "$SRC" 'STATE/hook-'       "훅 상태 파일을 코드가 실제로 쓴다"
assert_contains "$SK"  '~/.cache/tt/manifest' "스킬이 매니페스트를 안내한다"
assert_contains "$SRC" 'MANIFEST="${TT_MANIFEST:-$STATE/manifest}"' "매니페스트 경로가 그대로다"
assert_contains "$SK"  '~/.cache/tt/hook.log' "스킬이 감사 로그를 안내한다"
assert_contains "$SRC" 'STATE/hook.log'       "감사 로그를 코드가 실제로 쓴다"
assert_contains "$SK"  '~/.cache/tt/finished' "스킬이 finished 를 안내한다"
assert_contains "$SRC" 'STATE/finished'       "finished 를 코드가 실제로 쓴다"

# 규율 — 이 문장들이 빠지면 스킬은 화면 긁기로 되돌아간다.
assert_contains "$SK" "read-only" "읽기 전용이 기본이라고 못박는다"
assert_contains "$SK" "Hook state is the fact" "훅이 사실이고 화면은 렌더링이라는 규율이 있다"
assert_contains "$SK" "--settings--" "목록 맨 끝 설정 행이 세션이 아니라고 알린다"
assert_contains "$SRC" "TT_SETTINGS_ROW='--settings--'" "설정 행 센티넬 값이 그대로다"

# 스킬은 Claude Code 전용이다 — codex 에는 스킬 개념이 없다. README 가 그렇게 적어야 한다.
assert_contains "$RM" 'Claude Code only' "README 가 스킬이 Claude Code 전용이라고 적는다"
assert_contains "$RM" 'skills/fleetmux/SKILL.md' "README 가 스킬 파일 경로를 적는다"

# 설치기가 스킬을 어디로 깔지 말하는 곳과 README 가 말하는 곳이 같아야 한다.
assert_contains "$RM"              '~/.claude/skills/fleetmux' "README 의 스킬 설치 위치"
assert_contains "$(cat install.sh)" '.claude/skills/fleetmux'   "install.sh 의 스킬 설치 위치"

# ── ④ 소환키 문서 ──────────────────────────────────────────────────────────
# 플랫폼별 제약은 코드가 아니라 사실이라 코드로 못 잰다. 다만 README 가 근거로 든
# 키 이름이 스니펫 생성기가 아는 이름인지는 잴 수 있다.
for k in 'M-b' 'C-Left' 'M-Left'; do
    assert_contains "$RM"  "$k" "README 가 $k 를 설명한다"
    assert_contains "$SRC" "$k" "$k 가 스니펫 생성기의 후보 목록에 있다"
done
assert_contains "$RM" 'Mission Control' "macOS Ctrl+화살표가 뺏길 수 있다고 적는다"
assert_contains "$RM" 'Windows Terminal' "Windows Terminal 이 Alt+화살표를 먼저 먹는다고 적는다"
assert_contains "$RM" 'best effort' "WSL 은 best-effort 라고 적는다"
assert_contains "$RM" 'vmIdleTimeout' "vmIdleTimeout 이 답이 아니라고 적는다"
assert_contains "$RM" 'Task Scheduler' "@reboot cron 대신 작업 스케줄러가 필요하다고 적는다"

# 프리셋 이름은 install.sh 가 실제로 받는 것이어야 한다.
for p in safe mac linux wsl; do
    assert_contains "$RM"               "$p" "README 가 프리셋 $p 를 적는다"
    assert_contains "$(cat install.sh)" "$p)" "install.sh 가 프리셋 $p 를 받는다"
done

tt_test_done
