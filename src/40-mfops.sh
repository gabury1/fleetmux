# Serializes manifest mutations.
#   Why fd 8: fd 9 is already used by the finished/rc lock — the idle hook can hold both
#   locks at once, and using the same fd would close one lock out from under the other.
#   This is also called from the hook path, so the wait stays short. If we can't get the
#   lock, we just give up on this one write — if the manifest delayed the hook's actual
#   job (status updates, completion notifications), that would be the tail wagging the dog.
fmux_mf_lock() {
    local d="${MANIFEST%/*}"
    [ -d "$d" ] || mkdir -p "$d" 2>/dev/null || return 1
    command -v flock >/dev/null 2>&1 || return 0
    exec 8>"$MANIFEST.lock" 2>/dev/null || return 1
    flock -w 2 8 2>/dev/null || return 1
    return 0
}
fmux_mf_unlock() { exec 8>&- 2>/dev/null || true; return 0; }

# Prints that session's manifest line verbatim (empty output if none)
fmux_mf_row() {
    local line t=$'\t'
    [ -f "$MANIFEST" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in "$1$t"*) printf '%s' "$line"; return 0 ;; esac
    done < "$MANIFEST"
    return 0
}

# upsert — swaps in that session's line (appends if none exists).
#   ① If the content is unchanged, the file isn't written at all. The hook can fire
#      several times a second, and writing every time would just waste disk and hook
#      latency for nothing.
#   ② An empty-string argument means "don't know this time" → keep the existing value.
#      '-' means "confirmed absent" (overwrite). What each hook knows differs by event
#      (codex hooks have no conversation id, and the pane command isn't "claude" while a
#      tool is running) — if an unknown field wiped the existing record, restore would
#      quietly break.
#   ③ Written with zero forks (string ops + the printf builtin). Only one mv, and only
#      when something actually changed.
#   ④ The 6th field, "conversation home," follows the same rule. The hook is the only
#      place that knows this value precisely, from the cwd in stdin JSON — because it's
#      exactly the value claude itself uses to compute its own conversation folder.
fmux_mf_upsert() {
    local name="$1" cwd="$2" kind="$3" cmd="$4" conv="$5" chome="${6:-}"
    local t=$'\t' line old="" o row out="" found=0
    [ -n "$name" ] || return 0
    case "$name" in *"$t"*) return 0 ;; esac   # a name containing a tab would break the format — give up on recording it
    case "$cwd$kind$cmd$conv$chome" in *"$t"*) return 0 ;; esac
    fmux_mf_lock || return 0
    # Pass 1: look at the old line first (to preserve unknown fields we need the old values before building the new line)
    if [ -f "$MANIFEST" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in "$name$t"*) old="$line"; break ;; esac
        done < "$MANIFEST"
    fi
    if [ -n "$old" ]; then
        # The old line may have only 5 fields (recorded before the 6th was introduced) — in that case there's no chome slot, so it stays empty
        o=${old#*$t}; [ -n "$cwd" ]  || cwd=${o%%$t*}
        o=${o#*$t};   [ -n "$kind" ] || kind=${o%%$t*}
        o=${o#*$t};   [ -n "$cmd" ]  || cmd=${o%%$t*}
        o=${o#*$t};   [ -n "$conv" ] || conv=${o%%$t*}
        case "$o" in
            *"$t"*) o=${o#*$t}; [ -n "$chome" ] || chome=${o%%$t*} ;;
        esac
    fi
    [ -n "$cwd" ]   || cwd="-"
    [ -n "$kind" ]  || kind="tool"
    [ -n "$cmd" ]   || cmd="-"
    [ -n "$conv" ]  || conv="-"
    [ -n "$chome" ] || chome="-"
    # Conversation id must be a uuid only — if a mistimed value like "claude" gets in here,
    # the integrity check would reject every write after it, freezing the whole manifest
    # solid. Filtering it out at the door is cheap.
    fmux_is_uuid "$conv" || conv="-"
    case "$kind" in agent|tool) ;; *) kind="tool" ;; esac
    row="$name$t$cwd$t$kind$t$cmd$t$conv$t$chome"
    [ "$old" = "$row" ] && { fmux_mf_unlock; return 0; }   # unchanged → file untouched
    # Pass 2: replace in place (preserving order — this is a file humans read)
    if [ -f "$MANIFEST" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            [ -n "$line" ] || continue
            case "$line" in
                "$name$t"*)
                    [ "$found" = 0 ] || continue      # if the same name has two lines, clean it up here
                    found=1; out="$out$row"$'\n' ;;
                *) out="$out$line"$'\n' ;;
            esac
        done < "$MANIFEST"
    fi
    [ "$found" = 1 ] || out="$out$row"$'\n'
    fmux_mf_write "$out" || true      # validation failed = keep the existing file (silently give up on this write only)
    fmux_mf_unlock
    return 0
}

# Follows renames — if a tmux session's name changes, the manifest's key must change with it (otherwise restore resurrects a ghost)
fmux_mf_rename() {
    local old="$1" new="$2" t=$'\t' line out="" hit=0
    [ -n "$old" ] && [ -n "$new" ] || return 0
    [ -f "$MANIFEST" ] || return 0
    case "$new" in *"$t"*) return 0 ;; esac
    fmux_mf_lock || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        [ -n "$line" ] || continue
        case "$line" in
            "$old$t"*) hit=1; out="$out$new$t${line#*$t}"$'\n' ;;
            "$new$t"*) ;;                                    # an old line already using the new name loses to the rename
            *) out="$out$line"$'\n' ;;
        esac
    done < "$MANIFEST"
    [ "$hit" = 1 ] && { fmux_mf_write "$out" || true; }
    fmux_mf_unlock
    return 0
}

# Explicit delete — we don't auto-remove a line just because the session died (reviving
#   the dead is this file's whole purpose).
#   The number of lines removed is returned via the global FMUX_MF_HITS.
fmux_mf_forget() {
    local name="$1" t=$'\t' line out=""
    FMUX_MF_HITS=0
    [ -n "$name" ] || return 0
    [ -f "$MANIFEST" ] || return 0
    fmux_mf_lock || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        [ -n "$line" ] || continue
        case "$line" in
            "$name$t"*) FMUX_MF_HITS=$((FMUX_MF_HITS + 1)) ;;
            *) out="$out$line"$'\n' ;;
        esac
    done < "$MANIFEST"
    [ "$FMUX_MF_HITS" -gt 0 ] && { fmux_mf_write "$out" || FMUX_MF_HITS=0; }
    fmux_mf_unlock
    return 0
}

