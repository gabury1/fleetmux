# ── Fleet manifest (snapshot/restore ledger) ────────────────────────────────
# When the Pi dies and comes back, the whole tmux session set evaporates (10 of them really were
# rebuilt by hand once). So "what was floating where, as what" gets written to a file, and
# --restore brings it back to life.
#
# Format (tab-separated, 6 fields. Old 5-field lines still read fine as-is — writing without
# migration naturally produces 6 fields):
#   <name>\t<session cwd>\t<kind: agent|tool>\t<start command or ->\t<conversation id or ->\t<conversation home cwd or ->
#   The reason it's tabs is the same as --list: fields don't shift even when names/paths contain
#   spaces.
#   No empty fields allowed — '-' is the "none" sentinel (read collapses consecutive tabs into
#   one, which would shove fields out of place).
#
# Why the 6th field, "conversation home", exists separately (measured in practice):
#   `claude --resume <id>` doesn't work from just anywhere — it only finds that conversation from
#   'the project folder that corresponds to the current cwd'. But a tmux session's cwd and the
#   cwd the conversation was born in often differ (refact-worker: session cwd=…/_myproject,
#   transcript is under ~/.claude/projects/-home-euns/). Restoring with only the session cwd drops
#   you into the shell with "No conversation found". So the two are recorded separately — restore
#   creates the session at the session cwd, but runs the resume itself from the conversation home.
# TT_MANIFEST lets the path be swapped: an escape hatch so tests don't overwrite the real fleet
# record.
MANIFEST="${TT_MANIFEST:-$STATE/manifest}"

# A conversation id is a uuid. Not "something uuid-like" — only an exact uuid is let through.
#   There was a real incident (2026-07-25) where a field shifted by one slot and a string like
#   "claude" or "agent" sat in the conversation-id slot, propagating through every snapshot after
#   that. --resume on that line makes the conversation look like it vanished entirely.
#   Why case glob instead of [[ =~ ]]: no forks, no regex engine, no shell-implementation gap.
tt_is_uuid() {
    case "${1:-}" in
        [0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]) return 0 ;;
    esac
    return 1
}

# The login shell restore will put in the pane. Never rely on tmux's server-global default-shell.
#   default-shell freezes once, from the parent's $SHELL, when the server is born, and doesn't
#   change until the server dies. If @reboot cron spawns the server, $SHELL=/bin/sh → every pane
#   that server creates becomes dash, and dash doesn't read .bashrc, so claude vanishes from PATH
#   (2026-07-26: 5 agents wiped out). Fixing it with set -g default-shell would affect other
#   people's sessions too, so this is done explicitly per session instead — server-global state
#   stays untouched and the effect is confined to our own session.
#   Why there are two lookup sources (team deployment gate I4): `getent` belongs to glibc, so it
#   **doesn't exist on Mac**. If only the first line existed, this function would be a **constant**
#   on Mac, not a fallback — on a machine where zsh is the default and PATH only lives in
#   ~/.zshrc, the restored pane can't find claude again (a repeat of the incident above). So Mac's
#   user database (Directory Service) is asked a second time via `dscl`. Linux has no dscl and Mac
#   has no getent, so of the two lines, only the one that exists on that machine answers.
#   Why `|| s=''` is attached: this file is under `set -euo pipefail`. A pipeline with a
#   nonexistent command is rc 127, and pipefail propagates that out of the assignment — without
#   this, the function would die silently depending on the calling context.
tt_login_shell() {
    local s u
    u=$(id -un 2>/dev/null) || u=''
    s=$(getent passwd "$u" 2>/dev/null | cut -d: -f7) || s=''
    if [ -z "$s" ] && [ -n "$u" ]; then
        s=$(dscl . -read "/Users/$u" UserShell 2>/dev/null | awk 'NR==1{print $2}') || s=''
    fi
    case "$s" in */bash|*/zsh|*/fish) [ -x "$s" ] && { printf '%s' "$s"; return 0; } ;; esac
    printf '/bin/bash'
}

# Is an agent actually running in the pane — for restore verification. Same criteria as the
# second clause of tt_is_agent.
tt_pane_has_agent() {
    tmux list-panes -s -t "=${1:-}:" -F '#{pane_current_command}' 2>/dev/null \
        | grep -qxE 'claude|codex'
}

# Integrity check before writing — looks at every line of the 'entire file content' passed as an
# argument. Even one bad line → rc 1.
#   A broken manifest spreads silently: a field that's shifted once gets read as the "old value"
#   for the next snapshot, compounding the damage. So the rule is "if in doubt, don't write" —
#   the existing file left in place is always better.
#   Checks: field count is 5 or 6 / no empty fields / kind is agent|tool / conv is '-' or a uuid.
#   Why uuid detection doesn't use regex {n} repetition: interval support differs across awk
#   implementations (BSD awk).
TT_MF_CHECK_AWK='
    function isuuid(s,   i, c) {
        if (length(s) != 36) return 0
        for (i = 1; i <= 36; i++) {
            c = substr(s, i, 1)
            if (i == 9 || i == 14 || i == 19 || i == 24) { if (c != "-") return 0 }
            else if (c !~ /^[0-9a-fA-F]$/) return 0
        }
        return 1
    }
    $0 == "" { next }
    NF != 5 && NF != 6 { bad = 1; exit }
    { for (i = 1; i <= NF; i++) if ($i == "") { bad = 1; exit } }
    $3 != "agent" && $3 != "tool" { bad = 1; exit }
    $5 != "-" && !isuuid($5) { bad = 1; exit }
    END { exit (bad ? 1 : 0) }'
tt_mf_check() { printf '%s' "${1:-}" | awk -F'\t' "$TT_MF_CHECK_AWK"; }

# Atomic manifest replace — only content that passed validation lands. On failure the existing
# file is left untouched.
#   Warnings go to stderr: the hook path is 2>/dev/null so it stays quiet, while a human-run
#   --snapshot will notice it.
tt_mf_write() {
    if ! tt_mf_check "${1:-}"; then
        printf 'fmux: manifest write refused — malformed rows; %s left untouched\n' "$MANIFEST" >&2
        return 1
    fi
    if printf '%s' "${1:-}" > "$MANIFEST.tmp" 2>/dev/null; then
        mv -f "$MANIFEST.tmp" "$MANIFEST" 2>/dev/null || { rm -f "$MANIFEST.tmp"; return 1; }
        return 0
    fi
    rm -f "$MANIFEST.tmp"
    return 1
}

# Rotate 3 generations of backups (.bak → .bak2 → .bak3). Only runs right before a full replace
# (--snapshot).
#   Back when there was only 1 generation, since --snapshot runs on a 1-minute cron, the window to
#   catch an "oops" and recover was 60 seconds — one more bad snapshot and even the one backup
#   gets overwritten with bad content. With 3 generations, there's at least 3 minutes.
tt_mf_backup() {
    [ -f "$MANIFEST" ] || return 0
    [ -f "$MANIFEST.bak2" ] && cp -f "$MANIFEST.bak2" "$MANIFEST.bak3" 2>/dev/null
    [ -f "$MANIFEST.bak" ]  && cp -f "$MANIFEST.bak"  "$MANIFEST.bak2" 2>/dev/null
    cp -f "$MANIFEST" "$MANIFEST.bak" 2>/dev/null
    return 0
}

