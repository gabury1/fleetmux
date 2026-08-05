---
name: fleetmux
description: Use when asked what the other agent sessions are doing — "what is each session working on", "who is waiting for me", "is anything stuck", "fleet status", "check the other sessions", "did anything finish". Reports per-session state for tmux sessions running Claude Code or Codex, using fmux hook state rather than screen scraping. Read-only by default; broadcasting a prompt into other sessions requires an explicit human request.
---

# fleetmux — read the fleet without attaching

`tt` (a symlink to `fmux`) is a tmux cockpit for a fleet of coding agents. It already
knows what every session is doing. This skill is about reading what it knows, in the
right order, without breaking anything.

## The one rule

**Hook state is the fact. The screen is a rendering.**

Do not decide whether a session is working by looking at its pane. fmux tried that
first and it failed three ways: the "working" line has many shapes, an idle session's
status bar keeps ticking, and merely attaching re-wraps the pane. Every session
reports its own state through Claude Code / Codex hooks, and fmux writes it down.
Read what it wrote.

Order of operations, always: **state first, panes second.**

## Step 1 — the tally

```bash
tt --status
```

One line, the same one the tmux status bar shows: `⏸2 ✻3` — sessions awaiting a human
/ sessions working right now, plus `✓name` badges for work that finished while nobody
was watching. It is emitted with tmux style markup (`#[fg=colour215,bold]…#[default]`)
because the status bar is its home; read the glyphs and the numbers, ignore the
markup. Empty output means nothing is working and nothing is waiting.

`⏸` **is the one that matters.** It means a session is blocked on a human — a
permission prompt, a plan approval, a question. Surface those first, before anything
else, and say which sessions they are.

## Step 2 — the roster

```bash
tt --list
```

One row per session. Each row is `<name>` TAB `<display string>`, where the display
string carries ANSI color and the marks:

| mark | meaning |
|---|---|
| `●` | attached — a human has this session open |
| `✻` | working right now |
| `⏸` | awaiting a human decision |
| `✓` | finished while nobody was attached, and nobody has looked yet |
| `⊘` | Remote Control link dropped (red = fmux gave up retrying) |

Bold name = active conversation within the last few hours; dim = quiet. Sessions in
the accent color at the bottom are **tool sessions** (shells, `btop`, `lazydocker`,
`yazi`) — not agents. The final row is the literal string `--settings--`; it is a UI
row, not a session. Skip it.

Take the first field (before the tab) when you need a session name to pass to another
command; names may contain spaces.

## Step 3 — one session in detail

```bash
tt --preview <session-name>
```

The tail of that pane, trailing blank lines stripped — the bottom is where the
prompt, the spinner and the approval dialog live.

Use this **only after** the state told you which session is interesting. It is a
rendering: quote it as evidence for what a session is doing, never as the state
itself. If the pane and the hook state disagree, the hook state wins and the
disagreement is worth reporting.

## Raw state, when you need to be precise

```bash
cat ~/.cache/tt/hook-<tmux-session-id>   # "<state> <unix-ts> <agent-pid>"
cat ~/.cache/tt/manifest                 # TAB: name, cwd, kind, command, conversation-id, conversation home
cat ~/.cache/tt/finished                 # "<unix-ts> <name>" — finished, not yet seen
tail ~/.cache/tt/hook.log                # append-only audit trail of every transition
```

`hook-*` states are `working`, `waiting`, `idle`. The timestamp answers "how long has
it been like this?" and `hook.log` answers "when did it go quiet?" — both are cheaper
and more reliable than reading a pane twice.

A `manifest` row with `kind=tool` is a tool session. Treat that as authoritative when
deciding what is safe to write to.

## Many sessions at once

With more than two or three sessions, do not read every pane yourself — that is
hundreds of lines per session and it buys nothing. Dispatch one subagent per
interesting session, in parallel, and require a fixed report shape:

```
state:   working | waiting-on-human | idle
doing:   <one line>
blocked: <what it needs, or none>
```

Then merge. `tt --status` and `tt --list` already give you the tally and the marks, so
the subagents only have to fill in the "why".

## Writing into other sessions

This skill is **read-only** by default. Sending text into another agent's session
interrupts whatever it is doing and cannot be undone.

If — and only if — the human explicitly asks you to send something:

```bash
tt --do-broadcast <name> [<name>...]
```

It prints `targets: …`, then asks for the prompt text **on the terminal** (`/dev/tty`)
before sending. That means it is driven by a human at a terminal or in the popup; if
you invoke it without a controlling terminal it will exit without sending anything.
So the right move is usually to name the exact targets, confirm them out loud with the
human, and let the human press the key — or hand them the exact command.

Two rules that do not bend:

1. **Confirm the target list out loud before anything is sent.** Read the names back.
2. **Never target tool sessions** — shells, `btop`, `lazydocker`, `yazi`. A prompt
   typed into a shell runs as a command. fmux filters them out (`kind=tool` in the
   manifest) and reports `skipped N tool sessions`, but say which sessions you are
   about to touch anyway. A silent filter is not a substitute for looking.

Everything else that changes state — `tt --restore`, `tt --forget`, `tt config set`,
killing or renaming sessions — is the human's call, not yours. Propose, do not run.

## When tt is not installed

If `tt` is not on `PATH`, say so and stop. Do not fall back to `tmux capture-pane`
across the fleet to guess who is busy — that is the exact guesswork this tool exists
to remove, and it re-wraps panes as a side effect.
