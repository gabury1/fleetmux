#!/usr/bin/env bash
# install.sh — 가짜 HOME·가짜 PATH 에서만 돈다.
#
# ⛔ 진짜 tmux 를 절대 부르지 않는다. 이 기계에는 살아있는 함대가 있다.
#    PATH 를 통째로 봉인한다(SEAL): 필요한 유틸의 심링크만 든 디렉토리 하나 + 가짜 tmux/fzf.
#    가짜 tmux 는 `-V` 에만 답하고, 그 외 인자로 불리면 LEAK 파일을 남기고 rc 1 로 죽는다.
#    파일 끝에서 "가짜 tmux 는 -V 로만 불렸다"를 단언한다 — 진짜 호출이 새면 여기서 터진다.
set -u
. "$(dirname "$0")/lib.sh"

ORIGPATH="$PATH"
REPO=$(cd "$(dirname "$0")/.." && pwd -P) || exit 1
tt_test_sandbox

INST="$REPO/install.sh"
CALLS="$TTROOT/tmux-calls.log"
LEAK="$TTROOT/tmux-LEAK.log"

# ── PATH 봉인 ────────────────────────────────────────────────────────────────
# 이 기계에 진짜 fzf 가 어디 깔렸는지에 테스트가 기대면 안 된다("fzf 없음" 케이스가 기계마다
# 다른 답을 낸다). 그래서 필요한 유틸만 골라 심링크한 디렉토리를 만들고 PATH 를 그것만으로 짠다.
SEAL="$TTROOT/seal"
mkdir -p "$SEAL"
for c in sh bash env cat cp mv rm mkdir rmdir chmod ln cmp uname make awk sed grep tr cut \
         date ls dirname basename readlink sort head tail wc id touch find mktemp diff expr; do
    p=$(PATH="$ORIGPATH" command -v "$c" 2>/dev/null) || continue
    ln -sf "$p" "$SEAL/$c"
done
for c in bash awk make cmp; do
    [ -e "$SEAL/$c" ] || { echo "  FAIL 봉인 PATH 에 $c 가 없다 — 이 기계에서는 이 테스트를 돌릴 수 없다"; exit 1; }
done

# 가짜 tmux/fzf. 버전만 답한다.
mkstub() {   # $1=디렉토리 $2=tmux 버전('' 이면 tmux 를 안 만든다) $3=fzf 버전('' 이면 안 만듦)
    mkdir -p "$1"
    if [ -n "$2" ]; then
        {
            printf '#!/usr/bin/env bash\n'
            printf 'printf "%%s\\n" "tmux $*" >> "%s"\n' "$CALLS"
            printf 'if [ "${1:-}" = "-V" ]; then echo "tmux %s"; exit 0; fi\n' "$2"
            printf 'printf "%%s\\n" "LEAK: tmux $*" >> "%s"\n' "$LEAK"
            printf 'exit 1\n'
        } > "$1/tmux"
        chmod +x "$1/tmux"
    fi
    if [ -n "$3" ]; then
        {
            printf '#!/usr/bin/env bash\n'
            printf 'if [ "${1:-}" = "--version" ]; then echo "%s (test)"; exit 0; fi\n' "$3"
            printf 'printf "%%s\\n" "LEAK: fzf $*" >> "%s"\n' "$LEAK"
            printf 'exit 1\n'
        } > "$1/fzf"
        chmod +x "$1/fzf"
    fi
}

STUB_OK="$TTROOT/stub-ok";     mkstub "$STUB_OK"   3.5a  0.65.2
STUB_OLD="$TTROOT/stub-old";   mkstub "$STUB_OLD"  2.9a  0.65.2
STUB_NOFZF="$TTROOT/stub-nf";  mkstub "$STUB_NOFZF" 3.5a ''
STUB_NOTMUX="$TTROOT/stub-nt"; mkstub "$STUB_NOTMUX" ''   0.65.2
STUB_OLDFZF="$TTROOT/stub-of"; mkstub "$STUB_OLDFZF" 3.5a 0.44.1

OUT=''; RC=0
run_inst() {   # $1=스텁디렉토리, 나머지=install.sh 인자
    local stub="$1"; shift
    RC=0
    OUT=$(PATH="$stub:$SEAL" bash "$INST" "$@" < /dev/null 2>&1) || RC=$?
}

has() { case "$1" in *"$2"*) printf 'yes' ;; *) printf 'no' ;; esac; }
ex()  { if [ -e "$1" ]; then printf 'yes'; else printf 'no'; fi; }
cnt() { grep -c "$2" "$1" 2>/dev/null || true; }

BIN="$HOME/.local/bin"
LIBX="$HOME/.local/libexec/tt"
SNIP="$XDG_CONFIG_HOME/fleetmux/tmux.conf"
CONF="$XDG_CONFIG_HOME/fleetmux/config"
TMUXCONF="$HOME/.tmux.conf"

# ── ① 인자 처리 ─────────────────────────────────────────────────────────────
run_inst "$STUB_OK" --help
assert_eq "$RC" "0" "--help 는 rc 0"
assert_eq "$(has "$OUT" 'usage: ./install.sh')" "yes" "--help 가 사용법을 낸다"
assert_eq "$(ex "$BIN/fmux")" "no" "--help 는 아무것도 설치하지 않는다"

run_inst "$STUB_OK" --nonsense
assert_eq "$RC" "2" "모르는 옵션은 rc 2"
assert_eq "$(has "$OUT" '모르는 옵션')" "yes" "모르는 옵션을 이름으로 말한다"

# ── ② 의존성이 없거나 낮으면 멈춘다 ────────────────────────────────────────
run_inst "$STUB_OLD"
assert_eq "$RC" "1" "tmux 2.9a 면 멈춘다"
assert_eq "$(has "$OUT" 'tmux 2.9a')" "yes" "낮은 tmux 버전을 그대로 보여준다"
assert_eq "$(has "$OUT" '3.2')" "yes" "왜 필요한지(3.2)를 말한다"
assert_eq "$(has "$OUT" '아무것도 바꾸지 않았다')" "yes" "멈출 때 아무것도 안 바꿨다고 말한다"
assert_eq "$(ex "$BIN/fmux")" "no" "의존성 실패면 바이너리를 안 깐다"
assert_eq "$(ex "$LIBX")" "no" "의존성 실패면 shim 도 안 깐다"

run_inst "$STUB_NOTMUX"
assert_eq "$RC" "1" "tmux 가 없으면 멈춘다"
assert_eq "$(has "$OUT" 'tmux 가 없다')" "yes" "없는 것을 이름으로 말한다"

run_inst "$STUB_NOFZF"
assert_eq "$RC" "1" "fzf 가 없으면 멈춘다"
assert_eq "$(has "$OUT" 'fzf 가 없다')" "yes" "fzf 가 왜 필요한지 말한다"

run_inst "$STUB_OLDFZF"
assert_eq "$RC" "1" "fzf 0.44.1 이면 멈춘다"
assert_eq "$(has "$OUT" '0.64')" "yes" "fzf 요구 버전을 말한다"
assert_eq "$(ex "$BIN")" "no" "여기까지 아무것도 안 생겼다"

# ── ③ --dry-run 은 아무것도 안 바꾼다 ───────────────────────────────────────
run_inst "$STUB_OK" --dry-run
assert_eq "$RC" "0" "--dry-run 은 rc 0"
assert_eq "$(has "$OUT" '--dry-run')" "yes" "dry-run 임을 머리에 밝힌다"
assert_eq "$(has "$OUT" 'dry  ')" "yes" "할 일을 dry 줄로 보여준다"
assert_eq "$(ex "$BIN/fmux")" "no" "dry-run 은 바이너리를 안 만든다"
assert_eq "$(ex "$LIBX/claude")" "no" "dry-run 은 shim 을 안 만든다"
assert_eq "$(ex "$SNIP")" "no" "dry-run 은 스니펫을 안 만든다"
assert_eq "$(ex "$TMUXCONF")" "no" "dry-run 은 ~/.tmux.conf 를 안 만든다"
assert_eq "$(ex "$HOME/.claude")" "no" "dry-run 은 ~/.claude 를 안 만든다"
assert_eq "$(has "$OUT" '--cron')" "yes" "크론 줄을 보여준다"
assert_eq "$(has "$OUT" '@reboot')" "yes" "@reboot 줄도 보여준다"
assert_eq "$(has "$OUT" 'crontab')" "yes" "crontab 은 직접 넣으라고 말한다"

# ── ④ 실제 설치 — 터미널이 아니면 동의 없이 남의 파일을 안 고친다 ──────────
printf 'set -g mouse on\n' > "$TMUXCONF"
cp "$TMUXCONF" "$TTROOT/tmuxconf.before"

run_inst "$STUB_OK"
assert_eq "$RC" "0" "설치는 rc 0"
assert_eq "$(ex "$BIN/fmux")" "yes" "fmux 가 깔린다"
assert_rc 0 test -x "$BIN/fmux"
assert_rc 0 test -L "$BIN/tt"
assert_eq "$(ex "$LIBX/claude")" "yes" "claude shim 이 깔린다"
assert_eq "$(ex "$LIBX/codex")" "yes" "codex shim 이 깔린다"
assert_rc 0 test -x "$LIBX/claude"
assert_eq "$(ex "$SNIP")" "yes" "tmux 스니펫이 생긴다"
assert_eq "$(has "$(cat "$SNIP")" 'bind F ')" "yes" "스니펫에 소환키가 들어 있다"

# 동의 없이 ~/.tmux.conf 를 고치지 않는다 — 바이트로 잰다
assert_rc 0 cmp -s "$TTROOT/tmuxconf.before" "$TMUXCONF"
assert_eq "$(cnt "$TMUXCONF" 'source-file')" "0" "동의 없이는 source-file 줄이 안 들어간다"
assert_eq "$(has "$OUT" '터미널이 아니라 묻지 않았다')" "yes" "왜 안 넣었는지 말한다"
assert_eq "$(has "$OUT" "source-file $SNIP")" "yes" "대신 넣을 줄을 화면에 보여준다"

# 안 뺏는 쪽(safe)으로 간다 — 무prefix 바인딩이 없다
assert_eq "$(grep -c '^bind -n ' "$SNIP" || true)" "0" "터미널이 아니면 무prefix 키를 안 뺏는다"

# shim 이 무엇인지 한 줄 설명 + PATH 안내
assert_eq "$(has "$OUT" 'tmux 안에서 뜬 claude/codex')" "yes" "shim 이 무엇을 하는지 설명한다"
assert_eq "$(has "$OUT" 'export PATH=')" "yes" "PATH 넣는 법을 알려준다"
assert_eq "$(has "$OUT" '지우려면')" "yes" "지우는 법을 알려준다"
assert_eq "$(has "$OUT" "$LIBX")" "yes" "무엇을 어디 놓았는지 경로로 말한다"

# ~/.claude 는 스킬이 없으면 안 만든다
assert_eq "$(ex "$HOME/.claude")" "no" "스킬이 없으면 ~/.claude 를 안 건드린다"
assert_eq "$(has "$OUT" 'SKILL.md 가 없다')" "yes" "스킬이 없으면 건너뛴다고 말한다"

# ── ⑤ 두 번째 실행 — 멱등 ──────────────────────────────────────────────────
cp -R "$HOME/.local" "$TTROOT/local.before"
run_inst "$STUB_OK"
assert_eq "$RC" "0" "두 번째 실행도 rc 0"
assert_eq "$(has "$OUT" '이미 같은 내용')" "yes" "이미 있는 것은 그대로 둔다고 말한다"
assert_rc 0 cmp -s "$TTROOT/local.before/bin/fmux" "$BIN/fmux"
assert_rc 0 cmp -s "$TTROOT/local.before/libexec/tt/claude" "$LIBX/claude"
assert_rc 0 cmp -s "$TTROOT/tmuxconf.before" "$TMUXCONF"
assert_eq "$(cnt "$TMUXCONF" 'source-file')" "0" "두 번째 실행도 남의 파일을 안 고친다"

# ── ⑥ --yes 는 동의다 — 한 줄만, 두 번 돌려도 한 줄 ────────────────────────
run_inst "$STUB_OK" --yes
assert_eq "$RC" "0" "--yes 설치는 rc 0"
assert_eq "$(cnt "$TMUXCONF" 'source-file')" "1" "--yes 면 source-file 줄이 들어간다"
assert_eq "$(cnt "$TMUXCONF" 'mouse on')" "1" "원래 있던 줄은 그대로다"

run_inst "$STUB_OK" --yes
assert_eq "$RC" "0" "--yes 두 번째도 rc 0"
assert_eq "$(cnt "$TMUXCONF" 'source-file')" "1" "두 번 돌려도 중복 줄이 안 생긴다"
assert_eq "$(has "$OUT" '이미 이 파일을 source')" "yes" "이미 있으면 그렇다고 말한다"

# 주석으로만 적혀 있으면 없는 것으로 본다(그건 안 도는 줄이다)
cp "$TMUXCONF" "$TTROOT/tmuxconf.sourced"
printf 'set -g mouse on\n# source-file %s\n' "$SNIP" > "$TMUXCONF"
run_inst "$STUB_OK" --yes
assert_eq "$(cnt "$TMUXCONF" '^source-file')" "1" "주석 줄은 source 로 안 친다"
cp "$TTROOT/tmuxconf.sourced" "$TMUXCONF"

# ── ⑦ 소환키 프리셋 ────────────────────────────────────────────────────────
run_inst "$STUB_OK" --yes --preset mac
assert_eq "$RC" "0" "--preset mac 은 rc 0"
assert_eq "$(has "$(cat "$CONF")" 'key_summon_fast=M-b')" "yes" "mac 프리셋이 설정에 들어간다"
assert_eq "$(grep -c '^bind -n M-b ' "$SNIP" || true)" "1" "스니펫이 따라 바뀐다"
assert_eq "$(has "$OUT" 'Option')" "yes" "왜 M-b 인지 한 줄로 말한다"

run_inst "$STUB_OK" --yes --preset mac
assert_eq "$(has "$OUT" "이미 'M-b' 다")" "yes" "같은 프리셋을 다시 돌리면 그대로 둔다"

run_inst "$STUB_OK" --yes --preset wsl
assert_eq "$(grep -c '^bind -n C-Left ' "$SNIP" || true)" "1" "wsl 프리셋은 C-Left"
assert_eq "$(grep -c '^bind -n M-b ' "$SNIP" || true)" "0" "이전 프리셋 키는 걷힌다"
assert_eq "$(grep -c '^unbind -n -q M-b' "$SNIP" || true)" "1" "걷은 키에 unbind 가 남는다"

run_inst "$STUB_OK" --yes --preset safe
assert_eq "$(grep -c '^bind -n ' "$SNIP" || true)" "0" "safe 는 무prefix 키를 하나도 안 건다"

run_inst "$STUB_OK" --preset nope
assert_eq "$RC" "1" "모르는 프리셋이면 멈춘다"
assert_eq "$(has "$OUT" 'safe|mac|linux|wsl')" "yes" "쓸 수 있는 프리셋을 알려준다"

# ── ⑧ 설치 뒤 --dry-run 도 여전히 아무것도 안 바꾼다 ───────────────────────
cp -R "$HOME/.local" "$TTROOT/local.dry"
cp "$SNIP" "$TTROOT/snip.dry"; cp "$CONF" "$TTROOT/conf.dry"; cp "$TMUXCONF" "$TTROOT/tmuxconf.dry"
run_inst "$STUB_OK" --dry-run --yes --preset mac
assert_eq "$RC" "0" "설치 뒤 dry-run 도 rc 0"
assert_rc 0 cmp -s "$TTROOT/snip.dry" "$SNIP"
assert_rc 0 cmp -s "$TTROOT/conf.dry" "$CONF"
assert_rc 0 cmp -s "$TTROOT/tmuxconf.dry" "$TMUXCONF"
assert_rc 0 cmp -s "$TTROOT/local.dry/bin/fmux" "$BIN/fmux"
assert_eq "$(has "$OUT" 'config set key_summon_fast')" "yes" "dry-run 은 바꿀 값을 말만 한다"

# ── ⑨ 스킬 — 있으면 물어보고 깐다 ──────────────────────────────────────────
# 레포를 복제해 스킬 파일을 넣는다(진짜 레포는 안 건드린다).
REPO2="$TTROOT/repo2"
mkdir -p "$REPO2/skills/fleetmux"
cp "$INST" "$REPO2/install.sh"
cp "$REPO/Makefile" "$REPO2/Makefile"
cp -R "$REPO/src" "$REPO/bin" "$REPO/libexec" "$REPO2/"
printf -- '---\nname: fleetmux\n---\n테스트용 스킬\n' > "$REPO2/skills/fleetmux/SKILL.md"
RC=0
OUT=$(PATH="$STUB_OK:$SEAL" bash "$REPO2/install.sh" --yes < /dev/null 2>&1) || RC=$?
assert_eq "$RC" "0" "스킬이 있는 레포에서도 rc 0"
assert_eq "$(ex "$HOME/.claude/skills/fleetmux/SKILL.md")" "yes" "스킬을 ~/.claude/skills 로 깐다"
assert_eq "$(has "$OUT" 'skills/fleetmux')" "yes" "어디 깔았는지 말한다"

# 동의 없이는 안 깐다 — 스킬을 지우고 터미널 없이 다시
rm -rf "$HOME/.claude"
RC=0
OUT=$(PATH="$STUB_OK:$SEAL" bash "$REPO2/install.sh" < /dev/null 2>&1) || RC=$?
assert_eq "$(ex "$HOME/.claude")" "no" "동의 없이는 ~/.claude 에 아무것도 안 만든다"

# ── ⑩ shim 의 PATH 순서 판정 ───────────────────────────────────────────────
# 훅이 안 붙는 가장 흔한 원인이다: 진짜 claude 가 shim 보다 PATH 앞에 있는 경우.
printf '#!/bin/sh\nexit 0\n' > "$STUB_OK/claude"; chmod +x "$STUB_OK/claude"
RC=0
OUT=$(PATH="$STUB_OK:$SEAL:$LIBX" bash "$INST" < /dev/null 2>&1) || RC=$?
assert_eq "$RC" "0" "PATH 순서가 나빠도 설치는 끝난다"
assert_eq "$(has "$OUT" '보다 앞이다 — 훅이 안 붙는다')" "yes" "진짜 claude 가 앞서면 경고한다"
RC=0
OUT=$(PATH="$LIBX:$STUB_OK:$SEAL" bash "$INST" < /dev/null 2>&1) || RC=$?
assert_eq "$(has "$OUT" 'PATH 순서 좋다')" "yes" "shim 이 앞서면 좋다고 말한다"
assert_eq "$(has "$OUT" '보다 앞이다 — 훅이 안 붙는다')" "no" "그때는 경고하지 않는다"
rm -f "$STUB_OK/claude"

# ── ⑪ 남의 tt 는 덮지 않는다 ───────────────────────────────────────────────
ALT="$TTROOT/alt"
mkdir -p "$ALT/bin"
printf '#!/bin/sh\necho 남의 tt\n' > "$ALT/bin/tt"; chmod +x "$ALT/bin/tt"
cp "$ALT/bin/tt" "$TTROOT/tt.before"
run_inst "$STUB_OK" --prefix "$ALT" --preset safe
assert_eq "$RC" "0" "남의 tt 가 있어도 설치는 끝난다"
assert_rc 0 cmp -s "$TTROOT/tt.before" "$ALT/bin/tt"
assert_eq "$(has "$OUT" '심링크가 아닌 파일이다')" "yes" "남의 tt 를 건드리지 않았다고 말한다"

# ── ⑫ 못 쓰는 prefix — 어디까지 했는지 말하고 멈춘다 ───────────────────────
NOPREFIX="$TTROOT/notadir"
: > "$NOPREFIX"
run_inst "$STUB_OK" --prefix "$NOPREFIX"
assert_eq "$RC" "1" "설치할 수 없는 자리면 멈춘다"
assert_eq "$(has "$OUT" '설치를 멈춘다')" "yes" "멈췄다고 말한다"
assert_rc 0 test -f "$NOPREFIX"

# ── ⑬ 진짜 tmux 가 샜나 ────────────────────────────────────────────────────
assert_eq "$(ex "$LEAK")" "no" "가짜 tmux/fzf 가 -V 말고 다른 인자로 불린 적이 없다"
assert_eq "$(cnt "$CALLS" '^tmux -V$')" "$(cnt "$CALLS" '^tmux ')" "tmux 호출은 전부 -V 였다"
assert_rc 0 test -s "$CALLS"

tt_test_done
