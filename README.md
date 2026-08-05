# fleetmux

A tmux cockpit for running a fleet of AI coding agents.

`fmux` shows you — at a glance, without opening a single session — which of your
Claude Code / Codex sessions are **working**, which are **waiting for your approval**,
and which **finished while you were away**. It brings the whole fleet back after a
reboot, conversations included, and quietly repairs Remote Control links when they drop.

One bash file. No runtime to install.

```
  soma1     ● ✻          working right now
  soma2       ⏸          waiting for your approval  ← the one that matters
  general        ✓       finished while you were away
  files                  tool session (yazi)
```

## Why not just read the screen?

The first version scraped the terminal. It failed three times:

1. the "working" line has many shapes — `(26s · ↓ 763 tokens)`, `· Channeling… (11s · thinking with xhigh effort)`
2. an idle session's status bar ticks (rate-limit %), so a screen hash keeps changing
3. merely attaching re-wraps the pane, changing the hash again

**A screen is a rendering, not a fact.** So fmux stopped guessing and let the agent
report its own state, through Claude Code / Codex **hooks**:

```
[claude|codex] ──hook event──▶ fmux --hook <state> ──▶ ~/.cache/tt/hook-<session-id>
  UserPromptSubmit → working                              │
  Stop             → idle                                 ▼
  Notification     → waiting (⏸)                   list · status bar · alerts
  SessionStart     → boot
```

Hooks run as children of the agent process, so they inherit `$TMUX_PANE` — which
means each event knows exactly which tmux session it came from. That mapping is
free here and painful any other way.

## Installing the hooks without touching your settings

fmux never edits your `~/.claude/settings.json`. It puts a wrapper early in `PATH`:

```bash
~/.local/libexec/tt/claude
  inside tmux → exec real-claude --settings "$(fmux --hooks-json)" "$@"
  outside     → exec real-claude "$@"          # transparent
```

Delete the wrapper and every trace of fmux's involvement is gone. Aliases like
`cc='claude'` are covered too — an alias is text substitution, and the `PATH`
lookup happens after it.

The same directory holds a `codex` wrapper. The shim only fires when `tt` is on
`PATH` — the installer links `~/.local/bin/tt → fmux` for exactly that reason.

## Surviving a reboot

A manifest records, per session: `name · cwd · kind · command · conversation-id · conversation home`.
It is written every minute and whenever you open the popup, so there is no
"remember to save" ritual.

```bash
fmux --restore          # tools re-run their command, agents come back with claude --resume <id>
fmux --restore --dry    # just show the plan
```

`--resume`, never `--continue`: `--continue` picks "the latest chat in this folder",
which makes same-cwd sessions clone each other. Ask us how we know.

## Keeping Remote Control alive

> **Linux only.** This one feature needs `/proc/<pid>/stat` (`src/60-rc.sh`) to tie a
> Claude session file to a live process without falling for PID reuse. macOS has no
> `/proc`, so on a Mac the whole rc path is a no-op: `tt --rc` prints `?` for every
> row and the minute cron never injects anything. See [macOS](#macos--what-works-and-what-does-not).

Claude Code's Remote Control bridge drops silently (idle timeouts, after compaction,
overnight). The official fix is "run `/remote-control` again". fmux does it for you —
only when `bridgeSessionId` is actually empty, never while the session is busy, and
it backs off with a `⊘` badge when a session keeps dropping right after a repair.

## Keys

Inside the popup:

| | |
|---|---|
| `→` / Enter | enter session · `←` / Esc close · `^D` detach tmux |
| `^N` `^E` `^X` `^R` | new · rename (syncs the Claude session title) · kill · refresh |
| Tab + Enter | broadcast one prompt to several sessions (tool sessions are skipped) |
| `^B` | same broadcast, but keeps the popup open — for repeated sends |
| `^O` | settings screen — or pick the `⚙ settings` row at the bottom of the list |
| `?` | help |

These in-popup keys are fixed. The `key_new` … `key_settings` config entries exist
but nothing reads them yet — see [Configuration](#configuration).

## Summoning the popup

Two settings, because **one physical key arrives under different names per terminal**:

- `key_summon` — pressed *after* the tmux prefix. Default `F`. One key.
- `key_summon_fast` — prefix-less. Default **empty** (fmux steals no key until you say so).
  It is a *space-separated list*, so you can bind every name the same physical key
  may arrive as.

```bash
tt config set key_summon_fast 'C-Left M-Left'   # rewrites the tmux snippet on the spot
tt config unset key_summon_fast                 # back to prefix-only
```

What to bind where. **The rows are bindings (tmux key names), not physical keys** —
that distinction is the whole problem: one physical key arrives under a different
tmux name on each platform.

| binding you would write | Linux | macOS | Windows Terminal → WSL2 |
|---|---|---|---|
| `prefix + F` — the default | reaches tmux | reaches tmux | reaches tmux |
| `bind -n C-Left` | usually reaches tmux | Ctrl+← is often eaten by Mission Control first | reaches tmux |
| `bind -n M-Left` | usually reaches tmux | Option+← does **not** arrive under this name | Alt+← never arrives — WT moves its own panes |
| `bind -n M-b` | fires on Alt+b — it is not an arrow key here | this is what **Option+←** arrives as | fires on Alt+b |

- **macOS Option+←/→ arrives as `M-b`/`M-f`, not `M-Left`/`M-Right`.** The terminal
  sends `ESC b` for Terminal.app compatibility — Ghostty is reported to do this too,
  even with `macos-option-as-alt` set. Bind `M-b`, not `M-Left`.
- **macOS Ctrl+arrow** is a Mission Control shortcut by default; it may never reach
  tmux. Turn it off in System Settings or pick another key.
- **Windows Terminal** claims `Alt+Arrow` for its own pane navigation before WSL sees
  it. `C-Left` survives.

> **How much of this is measured?** Only the Linux column — this build has never run
> on macOS or under WSL2. The macOS and WSL rows are *reported* behaviour (terminal
> documentation and user reports), not something we reproduced. If you are the first
> to install on either, you are the first measurement: run `./install.sh --dry-run`
> first, and tell us what the keys actually did.

That is why the default is `prefix + F`: it is the only binding that works on every
platform without taking a key away from something else. `./install.sh` offers presets
(`safe` / `mac` / `linux` / `wsl`) and detects the platform, but you can always change
your mind with `tt config set`.

fmux does not edit your `~/.tmux.conf`. It owns one file and borrows one line:

```bash
tt --tmux-conf            # print the snippet — read it before you trust it
tt --tmux-conf --write    # write it, prints the path
# then, once, in ~/.tmux.conf:
source-file ~/.config/fleetmux/tmux.conf
```

Either form of that line is recognised — `~/…`, an absolute path, `-q`, quotes, leading
whitespace. fmux reads your tmux config to decide whether it may re-`source` the
snippet into the tmux server you are sitting in right now, and it only does that if it
finds this line; a comment or a line with the path merely *inside* it does not count.

The snippet is regenerated automatically whenever you change `key_summon`,
`key_summon_fast`, or `snapshot_on_exit`.

## Reading the list

| mark | meaning |
|---|---|
| **bold** / dim | talked within `recent_hours` (default 6h) / quiet |
| accent color | tool session (yazi, lazydocker…) — sorted alphabetically at the bottom |
| ● ✻ ⏸ ✓ ⊘ | attached · working · awaiting you · unseen result · remote control dropped |

`tt --status` prints the fleet tally `⏸2 ✻3` plus a `✓name` badge for work that
finished while you were away — one line, meant for a tmux status bar.

> **fmux does not wire your status bar.** Nothing in the snippet touches
> `status-right`; the tally only appears once *you* add two lines to your own tmux
> config. That is deliberate — `status-right` is a single value, so writing it would
> overwrite whatever you already have there, and fmux's whole discipline is that it
> owns one file and borrows one line. The two lines are in
> [Troubleshooting](#troubleshooting) (Q4).

## Configuration

```bash
tt config list           # every key: current value, and where the value came from
tt config get rc
tt config set rc off
tt config unset rc       # back to the default
tt config path           # where the file is
```

or press `^O` in the popup (also reachable as the `⚙ settings` row at the bottom of
the list). Enter flips a switch on the spot; value keys ask for input and validate it.

The file lives at `~/.config/fleetmux/config` (`$XDG_CONFIG_HOME/fleetmux/config` if
you set that). It is `key=value`, one per line, `#` for comments. fmux **never
`source`s it** — it is read by a whitelist parser, so a typo costs you one warning
line, not the whole cockpit. Precedence is **environment variable > file > default**;
the env var for `recent_hours` is `TT_RECENT_HOURS`, and so on.

### Keys that are wired

| key | default | what reads it |
|---|---|---|
| `rc` | `on` | `--cron`: auto-repair of dropped Remote Control links — **Linux only**, see [macOS](#macos--what-works-and-what-does-not) |
| `snapshot` | `on` | `--snapshot`, and the once-a-minute snapshot inside `--cron` |
| `snapshot_on_exit` | `on` | the tmux snippet's `client-detached` / `session-closed` hooks |
| `boot_restore` | `on` | `--boot-restore` |
| `recent_hours` | `6` | `--list`: bold (recent) vs dim (quiet) session names |
| `unseen_minutes` | `10` | `--status`: how long a `✓name` badge stays in the status bar |
| `accent` | `73` | 256-color number for tool-session names and `--help` headings |
| `log_max` | `1048576` | rotation threshold for `~/.cache/tt/hook.log` and `boot.log` |
| `key_summon` | `F` | the tmux snippet: `bind <key>` (after the prefix) |
| `key_summon_fast` | *(empty)* | the tmux snippet: `bind -n <key>` for each name in the list |

### Keys that are stored but not read yet

`key_new` `key_rename` `key_kill` `key_reload` `key_detach` `key_broadcast`
`key_help` `key_settings`

These validate and save, but **nothing reads them** — the in-popup keys are still
hardcoded. `tt config list` and the settings screen mark such rows `← 미배선`
("not wired"), and `tt config set` says so again on the spot. A toggle that lies is
worse than a missing toggle, so the marker is derived from the code itself rather
than from a hand-kept list.

### What "off" actually means

Turning a switch off stops **future automatic work**. It does not undo work already
done, and it does not touch anything outside fmux.

- **`rc=off`** does not disconnect anything. Links that are already attached stay
  attached; fmux simply stops re-running `/remote-control` for sessions whose bridge
  went empty. The `⊘` badges disappear because nobody is judging any more, not
  because the sessions recovered. `tt --rc` says `rc=off` and prints no table.
- **`snapshot=off`** stops the *sweeps*, not every write. What stops: `--snapshot`
  itself, the once-a-minute snapshot inside `--cron`, the one the popup fires when it
  opens, and the on-exit tmux hooks — i.e. every path that rewrites the manifest
  **wholesale** from the live session list. What keeps going: the hook path. Every
  agent event (`src/50-hook.sh`) ends in an unconditional `tt_mf_upsert`, outside the
  switch, so any session with a live claude/codex in it keeps its row — name, cwd,
  command, conversation id — up to date. Measured in `test/t-15-hook.sh`: with
  `snapshot=off` and no manifest at all, one `--hook working` creates one.
  So the switch does not freeze the manifest. What actually goes stale is everything
  the hooks cannot see: tool sessions, sessions renamed or moved from outside, and
  rows for sessions that have since died (nothing prunes them any more).
- **The 7-day warning is not this switch.** If `~/.cache/tt/boot.log` says
  `manifest is older than 7 days — restoring it anyway`, read it as *nothing has been
  writing the manifest at all* — usually the minute cron line was never installed.
  Restore still runs, and each line is re-validated (live conversation, transcript
  present, cwd exists) before it is used.
- **`boot_restore=off`** makes `--boot-restore` exit early. `--restore`, which you run
  by hand, is unaffected — the switch guards the automatic path only.
- **`snapshot_on_exit=off`** takes the two `set-hook` lines out of the tmux snippet,
  so a *new* tmux server never gets them. A server that is already running keeps the
  hooks it was given until it restarts — the snippet does not un-set them, because
  `set-hook -gu` would also delete a hook of yours that we never installed. Cost of
  the leftover: one extra manifest write when you detach.
- **Your crontab is never touched.** Neither fmux nor `./install.sh` writes to it; the
  installer only prints the two lines for you to paste. With `rc=off` the minute cron
  job still fires and is **not** cheap: `rc=off` skips only the rc round; the snapshot
  in the same tick still runs, and that is the part that talks to tmux the most. If
  you want the tick to be nearly free, turn `snapshot` off too — and if you want the
  job gone, remove it yourself with `crontab -e`.
- For a one-off skip of the next boot restore, without changing config:
  `touch ~/.cache/tt/no-autorestore`.

## Agent skill

`skills/fleetmux/SKILL.md` teaches an agent to read the fleet the same way the popup
does — hook state first, panes only as evidence. `./install.sh` offers to copy it to
`~/.claude/skills/fleetmux/`, or:

```bash
mkdir -p ~/.claude/skills/fleetmux
cp -R skills/fleetmux/. ~/.claude/skills/fleetmux/
```

This is **Claude Code only** — Codex has no skill mechanism. Codex sessions still
report their state through the hook wrapper; they just cannot load this document.

## Requirements

- tmux ≥ 3.2 (`display-popup`), fzf ≥ 0.64 (`--footer`), bash ≥ 3.2, awk
- `flock` is optional. Without it the duplicate-run guard is off (cron rounds can
  overlap, boot restore can double-fire). macOS has no `flock` by default —
  `brew install flock` if you want it.
- Linux and macOS — but **one feature is Linux-only** (Remote Control auto-repair);
  see [macOS](#macos--what-works-and-what-does-not). Windows only through WSL2, with
  caveats — see below.
- State lives in `~/.cache/tt/`. Delete it and you lose the manifest with it — the
  restore table — so what you lose is the next reboot's recovery, not just history.

## Install

**1. Get the repo.** There is no published remote yet, so clone the URL you were given
(or copy the directory over) — then run the installer from inside it:

```bash
cd fleetmux
./install.sh --dry-run      # optional: changes nothing, prints exactly what it would do
./install.sh
```

**2. Put it on your `PATH`.** The installer does not edit your shell startup file; it
prints this line at the end and leaves it to you. Add it to `~/.bashrc`
(`~/.bash_profile` for bash on macOS, `~/.zshrc` for zsh), then open a **new** shell:

```bash
export PATH="$HOME/.local/libexec/tt:$HOME/.local/bin:$PATH"
```

Order matters. `~/.local/bin` is where `fmux` and the `tt` symlink land;
`~/.local/libexec/tt` must come **first**, because that is the hook shim — put it after
the real `claude` and the status marks never appear. Skipping this step is why `tt`
says *command not found*.

**3. Check it.** `tt config list` prints the settings table; `tt` inside tmux opens the
popup.

```
./install.sh --dry-run      change nothing, just print what it would do
./install.sh --yes          accept every proposed default — except the summon key,
                            which stays `safe` (no prefix-less key is taken)
./install.sh --prefix DIR   install somewhere other than ~/.local
./install.sh --preset mac   summon-key preset: safe | mac | linux | wsl
```

`--yes` deliberately does **not** accept the detected key preset. Binding a
prefix-less key is a global change to your tmux — it takes that key away from whatever
else was using it — so it happens only when you name a preset yourself. "Accept the
defaults" must never mean "take two of my keys". Without `--preset`, `--yes` leaves
`key_summon_fast` empty, exactly as the default promises.

Eight steps: dependencies → `~/.local/bin/fmux` (+ the `tt` symlink) → hook shims in
`~/.local/libexec/tt/` → the tmux snippet → summon-key preset → agent skill → cron
instructions → summary. It asks before touching `~/.tmux.conf`, copies the file to
`~/.tmux.conf.fmux-bak` before adding the line, and starts a fresh line if yours did
not end in one. It **never** edits your crontab; it prints the lines and leaves them
to you:

```cron
* * * * * ~/.local/bin/fmux --cron >/dev/null 2>&1
@reboot   ~/.local/bin/fmux --boot-restore >/dev/null 2>&1
```

Re-running the installer is safe. If it stops, it tells you exactly how far it got.

## macOS — what works and what does not

Honest boundary, read from the code rather than guessed. Nothing below was *run* on a
Mac — each row names the line of code it was read from, so you can check us.

| on macOS | verdict | why (read from the code) |
|---|---|---|
| popup · list · hook state (`✻` `⏸` `✓`) · broadcast · `tt config` · summon key · manifest | works | no platform-specific call in the path |
| `tt --status` (fleet tally) | works | but nothing wires it for you on any platform — see [Troubleshooting](#troubleshooting) Q4 |
| `tt --restore` (by hand) | works | process lookup is `ps -o comm=`, which is POSIX (`src/10-util.sh`) |
| `tt --boot-restore` (`@reboot` cron) | **does not work** | its network gate is `timeout 5 getent hosts …` (`src/70-fleet.sh`). macOS has neither `timeout` (GNU coreutils) nor `getent` (glibc), so the check can never pass: it burns the full `TT_BOOT_NETWAIT` (120 s) and then exits 1 with `ABORT: no DNS+tcp/443` in `~/.cache/tt/boot.log`. The cron line ends in `>/dev/null 2>&1`, so it fails **silently**. |
| Remote Control auto-repair (`rc`) | **does not work** | `/proc/<pid>/stat` — see below |
| `bash` itself | works | macOS still ships bash 3.2 as `/bin/bash`, and fmux is written to 3.2 — `test/t-14-bash3.sh` scans the source for bash-4-only syntax so it stays that way |

Two smaller macOS details, both fixed in this build but worth knowing:

- **`flock` is absent**, so the duplicate-run guard is off (`brew install flock`).
  `--boot-restore` logs `warn: flock not found` and continues.
- **The login shell for restored panes** is looked up with `getent passwd` (absent) and
  now falls back to `dscl . -read /Users/"$(id -un)" UserShell` (`src/20-manifest.sh`).
  Before that fallback the answer was a constant `/bin/bash` — on a Mac, where zsh is
  the default, a restored pane would start a shell that never reads your `~/.zshrc`,
  and `claude --resume` would come back `command not found`.

Making `--boot-restore` work on macOS means replacing that gate with a
dependency-free check. It is **not** in this release — until then, do not add the
`@reboot` line on a Mac; run `tt --restore` by hand instead, which skips the gate
entirely.

**Does not work: Remote Control auto-repair (`rc`).** `src/60-rc.sh` identifies the
claude process behind a session with `/proc/<pid>/stat` (field 22, `starttime`) so a
recycled PID cannot be mistaken for the original. macOS has no `/proc`, so that lookup
always fails and everything built on it silently gives up:

- `tt --rc` prints `? no claude found` for every row — that is *unsupported*, not
  broken. It now says so in a line above the table.
- the minute cron never injects `/remote-control`, and the `⊘` badge never appears.
- Everything else in the same cron tick — the fleet snapshot — still runs normally.

**Partly affected: how a conversation id is discovered.** `--snapshot` learns
conversation ids through the same `/proc` lookup, so on macOS it cannot discover a
*new* one. The hook path can, and does: Claude Code's hook payload carries
`session_id` and `cwd`, and `src/50-hook.sh` records both on every event. So an agent
started inside tmux through the `PATH` shim is recorded and comes back with
`--resume`. An agent that never fired a hook (started outside tmux, or before you
installed fmux) keeps `-` in the manifest and will be restored as a plain session.

Fixing rc for macOS is a real port (`ps -o lstart=` instead of `/proc`), not a
one-liner — it is not in this release.

## Windows (WSL2) — best effort

tmux has no native Windows build, so WSL2 is the only route, and it is genuinely
weaker there. Be honest with yourself about this before relying on it:

- **Detached sessions do not survive closing your terminals.** When the last WSL
  process exits, the distro instance shuts down after roughly 15 seconds and the
  utility VM about a minute later. Your detached tmux server goes down with it, and
  fmux's manifest is only as good as the last snapshot it managed to write.
- **`vmIdleTimeout=-1` in `.wslconfig` is widely reported not to prevent this.**
  Do not plan around it.
- **`@reboot` cron never fires**, because nothing starts WSL at Windows boot. You need
  a Windows Task Scheduler entry that launches something in WSL (e.g.
  `wsl.exe -d <distro> -- ~/.local/bin/fmux --boot-restore`), and typically a
  long-lived process to keep the instance alive at all.
- **Key bindings are more constrained.** Windows Terminal takes `Alt+Arrow` before
  WSL sees it; use `prefix + F` or `C-Left`.

Everything that does not depend on the machine staying up — the popup, hook state,
broadcast, `tt config`, `--restore` run by hand — works normally.

## Troubleshooting

The five things that go wrong first, in the order people hit them.

### Q1. `tt: command not found`

Put the line the installer printed into your shell startup file and open a **new**
shell:

```bash
export PATH="$HOME/.local/libexec/tt:$HOME/.local/bin:$PATH"
```

`~/.bashrc` on Linux, `~/.bash_profile` for bash on macOS, `~/.zshrc` for zsh. The
`libexec/tt` half must stay **first** — that is the hook shim, and behind the real
`claude` it never fires. The installer does not edit startup files for you.

### Q2. The summon key does nothing

Most likely nothing is bound: `key_summon_fast` is empty by default, on purpose — fmux
takes no key until you say so. Turn it on and re-source:

```bash
tt config set key_summon_fast 'C-Left M-Left'   # macOS: 'M-b'
```

Then check three things:

1. `~/.tmux.conf` (or `~/.config/tmux/tmux.conf`) contains
   `source-file ~/.config/fleetmux/tmux.conf` as its own line. `~` is fine; so is an
   absolute path. A commented-out line is not.
2. If you are already inside tmux, the running server still has the old bindings.
   `tt config set` re-sources the snippet for you *if* it finds that line; otherwise
   press `prefix + :` and run `source-file ~/.tmux.conf` once.
3. `prefix + F` — the default — always works, even with no prefix-less key at all. If
   that fails too, the snippet is not being read at all, which is point 1 again.

On macOS, Option+← arrives as `M-b`, not `M-Left`, and Ctrl+arrow is usually eaten by
Mission Control. Under Windows Terminal, Alt+arrow never reaches WSL; use `C-Left`.

### Q3. The list shows up, but `⏸` (waiting for approval) never does

That is the hook path, and it depends entirely on the shim:

- `command -v claude` must print `~/.local/libexec/tt/claude`. If it prints anything
  else, go back to Q1 — the shim is not in front.
- The shim fires **only inside tmux, and only while `tt` is on `PATH`** (it checks
  `command -v tt`). Outside tmux it deliberately passes straight through.
- If you started that agent *before* installing fmux, it has no hooks. Restart it.
- The audit log is `~/.cache/tt/hook.log`. It is **rotated**, not append-forever: past
  `log_max` bytes it is cut back to the last ~2000 lines. A log that starts abruptly is
  rotation, not silence.

### Q4. The `⏸2 ✻3` tally never appears in the status bar

Nothing is broken — **fmux does not wire your status bar**, on any platform. It would
have to overwrite `status-right`, which is yours. Add these two lines to your own tmux
config (not to the fmux snippet, which is regenerated):

```tmux
set -g status-interval 5
set -ag status-right '#(~/.local/bin/fmux --status)'
```

`-ag` appends, so whatever you already had in `status-right` survives. Beyond drawing
the tally, this is also the **sampler** for the `✻` CPU-delta signal (`src/50-hook.sh`,
`src/30-state.sh`): every 5 s it refreshes the working-session snapshot the popup reads.
Without it the popup falls back to reading the screen — the same behaviour as before
that signal existed, so nothing regresses; the `✻` mark is just less certain.

### Q5. `tt --rc` says `? no claude found` on every row, and a reboot restores nothing

On macOS this is *unsupported*, not broken: rc needs `/proc/<pid>/stat`, and
`--boot-restore`'s network gate needs `getent` and `timeout`. macOS has none of the
three — see [macOS](#macos--what-works-and-what-does-not) for the exact table. Run
`tt --restore` by hand instead; it does not pass through that gate and works fine.

On Linux, both are real diagnostics. Bring `~/.cache/tt/boot.log`: if the last line is
`ABORT: no DNS+tcp/443`, the machine had no network within 120 s of boot and fmux
refused to restore on purpose — a fleet of network-less agents would look "already
running" forever and block your manual retry. If the log says the manifest is
`older than 7 days`, nothing has been writing it: the minute cron line was probably
never installed.

## Scripting surface

```
--list  --status  --preview <name>  --rc  --cron  --snapshot  --restore [--dry]
--boot-restore [--dry]  --forget <name>  --hook <state>  --hooks-json  --codex-hooks
--tmux-conf [--write]  --do-broadcast <name>...  --help
config [list|get|source|set|unset|path]
```

Humans use the popup; scripts and agents use the same doors through the CLI.

## License

MIT
