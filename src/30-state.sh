# Claude working-state pattern — decides "is it running right now" by looking at just one screen
# line (the line above the separator above ❯).
#
# Why this was touched again (2026-08-05): device-refactor was actually thinking, but ✻ didn't
#   show up in the list.
#   The anti-"stuck" guard in 80-view.sh clears ✻ when "the hook hasn't updated in over 20s AND
#   there's no spinner on screen either."
#   The working hook only updates via UserPromptSubmit/PostToolUse, so on a turn that thinks for
#   over 20s without using a tool, the update legitimately stops — that's exactly when this
#   pattern, the secondary evidence, is supposed to save it, and it didn't.
#   Evidence: .superpowers/sdd/screen-evidence/EVIDENCE.md and 7 captures (duplicated in
#   test/fixtures/screen).
#
# Why the five alternatives look the way they do — every one is backed by measurement, and
# test/t-08-working-pat.sh checks them exactly:
#   ① (\([^()]*|· )[Ee]sc to interrupt
#      The old pattern left this as a bare literal → it fired just from this repo's own docs
#      being displayed in a pane (a line that just says "the code has the literal string esc to
#      interrupt written in it" was a measured MATCH).
#      The real forms are only `(3s · esc to interrupt)` and `(esc to interrupt · ctrl+t …)`, so
#      it requires being right after an opening paren or right after a middle dot, which filters
#      out prose echoes.
#   ② \([^()]*[0-9]+[hms] · (↑|↓) ?[0-9.,]+[kKmM]? ?tokens
#      Timer + token counter. **Requiring it to be inside parentheses is the key part** — the old
#      pattern didn't require this, and it caught fmux's own TUI progress line
#      (`3/4 agents done · 17m 52s · ↓ 366.8k tokens`), reading itself as working (measured).
#      The old tail `[0-9]+m?s` forced an s at the end, so it completely missed
#      `(2m · ↑ 5k tokens)`, and since it only knew k, it also couldn't see `1.2M tokens` →
#      broadened to [hms] and [kKmM].
#   ③ (glyph) [^ ()]*(…|\.\.\.) ?\(?[0-9]
#      The spinner body. The old `[A-Za-z]+…` broke on the é in `✻ Sautéed… (12s`, causing a
#      false negative (measured), and the ellipsis only accepted U+2026, so another false
#      negative when the terminal rendered it as `...`. The reason `*` was added to the glyph
#      alternation is also measurement — `* Deliberating… (11s` has no token counter, so ②
#      couldn't save it, and all three old alternatives missed it.
#   ④ (glyph) [A-Za-z]*ing for [^ ]
#      `✻ Waiting for 1 dynamic workflow to finish` (the actual line 9 of a WORKING capture).
#      Being present-progressive, it's grammatically distinguished from a completed line (past
#      tense) — the only safe side among the "for" forms.
#   ⑤ (glyph) [^ ]+ for [0-9]+h   ← ❌ existed and was **removed** (2026-08-05, pre-install gate).
#      Why it was added: EVIDENCE.md flagged `✻ Sautéed for 1h 10m 46s` as a spinner.
#      Why it was removed — that basis collapsed under measurement:
#        · `grep -al 'Saut' screen-evidence/*.screen test/fixtures/screen/*.screen` = **0 hits**.
#          A "present-progressive for line at the hour(h) unit" doesn't exist in any capture.
#          Net gain is 0.
#        · Every for-line that actually exists in the captures is a **past-tense completion
#          line**: `✻ Baked for 11m 42s` (device-refactor's actual selected line) ·
#          `✻ Worked for 7m 32s` · `✻ Churned for 13m 39s` · `✻ Brewed for 21s`.
#          If it only grows into hour units (`✻ Baked for 1h 5m 3s`), the grammar is identical,
#          so text alone can't distinguish it → ⑤ was a pure new false positive with 0 gain /
#          confirmed loss (old pattern old=no → new=YES, measured).
#        · And the old claim that "the only place this fires is the branch with no hook" was
#          **wrong**: the working branch of 80-view.sh:186-197 also falls through to the screen
#          check when the hook is stale (>20s) and CPU isn't rc0.
#          In other words, ⑤ caught the completion line of "a session whose over-an-hour turn
#          just ended" and turned ✻ back on, and the completion line stays on screen until the
#          next turn, so it **never turns itself off** — it head-on defeated the very anti-"stuck"
#          guard this whole change was meant to protect. Nothing is lost: `✻ Waiting for …` is
#          still caught fine by ④.
#      ⛔ Do not add back "hour(h)-unit for". If you must, broaden ④, which requires
#         present-progressive (-ing).
#
# Why multibyte characters are written as a literal alternation (✻|✶|…) instead of inside a
# bracket expression: a 3-byte character inside a bracket expression collapses under the C locale
# into a **byte set**, not a character set (matching even just one of ✻'s three bytes passes).
# Alternation is fixed at the character level regardless of locale or grep implementation. Only
# ERE-only syntax is used — \d \s \b {n,m} (?:) and backreferences are GNU/PCRE extensions and
# don't work on BSD grep.
WORKING_PAT='(\([^()]*|· )[Ee]sc to interrupt|\([^()]*[0-9]+[hms] · (↑|↓) ?[0-9.,]+[kKmM]? ?tokens|(✻|✶|✳|✢|✽|·|\*) [^ ()]*(…|\.\.\.) ?\(?[0-9]|(✻|✶|✳|✢|✽|·|\*) [A-Za-z]*ing for [^ ]'

# Waiting-screen check — **the sole witness for clearing a stuck ⏸** (the waiting branch in
# 80-view.sh).
# If the hook has been silent for over 60s and there's no prompt on screen either, it's treated
# as a "canceled approval" and ⏸ is cleared.
# In other words, any prompt UI this doesn't catch **loses its ⏸ from the list** (it stays in
# the status bar, so the two go out of sync — a measured bug).
#
# So this pattern's bias is the opposite of WORKING_PAT's: **casting wide is the safe side.**
#   Miss it → the waiting session goes anonymous in the list (the person never comes back)
#   Catch too wide → a canceled approval turns off a bit late (the next hook event overwrites it
#   anyway)
#
# Which screen each alternative catches:
#   Do you want to        claude tool approval ("Do you want to proceed?" · "…make this edit to X?")
#   Would you like to     claude plan approval ("Would you like to proceed?") — the old pattern
#                         only matched 'to run' and so completely missed plan approval
#   Enter to select       AskUserQuestion / the tail of a selection menu
#                         ("Enter to select · Tab/Arrow keys to navigate · Esc to cancel")
#   Esc to cancel         the back half of the same tail. If the menu is up, one of the two will
#                         remain
#   Press enter to confirm / Yes, proceed    codex approval
#
# ⚠️ Do not put 'esc to interrupt' in here — that's the marker for **working** (WORKING_PAT ①),
#    and adding it would freeze a running session stuck as waiting.
WAITING_PAT='Do you want to|Would you like to|Enter to select|Esc to cancel|Press enter to confirm|Yes, proceed'

# Working check: the spinner always shows on "the one line right above the separator above the
# input box (❯)" — check only that one line.
# (Checking a chunk of the bottom N lines gets false positives/negatives from leftover
# conversation text on screen — got burned twice.)
fmux_working() {
    awk '
        { L[NR] = $0 }
        /^❯/ { p = NR }
        END {
            if (!p) exit
            i = p - 1
            if (i >= 1 && L[i] ~ /^──/) i--
            while (i >= 1 && L[i] ~ /^[ \t]*$/) i--
            if (i >= 1) print L[i]
        }' | grep -qaE "$WORKING_PAT"
}

# ── CPU-delta-based working check ───────────────────────────────────────────
# Why this was added (2026-08-05): the screen check above reads a rendering output, so a single
# glyph or one phrase changing silently breaks it — the entire WORKING_PAT comment block is proof
# of that. In contrast, "is that process burning CPU right now" is kernel accounting, unrelated
# to TUI text. So it's **inserted ahead of the screen check, not replacing it**.
#
# ⚠️ This signal is used **only as grounds to turn ✻ on**. Never as grounds to turn it off.
#    Since this bug was "wrongly clearing the ✻ of a session that was actually working," only a
#    placement that adds zero new deletion paths is safe. So fmux_cpu_busy's rc has 3 values:
#    0=working / 1=not / **2=undecidable**.
#    The moment "don't know" collapses into "no," ✻ disappears again — the caller decides how to
#    collapse it, in its own context.
#
# Design axis: --list is the path that opens the popup and must render instantly → a synchronous
# 3-second sampling can't be put in.
# So it uses **the delta against the snapshot left by the previous call** (same existing
# convention of keeping state in one line of a small file).
# The sampler is the status bar — `#(fmux --status)` in .tmux.conf runs every 5 seconds via
# status-interval 5, and refreshes the snapshot of working sessions. So the popup, whenever
# opened, instantly gets a fresh 3~10 second window.
# In an environment with no status bar (no attached client), the window always exceeds MAXWIN,
# so it's always rc 2 → behavior becomes exactly the same as before this was introduced (the
# screen check). There's no regression path.
#
# Unit: Linux /proc's USER_HZ tick (=fixed 100Hz) and macOS `ps -o time=`'s 1/100 second are the
# same unit, so **both platforms use the same arithmetic and the same threshold**. The only thing
# that differs is "the one line that reads the counter."
#
# Threshold basis — measured directly on this Pi (utime+stime at 1Hz, 7 claude sessions, 177
# seconds total, cross-checked against hook state):
#   Average per second: working 15.9 / 23.0 / 23.9 / 25.3 cs/s   idle 1.4 / 1.4 / 1.6 cs/s
#   By window length (min working vs max idle):
#     1s  working 2.00 vs idle 6.00   *** overlap ***     ← a 1~2 second window can't separate
#                                                            the two classes
#     2s  working 5.00 vs idle 5.50   *** overlap ***
#     3s  working 4.00~6.00 vs idle 4.00~5.00
#     5s  working 5.20~6.00 vs idle 3.20~4.00
#    20s  working 10.70~12.35 vs idle 2.15~2.85
#   Error rate by threshold: win3 th6 → false-neg 0~2.3% false-pos 0% | win3 th4 →
#                    false-pos 0.3~2.9% (idle bursts)
#                    win5 th10 → false-neg 26.4% (misses long thinking stretches)
#   In other words MINWIN=3 isn't a compromise but a line drawn by the data, and 6 is the only
#   value where false-neg and false-pos are both at their floor simultaneously.
#   The error is asymmetric, which is why this narrow margin is acceptable — a false negative is
#   still caught by the screen check as the third-priority fallback, and a false positive isn't a
#   newly created error since the hook is already working.
# Why MAXWIN is needed: a long window gets diluted. Plug in the stuck case where a turn was
#   canceled with Esc — worked 10s then stopped, queried 5 minutes later →
#   (25×10 + 1.5×290)/300 = 9.8 cs/s, crossing the threshold, so **the CPU signal becomes a
#   weapon that revives a stuck state**. Capping it at 60s means that window never forms in the
#   first place.
# Only overridable via environment variable, and deliberately not in the FMUX_CONF_KEYS whitelist —
#   this isn't a user setting, it's a tuning knob (if the TUI render cost changes in the future,
#   only this gets touched).
#   ⚠ A value that has become a config key must not be left as a `${VAR:-default}` global like
#   this: that global's name becomes exactly the env variable name for that key, so the
#   precedence rule permanently becomes "env wins," which kills the config file (this actually
#   happened to log_max — see the retrospective in 10-util.sh).
FMUX_CPU_BUSY=${FMUX_CPU_BUSY:-6}              # cs/s. 6% of one core
FMUX_CPU_MINWIN=${FMUX_CPU_MINWIN:-3}          # seconds. A window shorter than this is undecidable (1~2s overlaps with idle)
FMUX_CPU_MINWIN_COARSE=${FMUX_CPU_MINWIN_COARSE:-20}  # seconds. The floor when counter resolution is 1 second (=100cs)
FMUX_CPU_MAXWIN=${FMUX_CPU_MAXWIN:-60}         # seconds. A window longer than this is diluted and untrustworthy → undecidable
FMUX_CPU_ROTATE=${FMUX_CPU_ROTATE:-3}          # seconds. Sample rotation interval (if called earlier than this, the file isn't touched)
FMUX_STUCK_AFTER=${FMUX_STUCK_AFTER:-180}      # seconds. How long a `working` hook may stay silent before the status bar asks CPU for a second opinion

# macOS/BSD fallback: `ps -p <pid> -o time=` → centiseconds. Sets FMUX_CPU_CS and FMUX_CPU_Q.
#   `ps -o %cpu=` is not used — on Linux it's a **lifetime average** (measured: a session that
#   worked for 36 minutes still read 17.8% after going idle), so it can't distinguish "is it
#   working right now" at all, and BSD's decaying average has an undocumented constant. Above
#   all, using it would give Mac and Linux different rules, different thresholds, different
#   tests — with two branches, one of them will inevitably rot silently. Go with one algorithm,
#   one threshold.
#   The TIME format accepts all of [[DD-]HH:]MM:SS[.cc]. The `10#` prefix is mandatory — without
#   it 08/09 get read as octal and the arithmetic dies instantly. If there's a decimal point the
#   resolution is 1cs (Mac), if not it's 100cs (second-granularity ps) → the caller widens the
#   minimum window to 20s to block quantization false positives. Built to not break even without
#   checking on real Mac hardware.
fmux_cpu_cs_ps() {
    FMUX_CPU_CS=""; FMUX_CPU_Q=100
    local t d=0 h=0 m=0 s=0 frac=0
    t=$(ps -p "${1:-0}" -o time= 2>/dev/null | tr -d ' ') || return 1
    [ -n "$t" ] || return 1
    case "$t" in *-*) d=${t%%-*}; t=${t#*-} ;; esac
    case "$t" in *.*) frac=${t##*.}; t=${t%.*}; FMUX_CPU_Q=1 ;; esac
    case "$t" in
        *:*:*) h=${t%%:*}; t=${t#*:}; m=${t%%:*}; s=${t##*:} ;;
        *:*)   m=${t%%:*}; s=${t##*:} ;;
        *)     s=$t ;;
    esac
    # Normalize the fractional part to exactly two digits (.5 → 50, .123 → 12). Empty fields are
    # all blocked since 10#"" arithmetic dies instantly.
    case "$frac" in '') frac=0 ;; ?) frac="${frac}0" ;; ??) ;; *) frac=${frac%"${frac#??}"} ;; esac
    for t in "$d" "$h" "$m" "$s" "$frac"; do
        case "$t" in ''|*[!0-9]*) return 1 ;; esac
    done
    FMUX_CPU_CS=$(( ((10#$d * 24 + 10#$h) * 3600 + 10#$m * 60 + 10#$s) * 100 + 10#$frac ))
    return 0
}

# utime+stime centiseconds → global FMUX_CPU_CS, resolution → FMUX_CPU_Q. rc 1 = couldn't read
#   (permission / process gone).
#   Linux reads /proc directly, so it's **zero forks** (measured at 0.5ms per call). The screen
#   check forks 3 times per session — the CPU check is an order of magnitude cheaper. So putting
#   CPU ahead of the screen check actually makes the popup faster.
#   comm is inside parentheses and can contain spaces/parens → it must be cut with `##*') '`'s
#   longest right-side match or it breaks.
#   The 1st field of what remains after cutting is state, so utime (field 14 in the original) =
#   arr[11], stime (15) = arr[12].
#   ⛔ **Never add** cutime/cstime (fields 16, 17): the moment a child is reaped, that child's
#      lifetime CPU jumps wholesale onto the parent's counter, creating a fake spike of hundreds
#      of cs/s in a single window. Mac's `ps -o time=` doesn't count children either, so doing it
#      this way makes both platforms measure exactly the same thing.
#   USER_HZ is hardcoded to 100 (confirmed getconf CLK_TCK=100 on this Pi). Calling getconf would
#   add one more fork, and alpha/ia64, where it's 1024, aren't fmux targets.
#   FMUX_PROC is for test injection — feed it a fake /proc to exercise the whole path with no real
#   process.
fmux_cpu_read() {
    FMUX_CPU_CS=""; FMUX_CPU_Q=1
    local pid="${1:-0}" f line rest u s g
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    [ "$pid" -gt 0 ] || return 1
    f="${FMUX_PROC:-/proc}/$pid/stat"
    if [ -r "$f" ]; then
        line=""
        read -r line < "$f" 2>/dev/null || return 1
        rest=${line##*') '}
        [ "$rest" != "$line" ] || return 1        # no comm parens = not /proc stat format
        local arr
        g=0; case $- in *f*) g=1 ;; esac          # fields are all numeric, but block globbing at the source anyway
        set -f
        arr=( $rest )
        [ "$g" = 1 ] || set +f
        u="${arr[11]:-}"; s="${arr[12]:-}"
        case "$u" in ''|*[!0-9]*) return 1 ;; esac
        case "$s" in ''|*[!0-9]*) return 1 ;; esac
        FMUX_CPU_CS=$(( u + s ))
        FMUX_CPU_Q=1                                # 1 tick = 1cs
        return 0
    fi
    fmux_cpu_cs_ps "$pid"
}

# Snapshot file rotation. Format is one line, 5 fields: "<pid> <ts1> <cs1> <ts2> <cs2>" (same
#   shape as hook-<sid>).
#   Why there are **two** samples — this is the core trick of the design. Keeping just one
#   collides "the minimum window length (3s)" with "the refresh period (5s)": right after the
#   status bar overwrites it, the window the reader encounters is 0~5s, so roughly half the time
#   it fails to clear the floor. Holding two means that when the newest sample is too young, the
#   previous one can be used instead, so there's always a valid window no matter the call timing
#   (actual trajectory: newest 0~5s / previous 5~10s).
#   If called again within ROTATE, the file isn't touched at all — so mashing the popup open
#   doesn't collapse the window to 0 seconds, nor does it pile up writes to the SD card.
#   Why now is taken as an argument: the caller (--list / --status) has already called date once.
#   If not passed in, it's called here.
fmux_cpu_sample() {
    local sid="${1:-}" pid="${2:-0}" now="${3:-}" f cpid ts1 cs1 ts2 cs2 tmp d
    [ -n "$sid" ] || return 0
    case "$pid" in ''|*[!0-9]*) return 0 ;; esac
    [ "$pid" -gt 0 ] || return 0
    case "$now" in ''|*[!0-9]*) now=$(date +%s) ;; esac
    f="$STATE/cpu-$sid"
    ts2=0; cs2=0
    if [ -f "$f" ]; then
        cpid=""; ts1=""; cs1=""
        read -r cpid ts1 cs1 _ _ < "$f" 2>/dev/null || true
        case "${cpid:-}" in ''|*[!0-9]*) cpid=0 ;; esac
        case "${ts1:-}" in ''|*[!0-9]*) ts1=0 ;; esac
        case "${cs1:-}" in ''|*[!0-9]*) cs1=0 ;; esac
        # if pid differs, throw away the old sample wholesale (guards against pid reuse / agent restart)
        if [ "$cpid" = "$pid" ] && [ "$ts1" -gt 0 ]; then
            # ⛔ Reject a negative delta first. If now < ts1 (= a future timestamp got baked into
            #    the file), `-lt ROTATE` is **permanently true**, so it returns immediately every
            #    time here, and the file never gets updated again → fmux_cpu_busy keeps returning
            #    rc 2 because the window is negative → the CPU-delta check dies entirely.
            #    This actually happens from NTP correction, manual clock changes, or suspend.
            #    Since it's a freeze with no recovery path, this is the one spot where
            #    "it self-heals on the next tick" does not hold.
            d=$(( now - ts1 ))
            if [ "$d" -ge 0 ]; then
                if [ "$d" -lt "$FMUX_CPU_ROTATE" ]; then return 0; fi
                ts2=$ts1; cs2=$cs1          # normal rotation
            fi
            # if d < 0, don't carry the old sample forward (keep ts2=0) and let it be overwritten
            # below with the new sample
        fi
    fi
    fmux_cpu_read "$pid" || return 0
    mkdir -p "$STATE" 2>/dev/null || return 0
    # tmp+mv — so the reader never encounters a half-written line. Split by $$ so it's safe even
    # if --status and --list overlap.
    tmp="$f.$$"
    if printf '%s %s %s %s %s\n' "$pid" "$now" "$FMUX_CPU_CS" "$ts2" "$cs2" > "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$f" 2>/dev/null || rm -f "$tmp"
    else
        rm -f "$tmp"
    fi
    return 0
}

# CPU delta check. rc 0 = working / rc 1 = not working / **rc 2 = undecidable**.
#   Every case that produces rc 2 is enumerated below — this is so a rotten file never gets
#   misjudged using a stale value:
#     no snapshot (warm-up) · pid missing/mismatched · a field isn't numeric · window < minimum ·
#     window > MAXWIN · negative delta (counter reset) · couldn't read either /proc or ps
#     (process gone / permission).
#   The check is integer multiplication only — no division, no fractions (bash 3.2-safe).
#   The window is wall-clock (date) while the counter is CPU time → NTP jumps and suspend distort
#   the window.
#   Both a negative window and exceeding MAXWIN are blocked, dropping that case to undecidable.
#   The reason it "self-heals on the next tick" is that fmux_cpu_sample overwrites the file on a
#   negative delta — without that guard, it's the sampler (not here) that freezes, permanently
#   locking in rc 2 (which is why the two are a pair).
fmux_cpu_busy() {
    local sid="${1:-}" pid="${2:-0}" now="${3:-}" f cpid ts1 cs1 ts2 cs2 win minwin oldcs d
    [ -n "$sid" ] || return 2
    case "$pid" in ''|*[!0-9]*) return 2 ;; esac
    [ "$pid" -gt 0 ] || return 2
    f="$STATE/cpu-$sid"
    [ -f "$f" ] || return 2
    cpid=""; ts1=""; cs1=""; ts2=""; cs2=""
    read -r cpid ts1 cs1 ts2 cs2 < "$f" 2>/dev/null || return 2
    case "$cpid" in ''|*[!0-9]*) return 2 ;; esac
    [ "$cpid" = "$pid" ] || return 2
    case "$ts1" in ''|*[!0-9]*) return 2 ;; esac
    case "$cs1" in ''|*[!0-9]*) return 2 ;; esac
    case "${ts2:-}" in ''|*[!0-9]*) ts2=0 ;; esac
    case "${cs2:-}" in ''|*[!0-9]*) cs2=0 ;; esac
    case "$now" in ''|*[!0-9]*) now=$(date +%s) ;; esac
    fmux_cpu_read "$pid" || return 2
    # minimum window = max(MINWIN, resolution/threshold). If resolution is 1 second (ps), the
    # moment an idle process crosses one tick it reads as 33 cs/s in a 3-second window, causing a
    # false positive → only then is the window widened to 20 seconds.
    minwin=$FMUX_CPU_MINWIN
    if [ "${FMUX_CPU_Q:-1}" -gt 1 ] && [ "$FMUX_CPU_MINWIN_COARSE" -gt "$minwin" ]; then
        minwin=$FMUX_CPU_MINWIN_COARSE
    fi
    oldcs=""
    win=$(( now - ts1 ))
    if [ "$win" -ge "$minwin" ] && [ "$win" -le "$FMUX_CPU_MAXWIN" ]; then
        oldcs=$cs1                                  # the newest sample forms a sufficiently long window
    elif [ "$ts2" -gt 0 ]; then
        win=$(( now - ts2 ))                        # the newest sample is too young → widen the window using the previous sample
        if [ "$win" -ge "$minwin" ] && [ "$win" -le "$FMUX_CPU_MAXWIN" ]; then oldcs=$cs2; fi
    fi
    [ -n "$oldcs" ] || return 2
    d=$(( FMUX_CPU_CS - oldcs ))
    [ "$d" -ge 0 ] || return 2                      # the counter went backward = pid reuse/reset
    if [ "$d" -ge $(( FMUX_CPU_BUSY * win )) ]; then return 0; fi
    return 1
}

# ── Shared helpers ───────────────────────────────────────────────────────────
# Session names can contain spaces, slashes, regex metacharacters — all of it. Treating that as a
# field separator or regex breaks parsing (instant status-bar death) or kills the wrong session —
# the helpers below collect that logic in one place.
#
# tmux target notation rules (shared by every caller):
#   -t "=name"    session target (kill-session · rename-session · switch-client · attach · list-panes -s)
#   -t "=name:"   pane target (display-message · capture-pane · send-keys) — the colon means
#                 "that session's current window"
#   '=' requires an exact match. Without it, tmux does prefix matching, so 'zzhpfx' picks up
#   'zzhpfx2' (demonstrated) — if kill/send-keys goes out in that state, the wrong session dies
#   or a prompt gets jammed into someone else's window.
#   Drop the colon from a pane target and '=name' doesn't resolve at all, silently returning an
#   empty value (measured).

# Serializes finished-file mutation. --status is a read-modify-write called by the status bar
# every 5 seconds, and the idle hook is a rewrite+append — if they overlap, an away-completion
# notification silently disappears (lost update, deterministically reproducible).
# Same flock pattern as rc-check. fd 9 releases automatically if the process dies, so keep the
# critical section short.
fmux_finished_lock() {
    mkdir -p "$STATE"
    command -v flock >/dev/null 2>&1 || return 0
    exec 9>"$STATE/finished.lock" 2>/dev/null || return 0
    flock 9 2>/dev/null || true
    return 0
}
fmux_finished_unlock() { exec 9>&- 2>/dev/null || true; return 0; }

# The finished format is "<ts> <name>" — ts comes first, name is the last field.
#   The old format ("<name> <ts>") had `read -r name ts` split "my proj 1784…" into name=my/ts=proj,
#   which killed $((now-ts)) instantly with a set -u/arithmetic error. The status-bar badge
#   disappeared entirely, and the poison line stayed in the file permanently, so every subsequent
#   run kept dying too (fatal). Pushing the name to the end is safe no matter how many spaces it
#   has.
#   Normalized here in one pass so the reader still accepts the old format too, and lines with no
#   numeric ts are dropped.
#   Giving FMUX_FIN_SKIP (an env var) a name also erases that session's old records — this used to
#   be done with a sed regex, but if the name contained a `/`, a parse error (exit 4) got
#   swallowed by `|| true` and duplicates piled up.
#   Why ENVIRON is used instead of an awk variable: -v interprets backslashes in the value as
#   escapes, mangling the name.
FMUX_FIN_NORM='
    BEGIN { skip = ENVIRON["FMUX_FIN_SKIP"] }
    {
        if ($1 ~ /^[0-9]+$/)                  { t = $1;  s = $0; sub(/^[0-9]+[ \t]+/, "", s) }
        else if (NF > 1 && $NF ~ /^[0-9]+$/)  { t = $NF; s = $0; sub(/[ \t]+[0-9]+[ \t]*$/, "", s) }
        else next
        if (s != "" && s != skip) print t " " s
    }'

# Normalize (+ optionally remove) then replace in place. Only call this while holding the lock.
fmux_finished_rewrite() {
    local f="$STATE/finished"
    [ -s "$f" ] || return 0
    if FMUX_FIN_SKIP="${1:-}" awk "$FMUX_FIN_NORM" "$f" > "$f.tmp" 2>/dev/null; then
        mv -f "$f.tmp" "$f"
    else
        rm -f "$f.tmp"
    fi
    return 0
}

# Decides whether a hook file "belongs to this session." rc 0 = trustworthy, rc 1 = untrustworthy
#   (stale or missing).
#   Why this is needed: on reboot, tmux reissues session ids starting from $0. If a dead
#   session's hook-<id> is left behind, a new tool session that gets the same number inherits
#   someone else's state file and gets misclassified as an agent (measured 2026-07-25: DB and
#   DOCKER, which were lazydocker, ended up sitting in the agent group at the top of the list).
#   Two kinds of evidence — either one alone is accepted:
#     ① The agent pid the hook recorded is still alive = that process is evidence right this
#        moment.
#     ② Even if it couldn't record a pid (0, when climbing the parent chain fails), the recorded
#        timestamp is after the session's creation time = the file was written after this
#        session came into being, so it wasn't inherited.
#   If the session's creation time can't be obtained, it's folded to 0 and passed leniently like
#   before (no basis to judge → the harmless side).
fmux_hook_valid() {
    local hf="$1" created="${2:-0}" hts hpid
    [ -f "$hf" ] || return 1
    hts=0; hpid=0
    # The hook file format is "<state> <recorded-ts> <pid>" — state isn't used here (discarded into _)
    read -r _ hts hpid < "$hf" 2>/dev/null || true
    case "$hpid" in ''|*[!0-9]*) hpid=0 ;; esac
    case "$hts" in ''|*[!0-9]*) hts=0 ;; esac
    case "$created" in ''|*[!0-9]*) created=0 ;; esac
    # ① If a pid was recorded, its liveness is the final verdict — alive means genuine, dead
    #    means a ghost.
    #    Must not fall through to comparing timestamps here: if a reboot reuses the id, a dead
    #    hook's recorded timestamp can be later than the creation time of the session that newly
    #    received that id, mistaking a ghost for the genuine article (measured 2026-07-25,
    #    hook-6: pid 954169 was dead but passed anyway because hts>created, and it survived).
    if [ "$hpid" -gt 0 ]; then
        kill -0 "$hpid" 2>/dev/null && return 0
        return 1
    fi
    # ② Only fall back to timestamps when a pid couldn't be recorded (parent-chain climb failed → 0)
    [ "$hts" -ge "$created" ] && return 0
    return 1
}

# Decides whether it's an agent session (a session running claude/codex). Argument is a session
#   id ($3…) or a session name.
#   session_created can be passed as the second argument — a caller that already knows it
#   (--list) calls tmux one fewer time. If not passed, it's asked here.
#   Criterion: a hook file confirmed to belong to this session ∨ claude|codex in any pane — the
#   same criterion as the --list grouping check.
#   If the same check is scattered across multiple places, you get accidents like "listed as a
#   tool session but the broadcast keys still fly in."
fmux_is_agent() {
    local t="${1:-}" created="${2:-}" sid c2
    [ -n "$t" ] || return 1
    case "$t" in
        \$[0-9]*)               # a session id is unique on its own — no = prefix needed (adding one actually breaks the match)
            sid="$t"
            [ -n "$created" ] || created=$(tmux display-message -p -t "$sid" '#{session_created}' 2>/dev/null) || created="" ;;
        *)
            IFS=$'\t' read -r sid c2 < <(tmux display-message -p -t "=$t:" $'#{session_id}\t#{session_created}' 2>/dev/null) || return 1
            [ -n "$created" ] || created="$c2" ;;
    esac
    [ -n "$sid" ] || return 1
    fmux_hook_valid "$STATE/hook-${sid#\$}" "${created:-0}" && return 0
    tmux list-panes -s -t "$sid" -F '#{pane_current_command}' 2>/dev/null | grep -qxE 'claude|codex'
}

# Broadcast execution — injects only into agent sessions.
#   Typing a prompt into a tool session (yazi · lazydocker · a bare shell) either executes the
#   sentence as a shell command or gets eaten as a TUI shortcut (r=restart in lazydocker). Since
#   it's a safety-incident path, don't skip it silently — show that it was skipped.
fmux_broadcast() {
    local msg="$1" s sent=0 skipped=0 names=""
    shift
    for s in "$@"; do
        [ -n "$s" ] || continue
        # a separator line isn't a session — this is the last line of defense, so it's filtered here too.
        case "$s" in ─*) continue ;; esac
        if ! fmux_is_agent "$s"; then
            skipped=$((skipped + 1)); names="$names $s"; continue
        fi
        tmux send-keys -t "=$s:" -l "$msg"
        tmux send-keys -t "=$s:" Enter
        sent=$((sent + 1))
    done
    printf '→ sent to %d sessions\n' "$sent"
    [ "$skipped" -gt 0 ] && printf '  skipped %d tool sessions:%s\n' "$skipped" "$names"
    return 0
}

# Sweeps orphan and ghost hook files. Catches both kinds:
#   ① orphan — a file for a session id that no longer exists.
#   ② ghost  — the id is alive, but the file isn't 'that session's, right now.'
#      After a reboot tmux reissues session ids starting from $0 → a new session inherits a dead
#      session's state file as-is. Back when only ① was cleaned up, this survived wholesale and a
#      tool session got misclassified as an agent (measured). The check uses the single
#      fmux_hook_valid, the same one fmux_is_agent uses — if "the criterion for deleting" and "the
#      criterion for trusting" diverge, you get the contradiction of deleting it and then
#      trusting it again.
#   If the list of live ids can't be obtained, the sweep is skipped (safe). Shared by the boot
#   hook and --restore.
fmux_sweep_hooks() {
    local live lsout sid created hf id
    lsout=$(tmux ls -F $'#{session_id}\t#{session_created}' 2>/dev/null) || return 0
    [ -n "$lsout" ] || return 0
    # id → created lookup table, as one string (associative arrays are bash-4-only — they break on Mac's default 3.2)
    live=" "
    while IFS=$'\t' read -r sid created; do
        [ -n "$sid" ] || continue
        live="$live${sid#\$}=${created:-0} "
    done <<< "$lsout"
    #   The CPU snapshot (cpu-<id>) is deleted together too — it has to be tied to the hook
    #   file's lifetime, or you get the same "deleted but trusted again" contradiction. Its
    #   prefix differs, so it doesn't get caught by the hook-* glob above.
    for hf in "$STATE"/hook-*; do
        [ -f "$hf" ] || continue
        id=${hf##*/hook-}
        case "$live" in
            *" $id="*)
                created=${live#*" $id="}; created=${created%% *}
                fmux_hook_valid "$hf" "${created:-0}" || rm -f "$hf" "$STATE/cpu-$id" ;;   # ② ghost
            *) rm -f "$hf" "$STATE/cpu-$id" ;;                                           # ① orphan
        esac
    done
    # The last prompt (last-<id>) is handled together too. **No separate check is created for
    #   it** — the loop above just cleaned up hook files with the same criterion, so "is this
    #   id's hook file still standing" is, in one line, the same check. Splitting it into two
    #   copies would let the criteria drift apart on session-id reuse after a reboot, hanging a
    #   dead session's prompt at the top of a new session's preview — an accident already
    #   suffered with hook-*/cpu-*.
    #   (a tmp file being written is .last-<id>.<pid>, so it doesn't get caught by this glob)
    for hf in "$STATE"/last-*; do
        [ -f "$hf" ] || continue
        id=${hf##*/last-}
        case "$live" in
            *" $id="*)
                created=${live#*" $id="}; created=${created%% *}
                fmux_hook_valid "$STATE/hook-$id" "${created:-0}" || rm -f "$hf" ;;
            *) rm -f "$hf" ;;
        esac
    done
    # Reclaims leftover fragments (.last-<id>.<pid>). The glob above doesn't catch dotfiles, so
    #   this loops once more here.
    #   A fragment is left behind only when the hook died before reaching the mv (SIGKILL / disk
    #   full). The check uses the pid embedded in the name — if that process doesn't exist, this
    #   fragment will never be completed. **A live pid is left untouched**: it might be writing
    #   right now, and deleting it would make the mv fail, losing that prompt entirely. kill -0
    #   is a builtin, so it doesn't add a fork.
    for hf in "$STATE"/.last-*; do
        [ -f "$hf" ] || continue
        id=${hf##*.}
        case "$id" in ''|*[!0-9]*) rm -f "$hf"; continue ;; esac   # not a pid slot = not ours
        kill -0 "$id" 2>/dev/null || rm -f "$hf"
    done
    return 0
}

# JSON shallow string value → global FMUX_JV (same rule as rc_val, but zero forks).
#   Calling $(rc_val …) on the hook path spins up an extra subshell per event — since the hook is
#   called several times a second, only here does it return via a global instead of stdout. (The
#   rc-checking code still uses rc_val as-is.)
fmux_jv() {
    FMUX_JV=""
    local re="\"$2\"[[:space:]]*:[[:space:]]*\"([^\"]*)\""
    [[ "$1" =~ $re ]] || return 1
    FMUX_JV="${BASH_REMATCH[1]}"
    return 0
}
