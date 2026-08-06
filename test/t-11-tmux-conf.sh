#!/usr/bin/env bash
# tmux snippet generator — only checks the rendered result string.
# Real tmux is never called here: the machine this test runs on has a live fleet.
# lib.sh's sandbox unsets TMUX, so --write doesn't leak out through source-file either.
set -u
. "$(dirname "$0")/lib.sh"
tt_test_sandbox

CONF="$XDG_CONFIG_HOME/fleetmux/config"
SNIP="$XDG_CONFIG_HOME/fleetmux/tmux.conf"
mkdir -p "$(dirname "$CONF")"

# Helper that counts by line-start — "unbind -n" contains "bind -n" as a substring.
# Measuring the absence of a prefix-less binding with assert_contains would catch the unbind line
# and always pass (a false ok).
count_lines() { printf '%s\n' "$1" | grep -c "$2" || true; }

# ── ① Default — only the prefix binding appears, no prefix-less binding ──────
out=$("$TTBIN" --tmux-conf)
assert_contains "$out" "bind F " "the default summon key F comes out as a prefix binding"
assert_eq "$(count_lines "$out" '^bind -n ')" "0" "there is no prefix-less binding in the default"
assert_eq "$(count_lines "$out" '^bind F ')" "1" "the prefix binding is exactly one line"
assert_contains "$out" "$SNIP" "the header tells the path to source-file"

# ── ② Snapshot hooks on the way out ───────────────────────────────────────────
assert_contains "$out" "client-detached" "the client-detached hook is included"
assert_contains "$out" "session-closed"  "the session-closed hook is included"
# client-detached is -b (doesn't hold up the person leaving); session-closed is synchronous (the
# server is going down, so a background job would vanish before it runs). Each is measured separately.
assert_eq "$(count_lines "$out" '^set-hook -g client-detached .run-shell -b ')" "1" \
    "client-detached backgrounds via run-shell -b"
assert_eq "$(count_lines "$out" '^set-hook -g session-closed .run-shell \"')" "1" \
    "session-closed is synchronous, no -b"

# ── ③ Only steal the keys we bound (gate B3) ──────────────────────────────────
# The default (safe) preset is fmux binding no key at all. Even so, emitting an unbind would mean
# **we're erasing a binding someone else set up** — a direct contradiction of the README's "steals
# no key until you say so." The old version unconditionally walked a static candidate list
# (C-Left M-Left M-b C-Right M-Right M-f). This line guards against that regression.
assert_eq "$(count_lines "$out" '^unbind ')" "0" "no key we didn't bind gets unbound — the default has 0 unbind lines"
for k in C-Left M-Left M-b C-Right M-Right M-f; do
    assert_eq "$(count_lines "$out" "^unbind .*$k\$")" "0" "the default doesn't unbind someone else's $k"
done

# A key we did bind dies with it too when removed from config — proven by "a bind -n line left
# over in the previous snippet."
printf 'key_summon_fast=M-b\n' > "$CONF"
"$TTBIN" --tmux-conf --write >/dev/null
assert_eq "$(grep -c '^bind -n M-b ' "$SNIP" || true)" "1" "binding it when asked works"
printf 'key_summon_fast=\n' > "$CONF"
"$TTBIN" --tmux-conf --write >/dev/null
assert_eq "$(grep -c '^bind -n ' "$SNIP" || true)" "0" "removing it when asked leaves nothing bound"
assert_eq "$(grep -c '^unbind -n -q M-b$' "$SNIP" || true)" "1" "the M-b we had bound gets unbound along with it"
assert_eq "$(grep -c '^unbind -n -q M-f$' "$SNIP" || true)" "0" "M-f, which we never bound, is not unbound"
rm -f "$SNIP" "$CONF"
out=$("$TTBIN" --tmux-conf)

# ── ④ Populating the fast list gives each entry a prefix-less binding ────────
printf 'key_summon_fast=C-Left M-b\n' > "$CONF"
out=$("$TTBIN" --tmux-conf)
assert_contains "$out" "bind -n C-Left " "C-Left gets bound prefix-less"
assert_contains "$out" "bind -n M-b "    "M-b gets bound prefix-less"
assert_eq "$(count_lines "$out" '^bind -n ')" "2" "only as many as the list count get bound"
assert_eq "$(count_lines "$out" '^bind F ')" "1" "the prefix key remains even with fast on"
# The unbind for a key must come before its bind, so reapplication stays idempotent
assert_eq "$(count_lines "$out" '^unbind .*C-Left$')" "1" "a key being bound is unbound first too"

# ── ④-b Does the generator accept the key (S-Left) the installer suggests? ───
# If the suggestion exists only in the preset name and the generator can't accept that value, the
# installer says "bound" while binding nothing. So this checks that it also passes value
# validation (tt_conf_is_tmux_key).
rm -f "$SNIP" "$CONF"
printf 'key_summon_fast=S-Left\n' > "$CONF"
out=$("$TTBIN" --tmux-conf)
assert_contains "$out" "bind -n S-Left " "S-Left gets bound prefix-less"
assert_eq "$(count_lines "$out" '^bind -n ')" "1" "only S-Left gets bound"
assert_eq "$(count_lines "$out" '^unbind -n -q S-Left$')" "1" "the key being bound is unbound first (idempotent reapplication)"
# When switching from an old key to S-Left, the old key's unbind must appear. tmux doesn't drop a
# binding just because the config line was deleted — without this unbind the old key would keep
# living on the server.
rm -f "$SNIP" "$CONF"
printf 'key_summon_fast=C-Left M-Left\n' > "$CONF"
"$TTBIN" --tmux-conf --write >/dev/null
assert_eq "$(grep -c '^bind -n ' "$SNIP" || true)" "2" "precondition: two old keys are bound first"
printf 'key_summon_fast=S-Left\n' > "$CONF"
"$TTBIN" --tmux-conf --write >/dev/null
assert_eq "$(grep -c '^bind -n S-Left ' "$SNIP" || true)" "1" "only the new key gets bound"
assert_eq "$(grep -c '^bind -n ' "$SNIP" || true)" "1" "the old keys are no longer bound"
assert_eq "$(grep -c '^unbind -n -q C-Left$' "$SNIP" || true)" "1" "the unbind for old key C-Left appears"
assert_eq "$(grep -c '^unbind -n -q M-Left$' "$SNIP" || true)" "1" "the unbind for old key M-Left appears"
rm -f "$SNIP" "$CONF"

# ── ⑤ Emptying key_summon removes the prefix binding ─────────────────────────
printf 'key_summon=\n' > "$CONF"
out=$("$TTBIN" --tmux-conf)
assert_eq "$(count_lines "$out" '^bind [A-Za-z]')" "0" "when key_summon is empty there is no prefix binding"

# ── ⑥ snapshot_on_exit=off drops the two hook lines ───────────────────────────
printf 'snapshot_on_exit=off\n' > "$CONF"
out=$("$TTBIN" --tmux-conf)
assert_eq "$(count_lines "$out" '^set-hook ')" "0" "with snapshot_on_exit=off the hooks are dropped"
assert_contains "$out" "bind F " "the summon key remains even with the hook off"

# ── ⑦ --write creates the file ────────────────────────────────────────────────
printf 'key_summon=T\n' > "$CONF"
assert_rc 0 test ! -e "$SNIP"
assert_rc 0 "$TTBIN" --tmux-conf --write
assert_rc 0 test -f "$SNIP"
assert_contains "$(cat "$SNIP")" "bind T " "the written file contains the changed key"
assert_eq "$("$TTBIN" --tmux-conf --write)" "$SNIP" "--write reports the path it wrote"
# No temp file is left behind (atomic write)
assert_eq "$(count_lines "$(ls "$(dirname "$SNIP")")" '^tmux\.conf\.tmp')" "0" "no temp file is left behind"

# ── ⑧ config set rewrites the snippet ─────────────────────────────────────────
"$TTBIN" config set key_summon G >/dev/null
assert_contains "$(cat "$SNIP")" "bind G " "changing key_summon refreshes the snippet"
"$TTBIN" config set key_summon_fast "M-Left" >/dev/null
assert_contains "$(cat "$SNIP")" "bind -n M-Left " "changing key_summon_fast refreshes the snippet"
"$TTBIN" config set snapshot_on_exit off >/dev/null
assert_eq "$(count_lines "$(cat "$SNIP")" '^set-hook ')" "0" "turning off snapshot_on_exit drops the hook from the snippet"
"$TTBIN" config unset snapshot_on_exit >/dev/null
assert_eq "$(count_lines "$(cat "$SNIP")" '^set-hook ')" "2" "unset refreshes the snippet too"

# Changing a key unrelated to the snippet doesn't break anything (a silent no-op reapplication
# doesn't taint rc)
assert_rc 0 "$TTBIN" config set accent 100

# ── ⑨ A hand-entered odd value doesn't leak into the snippet ─────────────────
# The parser filters the value's character set, but the renderer also double-checks the tmux key
# shape once more (defense in depth).
printf 'key_summon=a/b\n' > "$CONF"
out=$("$TTBIN" --tmux-conf 2>/dev/null)
assert_eq "$(count_lines "$out" '^bind a/b')" "0" "a value that isn't shaped like a key doesn't go out as a binding"

# ── ⑩ Doesn't apply to a live server without consent (gate B4) ───────────────
# Real tmux still never runs here either: a fake tmux that only records what it's told is placed
# at the front of PATH, and TMUX is set by hand to fake "we're inside tmux right now." With that in
# place, we measure via the log whether tmux source-file went out when the snippet is written.
#   Verdict: it must go out **only when the user's own config actually has a source-file line**.
#   The old version fired unconditionally even when ~/.tmux.conf didn't exist at all — just running
#   --write to eyeball the snippet changed someone else's server keys.
# Everything up to here (through ⑨) ran under tt_test_sandbox's sealed fake tmux. TMUX is empty, so
# --write must send nothing to a live server — the seal log pins that down.
assert_no_tmux_mutation "with TMUX empty, --write never calls tmux at all"
assert_eq "$(cat "$TT_TMUX_STUB_LOG")" "" "sections ①–⑨ never call tmux even once"

mkdir -p "$TTROOT/fakebin"
cat > "$TTROOT/fakebin/tmux" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TT_TMUX_LOG"
exit 0
SHIM
chmod +x "$TTROOT/fakebin/tmux"
export TT_TMUX_LOG="$TTROOT/tmux-calls.log"
export PATH="$TTROOT/fakebin:$PATH"
export TMUX="/fake/socket,0,0"
printf 'key_summon=F\n' > "$CONF"

: > "$TT_TMUX_LOG"
rm -f "$HOME/.tmux.conf"
"$TTBIN" --tmux-conf --write >/dev/null
assert_eq "$(cat "$TT_TMUX_LOG")" "" "no source-file is fired at the server of someone who hasn't wired us in"

# A substring match would pass right here — a broken, newline-less concatenated line (the shape of
# B1's damage) and a comment line are not "wired in."
: > "$TT_TMUX_LOG"
printf 'set -g mouse onsource-file %s\n# source-file %s\n' "$SNIP" "$SNIP" > "$HOME/.tmux.conf"
"$TTBIN" --tmux-conf --write >/dev/null
assert_eq "$(cat "$TT_TMUX_LOG")" "" "a broken line or a comment line doesn't count as wired"

: > "$TT_TMUX_LOG"
printf 'set -g mouse on\nsource-file %s\n' "$SNIP" > "$HOME/.tmux.conf"
"$TTBIN" --tmux-conf --write >/dev/null
assert_contains "$(cat "$TT_TMUX_LOG")" "source-file $SNIP" "someone who is wired in gets it applied to their server right there"

# ── ⑩-b A line written with a tilde counts as wired too (gate I1) ────────────
# This is exactly the shape README teaches: `source-file ~/.config/fleetmux/tmux.conf`. tmux
# handles this line normally, but if we only matched exact absolute paths, **exactly the person who
# followed the docs** would read as "not wired" → tt config set wouldn't apply to the live server
# while the screen still prints success, and re-running the installer would append yet another
# duplicate source line.
: > "$TT_TMUX_LOG"
printf 'set -g mouse on\nsource-file ~/.config/fleetmux/tmux.conf\n' > "$HOME/.tmux.conf"
assert_eq "$SNIP" "$HOME/.config/fleetmux/tmux.conf" "precondition: that tilde line points at our snippet"
"$TTBIN" --tmux-conf --write >/dev/null
assert_contains "$(cat "$TT_TMUX_LOG")" "source-file $SNIP" "a source-file line written with a tilde counts as wired too"

# But it must not expand unconditionally — ~other/… is **someone else's home**, not our line.
: > "$TT_TMUX_LOG"
printf 'source-file ~other/.config/fleetmux/tmux.conf\n' > "$HOME/.tmux.conf"
"$TTBIN" --tmux-conf --write >/dev/null
assert_eq "$(cat "$TT_TMUX_LOG")" "" "a ~other form (someone else's home) does not count as wired"

# Outside tmux, nothing is fired even if wired in (there's no server to send it to)
: > "$TT_TMUX_LOG"
TMUX='' "$TTBIN" --tmux-conf --write >/dev/null
assert_eq "$(cat "$TT_TMUX_LOG")" "" "outside tmux, no server is touched at all"
unset TMUX

tt_test_done
