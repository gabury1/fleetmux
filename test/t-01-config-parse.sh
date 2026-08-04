#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
tt_test_sandbox

CONF="$XDG_CONFIG_HOME/fleetmux/config"
mkdir -p "$(dirname "$CONF")"

# ① 파일이 없으면 전부 기본값
assert_eq "$("$TTBIN" config get rc)"             "on"      "rc 기본값은 on"
assert_eq "$("$TTBIN" config get recent_hours)"   "6"       "recent_hours 기본값은 6"
assert_eq "$("$TTBIN" config get key_summon)"     "F"       "key_summon 기본값은 F"
assert_eq "$("$TTBIN" config get key_summon_fast)" ""       "key_summon_fast 기본값은 빈 값"
assert_eq "$("$TTBIN" config source rc)"          "default" "출처는 default"

# ② 파일 값이 기본값을 이긴다
cat > "$CONF" <<'EOF'
# 주석은 무시된다
rc=off

recent_hours=12
key_summon_fast=C-Left M-b
EOF
assert_eq "$("$TTBIN" config get rc)"              "off"          "파일이 기본값을 이긴다"
assert_eq "$("$TTBIN" config get recent_hours)"    "12"           "숫자 값도 읽는다"
assert_eq "$("$TTBIN" config get key_summon_fast)" "C-Left M-b"   "공백 있는 값(목록)을 읽는다"
assert_eq "$("$TTBIN" config source rc)"           "file"         "출처는 file"

# ③ env 가 파일을 이긴다
assert_eq "$(TT_RC=on "$TTBIN" config get rc)"     "on"   "env 가 파일을 이긴다"
assert_eq "$(TT_RC=on "$TTBIN" config source rc)"  "env"  "출처는 env"

# ④ 깨진 줄과 모르는 키는 무시하고 나머지는 산다
cat > "$CONF" <<'EOF'
rc=off
이건 = 깨진 줄이다
unknown_key=1
rm -rf $HOME
accent=200
EOF
assert_eq "$("$TTBIN" config get rc)"     "off"  "깨진 줄이 있어도 앞 값은 산다"
assert_eq "$("$TTBIN" config get accent)" "200"  "깨진 줄 뒤의 값도 산다"
assert_contains "$("$TTBIN" config get rc 2>&1 >/dev/null)" "무시" "무시했다고 경고한다"
# 그리고 HOME 은 멀쩡해야 한다 — source 했다면 지워졌을 자리
assert_rc 0 test -d "$HOME"

# ⑤ 모르는 키를 물으면 거절한다
assert_rc 1 "$TTBIN" config get nope

tt_test_done
