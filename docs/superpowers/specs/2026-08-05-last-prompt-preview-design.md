# Last prompt preview — design

Written 2026-08-05 · Status: approved

## Background

The popup preview currently shows the tail of the session's screen (the last N lines
of `tmux capture-pane`). But **what I told it to do** usually scrolls off the top and
disappears. When an agent thinks for a long time or uses several tools, the prompt is
off-screen and all that's left is the progress indicator.

For someone running ten sessions, "what did I even ask this session to do" is a
question that comes up every single time. The answer isn't on screen — it's only in
memory.

## Goal

Pin **the last prompt sent to that session** at the top of the preview.

## Non-goals

- Prompt history (keep only the last one)
- Showing it in the list row (preview only — the list keeps session name and marks)
- Response summaries / title generation (never calls a model)

## Why we don't scrape the screen

This is the tool's core discipline — **hook state is the fact, the screen is a
rendering.** Scraping the prompt from the screen breaks every time on line wraps, box
characters, scrolling. And there's no need to:

The `--hook` receiver in `src/50-hook.sh` already reads and parses a payload from
stdin (`tt_jv "$payload" session_id`, `tt_jv "$payload" cwd`). Claude Code's
`UserPromptSubmit` payload includes the prompt body itself. **The material is already
in hand — it just needs to be pulled out one more time.**

## Design

### 1. Storage

```
~/.cache/tt/last-<tmux-session-id>
  line 1     recorded time (unix epoch)
  line 2+    raw prompt text
```

- Written only from `UserPromptSubmit` (claude) / the corresponding codex event. No
  other hook touches it.
- **4096-byte cap.** Trims a giant pasted instruction before it eats disk and preview
  space. If trimmed, that fact must show up in the render (see section 3 below).
- Control characters are stripped except newlines. If a terminal escape sequence
  leaked straight into the preview it would break — the hook receives user input, so
  anything can arrive.
- Writes are atomic (tmp+mv). The hook is a short-lived process that runs per event,
  and the preview reads the same file concurrently.

### 2. Cleanup

- The `SessionEnd` (clear) hook deletes that session's file — same spot where
  `hook-<sid>` gets deleted.
- The orphan sweep (`tt_sweep_hooks`), when it sweeps `hook-*`, sweeps `last-*` too.
  After a reboot, tmux reissues session IDs starting from `$0`, so a dead session's
  file must be kept from attaching to a new session. **It uses the exact same
  criterion as `hook-*`** (no separate one is built).

### 3. Render

If `--preview` finds a file, it draws the header first and shrinks the screen tail by
that many lines.

Shipped in v0.1.2, the shape was tuned three times through real usage, and **below is
the confirmed final form.** Intermediate versions (vertical rule, box) were all
discarded — the box was explicitly thrown out for being "ugly."

```
last prompt ❯                          ← label line. reads like a shell prompt (dim)
keep going on the device domain        ← body line 1. no prefix, full window width
refactor, based on where we folded     ← line 2
… +4 lines                             ← remaining line count (absent if there is none)
──────────────────────────────         ← divider (dim, width = preview width)
(existing screen tail)
```

- The label gets its own line. The body starts **on the next line, with no
  indentation** — a two-space prefix would just mean losing two more columns, and once
  the label moves up there's nothing left for a prefix to do.
- Body is capped at 3 lines. If it overflows, the last slot shows `… +N lines` (that
  line itself counts against the 3-line body budget).
- If it was also cut off by the 4096-byte cap, that's shown in the same spot too
  (e.g. `… +N lines (truncated)`).
- Color follows the config's `accent`; both label and divider are **dim** — what needs
  reading is the body.
- On a narrow width, each line is trimmed to the preview width
  (`FZF_PREVIEW_COLUMNS`). If the width can't even fit the label line (under 13
  columns), the whole header is dropped — the additive-extra principle.
- Line budget = 1 label + up to 3 body + 1 divider = 5. That many lines are subtracted
  from `FZF_PREVIEW_LINES` before trimming the screen tail — otherwise the preview
  overflows and the top gets cut off.

### 4. Failure modes

| Situation | Behavior |
|---|---|
| No `last-<sid>` (first run, already cleaned up, tool session) | No header, screen tail only, exactly as today |
| Preview width narrower than the label (13 cols) | No header, screen tail only — better to have none than start by truncating the label |
| File is corrupt or unreadable | Proceeds without a header. The preview never breaks |
| Prompt can't be pulled from the codex payload | Skipped silently. No effect on state determination |
| Hook can't read the payload (empty stdin) | Behaves exactly as before — just without this feature |

**Principle**: this feature is an additive extra. If it fails, it must have zero
effect on the preview, state determination, or the manifest.

## Tests

- The hook pulls the prompt from the payload and writes it to the file (line 1 epoch,
  line 2+ body)
- Truncated at the 4096-byte cap, and the fact of truncation shows up in the render
- Control characters / escapes are filtered out
- `… +N lines` when over 3 lines; that line is absent when 3 or fewer
- The preview comes out byte-identical to today when the file doesn't exist
- The `clear` hook deletes the file / sweep deletes orphans
- The screen tail shrinks by exactly the header's line count (total preview lines
  never exceed `FZF_PREVIEW_LINES`)

## Open

- The payload shape of codex's prompt-submit event hasn't been confirmed. Measure it
  during implementation; if it can't be pulled out, keep this claude-only and document
  that fact.
