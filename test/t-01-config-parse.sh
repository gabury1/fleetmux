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

# ⑥ '=' 없는 줄도 경고한다 — 전엔 조용히 씹었다(고침 라운드 1, 지적 2)
cat > "$CONF" <<'EOF'
rc=off
rm -rf $HOME
EOF
_warn=$("$TTBIN" config get rc 2>&1 >/dev/null)
assert_contains "$_warn" "key=value 모양이 아니다" "'=' 없는 줄도 경고한다"
assert_eq "$("$TTBIN" config get rc)" "off" "'=' 없는 줄이 있어도 다른 값은 산다"

# ⑦ 같은 프로세스에서 여러 키를 조회해도 경고는 한 번만 — 전엔 조회한 키 수만큼
#    같은 경고가 반복됐다(고침 라운드 1, 지적 1). 개수를 직접 센다(존재만 보면 재발을 못 잡는다).
#    `config get <key>` 는 키 하나만 받아 서브셸을 한 번만 포크하니 이 시나리오를 재현
#    못 한다(고침 라운드 2 지적) — 실제로 키 개수만큼 서브셸을 포크하는 건 `config`
#    (인자 없는 목록) 다. 85-config-cli.sh 의 list 분기가 TT_CONF_KEYS 를 훑으며
#    `$(tt_conf_get "$k")`/`$(tt_conf_source "$k")` 를 키마다 새 서브셸로 부른다 — 그
#    서브셸이 매번 TT_CONF_LOADED=0 을 새로 물려받으면 파일을 다시 파싱해 경고를 반복한다.
cat > "$CONF" <<'EOF'
rc=off
accent=150
unknown_key=1
EOF
_warn=$("$TTBIN" config 2>&1 >/dev/null)
_count=$(printf '%s\n' "$_warn" | grep -c "모르는 키: unknown_key")
assert_eq "$_count" "1" "config 목록도 키마다 서브셸을 포크하지만 경고는 한 번만"

# ⑧ ★설정 파일이 있는데 **못 읽히면** 기본값으로 간다 — 죽지 않는다.
#    tt_conf_load 가 `-f` 로만 검사하면 존재 검사를 통과한 뒤 `done < "$TT_CONF"` 의
#    리다이렉트가 실패하고, 00-header 의 set -e 가 그걸 물어 **프로세스가 통째로 죽는다**.
#    그 경로에 매달린 것이 크론(매분 --cron)과 @reboot(--boot-restore)이다: 설정 파일 퍼미션
#    하나가 함대 복원과 rc 복구를 이유도 안 남기고 정지시킨다. `-r` 한 글자가 그 전부를 막는다.
if [ "$(id -u)" = 0 ]; then
    printf '  --   root 로 도는 중 — 읽기 권한 검사는 건너뜀(root 는 0000 도 읽는다)\n'
else
    printf 'rc=off\n' > "$CONF"
    chmod 000 "$CONF"
    assert_rc 0 "$TTBIN" config get rc
    assert_eq "$("$TTBIN" config get rc 2>/dev/null)" "on" \
        "★못 읽는 설정 파일은 기본값으로 접는다(파싱해서 얻은 off 가 아니라 default 인 on)"
    assert_eq "$("$TTBIN" config source rc 2>/dev/null)" "default" "출처도 default 라고 정직하게 답한다"
    # 목록·CLI 진입점도 같이 산다 — 여기가 죽으면 설정 화면 전체가 안 열린다
    assert_rc 0 "$TTBIN" config
    chmod 644 "$CONF"
    assert_eq "$("$TTBIN" config get rc)" "off" "권한을 돌려주면 다시 파일 값을 읽는다(가드가 파일을 무시하는 게 아니다)"
    : > "$CONF"
fi

tt_test_done
