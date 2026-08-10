# What is in these five pictures

They are on the site under "How you use it". This file says which parts are the tool actually
running and which parts are stage dressing, because a screenshot cannot say that for itself.

Reshoot with `demo/shots.sh` and the tapes it describes; the plan is
`docs/superpowers/plans/2026-08-10-walkthrough-screenshots.md`.

## Real in every frame

Everything fmux draws: the popup, the session list, the marks (`⏸` `✻` `✓`), the tool-session
colour, the preview pane, the rename and new-session prompts, the status bar tally, and the
`--restore` output. That is what the pictures are of, so none of it is faked.

## Stage dressing

**The agent screens behind the popup are `cat`, not Claude.** `demo/screens/*.txt` are
representative transcripts, printed into a pane that then sleeps. Four live agents would cost
tokens and — worse for a set of pictures meant to be reproducible — give a different screen on
every take. The same choice, and the same reasoning, as `demo/demo.gif`.

**The hook state is written by hand.** Making a session genuinely sit at ⏸ means answering a
permission prompt and then walking away; `demo/shots.sh` writes `hook-<id>` directly instead. The
records are otherwise honest — a live pid, a fresh timestamp — because `fmux_hook_valid` throws
out anything else.

**01 is two frames stacked.** fmux runs fzf full-screen, so the moment the list appears the shell
line that launched it is gone — "typed `fmux`" and "the list it opened" cannot coexist in one
capture. Both halves are real captures, seconds apart, with a rule drawn between them. Nothing
was painted in.

**05 restores tool sessions, not agents.** The fleet's manifest was rewritten to `kind=tool` for
the shoot. A real `--restore` relaunches agents with `claude --resume` and then *verifies* them,
waiting 12 seconds, retrying, waiting again — and in a sandbox with no `claude` on PATH that
verification is guaranteed to fail, so after 24 seconds the frame would have read
`RESTORE INCOMPLETE` instead of showing the fleet. Restoring tool sessions exercises the same
manifest, the same session creation, the same output format; only the per-session command differs.

## Not in any frame

No agent orchestration, no bulk session creation (`Alt+N` is designed but unimplemented), and
nothing else the current build cannot do.

## Privacy

Shot on a throwaway tmux server under `/tmp/fmux-shots`, with an empty `$HOME` (no MCP servers, no
skills), in a directory that is not a git repository. Session names, prompts and paths in the
images are invented for the shoot.

⚠️ The root directory has to live outside your home directory. The manifest stores each session's
cwd verbatim and `--restore` prints it, so a first attempt staged under a path containing the
author's username put it straight into frame 05.
