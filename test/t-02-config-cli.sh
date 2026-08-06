#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
fmux_test_sandbox

CONF="$XDG_CONFIG_HOME/fleetmux/config"

# ① path gives the config file path (even if the file does not exist yet)
assert_eq "$("$FMUXBIN" config path)" "$CONF" "config path gives the path"

# ② set creates the file and writes the value
assert_rc 0 "$FMUXBIN" config set rc off
assert_eq "$("$FMUXBIN" config get rc)" "off" "the value set is read back"
assert_rc 0 test -f "$CONF"

# ③ invalid values are rejected — the file does not change either
assert_rc 1 "$FMUXBIN" config set rc maybe
assert_eq "$("$FMUXBIN" config get rc)" "off" "a rejected set does not change the file"
assert_rc 1 "$FMUXBIN" config set recent_hours abc
assert_rc 1 "$FMUXBIN" config set accent 999
assert_rc 1 "$FMUXBIN" config set nope 1

# ④ reserved keys refuse remapping
assert_rc 1 "$FMUXBIN" config set key_new esc
assert_rc 1 "$FMUXBIN" config set key_kill enter

# ⑤ key conflicts are rejected (key_rename already uses ctrl-e)
assert_rc 1 "$FMUXBIN" config set key_new ctrl-e
assert_contains "$("$FMUXBIN" config set key_new ctrl-e 2>&1)" "key_rename" "names the key it conflicts with"

# ⑥ preserves hand-written comments and line order
printf '# my comment\nrc=off\naccent=200\n' > "$CONF"
"$FMUXBIN" config set accent 100 >/dev/null
assert_contains "$(cat "$CONF")" "# my comment" "the comment survives"
assert_eq "$(head -2 "$CONF" | tail -1)" "rc=off" "line order is preserved"
assert_eq "$("$FMUXBIN" config get accent)" "100" "only the value changes"

# ⑦ unset reverts to the default
assert_rc 0 "$FMUXBIN" config unset accent
assert_eq "$("$FMUXBIN" config get accent)" "73" "unset reverts to the default value"

# ⑧ the list shows both value and source
out=$("$FMUXBIN" config)
assert_contains "$out" "rc" "rc appears in the list"
assert_contains "$out" "file" "the list shows the source"
assert_contains "$out" "key_summon" "key_summon appears in the list"

# ⑨ set's key-conflict check (the `for other in $FMUX_CONF_KEYS ... $(fmux_conf_get "$other")` loop
#    inside fmux_conf_validate) also forks a subshell per key — a malformed line here could also have
#    repeated its warning once per key. The single bare fmux_conf_load at the top of the `config`
#    entry point guards this path too, not just `list`.
cat > "$CONF" <<'EOF'
rc=off
unknown_key=1
EOF
_warn=$("$FMUXBIN" config set key_new ctrl-t 2>&1 >/dev/null)
_count=$(printf '%s\n' "$_warn" | grep -c "unknown key: unknown_key")
assert_eq "$_count" "1" "set's conflict-check loop also warns only once"

# ⑩ does not present a hand-edited invalid value as if it were the effective value (recommendation N4)
# `fmux config set` rejects invalid values, but the README also documents hand-editing the file as a
# normal path. A value that arrives through that path folds differently depending on the consumer —
# if the table does not disclose that, the two screens tell two different truths ("the config says
# 6h, so why doesn't it run every 6 hours?").
cat > "$CONF" <<'EOF'
recent_hours=6h
rc=maybe
key_summon=a/b
EOF
out=$("$FMUXBIN" config list 2>/dev/null)
assert_contains "$out" "invalid value" "invalid values get a marker attached"
assert_contains "$(printf '%s\n' "$out" | grep '^recent_hours ')" "falls back to default 1" \
    "numeric keys say they fold back to the default"
assert_contains "$(printf '%s\n' "$out" | grep '^rc ')" "falls back to off" \
    "boolean keys say they fold to off — not back to the default (on)"
assert_contains "$(printf '%s\n' "$out" | grep '^key_summon ')" "that key drops out of the snippet" \
    "summon keys say they drop out of the snippet"
# healthy values get no marker attached — otherwise the marker becomes noise
assert_eq "$(printf '%s\n' "$out" | grep -c '^snapshot .*invalid value' || true)" "0" "healthy values get no marker attached"
: > "$CONF"
assert_eq "$("$FMUXBIN" config list 2>/dev/null | grep -c 'invalid value' || true)" "0" \
    "a fresh install with only defaults has no invalid-value markers at all"

fmux_test_done
