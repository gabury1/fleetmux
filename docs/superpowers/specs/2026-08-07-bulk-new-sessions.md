# Spinning up several sessions at once

Decided 2026-08-07 · status: agreed, not implemented

## What

One key in the popup creates N sessions at once, named from a prefix: `worker1`, `worker2`,
`worker3`. It pairs with broadcast, which already exists — bring up a group, then send them all
one prompt.

## Why

`^N` makes one session and asks for its name. Standing up a fleet of five means pressing it five
times and inventing five names, which is exactly the chore this tool exists to remove. The names
in that situation are never meaningful anyway: they are `worker1..5`.

## The key: `M-n`, not `Ctrl+Shift+N`

`Ctrl+Shift+N` was the first idea and it does not survive contact with terminals. Most send the
same byte for `Ctrl+N` and `Ctrl+Shift+N` (0x0E) — telling them apart needs the kitty keyboard
protocol or `modifyOtherKeys`, which is not on by default anywhere we can rely on.

We measured this exact class of failure on 2026-08-06: a terminal was translating `Option+Left`
into `ESC b` and never forwarding the key at all, so a binding for it could never fire. A key that
works on the author's terminal and nowhere else is worse than no key.

Popup keys are read by **fzf**, not tmux, and fzf distinguishes `alt-n` reliably. `^N` makes one,
`M-n` makes several — adjacent keys for adjacent jobs.

## The three questions

All three are asked, each with a default, so the fast path is Enter three times:

```
how many?        [3]
name prefix      [worker]
start command    [claude]
```

`^N` already asks for a name and a command; skipping the questions here would make the two keys
behave by different rules. Speed comes from the defaults, not from removing the questions.

## Decided behaviour

| | |
|---|---|
| cwd | The current session's cwd, for all of them. Not asked — a fleet spun up together belongs in one place, and a fourth question would undo the point |
| name collisions | Taken numbers are skipped. Asking for 3 with `worker2` already alive gives `worker1`, `worker3`, `worker4` |
| cap | 10 per invocation. A typo of `50` should not put fifty agents on a Raspberry Pi |
| kind | Whatever the start command implies — the same judgment `^N` already makes, so tool sessions stay out of broadcast |
| failure | If one session fails to create, the rest still come up and the failure is named. Partial success is reported, never silently swallowed |

## Not doing

- Per-session names or commands. That is `^N`, one at a time.
- Layout or window arrangement. These are sessions, and the popup is how you move between them.

## Tests

- Three sessions are created with the prefix and the numbers continue past taken names
- The cap holds, and asking for more than the cap says so rather than truncating in silence
- Every created session lands in the current session's cwd
- Esc at any of the three prompts cancels the whole thing and creates nothing
- A start command that is a tool (not an agent) is still classified as a tool session
