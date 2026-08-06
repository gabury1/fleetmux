# demo

`demo.gif` in the README is rendered from `demo.tape` with [vhs](https://github.com/charmbracelet/vhs):

```sh
vhs demo/demo.tape
```

`fleet.sh` builds the fleet the recording shows. It runs on **its own tmux socket** under a
throwaway `$HOME`, so recording never touches a real fleet, and the states are written directly
rather than waited for — the demo is about what fmux draws, and it has to draw the same thing
every time.

Two details that are easy to get wrong when writing state by hand:

- The pid in a hook file has to be a live process and the timestamp has to be **later than the
  session was created**. `fmux_hook_valid` discards a record older than its session as a ghost
  from a previous boot, which is exactly what a hand-written file looks like otherwise.
- `fleet.sh` binds one extra key (`M-g`) for the recorder. vhs cannot send `Shift+Up` — its
  modifiers take a character, not a named key — and the recording shows the popup appearing,
  not the keystroke.

The prompt is set to a bare `$` and the status line to a dark style on purpose: a published
recording should not carry someone's hostname and home directory.
