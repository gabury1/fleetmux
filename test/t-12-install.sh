#!/usr/bin/env bash
# install.sh — only runs under a fake HOME and fake PATH.
#
# ⛔ Never calls the real tmux. This machine has a live fleet running on it.
#    Seals PATH entirely (SEAL): one directory holding only symlinks to the needed utilities, plus a fake tmux/fzf.
#    The fake tmux answers only to `-V`; called with any other argument, it leaves a LEAK file and dies with rc 1.
#    At the end of the file it asserts that "the fake tmux was only ever called with -V" — if a real call leaked through, this is where it blows up.
set -u
. "$(dirname "$0")/lib.sh"

ORIGPATH="$PATH"
REPO=$(cd "$(dirname "$0")/.." && pwd -P) || exit 1
fmux_test_sandbox

INST="$REPO/install.sh"
CALLS="$FMUXROOT/tmux-calls.log"
LEAK="$FMUXROOT/tmux-LEAK.log"

# ── PATH seal ────────────────────────────────────────────────────────────────
# The test must not depend on where the real fzf happens to be installed on this machine (the "no
# fzf" case would answer differently on every machine). So it builds a directory that symlinks
# only the needed utilities and makes PATH out of that alone.
SEAL="$FMUXROOT/seal"
mkdir -p "$SEAL"
for c in sh bash env cat cp mv rm mkdir rmdir chmod ln cmp uname make awk sed grep tr cut \
         date ls dirname basename readlink sort head tail wc id touch find mktemp diff expr; do
    p=$(PATH="$ORIGPATH" command -v "$c" 2>/dev/null) || continue
    ln -sf "$p" "$SEAL/$c"
done
for c in bash awk make cmp; do
    [ -e "$SEAL/$c" ] || { echo "  FAIL $c is missing from the sealed PATH — this test cannot run on this machine"; exit 1; }
done

# Fake tmux/fzf. Answers only the version.
mkstub() {   # $1=directory $2=tmux version ('' means do not create tmux) $3=fzf version ('' means do not create it)
    mkdir -p "$1"
    if [ -n "$2" ]; then
        {
            printf '#!/usr/bin/env bash\n'
            printf 'printf "%%s\\n" "tmux $*" >> "%s"\n' "$CALLS"
            printf 'if [ "${1:-}" = "-V" ]; then echo "tmux %s"; exit 0; fi\n' "$2"
            printf 'printf "%%s\\n" "LEAK: tmux $*" >> "%s"\n' "$LEAK"
            printf 'exit 1\n'
        } > "$1/tmux"
        chmod +x "$1/tmux"
    fi
    if [ -n "$3" ]; then
        {
            printf '#!/usr/bin/env bash\n'
            printf 'if [ "${1:-}" = "--version" ]; then echo "%s (test)"; exit 0; fi\n' "$3"
            printf 'printf "%%s\\n" "LEAK: fzf $*" >> "%s"\n' "$LEAK"
            printf 'exit 1\n'
        } > "$1/fzf"
        chmod +x "$1/fzf"
    fi
}

STUB_OK="$FMUXROOT/stub-ok";     mkstub "$STUB_OK"   3.5a  0.65.2
STUB_OLD="$FMUXROOT/stub-old";   mkstub "$STUB_OLD"  2.9a  0.65.2
STUB_NOFZF="$FMUXROOT/stub-nf";  mkstub "$STUB_NOFZF" 3.5a ''
STUB_NOTMUX="$FMUXROOT/stub-nt"; mkstub "$STUB_NOTMUX" ''   0.65.2
STUB_OLDFZF="$FMUXROOT/stub-of"; mkstub "$STUB_OLDFZF" 3.5a 0.44.1

OUT=''; RC=0
run_inst() {   # $1=stub directory, the rest=install.sh args
    local stub="$1"; shift
    RC=0
    OUT=$(PATH="$stub:$SEAL" bash "$INST" "$@" < /dev/null 2>&1) || RC=$?
}

has() { case "$1" in *"$2"*) printf 'yes' ;; *) printf 'no' ;; esac; }
ex()  { if [ -e "$1" ]; then printf 'yes'; else printf 'no'; fi; }
cnt() { grep -c "$2" "$1" 2>/dev/null || true; }

BIN="$HOME/.local/bin"
LIBX="$HOME/.local/libexec/fmux"
SNIP="$XDG_CONFIG_HOME/fleetmux/tmux.conf"
CONF="$XDG_CONFIG_HOME/fleetmux/config"
TMUXCONF="$HOME/.tmux.conf"

# ── ① argument handling ─────────────────────────────────────────────────────
run_inst "$STUB_OK" --help
assert_eq "$RC" "0" "--help is rc 0"
assert_eq "$(has "$OUT" 'usage: ./install.sh')" "yes" "--help prints usage"
assert_eq "$(ex "$BIN/fmux")" "no" "--help installs nothing"

run_inst "$STUB_OK" --nonsense
assert_eq "$RC" "2" "an unknown option is rc 2"
assert_eq "$(has "$OUT" 'unknown option')" "yes" "names the unknown option"

# ── ② missing or too-low dependencies halt the install ──────────────────────
run_inst "$STUB_OLD"
assert_eq "$RC" "1" "tmux 2.9a halts"
assert_eq "$(has "$OUT" 'tmux 2.9a')" "yes" "shows the low tmux version as-is"
assert_eq "$(has "$OUT" '3.2')" "yes" "says why (3.2) it is needed"
assert_eq "$(has "$OUT" 'Nothing was changed')" "yes" "says nothing was changed when it halts"
assert_eq "$(ex "$BIN/fmux")" "no" "a dependency failure does not install the binary"
assert_eq "$(ex "$LIBX")" "no" "a dependency failure does not install the shim either"

run_inst "$STUB_NOTMUX"
assert_eq "$RC" "1" "no tmux halts"
assert_eq "$(has "$OUT" 'tmux is not present')" "yes" "names what is missing"

run_inst "$STUB_NOFZF"
assert_eq "$RC" "1" "no fzf halts"
assert_eq "$(has "$OUT" 'fzf is not present')" "yes" "says why fzf is needed"

run_inst "$STUB_OLDFZF"
assert_eq "$RC" "1" "fzf 0.44.1 halts"
assert_eq "$(has "$OUT" '0.64')" "yes" "states the fzf version required"
assert_eq "$(ex "$BIN")" "no" "nothing has appeared yet at this point"

# ── ③ --dry-run changes nothing ──────────────────────────────────────────────
run_inst "$STUB_OK" --dry-run
assert_eq "$RC" "0" "--dry-run is rc 0"
assert_eq "$(has "$OUT" '--dry-run')" "yes" "announces dry-run at the top"
assert_eq "$(has "$OUT" 'dry  ')" "yes" "shows what would be done as dry lines"
assert_eq "$(ex "$BIN/fmux")" "no" "dry-run does not create the binary"
assert_eq "$(ex "$LIBX/claude")" "no" "dry-run does not create the shim"
assert_eq "$(ex "$SNIP")" "no" "dry-run does not create the snippet"
assert_eq "$(ex "$TMUXCONF")" "no" "dry-run does not create ~/.tmux.conf"
assert_eq "$(ex "$HOME/.claude")" "no" "dry-run does not create ~/.claude"
assert_eq "$(has "$OUT" '--cron')" "yes" "shows the cron lines"
assert_eq "$(has "$OUT" '@reboot')" "yes" "shows the @reboot line too"
assert_eq "$(has "$OUT" 'crontab')" "yes" "says to add crontab entries yourself"

# ── ④ a real install — without a terminal, someone else's file is not changed without consent ──
printf 'set -g mouse on\n' > "$TMUXCONF"
cp "$TMUXCONF" "$FMUXROOT/tmuxconf.before"

run_inst "$STUB_OK"
assert_eq "$RC" "0" "install is rc 0"
assert_eq "$(ex "$BIN/fmux")" "yes" "fmux gets installed"
assert_rc 0 test -x "$BIN/fmux"
assert_rc 0 test -L "$BIN/tt"
assert_eq "$(ex "$LIBX/claude")" "yes" "the claude shim gets installed"
assert_eq "$(ex "$LIBX/codex")" "yes" "the codex shim gets installed"
assert_rc 0 test -x "$LIBX/claude"
assert_eq "$(ex "$SNIP")" "yes" "the tmux snippet is created"
assert_eq "$(has "$(cat "$SNIP")" 'bind F ')" "yes" "the snippet contains the summon key"

# ~/.tmux.conf is not changed without consent — measured byte for byte
assert_rc 0 cmp -s "$FMUXROOT/tmuxconf.before" "$TMUXCONF"
assert_eq "$(cnt "$TMUXCONF" 'source-file')" "0" "without consent, no source-file line is added"
assert_eq "$(has "$OUT" 'not a terminal, so we did not ask')" "yes" "says why it did not add it"
assert_eq "$(has "$OUT" "source-file $SNIP")" "yes" "shows on screen the line it would add instead"

# Keeps the config default (S-Up) — "could not ask" is not the same as "was told no".
assert_eq "$(grep -c '^bind -n S-Up ' "$SNIP" || true)" "1" "without a terminal, the default S-Up is still bound"

# one line explaining what the shim is + PATH guidance
assert_eq "$(has "$OUT" 'claude/codex launched inside tmux')" "yes" "explains what the shim does"
assert_eq "$(has "$OUT" 'export PATH=')" "yes" "shows how to add it to PATH"
assert_eq "$(has "$OUT" 'deleting this file removes all trace')" "yes" "shows how to remove it"
assert_eq "$(has "$OUT" "$LIBX")" "yes" "states in a path where things were placed"

# ~/.claude is not created without consent.
#   (Now that the repo has skills/fleetmux/SKILL.md, this run is not "skipped because it is
#    missing" but "not installed because it could not ask" — the skip for a repo with no skill
#    at all is measured at ⑨.)
assert_eq "$(ex "$HOME/.claude")" "no" "without consent, ~/.claude is left untouched"
assert_eq "$(has "$OUT" 'not installed')" "yes" "says it was not installed and how to install it later"

# ── ⑤ second run — idempotent ────────────────────────────────────────────────
cp -R "$HOME/.local" "$FMUXROOT/local.before"
run_inst "$STUB_OK"
assert_eq "$RC" "0" "the second run is also rc 0"
assert_eq "$(has "$OUT" 'already identical')" "yes" "says what already exists is left as-is"
assert_rc 0 cmp -s "$FMUXROOT/local.before/bin/fmux" "$BIN/fmux"
assert_rc 0 cmp -s "$FMUXROOT/local.before/libexec/fmux/claude" "$LIBX/claude"
assert_rc 0 cmp -s "$FMUXROOT/tmuxconf.before" "$TMUXCONF"
assert_eq "$(cnt "$TMUXCONF" 'source-file')" "0" "the second run also does not change someone else's file"

# ── ⑥ --yes is consent — one line only, still one line after two runs ───────
run_inst "$STUB_OK" --yes
assert_eq "$RC" "0" "a --yes install is rc 0"
assert_eq "$(cnt "$TMUXCONF" 'source-file')" "1" "with --yes, the source-file line is added"
assert_eq "$(cnt "$TMUXCONF" 'mouse on')" "1" "the line that was already there stays as-is"

run_inst "$STUB_OK" --yes
assert_eq "$RC" "0" "--yes a second time is also rc 0"
assert_eq "$(cnt "$TMUXCONF" 'source-file')" "1" "running twice does not create a duplicate line"
assert_eq "$(has "$OUT" 'already sources this file')" "yes" "says so when it is already there"

# A line that only exists as a comment is treated as absent (a commented line does not run)
cp "$TMUXCONF" "$FMUXROOT/tmuxconf.sourced"
printf 'set -g mouse on\n# source-file %s\n' "$SNIP" > "$TMUXCONF"
run_inst "$STUB_OK" --yes
assert_eq "$(cnt "$TMUXCONF" '^source-file')" "1" "a comment line does not count as sourcing"
cp "$FMUXROOT/tmuxconf.sourced" "$TMUXCONF"

# ── ⑥-b someone else's file that does not end in a newline (gate B1) ────────
# Using `>>` alone **corrupts the user's last line** — and it is still reported as rc 0 "success".
# Builds a real file like that by leaving \n off printf (a shape that is common when an editor
# saves a file).
rm -f "$TMUXCONF.fmux-bak"
printf 'set -g mouse on\nset -g status-position top' > "$TMUXCONF"     # ← no newline (deliberate)
cp "$TMUXCONF" "$FMUXROOT/tmuxconf.nonl"
assert_eq "$(tail -c 1 "$TMUXCONF" | od -An -c | tr -d ' \n')" "p" "repro: the last byte is not a newline"

run_inst "$STUB_OK" --yes
assert_eq "$RC" "0" "rc 0 even for a file with no trailing newline"
assert_eq "$(cnt "$TMUXCONF" '^set -g status-position top$')" "1" "the user's last line survives untouched"
assert_eq "$(cnt "$TMUXCONF" '^source-file')" "1" "our line starts on its own line"
assert_eq "$(cnt "$TMUXCONF" 'topsource-file')" "0" "the two lines were not glued into one"
# A backup exists, and its content is byte-identical to the pre-edit original — it must be
# possible to undo this
assert_eq "$(ex "$TMUXCONF.fmux-bak")" "yes" "leaves a backup before editing"
assert_rc 0 cmp -s "$FMUXROOT/tmuxconf.nonl" "$TMUXCONF.fmux-bak"
assert_eq "$(has "$OUT" "$TMUXCONF.fmux-bak")" "yes" "tells the person the backup path"
assert_eq "$(has "$OUT" 'does not end in a newline')" "yes" "says why it added the newline first"

# Also checks that the file is in a shape tmux can actually read — no stray token from someone
# else's line in front of ours
assert_eq "$(grep -c '^source-file ' "$TMUXCONF" || true)" "1" "source-file is the first token on the line"

# ── ⑥-c an already-broken line is not "already configured" (gate B2) ────────
# Reproduces exactly the corrupted shape the old version (before the B1 fix) produced. A
# partial-match check would look at this and call it "already sourced," passing over it — a
# rerun could never self-heal and the damage would stay hidden forever.
printf 'set -g mouse onsource-file %s\n' "$SNIP" > "$TMUXCONF"
run_inst "$STUB_OK" --yes
assert_eq "$(has "$OUT" 'already sources this file')" "no" "does not mistake a broken line for already configured"
assert_eq "$(grep -c '^source-file ' "$TMUXCONF" || true)" "1" "inserts a clean line fresh — self-heals"

# Treated as the same line whether it has leading whitespace, a -q flag, or quotes (still keeps
# an exact match)
printf '  source-file -q "%s"\n' "$SNIP" > "$TMUXCONF"
run_inst "$STUB_OK" --yes
assert_eq "$(has "$OUT" 'already sources this file')" "yes" "counts it as the same line even with indentation, a flag, or quotes"
assert_eq "$(cnt "$TMUXCONF" 'source-file')" "1" "in that case no extra line is added"

# Treated as the same line even written with a tilde (gate I1) — this is exactly the shape
# README teaches. Without expanding it, **exactly the person who typed it by hand following the
# docs** gets one extra duplicate source line on rerun.
assert_eq "$SNIP" "$HOME/.config/fleetmux/tmux.conf" "premise: the tilde line points at our snippet"
printf 'set -g mouse on\nsource-file ~/.config/fleetmux/tmux.conf\n' > "$TMUXCONF"
run_inst "$STUB_OK" --yes
assert_eq "$(has "$OUT" 'already sources this file')" "yes" "treats a tilde-written line as already linked too"
assert_eq "$(cnt "$TMUXCONF" 'source-file')" "1" "so it does not append a duplicate line"

# Someone else's home (~other/…) is not our line — blindly expanding to $HOME would itself be a
# false positive.
printf 'source-file ~other/.config/fleetmux/tmux.conf\n' > "$TMUXCONF"
run_inst "$STUB_OK" --yes
assert_eq "$(cnt "$TMUXCONF" 'source-file')" "2" "a ~other form is not counted as our line"

# A line sourcing a different file is not our line
printf 'source-file %s.other\n' "$SNIP" > "$TMUXCONF"
run_inst "$STUB_OK" --yes
assert_eq "$(cnt "$TMUXCONF" 'source-file')" "2" "a line sourcing a different path is not counted as ours"

cp "$FMUXROOT/tmuxconf.sourced" "$TMUXCONF"

# ── ⑦ summon key preset ──────────────────────────────────────────────────────
run_inst "$STUB_OK" --yes --preset mac
assert_eq "$RC" "0" "--preset mac is rc 0"
assert_eq "$(has "$(cat "$CONF")" 'key_summon_fast=M-b')" "yes" "the mac preset lands in the config"
assert_eq "$(grep -c '^bind -n M-b ' "$SNIP" || true)" "1" "the snippet changes to match"
assert_eq "$(has "$OUT" 'Option')" "yes" "says in one line why it is M-b"

run_inst "$STUB_OK" --yes --preset mac
assert_eq "$(has "$OUT" "already 'M-b'")" "yes" "running the same preset again leaves it as-is"

run_inst "$STUB_OK" --yes --preset wsl
assert_eq "$(grep -c '^bind -n C-Left ' "$SNIP" || true)" "1" "the wsl preset is C-Left"
assert_eq "$(grep -c '^bind -n M-b ' "$SNIP" || true)" "0" "the previous preset's key gets unbound"
assert_eq "$(grep -c '^unbind -n -q M-b' "$SNIP" || true)" "1" "an unbind is left for the key that was unbound"

run_inst "$STUB_OK" --yes --preset safe
assert_eq "$(grep -c '^bind -n ' "$SNIP" || true)" "0" "safe binds no no-prefix key at all"

# ── ⑦-b --yes does not auto-adopt the detected preset (gate I3) ─────────────
# Previously ASSUME_YES took ask_word's default (= the detected value) as-is, with no prompt. So
# on Linux, `./install.sh --yes` globally stole **two** no-prefix keys (C-Left M-Left), while
# right next to it README was promising `key_summon_fast — Default empty (fmux steals no key
# until you say so)`. Taking a key globally does not belong in the category of "accepting the
# suggested default."
run_inst "$STUB_OK" --yes --preset linux         # ← first put it into the 'stolen' state
assert_eq "$(grep -c '^bind -n ' "$SNIP" || true)" "2" "repro: --preset linux binds two no-prefix keys"
run_inst "$STUB_OK" --yes
assert_eq "$RC" "0" "--yes alone is rc 0"
# Since 2026-08-11 the config default *is* S-Up, so "nobody to ask" keeps it rather than clearing
# it — writing safe here would turn "I did not ask" into "you said no". The two-key presets are
# what still require saying it out loud; see the next block.
assert_eq "$(grep -c '^bind -n S-Up ' "$SNIP" || true)" "1" "--yes keeps the default S-Up"
assert_eq "$(grep -c '^bind -n ' "$SNIP" || true)" "1" "and takes nothing beyond it"
assert_eq "$(grep -c '^bind F ' "$SNIP" || true)" "1" "the prefix summon key (F) stays as-is"
assert_eq "$(has "$OUT" 'no one to ask')" "yes" "says on screen that it kept the default"
assert_eq "$(has "$OUT" './install.sh --preset safe')" "yes" "and how to take no key at all"
# The stealing path only opens when spelled out explicitly — if that path gets blocked, this
# change has removed the feature.
run_inst "$STUB_OK" --yes --preset linux
assert_eq "$(grep -c '^bind -n ' "$SNIP" || true)" "2" "an explicit --preset still steals"
run_inst "$STUB_OK" --yes --preset safe

run_inst "$STUB_OK" --preset nope
assert_eq "$RC" "1" "an unknown preset halts"
assert_eq "$(has "$OUT" 'safe|shift|mac|linux|wsl')" "yes" "lists the presets that can be used"

# ── ⑦-c the suggestion is S-Up (one no-prefix keystroke) ──────────────────
# Reasoning: macOS Mission Control eats C-arrow first, Windows Terminal eats M-arrow first, and
# Ctrl+letter is already used by shell line editing, vim, fzf. The only no-prefix single
# keystroke that gets through all three is S-arrow.
# Three things are measured here: ① is the suggestion actually S-Up ② does it say what it takes
# ③ does it still not steal it where it could not ask.
run_inst "$STUB_OK" --preset safe                # first return it to the not-stolen state
run_inst "$STUB_OK" --dry-run
assert_eq "$RC" "0" "dry-run is rc 0"
assert_eq "$(has "$OUT" "suggested: shift — key_summon_fast='S-Up'")" "yes" "the suggestion is S-Up"
assert_eq "$(has "$OUT" 'this takes the key away from every app in the pane')" "yes" "says right there what it takes"
assert_eq "$(has "$OUT" "Pick a different key if you're already using it.")" "yes" "recommends a different key to someone already using it"
assert_eq "$(has "$OUT" 'S-Up/S-Down to tmux window switching')" "yes" "writes down the known risk (window-switching bindings)"
# Where it cannot ask it keeps the default and says which one, rather than going silent.
assert_eq "$(has "$OUT" 'no one to ask')" "yes" "says so when it cannot ask"
assert_eq "$(has "$OUT" './install.sh --preset safe')" "yes" "and points at the way to take no key at all"

# --preset shift actually binds S-Up (is the suggestion's name a real preset?).
run_inst "$STUB_OK" --yes --preset shift
assert_eq "$RC" "0" "--preset shift is rc 0"
assert_eq "$(has "$(cat "$CONF")" 'key_summon_fast=S-Up')" "yes" "the shift preset lands in the config"
assert_eq "$(grep -c '^bind -n S-Up ' "$SNIP" || true)" "1" "the snippet emits bind -n S-Up"
assert_eq "$(grep -c '^unbind -n -q S-Up$' "$SNIP" || true)" "1" "even the key being bound is unbound first (idempotent on reapply)"
assert_eq "$(grep -c '^bind F ' "$SNIP" || true)" "1" "the prefix summon key stays as-is"

# ── ⑦-c' where tmux is gets written down while it can still be seen ────────
# This script runs in an interactive shell, where `command -v tmux` answers. The two places fmux
# runs afterwards do not: a popup gets the tmux server's environment and cron gets /usr/bin:/bin,
# and on a Mac neither could find tmux — the popup drew an empty session list instead of saying
# so (2026-08-14). fmux repairs its own PATH at run time (t-19 pins that); this is the shortcut
# for a prefix nothing can guess, and it is only knowable from here.
assert_eq "$(has "$(cat "$CONF")" "tmux_path=$STUB_OK/tmux")" "yes" \
    "★the absolute path of the tmux it checked is recorded in the config"
assert_eq "$(has "$OUT" "config tmux_path='$STUB_OK/tmux'")" "yes" "and it says that it did"

# Dry-run must stay a dry run. This key is written with the same `config set` as the summon key,
# so if it ever escaped the is_dry check it would be the one write that a --dry-run performs.
run_inst "$STUB_OK" --dry-run
assert_eq "$(has "$OUT" "fmux config set tmux_path '$STUB_OK/tmux'")" "yes" "dry-run says it would record tmux_path"
assert_eq "$(has "$OUT" "config tmux_path='$STUB_OK/tmux'")" "no" "and does not claim to have done it"

# ── ⑦-d --yes does not auto-adopt the new suggestion either (regression guard) ──
# The suggestion getting better and it being fine to take without consent are different
# statements. Nails down the same discipline as ⑦-b again, this time **for the new default
# suggestion (S-Up)** — without this line, a future change reasoning "the default changed, so
# --yes should follow along" would quietly slip through.
assert_eq "$(grep -c '^bind -n S-Up ' "$SNIP" || true)" "1" "repro: S-Up is currently bound"
run_inst "$STUB_OK" --yes
assert_eq "$RC" "0" "--yes alone is rc 0"
assert_eq "$(grep -c '^bind -n S-Up ' "$SNIP" || true)" "1" "--yes leaves the default S-Up in place"
assert_eq "$(has "$OUT" 'no one to ask')" "yes" "says on screen that it kept the default"

# Asking for no prefix-less key at all still works, and is still the only way to get there
# without a terminal. `safe` writes an explicit empty value — `config unset` would hand the key
# back, because the code default is S-Up now.
run_inst "$STUB_OK" --yes --preset safe
assert_eq "$(grep -c '^bind -n ' "$SNIP" || true)" "0" "--preset safe takes no prefix-less key"
assert_eq "$(cnt "$CONF" '^key_summon_fast=$')" "1" "and says so with an explicit empty value, not by unsetting"

# ── ⑦-e warns before overwriting a line that already uses that key ──────────
# Does not ask a live tmux server — reads only config files. A dotfile that binds S-Up/S-Down
# to window switching being common is exactly why this detection exists.
cp "$TMUXCONF" "$FMUXROOT/tmuxconf.noclash"
printf 'bind -n S-Up previous-window\n' >> "$TMUXCONF"
run_inst "$STUB_OK" --dry-run
assert_eq "$(has "$OUT" 'found a line in your config already binding that key')" "yes" "warns before overwriting a clash"
assert_eq "$(has "$OUT" 'bind -n S-Up previous-window')" "yes" "shows that line as-is"
assert_eq "$(has "$OUT" "$TMUXCONF:")" "yes" "says which file and which line number"
# Does not overreach onto someone else's other key — a line binding S-Down is not a clash with
# the S-Up suggestion.
cp "$FMUXROOT/tmuxconf.noclash" "$TMUXCONF"
printf 'bind -n S-Down next-window\n' >> "$TMUXCONF"
run_inst "$STUB_OK" --dry-run
assert_eq "$(has "$OUT" 'found a line in your config already binding that key')" "no" "a non-overlapping line is not called a clash"
cp "$FMUXROOT/tmuxconf.noclash" "$TMUXCONF"

# ── ⑦-f the suggestion and a decline where it can ask (a real pty) ──────────
# ASK_TTY is `[ -t 0 ]`. A pipe cannot hit that branch, so this spins up a pty.
# Only runs when util-linux's `script -qec CMD /dev/null` form is available — BSD (Mac) script
# has a different argument order and lacks this form. If missing, it says so instead of silently
# passing.
SCRIPTBIN=$(PATH="$ORIGPATH" command -v script 2>/dev/null) || SCRIPTBIN=''
if [ -n "$SCRIPTBIN" ] && "$SCRIPTBIN" -qec 'true' /dev/null > /dev/null 2>&1 < /dev/null; then
    # $2 = the answers to stream into stdin. At this point $TMUXCONF already has the source
    # line, so step 4 does not ask → the answers go in [preset, install-skill] order.
    run_inst_tty() {   # $1=stub directory $2=answer string, the rest=install.sh args
        local stub="$1" input="$2"; shift 2
        RC=0
        # %b matters — the newlines between answers must be sent as real newlines for read to
        # receive one line at a time.
        OUT=$(printf '%b' "$input" \
              | PATH="$stub:$SEAL" "$SCRIPTBIN" -qec "bash '$INST' $*" /dev/null 2>&1) || RC=$?
    }

    run_inst "$STUB_OK" --preset safe            # starting from the not-stolen state
    # ① a bare Enter = accepting the suggestion → binds S-Up
    run_inst_tty "$STUB_OK" '\nn\n'
    assert_eq "$RC" "0" "an interactive pty install is rc 0"
    assert_eq "$(has "$OUT" 'preset (shift|safe|mac|linux|wsl) [shift]')" "yes" "the prompt defaults to shift"
    assert_eq "$(has "$(cat "$CONF")" 'key_summon_fast=S-Up')" "yes" "just Enter accepts S-Up"
    assert_eq "$(grep -c '^bind -n S-Up ' "$SNIP" || true)" "1" "the snippet also gets S-Up bound"

    # ② decline (safe) → goes with the prefix approach. No no-prefix key survives.
    run_inst_tty "$STUB_OK" 'safe\nn\n'
    assert_eq "$RC" "0" "even declining is rc 0"
    assert_eq "$(grep -c '^bind -n ' "$SNIP" || true)" "0" "declining leaves no no-prefix key at all"
    # An explicit empty value, not an absent one: with S-Up as the code default, unsetting would
    # give the key straight back to someone who just said they did not want it.
    assert_eq "$(cnt "$CONF" '^key_summon_fast=$')" "1" "declining writes an explicit empty value"
    assert_eq "$(grep -c '^bind F ' "$SNIP" || true)" "1" "declining leaves the prefix approach"
    assert_eq "$(grep -c '^unbind -n -q S-Up$' "$SNIP" || true)" "1" "the S-Up it had taken gets returned"

    # ③ a typo falls to the non-stealing side — an unknown answer must not be read as the suggestion
    run_inst_tty "$STUB_OK" 'shfit\nn\n'
    assert_eq "$(has "$OUT" "unknown preset 'shfit'")" "yes" "says so for an unknown answer"
    assert_eq "$(grep -c '^bind -n ' "$SNIP" || true)" "0" "an unknown answer falls to safe"
else
    printf '  skip pty interactive check — no util-linux-style script (expected on BSD/Mac)\n'
fi
run_inst "$STUB_OK" --yes --preset safe

# ── ⑧ --dry-run after install still changes nothing ─────────────────────────
cp -R "$HOME/.local" "$FMUXROOT/local.dry"
cp "$SNIP" "$FMUXROOT/snip.dry"; cp "$CONF" "$FMUXROOT/conf.dry"; cp "$TMUXCONF" "$FMUXROOT/tmuxconf.dry"
run_inst "$STUB_OK" --dry-run --yes --preset mac
assert_eq "$RC" "0" "dry-run after install is also rc 0"
assert_rc 0 cmp -s "$FMUXROOT/snip.dry" "$SNIP"
assert_rc 0 cmp -s "$FMUXROOT/conf.dry" "$CONF"
assert_rc 0 cmp -s "$FMUXROOT/tmuxconf.dry" "$TMUXCONF"
assert_rc 0 cmp -s "$FMUXROOT/local.dry/bin/fmux" "$BIN/fmux"
assert_eq "$(has "$OUT" 'config set key_summon_fast')" "yes" "dry-run only talks about the value it would change"

# ── ⑨ skill — if present, asks and installs ─────────────────────────────────
# Clones the repo and drops a skill file in (the real repo is untouched).
REPO2="$FMUXROOT/repo2"
mkdir -p "$REPO2/skills/fleetmux"
cp "$INST" "$REPO2/install.sh"
cp "$REPO/Makefile" "$REPO2/Makefile"
cp -R "$REPO/src" "$REPO/bin" "$REPO/libexec" "$REPO2/"
printf -- '---\nname: fleetmux\n---\ntest skill\n' > "$REPO2/skills/fleetmux/SKILL.md"
RC=0
OUT=$(PATH="$STUB_OK:$SEAL" bash "$REPO2/install.sh" --yes < /dev/null 2>&1) || RC=$?
assert_eq "$RC" "0" "rc 0 even for a repo that has the skill"
assert_eq "$(ex "$HOME/.claude/skills/fleetmux/SKILL.md")" "yes" "installs the skill to ~/.claude/skills"
assert_eq "$(has "$OUT" 'skills/fleetmux')" "yes" "says where it installed it"

# Not installed without consent — remove the skill and try again without a terminal
rm -rf "$HOME/.claude"
RC=0
OUT=$(PATH="$STUB_OK:$SEAL" bash "$REPO2/install.sh" < /dev/null 2>&1) || RC=$?
assert_eq "$(ex "$HOME/.claude")" "no" "without consent, nothing is created under ~/.claude"

# A repo with no skill file at all — does not silently pass over it, says it is skipping.
rm -rf "$REPO2/skills"
RC=0
OUT=$(PATH="$STUB_OK:$SEAL" bash "$REPO2/install.sh" --yes < /dev/null 2>&1) || RC=$?
assert_eq "$RC" "0" "rc 0 even for a repo with no skill"
assert_eq "$(has "$OUT" 'no skills/fleetmux/SKILL.md')" "yes" "says it is skipping when there is no skill"
assert_eq "$(ex "$HOME/.claude")" "no" "does not create ~/.claude when there is no skill"

# ── ⑩ shim PATH order judgment ───────────────────────────────────────────────
# The most common reason hooks fail to attach: the real claude sits ahead of the shim on PATH.
printf '#!/bin/sh\nexit 0\n' > "$STUB_OK/claude"; chmod +x "$STUB_OK/claude"
RC=0
OUT=$(PATH="$STUB_OK:$SEAL:$LIBX" bash "$INST" < /dev/null 2>&1) || RC=$?
assert_eq "$RC" "0" "the install finishes even with a bad PATH order"
assert_eq "$(has "$OUT" "comes before the shim")" "yes" "warns that hooks will not attach when the real claude comes first on PATH"
RC=0
OUT=$(PATH="$LIBX:$STUB_OK:$SEAL" bash "$INST" < /dev/null 2>&1) || RC=$?
assert_eq "$(has "$OUT" 'PATH order is good')" "yes" "says good when the shim comes first"
assert_eq "$(has "$OUT" "comes before the shim")" "no" "does not warn when the shim comes first"
rm -f "$STUB_OK/claude"

# ── ⑪ someone else's tt is not overwritten ───────────────────────────────────
ALT="$FMUXROOT/alt"
mkdir -p "$ALT/bin"
printf '#!/bin/sh\necho not our tt\n' > "$ALT/bin/tt"; chmod +x "$ALT/bin/tt"
cp "$ALT/bin/tt" "$FMUXROOT/tt.before"
run_inst "$STUB_OK" --prefix "$ALT" --preset safe
assert_eq "$RC" "0" "the install finishes even with someone else's tt present"
assert_rc 0 cmp -s "$FMUXROOT/tt.before" "$ALT/bin/tt"
assert_eq "$(has "$OUT" 'is not ours')" "yes" "says it did not touch someone else's tt"

# ── ⑪-b someone else's tt **symlink** is not overwritten either (gate I2) ───
# This is the real spot. The most common way to hang a personal tool off ~/.local/bin is a
# symlink, but the old guard was `[ -e ] && [ ! -L ]`, so it protected **only regular files** and
# silently replaced a symlink. With no backup and no warning, the original target survives
# nowhere = unrecoverable. Both paths get walked here: with make present, `make install` hangs it
# (so the Makefile needs the same guard too), and without make, install.sh hangs it by its own
# hand.
ALT2="$FMUXROOT/alt2"
mkdir -p "$ALT2/bin" "$ALT2/theirs"
printf '#!/bin/sh\necho not our tool\n' > "$ALT2/theirs/mytool"; chmod +x "$ALT2/theirs/mytool"
ln -sf "$ALT2/theirs/mytool" "$ALT2/bin/tt"
assert_rc 0 test -L "$ALT2/bin/tt"

run_inst "$STUB_OK" --prefix "$ALT2" --preset safe
assert_eq "$RC" "0" "the install finishes even with someone else's tt symlink present"
assert_eq "$(readlink "$ALT2/bin/tt")" "$ALT2/theirs/mytool" "someone else's symlink survives as-is"
assert_eq "$(has "$OUT" 'is not ours')" "yes" "says it belongs to someone else"
assert_eq "$(has "$OUT" "symlink → $ALT2/theirs/mytool")" "yes" "shows what is there down to the target path"
assert_eq "$(has "$OUT" 'ok   '"$ALT2/bin/tt"' → fmux')" "no" "does not print that it hung it when it did not"
assert_eq "$(has "$OUT" 'mv ')" "yes" "shows a way so the person can decide"
assert_eq "$(ex "$ALT2/bin/fmux")" "yes" "fmux itself still gets installed anyway"

# The path without make (HAVE_MAKE=0) must land on the same judgment — here install.sh does the
# ln itself.
NOMAKE="$FMUXROOT/nomake"
mkdir -p "$NOMAKE"
for c in sh bash env cat cp mv rm mkdir chmod ln cmp uname awk sed grep tr cut date ls \
         dirname basename readlink sort head tail wc id touch find mktemp diff expr; do
    [ -e "$SEAL/$c" ] && ln -sf "$SEAL/$c" "$NOMAKE/$c"
done
ALT3="$FMUXROOT/alt3"
mkdir -p "$ALT3/bin" "$ALT3/theirs"
printf '#!/bin/sh\necho not our tool\n' > "$ALT3/theirs/mytool"; chmod +x "$ALT3/theirs/mytool"
ln -sf "$ALT3/theirs/mytool" "$ALT3/bin/tt"
RC=0
OUT=$(PATH="$STUB_OK:$NOMAKE" bash "$INST" --prefix "$ALT3" --preset safe < /dev/null 2>&1) || RC=$?
assert_eq "$RC" "0" "the install finishes even without make"
assert_eq "$(has "$OUT" 'make is not present')" "yes" "actually walked the no-make path"
assert_eq "$(readlink "$ALT3/bin/tt")" "$ALT3/theirs/mytool" "the no-make path also does not touch someone else's symlink"

# The other side — a symlink we hung gets re-hung the same way on rerun (idempotent). Otherwise
# hook injection dies wholesale from the second install onward.
ALT4="$FMUXROOT/alt4"
run_inst "$STUB_OK" --prefix "$ALT4" --preset safe
assert_eq "$(readlink "$ALT4/bin/tt")" "fmux" "hangs our symlink in an empty spot"
run_inst "$STUB_OK" --prefix "$ALT4" --preset safe
assert_eq "$(readlink "$ALT4/bin/tt")" "fmux" "a rerun leaves our symlink as-is"
assert_eq "$(has "$OUT" 'is not ours')" "no" "does not mistake our own for someone else's"
# A dangling symlink belonging to someone else is not 'empty' either — -e is false but -L is true.
ALT5="$FMUXROOT/alt5"
mkdir -p "$ALT5/bin"
ln -sf "$FMUXROOT/does-not-exist" "$ALT5/bin/tt"
run_inst "$STUB_OK" --prefix "$ALT5" --preset safe
assert_eq "$(readlink "$ALT5/bin/tt")" "$FMUXROOT/does-not-exist" "does not swap out a dangling symlink belonging to someone else either"
assert_eq "$(has "$OUT" 'is not ours')" "yes" "treats a dangling symlink as someone else's too"

# --dry-run has to say the same thing (so there is no surprise after the fact)
run_inst "$STUB_OK" --dry-run --prefix "$ALT2"
assert_eq "$(has "$OUT" 'is not ours')" "yes" "dry-run warns ahead of time"
assert_eq "$(readlink "$ALT2/bin/tt")" "$ALT2/theirs/mytool" "dry-run naturally changes nothing"

# ── ⑫ an unusable prefix — says how far it got and stops ────────────────────
NOPREFIX="$FMUXROOT/notadir"
: > "$NOPREFIX"
run_inst "$STUB_OK" --prefix "$NOPREFIX"
assert_eq "$RC" "1" "halts when the location cannot be installed to"
assert_eq "$(has "$OUT" 'stopping the install')" "yes" "says it stopped"
assert_rc 0 test -f "$NOPREFIX"

# ── ⑫-b consent comes first — nothing lands on someone else's server before asking (gate B5) ──
# Only here does it fill in TMUX to create "installing from inside tmux." The stub logs to a log
# file dedicated to this section so it does not mix with ⑬'s seal check (source-file is not -V,
# so it would be a LEAK if it were STUB_OK).
TIN="$FMUXROOT/stub-tmuxin"
TIN_LOG="$FMUXROOT/tmuxin-calls.log"
mkdir -p "$TIN"
{
    printf '#!/usr/bin/env bash\n'
    printf 'printf "%%s\\n" "tmux $*" >> "%s"\n' "$TIN_LOG"
    printf 'if [ "${1:-}" = "-V" ]; then echo "tmux 3.5a"; fi\n'
    printf 'exit 0\n'
} > "$TIN/tmux"
chmod +x "$TIN/tmux"
cp "$STUB_OK/fzf" "$TIN/fzf"

# Both runs pin the preset to safe — since an unchanged value means step 5 does not rewrite the
# snippet, the source-file that leaves this section belongs only to step 4 (the snippet).
# Otherwise step 5's rewrite would hide a step-4 ordering bug (a net that would still pass even if
# the old order were restored).
# ① no consent (not a terminal) — not even linked yet. Not a single character of the live server
# should change.
: > "$TIN_LOG"
printf 'set -g mouse on\n' > "$TMUXCONF"
RC=0
OUT=$(PATH="$TIN:$SEAL" TMUX="/fake/socket,0,0" bash "$INST" --preset safe < /dev/null 2>&1) || RC=$?
assert_eq "$RC" "0" "the install is rc 0 even run from inside tmux"
assert_eq "$(cnt "$TMUXCONF" 'source-file')" "0" "without consent, no line is added to someone else's config"
assert_eq "$(cnt "$TIN_LOG" 'source-file')" "0" "before consent, no source-file is fired at the live server"
assert_eq "$(ex "$SNIP")" "yes" "our own file still gets brought up to date"
assert_eq "$(has "$OUT" 'no tmux config reads this file yet')" "yes" "the message matches reality's direction"

# ② consent given — only then does it land on this server too.
: > "$TIN_LOG"
RC=0
OUT=$(PATH="$TIN:$SEAL" TMUX="/fake/socket,0,0" bash "$INST" --yes --preset safe < /dev/null 2>&1) || RC=$?
assert_eq "$RC" "0" "--yes is also rc 0"
assert_eq "$(cnt "$TMUXCONF" '^source-file')" "1" "with consent, the line is added"
assert_contains "$(cat "$TIN_LOG")" "source-file $SNIP" "with consent, this server gets it too"

# ── ⑫-c someone else's skill is not overwritten without a backup (recommendation N1) ──
rm -rf "$HOME/.claude"
mkdir -p "$HOME/.claude/skills/fleetmux"
printf 'my skill\n' > "$HOME/.claude/skills/fleetmux/SKILL.md"
printf 'my note\n'  > "$HOME/.claude/skills/fleetmux/mine.md"
cp -R "$HOME/.claude/skills/fleetmux" "$FMUXROOT/skill.before"
RC=0
OUT=$(PATH="$STUB_OK:$SEAL" bash "$REPO2/install.sh" --yes < /dev/null 2>&1) || RC=$?
assert_eq "$(ex "$HOME/.claude/skills/fleetmux.fmux-bak/SKILL.md")" "no" "a repo with no skill makes no backup either"
mkdir -p "$REPO2/skills/fleetmux"
printf -- '---\nname: fleetmux\n---\ntest skill\n' > "$REPO2/skills/fleetmux/SKILL.md"
RC=0
OUT=$(PATH="$STUB_OK:$SEAL" bash "$REPO2/install.sh" --yes < /dev/null 2>&1) || RC=$?
assert_eq "$RC" "0" "rc 0 even when the skill already exists"
assert_rc 0 cmp -s "$FMUXROOT/skill.before/SKILL.md" "$HOME/.claude/skills/fleetmux.fmux-bak/SKILL.md"
assert_rc 0 cmp -s "$FMUXROOT/skill.before/mine.md"  "$HOME/.claude/skills/fleetmux.fmux-bak/mine.md"
assert_eq "$(has "$OUT" 'fmux-bak')" "yes" "tells the person the backup path"
assert_contains "$(cat "$HOME/.claude/skills/fleetmux/SKILL.md")" "test skill" "installs ours after that"

# ── ⑫-d a rerun does not destroy that backup (gate C3) ──────────────────────
# The old code did `rm -rf "$SKILL_DST.fmux-bak"` right before backing up. The second run first
# deleted the **user's original** left by the first run, then backed up the directory — already
# overwritten with our files — into that same spot. The screen prints "backed up" both times, yet
# the user's original survives nowhere on the machine. Unrecoverable, and the trigger condition
# is a single 'rerun' — right next to it, README promises "Re-running the installer is safe."
# Once a backup is made, it is never overwritten again.
RC=0
OUT=$(PATH="$STUB_OK:$SEAL" bash "$REPO2/install.sh" --yes < /dev/null 2>&1) || RC=$?
assert_eq "$RC" "0" "a rerun is also rc 0"
assert_rc 0 cmp -s "$FMUXROOT/skill.before/SKILL.md" "$HOME/.claude/skills/fleetmux.fmux-bak/SKILL.md"
assert_rc 0 cmp -s "$FMUXROOT/skill.before/mine.md"  "$HOME/.claude/skills/fleetmux.fmux-bak/mine.md"
assert_eq "$(has "$(cat "$HOME/.claude/skills/fleetmux.fmux-bak/SKILL.md")" 'test skill')" "no" \
    "★the backup did not turn into our file — the user's original stays intact"
assert_eq "$(has "$OUT" 'nothing to back up')" "yes" "when the content is already identical, no backup is made at all"

# If someone hand-edits the installed skill and then reruns — the original backup is kept, and
# that edit is saved off separately.
printf 'a line I edited later\n' >> "$HOME/.claude/skills/fleetmux/SKILL.md"
RC=0
OUT=$(PATH="$STUB_OK:$SEAL" bash "$REPO2/install.sh" --yes < /dev/null 2>&1) || RC=$?
assert_eq "$RC" "0" "a rerun with changed content is also rc 0"
assert_rc 0 cmp -s "$FMUXROOT/skill.before/SKILL.md" "$HOME/.claude/skills/fleetmux.fmux-bak/SKILL.md"
assert_eq "$(has "$OUT" 'your original from the first run')" "yes" "recognizes the existing backup as the original and does not overwrite it"
assert_eq "$(ls -d "$HOME/.claude/skills/fleetmux.fmux-bak."* 2>/dev/null | wc -l | tr -d ' ')" "1" \
    "this run's change gets a timestamp and is saved alongside"
assert_eq "$(cat "$HOME"/.claude/skills/fleetmux.fmux-bak.*/SKILL.md | grep -c 'a line I edited later' || true)" "1" \
    "that copy contains the line the person edited"

# ── ⑫-b `curl | bash` must still be able to ask ──────────────────────────────
# Measured 2026-08-06, on the day the repo went public: the very first real install off the
# README one-liner produced a binary and nothing else. `curl … | bash` puts the *script* on
# stdin, so `[ -t 0 ]` was false and every question auto-answered "no" — the tmux snippet was
# never linked, no summon key was bound, and the popup could not be opened at all. Nothing in
# the output said a choice had been skipped.
#
# So this measures the distinction the old code collapsed:
#   "stdin is a pipe"  ≠  "no human is here"
# The installer now asks through /dev/tty. Runs under a pty, with stdin fed from a pipe —
# exactly the `curl | bash` shape — and requires that a question is actually printed.
# Skipped where no pty tool exists; the no-tty path below is measured either way.
if script -qec true /dev/null > /dev/null 2>&1; then
    PTYOUT="$FMUXROOT/pty.out"
    PTYHOME="$FMUXROOT/ptyhome"; mkdir -p "$PTYHOME"
    printf 'n\nn\nn\nn\nn\nn\n' > "$FMUXROOT/answers"
    FMUX_TTY='' script -qec \
        "HOME=$PTYHOME FMUX_TTY= bash -c 'cat $REPO/install.sh | bash -s -- --prefix $PTYHOME/.local --preset safe'" \
        /dev/null < "$FMUXROOT/answers" > "$PTYOUT" 2>&1 || true
    assert_eq "$(cnt "$PTYOUT" '\[y/N\]')" "2" \
        "★piped into bash under a terminal, it still asks (the README one-liner is this exact shape)"
    assert_eq "$(cnt "$PTYOUT" 'not a terminal, so we did not ask')" "0" \
        "★it does not claim there is no terminal when there is one"
else
    printf '  skip no pty tool (script) — cannot measure the curl-pipe ask path here\n'
fi

# And the genuine no-one-is-here case must keep answering itself "no". FMUX_TTY=off forces it
# (the sandbox exports it), because a suite run from a terminal could otherwise open /dev/tty
# and behave differently depending on whether a human was watching.
NOTTYHOME="$FMUXROOT/nottyhome"; mkdir -p "$NOTTYHOME"
OUT=$(HOME="$NOTTYHOME" FMUX_TTY=off bash "$REPO/install.sh" \
        --prefix "$NOTTYHOME/.local" --preset safe < /dev/null 2>&1) || true
assert_eq "$(has "$OUT" 'not a terminal, so we did not ask')" "yes" \
    "with no terminal at all it still refuses to assume consent"
assert_eq "$(ex "$NOTTYHOME/.tmux.conf")" "no" "and it changes nothing it was not allowed to change"

# ── ⑬ did the real tmux leak ─────────────────────────────────────────────────
assert_eq "$(ex "$LEAK")" "no" "the fake tmux/fzf was never called with anything but -V"
assert_eq "$(cnt "$CALLS" '^tmux -V$')" "$(cnt "$CALLS" '^tmux ')" "every tmux call was -V"
assert_rc 0 test -s "$CALLS"

fmux_test_done
