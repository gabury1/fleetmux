# fleetmux config system Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Open up fmux's hardcoded preferences (rc auto-recovery, cron snapshots, thresholds, color, keybindings) into a config file, changeable via the `fmux config` CLI and an in-popup settings screen.

**Architecture:** A new file `src/05-config.sh` defines the whitelist parser and `fmux_conf_get`, loaded once at script start (never `source`d). Consumption sites (`--cron`, `--snapshot`, `--boot-restore`, `--list`, `--status`, the popup) call `fmux_conf_get` instead of using constants. The CLI lives in `src/85-config-cli.sh`, the in-popup settings screen in `src/86-config-view.sh`. On the tmux side (summon key, exit-snapshot hook), fmux generates a snippet file it owns, so the user's `.tmux.conf` is never touched.

**Tech Stack:** bash (3.2-compatible), tmux ≥ 3.2, fzf ≥ 0.64, awk/flock. No new dependencies.

## Global Constraints

- **Must run on bash 3.2** (macOS's default `/bin/bash`). No associative arrays (`declare -A`), no `${var^^}` — use `tr` for uppercasing.
- **No GNU-only options.** No `stat -c`, `readlink -f`, `sed -i`. Use `wc -c <file` for size, tmp+`mv` for in-place edits.
- **Whenever `src/*.sh` changes, rebuild `bin/fmux` with `make` and include it in the same commit.** `make verify` does a byte comparison confirming "the committed `bin/fmux` == `src/*.sh` concatenated." Skip this and verification breaks.
- **When adding a new file, insert it into the `Makefile`'s `SRC` list in numeric order.** The list is the source of truth, not a glob.
- **Shebang only in `src/00-header.sh`.** Put it anywhere else and it ends up buried in the middle of the concatenated output.
- Entry points are an `if [ "${1:-}" = "--x" ]; then …; exit 0; fi` chain, and **the branch that appears first wins.** File number is priority order.
- **Never `source` the config file.** It's read by hooks on every event and by cron every minute.
- **The program never edits the user's `~/.tmux.conf` or crontab.**
- Tests are pure bash. No new test dependency (bats, etc.) is introduced.
- Value charset: the spec draft's `^[a-z_][a-z0-9_]*=[0-9A-Za-z_./:+-]*$` **blocks spaces, which means `key_summon_fast="C-Left M-b"` can't be accepted.** This plan includes a space in the value charset (`[0-9A-Za-z_./:+ -]*`). The spec doc is also corrected in Task 2.

---

### Task 1: Test harness

**Files:**
- Create: `test/run.sh`
- Create: `test/lib.sh`
- Modify: `Makefile:49-57` (add test execution to the `check` target)

**Interfaces:**
- Produces: shell functions provided by `test/lib.sh` — `fmux_test_sandbox` (creates a temp HOME/XDG_CONFIG_HOME and sets `FMUXBIN` as an absolute path), `assert_eq <actual> <expected> <description>`, `assert_contains <string> <substring> <description>`, `assert_rc <expected_rc> <command...>`. Every subsequent task's tests use only these three.

- [ ] **Step 1: Write the test library**

`test/lib.sh`:

```bash
# fleetmux shared test utilities — pure bash. No dependencies.
# Each test file sources this and starts with fmux_test_sandbox.

FMUX_FAIL=0
FMUX_RUN=0

# Builds an isolated HOME/XDG so the real ~/.config and ~/.cache are never touched.
fmux_test_sandbox() {
    FMUXROOT=$(mktemp -d "${TMPDIR:-/tmp}/fmux-test.XXXXXX") || exit 1
    export HOME="$FMUXROOT/home"
    export XDG_CONFIG_HOME="$FMUXROOT/home/.config"
    mkdir -p "$HOME" "$XDG_CONFIG_HOME"
    # isolate the socket name so tests never attach to a real tmux server
    export TMUX_TMPDIR="$FMUXROOT"
    trap 'rm -rf "$FMUXROOT"' EXIT
}

assert_eq() {
    FMUX_RUN=$((FMUX_RUN + 1))
    if [ "$1" = "$2" ]; then
        printf '  ok   %s\n' "$3"
    else
        FMUX_FAIL=$((FMUX_FAIL + 1))
        printf '  FAIL %s\n       expected: [%s]\n       actual:   [%s]\n' "$3" "$2" "$1"
    fi
}

assert_contains() {
    FMUX_RUN=$((FMUX_RUN + 1))
    case "$1" in
        *"$2"*) printf '  ok   %s\n' "$3" ;;
        *) FMUX_FAIL=$((FMUX_FAIL + 1))
           printf '  FAIL %s\n       [%s] does not contain [%s]\n' "$3" "$1" "$2" ;;
    esac
}

# rc check — wrapped in a subshell so it doesn't die under set -e
assert_rc() {
    local want="$1"; shift
    local got=0
    "$@" >/dev/null 2>&1 || got=$?
    FMUX_RUN=$((FMUX_RUN + 1))
    if [ "$got" = "$want" ]; then
        printf '  ok   rc=%s  %s\n' "$want" "$1"
    else
        FMUX_FAIL=$((FMUX_FAIL + 1))
        printf '  FAIL rc  %s\n       expected: %s  actual: %s\n' "$*" "$want" "$got"
    fi
}

fmux_test_done() {
    printf '  — %d/%d failed\n' "$FMUX_FAIL" "$FMUX_RUN"
    [ "$FMUX_FAIL" = 0 ]
}
```

- [ ] **Step 2: Write the runner**

`test/run.sh`:

```bash
#!/usr/bin/env bash
# Runs every test/t-*.sh, each as its own process.
# If one file dies the rest still run — so all failures show up at once.
set -u
cd "$(dirname "$0")/.." || exit 1
FMUXBIN="$PWD/bin/fmux"
[ -x "$FMUXBIN" ] || { echo "bin/fmux not found — run make first"; exit 1; }
export FMUXBIN

fail=0
for t in test/t-*.sh; do
    [ -f "$t" ] || continue
    printf '%s\n' "$t"
    bash "$t" || fail=1
done
[ "$fail" = 0 ] && echo "all tests passed" || echo "some tests failed"
exit "$fail"
```

- [ ] **Step 3: Write a test that measures itself**

`test/t-00-harness.sh`:

```bash
#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
fmux_test_sandbox

assert_eq "$(printf 'a')" "a" "assert_eq passes on equal values"
assert_contains "hello world" "lo w" "assert_contains finds the substring"
assert_rc 0 true
assert_rc 1 false
# the sandbox must not be the real HOME
case "$HOME" in */fmux-test.*) printf '  ok   HOME is isolated\n' ;;
    *) printf '  FAIL HOME is not isolated: %s\n' "$HOME"; FMUX_FAIL=$((FMUX_FAIL+1)) ;;
esac

fmux_test_done
```

- [ ] **Step 4: Run it and confirm it passes**

```bash
chmod +x test/run.sh
make && ./test/run.sh
```

Expected: `test/t-00-harness.sh` is all `ok`, ending with `all tests passed`.

- [ ] **Step 5: Wire into `make check`**

Change the `check` target in `Makefile` to this:

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

- [ ] **Step 6: Commit**

```bash
make check
git add test/lib.sh test/run.sh test/t-00-harness.sh Makefile
git commit -m "test: add pure-bash test harness"
```

---

### Task 2: Config parser (`src/05-config.sh`)

**Files:**
- Create: `src/05-config.sh`
- Modify: `Makefile:29-39` (insert `src/05-config.sh` into the SRC list right after `00-header.sh`, and add a line to the file-description comment)
- Modify: `docs/superpowers/specs/2026-08-04-fleetmux-config-design.md` (correct the value charset to allow spaces)
- Test: `test/t-01-config-parse.sh`

**Interfaces:**
- Consumes: `STATE` (00-header.sh), `test/lib.sh` (Task 1)
- Produces:
  - `FMUX_CONF` — the config file's absolute path string
  - `FMUX_CONF_KEYS` — space-separated list of known keys (same order as output)
  - `fmux_conf_default <key>` — prints the default to stdout. rc 1 if the key is unknown
  - `fmux_conf_get <key>` — prints the effective value (env > file > default) to stdout. rc 1 if the key is unknown
  - `fmux_conf_source <key>` — prints one of `env` | `file` | `default` to stdout
  - `fmux_conf_on <key>` — rc 0 if the boolean key is on, rc 1 otherwise

- [ ] **Step 1: Write a failing test**

`test/t-01-config-parse.sh`:

```bash
#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
fmux_test_sandbox

CONF="$XDG_CONFIG_HOME/fleetmux/config"
mkdir -p "$(dirname "$CONF")"

# ① everything defaults when there's no file
assert_eq "$("$FMUXBIN" config get rc)"             "on"      "rc defaults to on"
assert_eq "$("$FMUXBIN" config get recent_hours)"   "6"       "recent_hours defaults to 6"
assert_eq "$("$FMUXBIN" config get key_summon)"     "F"       "key_summon defaults to F"
assert_eq "$("$FMUXBIN" config get key_summon_fast)" ""       "key_summon_fast defaults to empty"
assert_eq "$("$FMUXBIN" config source rc)"          "default" "source is default"

# ② the file beats the default
cat > "$CONF" <<'EOF'
# comments are ignored
rc=off

recent_hours=12
key_summon_fast=C-Left M-b
EOF
assert_eq "$("$FMUXBIN" config get rc)"              "off"          "the file beats the default"
assert_eq "$("$FMUXBIN" config get recent_hours)"    "12"           "numeric values are also read"
assert_eq "$("$FMUXBIN" config get key_summon_fast)" "C-Left M-b"   "a value with a space (a list) is read"
assert_eq "$("$FMUXBIN" config source rc)"           "file"         "source is file"

# ③ env beats the file
assert_eq "$(FMUX_RC=on "$FMUXBIN" config get rc)"     "on"   "env beats the file"
assert_eq "$(FMUX_RC=on "$FMUXBIN" config source rc)"  "env"  "source is env"

# ④ broken lines and unknown keys are ignored, the rest survives
cat > "$CONF" <<'EOF'
rc=off
this = is a broken line
unknown_key=1
rm -rf $HOME
accent=200
EOF
assert_eq "$("$FMUXBIN" config get rc)"     "off"  "earlier values survive a broken line"
assert_eq "$("$FMUXBIN" config get accent)" "200"  "values after the broken line survive too"
assert_contains "$("$FMUXBIN" config get rc 2>&1 >/dev/null)" "ignor" "warns that it was ignored"
# and HOME must still be intact — the spot that would've been wiped if this were sourced
assert_rc 0 test -d "$HOME"

# ⑤ an unknown key is refused
assert_rc 1 "$FMUXBIN" config get nope

fmux_test_done
```

- [ ] **Step 2: Confirm it fails**

```bash
./test/run.sh
```

Expected: `t-01-config-parse.sh` fails entirely (there's no `config` subcommand yet, so fmux either fails trying to launch the popup, or prints nothing).

- [ ] **Step 3: Write the parser**

`src/05-config.sh`:

```bash
# ── config ──────────────────────────────────────────────────────────────────
# Priority: env var > config file > code default.
#
# Why this file is never `source`d: it's read by hooks on every event and by cron
# every minute. If it were sourced, a single typo'd line from the user would silently
# kill fleet command entirely from that point on. So it's read only through a
# whitelist parser — only lines with a known key and a known shape pass through.
FMUX_CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/fleetmux"
FMUX_CONF="${FMUX_CONF_FILE:-$FMUX_CONF_DIR/config}"

# The known keys. This order is also the order `fmux config` lists them in.
FMUX_CONF_KEYS='rc snapshot snapshot_on_exit boot_restore recent_hours unseen_minutes accent log_max key_new key_rename key_kill key_reload key_detach key_broadcast key_help key_settings key_summon key_summon_fast'

# Defaults. rc 1 for an unknown key — this function also doubles as the "is this a
# known key" check.
fmux_conf_default() {
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

# key → env var name. bash 3.2 has no ${var^^} → uppercase with tr instead.
fmux_conf_envname() {
    printf 'FMUX_%s' "$(printf '%s' "${1:-}" | tr '[:lower:]' '[:upper:]')"
}

# Reads one key from the config file. rc 1 if absent.
#   Passes only if: the key is on the known list, the line has the shape `key=value`,
#   and the value consists only of [0-9A-Za-z_./:+ -] (space allowed — key_summon_fast
#   is a list).
fmux_conf_file_get() {
    local want="${1:-}" line k v found=1 out=''
    [ -f "$FMUX_CONF" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ''|'#'*|' '*'#'*) continue ;; esac
        case "$line" in *=*) ;; *) continue ;; esac
        k=${line%%=*}
        v=${line#*=}
        # key shape check
        case "$k" in
            ''|*[!a-z0-9_]*) printf 'fleetmux: ignoring line in %s — not a key shape: %s\n' "$FMUX_CONF" "$line" >&2; continue ;;
        esac
        # is it a known key
        if ! fmux_conf_default "$k" >/dev/null 2>&1; then
            printf 'fleetmux: ignoring line in %s — unknown key: %s\n' "$FMUX_CONF" "$k" >&2
            continue
        fi
        # value charset check
        case "$v" in
            *[!0-9A-Za-z_./:+\ -]*) printf 'fleetmux: ignoring line in %s — disallowed character in value: %s\n' "$FMUX_CONF" "$line" >&2; continue ;;
        esac
        if [ "$k" = "$want" ]; then out=$v; found=0; fi   # the last matching line wins
    done < "$FMUX_CONF"
    [ "$found" = 0 ] || return 1
    printf '%s' "$out"
    return 0
}

# Effective value. rc 1 for an unknown key.
fmux_conf_get() {
    local k="${1:-}" envn v
    fmux_conf_default "$k" >/dev/null 2>&1 || return 1
    envn=$(fmux_conf_envname "$k")
    eval "v=\${$envn+set}"
    if [ "${v:-}" = set ]; then eval "printf '%s' \"\$$envn\""; return 0; fi
    if v=$(fmux_conf_file_get "$k" 2>/dev/null); then printf '%s' "$v"; return 0; fi
    fmux_conf_default "$k"
}

# Where the value came from — env | file | default
fmux_conf_source() {
    local k="${1:-}" envn v
    fmux_conf_default "$k" >/dev/null 2>&1 || return 1
    envn=$(fmux_conf_envname "$k")
    eval "v=\${$envn+set}"
    if [ "${v:-}" = set ]; then printf 'env'; return 0; fi
    if fmux_conf_file_get "$k" >/dev/null 2>&1; then printf 'file'; return 0; fi
    printf 'default'
}

# Is a boolean key on. on/1/true/yes count as on (case-insensitive).
fmux_conf_on() {
    local v
    v=$(fmux_conf_get "${1:-}") || return 1
    case "$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')" in
        on|1|true|yes) return 0 ;;
        *) return 1 ;;
    esac
}
```

- [ ] **Step 4: Wire up a minimal `config get` / `config source` CLI**

Task 3 adds the rest (`list`, `set`, `unset`, `path`). For now, just the two the tests need.
Append this to the end of `src/05-config.sh`:

```bash
# config query entry point (minimal). 85-config-cli.sh handles the rest of the subcommands.
if [ "${1:-}" = "config" ] && { [ "${2:-}" = "get" ] || [ "${2:-}" = "source" ]; }; then
    [ -n "${3:-}" ] || { echo "usage: fmux config ${2} <key>" >&2; exit 1; }
    if [ "$2" = get ]; then fmux_conf_get "$3" || { echo "unknown key: $3" >&2; exit 1; }
    else                    fmux_conf_source "$3" || { echo "unknown key: $3" >&2; exit 1; }
    fi
    echo
    exit 0
fi
```

- [ ] **Step 5: Add to Makefile SRC**

Insert right after `src/00-header.sh` in the `SRC` list:

```make
SRC = src/00-header.sh \
      src/05-config.sh \
      src/10-util.sh \
```

Add a line to the file-description comment too:

```
#   05-config.sh   config — whitelist parser, env>file>default priority, fmux_conf_get/on/source
```

- [ ] **Step 6: Confirm the test passes**

```bash
make && ./test/run.sh
```

Expected: `t-01-config-parse.sh` all `ok`.

- [ ] **Step 7: Correct the value charset in the spec doc**

In `docs/superpowers/specs/2026-08-04-fleetmux-config-design.md`, change

```
  a line matches `^[a-z_][a-z0-9_]*=[0-9A-Za-z_./:+-]*$`
```

to:

```
  a line matches `^[a-z_][a-z0-9_]*=[0-9A-Za-z_./:+ -]*$` (spaces allowed in the value —
  `key_summon_fast` is a key list)
```

- [ ] **Step 8: Commit**

```bash
make check
git add src/05-config.sh Makefile bin/fmux test/t-01-config-parse.sh docs/superpowers/specs/2026-08-04-fleetmux-config-design.md
git commit -m "feat: config parser — whitelist-based, env>file>default"
```

---

### Task 3: `fmux config` CLI (list / set / unset / path)

**Files:**
- Create: `src/85-config-cli.sh`
- Modify: `Makefile` (insert `src/85-config-cli.sh` into SRC right after `src/80-view.sh`, plus a comment line)
- Modify: `src/05-config.sh` (remove the minimal CLI block added in Step 4 — 85 takes over entirely)
- Test: `test/t-02-config-cli.sh`

**Interfaces:**
- Consumes: `fmux_conf_get`, `fmux_conf_source`, `fmux_conf_default`, `FMUX_CONF_KEYS`, `FMUX_CONF` (Task 2)
- Produces:
  - `fmux_conf_validate <key> <value>` — rc 0 if valid, rc 1 + reason on stderr otherwise
  - `fmux_conf_set <key> <value>` — atomic write. Preserves comments and line order
  - `fmux_conf_unset <key>` — deletes that line
  - CLI: `fmux config` / `fmux config get <k>` / `fmux config source <k>` / `fmux config set <k> <v>` / `fmux config unset <k>` / `fmux config path`

- [ ] **Step 1: Write a failing test**

`test/t-02-config-cli.sh`:

```bash
#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
fmux_test_sandbox

CONF="$XDG_CONFIG_HOME/fleetmux/config"

# ① path returns the config file path (even before the file exists)
assert_eq "$("$FMUXBIN" config path)" "$CONF" "config path returns the path"

# ② set creates the file and writes the value
assert_rc 0 "$FMUXBIN" config set rc off
assert_eq "$("$FMUXBIN" config get rc)" "off" "the value set is read back"
assert_rc 0 test -f "$CONF"

# ③ an invalid value is rejected — the file isn't touched either
assert_rc 1 "$FMUXBIN" config set rc maybe
assert_eq "$("$FMUXBIN" config get rc)" "off" "a rejected set doesn't change the file"
assert_rc 1 "$FMUXBIN" config set recent_hours abc
assert_rc 1 "$FMUXBIN" config set accent 999
assert_rc 1 "$FMUXBIN" config set nope 1

# ④ reserved keys refuse to be remapped
assert_rc 1 "$FMUXBIN" config set key_new esc
assert_rc 1 "$FMUXBIN" config set key_kill enter

# ⑤ key conflicts are refused (key_rename is already ctrl-e)
assert_rc 1 "$FMUXBIN" config set key_new ctrl-e
assert_contains "$("$FMUXBIN" config set key_new ctrl-e 2>&1)" "key_rename" "names the key it collided with"

# ⑥ hand-written comments and line order are preserved
printf '# my comment\nrc=off\naccent=200\n' > "$CONF"
"$FMUXBIN" config set accent 100 >/dev/null
assert_contains "$(cat "$CONF")" "# my comment" "the comment survives"
assert_eq "$(head -2 "$CONF" | tail -1)" "rc=off" "line order is preserved"
assert_eq "$("$FMUXBIN" config get accent)" "100" "only the value changes"

# ⑦ unset reverts to the default
assert_rc 0 "$FMUXBIN" config unset accent
assert_eq "$("$FMUXBIN" config get accent)" "73" "unset gives back the default"

# ⑧ the listing shows both value and source
out=$("$FMUXBIN" config)
assert_contains "$out" "rc" "rc is in the listing"
assert_contains "$out" "file" "the listing shows the source"
assert_contains "$out" "key_summon" "key_summon is in the listing"

fmux_test_done
```

- [ ] **Step 2: Confirm it fails**

```bash
./test/run.sh
```

Expected: most of `t-02-config-cli.sh` fails.

- [ ] **Step 3: Write validation, writing, and the CLI**

`src/85-config-cli.sh`:

```bash
# ── config CLI ──────────────────────────────────────────────────────────────
# Keys that can never be remapped. There must always be one door open that gets
# you out even if you fumble.
FMUX_CONF_RESERVED='esc enter left'

# Is this a key name fzf recognizes inside the popup (a whitelist subset).
# If a name not here is passed through, fzf refuses to launch at all, and the
# control tower doesn't come up — so this is blocked in advance.
fmux_conf_is_fzf_key() {
    case "${1:-}" in
        ctrl-[a-z]|alt-[a-z0-9]) return 0 ;;
        f[1-9]|f1[0-2]) return 0 ;;
        tab|btab|home|end|pgup|pgdn|del|ins|up|down|left|right|enter|esc|space) return 0 ;;
        ?) return 0 ;;      # a single printable character like '?'
        *) return 1 ;;
    esac
}

# Is this a key name tmux understands. Used for key_summon (single) and
# key_summon_fast (space-separated list).
fmux_conf_is_tmux_key() {
    case "${1:-}" in
        ''|*[!A-Za-z0-9C\-M\ ]*) return 1 ;;
    esac
    return 0
}

# Validation. On rc 1, the reason is printed to stderr.
fmux_conf_validate() {
    local k="${1:-}" v="${2:-}" other ov
    fmux_conf_default "$k" >/dev/null 2>&1 || { echo "unknown key: $k" >&2; return 1; }
    case "$k" in
        rc|snapshot|snapshot_on_exit|boot_restore)
            case "$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')" in
                on|off|1|0|true|false|yes|no) ;;
                *) echo "$k must be on|off (got: $v)" >&2; return 1 ;;
            esac ;;
        recent_hours|unseen_minutes|log_max)
            case "$v" in ''|*[!0-9]*) echo "$k must be a positive integer (got: $v)" >&2; return 1 ;; esac
            [ "$v" -gt 0 ] || { echo "$k must be greater than 0" >&2; return 1; } ;;
        accent)
            case "$v" in ''|*[!0-9]*) echo "accent must be an integer 0-255 (got: $v)" >&2; return 1 ;; esac
            [ "$v" -le 255 ] || { echo "accent must be 0-255 (got: $v)" >&2; return 1; } ;;
        key_summon)
            fmux_conf_is_tmux_key "$v" || { echo "key_summon must be a tmux key name (e.g. F, C-Left)" >&2; return 1; } ;;
        key_summon_fast)
            for ov in $v; do
                fmux_conf_is_tmux_key "$ov" || { echo "'$ov' in key_summon_fast is not a tmux key name" >&2; return 1; }
            done ;;
        key_*)
            for ov in $FMUX_CONF_RESERVED; do
                [ "$v" = "$ov" ] && { echo "$v is reserved and can't be remapped (close/enter must always stay open)" >&2; return 1; }
            done
            fmux_conf_is_fzf_key "$v" || { echo "not a key name fzf understands: $v (e.g. ctrl-n, alt-x, f2)" >&2; return 1; }
            # conflict — is this key already used by another action
            for other in $FMUX_CONF_KEYS; do
                case "$other" in key_summon|key_summon_fast|"$k") continue ;; key_*) ;; *) continue ;; esac
                if [ "$(fmux_conf_get "$other")" = "$v" ]; then
                    echo "$v is already used by $other" >&2; return 1
                fi
            done ;;
    esac
    return 0
}

# Atomic write. Existing lines get only their value replaced; new ones are appended
# (preserves comments and order).
fmux_conf_write() {
    local k="${1:-}" v="${2:-}" mode="${3:-set}" tmp line seen=0
    mkdir -p "${FMUX_CONF%/*}" 2>/dev/null || true
    tmp="$FMUX_CONF.tmp.$$"
    : > "$tmp" || { echo "can't write config file: $FMUX_CONF" >&2; return 1; }
    if [ -f "$FMUX_CONF" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in
                "$k"=*)
                    seen=1
                    [ "$mode" = set ] && printf '%s=%s\n' "$k" "$v" >> "$tmp"
                    ;;
                *) printf '%s\n' "$line" >> "$tmp" ;;
            esac
        done < "$FMUX_CONF"
    fi
    if [ "$mode" = set ] && [ "$seen" = 0 ]; then printf '%s=%s\n' "$k" "$v" >> "$tmp"; fi
    mv -f "$tmp" "$FMUX_CONF" || { rm -f "$tmp"; return 1; }
    return 0
}

if [ "${1:-}" = "config" ]; then
    case "${2:-}" in
        ''|list)
            printf '%-18s %-14s %s\n' 'KEY' 'VALUE' 'SOURCE'
            for k in $FMUX_CONF_KEYS; do
                printf '%-18s %-14s %s\n' "$k" "$(fmux_conf_get "$k")" "$(fmux_conf_source "$k")"
            done
            exit 0 ;;
        get|source)
            [ -n "${3:-}" ] || { echo "usage: fmux config $2 <key>" >&2; exit 1; }
            if [ "$2" = get ]; then fmux_conf_get "$3" || { echo "unknown key: $3" >&2; exit 1; }
            else                    fmux_conf_source "$3" || { echo "unknown key: $3" >&2; exit 1; }
            fi
            echo
            exit 0 ;;
        set)
            [ -n "${3:-}" ] || { echo "usage: fmux config set <key> <value>" >&2; exit 1; }
            shift 2; k=$1; shift
            v="$*"
            fmux_conf_validate "$k" "$v" || exit 1
            fmux_conf_write "$k" "$v" set || exit 1
            printf '%s=%s\n' "$k" "$v"
            exit 0 ;;
        unset)
            [ -n "${3:-}" ] || { echo "usage: fmux config unset <key>" >&2; exit 1; }
            fmux_conf_default "$3" >/dev/null 2>&1 || { echo "unknown key: $3" >&2; exit 1; }
            fmux_conf_write "$3" '' unset || exit 1
            printf '%s → default %s\n' "$3" "$(fmux_conf_default "$3")"
            exit 0 ;;
        path)
            printf '%s\n' "$FMUX_CONF"; exit 0 ;;
        *)
            echo "usage: fmux config [list|get|source|set|unset|path]" >&2; exit 1 ;;
    esac
fi
```

- [ ] **Step 4: Remove the minimal CLI added in Task 2**

Delete the whole `if [ "${1:-}" = "config" ] && { … }` block at the end of `src/05-config.sh`.
If two places handle the same subcommand, the earlier file wins and 85's code never runs.

- [ ] **Step 5: Add to Makefile SRC**

```make
      src/80-view.sh \
      src/85-config-cli.sh \
      src/90-main.sh
```

Add to the comment too:

```
#   85-config-cli.sh config CLI — validation, atomic writes, fmux config subcommands
```

- [ ] **Step 6: Confirm the tests pass**

```bash
make && ./test/run.sh
```

Expected: `t-01` and `t-02` all `ok`.

- [ ] **Step 7: Commit**

```bash
make check
git add src/05-config.sh src/85-config-cli.sh Makefile bin/fmux test/t-02-config-cli.sh
git commit -m "feat: fmux config CLI — validation, conflict detection, atomic writes"
```

---

### Task 4: Wire up feature switches (rc / snapshot / boot_restore)

**Files:**
- Modify: `src/60-rc.sh:75` (early return before the rc step, inside the `--cron` entry point)
- Modify: `src/60-rc.sh:147` (top of the `--rc` entry point)
- Modify: `src/70-fleet.sh:25` (top of the `--snapshot` entry point)
- Modify: `src/70-fleet.sh:327` (top of the `--boot-restore` entry point)
- Test: `test/t-03-switches.sh`

**Interfaces:**
- Consumes: `fmux_conf_on` (Task 2)
- Produces: none (behavior change only)

- [ ] **Step 1: Write a failing test**

`test/t-03-switches.sh`:

```bash
#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
fmux_test_sandbox

CONF="$XDG_CONFIG_HOME/fleetmux/config"
mkdir -p "$(dirname "$CONF")"

# should succeed quietly with switches off, even with no tmux or no server.
printf 'rc=off\nsnapshot=off\nboot_restore=off\n' > "$CONF"

assert_rc 0 "$FMUXBIN" --cron
assert_rc 0 "$FMUXBIN" --rc
assert_rc 0 "$FMUXBIN" --boot-restore --dry

out=$("$FMUXBIN" --snapshot 2>&1) || true
assert_contains "$out" "snapshot=off" "says so when the snapshot switch is off"

# no manifest is written while it's off
assert_rc 1 test -f "$HOME/.cache/fmux/manifest"

fmux_test_done
```

- [ ] **Step 2: Confirm it fails**

```bash
./test/run.sh
```

Expected: `t-03` fails (there's no switch yet, so it either fails calling tmux with rc≠0, or writes the manifest anyway).

- [ ] **Step 3: Wire the switch into `--cron` and `--rc`**

`--cron` already does two things: runs an rc-recovery pass, and at the end calls
`--snapshot` (`src/60-rc.sh:142` — `[ -n "$only" ] || "$SELF" --snapshot >/dev/null 2>&1 || true`).
**Because they need independent off switches, two spots need to change.**

First, right after `if [ "${1:-}" = "--cron" ] || [ "${1:-}" = "--rc-check" ]; then`
(line 75), insert the rc switch. Note that `exit 0` here would also kill the snapshot
at the end, so **it skips, it doesn't exit**:

```bash
    fmux_rc_enabled=1
    fmux_conf_on rc || fmux_rc_enabled=0     # even with rc=off, the snapshot below must still run
```

Then, right before the `while read -r sid name; do` loop (line 84) that runs the rc
pass, add one line:

```bash
    if [ "$fmux_rc_enabled" = 1 ]; then
```

Close it right where the loop ends (**before** the `--snapshot` call at line 142):

```bash
    fi
    fmux_conf_on snapshot && { [ -n "$only" ] || "$SELF" --snapshot >/dev/null 2>&1 || true; }
```

> Why wrap with `if` instead of just changing indentation: exiting via `exit 0` would
> drop the snapshot entirely from that cron tick. `rc` and `snapshot` are independent
> switches, so one being off must not stop the other from running.

Insert this right after `if [ "${1:-}" = "--rc"; then` (line 147) in `src/60-rc.sh`:

```bash
    fmux_conf_on rc || { echo "rc=off — auto-recovery is off (fmux config set rc on)"; exit 0; }
```

- [ ] **Step 4: Wire the switch into `--snapshot` and `--boot-restore`**

Right after `if [ "${1:-}" = "--snapshot" ]; then` in `src/70-fleet.sh`:

```bash
    fmux_conf_on snapshot || { echo "snapshot=off — not recording (fmux config set snapshot on)"; exit 0; }
```

Right after `if [ "${1:-}" = "--boot-restore" ]; then` in `src/70-fleet.sh`:

```bash
    fmux_conf_on boot_restore || { echo "boot_restore=off — skipping boot restore"; exit 0; }
```

- [ ] **Step 5: Confirm the tests pass**

```bash
make && ./test/run.sh
```

Expected: `t-03` all `ok`.

- [ ] **Step 6: Confirm by hand that behavior is unchanged when the switches are on**

```bash
fmux config set snapshot on
fmux --snapshot
fmux config              # check snapshot shows as on/file
```

Expected: `snapshot: N sessions → …` prints exactly as it always did.

- [ ] **Step 7: Commit**

```bash
make check
git add src/60-rc.sh src/70-fleet.sh bin/fmux test/t-03-switches.sh
git commit -m "feat: make rc, snapshot, boot_restore configurable off switches"
```

---

### Task 5: Wire up thresholds and color

**Files:**
- Modify: `src/80-view.sh:208` (`21600` → `recent_hours`)
- Modify: `src/50-hook.sh:168` (`600` → `unseen_minutes`)
- Modify: `src/80-view.sh:166`, `src/90-main.sh:169` (`38;5;73` → `accent`)
- Modify: `src/10-util.sh:21` (route `FMUX_LOG_MAX` through config)
- Test: `test/t-04-tunables.sh`

**Interfaces:**
- Consumes: `fmux_conf_get` (Task 2)
- Produces: none (behavior change only)

- [ ] **Step 1: Write a failing test**

`test/t-04-tunables.sh`:

```bash
#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
fmux_test_sandbox

CONF="$XDG_CONFIG_HOME/fleetmux/config"
mkdir -p "$(dirname "$CONF")"

# changing accent should follow through to the color code in --help output
# (a surface observable even without tmux)
printf 'accent=200\n' > "$CONF"
assert_contains "$("$FMUXBIN" --help 2>&1)" $'\033[38;5;200m' "accent reflects in --help color"

printf 'accent=73\n' > "$CONF"
assert_contains "$("$FMUXBIN" --help 2>&1)" $'\033[38;5;73m' "the default accent still works too"

# log_max should be readable through config
printf 'log_max=4096\n' > "$CONF"
assert_eq "$("$FMUXBIN" config get log_max)" "4096" "log_max reads from config"
# backward compat — the env var still wins
assert_eq "$(FMUX_LOG_MAX=999 "$FMUXBIN" config get log_max)" "999" "FMUX_LOG_MAX env var wins"

fmux_test_done
```

- [ ] **Step 2: Confirm it fails**

```bash
./test/run.sh
```

Expected: the two accent-related lines fail (color is fixed at 73).

- [ ] **Step 3: Route color through config**

Change `src/90-main.sh:169` to this:

```bash
    FMUX_ACCENT_N=$(fmux_conf_get accent)
    T=$'\033[38;5;'"$FMUX_ACCENT_N"'m'; D=$'\033[2m'; R=$'\033[0m'; B=$'\033[1m'
```

In the `printf` at `src/80-view.sh:166`, replace the literal `38;5;73` with a variable.
Read it once at the start of the `--list` entry point in the same file:

```bash
    acc=$(fmux_conf_get accent)
```

And change the printf to:

```bash
                printf '%s\t\033[38;5;%sm%s\033[0m \033[36m%s\033[0m\n' "$name" "$acc" "$name" "$attached"
```

- [ ] **Step 4: Route thresholds through config**

Near `src/80-view.sh:208`, change the comparison using `21600` like this (compute once,
earlier in the same entry point):

```bash
    recent_s=$(( $(fmux_conf_get recent_hours) * 3600 ))
```

```bash
            if [ $(( now - ts )) -lt "$recent_s" ]; then
```

Change the `-le 600` in `src/50-hook.sh:168` like this (compute once, earlier in the
`--status` entry point):

```bash
    unseen_s=$(( $(fmux_conf_get unseen_minutes) * 60 ))
```

```bash
            [ $(( now - ts )) -le "$unseen_s" ] && out="$out ✓$name"   # status bar honors unseen_minutes only
```

- [ ] **Step 5: Route `FMUX_LOG_MAX` through config**

Change `src/10-util.sh:21` to this (the env-var priority is already handled by
`fmux_conf_get`):

```bash
FMUX_LOG_MAX=$(fmux_conf_get log_max)
```

`FMUX_LOG_KEEP` isn't a config key, so leave it as is.

> Note: `10-util.sh` is concatenated after `05-config.sh` (Task 2 put it in that SRC
> order). Get the order wrong and it dies with `fmux_conf_get: command not found`. This
> isn't caught by `bash -n` before `make verify` — you have to actually run it to
> confirm.

- [ ] **Step 6: Test and confirm for real**

```bash
make && ./test/run.sh
fmux config set accent 200 && fmux --list | head -3   # see the color change with your own eyes
fmux config unset accent
```

- [ ] **Step 7: Commit**

```bash
make check
git add src/10-util.sh src/50-hook.sh src/80-view.sh src/90-main.sh bin/fmux test/t-04-tunables.sh
git commit -m "feat: make thresholds and accent color configurable"
```

---

### Task 6: Generate the tmux snippet (`fmux --tmux-conf`) — summon key and exit snapshot

**Files:**
- Create: `src/87-tmux-conf.sh`
- Modify: `Makefile` (insert `src/87-tmux-conf.sh` into SRC right after `85-config-cli.sh`, plus a comment)
- Modify: `src/85-config-cli.sh` (call the snippet-regeneration hook after a successful `set`/`unset`)
- Test: `test/t-05-tmux-conf.sh`

**Interfaces:**
- Consumes: `fmux_conf_get`, `fmux_conf_on` (Task 2), `SELFQ` (00-header.sh)
- Produces:
  - `FMUX_TMUX_CONF` — the snippet file's absolute path (`$FMUX_CONF_DIR/tmux.conf`)
  - `fmux_tmux_conf_render` — prints the snippet contents to stdout
  - `fmux_tmux_conf_write` — writes the snippet atomically. Reflects immediately via `source-file` if inside tmux
  - CLI: `fmux --tmux-conf` (render to stdout) / `fmux --tmux-conf --write` (write the file)

- [ ] **Step 1: Write a failing test**

`test/t-05-tmux-conf.sh`:

```bash
#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
fmux_test_sandbox

CONF="$XDG_CONFIG_HOME/fleetmux/config"
SNIP="$XDG_CONFIG_HOME/fleetmux/tmux.conf"
mkdir -p "$(dirname "$CONF")"

# ① default — only the prefix key is bound, no prefix-less binding
out=$("$FMUXBIN" --tmux-conf)
assert_contains "$out" "bind F " "the default summon key F appears as a prefix binding"
case "$out" in *"bind -n"*) printf '  FAIL default has a prefix-less binding\n'; FMUX_FAIL=$((FMUX_FAIL+1)) ;;
    *) printf '  ok   default has no prefix-less binding\n' ;; esac

# ② the exit-snapshot hooks are included
assert_contains "$out" "client-detached" "the client-detached hook is included"
assert_contains "$out" "session-closed"  "the session-closed hook is included"
assert_contains "$out" "run-shell -b"    "client-detached runs in the background"

# ③ setting the fast list produces a prefix-less binding per item
printf 'key_summon_fast=C-Left M-b\n' > "$CONF"
out=$("$FMUXBIN" --tmux-conf)
assert_contains "$out" "bind -n C-Left" "C-Left is bound prefix-less"
assert_contains "$out" "bind -n M-b"    "M-b is bound prefix-less"
assert_contains "$out" "unbind -n"      "unbind is also emitted for removed keys"

# ④ snapshot_on_exit=off drops the two hook lines
printf 'snapshot_on_exit=off\n' > "$CONF"
out=$("$FMUXBIN" --tmux-conf)
case "$out" in *client-detached*) printf '  FAIL hook still present when off\n'; FMUX_FAIL=$((FMUX_FAIL+1)) ;;
    *) printf '  ok   snapshot_on_exit=off drops the hook\n' ;; esac

# ⑤ --write creates the file
printf 'key_summon=T\n' > "$CONF"
assert_rc 0 "$FMUXBIN" --tmux-conf --write
assert_rc 0 test -f "$SNIP"
assert_contains "$(cat "$SNIP")" "bind T " "the written file has the changed key"

fmux_test_done
```

- [ ] **Step 2: Confirm it fails**

```bash
./test/run.sh
```

Expected: `t-05` fails entirely (`--tmux-conf` doesn't exist yet).

- [ ] **Step 3: Write the snippet generator**

`src/87-tmux-conf.sh`:

```bash
# ── tmux snippet ────────────────────────────────────────────────────────────
# fmux never edits the user's ~/.tmux.conf. It owns one file of its own and
# only borrows one `source-file` line in the user's config. Delete it and it
# leaves no trace — same philosophy as the shim.
FMUX_TMUX_CONF="$FMUX_CONF_DIR/tmux.conf"

# Candidate list for stripping prefix-less bindings left over from a previous
# version. tmux has no "vanishes automatically once removed from config" model —
# once a key is bound, it stays bound until the server dies.
FMUX_TMUX_UNBIND_CANDIDATES='C-Left M-Left M-b C-Right M-Right'

fmux_tmux_conf_render() {
    local popup="display-popup -E -w 85% -h 75% -b rounded -T ' tt ' $SELFQ --from '#S'"
    local k fast

    printf '# file generated by fleetmux — do not edit by hand. Changed via fmux config set …\n'
    printf '# your own config only needs this one line:  source-file %s\n\n' "$FMUX_TMUX_CONF"

    # strip prior-version prefix-less bindings first (fails silently if absent, which is fine)
    for k in $FMUX_TMUX_UNBIND_CANDIDATES; do
        printf 'unbind -n %s\n' "$k"
    done
    printf '\n'

    k=$(fmux_conf_get key_summon)
    [ -n "$k" ] && printf 'bind %s %s\n' "$k" "$popup"

    fast=$(fmux_conf_get key_summon_fast)
    for k in $fast; do
        printf 'bind -n %s %s\n' "$k" "$popup"
    done

    if fmux_conf_on snapshot_on_exit; then
        printf '\n# record one more time on exit.\n'
        # client-detached uses -b — a snapshot must never hold up someone who's leaving.
        printf "set-hook -g client-detached 'run-shell -b \"%s --snapshot >/dev/null 2>&1\"'\n" "$SELF"
        # session-closed is synchronous — the server is going down, so backgrounding it
        # risks vanishing before it runs.
        printf "set-hook -g session-closed 'run-shell \"%s --snapshot >/dev/null 2>&1\"'\n" "$SELF"
    fi
}

fmux_tmux_conf_write() {
    local tmp
    mkdir -p "$FMUX_CONF_DIR" 2>/dev/null || true
    tmp="$FMUX_TMUX_CONF.tmp.$$"
    fmux_tmux_conf_render > "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$FMUX_TMUX_CONF" || { rm -f "$tmp"; return 1; }
    # if inside tmux, reflect immediately. otherwise, source-file picks it up next tmux start.
    [ -n "${TMUX:-}" ] && tmux source-file "$FMUX_TMUX_CONF" 2>/dev/null
    return 0
}

if [ "${1:-}" = "--tmux-conf" ]; then
    if [ "${2:-}" = "--write" ]; then
        fmux_tmux_conf_write || { echo "can't write snippet: $FMUX_TMUX_CONF" >&2; exit 1; }
        printf '%s\n' "$FMUX_TMUX_CONF"
    else
        fmux_tmux_conf_render
    fi
    exit 0
fi
```

- [ ] **Step 4: Make `config set` auto-refresh the snippet**

In the `set`/`unset` branches of `src/85-config-cli.sh`, add this right after `fmux_conf_write`
succeeds:

```bash
            case "$k" in key_summon|key_summon_fast) "$SELF" --tmux-conf --write >/dev/null 2>&1 || true ;; esac
            case "$k" in snapshot_on_exit) "$SELF" --tmux-conf --write >/dev/null 2>&1 || true ;; esac
```

In the `unset` branch, check `$3` instead of `$k`.

> Why it re-invokes itself: the snippet-render function lives in `87-tmux-conf.sh`,
> which is concatenated after `85`. Following the `$SELF` re-invocation convention
> already used in some 20 other spots is safer than reversing file order.

- [ ] **Step 5: Makefile SRC and tests**

```make
      src/85-config-cli.sh \
      src/87-tmux-conf.sh \
      src/90-main.sh
```

```bash
make && ./test/run.sh
```

Expected: `t-05` all `ok`.

- [ ] **Step 6: Confirm for real (non-destructive)**

```bash
fmux --tmux-conf            # prints to screen only — never touches a file
```

Expected: `bind F …` and the two exit-snapshot hook lines appear.

- [ ] **Step 7: Commit**

```bash
make check
git add src/85-config-cli.sh src/87-tmux-conf.sh Makefile bin/fmux test/t-05-tmux-conf.sh
git commit -m "feat: generate tmux snippet — summon key, fast-key list, exit snapshot"
```

---

### Task 7: Popup keybinding remapping and triple defense

**Files:**
- Modify: `src/90-main.sh:240-260` (route the literal fzf `--bind` strings through config)
- Test: `test/t-06-keys.sh`

**Interfaces:**
- Consumes: `fmux_conf_get` (Task 2), `fmux_conf_is_fzf_key` (Task 3)
- Produces: `fmux_key <action-key-name>` — prints the validated key name to stdout. If the configured value isn't an fzf key name, reverts to default and warns to stderr

- [ ] **Step 1: Write a failing test**

`test/t-06-keys.sh`:

```bash
#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
fmux_test_sandbox

CONF="$XDG_CONFIG_HOME/fleetmux/config"
mkdir -p "$(dirname "$CONF")"

# fmux_key lives inside fmux, so it's observed through a debug entry point --print-keys
assert_contains "$("$FMUXBIN" --print-keys)" "new=ctrl-n" "the default key appears"

printf 'key_new=ctrl-t\n' > "$CONF"
assert_contains "$("$FMUXBIN" --print-keys)" "new=ctrl-t" "the configured key is reflected"

# a hand-broken file — a name that fails validation reverts to default
printf 'key_new=ctrl-nonexistent\n' > "$CONF"
out=$("$FMUXBIN" --print-keys 2>&1)
assert_contains "$out" "new=ctrl-n" "an unknown key name reverts to default"
assert_contains "$out" "warn"       "warns that it reverted"

# reversion is per-key only — other keys keep their configured values
printf 'key_new=ctrl-nonexistent\nkey_kill=ctrl-y\n' > "$CONF"
out=$("$FMUXBIN" --print-keys 2>&1)
assert_contains "$out" "new=ctrl-n"  "only the broken key reverts"
assert_contains "$out" "kill=ctrl-y" "the intact key keeps its configured value"

fmux_test_done
```

- [ ] **Step 2: Confirm it fails**

```bash
./test/run.sh
```

Expected: `t-06` fails entirely (`--print-keys` doesn't exist).

- [ ] **Step 3: Write `fmux_key` and the debug entry point**

Add this **before** the block in `src/90-main.sh` that invokes fzf:

```bash
# Checks whether the configured key is a name fzf understands, and if not, reverts
# only that key to default. If this isn't caught here, fzf refuses to launch at all
# and the control tower doesn't come up — the worst failure this tool can have.
fmux_key() {
    local action="${1:-}" k def
    def=$(fmux_conf_default "key_$action") || return 1
    k=$(fmux_conf_get "key_$action")
    if fmux_conf_is_fzf_key "$k"; then printf '%s' "$k"; return 0; fi
    printf 'fleetmux warning: key_%s value "%s" is not a key name fzf understands — reverting to default %s\n' \
        "$action" "$k" "$def" >&2
    printf '%s' "$def"
}

if [ "${1:-}" = "--print-keys" ]; then
    for a in new rename kill reload detach broadcast help settings; do
        printf '%s=%s\n' "$a" "$(fmux_key "$a")"
    done
    exit 0
fi
```

- [ ] **Step 4: Route the fzf bindings through config**

Replace the literal `--bind` values at `src/90-main.sh:246-257` with this (only the key
name becomes a variable, the action string stays as-is):

```bash
          --bind "$(fmux_key help):execute($SELFQ --help </dev/tty >/dev/tty 2>&1; printf '  press any key to return' >/dev/tty; read -rsn1 </dev/tty)" \
          --bind 'right:accept' \
          --bind 'left:abort' \
          --bind "$(fmux_key reload):reload($SELFQ --list)" \
          --bind "$(fmux_key detach):execute-silent(tmux detach-client)+abort" \
          --bind "$(fmux_key new):execute($SELFQ --do-new </dev/tty >/dev/tty 2>&1)+clear-query+reload($SELFQ --list)" \
          --bind "$(fmux_key rename):execute($SELFQ --do-rename {1} </dev/tty >/dev/tty 2>&1)+clear-query+reload($SELFQ --list)" \
          --bind "$(fmux_key kill):execute($SELFQ --do-kill {1} </dev/tty >/dev/tty 2>&1)+reload($SELFQ --list)" \
          --bind "$(fmux_key broadcast):execute($SELFQ --do-broadcast {+1} </dev/tty >/dev/tty 2>&1)+deselect-all+clear-query") || exit 0
```

- [ ] **Step 5: Last-resort defense — retry with default bindings if fzf fails to launch**

The fzf call site (lines 242~257) stores the result in a `session` variable (`CUR` is
"the name of the session currently attached" — a different variable; don't confuse the
two). Move the whole call into a function and branch on rc.

In `src/90-main.sh`, wrap the whole statement starting with `session=$("$SELF" --list \`
in the function definition below:

```bash
# One fzf popup call. Returns the selection on stdout.
#   rc 0   picked something
#   rc 1   nothing matched
#   rc 2   fzf failed to launch — usually a bad key name in --bind
#   rc 130 the user exited with Esc/Ctrl-C
fmux_popup_fzf() {
    "$SELF" --list \
    | fzf --ansi --reverse --cycle --prompt='❯ ' --pointer='▶' --info=hidden --multi \
          ... (existing options unchanged, only --bind uses the fmux_key form from Step 4) ...
}
```

And change the call site to this:

```bash
rc=0
session=$(fmux_popup_fzf) || rc=$?
if [ "$rc" = 2 ]; then
    # fzf never even came up because of a configured key — retry once with defaults.
    # A control tower that fails to come up at all is the worst failure this tool can have.
    printf 'fleetmux warning: couldn'"'"'t launch the popup with the configured keys — launching with defaults (check fmux config)\n' >&2
    rc=0
    session=$(FMUX_KEYS_DEFAULT=1 fmux_popup_fzf) || rc=$?
fi
[ "$rc" = 0 ] || exit 0     # 1 (no match) and 130 (user cancelled) end quietly
```

Add a `FMUX_KEYS_DEFAULT` escape hatch to `fmux_key` (two lines added to the function
written in Step 3):

```bash
fmux_key() {
    local action="${1:-}" k def
    def=$(fmux_conf_default "key_$action") || return 1
    [ -n "${FMUX_KEYS_DEFAULT:-}" ] && { printf '%s' "$def"; return 0; }
    k=$(fmux_conf_get "key_$action")
    if fmux_conf_is_fzf_key "$k"; then printf '%s' "$k"; return 0; fi
    printf 'fleetmux warning: key_%s value "%s" is not a key name fzf understands — reverting to default %s\n' \
        "$action" "$k" "$def" >&2
    printf '%s' "$def"
}
```

- [ ] **Step 6: Test and confirm for real**

```bash
make && ./test/run.sh
fmux config set key_new ctrl-t
tmux new-session -d -s zz-keytest 'sleep 60'   # a zz prefix is excluded from the manifest
# open the popup and confirm with your own eyes that Ctrl-T opens a new session, then
tmux kill-session -t zz-keytest
fmux config unset key_new
```

- [ ] **Step 7: Commit**

```bash
make check
git add src/90-main.sh bin/fmux test/t-06-keys.sh
git commit -m "feat: popup keybinding remap — validation, per-key fallback, retry with defaults on launch failure"
```

---

### Task 8: In-popup settings screen

**Files:**
- Create: `src/86-config-view.sh`
- Modify: `Makefile` (insert `src/86-config-view.sh` into SRC after `85-config-cli.sh`, before `87-tmux-conf.sh`)
- Modify: `src/80-view.sh` (add a `⚙ settings` entry at the very end of `--list` output)
- Modify: `src/90-main.sh` (add the `fmux_key settings` binding; selecting the `⚙` entry opens the settings screen)
- Test: `test/t-07-config-view.sh`

**Interfaces:**
- Consumes: `fmux_conf_get`, `fmux_conf_source`, `FMUX_CONF_KEYS` (Task 2), `fmux_conf_validate` (Task 3)
- Produces:
  - `fmux --config-list` — prints one line per setting for the settings screen (`key<TAB>display string`)
  - `fmux --config-toggle <key>` — flips and saves if boolean, otherwise rc 2 (a signal that the caller needs to prompt for a value)
  - `fmux --config-view` — the fzf settings screen

- [ ] **Step 1: Write a failing test**

`test/t-07-config-view.sh`:

```bash
#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
fmux_test_sandbox

CONF="$XDG_CONFIG_HOME/fleetmux/config"
mkdir -p "$(dirname "$CONF")"

# the listing used by the settings screen
out=$("$FMUXBIN" --config-list)
assert_contains "$out" "rc" "rc is in the listing"
assert_contains "$out" "on" "the current value shows"

# boolean toggle
assert_rc 0 "$FMUXBIN" --config-toggle rc
assert_eq "$("$FMUXBIN" config get rc)" "off" "toggling flips the value"
assert_rc 0 "$FMUXBIN" --config-toggle rc
assert_eq "$("$FMUXBIN" config get rc)" "on" "toggling again flips it back"

# a non-boolean key is rc 2 (a signal that a value needs to be entered)
assert_rc 2 "$FMUXBIN" --config-toggle accent
assert_eq "$("$FMUXBIN" config get accent)" "73" "the value doesn't change when toggle fails"

# a settings entry is appended to the end of --list
assert_contains "$("$FMUXBIN" --list 2>/dev/null)" "settings" "a settings entry appears at the end of the session list"

fmux_test_done
```

- [ ] **Step 2: Confirm it fails**

```bash
./test/run.sh
```

- [ ] **Step 3: Write the settings-screen backend**

`src/86-config-view.sh`:

```bash
# ── popup settings screen ──────────────────────────────────────────────────
# What each line carries: key<TAB>pretty display. fzf only forwards the first field.
fmux_conf_is_bool() {
    case "${1:-}" in rc|snapshot|snapshot_on_exit|boot_restore) return 0 ;; *) return 1 ;; esac
}

fmux_conf_desc() {
    case "${1:-}" in
        rc)               printf 'Remote Control auto-recovery' ;;
        snapshot)         printf 'record the fleet every minute' ;;
        snapshot_on_exit) printf 'record the fleet on exit' ;;
        boot_restore)     printf 'auto-restore on boot' ;;
        recent_hours)     printf 'threshold for bolding a name (hours)' ;;
        unseen_minutes)   printf 'status bar ✓ retention (minutes)' ;;
        accent)           printf 'accent color (256-color number)' ;;
        log_max)          printf 'log rotation threshold (bytes)' ;;
        key_summon)       printf 'popup summon (after prefix)' ;;
        key_summon_fast)  printf 'popup summon (prefix-less, space-separated list)' ;;
        key_*)            printf 'keybinding' ;;
        *)                printf '' ;;
    esac
}

if [ "${1:-}" = "--config-list" ]; then
    for k in $FMUX_CONF_KEYS; do
        v=$(fmux_conf_get "$k")
        [ -n "$v" ] || v='(none)'
        printf '%s\t%-18s %-14s %s\n' "$k" "$k" "$v" "$(fmux_conf_desc "$k")"
    done
    exit 0
fi

if [ "${1:-}" = "--config-toggle" ]; then
    k="${2:-}"
    fmux_conf_default "$k" >/dev/null 2>&1 || { echo "unknown key: $k" >&2; exit 1; }
    fmux_conf_is_bool "$k" || exit 2          # not boolean → the caller needs to prompt for a value
    if fmux_conf_on "$k"; then nv=off; else nv=on; fi
    "$SELF" config set "$k" "$nv" >/dev/null || exit 1
    exit 0
fi

if [ "${1:-}" = "--config-view" ]; then
    while :; do
        sel=$(fmux_conf_view_once) || break
        [ -n "$sel" ] || break
    done
    exit 0
fi

# One draw, one pick. Enter toggles or prompts for a value, Esc exits.
fmux_conf_view_once() {
    local line k
    line=$("$SELF" --config-list | fzf --ansi --delimiter=$'\t' --with-nth=2 \
        --prompt='settings ' --header='Enter to change   Esc to go back' \
        --bind 'left:abort' --bind 'esc:abort') || return 1
    k=${line%%$'\t'*}
    [ -n "$k" ] || return 1
    if "$SELF" --config-toggle "$k"; then return 0; fi
    [ $? = 2 ] || return 0
    # not boolean — prompt for a value
    printf 'new value for %s (current: %s): ' "$k" "$("$SELF" config get "$k")" >/dev/tty
    IFS= read -r nv </dev/tty || return 0
    [ -n "$nv" ] || return 0
    "$SELF" config set "$k" "$nv" >/dev/tty 2>&1 || { printf '  (leaving it as is)\n' >/dev/tty; sleep 1; }
    return 0
}
```

> Functions must be defined before entry points reference them. Move the
> `fmux_conf_view_once` definition **above** the `--config-view` entry point in the code
> above.

- [ ] **Step 4: Append `⚙ settings` to the end of the session list — and plug three leaks**

`--list` output is consumed by three other places besides the popup list itself: the
preview (`--preview {1}`), broadcast-target collection, and the empty-list bootstrap
check. Leaking one extra row into any of those makes them misbehave silently.

First, in `src/80-view.sh`, add this as the last line of `--list` output, after all the
tool sessions have already been printed:

```bash
    printf '%s\t%s\n' '--settings--' $'\033[2m⚙ settings\033[0m'
```

Then plug the leaks.

① Preview — at the very top of the `--preview` entry point at `src/90-main.sh:69`:

```bash
    if [ "${2:-}" = "--settings--" ]; then "$SELF" config; exit 0; fi   # show current config when the settings row is selected
```

② Broadcast target collection — right before `targets+=("${line%%$'\t'*}")`:

```bash
        case "${line%%$'\t'*}" in '--settings--') continue ;; esac      # never send a prompt to the settings row
```

③ Empty-list bootstrap — `if [ -z "$("$SELF" --list)" ]; then` (line 228) is now never
empty because of the settings row. Exclude it from that check:

```bash
if [ -z "$("$SELF" --list | grep -v '^--settings--	' || true)" ]; then
```

- [ ] **Step 5: Wire up the two entry paths in the popup**

Add one line to the fzf bindings in `src/90-main.sh` (the list moved into `fmux_popup_fzf`
in Step 4 of the previous task):

```bash
          --bind "$(fmux_key settings):execute($SELFQ --config-view </dev/tty >/dev/tty 2>&1)+reload($SELFQ --list)" \
```

Then, right **after** `session=$(printf '%s\n' "$session" | grep -v '^─' || true)`
(line 259), and **before** counting the number of multi-selections, insert:

```bash
# the settings row was picked — open the settings screen instead of entering a session,
# and return to the list once it's closed.
if [ "${session%%$'\t'*}" = '--settings--' ]; then
    "$SELF" --config-view
    exec "$SELF" --from "$CUR"
fi
```

> Don't confuse `session` and `CUR`. `session` is the line fzf returned as the
> selection; `CUR` is the name of the currently attached session (the value received
> via `--from`).

- [ ] **Step 6: Test and confirm for real**

```bash
make && ./test/run.sh
fmux --config-list | head -5
# open the popup and confirm with your own eyes that Ctrl-O opens the settings screen,
# and Esc returns to the list
```

- [ ] **Step 7: Commit**

```bash
make check
git add src/80-view.sh src/86-config-view.sh src/90-main.sh Makefile bin/fmux test/t-07-config-view.sh
git commit -m "feat: in-popup settings screen — toggle, value entry, two entry paths"
```

---

---

### Task 9: Ship an agent-facing skill (`skills/fleetmux/SKILL.md`)

fmux already knows session state through hooks. This task opens that knowledge up to
**the agent itself.** The same fact a human sees by opening the popup, the claude
inside a session gets to read with one command.

This differs from the old screen-scraping approach (capturing another session's
screen with `capture-pane` and reading it visually) — that's a path fmux tried and
abandoned three times (the "working" indicator has multiple shapes, an idle session's
status bar keeps flickering so its hash keeps changing, and merely attaching re-wraps
the pane and changes it again). The skill follows the same discipline:
**hook state is the fact, the screen is a reference.**

**Files:**
- Create: `skills/fleetmux/SKILL.md`
- Test: `test/t-08-skill.sh`

**Interfaces:**
- Consumes: `fmux --list`, `fmux --status`, `fmux --preview` (existing CLI, unchanged), `~/.cache/fmux/hook-*`
- Produces: a file copied to `~/.claude/skills/fleetmux/SKILL.md` at install time. No code changes

- [ ] **Step 1: Write a failing test**

`test/t-08-skill.sh`:

```bash
#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
fmux_test_sandbox
cd "$(dirname "$0")/.." || exit 1

S=skills/fleetmux/SKILL.md
assert_rc 0 test -f "$S"

# needs frontmatter to be recognized as a skill
assert_eq "$(head -1 "$S")" "---" "starts with frontmatter"
assert_contains "$(sed -n '1,6p' "$S")" "name: fleetmux" "has a name field"
assert_contains "$(sed -n '1,6p' "$S")" "description:" "has a description field"

# the commands the skill points to must be real entry points
for cmd in -- --list --status --preview; do
    case "$cmd" in --) continue ;; esac
    assert_contains "$(cat "$S")" "tt $cmd" "the skill mentions tt $cmd"
    assert_contains "$(cat src/*.sh)" "\"\${1:-}\" = \"$cmd\"" "the $cmd entry point actually exists"
done

# write operations must be documented as requiring confirmation
assert_contains "$(cat "$S")" "--do-broadcast" "mentions broadcasting"
assert_contains "$(cat "$S")" "read-only" "states that read-only is the default"

fmux_test_done
```

- [ ] **Step 2: Confirm it fails**

```bash
./test/run.sh
```

Expected: `t-08` fails from the first line (the file doesn't exist).

- [ ] **Step 3: Write the skill**

`skills/fleetmux/SKILL.md` (written in English, matching the repo's language):

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
fmux --status     # one line: "⏸2 ✻3" — waiting for you / working right now, plus ✓name badges
fmux --list       # one row per session: name, marks, last activity
```

Marks: `●` attached · `✻` working · `⏸` awaiting your approval · `✓` finished while you were away
· `⊘` remote control dropped.

**`⏸` is the one that matters.** It means a session is blocked on a human — permission prompt,
plan approval, a question. Surface those first, before anything else.

## One session in detail

```bash
fmux --preview <session-name>    # tail of that pane — the bottom is where the prompt lives
```

Use this only after the state told you which session is interesting. It is a rendering: quote it
as evidence, never as the state itself.

## Raw state, if you need it

```bash
cat ~/.cache/fmux/hook-<tmux-session-id>   # "<state> <unix-ts> <agent-pid>"
cat ~/.cache/fmux/manifest                 # name, cwd, kind, command, conversation id
```

`~/.cache/fmux/hook.log` is an append-only audit trail of every state transition — useful for
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

Then merge. `fmux --status` already gives you the tally, so the subagents only fill in the "why".

## Writing into other sessions

This skill is **read-only** by default. Sending text into another agent's session interrupts
whatever it is doing and cannot be undone.

If — and only if — the human explicitly asks to send something:

```bash
fmux --do-broadcast <name> [<name>...]    # prompts, then sends to each
```

Confirm the exact target list with the human first. Never broadcast to tool sessions (shells,
`btop`, `lazydocker`); a prompt typed into a shell runs as a command. fmux skips them, but say
out loud which sessions you are about to touch.

## When tt is not installed

If `tt` is not on PATH, say so and stop. Do not fall back to scraping panes — that is the exact
guesswork this tool exists to remove.
```

- [ ] **Step 4: Confirm the test passes**

```bash
./test/run.sh
```

Expected: `t-08` all `ok`.

- [ ] **Step 5: Try it for real**

```bash
mkdir -p ~/.claude/skills/fleetmux
cp skills/fleetmux/SKILL.md ~/.claude/skills/fleetmux/SKILL.md
```

In a new claude session, ask "what are the other sessions doing?" and confirm the
skill fires and calls `fmux --status` first.

> Install automation (having `install.sh` ask whether to lay down this directory) is
> covered in the **public-release plan**. The skill is Claude Code-only — codex has no
> concept of skills, so the README says so.

- [ ] **Step 6: Commit**

```bash
make check
git add skills/fleetmux/SKILL.md test/t-08-skill.sh
git commit -m "feat: agent-facing skill — read the fleet via hook state instead of the screen"
```

---

## Next plan (out of scope for this document)

- **Public release prep**: `install.sh` (check dependencies → call `make install` → place the shim → instruct the single `source-file` line → choose a summon-key preset → ask whether to install the skill), the README's `Configuration` section, fixing the wrong libexec path in the README (`libexec/fleetmux` → `libexec/tt`), a macOS/WSL key table. Spun off into a separate plan document.
- **Verify `0.0.0.0:5432`**: unrelated to fmux, a Pi-operations matter. Under investigation in the LX-notes session.
