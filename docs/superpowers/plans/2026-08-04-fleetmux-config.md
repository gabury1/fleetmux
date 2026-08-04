# fleetmux 설정 시스템 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** fmux 의 하드코딩된 취향(rc 자동복구·크론 스냅샷·임계값·색·단축키)을 설정 파일로 열고, `tt config` CLI 와 팝업 안 설정 화면으로 바꿀 수 있게 한다.

**Architecture:** 새 파일 `src/05-config.sh` 가 화이트리스트 파서와 `tt_conf_get` 을 정의하고 스크립트 시작 시 한 번 로드한다(`source` 하지 않는다). 소비 지점(`--cron`·`--snapshot`·`--boot-restore`·`--list`·`--status`·팝업)은 상수 대신 `tt_conf_get` 을 부른다. CLI 는 `src/85-config-cli.sh`, 팝업 설정 화면은 `src/86-config-view.sh` 에 둔다. tmux 쪽(소환키·종료 스냅샷 훅)은 fmux 가 소유하는 스니펫 파일을 생성해 사용자 `.tmux.conf` 를 건드리지 않는다.

**Tech Stack:** bash(3.2 호환), tmux ≥ 3.2, fzf ≥ 0.64, awk/flock. 새 의존성 없음.

## Global Constraints

- **bash 3.2 에서 돌아야 한다** (맥 기본 `/bin/bash`). 연관배열(`declare -A`) 금지, `${var^^}` 금지 — `tr` 로 대문자화한다.
- **GNU 전용 옵션 금지.** `stat -c`·`readlink -f`·`sed -i` 금지. 크기는 `wc -c <파일`, 인플레이스 편집은 tmp+`mv`.
- **`src/*.sh` 를 고치면 반드시 `make` 로 `bin/fmux` 를 재빌드해 같은 커밋에 넣는다.** `make verify` 가 "커밋된 `bin/fmux` == `src/*.sh` 이어붙인 것"을 바이트 비교한다. 어기면 검증이 깨진다.
- **새 파일을 추가하면 `Makefile` 의 `SRC` 목록에 번호 순서대로 넣는다.** 글롭이 아니라 그 목록이 정답이다.
- **셔뱅은 `src/00-header.sh` 에만.** 다른 파일에 넣으면 합친 결과 한가운데 셔뱅이 박힌다.
- 진입점은 `if [ "${1:-}" = "--x" ]; then …; exit 0; fi` 체인이고 **먼저 나오는 분기가 이긴다.** 파일 번호가 곧 우선순위다.
- 설정 파일을 **절대 `source` 하지 않는다.** 훅이 이벤트마다, cron 이 1분마다 읽는 경로다.
- 사용자 `~/.tmux.conf`·crontab 을 **프로그램이 편집하지 않는다.**
- 테스트는 순수 bash. 새 테스트 의존성(bats 등) 도입 금지.
- 값 문자셋: 스펙 초안의 `^[a-z_][a-z0-9_]*=[0-9A-Za-z_./:+-]*$` 는 **공백을 막아 `key_summon_fast="C-Left M-b"` 를 못 받는다.** 이 계획에서는 값 문자셋에 공백을 포함한다(`[0-9A-Za-z_./:+ -]*`). 스펙 문서도 Task 2 에서 함께 고친다.

---

### Task 1: 테스트 하네스

**Files:**
- Create: `test/run.sh`
- Create: `test/lib.sh`
- Modify: `Makefile:49-57` (`check` 타깃에 테스트 실행 추가)

**Interfaces:**
- Produces: `test/lib.sh` 가 제공하는 셸 함수 — `tt_test_sandbox`(임시 HOME·XDG_CONFIG_HOME 을 만들고 `TTBIN` 을 절대경로로 세팅), `assert_eq <실제> <기대> <설명>`, `assert_contains <문자열> <조각> <설명>`, `assert_rc <기대rc> <명령...>`. 이후 모든 태스크의 테스트가 이 셋만 쓴다.

- [ ] **Step 1: 테스트 라이브러리를 쓴다**

`test/lib.sh`:

```bash
# fleetmux 테스트 공용 — 순수 bash. 의존성 없음.
# 각 테스트 파일은 이 파일을 source 하고 tt_test_sandbox 로 시작한다.

TT_FAIL=0
TT_RUN=0

# 격리된 HOME/XDG 를 만든다. 진짜 ~/.config, ~/.cache 를 절대 건드리지 않기 위함.
tt_test_sandbox() {
    TTROOT=$(mktemp -d "${TMPDIR:-/tmp}/fmux-test.XXXXXX") || exit 1
    export HOME="$TTROOT/home"
    export XDG_CONFIG_HOME="$TTROOT/home/.config"
    mkdir -p "$HOME" "$XDG_CONFIG_HOME"
    # 테스트가 진짜 tmux 서버에 붙지 않도록 소켓 이름을 격리한다
    export TMUX_TMPDIR="$TTROOT"
    trap 'rm -rf "$TTROOT"' EXIT
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
```

- [ ] **Step 2: 러너를 쓴다**

`test/run.sh`:

```bash
#!/usr/bin/env bash
# 모든 test/t-*.sh 를 각각 별도 프로세스로 돌린다.
# 한 파일이 죽어도 나머지는 돈다 — 실패를 한 번에 다 보기 위함.
set -u
cd "$(dirname "$0")/.." || exit 1
TTBIN="$PWD/bin/fmux"
[ -x "$TTBIN" ] || { echo "bin/fmux 가 없다 — 먼저 make 를 돌려라"; exit 1; }
export TTBIN

fail=0
for t in test/t-*.sh; do
    [ -f "$t" ] || continue
    printf '%s\n' "$t"
    bash "$t" || fail=1
done
[ "$fail" = 0 ] && echo "테스트 전부 통과" || echo "테스트 실패 있음"
exit "$fail"
```

- [ ] **Step 3: 자기 자신을 재는 테스트를 쓴다**

`test/t-00-harness.sh`:

```bash
#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
tt_test_sandbox

assert_eq "$(printf 'a')" "a" "assert_eq 가 같은 값을 통과시킨다"
assert_contains "hello world" "lo w" "assert_contains 가 조각을 찾는다"
assert_rc 0 true
assert_rc 1 false
# 샌드박스가 진짜 HOME 이 아니어야 한다
case "$HOME" in */fmux-test.*) printf '  ok   HOME 이 격리됐다\n' ;;
    *) printf '  FAIL HOME 이 격리되지 않았다: %s\n' "$HOME"; TT_FAIL=$((TT_FAIL+1)) ;;
esac

tt_test_done
```

- [ ] **Step 4: 실행해서 통과를 확인한다**

```bash
chmod +x test/run.sh
make && ./test/run.sh
```

기대: `test/t-00-harness.sh` 가 전부 `ok`, 마지막에 `테스트 전부 통과`.

- [ ] **Step 5: `make check` 에 물린다**

`Makefile` 의 `check` 타깃을 이렇게 바꾼다:

```make
check: $(OUT)
	bash -n $(OUT)
	@if command -v shellcheck > /dev/null 2>&1; then \
		shellcheck -x $(OUT) && echo "shellcheck: clean"; \
	else \
		echo "shellcheck not installed — skipped"; \
	fi
	@./test/run.sh
```

- [ ] **Step 6: 커밋**

```bash
make check
git add test/lib.sh test/run.sh test/t-00-harness.sh Makefile
git commit -m "test: 순수 bash 테스트 하네스 추가"
```

---

### Task 2: 설정 파서 (`src/05-config.sh`)

**Files:**
- Create: `src/05-config.sh`
- Modify: `Makefile:29-39` (SRC 목록에 `src/05-config.sh` 를 `00-header.sh` 다음에 삽입, 파일 설명 주석에도 한 줄 추가)
- Modify: `docs/superpowers/specs/2026-08-04-fleetmux-config-design.md` (값 문자셋에 공백 허용으로 정정)
- Test: `test/t-01-config-parse.sh`

**Interfaces:**
- Consumes: `STATE`(00-header.sh), `test/lib.sh`(Task 1)
- Produces:
  - `TT_CONF` — 설정 파일 절대경로 문자열
  - `TT_CONF_KEYS` — 공백으로 나뉜 알려진 키 목록(출력 순서와 같다)
  - `tt_conf_default <key>` — 기본값을 stdout 에. 모르는 키면 rc 1
  - `tt_conf_get <key>` — 유효값(env > 파일 > 기본)을 stdout 에. 모르는 키면 rc 1
  - `tt_conf_source <key>` — `env` | `file` | `default` 중 하나를 stdout 에
  - `tt_conf_on <key>` — 불린 키가 켜져 있으면 rc 0, 아니면 rc 1

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`test/t-01-config-parse.sh`:

```bash
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
```

- [ ] **Step 2: 실패를 확인한다**

```bash
./test/run.sh
```

기대: `t-01-config-parse.sh` 가 전부 FAIL (`config` 서브커맨드가 아직 없어 fmux 가 팝업을 띄우려다 실패하거나 빈 출력).

- [ ] **Step 3: 파서를 쓴다**

`src/05-config.sh`:

```bash
# ── 설정 ────────────────────────────────────────────────────────────────────
# 우선순위: 환경변수 > 설정 파일 > 코드 기본값.
#
# 이 파일을 절대 `source` 하지 않는 이유: 훅이 이벤트마다, cron 이 1분마다 읽는 경로다.
# source 라면 사용자가 오타 한 줄만 넣어도 그 순간부터 함대 관제 전체가 조용히 죽는다.
# 그래서 화이트리스트 파서로만 읽는다 — 아는 키의, 아는 모양의 줄만 통과시킨다.
TT_CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/fleetmux"
TT_CONF="${TT_CONF_FILE:-$TT_CONF_DIR/config}"

# 알려진 키. 이 순서가 곧 `tt config` 목록 출력 순서다.
TT_CONF_KEYS='rc snapshot snapshot_on_exit boot_restore recent_hours unseen_minutes accent log_max key_new key_rename key_kill key_reload key_detach key_broadcast key_help key_settings key_summon key_summon_fast'

# 기본값. 모르는 키면 rc 1 — "알려진 키인가" 판정도 이 함수가 겸한다.
tt_conf_default() {
    case "${1:-}" in
        rc|snapshot|snapshot_on_exit|boot_restore) printf 'on' ;;
        recent_hours)    printf '6' ;;
        unseen_minutes)  printf '10' ;;
        accent)          printf '73' ;;
        log_max)         printf '1048576' ;;
        key_new)         printf 'ctrl-n' ;;
        key_rename)      printf 'ctrl-e' ;;
        key_kill)        printf 'ctrl-x' ;;
        key_reload)      printf 'ctrl-r' ;;
        key_detach)      printf 'ctrl-d' ;;
        key_broadcast)   printf 'ctrl-b' ;;
        key_help)        printf '?' ;;
        key_settings)    printf 'ctrl-o' ;;
        key_summon)      printf 'F' ;;
        key_summon_fast) printf '' ;;
        *) return 1 ;;
    esac
    return 0
}

# 키 → 환경변수 이름. bash 3.2 에는 ${var^^} 가 없다 → tr 로 올린다.
tt_conf_envname() {
    printf 'TT_%s' "$(printf '%s' "${1:-}" | tr '[:lower:]' '[:upper:]')"
}

# 설정 파일에서 한 키를 읽는다. 없으면 rc 1.
#   통과 조건: 키가 알려진 목록에 있고, 줄 모양이 `key=value` 이며,
#   값이 [0-9A-Za-z_./:+ -] 로만 이뤄진다(공백 허용 — key_summon_fast 가 목록이다).
tt_conf_file_get() {
    local want="${1:-}" line k v found=1 out=''
    [ -f "$TT_CONF" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ''|'#'*|' '*'#'*) continue ;; esac
        case "$line" in *=*) ;; *) continue ;; esac
        k=${line%%=*}
        v=${line#*=}
        # 키 모양 검사
        case "$k" in
            ''|*[!a-z0-9_]*) printf 'fleetmux: %s 의 줄 무시 — 키 모양이 아니다: %s\n' "$TT_CONF" "$line" >&2; continue ;;
        esac
        # 알려진 키인가
        if ! tt_conf_default "$k" >/dev/null 2>&1; then
            printf 'fleetmux: %s 의 줄 무시 — 모르는 키: %s\n' "$TT_CONF" "$k" >&2
            continue
        fi
        # 값 문자셋 검사
        case "$v" in
            *[!0-9A-Za-z_./:+\ -]*) printf 'fleetmux: %s 의 줄 무시 — 값에 허용 안 된 글자: %s\n' "$TT_CONF" "$line" >&2; continue ;;
        esac
        if [ "$k" = "$want" ]; then out=$v; found=0; fi   # 마지막에 쓴 줄이 이긴다
    done < "$TT_CONF"
    [ "$found" = 0 ] || return 1
    printf '%s' "$out"
    return 0
}

# 유효값. 모르는 키면 rc 1.
tt_conf_get() {
    local k="${1:-}" envn v
    tt_conf_default "$k" >/dev/null 2>&1 || return 1
    envn=$(tt_conf_envname "$k")
    eval "v=\${$envn+set}"
    if [ "${v:-}" = set ]; then eval "printf '%s' \"\$$envn\""; return 0; fi
    if v=$(tt_conf_file_get "$k" 2>/dev/null); then printf '%s' "$v"; return 0; fi
    tt_conf_default "$k"
}

# 값이 어디서 왔나 — env | file | default
tt_conf_source() {
    local k="${1:-}" envn v
    tt_conf_default "$k" >/dev/null 2>&1 || return 1
    envn=$(tt_conf_envname "$k")
    eval "v=\${$envn+set}"
    if [ "${v:-}" = set ]; then printf 'env'; return 0; fi
    if tt_conf_file_get "$k" >/dev/null 2>&1; then printf 'file'; return 0; fi
    printf 'default'
}

# 불린 키가 켜져 있나. on/1/true/yes 를 켜짐으로 본다(대소문자 무시).
tt_conf_on() {
    local v
    v=$(tt_conf_get "${1:-}") || return 1
    case "$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')" in
        on|1|true|yes) return 0 ;;
        *) return 1 ;;
    esac
}
```

- [ ] **Step 4: `config get` / `config source` 최소 CLI 를 붙인다**

Task 3 에서 나머지(`list`·`set`·`unset`·`path`)를 붙인다. 지금은 테스트가 요구하는 둘만.
`src/05-config.sh` 맨 아래에 이어 붙인다:

```bash
# 설정 조회 진입점(최소). 나머지 하위명령은 85-config-cli.sh 가 맡는다.
if [ "${1:-}" = "config" ] && { [ "${2:-}" = "get" ] || [ "${2:-}" = "source" ]; }; then
    [ -n "${3:-}" ] || { echo "usage: tt config ${2} <key>" >&2; exit 1; }
    if [ "$2" = get ]; then tt_conf_get "$3" || { echo "모르는 키: $3" >&2; exit 1; }
    else                    tt_conf_source "$3" || { echo "모르는 키: $3" >&2; exit 1; }
    fi
    echo
    exit 0
fi
```

- [ ] **Step 5: Makefile SRC 에 넣는다**

`SRC` 목록에서 `src/00-header.sh` 바로 다음 줄에 삽입:

```make
SRC = src/00-header.sh \
      src/05-config.sh \
      src/10-util.sh \
```

파일 설명 주석에도 한 줄 추가:

```
#   05-config.sh   설정 — 화이트리스트 파서·env>파일>기본 우선순위·tt_conf_get/on/source
```

- [ ] **Step 6: 테스트 통과를 확인한다**

```bash
make && ./test/run.sh
```

기대: `t-01-config-parse.sh` 전부 `ok`.

- [ ] **Step 7: 스펙 문서의 값 문자셋을 정정한다**

`docs/superpowers/specs/2026-08-04-fleetmux-config-design.md` 에서

```
  줄이 `^[a-z_][a-z0-9_]*=[0-9A-Za-z_./:+-]*$` 를 만족하고
```

를 다음으로 바꾼다:

```
  줄이 `^[a-z_][a-z0-9_]*=[0-9A-Za-z_./:+ -]*$` 를 만족하고 (값에 공백 허용 —
  `key_summon_fast` 는 키 목록이다)
```

- [ ] **Step 8: 커밋**

```bash
make check
git add src/05-config.sh Makefile bin/fmux test/t-01-config-parse.sh docs/superpowers/specs/2026-08-04-fleetmux-config-design.md
git commit -m "feat: 설정 파서 — 화이트리스트 방식, env>파일>기본"
```

---

### Task 3: `tt config` CLI (list / set / unset / path)

**Files:**
- Create: `src/85-config-cli.sh`
- Modify: `Makefile` (SRC 에 `src/85-config-cli.sh` 를 `src/80-view.sh` 다음에 삽입 + 주석 한 줄)
- Modify: `src/05-config.sh` (Step 4 에서 넣은 최소 CLI 블록을 지운다 — 85 가 전부 맡는다)
- Test: `test/t-02-config-cli.sh`

**Interfaces:**
- Consumes: `tt_conf_get`·`tt_conf_source`·`tt_conf_default`·`TT_CONF_KEYS`·`TT_CONF`(Task 2)
- Produces:
  - `tt_conf_validate <key> <value>` — 유효하면 rc 0, 아니면 rc 1 + 사유를 stderr 에
  - `tt_conf_set <key> <value>` — 원자적 쓰기. 주석·줄 순서 보존
  - `tt_conf_unset <key>` — 해당 줄 삭제
  - CLI: `tt config` / `tt config get <k>` / `tt config source <k>` / `tt config set <k> <v>` / `tt config unset <k>` / `tt config path`

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`test/t-02-config-cli.sh`:

```bash
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

tt_test_done
```

- [ ] **Step 2: 실패를 확인한다**

```bash
./test/run.sh
```

기대: `t-02-config-cli.sh` 대부분 FAIL.

- [ ] **Step 3: 검증·쓰기·CLI 를 쓴다**

`src/85-config-cli.sh`:

```bash
# ── 설정 CLI ────────────────────────────────────────────────────────────────
# 재매핑을 막는 키. 잘못 밟아도 나갈 수 있는 문 하나는 늘 열어둔다.
TT_CONF_RESERVED='esc enter left'

# 팝업 안에서 fzf 가 받는 키 이름인가(부분집합 화이트리스트).
# 여기 없는 이름을 넘기면 fzf 가 기동 자체를 거부해 관제탑이 안 뜬다 — 그래서 미리 막는다.
tt_conf_is_fzf_key() {
    case "${1:-}" in
        ctrl-[a-z]|alt-[a-z0-9]) return 0 ;;
        f[1-9]|f1[0-2]) return 0 ;;
        tab|btab|home|end|pgup|pgdn|del|ins|up|down|left|right|enter|esc|space) return 0 ;;
        ?) return 0 ;;      # '?' 같은 출력 가능한 한 글자
        *) return 1 ;;
    esac
}

# tmux 가 받는 키 이름인가. key_summon(한 개)·key_summon_fast(공백 목록)에 쓴다.
tt_conf_is_tmux_key() {
    case "${1:-}" in
        ''|*[!A-Za-z0-9C\-M\ ]*) return 1 ;;
    esac
    return 0
}

# 유효성 검사. rc 1 이면 stderr 에 사유가 찍힌다.
tt_conf_validate() {
    local k="${1:-}" v="${2:-}" other ov
    tt_conf_default "$k" >/dev/null 2>&1 || { echo "모르는 키: $k" >&2; return 1; }
    case "$k" in
        rc|snapshot|snapshot_on_exit|boot_restore)
            case "$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')" in
                on|off|1|0|true|false|yes|no) ;;
                *) echo "$k 는 on|off 여야 한다 (받은 값: $v)" >&2; return 1 ;;
            esac ;;
        recent_hours|unseen_minutes|log_max)
            case "$v" in ''|*[!0-9]*) echo "$k 는 양의 정수여야 한다 (받은 값: $v)" >&2; return 1 ;; esac
            [ "$v" -gt 0 ] || { echo "$k 는 0보다 커야 한다" >&2; return 1; } ;;
        accent)
            case "$v" in ''|*[!0-9]*) echo "accent 는 0~255 정수여야 한다 (받은 값: $v)" >&2; return 1 ;; esac
            [ "$v" -le 255 ] || { echo "accent 는 0~255 여야 한다 (받은 값: $v)" >&2; return 1; } ;;
        key_summon)
            tt_conf_is_tmux_key "$v" || { echo "key_summon 은 tmux 키 이름이어야 한다 (예: F, C-Left)" >&2; return 1; } ;;
        key_summon_fast)
            for ov in $v; do
                tt_conf_is_tmux_key "$ov" || { echo "key_summon_fast 의 '$ov' 는 tmux 키 이름이 아니다" >&2; return 1; }
            done ;;
        key_*)
            for ov in $TT_CONF_RESERVED; do
                [ "$v" = "$ov" ] && { echo "$v 는 예약키라 재매핑할 수 없다 (닫기·진입은 늘 열려 있어야 한다)" >&2; return 1; }
            done
            tt_conf_is_fzf_key "$v" || { echo "fzf 가 아는 키 이름이 아니다: $v (예: ctrl-n, alt-x, f2)" >&2; return 1; }
            # 충돌 — 같은 키를 이미 쓰는 다른 액션이 있나
            for other in $TT_CONF_KEYS; do
                case "$other" in key_summon|key_summon_fast|"$k") continue ;; key_*) ;; *) continue ;; esac
                if [ "$(tt_conf_get "$other")" = "$v" ]; then
                    echo "$v 는 이미 $other 가 쓰고 있다" >&2; return 1
                fi
            done ;;
    esac
    return 0
}

# 원자적 쓰기. 있는 줄은 값만 교체하고, 없으면 끝에 붙인다(주석·순서 보존).
tt_conf_write() {
    local k="${1:-}" v="${2:-}" mode="${3:-set}" tmp line seen=0
    mkdir -p "${TT_CONF%/*}" 2>/dev/null || true
    tmp="$TT_CONF.tmp.$$"
    : > "$tmp" || { echo "설정 파일을 쓸 수 없다: $TT_CONF" >&2; return 1; }
    if [ -f "$TT_CONF" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in
                "$k"=*)
                    seen=1
                    [ "$mode" = set ] && printf '%s=%s\n' "$k" "$v" >> "$tmp"
                    ;;
                *) printf '%s\n' "$line" >> "$tmp" ;;
            esac
        done < "$TT_CONF"
    fi
    if [ "$mode" = set ] && [ "$seen" = 0 ]; then printf '%s=%s\n' "$k" "$v" >> "$tmp"; fi
    mv -f "$tmp" "$TT_CONF" || { rm -f "$tmp"; return 1; }
    return 0
}

if [ "${1:-}" = "config" ]; then
    case "${2:-}" in
        ''|list)
            printf '%-18s %-14s %s\n' 'KEY' 'VALUE' 'SOURCE'
            for k in $TT_CONF_KEYS; do
                printf '%-18s %-14s %s\n' "$k" "$(tt_conf_get "$k")" "$(tt_conf_source "$k")"
            done
            exit 0 ;;
        get|source)
            [ -n "${3:-}" ] || { echo "usage: tt config $2 <key>" >&2; exit 1; }
            if [ "$2" = get ]; then tt_conf_get "$3" || { echo "모르는 키: $3" >&2; exit 1; }
            else                    tt_conf_source "$3" || { echo "모르는 키: $3" >&2; exit 1; }
            fi
            echo
            exit 0 ;;
        set)
            [ -n "${3:-}" ] || { echo "usage: tt config set <key> <value>" >&2; exit 1; }
            shift 2; k=$1; shift
            v="$*"
            tt_conf_validate "$k" "$v" || exit 1
            tt_conf_write "$k" "$v" set || exit 1
            printf '%s=%s\n' "$k" "$v"
            exit 0 ;;
        unset)
            [ -n "${3:-}" ] || { echo "usage: tt config unset <key>" >&2; exit 1; }
            tt_conf_default "$3" >/dev/null 2>&1 || { echo "모르는 키: $3" >&2; exit 1; }
            tt_conf_write "$3" '' unset || exit 1
            printf '%s → 기본값 %s\n' "$3" "$(tt_conf_default "$3")"
            exit 0 ;;
        path)
            printf '%s\n' "$TT_CONF"; exit 0 ;;
        *)
            echo "usage: tt config [list|get|source|set|unset|path]" >&2; exit 1 ;;
    esac
fi
```

- [ ] **Step 4: Task 2 에서 넣은 최소 CLI 를 지운다**

`src/05-config.sh` 끝의 `if [ "${1:-}" = "config" ] && { … }` 블록 전체를 삭제한다.
같은 하위명령을 두 곳이 처리하면 앞 파일이 이겨서 85 의 코드가 죽는다.

- [ ] **Step 5: Makefile SRC 에 넣는다**

```make
      src/80-view.sh \
      src/85-config-cli.sh \
      src/90-main.sh
```

주석에도 추가:

```
#   85-config-cli.sh 설정 CLI — 검증·원자적 쓰기·tt config 하위명령
```

- [ ] **Step 6: 테스트 통과를 확인한다**

```bash
make && ./test/run.sh
```

기대: `t-01`·`t-02` 전부 `ok`.

- [ ] **Step 7: 커밋**

```bash
make check
git add src/05-config.sh src/85-config-cli.sh Makefile bin/fmux test/t-02-config-cli.sh
git commit -m "feat: tt config CLI — 검증·충돌 감지·원자적 쓰기"
```

---

### Task 4: 기능 스위치 배선 (rc / snapshot / boot_restore)

**Files:**
- Modify: `src/60-rc.sh:75` (`--cron` 진입점 안에서 rc 단계 앞에 조기 return)
- Modify: `src/60-rc.sh:147` (`--rc` 진입점 맨 앞)
- Modify: `src/70-fleet.sh:25` (`--snapshot` 진입점 맨 앞)
- Modify: `src/70-fleet.sh:327` (`--boot-restore` 진입점 맨 앞)
- Test: `test/t-03-switches.sh`

**Interfaces:**
- Consumes: `tt_conf_on`(Task 2)
- Produces: 없음(동작 변경만)

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`test/t-03-switches.sh`:

```bash
#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
tt_test_sandbox

CONF="$XDG_CONFIG_HOME/fleetmux/config"
mkdir -p "$(dirname "$CONF")"

# tmux 가 없거나 서버가 없어도 스위치가 꺼져 있으면 조용히 성공해야 한다.
printf 'rc=off\nsnapshot=off\nboot_restore=off\n' > "$CONF"

assert_rc 0 "$TTBIN" --cron
assert_rc 0 "$TTBIN" --rc
assert_rc 0 "$TTBIN" --boot-restore --dry

out=$("$TTBIN" --snapshot 2>&1) || true
assert_contains "$out" "snapshot=off" "스냅샷이 꺼져 있으면 그렇게 말한다"

# 껐을 때 매니페스트를 만들지 않는다
assert_rc 1 test -f "$HOME/.cache/tt/manifest"

tt_test_done
```

- [ ] **Step 2: 실패를 확인한다**

```bash
./test/run.sh
```

기대: `t-03` 이 FAIL (지금은 스위치가 없어 tmux 를 부르려다 rc≠0 이 되거나 매니페스트를 만든다).

- [ ] **Step 3: `--cron` 과 `--rc` 에 스위치를 단다**

`--cron` 은 이미 두 가지 일을 한다: rc 복구 라운드를 돌고, 끝에서 `--snapshot` 을 부른다
(`src/60-rc.sh:142` — `[ -n "$only" ] || "$SELF" --snapshot >/dev/null 2>&1 || true`).
**둘을 따로 꺼야 하므로 손대는 자리도 둘이다.**

먼저 `if [ "${1:-}" = "--cron" ] || [ "${1:-}" = "--rc-check" ]; then` (75행) 바로 다음 줄에
rc 스위치를 넣는다. 단, 여기서 `exit 0` 하면 끝의 스냅샷까지 같이 죽으므로 **건너뛸 뿐 나가지 않는다**:

```bash
    tt_rc_enabled=1
    tt_conf_on rc || tt_rc_enabled=0     # rc=off 여도 아래 스냅샷은 살아야 한다
```

그리고 rc 라운드를 도는 `while read -r sid name; do` 루프(84행) 앞에 한 줄:

```bash
    if [ "$tt_rc_enabled" = 1 ]; then
```

루프가 끝나는 자리(142행의 `--snapshot` 호출 **앞**)에서 닫는다:

```bash
    fi
    tt_conf_on snapshot && { [ -n "$only" ] || "$SELF" --snapshot >/dev/null 2>&1 || true; }
```

> 들여쓰기만 바꾸는 대신 `if` 로 감싸는 이유: `exit 0` 으로 빠지면 크론 한 틱에서 스냅샷이 통째로
> 사라진다. `rc` 와 `snapshot` 은 서로 다른 스위치이므로 한쪽이 꺼져도 다른 쪽은 돌아야 한다.

`src/60-rc.sh` 의 `if [ "${1:-}" = "--rc" ]; then` (147행) 바로 다음 줄에 삽입:

```bash
    tt_conf_on rc || { echo "rc=off — 자동복구가 꺼져 있다 (tt config set rc on)"; exit 0; }
```

- [ ] **Step 4: `--snapshot` 과 `--boot-restore` 에 스위치를 단다**

`src/70-fleet.sh` 의 `if [ "${1:-}" = "--snapshot" ]; then` 바로 다음 줄:

```bash
    tt_conf_on snapshot || { echo "snapshot=off — 기록하지 않는다 (tt config set snapshot on)"; exit 0; }
```

`src/70-fleet.sh` 의 `if [ "${1:-}" = "--boot-restore" ]; then` 바로 다음 줄:

```bash
    tt_conf_on boot_restore || { echo "boot_restore=off — 부팅 복원을 건너뛴다"; exit 0; }
```

- [ ] **Step 5: 테스트 통과를 확인한다**

```bash
make && ./test/run.sh
```

기대: `t-03` 전부 `ok`.

- [ ] **Step 6: 켜져 있을 때 동작이 그대로인지 손으로 확인한다**

```bash
tt config set snapshot on
tt --snapshot
tt config              # snapshot 이 on/file 로 보이는지
```

기대: `snapshot: N sessions → …` 가 예전처럼 찍힌다.

- [ ] **Step 7: 커밋**

```bash
make check
git add src/60-rc.sh src/70-fleet.sh bin/fmux test/t-03-switches.sh
git commit -m "feat: rc·snapshot·boot_restore 를 설정으로 끌 수 있게"
```

---

### Task 5: 임계값·색 배선

**Files:**
- Modify: `src/80-view.sh:208` (`21600` → `recent_hours`)
- Modify: `src/50-hook.sh:168` (`600` → `unseen_minutes`)
- Modify: `src/80-view.sh:166`, `src/90-main.sh:169` (`38;5;73` → `accent`)
- Modify: `src/10-util.sh:21` (`TT_LOG_MAX` 을 설정 경유로)
- Test: `test/t-04-tunables.sh`

**Interfaces:**
- Consumes: `tt_conf_get`(Task 2)
- Produces: 없음(동작 변경만)

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`test/t-04-tunables.sh`:

```bash
#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
tt_test_sandbox

CONF="$XDG_CONFIG_HOME/fleetmux/config"
mkdir -p "$(dirname "$CONF")"

# accent 를 바꾸면 --help 출력의 색 코드가 따라 바뀐다 (tmux 없이도 볼 수 있는 표면)
printf 'accent=200\n' > "$CONF"
assert_contains "$("$TTBIN" --help 2>&1)" $'\033[38;5;200m' "accent 가 --help 색에 반영된다"

printf 'accent=73\n' > "$CONF"
assert_contains "$("$TTBIN" --help 2>&1)" $'\033[38;5;73m' "기본 accent 도 그대로 동작한다"

# log_max 는 설정으로 읽혀야 한다
printf 'log_max=4096\n' > "$CONF"
assert_eq "$("$TTBIN" config get log_max)" "4096" "log_max 를 설정에서 읽는다"
# 하위호환 — 환경변수가 여전히 이긴다
assert_eq "$(TT_LOG_MAX=999 "$TTBIN" config get log_max)" "999" "TT_LOG_MAX 환경변수가 이긴다"

tt_test_done
```

- [ ] **Step 2: 실패를 확인한다**

```bash
./test/run.sh
```

기대: accent 관련 두 줄이 FAIL(색이 73 으로 고정돼 있다).

- [ ] **Step 3: 색을 설정 경유로 바꾼다**

`src/90-main.sh:169` 를 다음으로 바꾼다:

```bash
    TT_ACCENT_N=$(tt_conf_get accent)
    T=$'\033[38;5;'"$TT_ACCENT_N"'m'; D=$'\033[2m'; R=$'\033[0m'; B=$'\033[1m'
```

`src/80-view.sh:166` 의 `printf` 에서 `38;5;73` 을 변수로 바꾼다. 같은 파일 `--list` 진입점 시작 부분에 한 번만 읽어둔다:

```bash
    acc=$(tt_conf_get accent)
```

그리고 해당 printf 를:

```bash
                printf '%s\t\033[38;5;%sm%s\033[0m \033[36m%s\033[0m\n' "$name" "$acc" "$name" "$attached"
```

- [ ] **Step 4: 임계값을 설정 경유로 바꾼다**

`src/80-view.sh:208` 부근, `21600` 을 쓰는 비교를 이렇게 바꾼다(같은 진입점 앞쪽에서 한 번 계산):

```bash
    recent_s=$(( $(tt_conf_get recent_hours) * 3600 ))
```

```bash
            if [ $(( now - ts )) -lt "$recent_s" ]; then
```

`src/50-hook.sh:168` 의 `-le 600` 을 이렇게 바꾼다(`--status` 진입점 앞쪽에서 한 번 계산):

```bash
    unseen_s=$(( $(tt_conf_get unseen_minutes) * 60 ))
```

```bash
            [ $(( now - ts )) -le "$unseen_s" ] && out="$out ✓$name"   # 상태바엔 unseen_minutes 만큼만
```

- [ ] **Step 5: `TT_LOG_MAX` 을 설정 경유로 바꾼다**

`src/10-util.sh:21` 을 다음으로 바꾼다(환경변수 우선순위는 `tt_conf_get` 이 이미 지킨다):

```bash
TT_LOG_MAX=$(tt_conf_get log_max)
```

`TT_LOG_KEEP` 은 설정 키가 아니므로 그대로 둔다.

> 주의: `10-util.sh` 는 `05-config.sh` 다음에 이어붙는다(Task 2 에서 SRC 순서를 그렇게 넣었다).
> 순서를 지키지 않으면 `tt_conf_get: command not found` 로 죽는다. `make verify` 전에 `bash -n` 으로 걸러지지 않으니 반드시 실행해서 확인할 것.

- [ ] **Step 6: 테스트와 실물 확인**

```bash
make && ./test/run.sh
tt config set accent 200 && tt --list | head -3   # 색이 바뀌는지 눈으로
tt config unset accent
```

- [ ] **Step 7: 커밋**

```bash
make check
git add src/10-util.sh src/50-hook.sh src/80-view.sh src/90-main.sh bin/fmux test/t-04-tunables.sh
git commit -m "feat: 임계값·강조색을 설정으로 튜닝 가능하게"
```

---

### Task 6: tmux 스니펫 생성 (`tt --tmux-conf`) — 소환키와 종료 스냅샷

**Files:**
- Create: `src/87-tmux-conf.sh`
- Modify: `Makefile` (SRC 에 `src/87-tmux-conf.sh` 를 `85-config-cli.sh` 다음에 삽입 + 주석)
- Modify: `src/85-config-cli.sh` (`set`/`unset` 성공 후 스니펫 재생성 훅 호출)
- Test: `test/t-05-tmux-conf.sh`

**Interfaces:**
- Consumes: `tt_conf_get`·`tt_conf_on`(Task 2), `SELFQ`(00-header.sh)
- Produces:
  - `TT_TMUX_CONF` — 스니펫 파일 절대경로(`$TT_CONF_DIR/tmux.conf`)
  - `tt_tmux_conf_render` — 스니펫 내용을 stdout 에
  - `tt_tmux_conf_write` — 스니펫을 원자적으로 쓴다. tmux 안이면 `source-file` 로 즉시 반영
  - CLI: `tt --tmux-conf` (stdout 에 렌더) / `tt --tmux-conf --write` (파일로 쓰기)

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`test/t-05-tmux-conf.sh`:

```bash
#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
tt_test_sandbox

CONF="$XDG_CONFIG_HOME/fleetmux/config"
SNIP="$XDG_CONFIG_HOME/fleetmux/tmux.conf"
mkdir -p "$(dirname "$CONF")"

# ① 기본값 — prefix 키만 걸리고 무prefix 는 없다
out=$("$TTBIN" --tmux-conf)
assert_contains "$out" "bind F " "기본 소환키 F 가 prefix 바인딩으로 나온다"
case "$out" in *"bind -n"*) printf '  FAIL 기본값에 무prefix 바인딩이 있다\n'; TT_FAIL=$((TT_FAIL+1)) ;;
    *) printf '  ok   기본값에는 무prefix 바인딩이 없다\n' ;; esac

# ② 종료 스냅샷 훅이 들어간다
assert_contains "$out" "client-detached" "client-detached 훅이 들어간다"
assert_contains "$out" "session-closed"  "session-closed 훅이 들어간다"
assert_contains "$out" "run-shell -b"    "client-detached 는 백그라운드"

# ③ fast 목록을 넣으면 무prefix 바인딩이 항목마다 생긴다
printf 'key_summon_fast=C-Left M-b\n' > "$CONF"
out=$("$TTBIN" --tmux-conf)
assert_contains "$out" "bind -n C-Left" "C-Left 가 무prefix 로 걸린다"
assert_contains "$out" "bind -n M-b"    "M-b 가 무prefix 로 걸린다"
assert_contains "$out" "unbind -n"      "지운 키를 위해 unbind 도 낸다"

# ④ snapshot_on_exit=off 면 훅 두 줄이 빠진다
printf 'snapshot_on_exit=off\n' > "$CONF"
out=$("$TTBIN" --tmux-conf)
case "$out" in *client-detached*) printf '  FAIL off 인데 훅이 남아 있다\n'; TT_FAIL=$((TT_FAIL+1)) ;;
    *) printf '  ok   snapshot_on_exit=off 면 훅이 빠진다\n' ;; esac

# ⑤ --write 가 파일을 만든다
printf 'key_summon=T\n' > "$CONF"
assert_rc 0 "$TTBIN" --tmux-conf --write
assert_rc 0 test -f "$SNIP"
assert_contains "$(cat "$SNIP")" "bind T " "쓰인 파일에 바뀐 키가 들어 있다"

tt_test_done
```

- [ ] **Step 2: 실패를 확인한다**

```bash
./test/run.sh
```

기대: `t-05` 전부 FAIL (`--tmux-conf` 가 없다).

- [ ] **Step 3: 스니펫 생성기를 쓴다**

`src/87-tmux-conf.sh`:

```bash
# ── tmux 스니펫 ─────────────────────────────────────────────────────────────
# fmux 는 사용자의 ~/.tmux.conf 를 편집하지 않는다. 자기 파일 하나를 소유하고,
# 사용자 설정에는 `source-file` 한 줄만 빌린다. 지우면 흔적이 사라진다 — shim 과 같은 철학.
TT_TMUX_CONF="$TT_CONF_DIR/tmux.conf"

# 이전 판이 걸어둔 무prefix 바인딩을 걷어내기 위한 후보 목록.
# tmux 는 "설정에 없으면 알아서 사라지는" 모델이 아니라, 한 번 bind 하면 서버가 죽을 때까지 남는다.
TT_TMUX_UNBIND_CANDIDATES='C-Left M-Left M-b C-Right M-Right'

tt_tmux_conf_render() {
    local popup="display-popup -E -w 85% -h 75% -b rounded -T ' tt ' $SELFQ --from '#S'"
    local k fast

    printf '# fleetmux 가 생성한 파일 — 손으로 고치지 마라. tt config set … 로 바뀐다.\n'
    printf '# 사용자 설정에는 이 한 줄만 넣는다:  source-file %s\n\n' "$TT_TMUX_CONF"

    # 이전 판의 무prefix 바인딩을 먼저 걷는다(없으면 조용히 실패하므로 그대로 둔다)
    for k in $TT_TMUX_UNBIND_CANDIDATES; do
        printf 'unbind -n %s\n' "$k"
    done
    printf '\n'

    k=$(tt_conf_get key_summon)
    [ -n "$k" ] && printf 'bind %s %s\n' "$k" "$popup"

    fast=$(tt_conf_get key_summon_fast)
    for k in $fast; do
        printf 'bind -n %s %s\n' "$k" "$popup"
    done

    if tt_conf_on snapshot_on_exit; then
        printf '\n# 떠날 때 한 번 더 기록한다.\n'
        # client-detached 는 -b — 떠나는 사람을 스냅샷이 붙잡으면 안 된다.
        printf "set-hook -g client-detached 'run-shell -b \"%s --snapshot >/dev/null 2>&1\"'\n" "$SELF"
        # session-closed 는 동기 — 서버가 내려가는 중이라 백그라운드는 실행 전에 사라질 수 있다.
        printf "set-hook -g session-closed 'run-shell \"%s --snapshot >/dev/null 2>&1\"'\n" "$SELF"
    fi
}

tt_tmux_conf_write() {
    local tmp
    mkdir -p "$TT_CONF_DIR" 2>/dev/null || true
    tmp="$TT_TMUX_CONF.tmp.$$"
    tt_tmux_conf_render > "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$TT_TMUX_CONF" || { rm -f "$tmp"; return 1; }
    # tmux 안이면 즉시 반영한다. 밖이면 다음 tmux 시작 때 source-file 이 읽는다.
    [ -n "${TMUX:-}" ] && tmux source-file "$TT_TMUX_CONF" 2>/dev/null
    return 0
}

if [ "${1:-}" = "--tmux-conf" ]; then
    if [ "${2:-}" = "--write" ]; then
        tt_tmux_conf_write || { echo "스니펫을 쓸 수 없다: $TT_TMUX_CONF" >&2; exit 1; }
        printf '%s\n' "$TT_TMUX_CONF"
    else
        tt_tmux_conf_render
    fi
    exit 0
fi
```

- [ ] **Step 4: `config set` 이 스니펫을 자동 갱신하게 한다**

`src/85-config-cli.sh` 의 `set`·`unset` 분기에서 `tt_conf_write` 성공 직후에 다음을 넣는다:

```bash
            case "$k" in key_summon|key_summon_fast) "$SELF" --tmux-conf --write >/dev/null 2>&1 || true ;; esac
            case "$k" in snapshot_on_exit) "$SELF" --tmux-conf --write >/dev/null 2>&1 || true ;; esac
```

`unset` 분기에서는 `$k` 대신 `$3` 을 본다.

> 자기 자신을 다시 부르는 이유: 스니펫 렌더 함수는 `87-tmux-conf.sh` 에 있는데 그 파일은 `85` 보다
> 뒤에 이어붙는다. 파일 순서를 뒤집는 것보다 이미 20군데에서 쓰는 `$SELF` 재호출 관례를 따르는 편이
> 안전하다.

- [ ] **Step 5: Makefile SRC 와 테스트**

```make
      src/85-config-cli.sh \
      src/87-tmux-conf.sh \
      src/90-main.sh
```

```bash
make && ./test/run.sh
```

기대: `t-05` 전부 `ok`.

- [ ] **Step 6: 실물에서 확인한다 (파괴적이지 않음)**

```bash
tt --tmux-conf            # 화면에만 출력 — 파일을 안 건드린다
```

기대: `bind F …`, 종료 스냅샷 훅 두 줄이 보인다.

- [ ] **Step 7: 커밋**

```bash
make check
git add src/85-config-cli.sh src/87-tmux-conf.sh Makefile bin/fmux test/t-05-tmux-conf.sh
git commit -m "feat: tmux 스니펫 생성 — 소환키·빠른 키 목록·떠날 때 스냅샷"
```

---

### Task 7: 팝업 단축키 재매핑과 3중 방어

**Files:**
- Modify: `src/90-main.sh:240-260` (fzf `--bind` 리터럴을 설정 경유로)
- Test: `test/t-06-keys.sh`

**Interfaces:**
- Consumes: `tt_conf_get`(Task 2), `tt_conf_is_fzf_key`(Task 3)
- Produces: `tt_key <액션키이름>` — 검증된 키 이름을 stdout 에. 설정값이 fzf 키 이름이 아니면 기본값으로 되돌리고 stderr 에 경고

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`test/t-06-keys.sh`:

```bash
#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
tt_test_sandbox

CONF="$XDG_CONFIG_HOME/fleetmux/config"
mkdir -p "$(dirname "$CONF")"

# tt_key 는 fmux 안에 있으므로 --print-keys 라는 확인용 진입점으로 관찰한다
assert_contains "$("$TTBIN" --print-keys)" "new=ctrl-n" "기본 키가 나온다"

printf 'key_new=ctrl-t\n' > "$CONF"
assert_contains "$("$TTBIN" --print-keys)" "new=ctrl-t" "설정한 키가 반영된다"

# 파일을 손으로 망가뜨린 경우 — 검증을 통과 못 하는 이름은 기본값으로 되돌린다
printf 'key_new=ctrl-없는키\n' > "$CONF"
out=$("$TTBIN" --print-keys 2>&1)
assert_contains "$out" "new=ctrl-n" "모르는 키 이름이면 기본값으로 되돌린다"
assert_contains "$out" "경고"       "되돌렸다고 경고한다"

# 되돌림은 그 키만 — 다른 키는 설정값을 지킨다
printf 'key_new=ctrl-없는키\nkey_kill=ctrl-y\n' > "$CONF"
out=$("$TTBIN" --print-keys 2>&1)
assert_contains "$out" "new=ctrl-n"  "망가진 키만 되돌린다"
assert_contains "$out" "kill=ctrl-y" "멀쩡한 키는 설정값을 지킨다"

tt_test_done
```

- [ ] **Step 2: 실패를 확인한다**

```bash
./test/run.sh
```

기대: `t-06` 전부 FAIL (`--print-keys` 가 없다).

- [ ] **Step 3: `tt_key` 와 확인용 진입점을 쓴다**

`src/90-main.sh` 에서 fzf 를 부르는 블록 **앞**에 넣는다:

```bash
# 설정된 키가 fzf 가 아는 이름인지 확인하고, 아니면 그 키만 기본값으로 되돌린다.
# 여기서 막지 않으면 fzf 가 기동 자체를 거부해 관제탑이 아예 안 뜬다 —
# 관제탑이 안 뜨는 것이 이 도구에서 가장 나쁜 실패다.
tt_key() {
    local action="${1:-}" k def
    def=$(tt_conf_default "key_$action") || return 1
    k=$(tt_conf_get "key_$action")
    if tt_conf_is_fzf_key "$k"; then printf '%s' "$k"; return 0; fi
    printf 'fleetmux 경고: key_%s 의 값 "%s" 는 fzf 가 아는 키 이름이 아니다 — 기본값 %s 로 돌린다\n' \
        "$action" "$k" "$def" >&2
    printf '%s' "$def"
}

if [ "${1:-}" = "--print-keys" ]; then
    for a in new rename kill reload detach broadcast help settings; do
        printf '%s=%s\n' "$a" "$(tt_key "$a")"
    done
    exit 0
fi
```

- [ ] **Step 4: fzf 바인딩을 설정 경유로 바꾼다**

`src/90-main.sh:246-257` 의 `--bind` 리터럴을 다음으로 바꾼다(키 이름만 변수화, 동작 문자열은 그대로):

```bash
          --bind "$(tt_key help):execute($SELFQ --help </dev/tty >/dev/tty 2>&1; printf '  press any key to return' >/dev/tty; read -rsn1 </dev/tty)" \
          --bind 'right:accept' \
          --bind 'left:abort' \
          --bind "$(tt_key reload):reload($SELFQ --list)" \
          --bind "$(tt_key detach):execute-silent(tmux detach-client)+abort" \
          --bind "$(tt_key new):execute($SELFQ --do-new </dev/tty >/dev/tty 2>&1)+clear-query+reload($SELFQ --list)" \
          --bind "$(tt_key rename):execute($SELFQ --do-rename {1} </dev/tty >/dev/tty 2>&1)+clear-query+reload($SELFQ --list)" \
          --bind "$(tt_key kill):execute($SELFQ --do-kill {1} </dev/tty >/dev/tty 2>&1)+reload($SELFQ --list)" \
          --bind "$(tt_key broadcast):execute($SELFQ --do-broadcast {+1} </dev/tty >/dev/tty 2>&1)+deselect-all+clear-query") || exit 0
```

- [ ] **Step 5: 최후 방어 — fzf 가 기동에 실패하면 기본 바인딩으로 재시도**

fzf 호출부(242~257행)는 결과를 `session` 변수에 담는다(`CUR` 은 "지금 붙어 있는 세션 이름"이라
이름이 다르다 — 헷갈리지 말 것). 이 호출 전체를 함수로 옮기고 rc 를 갈라 처리한다.

`src/90-main.sh` 에서 `session=$("$SELF" --list \` 로 시작하는 문장 전체를 아래 함수 정의로 감싼다:

```bash
# fzf 팝업 한 번. 표준출력으로 선택 결과를 준다.
#   rc 0   골랐다
#   rc 1   일치하는 항목이 없다
#   rc 2   fzf 기동 실패 — 대개 --bind 의 키 이름이 잘못됐을 때다
#   rc 130 사용자가 Esc/Ctrl-C 로 나갔다
tt_popup_fzf() {
    "$SELF" --list \
    | fzf --ansi --reverse --cycle --prompt='❯ ' --pointer='▶' --info=hidden --multi \
          ... (기존 옵션 그대로, --bind 만 Step 4 의 tt_key 형태로) ...
}
```

그리고 호출부를 이렇게 바꾼다:

```bash
rc=0
session=$(tt_popup_fzf) || rc=$?
if [ "$rc" = 2 ]; then
    # 설정한 키 때문에 fzf 가 아예 안 떴다 — 기본 키로 한 번 더.
    # 관제탑이 안 뜨는 상태가 이 도구에서 가장 나쁜 실패다.
    printf 'fleetmux 경고: 설정된 단축키로 팝업을 못 띄웠다 — 기본 키로 띄운다 (tt config 로 확인)\n' >&2
    rc=0
    session=$(TT_KEYS_DEFAULT=1 tt_popup_fzf) || rc=$?
fi
[ "$rc" = 0 ] || exit 0     # 1(무일치)·130(사용자 취소)은 조용히 끝낸다
```

`tt_key` 에 `TT_KEYS_DEFAULT` 탈출구를 넣는다(Step 3 에서 쓴 함수에 두 줄 추가):

```bash
tt_key() {
    local action="${1:-}" k def
    def=$(tt_conf_default "key_$action") || return 1
    [ -n "${TT_KEYS_DEFAULT:-}" ] && { printf '%s' "$def"; return 0; }
    k=$(tt_conf_get "key_$action")
    if tt_conf_is_fzf_key "$k"; then printf '%s' "$k"; return 0; fi
    printf 'fleetmux 경고: key_%s 의 값 "%s" 는 fzf 가 아는 키 이름이 아니다 — 기본값 %s 로 돌린다\n' \
        "$action" "$k" "$def" >&2
    printf '%s' "$def"
}
```

- [ ] **Step 6: 테스트와 실물 확인**

```bash
make && ./test/run.sh
tt config set key_new ctrl-t
tmux new-session -d -s zz-keytest 'sleep 60'   # zz 접두는 매니페스트에서 제외된다
# 팝업을 띄워 Ctrl-T 가 새 세션을 여는지 눈으로 확인한 뒤
tmux kill-session -t zz-keytest
tt config unset key_new
```

- [ ] **Step 7: 커밋**

```bash
make check
git add src/90-main.sh bin/fmux test/t-06-keys.sh
git commit -m "feat: 팝업 단축키 재매핑 — 검증·개별 폴백·기동 실패 시 기본키 재시도"
```

---

### Task 8: 팝업 안 설정 화면

**Files:**
- Create: `src/86-config-view.sh`
- Modify: `Makefile` (SRC 에 `src/86-config-view.sh` 를 `85-config-cli.sh` 다음, `87-tmux-conf.sh` 앞에 삽입)
- Modify: `src/80-view.sh` (`--list` 출력 맨 끝에 `⚙ settings` 항목 추가)
- Modify: `src/90-main.sh` (`tt_key settings` 바인딩 추가, `⚙` 항목 선택 시 설정 화면으로)
- Test: `test/t-07-config-view.sh`

**Interfaces:**
- Consumes: `tt_conf_get`·`tt_conf_source`·`TT_CONF_KEYS`(Task 2), `tt_conf_validate`(Task 3)
- Produces:
  - `tt --config-list` — 설정 화면용 한 줄씩 출력(`키<TAB>표시문자열`)
  - `tt --config-toggle <key>` — 불린이면 뒤집어 저장, 아니면 rc 2(호출자가 값 입력을 받아야 한다는 신호)
  - `tt --config-view` — fzf 설정 화면

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`test/t-07-config-view.sh`:

```bash
#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
tt_test_sandbox

CONF="$XDG_CONFIG_HOME/fleetmux/config"
mkdir -p "$(dirname "$CONF")"

# 설정 화면용 목록
out=$("$TTBIN" --config-list)
assert_contains "$out" "rc" "목록에 rc 가 있다"
assert_contains "$out" "on" "현재 값이 보인다"

# 불린 토글
assert_rc 0 "$TTBIN" --config-toggle rc
assert_eq "$("$TTBIN" config get rc)" "off" "토글이 값을 뒤집는다"
assert_rc 0 "$TTBIN" --config-toggle rc
assert_eq "$("$TTBIN" config get rc)" "on" "다시 토글하면 돌아온다"

# 불린이 아닌 키는 rc 2 (값 입력이 필요하다는 신호)
assert_rc 2 "$TTBIN" --config-toggle accent
assert_eq "$("$TTBIN" config get accent)" "73" "토글 실패 시 값이 안 바뀐다"

# --list 끝에 설정 항목이 붙는다
assert_contains "$("$TTBIN" --list 2>/dev/null)" "settings" "세션 목록 끝에 settings 항목이 있다"

tt_test_done
```

- [ ] **Step 2: 실패를 확인한다**

```bash
./test/run.sh
```

- [ ] **Step 3: 설정 화면 백엔드를 쓴다**

`src/86-config-view.sh`:

```bash
# ── 팝업 설정 화면 ──────────────────────────────────────────────────────────
# 한 줄에 담는 것: 키<TAB>보기좋은 표시. fzf 가 첫 필드만 뒤로 넘긴다.
tt_conf_is_bool() {
    case "${1:-}" in rc|snapshot|snapshot_on_exit|boot_restore) return 0 ;; *) return 1 ;; esac
}

tt_conf_desc() {
    case "${1:-}" in
        rc)               printf 'Remote Control 자동복구' ;;
        snapshot)         printf '1분마다 함대 기록' ;;
        snapshot_on_exit) printf '떠날 때 함대 기록' ;;
        boot_restore)     printf '부팅 시 자동 복원' ;;
        recent_hours)     printf '이름을 굵게 쓰는 기준(시간)' ;;
        unseen_minutes)   printf '상태바 ✓ 유지(분)' ;;
        accent)           printf '강조색(256색 번호)' ;;
        log_max)          printf '로그 회전 임계(바이트)' ;;
        key_summon)       printf '팝업 소환 (prefix 뒤)' ;;
        key_summon_fast)  printf '팝업 소환 (무prefix, 공백으로 여러 개)' ;;
        key_*)            printf '단축키' ;;
        *)                printf '' ;;
    esac
}

if [ "${1:-}" = "--config-list" ]; then
    for k in $TT_CONF_KEYS; do
        v=$(tt_conf_get "$k")
        [ -n "$v" ] || v='(없음)'
        printf '%s\t%-18s %-14s %s\n' "$k" "$k" "$v" "$(tt_conf_desc "$k")"
    done
    exit 0
fi

if [ "${1:-}" = "--config-toggle" ]; then
    k="${2:-}"
    tt_conf_default "$k" >/dev/null 2>&1 || { echo "모르는 키: $k" >&2; exit 1; }
    tt_conf_is_bool "$k" || exit 2          # 불린이 아니다 → 호출자가 값을 입력받아야 한다
    if tt_conf_on "$k"; then nv=off; else nv=on; fi
    "$SELF" config set "$k" "$nv" >/dev/null || exit 1
    exit 0
fi

if [ "${1:-}" = "--config-view" ]; then
    while :; do
        sel=$(tt_conf_view_once) || break
        [ -n "$sel" ] || break
    done
    exit 0
fi

# 한 번 그리고 한 번 고른다. Enter 로 토글하거나 값을 입력받고, Esc 로 빠져나온다.
tt_conf_view_once() {
    local line k
    line=$("$SELF" --config-list | fzf --ansi --delimiter=$'\t' --with-nth=2 \
        --prompt='설정 ' --header='Enter 바꾸기   Esc 돌아가기' \
        --bind 'left:abort' --bind 'esc:abort') || return 1
    k=${line%%$'\t'*}
    [ -n "$k" ] || return 1
    if "$SELF" --config-toggle "$k"; then return 0; fi
    [ $? = 2 ] || return 0
    # 불린이 아니면 값을 입력받는다
    printf '%s 의 새 값 (지금: %s): ' "$k" "$("$SELF" config get "$k")" >/dev/tty
    IFS= read -r nv </dev/tty || return 0
    [ -n "$nv" ] || return 0
    "$SELF" config set "$k" "$nv" >/dev/tty 2>&1 || { printf '  (그대로 둔다)\n' >/dev/tty; sleep 1; }
    return 0
}
```

> 함수는 진입점보다 먼저 정의돼야 한다. 위 코드에서 `tt_conf_view_once` 정의를 `--config-view`
> 진입점 **앞**으로 옮겨서 배치할 것.

- [ ] **Step 4: 세션 목록 끝에 `⚙ settings` 를 붙인다 — 그리고 새는 곳 셋을 막는다**

`--list` 의 출력은 팝업 목록 말고도 세 곳이 먹는다. 행을 하나 더 흘리면 그 셋이 조용히 오작동한다:
프리뷰(`--preview {1}`), 브로드캐스트 대상 수집, 빈 목록 부트스트랩 판정.

먼저 `src/80-view.sh` 의 `--list` 진입점에서 도구 세션까지 다 출력한 **뒤** 마지막 줄로 추가:

```bash
    printf '%s\t%s\n' '--settings--' $'\033[2m⚙ settings\033[0m'
```

이어서 새는 곳을 막는다.

① 프리뷰 — `src/90-main.sh:69` 의 `--preview` 진입점 맨 앞에:

```bash
    if [ "${2:-}" = "--settings--" ]; then "$SELF" config; exit 0; fi   # 설정 행을 고르면 현재 설정을 보여준다
```

② 브로드캐스트 대상 수집 — `targets+=("${line%%$'\t'*}")` 앞에:

```bash
        case "${line%%$'\t'*}" in '--settings--') continue ;; esac      # 설정 행에는 프롬프트를 보내지 않는다
```

③ 빈 목록 부트스트랩 — `if [ -z "$("$SELF" --list)" ]; then` (228행)은 설정 행 때문에 이제 절대
비지 않는다. 판정에서 설정 행을 뺀다:

```bash
if [ -z "$("$SELF" --list | grep -v '^--settings--	' || true)" ]; then
```

- [ ] **Step 5: 팝업에서 두 진입로를 연결한다**

`src/90-main.sh` 의 fzf 바인딩(Step 4 에서 `tt_popup_fzf` 안으로 옮긴 그 목록)에 한 줄 추가:

```bash
          --bind "$(tt_key settings):execute($SELFQ --config-view </dev/tty >/dev/tty 2>&1)+reload($SELFQ --list)" \
```

그리고 선택 결과를 처리하는 자리 — `session=$(printf '%s\n' "$session" | grep -v '^─' || true)`
(259행) **다음**, 다중선택 개수를 세기 **전**에 넣는다:

```bash
# 설정 행을 골랐다 — 세션 진입 대신 설정 화면을 열고, 닫으면 목록으로 돌아온다.
if [ "${session%%$'\t'*}" = '--settings--' ]; then
    "$SELF" --config-view
    exec "$SELF" --from "$CUR"
fi
```

> `session` 과 `CUR` 을 헷갈리지 말 것. `session` 은 fzf 가 돌려준 선택 줄이고,
> `CUR` 은 지금 붙어 있는 세션 이름(`--from` 으로 받은 값)이다.

- [ ] **Step 6: 테스트와 실물 확인**

```bash
make && ./test/run.sh
tt --config-list | head -5
# 팝업을 띄워 Ctrl-O 로 설정 화면이 열리는지, Esc 로 돌아오는지 눈으로 확인
```

- [ ] **Step 7: 커밋**

```bash
make check
git add src/80-view.sh src/86-config-view.sh src/90-main.sh Makefile bin/fmux test/t-07-config-view.sh
git commit -m "feat: 팝업 안 설정 화면 — 토글·값 입력·두 진입로"
```

---

---

### Task 9: 에이전트용 스킬 배포 (`skills/fleetmux/SKILL.md`)

fmux 는 훅으로 상태를 이미 알고 있다. 그 앎을 **에이전트 자신에게** 열어주는 것이 이 태스크다.
사람이 팝업을 열어 보는 것과 같은 사실을, 세션 안의 claude 가 명령 한 줄로 읽게 한다.

기존 화면 긁기 방식(`capture-pane` 으로 다른 세션 화면을 떠서 눈으로 판독)과 다르다 —
그 방식은 fmux 가 세 번 실패하고 버린 길이다(작업중 표시의 모양이 여러 가지, 유휴 세션도
상태바가 깜빡여 해시가 계속 바뀜, 붙기만 해도 pane 이 다시 감겨 또 바뀜). 스킬도 같은 규율을 따른다:
**훅 상태가 정답, 화면은 참고.**

**Files:**
- Create: `skills/fleetmux/SKILL.md`
- Test: `test/t-08-skill.sh`

**Interfaces:**
- Consumes: `tt --list`·`tt --status`·`tt --preview`(기존 CLI, 변경 없음), `~/.cache/tt/hook-*`
- Produces: 설치 시 `~/.claude/skills/fleetmux/SKILL.md` 로 복사될 파일. 코드 변경 없음

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`test/t-08-skill.sh`:

```bash
#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
tt_test_sandbox
cd "$(dirname "$0")/.." || exit 1

S=skills/fleetmux/SKILL.md
assert_rc 0 test -f "$S"

# 프론트매터가 있어야 스킬로 인식된다
assert_eq "$(head -1 "$S")" "---" "프론트매터로 시작한다"
assert_contains "$(sed -n '1,6p' "$S")" "name: fleetmux" "name 필드가 있다"
assert_contains "$(sed -n '1,6p' "$S")" "description:" "description 필드가 있다"

# 스킬이 안내하는 명령이 실제로 존재하는 진입점이어야 한다
for cmd in -- --list --status --preview; do
    case "$cmd" in --) continue ;; esac
    assert_contains "$(cat "$S")" "tt $cmd" "스킬이 tt $cmd 를 안내한다"
    assert_contains "$(cat src/*.sh)" "\"\${1:-}\" = \"$cmd\"" "$cmd 진입점이 실제로 있다"
done

# 쓰기 동작은 반드시 확인을 거치라고 적혀 있어야 한다
assert_contains "$(cat "$S")" "--do-broadcast" "브로드캐스트를 언급한다"
assert_contains "$(cat "$S")" "read-only" "읽기 전용이 기본이라고 못박는다"

tt_test_done
```

- [ ] **Step 2: 실패를 확인한다**

```bash
./test/run.sh
```

기대: `t-08` 이 첫 줄부터 FAIL(파일이 없다).

- [ ] **Step 3: 스킬을 쓴다**

`skills/fleetmux/SKILL.md` (레포 언어에 맞춰 영어로 쓴다):

```markdown
---
name: fleetmux
description: Use when asked what the other agent sessions are doing — "what is each session working on", "who is waiting for me", "is anything stuck", "fleet status", "check the other sessions". Reports per-session state for tmux sessions running Claude Code or Codex, using fmux hook state rather than screen scraping. Read-only by default.
---

# fleetmux — read the fleet without attaching

## The one rule

**Hook state is the fact. The screen is a rendering.**

Do not decide whether a session is working by looking at its pane. fmux tried that first and it
failed three ways: the "working" line has many shapes, an idle session's status bar keeps ticking,
and merely attaching re-wraps the pane. Every session reports its own state through Claude Code /
Codex hooks, and fmux writes that down. Read what it wrote.

## Fleet at a glance

```bash
tt --status     # one line: "⏸2 ✻3" — waiting for you / working right now, plus ✓name badges
tt --list       # one row per session: name, marks, last activity
```

Marks: `●` attached · `✻` working · `⏸` awaiting your approval · `✓` finished while you were away
· `⊘` remote control dropped.

**`⏸` is the one that matters.** It means a session is blocked on a human — permission prompt,
plan approval, a question. Surface those first, before anything else.

## One session in detail

```bash
tt --preview <session-name>    # tail of that pane — the bottom is where the prompt lives
```

Use this only after the state told you which session is interesting. It is a rendering: quote it
as evidence, never as the state itself.

## Raw state, if you need it

```bash
cat ~/.cache/tt/hook-<tmux-session-id>   # "<state> <unix-ts> <agent-pid>"
cat ~/.cache/tt/manifest                 # name, cwd, kind, command, conversation id
```

`~/.cache/tt/hook.log` is an append-only audit trail of every state transition — useful for
"when did it go quiet?".

## Many sessions

With more than two sessions, do not read every pane yourself — that is hundreds of lines per
session and it buys nothing. Dispatch one subagent per session, in parallel, and require a fixed
report shape:

```
state:   working | waiting-on-human | idle
doing:   <one line>
blocked: <what it needs, or none>
```

Then merge. `tt --status` already gives you the tally, so the subagents only fill in the "why".

## Writing into other sessions

This skill is **read-only** by default. Sending text into another agent's session interrupts
whatever it is doing and cannot be undone.

If — and only if — the human explicitly asks to send something:

```bash
tt --do-broadcast <name> [<name>...]    # prompts, then sends to each
```

Confirm the exact target list with the human first. Never broadcast to tool sessions (shells,
`btop`, `lazydocker`); a prompt typed into a shell runs as a command. fmux skips them, but say
out loud which sessions you are about to touch.

## When tt is not installed

If `tt` is not on PATH, say so and stop. Do not fall back to scraping panes — that is the exact
guesswork this tool exists to remove.
```

- [ ] **Step 4: 테스트 통과를 확인한다**

```bash
./test/run.sh
```

기대: `t-08` 전부 `ok`.

- [ ] **Step 5: 실물로 한 번 써본다**

```bash
mkdir -p ~/.claude/skills/fleetmux
cp skills/fleetmux/SKILL.md ~/.claude/skills/fleetmux/SKILL.md
```

새 claude 세션에서 "다른 세션들 뭐 하고 있어?" 라고 물어 스킬이 발동하는지, `tt --status` 를
먼저 부르는지 확인한다.

> 설치 자동화(`install.sh` 가 이 디렉토리를 깔지 물어보기)는 **공개 준비 계획**에서 다룬다.
> 스킬은 Claude Code 전용이다 — codex 에는 스킬 개념이 없으므로 README 에 그렇게 적는다.

- [ ] **Step 6: 커밋**

```bash
make check
git add skills/fleetmux/SKILL.md test/t-08-skill.sh
git commit -m "feat: 에이전트용 스킬 — 화면 대신 훅 상태로 함대를 읽는다"
```

---

## 다음 계획 (이 문서 범위 밖)

- **공개 준비**: `install.sh`(의존성 확인 → `make install` → shim 배치 → `source-file` 한 줄 안내 → 소환키 프리셋 선택 → 스킬 설치 여부 질문), README 의 `Configuration` 절과 libexec 경로 오기(`libexec/fleetmux` → `libexec/tt`) 수정, macOS/WSL 키 표. 별도 계획 문서로 뺀다.
- **`0.0.0.0:5432` 확인**: fmux 와 무관한 파이 운영 건. LX 노트 세션이 조사 중.
