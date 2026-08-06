#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
tt_test_sandbox

CONF="$XDG_CONFIG_HOME/fleetmux/config"
mkdir -p "$(dirname "$CONF")"

# ① No file → everything falls back to defaults
assert_eq "$("$TTBIN" config get rc)"             "on"      "rc defaults to on"
assert_eq "$("$TTBIN" config get recent_hours)"   "1"       "recent_hours defaults to 1"
assert_eq "$("$TTBIN" config get key_summon)"     "F"       "key_summon defaults to F"
assert_eq "$("$TTBIN" config get key_summon_fast)" ""       "key_summon_fast defaults to empty"
assert_eq "$("$TTBIN" config source rc)"          "default" "source is default"

# ② A value from the file beats the default
cat > "$CONF" <<'EOF'
# comments are ignored
rc=off

recent_hours=12
key_summon_fast=C-Left M-b
EOF
assert_eq "$("$TTBIN" config get rc)"              "off"          "the file beats the default"
assert_eq "$("$TTBIN" config get recent_hours)"    "12"           "numeric values are read too"
assert_eq "$("$TTBIN" config get key_summon_fast)" "C-Left M-b"   "a value with spaces (a list) is read"
assert_eq "$("$TTBIN" config source rc)"           "file"         "source is file"

# ③ env beats the file
assert_eq "$(TT_RC=on "$TTBIN" config get rc)"     "on"   "env beats the file"
assert_eq "$(TT_RC=on "$TTBIN" config source rc)"  "env"  "source is env"

# ④ Broken lines and unknown keys are ignored — the rest still survives
cat > "$CONF" <<'EOF'
rc=off
this = is a broken line
unknown_key=1
rm -rf $HOME
accent=200
EOF
assert_eq "$("$TTBIN" config get rc)"     "off"  "an earlier value survives even with a broken line present"
assert_eq "$("$TTBIN" config get accent)" "200"  "a value after a broken line survives too"
assert_contains "$("$TTBIN" config get rc 2>&1 >/dev/null)" "ignoring" "it warns that a line was ignored"
# And HOME must still be intact — the spot that would be gone had it been sourced
assert_rc 0 test -d "$HOME"

# ⑤ Asking for an unknown key is refused
assert_rc 1 "$TTBIN" config get nope

# ⑥ A line with no '=' warns too — it used to be swallowed silently (fix round 1, finding 2)
cat > "$CONF" <<'EOF'
rc=off
rm -rf $HOME
EOF
_warn=$("$TTBIN" config get rc 2>&1 >/dev/null)
assert_contains "$_warn" "not key=value shape" "a line with no '=' warns too"
assert_eq "$("$TTBIN" config get rc)" "off" "other values survive even with a line missing '='"

# ⑦ Looking up several keys in the same process still warns only once — it used to repeat the
#    same warning once per key looked up (fix round 1, finding 1). Count the occurrences directly
#    (mere presence would miss a regression).
#    `config get <key>` only takes a single key, so it forks a subshell only once and cannot
#    reproduce this scenario (fix round 2 finding) — the thing that actually forks one subshell
#    per key is `config` with no arguments (the listing). The list branch in 85-config-cli.sh walks
#    TT_CONF_KEYS and calls `$(tt_conf_get "$k")`/`$(tt_conf_source "$k")` in a fresh subshell per
#    key — if each subshell inherited a fresh TT_CONF_LOADED=0, it would re-parse the file and
#    repeat the warning every time.
cat > "$CONF" <<'EOF'
rc=off
accent=150
unknown_key=1
EOF
_warn=$("$TTBIN" config 2>&1 >/dev/null)
_count=$(printf '%s\n' "$_warn" | grep -c "unknown key: unknown_key")
assert_eq "$_count" "1" "the config listing also forks a subshell per key, but the warning still fires only once"

# ⑧ ★If the config file exists but **cannot be read**, fall back to defaults — do not die.
#    If tt_conf_load only checked with `-f`, it would pass the existence check and then the
#    redirect on `done < "$TT_CONF"` would fail, and 00-header's set -e would catch that and
#    **kill the whole process**. Hanging off that path are cron (every minute) and @reboot
#    (--boot-restore): one config file permission bit would halt fleet restore and rc recovery
#    with no reason left behind. The single letter `-r` blocks all of that.
if [ "$(id -u)" = 0 ]; then
    printf '  --   running as root — skipping the read-permission check (root reads even 0000)\n'
else
    printf 'rc=off\n' > "$CONF"
    chmod 000 "$CONF"
    assert_rc 0 "$TTBIN" config get rc
    assert_eq "$("$TTBIN" config get rc 2>/dev/null)" "on" \
        "★an unreadable config file folds back to the default (on, not the off it would have gotten by parsing)"
    assert_eq "$("$TTBIN" config source rc 2>/dev/null)" "default" "source honestly reports default too"
    # The listing / CLI entry point must survive too — if this dies, the whole config screen never opens
    assert_rc 0 "$TTBIN" config
    chmod 644 "$CONF"
    assert_eq "$("$TTBIN" config get rc)" "off" "restoring permissions reads the file value again (the guard does not just ignore the file forever)"
    : > "$CONF"
fi

tt_test_done
