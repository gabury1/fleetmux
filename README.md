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
~/.local/libexec/fleetmux/claude
  inside tmux → exec real-claude --settings "$(fmux --hooks-json)" "$@"
  outside     → exec real-claude "$@"          # transparent
```

Delete the wrapper and every trace of fmux's involvement is gone. Aliases like
`cc='claude'` are covered too — an alias is text substitution, and the `PATH`
lookup happens after it.

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

Claude Code's Remote Control bridge drops silently (idle timeouts, after compaction,
overnight). The official fix is "run `/remote-control` again". fmux does it for you —
only when `bridgeSessionId` is actually empty, never while the session is busy, and
it backs off with a `⊘` badge when a session keeps dropping right after a repair.

## Keys

| | |
|---|---|
| `Option+←` | summon the popup from anywhere |
| `→` / Enter | enter session · `←` / Esc close · `^D` detach tmux |
| `^N` `^E` `^X` | new · rename (syncs the Claude session title) · kill |
| Tab + Enter | broadcast one prompt to several sessions (tool sessions are skipped) |
| `?` | help |

## Reading the list

| mark | meaning |
|---|---|
| **bold** / dim | talked within 6h / quiet |
| teal | tool session (yazi, lazydocker…) — sorted alphabetically at the bottom |
| ● ✻ ⏸ ✓ ⊘ | attached · working · awaiting you · unseen result · remote control dropped |

Status bar carries the fleet tally `⏸2 ✻3` and a `✓name` badge for work that
finished while you were away.

## Requirements

- tmux ≥ 3.2 (popups), fzf ≥ 0.64 (footer), bash
- Linux and macOS. Windows via WSL2 — tmux has no native Windows build.
- State lives in `~/.cache/tt/`. Delete it and you lose nothing but history.

## Install

```bash
git clone https://github.com/<you>/fleetmux
cd fleetmux && ./install.sh
```

## Scripting surface

`--list --status --rc --snapshot --restore --forget --hook --hooks-json --codex-hooks --cron --preview`

Humans use the popup; scripts and agents use the same doors through the CLI.

## License

MIT
