#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
tt_test_sandbox

CONF="$XDG_CONFIG_HOME/fleetmux/config"

# ① path 는 설정 파일 경로를 준다 (파일이 아직 없어도)
assert_eq "$("$TTBIN" config path)" "$CONF" "config path 가 경로를 준다"

# ② set 이 파일을 만들고 값을 넣는다
assert_rc 0 "$TTBIN" config set rc off
assert_eq "$("$TTBIN" config get rc)" "off" "set 한 값이 읽힌다"
assert_rc 0 test -f "$CONF"

# ③ 잘못된 값은 거절한다 — 파일도 안 바뀐다
assert_rc 1 "$TTBIN" config set rc maybe
assert_eq "$("$TTBIN" config get rc)" "off" "거절된 set 은 파일을 안 바꾼다"
assert_rc 1 "$TTBIN" config set recent_hours abc
assert_rc 1 "$TTBIN" config set accent 999
assert_rc 1 "$TTBIN" config set nope 1

# ④ 예약키는 재매핑을 거절한다
assert_rc 1 "$TTBIN" config set key_new esc
assert_rc 1 "$TTBIN" config set key_kill enter

# ⑤ 키 충돌을 거절한다 (key_rename 이 이미 ctrl-e)
assert_rc 1 "$TTBIN" config set key_new ctrl-e
assert_contains "$("$TTBIN" config set key_new ctrl-e 2>&1)" "key_rename" "충돌한 상대를 알려준다"

# ⑥ 사람이 쓴 주석과 줄 순서를 보존한다
printf '# 내 주석\nrc=off\naccent=200\n' > "$CONF"
"$TTBIN" config set accent 100 >/dev/null
assert_contains "$(cat "$CONF")" "# 내 주석" "주석이 살아남는다"
assert_eq "$(head -2 "$CONF" | tail -1)" "rc=off" "줄 순서가 유지된다"
assert_eq "$("$TTBIN" config get accent)" "100" "값만 바뀐다"

# ⑦ unset 은 기본값으로 되돌린다
assert_rc 0 "$TTBIN" config unset accent
assert_eq "$("$TTBIN" config get accent)" "73" "unset 하면 기본값"

# ⑧ 목록은 값과 출처를 함께 보여준다
out=$("$TTBIN" config)
assert_contains "$out" "rc" "목록에 rc 가 있다"
assert_contains "$out" "file" "목록이 출처를 보여준다"
assert_contains "$out" "key_summon" "목록에 key_summon 이 있다"

# ⑨ set 의 키 충돌 검사(tt_conf_validate 의 `for other in $TT_CONF_KEYS ...
#    $(tt_conf_get "$other")`)도 키마다 서브셸을 포크한다 — 여기서도 malformed 줄이
#    있으면 경고가 키 개수만큼 반복될 수 있었다. `config` 진입점 맨 위의 bare
#    tt_conf_load 하나가 list 뿐 아니라 이 경로도 함께 지킨다.
cat > "$CONF" <<'EOF'
rc=off
unknown_key=1
EOF
_warn=$("$TTBIN" config set key_new ctrl-t 2>&1 >/dev/null)
_count=$(printf '%s\n' "$_warn" | grep -c "모르는 키: unknown_key")
assert_eq "$_count" "1" "set 의 충돌 검사 루프도 경고는 한 번만"

# ⑩ 손으로 고친 무효값을 실효값처럼 보여주지 않는다 (권고 N4)
# `tt config set` 은 무효값을 거절하지만 README 는 파일 손편집도 정상 경로로 안내한다.
# 그 경로로 들어온 값은 소비자마다 다르게 접힌다 — 표가 그걸 안 밝히면 두 화면이 서로
# 다른 진실을 말한다("설정엔 6h 라 적혀 있는데 왜 6시간으로 안 도나").
cat > "$CONF" <<'EOF'
recent_hours=6h
rc=maybe
key_summon=a/b
EOF
out=$("$TTBIN" config list 2>/dev/null)
assert_contains "$out" "무효값" "무효값에 표시를 붙인다"
assert_contains "$(printf '%s\n' "$out" | grep '^recent_hours ')" "기본값 6 로 돈다" \
    "숫자 키는 기본값으로 접힌다고 말한다"
assert_contains "$(printf '%s\n' "$out" | grep '^rc ')" "꺼짐으로 돈다" \
    "불린 키는 꺼짐으로 접힌다고 말한다 — 기본값(on)으로 돌아가는 게 아니다"
assert_contains "$(printf '%s\n' "$out" | grep '^key_summon ')" "스니펫에서 그 키는 빠진다" \
    "소환키는 스니펫에서 빠진다고 말한다"
# 성한 값에는 아무 표시도 안 붙는다 — 안 그러면 표시가 소음이 된다
assert_eq "$(printf '%s\n' "$out" | grep -c '^snapshot .*무효값' || true)" "0" "멀쩡한 값에는 안 붙인다"
: > "$CONF"
assert_eq "$("$TTBIN" config list 2>/dev/null | grep -c '무효값' || true)" "0" \
    "기본값만 있는 새 설치에는 무효값 표시가 하나도 없다"

tt_test_done
