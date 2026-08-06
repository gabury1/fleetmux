# fleetmux config system — design

Written 2026-08-04 · Status: awaiting review

## Background

fmux has so far only ever run on one person's machine. So preference was the default —
rc auto-recovery was always on, cron took a snapshot every minute, "recent" meant 6
hours, and the accent color was 73.

Public distribution breaks that assumption. In particular, **rc auto-recovery types
keys into someone else's session.** There's no reason for someone seeing this tool for
the first time to install something they can't turn that off in.

## Goals

- On/off switches: rc auto-recovery, cron snapshots, boot auto-restore
- Tuning: recent threshold, ✓ badge retention, accent color, log rotation size
- Keybinding remapping: every key inside the popup, plus the popup summon key
- Config must be changeable **inside the popup** (never have to leave `tt`)
- Record the fleet one more time on exit (terminal closed, detach, session end)

## Non-goals (YAGNI)

- Per-project / per-session config — one machine is enough. It would only complicate
  the lookup rules and priority order.
- Config sync, profiles, theme packs
- Toggling the hook shim (`libexec/tt/claude`) on/off — that's an install-time choice;
  removing it removes the interception entirely.

## Why env vars alone aren't enough

The code already has conventions like `${FMUX_LOG_MAX:-…}`. But the two features people
actually want to turn off (rc auto-recovery, snapshots) **run from cron.** Cron doesn't
go through a login shell, so it never sees `export FMUX_RC=0` in `~/.bashrc`. Hooks are
the same — they only inherit the agent process's environment.

→ Config has to be a **file**. Env vars stay as a one-off override layered on top.

## Design

### 1. Storage

```
${XDG_CONFIG_HOME:-$HOME/.config}/fleetmux/config
```

```ini
# fleetmux config — tt config set <key> <value>
rc=off
recent_hours=12
key_new=ctrl-t
```

- One `key=value` per line, `#` comments, blank lines allowed
- **Never `source`d.** Read by a whitelist parser: a line is accepted only if it
  matches `^[a-z_][a-z0-9_]*=[0-9A-Za-z_./:+ -]*$` (spaces allowed in the value —
  `key_summon_fast` is a key list) **and** the key is on the known list.
  Everything else is ignored, with a one-line warning to stderr.
  Reason: this file is read by hooks on every event and by cron every minute. If it
  were `source`d, one typo'd line would silently kill fleet command entirely. The
  trust boundary is narrowed to a single parser.
- Read once at the start of every entry point (`fmux_conf_load`). The file is under ten
  lines, so it isn't cached.

### 2. Priority

```
env var  >  config file  >  code default
```

Env vars are for one-off experiments (`FMUX_RC=0 tt --cron`). The existing
`FMUX_LOG_MAX`, `FMUX_BOOT_NETWAIT`, `FMUX_MANIFEST` are kept as-is (backward compatible).

### 3. Key list v1

| Key | Default | env | When off/changed |
|---|---|---|---|
| `rc` | `on` | `FMUX_RC` | Skips the rc auto-recovery step entirely. The `⊘` badge is not computed either |
| `snapshot` | `on` | `FMUX_SNAPSHOT` | `--cron` stops writing the manifest |
| `snapshot_on_exit` | `on` | `FMUX_SNAPSHOT_ON_EXIT` | No record on exit (detach / session close) |
| `boot_restore` | `on` | `FMUX_BOOT_RESTORE` | `--boot-restore` returns immediately |
| `recent_hours` | `6` | `FMUX_RECENT_HOURS` | Time window for bolding a session name |
| `unseen_minutes` | `10` | `FMUX_UNSEEN_MINUTES` | How long the status bar keeps showing `✓name` |
| `accent` | `73` | `FMUX_ACCENT` | 256-color number (tool session / header highlight) |
| `log_max` | `1048576` | `FMUX_LOG_MAX` | hook.log rotation threshold (absorbs the existing variable) |

`on`/`off` also accept `1`/`0` and `true`/`false`. Any other value is rejected by
`set`.

### 4. Keybindings

| Key | Default | Action |
|---|---|---|
| `key_new` | `ctrl-n` | New session |
| `key_rename` | `ctrl-e` | Rename |
| `key_kill` | `ctrl-x` | Kill session |
| `key_reload` | `ctrl-r` | Refresh list |
| `key_detach` | `ctrl-d` | Detach from tmux |
| `key_broadcast` | `ctrl-b` | Broadcast with popup held open |
| `key_help` | `?` | Help |
| `key_settings` | `ctrl-o` | Settings screen ("options") |
| `key_summon` | `F` | Popup summon — after prefix (see sections 6a and 6 below) |
| `key_summon_fast` | (empty) | List of prefix-less summon keys (see section 6b below) |

Value syntax **reuses fzf's key names verbatim** (`ctrl-n`, `alt-x`, `f2`, `btab`). By
not inventing new syntax, the fzf docs double as our docs for free. Only
`key_summon` and `key_summon_fast` use tmux key syntax (`F`, `M-Left`, `C-Left`,
`M-b`) — those two are keys tmux receives, not fzf.

**Reserved**: `esc`, `left` (close), `enter` (enter session) can never be remapped.
There must always be one door open that gets you out even if you fumble.

**Conflicts**: `set` rejects a key already bound to a different action (and prints
which one it collided with).

**Validation**: on load, checked against a whitelist of key names fzf understands
(`ctrl-[a-z]`, `alt-[a-z0-9]`, `f1`–`f12`, `tab`/`btab`/`home`/`end`/`pgup`/`pgdn`/
`del`/`ins`, arrow keys, a single printable character like `?`). An unrecognized name
gets **only that key** reset to its default, with a warning.

**Last-resort defense**: even a combination that passes validation can still make fzf
fail to launch (rc≠0, immediate exit). In that case it's relaunched once more with
default bindings, with a notice that "it came up with defaults because of a config
key." A control tower that fails to come up at all is the worst possible failure.

### 5. CLI

```
tt config                 # everything — value + source (default|file|env)
tt config get <key>
tt config set <key> <val> # validate → tmp file → mv (atomic), same flock pattern as the manifest
tt config unset <key>     # remove the line from the file → revert to default
tt config path            # print the config file path
```

An invalid key/value prints rc 1 and the allowed range. `set` preserves comments and
line order the human hand-edited (existing lines get replaced in place, missing ones
are appended).

### 6a. Why the default summon key uses prefix

A survey of common practice (2026-08-04): tmux session-manager plugins **without
exception** default to `prefix + one letter`.

| Tool | Default |
|---|---|
| tmux-sessionx | `prefix + O` (prefix-less is opt-in separately via `@sessionx-prefix off`) |
| tmux-fzf | `prefix + F` |
| sesh / t-smart | `prefix + T` |
| tmux-session-wizard | `prefix + T` |
| tmux-fzf-session-switch | `prefix + C-f` |
| tmux-sessionist | `prefix + g`, among others |

No session manager was found that defaults to a prefix-less one-shot key. The reason
is clear from platform-by-platform measurement:

| Key | Linux | macOS | Windows (WSL2+WT) |
|---|---|---|---|
| `M-Left` (`ESC[1;3D`) | ✅ | ❌ Ghostty/Terminal.app send Option+← as `ESC b` | ❌ WT eats Alt+Arrow for pane navigation first |
| `M-b` (`ESC b`) | ✅ | ✅ **macOS's Option+← lands here** | ✅ |
| `C-Left` | ✅ | ⚠️ Mission Control space-switching can eat it first | ✅ |
| `prefix + F` | ✅ | ✅ | ✅ |

**On macOS, Option+← is `M-b`.** Ghostty sends `ESC b` even with
`macos-option-as-alt=true` (intentional Terminal.app compatibility, ghostty#7131,
discussion#7740). cmux is built on libghostty, so it's the same. Consequently, on a
Mac **you cannot distinguish Option+← from Alt+b** — binding this key to summon means
losing readline's `backward-word` is not a choice, it's inevitable. This goes in the
README verbatim.

The default is `prefix + F` (fleet). In tmux's default bindings, uppercase `F` is
unused (`f`=find-window and `Space`=next-layout are alive, so those are avoided).

### 6b. Fast keys — a list, not a single value

The same physical key arrives as different bytes depending on the terminal. That's why
`key_summon_fast` is a space-separated list.

| Key | Default | Meaning |
|---|---|---|
| `key_summon` | `F` | One letter after prefix. The guaranteed fallback |
| `key_summon_fast` | (empty) | List of prefix-less keys. e.g. `C-Left M-Left M-b` |

install.sh presets:

| Preset | `key_summon_fast` | Target |
|---|---|---|
| safe | (empty) | Default. First run is guaranteed to succeed |
| mac | `M-b` | Option+← on Ghostty, cmux, Terminal.app |
| linux | `C-Left M-Left` | Local Linux terminals |
| wsl | `C-Left` | Windows Terminal (WT eats Alt+Arrow) |

### 6. Popup summon key — dedicated snippet file

fmux does not edit `~/.tmux.conf`. Instead it owns its own file:

```
~/.config/fleetmux/tmux.conf     ← created and owned by fmux. The user never touches it
```

The user's `.tmux.conf` gets exactly one line added at install time:

```tmux
source-file ~/.config/fleetmux/tmux.conf
```

```tmux
# example generated — key_summon=F, key_summon_fast="C-Left M-b"
bind    F      display-popup -E -w 85% -h 75% "tt --from '#S'"
bind -n C-Left display-popup -E -w 85% -h 75% "tt --from '#S'"
bind -n M-b    display-popup -E -w 85% -h 75% "tt --from '#S'"
```

`tt config set key_summon_fast "C-Left M-b"` only rewrites its own file, and if you're
inside tmux it reflects immediately via `tmux source-file`. Any key dropped from the
list also gets an `unbind` emitted — otherwise the removed binding stays alive until
the server dies.

Same philosophy as the shim — **borrow one line, and removing it leaves no trace.**

### 7. Popup settings screen

- Two entry points: `key_settings` (default `ctrl-o`) from anywhere, or the
  `⚙ settings` item at the bottom of the list
- The screen is an fzf re-invocation (`tt --config-view`). Each line is
  `key · current value · one-line description`
- Enter:
  - boolean → immediate toggle, save, reload
  - number/color → captured via fzf `print-query`, validated, then saved
  - `key_*` → **captured by an actual keypress**. Inside `execute()`, `read -rsn1
    </dev/tty` reads it and reverse-maps it into the `ctrl-n` form. "Press it" beats
    "type in the string ctrl-n"
- Esc → back to the session list. Color changes take effect from the next render

### 8. Snapshot on exit

Right now there are only two chances to record: the `--cron` one-minute tick and
opening the popup. For someone who turned cron off with `snapshot=off`, there's no
record at all — once we allow that switch to exist, **a record on exit** becomes
necessary.

The trigger is caught via tmux hooks. Measured in practice (2026-08-04, tmux 3.5a,
separate socket):

| Situation | Hook fired | Confirmed |
|---|---|---|
| An attached terminal is killed by force (window closed, SSH drops) | `client-detached` | ✅ reproduced with client SIGKILL |
| `kill-server` / last session closes | `session-closed` | ✅ `run-shell` still runs while the server is going down |

```tmux
# ~/.config/fleetmux/tmux.conf — file owned by fmux (same place as the summon key)
set-hook -g client-detached 'run-shell -b "tt --snapshot >/dev/null 2>&1"'
set-hook -g session-closed  'run-shell "tt --snapshot >/dev/null 2>&1"'
```

- `client-detached` uses `-b` (background). A snapshot must never hold up someone who
  is leaving.
- `session-closed` runs **synchronously**. The server is going down, so throwing it
  into the background risks it vanishing before it runs.
- It's safe even if session enumeration returns zero lines mid-crash — `--snapshot`
  never writes when zero sessions are alive (`70-fleet.sh:103`). The path where the
  fleet log evaporates at exactly the moment it's needed most is already closed off.
- Concurrent runs are serialized by the manifest flock (safe even overlapping a cron
  tick).

One more config key is added — cron and the exit hook aren't wanted by the same
people:

| Key | Default | Meaning |
|---|---|---|
| `snapshot` | `on` | The `--cron` one-minute record |
| `snapshot_on_exit` | `on` | Record on exit (detach / session close) |

If `snapshot_on_exit=off`, the two `set-hook` lines are omitted when generating the
snippet, and reflected immediately if inside tmux.

## What "off" means (spelled out in the docs)

- `rc=off` does not disconnect an already-attached Remote Control link. It only stops
  **auto re-execution**
- With `snapshot=off`, the manifest goes stale. The "7 days stale" warning from
  `--restore` isn't a bug, it's the consequence
- **The user's crontab is never touched.** Turning things off is implemented as an
  early return inside fmux itself. The program never quietly edits someone else's
  scheduler

## Failure modes and responses

| Situation | Response |
|---|---|
| Config file corrupted / unreadable | Everything runs on defaults + one warning line. Never aborts |
| Unknown key | Ignored + warned. An older fmux surviving a newer config file |
| Invalid key name | Only that key reverts to default + warning |
| fzf fails to launch | Retried with default bindings |
| Interrupted mid-`set` | tmp+mv means the original survives |

## Tests

There's no `test/` right now. Since the parser is the trust core, that's the only
thing built here (pure bash, no dependencies):

- Ignores broken lines / unknown keys and still reads the rest
- env beats file, file beats default
- `set` preserves comments and order, and writes atomically
- Rejects remapping reserved keys and key conflicts
- An invalid key name reverts only that key to default

Wired into `make check`.

## Docs

- README gets a `Configuration` section — file location, key table, `tt config`
  usage, "what off means"
- One line added to `config` in `--help`
- Also fixes the wrong libexec path in the README (`libexec/fleetmux` →
  `libexec/tt`) at the same time

## Follow-ups (out of scope this round)

- Previewing key conflicts on the settings screen before you commit
- Theme presets
- Per-project config
