#!/usr/bin/env bash
# tmux 스니펫 생성기 — 렌더 결과 문자열만 검사한다.
# 여기서 진짜 tmux 를 절대 부르지 않는다: 이 테스트가 도는 기계에는 살아있는 함대가 있다.
# lib.sh 의 샌드박스가 TMUX 를 unset 하므로 --write 도 source-file 로 새지 않는다.
set -u
. "$(dirname "$0")/lib.sh"
tt_test_sandbox

CONF="$XDG_CONFIG_HOME/fleetmux/config"
SNIP="$XDG_CONFIG_HOME/fleetmux/tmux.conf"
mkdir -p "$(dirname "$CONF")"

# 줄머리로 세는 헬퍼 — "unbind -n" 은 "bind -n" 을 부분문자열로 품는다.
# assert_contains 로 무prefix 바인딩의 부재를 재면 unbind 줄에 걸려 늘 통과한다(거짓 ok).
count_lines() { printf '%s\n' "$1" | grep -c "$2" || true; }

# ── ① 기본값 — prefix 바인딩만 나오고 무prefix 는 없다 ────────────────────────
out=$("$TTBIN" --tmux-conf)
assert_contains "$out" "bind F " "기본 소환키 F 가 prefix 바인딩으로 나온다"
assert_eq "$(count_lines "$out" '^bind -n ')" "0" "기본값에는 무prefix 바인딩이 없다"
assert_eq "$(count_lines "$out" '^bind F ')" "1" "prefix 바인딩은 정확히 한 줄"
assert_contains "$out" "$SNIP" "머리말이 source-file 할 경로를 알려준다"

# ── ② 떠날 때 스냅샷 훅 ──────────────────────────────────────────────────────
assert_contains "$out" "client-detached" "client-detached 훅이 들어간다"
assert_contains "$out" "session-closed"  "session-closed 훅이 들어간다"
# client-detached 는 -b(떠나는 사람을 붙잡지 않는다), session-closed 는 동기
# (서버가 내려가는 중이라 백그라운드는 실행 전에 사라진다). 둘을 각각 잰다.
assert_eq "$(count_lines "$out" '^set-hook -g client-detached .run-shell -b ')" "1" \
    "client-detached 는 run-shell -b 로 백그라운드"
assert_eq "$(count_lines "$out" '^set-hook -g session-closed .run-shell \"')" "1" \
    "session-closed 는 -b 없이 동기"

# ── ③ 이전 판을 걷는 unbind ──────────────────────────────────────────────────
assert_contains "$out" "unbind -n" "지운 키를 위해 unbind 도 낸다"

# ── ④ fast 목록을 넣으면 항목마다 무prefix 바인딩이 생긴다 ───────────────────
printf 'key_summon_fast=C-Left M-b\n' > "$CONF"
out=$("$TTBIN" --tmux-conf)
assert_contains "$out" "bind -n C-Left " "C-Left 가 무prefix 로 걸린다"
assert_contains "$out" "bind -n M-b "    "M-b 가 무prefix 로 걸린다"
assert_eq "$(count_lines "$out" '^bind -n ')" "2" "목록 항목 수만큼만 걸린다"
assert_eq "$(count_lines "$out" '^bind F ')" "1" "fast 를 켜도 prefix 키는 남는다"
# 같은 키에 unbind 가 먼저 나와야 재적용이 멱등하다
assert_eq "$(count_lines "$out" '^unbind .*C-Left$')" "1" "거는 키도 먼저 걷는다"

# ── ⑤ key_summon 을 비우면 prefix 바인딩이 사라진다 ──────────────────────────
printf 'key_summon=\n' > "$CONF"
out=$("$TTBIN" --tmux-conf)
assert_eq "$(count_lines "$out" '^bind [A-Za-z]')" "0" "key_summon 이 비면 prefix 바인딩이 없다"

# ── ⑥ snapshot_on_exit=off 면 훅 두 줄이 빠진다 ──────────────────────────────
printf 'snapshot_on_exit=off\n' > "$CONF"
out=$("$TTBIN" --tmux-conf)
assert_eq "$(count_lines "$out" '^set-hook ')" "0" "snapshot_on_exit=off 면 훅이 빠진다"
assert_contains "$out" "bind F " "훅을 꺼도 소환키는 남는다"

# ── ⑦ --write 가 파일을 만든다 ───────────────────────────────────────────────
printf 'key_summon=T\n' > "$CONF"
assert_rc 0 test ! -e "$SNIP"
assert_rc 0 "$TTBIN" --tmux-conf --write
assert_rc 0 test -f "$SNIP"
assert_contains "$(cat "$SNIP")" "bind T " "쓰인 파일에 바뀐 키가 들어 있다"
assert_eq "$("$TTBIN" --tmux-conf --write)" "$SNIP" "--write 는 쓴 경로를 알려준다"
# 임시 파일을 남기지 않는다(원자적 쓰기)
assert_eq "$(count_lines "$(ls "$(dirname "$SNIP")")" '^tmux\.conf\.tmp')" "0" "임시 파일이 안 남는다"

# ── ⑧ config set 이 스니펫을 다시 쓴다 ──────────────────────────────────────
"$TTBIN" config set key_summon G >/dev/null
assert_contains "$(cat "$SNIP")" "bind G " "key_summon 을 바꾸면 스니펫이 갱신된다"
"$TTBIN" config set key_summon_fast "M-Left" >/dev/null
assert_contains "$(cat "$SNIP")" "bind -n M-Left " "key_summon_fast 를 바꾸면 스니펫이 갱신된다"
"$TTBIN" config set snapshot_on_exit off >/dev/null
assert_eq "$(count_lines "$(cat "$SNIP")" '^set-hook ')" "0" "snapshot_on_exit 를 끄면 스니펫에서 훅이 빠진다"
"$TTBIN" config unset snapshot_on_exit >/dev/null
assert_eq "$(count_lines "$(cat "$SNIP")" '^set-hook ')" "2" "unset 해도 스니펫이 갱신된다"

# 스니펫과 무관한 키를 바꿔도 깨지지 않는다(재호출이 조용히 실패해도 rc 를 오염시키지 않는다)
assert_rc 0 "$TTBIN" config set accent 100

# ── ⑨ 손으로 넣은 이상한 값은 스니펫으로 새지 않는다 ────────────────────────
# 파서가 값 문자셋을 거르지만, 렌더도 tmux 키 모양을 한 번 더 본다(방어 이중화).
printf 'key_summon=a/b\n' > "$CONF"
out=$("$TTBIN" --tmux-conf 2>/dev/null)
assert_eq "$(count_lines "$out" '^bind a/b')" "0" "키 모양이 아닌 값은 바인딩으로 안 나간다"

tt_test_done
