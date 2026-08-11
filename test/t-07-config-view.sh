#!/usr/bin/env bash
# In-popup settings screen — guards the backend entry points and the --list consumption site.
#
# What this test protects:
#   ① The --config-list contract — one line per key, current value, description, and an honest
#      "not wired" marker. (The point of the marker is not lying to a toggle, so it is also a
#      failure if a marker shows up on a key that IS wired.)
#   ② The --config-toggle contract — booleans flip with rc 0, everything else is rc 2, and an
#      unknown key is rc 1. Must also verify the value does not change on rc 2 (it is just a
#      signal for the caller to prompt for input).
#   ③ --list must have **no** settings row — every line that goes out to the list is a real tmux
#      session. (There used to be a trailing ⚙ row. Putting a non-session into the session list
#      cost six guard sites everywhere that consumes the list, and one of them — the empty-list
#      bootstrap check — actually broke. So the assertion was not deleted, it was flipped: now it
#      is a failure if that row is present.)
#   ④ Those guards must be gone for good, and the door to settings (^O) must still work.
#
# The fzf interactive screen is measured by putting a fake fzf ahead on PATH: it records to a file
# what went into fzf and how many times it was called. It cannot fake real keystrokes, but it can
# measure exactly "which screen did it go to" precisely.
set -u
. "$(dirname "$0")/lib.sh"
fmux_test_sandbox

CONF="$XDG_CONFIG_HOME/fleetmux/config"
mkdir -p "$(dirname "$CONF")"
SENT='--settings--'
TAB=$'\t'
# sed script that strips ANSI colour. \x1b is a GNU extension that does not work under macOS's
# stock sed — the shell substitutes a real ESC byte before handing it over.
FMUX_DEANSI=$'s/\033\\[[0-9;]*m//g'

# ── ⛔ PATH GUARD — this sits ahead of every other assertion in this file ──────────
# ③ below calls the real `--list`. If the code that puts a fake tmux ahead on PATH sits after that
# point, that stretch reaches for the developer machine's **real tmux server**. Today that is
# harmless because fmux_test_sandbox's double isolation (swapping TMUX_TMPDIR + unsetting TMUX) keeps
# it from finding the socket, but that is a defence that collapses the moment one env var leaks —
# this is the same family of bug that actually caused a kill-server incident in this repo, so the
# ordering is pinned down here.
# (No assertion changed here. Only the install site was moved up.)
#
# This fake only answers `tmux ls -F` — it hands back FMUX_FAKE_SESSIONS (a newline-separated list of
# session names) as the session list, as-is. If it is empty, that is "0 sessions". Every other
# subcommand is rc 1 — the same answer a machine with no server would give, so it does not weaken
# any assertion.
mkdir -p "$FMUXROOT/bin"
cat > "$FMUXROOT/bin/tmux" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FMUX_TMUX_LOG"
case "$1 ${2:-}" in
    "ls -F")
        case "$3" in
            *session_created*)
                i=0
                while IFS= read -r s; do
                    [ -n "$s" ] || continue
                    i=$((i + 1))
                    printf '$%s\t1700000000\t0\t-\t%s\n' "$i" "$s"
                done <<< "${FMUX_FAKE_SESSIONS:-}"
                exit 0 ;;
        esac ;;
esac
exit 1
SHIM
chmod +x "$FMUXROOT/bin/tmux"
export FMUX_TMUX_LOG="$FMUXROOT/tmux-calls.log"
: > "$FMUX_TMUX_LOG"
REALPATH_SAVED="$PATH"
export PATH="$FMUXROOT/bin:$PATH"

# ── ① --config-list ────────────────────────────────────────────────────────
: > "$CONF"
out=$("$FMUXBIN" --config-list)
plain=$(printf '%s\n' "$out" | sed "$FMUX_DEANSI")

assert_eq "$(printf '%s\n' "$plain" | grep -c .)" "19" "all 19 known keys come out, one per line"
assert_contains "$plain" "rc${TAB}rc " "field 1 is the key name"
assert_contains "$plain" "remote-control" "a description is attached"

# Field 1 is the value fzf hides and that we cut out ourselves — it must be exactly the key
first=$(printf '%s\n' "$out" | head -1); first=${first%%$'\t'*}
# The first row is the summon key — the screen is ordered by why someone opened it, and that is
# the row they came for. It used to be last.
assert_eq "$first" "key_summon_fast" "the tab-prefixed part of the first line is the bare key"

# The current value shows up — including a file value winning over the default
printf 'accent=99\n' > "$CONF"
plain=$("$FMUXBIN" --config-list | sed "$FMUX_DEANSI")
assert_contains "$plain" "accent             99" "a value written to the file shows up in the list"
: > "$CONF"
plain=$("$FMUXBIN" --config-list | sed "$FMUX_DEANSI")
assert_contains "$plain" "rc                 on" "the default shows up when there is no config"

# ── ①-b Is the "not wired" marker honest? ───────────────────────────────────────
# The set T4 wires (rc·snapshot·boot_restore), the set T6 wires into the tmux snippet
# (key_summon·key_summon_fast·snapshot_on_exit), and the four T5 wires
# (recent_hours·unseen_minutes·accent·log_max) must have no marker, and everything else must.
# Flipping this judgment means the settings screen would sell a toggle that "looks off but is not".
for k in rc snapshot boot_restore snapshot_on_exit key_summon key_summon_fast \
         recent_hours unseen_minutes accent log_max; do
    row=$(printf '%s\n' "$plain" | grep "^$k$TAB")
    case "$row" in *"not wired"*) got=yes ;; *) got=no ;; esac
    assert_eq "$got" "no" "$k is actually wired, so it carries no not-wired marker"
done
for k in key_new key_settings; do
    row=$(printf '%s\n' "$plain" | grep "^$k$TAB")
    case "$row" in *"not wired"*) got=yes ;; *) got=no ;; esac
    assert_eq "$got" "yes" "$k is not wired yet, so it carries the not-wired marker"
done
# The wiring judgment is grounded in the code itself — fmux_conf_wired scrapes "lookup calls that
# pass a literal key" straight out of the concatenated script. So wiring a new key makes this
# screen follow along automatically.
#   This count is the **watchdog** for that automatic judgment: the day key remapping (T7) wires
#   an eighth key, this must fail first — both "wired but the marker didn't update" and "not wired
#   but the marker vanished" both hinge on this one line.
assert_eq "$(printf '%s\n' "$plain" | grep -vc "not wired")" "11" "exactly 11 keys are wired right now"

# ── ② --config-toggle ──────────────────────────────────────────────────────
: > "$CONF"
assert_rc 0 "$FMUXBIN" --config-toggle rc
assert_eq "$("$FMUXBIN" config get rc)" "off" "the toggle flips the value"
assert_rc 0 "$FMUXBIN" --config-toggle rc
assert_eq "$("$FMUXBIN" config get rc)" "on" "toggling again flips it back"
assert_contains "$(cat "$CONF")" "rc=on" "the toggle is persisted to the config file"

# A non-boolean key is rc 2 — the signal "prompt for a value". The value itself is never touched.
assert_rc 2 "$FMUXBIN" --config-toggle accent
assert_eq "$("$FMUXBIN" config get accent)" "73" "the value does not change on rc 2"
assert_rc 2 "$FMUXBIN" --config-toggle key_new
case "$(cat "$CONF")" in *accent*|*key_new*) got=yes ;; *) got=no ;; esac
assert_eq "$got" "no" "rc 2 writes nothing to the config file"

# An unknown key or an empty key is rc 1, with a reason given
assert_rc 1 "$FMUXBIN" --config-toggle nope
assert_rc 1 "$FMUXBIN" --config-toggle
assert_contains "$("$FMUXBIN" --config-toggle nope 2>&1)" "unknown key" "an unknown key is reported as such"

# Toggling a key pinned by an env var only changes the file — the screen's value would not
# actually change — and that lie is blocked up front.
out=$(FMUX_RC=on "$FMUXBIN" --config-toggle rc 2>&1) || rc=$?
assert_eq "${rc:-0}" "1" "a key an env var wins over refuses the toggle"
assert_contains "$out" "FMUX_RC" "the rejection names that environment variable"

# log_max used to **always** hit this rejection — 10-util.sh set its own FMUX_LOG_MAX global, and
# since that name is exactly this key's environment variable name, it always read as "env wins"
# even with no real environment variable set. Threshold wiring (T5) removed that global. Now it
# behaves like any other value key — rc 2 (prompt for a value) — and is only rejected when a real
# environment variable is actually set.
assert_rc 2 "$FMUXBIN" --config-toggle log_max
assert_rc 1 env FMUX_LOG_MAX=4096 "$FMUXBIN" --config-toggle log_max
assert_contains "$(FMUX_LOG_MAX=4096 "$FMUXBIN" --config-toggle log_max 2>&1)" "FMUX_LOG_MAX" \
    "it only rejects and names the variable when a real environment variable is set"

# The config file is read exactly once per entry point (05-config.sh:53 contract) —
# --config-list calls fmux_conf_get/fmux_conf_source in a subshell per key, so breaking that contract
# would print the warning 36 times.
printf 'rc=on\nunknown_key=1\n' > "$CONF"
warn=$("$FMUXBIN" --config-list 2>&1 >/dev/null)
assert_eq "$(printf '%s\n' "$warn" | grep -c 'unknown key: unknown_key')" "1" \
    "--config-list looks the key up 36 times but warns only once"
warn=$("$FMUXBIN" --config-toggle rc 2>&1 >/dev/null)
assert_eq "$(printf '%s\n' "$warn" | grep -c 'unknown key: unknown_key')" "1" \
    "--config-toggle also warns only once"
: > "$CONF"

# ── ③ --list carries only sessions ────────────────────────────────────────
# (a) 0 sessions means an empty list. There used to be a trailing ⚙ row here, which broke the
#     bootstrap check that asked "is the list empty". Now empty means empty.
list=$(FMUX_FAKE_SESSIONS="" "$FMUXBIN" --list 2>/dev/null) || true
assert_eq "$list" "" "with 0 sessions, --list emits nothing"
case "$list" in *settings*) got=yes ;; *) got=no ;; esac
assert_eq "$got" "no" "no settings row in the list"
case "$list" in *⚙*) got=yes ;; *) got=no ;; esac
assert_eq "$got" "no" "no ⚙-painted row either"

# (b) ★regression guard — **every row in the list must be a real tmux session name.**
#   Injects a fake session list and diffs field 1 against it, one by one. If anyone ever leaks
#   another non-session row (settings, separator, ad banner, whatever) in here again, this catches
#   it — the moment that happens it needs a guard at all six sites consuming the list, and missing
#   even one leaves tt hunting for a session that is not there.
#   Deliberately mixes in an awkward name too — checking a space-containing name survives intact
#   as one row.
#   The old sentinel is deliberately NOT mixed into the injected names: doing so would let a
#   resurrected settings row pass the comparison by having the same name as an "injected session".
#   The regression has to be caught by the name comparison itself.
FAKE=$'alpha\nbra vo\nzulu'
list=$(FMUX_FAKE_SESSIONS="$FAKE" "$FMUXBIN" --list 2>/dev/null) || true
bad=""
while IFS= read -r line; do
    [ -n "$line" ] || continue
    nm=${line%%$'\t'*}
    case $'\n'"$FAKE"$'\n' in
        *$'\n'"$nm"$'\n'*) ;;
        *) bad="$bad[$nm]" ;;
    esac
done <<< "$list"
assert_eq "$bad" "" "★every row of --list is a real tmux session name"
assert_eq "$(printf '%s\n' "$list" | grep -c .)" "3" "the row count matches the session count exactly — no extra tagalong row"
assert_contains "$list" "bra vo" "a name with a space also stays intact as one row"

# (c) A **real session** with the same name as the old sentinel is now just an ordinary row — with
#     the reserved word gone, there is no special-casing either. It used to collide with the UI
#     row and become a session tt could neither kill nor rename.
list=$(FMUX_FAKE_SESSIONS="$SENT" "$FMUXBIN" --list 2>/dev/null) || true
assert_eq "${list%%$'\t'*}" "$SENT" "a session with that name also has field 1 as the plain name"
assert_eq "$(printf '%s\n' "$list" | grep -c .)" "1" "and it is exactly one row"

# ── ④ No guard remains ────────────────────────────────────────────────────
# The old sentinel string must be nowhere in the code. If even one remains, the special case "this
# is not a session" is still alive somewhere, and wherever that special case sits, a real session
# could be misjudged.
assert_eq "$(grep -c "FMUX_SETTINGS_ROW" "$FMUXBIN" || true)" "0" "the sentinel constant is gone from the code"
assert_eq "$(grep -c "fmux_name_reserved" "$FMUXBIN" || true)" "0" "the reserved-name judgment function is gone too"

# Preview: this name used to draw a settings table instead of tmux. Now it is just a session name
# and goes out via capture-pane — measured with the fake tmux, proving the special case is gone.
: > "$FMUX_TMUX_LOG"
out=$("$FMUXBIN" --preview "$SENT" 2>/dev/null) || true
case "$out" in *KEY*SOURCE*) got=yes ;; *) got=no ;; esac
assert_eq "$got" "no" "the preview no longer draws the settings table"
assert_contains "$(cat "$FMUX_TMUX_LOG")" "capture-pane" "it just goes to capture the pane of that session name"

# ── ④ Bootstrap — onboarding with 0 sessions, the picker with at least one ─────────
# This judgment was the most destructive regression site (the `grep -v` that filtered out the
# settings row lived here). Measured by driving the real popup: if the fake fzf was called, it
# leaked into the picker; if not, it went to bootstrap. Bootstrap's read opens /dev/tty, and
# detaching the controlling terminal with setsid makes that fail and exit quietly — so this does
# not hang even when a human runs make check.
cat > "$FMUXROOT/bin/fzf" <<'SHIM'
#!/usr/bin/env bash
n=$(cat "$FMUX_FZF_DIR/count" 2>/dev/null || echo 0); n=$((n + 1))
printf '%s' "$n" > "$FMUX_FZF_DIR/count"
printf '%s\n' "$@" > "$FMUX_FZF_DIR/argv.$n"   # also records bindings·footer (evidence the screen is wired)
cat > "$FMUX_FZF_DIR/in.$n"
# Pretends to pick only on the 1st call — so the flow makes exactly one loop and stops (no infinite reentry)
if [ "$n" = 1 ]; then
    case "${FMUX_FZF_PICK:-}" in
        multi) cat "$FMUX_FZF_DIR/in.$n" && exit 0 ;;   # pretend Tab picked everything
    esac
fi
exit 130
SHIM
chmod +x "$FMUXROOT/bin/fzf"
export FMUX_FZF_DIR="$FMUXROOT/fzf"
mkdir -p "$FMUX_FZF_DIR"
printf 'snapshot=off\n' > "$CONF"     # quiets the snapshot the popup fires off in the background

if command -v setsid >/dev/null 2>&1; then
    # (a) 0 sessions — the list is entirely empty. Must go to bootstrap, must not leak to fzf.
    rm -f "$FMUX_FZF_DIR/count"
    FMUX_FAKE_SESSIONS="" setsid "$FMUXBIN" --from "" </dev/null >/dev/null 2>&1 || true
    assert_eq "$(cat "$FMUX_FZF_DIR/count" 2>/dev/null || echo 0)" "0" \
        "with 0 sessions it goes to bootstrap"

    # (b) 1 session — the picker must come up now (the judgment did not over-filter)
    rm -f "$FMUX_FZF_DIR/count"
    FMUX_FAKE_SESSIONS="fmuxcv1" setsid "$FMUXBIN" --from "" </dev/null >/dev/null 2>&1 || true
    assert_eq "$(cat "$FMUX_FZF_DIR/count" 2>/dev/null || echo 0)" "1" \
        "the picker comes up as soon as there is at least one session"
    assert_contains "$(cat "$FMUX_FZF_DIR/in.1" 2>/dev/null || true)" "fmuxcv1" "that picker contains the session"
    case "$(cat "$FMUX_FZF_DIR/in.1" 2>/dev/null || true)" in *"$SENT"*) got=yes ;; *) got=no ;; esac
    assert_eq "$got" "no" "no settings row in that picker — only sessions go in"

    # (c) ★M2 — exactly one live session, and it is **the one currently attached**.
    #   The judgment is "is there at least one session at all", not "is there a row in the list":
    #   if CUR is set we were opened from inside a session, which proves one exists, so the picker
    #   comes up. (This used to matter more — the list dropped the attached session until
    #   2026-08-10, so a lone session made --list come back empty and the bootstrap fired while a
    #   session was plainly alive. The list keeps it now, but CUR is still the more direct proof.)
    #   (There used to be a `grep -v` filtering out the settings row right here, and that is what
    #   broke this judgment.)
    rm -f "$FMUX_FZF_DIR/count" "$FMUX_FZF_DIR"/in.*    # also clear in.* — must not pass on leftovers from the prior case
    FMUX_FAKE_SESSIONS="" setsid "$FMUXBIN" --from "cur1" </dev/null >/dev/null 2>&1 || true
    assert_eq "$(cat "$FMUX_FZF_DIR/count" 2>/dev/null || echo 0)" "1" \
        "★the picker comes up even when the only session is the attached one and the list is empty (does not leak to bootstrap)"
else
    printf '  --   no setsid — skipping the bootstrap judgment\n'
fi

# ── ⑤ The one door to settings is ^O — and it is actually open ────────────
# With the ⚙ row gone from the list, discoverability is the footer's job. Measures that the
# binding and the footer text come from the same value (if they drift apart, the screen teaches a
# key that does not exist), and that the key actually opens the settings screen.
rm -f "$FMUX_FZF_DIR/count" "$FMUX_FZF_DIR"/in.* "$FMUX_FZF_DIR"/argv.*
FMUX_FAKE_SESSIONS="fmuxcv1" "$FMUXBIN" --from "" </dev/null >/dev/null 2>&1 || true
argv=$(cat "$FMUX_FZF_DIR/argv.1" 2>/dev/null || true)
assert_contains "$argv" "ctrl-o:execute" "^O is actually bound in the popup"
assert_contains "$argv" "--config-view" "that binding opens the settings screen"
assert_contains "$argv" "? help · ^O settings" "the footer prints that key at the bottom of the screen"

# And --config-view still draws the settings list (fewer doors in, but the same screen).
rm -f "$FMUX_FZF_DIR/count" "$FMUX_FZF_DIR"/in.*
"$FMUXBIN" --config-view </dev/null >/dev/null 2>&1 || true
in1=$(cat "$FMUX_FZF_DIR/in.1" 2>/dev/null || true)
assert_contains "$in1" "not wired" "^O calls up the settings list"
assert_contains "$in1" "accent" "the settings list has the keys in it"
case "$in1" in *fmuxcv1*) got=yes ;; *) got=no ;; esac
assert_eq "$got" "no" "the settings screen is never mixed with the session list"

# ── ⑥ Tab multi-select → broadcast targets are exactly what was picked ────────
# There used to be a settings row tacked onto the end of the list that came in stamped along with
# the other sessions, and had to be filtered out again in the target-collection loop. Now that the
# list holds only sessions, whatever was picked IS the target set — no extras, no drops.
#   Faking fzf to pretend it picked the whole list means 2 sessions → count=2 → the broadcast path.
#   The targets line comes out on stdout first, and then it stops at the prompt.
if command -v setsid >/dev/null 2>&1; then
    rm -f "$FMUX_FZF_DIR/count" "$FMUX_FZF_DIR"/in.*
    out=$(FMUX_FAKE_SESSIONS=$'fmuxcv1\nfmuxcv2' FMUX_FZF_PICK=multi \
        setsid "$FMUXBIN" --from "" </dev/null 2>/dev/null) || true
    assert_contains "$out" "targets: fmuxcv1 fmuxcv2" "the picked sessions are exactly the broadcast targets"
    case "$out" in *"$SENT"*|*settings*) got=yes ;; *) got=no ;; esac
    assert_eq "$got" "no" "nothing non-session sneaks into the targets line"
fi

# ── ⑦ There is no reserved name anymore — '--settings--' is just a session name too ─────────
# This name used to be a reserved word. The settings row mixed into the list was judged by "field 1
# is --settings-- → not a session", so a real session with that name would trip every one of those
# guards (the preview drew the settings table, and ^X/^E refused it, leaving a session tt could
# neither kill nor rename).
# With the settings row gone, the basis for that misjudgment is gone too — so the assertions are
# not deleted, they are flipped: the three doors that take a name (^N·^E·the empty-list bootstrap)
# must now accept this name as a **plain, ordinary name**.
#
# All three of these doors read from /dev/tty (fmux_prompt·read -rp) — a pipe cannot drive them. A
# real pty is attached to fake it. script's syntax differs between Linux (util-linux) and macOS
# (BSD), so both are tried, and if neither works this is skipped (same discipline as setsid).
#   If the guard is broken and the prompt keeps waiting for more input, the pty never closes and
#   this hangs forever. A regression stalling all of make check is worse than just failing — so
#   ① enough input is fed to run all the way through even when the guard is absent, and ② timeout
#   wraps the run if it is available.
fmux_pty() {                      # fmux_pty <input-to-feed> <command-string>
    local run="$2"
    command -v timeout >/dev/null 2>&1 && run="timeout 10 $run"
    if [ "${FMUX_PTY:-}" = util-linux ]; then
        printf '%s' "$1" | script -qec "$run" /dev/null 2>&1
    else
        printf '%s' "$1" | script -q /dev/null /usr/bin/env bash -c "$run" 2>&1
    fi
}
FMUX_PTY=""
if command -v script >/dev/null 2>&1; then
    if printf 'x\n' | script -qec 'read -r c </dev/tty' /dev/null >/dev/null 2>&1; then
        FMUX_PTY=util-linux
    elif printf 'x\n' | script -q /dev/null /usr/bin/env bash -c 'read -r c </dev/tty' >/dev/null 2>&1; then
        FMUX_PTY=bsd
    fi
fi

if [ -n "$FMUX_PTY" ]; then
    FMUXQ="'${FMUXBIN//\'/\'\\\'\'}'"

    # (a) Giving that name via ^N just creates it, no rejection — feeds two lines (name, start command).
    : > "$FMUX_TMUX_LOG"
    out=$(fmux_pty "$SENT"$'\n\n' "$FMUXQ --do-new") || true
    case "$out" in *"reserved name"*) got=yes ;; *) got=no ;; esac
    assert_eq "$got" "no" "^N no longer rejects this name as a reserved word"
    case "$(cat "$FMUX_TMUX_LOG")" in *"new-session -d -s $SENT"*) got=yes ;; *) got=no ;; esac
    assert_eq "$got" "yes" "it just creates a session with that name"

    # (b) A normal name naturally still works too — the other side of the measurement
    : > "$FMUX_TMUX_LOG"
    fmux_pty $'fmuxok1\n\n' "$FMUXQ --do-new" >/dev/null 2>&1 || true
    case "$(cat "$FMUX_TMUX_LOG")" in *"new-session -d -s fmuxok1"*) got=yes ;; *) got=no ;; esac
    assert_eq "$got" "yes" "a normal name is also created as-is"

    # (c) ^E rename goes through the same way — no rejection, all the way to tmux
    : > "$FMUX_TMUX_LOG"
    out=$(fmux_pty "$SENT"$'\n' "$FMUXQ --do-rename fmuxcv1") || true
    case "$out" in *"reserved name"*) got=yes ;; *) got=no ;; esac
    assert_eq "$got" "no" "^E does not reject this name either"
    case "$(cat "$FMUX_TMUX_LOG")" in *"rename-session -t =fmuxcv1 $SENT"*) got=yes ;; *) got=no ;; esac
    assert_eq "$got" "yes" "the rename goes all the way to tmux"

    # (d) Picking a session with that name via ^X gets the usual confirm prompt, not "not a
    #     session". Answers n so it never reaches the real kill — just being asked proves the
    #     special case is gone.
    : > "$FMUX_TMUX_LOG"
    out=$(fmux_pty $'n\n' "$FMUXQ --do-kill $SENT") || true
    assert_contains "$out" "kill $SENT?" "^X treats that name as an ordinary session and asks to confirm"
    case "$out" in *"not a session"*) got=yes ;; *) got=no ;; esac
    assert_eq "$got" "no" "the special-case 'not a session' message is gone"
    case "$(cat "$FMUX_TMUX_LOG")" in *kill-session*) got=yes ;; *) got=no ;; esac
    assert_eq "$got" "no" "answering n means it never reaches kill"

    # (e) The empty-list bootstrap is the same door — the first session's name is taken here too
    : > "$FMUX_TMUX_LOG"
    export FMUX_FAKE_SESSIONS=""      # an assignment before a function call may not propagate to the child — export it explicitly
    out=$(fmux_pty "$SENT"$'\n' "$FMUXQ --from ''") || true
    case "$out" in *"reserved name"*) got=yes ;; *) got=no ;; esac
    assert_eq "$got" "no" "bootstrap does not reject it either"
    case "$(cat "$FMUX_TMUX_LOG")" in *"new-session -s $SENT"*) got=yes ;; *) got=no ;; esac
    assert_eq "$got" "yes" "the first session is created with exactly the name given"
else
    printf '  --   no script available to attach a pty — skipping this section\n'
fi

# ── ⑤ fzf refusing to start must not close the popup silently ────────────────
# Reported by a teammate on 2026-08-11: "Shift+Up, it flashes and disappears." That is what an
# fzf that cannot start looks like from the outside — it writes its complaint to the screen, the
# command ends, and tmux takes the popup down with the message still on it. Nothing reaches a log,
# because the only thing that failed wrote to a terminal that no longer exists.
#
# The cause was one character of error handling: `fzf … || exit 0`. Every non-zero code — an
# option this fzf has never heard of, a terminal it cannot drive — was treated exactly like Esc.
# So the fix is not about fzf at all; it is about telling "the user closed it" apart from "it
# never opened", and holding the popup open for the second kind.
#
# 1 (no match) and 130 (interrupt) stay silent: those are ordinary ways to leave the list.
FAILDIR="$FMUXROOT/fzfrc"; mkdir -p "$FAILDIR"
cat > "$FMUXROOT/bin/fzf" <<'SHIM'
#!/usr/bin/env bash
printf 'unknown option: --footer\n' >&2
exit "${FMUX_FAKE_FZF_RC:-2}"
SHIM
chmod +x "$FMUXROOT/bin/fzf"
export PATH="$FMUXROOT/bin:$REALPATH_SAVED"

run_popup() {            # run_popup <rc fzf should exit with> → what the user sees
    FMUX_FAKE_FZF_RC="$1" "$FMUXBIN" --from probe-session </dev/null 2>&1 || true
}

out=$(run_popup 2)
assert_contains "$out" "could not start" \
    "an fzf that refuses to start says so — the popup does not just vanish"
assert_contains "$out" "unknown option: --footer" \
    "fzf's own complaint survives to the screen, above our message"
assert_contains "$out" "0.64" \
    "the message names the version fmux needs, since that is the usual cause"

# Esc and empty-match are not errors. If these ever start printing the banner, every popup close
# would end with a wall of text — the opposite failure, and a much more annoying one.
for rc in 1 130; do
    out=$(run_popup "$rc")
    case "$out" in
        *"could not start"*)
            FMUX_RUN=$((FMUX_RUN + 1)); FMUX_FAIL=$((FMUX_FAIL + 1))
            printf '  FAIL rc %s is an ordinary close and must stay quiet\n' "$rc" ;;
        *)
            FMUX_RUN=$((FMUX_RUN + 1))
            printf '  ok   rc %s (ordinary close) stays quiet\n' "$rc" ;;
    esac
done

export PATH="$REALPATH_SAVED"
fmux_test_done
