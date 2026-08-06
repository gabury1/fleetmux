#!/usr/bin/env bash
# This is where the docs and the code split apart and it blows up.
#
# README and the skill are what a teammate reads first, and if the commands and paths written
# there do not actually exist, the result is not "the install failed" but "this tool lies." So
# we check the docs:
#   (1) do the files/paths README points to actually exist (install.sh, libexec path, skill)
#   (2) does README's config table match the real defaults and wiring state (no lying table)
#   (3) do the tt entry points the skill teaches actually exist in src
#
# Not a single line of tmux is called. The `fmux config …` used here is a door that does not
# touch tmux.
set -u
. "$(dirname "$0")/lib.sh"
fmux_test_sandbox
cd "$(dirname "$0")/.." || exit 1

README=README.md
SKILL=skills/fleetmux/SKILL.md
SRC=$(cat src/*.sh)
RM=$(cat "$README")

# ── (1) does what README points to actually exist ──────────────────────────
assert_rc 0 test -f "$README"
assert_contains "$RM" './install.sh' "README points to install.sh"
assert_rc 0 test -x install.sh

# The options it advertises must be options that actually exist. --help exits before the
# dependency check, so it installs nothing and never calls tmux either.
usage=$(./install.sh --help 2>&1) || usage=''
for opt in --dry-run --yes --prefix --preset; do
    assert_contains "$RM"    "$opt" "README documents $opt"
    assert_contains "$usage" "$opt" "install.sh actually accepts $opt"
done

# ── (1)-b wrong libexec path ────────────────────────────────────────────────
# The shim lives at ~/.local/libexec/fmux/. The old README said libexec/fleetmux, and anyone
# who set PATH to that path quietly lives with zero hooks firing.
assert_eq "$(grep -c 'libexec/fleetmux' "$README" || true)" "0" \
    "the old path libexec/fleetmux does not linger in README"
assert_contains "$RM" '~/.local/libexec/fmux/' "README states the real shim path"
assert_contains "$(cat install.sh)" 'libexec/fmux' "install.sh uses the same path"
assert_contains "$SRC" 'libexec/fmux' "the restore-path PATH fixup uses the same path too"

# ── (1)-c does the cron guidance point at a real entry point ───────────────
for flag in --cron --boot-restore; do
    assert_contains "$RM"  "$flag" "README's cron guidance uses $flag"
    assert_contains "$SRC" "\"\${1:-}\" = \"$flag\"" "the $flag entry point actually exists"
done

# ── (1)-d does every door listed under Scripting surface actually exist ────
for flag in --list --status --preview --rc --snapshot --restore --forget \
            --hook --hooks-json --codex-hooks --tmux-conf --do-broadcast --help; do
    assert_contains "$RM"  "$flag" "README documents $flag"
    assert_contains "$SRC" "\"\${1:-}\" = \"$flag\"" "the $flag entry point actually exists"
done
assert_contains "$SRC" '"${1:-}" = "config"' "the fmux config entry point actually exists"

# ── (2) is the config table honest ──────────────────────────────────────────
# README lists "keys that are wired" separately from "keys that only get saved." If that
# split disagrees with what the code decides (the not-wired marker in fmux config list), the
# doc is selling a toggle that does nothing.
WIRED='rc snapshot snapshot_on_exit boot_restore status_badges recent_hours unseen_minutes accent log_max key_summon key_summon_fast'
UNWIRED='key_new key_rename key_kill key_reload key_detach key_broadcast key_help key_settings'

list=$("$FMUXBIN" config list 2>/dev/null) || list=''
assert_contains "$list" "KEY" "fmux config list prints a table"

for k in $WIRED; do
    row=$(printf '%s\n' "$list" | grep "^$k ") || row=''
    case "$row" in *"not wired"*) got=unwired ;; *) got=wired ;; esac
    assert_eq "$got" "wired" "$k is wired in the code (matches README's wiring table)"
    assert_contains "$RM" "\`$k\`" "README documents $k"
done
for k in $UNWIRED; do
    row=$(printf '%s\n' "$list" | grep "^$k ") || row=''
    case "$row" in *"not wired"*) got=unwired ;; *) got=wired ;; esac
    assert_eq "$got" "unwired" "$k is still not wired (matches README's not-wired list)"
    assert_contains "$RM" "\`$k\`" "README documents the not-wired key $k"
done

# Every known key must be classified in one of README's two lists — adding a key without
# updating the docs is caught right here.
keys=$(grep -m1 '^FMUX_CONF_KEYS=' src/05-config.sh | sed "s/^FMUX_CONF_KEYS='//; s/'$//")
for k in $keys; do
    got=no
    case " $WIRED $UNWIRED " in *" $k "*) got=yes ;; esac
    assert_eq "$got" "yes" "$k is classified in README's config table"
done

# (2)-b is the default listed in the table the real default. README row shape:
#        | `key` | `value` | … | — key_summon_fast is the only one written as *(empty)*
#        because its value is blank.
for k in $WIRED; do
    want=$("$FMUXBIN" config get "$k" 2>/dev/null) || want=''
    doc=$(grep "^| \`$k\` |" "$README" | head -1 | awk -F'|' '{print $3}' \
          | sed 's/^ *//; s/ *$//; s/^`//; s/`$//') || doc=''
    case "$doc" in '*(empty)*') doc='' ;; esac
    assert_eq "$doc" "$want" "README's stated default for $k matches the code's default"
done

# (2)-c does "what turning it off means" stay attached to real behaviour — the string the doc
# cites as evidence is actually in the code.
assert_contains "$RM"  'no-autorestore' "README documents how to skip it just once"
assert_contains "$SRC" 'no-autorestore' "the code actually reads no-autorestore"
assert_contains "$RM"  'older than 7 days' "README documents the manifest-staleness warning text"
assert_contains "$SRC" 'older than 7 days' "that warning text is actually in the code"
assert_contains "$SRC" 'rc=off' "the rc=off notice is actually in the code"

# ── (3) skill ────────────────────────────────────────────────────────────
assert_rc 0 test -f "$SKILL"
SK=$(cat "$SKILL")
FM=$(sed -n '1,8p' "$SKILL")
assert_eq "$(head -1 "$SKILL")" "---" "it opens with frontmatter"
assert_contains "$FM" "name: fleetmux" "it has a name field"
assert_contains "$FM" "description:" "it has a description field"
assert_eq "$(sed -n '2,8p' "$SKILL" | grep -c '^---$' || true)" "1" "the frontmatter is closed"

# The commands the skill points to must be entry points that actually exist.
for cmd in --status --list --preview --do-broadcast; do
    assert_contains "$SK"  "fmux $cmd" "the skill documents fmux $cmd"
    assert_contains "$SRC" "\"\${1:-}\" = \"$cmd\"" "the $cmd entry point actually exists"
done

# State file paths must be real too — the skill must never cat a file that does not exist.
assert_contains "$SK"  '~/.cache/fmux/hook-' "the skill documents the hook state file"
assert_contains "$SRC" 'STATE/hook-'       "the code actually writes the hook state file"
assert_contains "$SK"  '~/.cache/fmux/manifest' "the skill documents the manifest"
assert_contains "$SRC" 'MANIFEST="${FMUX_MANIFEST:-$STATE/manifest}"' "the manifest path is unchanged"
assert_contains "$SK"  '~/.cache/fmux/hook.log' "the skill documents the audit log"
assert_contains "$SRC" 'STATE/hook.log'       "the code actually writes the audit log"
assert_contains "$SK"  '~/.cache/fmux/finished' "the skill documents finished"
assert_contains "$SRC" 'STATE/finished'       "the code actually writes finished"

# Discipline — drop these sentences and the skill falls back to screen-scraping.
assert_contains "$SK" "read-only" "it pins read-only as the default"
assert_contains "$SK" "Hook state is the fact" "it states the discipline that the hook is fact and the screen is only a rendering"
# Only sessions appear in the list — if the skill still teaches "skip the last row, it is not
# a session," that describes a screen that no longer exists. Measure both the code and the
# skill together for whether that row is gone.
assert_eq "$(grep -c -- '--settings--' "$SKILL" || true)" "0" "the skill no longer mentions the removed settings row"
case "$SRC" in *FMUX_SETTINGS_ROW*) got=yes ;; *) got=no ;; esac
assert_eq "$got" "no" "the code has no settings-row sentinel either"
assert_contains "$SK" "row is a real tmux session" "it pins that every row in the list is a real session"

# The skill is Claude Code only — codex has no concept of skills. README must say so.
assert_contains "$RM" 'Claude Code only' "README states the skill is Claude Code only"
assert_contains "$RM" 'skills/fleetmux/SKILL.md' "README states the skill file path"

# Where the installer says it puts the skill and where README says it goes must agree.
assert_contains "$RM"              '~/.claude/skills/fleetmux' "README's skill install location"
assert_contains "$(cat install.sh)" '.claude/skills/fleetmux'   "install.sh's skill install location"

# ── (4) summon-key docs ─────────────────────────────────────────────────────
# Per-platform constraints are facts, not code, so they can't be measured from code. What can
# be measured is whether the key names README cites as evidence are values the installer's
# presets actually hand out — install.sh's presets are the door through which a teammate
# gets that name.
INST_SH=$(cat install.sh)
for k in 'M-b' 'C-Left' 'M-Left' 'S-Left'; do
    assert_contains "$RM"      "$k" "README explains $k"
    assert_contains "$INST_SH" "$k" "install.sh's presets actually hand out $k"
done

# ── (4)-a does the fact "the suggestion is S-Left" say the same thing on screen, in the
#     docs, and in the code ────────────────────────────────────────────────────────────────
# If the key the installer suggests, README's table/paragraph, and fmux --help's guidance say
# different things, a teammate has no way to know which of the three to trust. Tie all three
# to the same string.
assert_contains "$INST_SH" 'PRESET_SUGGEST=shift' "install.sh's suggested default is shift"
assert_contains "$INST_SH" "shift) printf 'S-Left'" "the shift preset actually produces S-Left"
assert_contains "$INST_SH" "takes the key away from every app in the pane" "the suggestion text says what it takes away"
assert_contains "$INST_SH" "dotfiles that bind S-Left/S-Right to tmux window switching are common" \
    "it recommends a different key to anyone already using this one"
assert_contains "$RM" '`bind -n S-Left` — what `./install.sh` offers' "README's table has a Shift row"
assert_contains "$RM" 'the only prefix-less single keystroke that survives all three' \
    "README states the reasoning for the Shift family"
assert_contains "$RM" 'bind `S-Left`/`S-Right` to' "README states the known risk (window-switching bindings)"
assert_contains "$RM" 'Why a single keystroke is what the installer offers' \
    "README has a paragraph on why a single keystroke"
assert_contains "$RM" 'fmux config unset key_summon_fast   # rewrites the snippet' \
    "README states how to turn it off"
assert_contains "$RM" 'installing the config file alone steals nothing' \
    "README states the config default is still empty"
# The screen (fmux --help) must say the same thing — the old key must not be taught only here.
HELP=$("$FMUXBIN" --help 2>&1) || HELP=''
assert_contains "$HELP" 'S-Left' "fmux --help documents S-Left"
assert_contains "$HELP" 'takes that key from everything in' "fmux --help also states what it takes away"
assert_eq "$(printf '%s' "$HELP" | grep -c "key_summon_fast 'C-Left M-Left'" || true)" "0" \
    "the old suggestion (C-Left M-Left) does not linger in fmux --help"

# The config default must stay split off — the default must not follow the suggestion just
# because the suggestion changed.
assert_eq "$("$FMUXBIN" config get key_summon_fast)" "" "the config default key_summon_fast is still empty"

# The snippet generator must have **no static candidate list** (deploy gate B3). If it did, even
# the default (safe) preset would unbind those keys — erasing bindings we never made, i.e.
# someone else's. README promises right next to it that it "steals no key until you say so."
assert_eq "$(grep -c 'FMUX_TMUX_UNBIND_CANDIDATES' src/*.sh install.sh | grep -v ':0$' | wc -l | tr -d ' ')" "0" \
    "no static candidate list of no-prefix keys exists in the code"
assert_contains "$RM" 'steals no key' "README's promise text is unchanged"

# ── (4)-b does the doc disclose its own verification status (deploy gate B10) ──────────────
# This repo has never once run on macOS or WSL. Writing that table as flat assertion would let
# an unverified claim decide a teammate's first key choice.
assert_contains "$RM" 'How much of this is measured?'  "README discloses the table's verification status"
assert_contains "$RM" 'not something we reproduced'    "it states that unverified rows were not reproduced"
assert_contains "$RM" 'reported' "it marks unverified rows as 'reported'"
assert_contains "$RM" 'bindings (tmux key names), not physical keys' "it discloses what the table measures"

# ── (4)-c does it state that rc is Linux-only (deploy gate B8) ─────────────────────────────
# The fact that the code hangs on /proc must be attached to the doc.
assert_contains "$SRC" '/proc/$1/stat' "the rc verdict actually hangs on /proc"
assert_contains "$RM"  'Linux only'    "README states rc is Linux-only"
assert_contains "$RM"  '/proc'         "README states the reason (/proc)"
assert_contains "$RM"  'macOS — what works and what does not' "it splits out what works and what does not on macOS"
assert_contains "$SRC" 'no /proc (macOS unsupported)' "fmux --rc also states that boundary on screen"

# ── (4)-d does the snapshot=off description match the code (deploy gate B9) ────────────────
# The hook path's upsert is **outside** the switch — that's why the manifest never goes
# stale. The old sentence was disproven.
assert_eq "$(grep -c 'the manifest stops being updated' "$README" || true)" "0" \
    "the disproven sentence ('manifest stops being updated') is not in README"
assert_contains "$RM" 'unconditional `fmux_mf_upsert`' "README cites the actual behaviour as evidence"
assert_contains "$SRC" 'fmux_mf_upsert "$sname"' "that upsert actually exists on the hook path"

# ── (4)-e can the install section actually be followed (deploy gate B11) ───────────────────
assert_eq "$(grep -c '<you>' "$README" || true)" "0" "no uncopyable placeholders remain"
# The repo went public on 2026-08-06. README used to say there was no published remote —
# now the opposite must hold, and the claim must match what install.sh actually defaults to.
assert_eq "$(grep -c 'no published remote yet' "$README" || true)" "0" \
    "the obsolete 'no published remote yet' sentence is gone from README"
assert_contains "$RM" 'raw.githubusercontent.com/gabury1/fleetmux' "README gives the real one-liner address"
assert_contains "$(cat install.sh)" 'gabury1/fleetmux' "install.sh defaults to that same address (README does not point somewhere the installer will not go)"
assert_eq "$(grep -l 'OWNER/fleetmux' "$README" install.sh 2>/dev/null | grep -c .)" "0" \
    "no placeholder slug survives in README or install.sh"
assert_contains "$RM" 'export PATH="$HOME/.local/libexec/fmux:$HOME/.local/bin:$PATH"' \
    "README states the PATH line verbatim"
assert_contains "$INST_SH" 'export PATH="%s:%s:$PATH"' "install.sh prints the same line"
assert_contains "$RM" 'command not found' "it states what happens if you don't fix PATH"
assert_contains "$RM" 'Mission Control' "it states that macOS Ctrl+arrow can get taken"
assert_contains "$RM" 'Windows Terminal' "it states Windows Terminal eats Alt+arrow first"
assert_contains "$RM" 'best effort' "it states WSL is best-effort"
assert_contains "$RM" 'vmIdleTimeout' "it states vmIdleTimeout is not the answer"
assert_contains "$RM" 'Task Scheduler' "it states Task Scheduler is needed instead of @reboot cron"

# Preset names must be ones install.sh actually accepts.
for p in safe mac linux wsl; do
    assert_contains "$RM"               "$p" "README states the preset $p"
    assert_contains "$(cat install.sh)" "$p)" "install.sh accepts the preset $p"
done

# ── (5) status bar — do the doc and the snippet say the same thing (deploy gate C1) ────────
# This is the spot t-13 missed entirely: four places (two spots in README, SKILL.md, and
# fmux --help) **flatly asserted** the status-bar tally as a working feature, and the wiring
# code was not in the repo. 100% of teammates would never see that screen. So here we don't
# count sentences — we **render what the snippet actually produces** and match it against the
# doc. Once someone later wires it in, this same judgment automatically demands the opposite
# claim — it's not a net that only runs one direction.
snip=$("$FMUXBIN" --tmux-conf 2>/dev/null) || snip=''
# The snippet no longer names status-right directly — it calls fmux, which does the prepend.
case "$snip" in *status-right*|*--status-bind*) wired=yes ;; *) wired=no ;; esac
# 2026-08-06: it got wired (status_badges, on by default), so the judgment flipped — exactly
# what this block was built to do.
assert_eq "$wired" "yes" "the snippet now wires status-right (fact check)"
if [ "$wired" = no ]; then
    assert_contains "$RM" 'fmux does not wire your status bar' \
        "since nothing is wired, README says it does not attach automatically"
    assert_contains "$RM" 'set -ag status-right' "README tells you the line to add yourself"
    assert_contains "$RM" 'set -g status-interval 5' "README also tells you the refresh-interval line"
    assert_contains "$SK" 'Wiring it into `status-right` is manual' \
        "the skill also assumes someone who has never seen the status bar"
    assert_contains "$("$FMUXBIN" --help 2>/dev/null)" 'not wired automatically' \
        "fmux --help says the same thing"
    # The disproven flat claim must not linger.
    assert_eq "$(grep -c 'Status bar carries the fleet tally' "$README" || true)" "0" \
        "the old claim ('status bar carries the tally') is not in README"
    assert_eq "$(grep -c 'the status-bar tally' "$README" || true)" "0" \
        "the old claim in the macOS Works list is also gone"
    assert_eq "$(grep -c 'the same one the tmux status bar shows' "$SKILL" || true)" "0" \
        "the skill's old claim is also gone"
else
    assert_eq "$(grep -c 'does not wire your status bar' "$README" || true)" "0" \
        "once it is wired, the 'does not attach' notice must not linger"
    assert_contains "$RM" 'status_badges' "README documents the switch that controls it"
    assert_contains "$RM" 'fmux config set status_badges off' "README says how to turn it off"
    assert_eq "$(printf '%s' "$("$FMUXBIN" --help 2>/dev/null)" | grep -c 'not wired automatically' || true)" "0" \
        "fmux --help no longer claims the status bar is not wired"
fi

# ── (6) macOS --boot-restore boundary (deploy gate C2) ─────────────────────────────────────
# The network gate hangs on timeout and getent — neither ships on macOS by default. Yet
# README's macOS **Works** list included --boot-restore. The cron line ends in
# >/dev/null 2>&1, so the failure is silent: a teammate would debug "it's supposed to restore,
# why didn't it" forever.
assert_contains "$SRC" 'timeout 5 getent hosts' "boot-restore's network gate actually hangs on those two"
assert_contains "$RM"  'macOS has neither `timeout`' "README states macOS lacks both"
assert_contains "$RM"  'does not work' "README states plainly that it does not work"
assert_contains "$RM"  'ABORT: no DNS+tcp/443' "it states what symptom this shows up as"
assert_contains "$SRC" 'ABORT: no DNS+tcp/443' "that string is actually in the code"
# --restore (by hand) does not pass through that gate — it works on macOS too. That
# distinction must be in the doc.
assert_contains "$RM" 'fmux --restore` (by hand)' "it states separately that --restore by hand works on macOS"

# ── (7) login-shell detection (deploy gate I4) ──────────────────────────────────────────────
# getent belongs to glibc, so it doesn't exist on macOS -> not a fallback, a hardcoded /bin/bash.
assert_contains "$SRC" 'dscl . -read' "the macOS login-shell fallback is in the code"
assert_contains "$RM"  'dscl . -read' "README documents that fallback"

# ── (8) --yes does not steal a key (deploy gate I3) ─────────────────────────────────────────
# README:106's "steals no key until you say so" and install.sh's --yes used to disagree.
assert_contains "$INST_SH" '--yes goes to safe, stealing no key' "install.sh states that"
assert_contains "$INST_SH" 'elif [ "$ASSUME_YES" = 1 ]; then' "that branch actually exists in the code"
assert_contains "$RM" 'does **not** accept the detected key preset' "README states the boundary of --yes"

# ── (9) Troubleshooting section ─────────────────────────────────────────────────────────────
# The only doc a teammate gets is this one README. The last line of the guide points here.
assert_eq "$(grep -c '^## Troubleshooting' "$README" || true)" "1" "README has a Troubleshooting section"
assert_contains "$RM" '`tt: command not found`' "Q1 — PATH"
assert_contains "$RM" 'The summon key does nothing' "Q2 — summon key"
assert_contains "$RM" 'never does' "Q3 — the pause badge never shows"
assert_contains "$RM" 'never appears in the status bar' "Q4 — status-bar tally"
assert_contains "$RM" 'restores nothing' "Q5 — rc / boot restore"
# The string each answer cites as evidence must actually exist in the code — the FAQ must not
# teach a file or behaviour that does not exist.
assert_contains "$SRC" 'STATE/boot.log'  "the boot.log path exists in the code"
assert_contains "$RM"  '~/.cache/fmux/boot.log' "Q5 documents that log"
assert_contains "$(cat libexec/claude)" 'command -v fmux' "the shim-firing condition Q3 states is real code"
assert_contains "$RM"  'command -v fmux' "Q3 states that condition verbatim"

fmux_test_done
