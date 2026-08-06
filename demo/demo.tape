# fmux demo — reproducible: demo/fleet.sh builds a fake fleet on its own tmux socket, so this
# never touches a real one and always shows the same states.
#   render:  vhs demo/demo.tape
Output demo/demo.gif

Set Shell bash
Set FontSize 15
Set Width 1500
Set Height 760
Set Padding 18
Set Framerate 24
Set Theme { "name": "fmux", "background": "#12161c", "foreground": "#c8d3d5", "cursor": "#4ec9b0", "black": "#12161c", "red": "#e06c75", "green": "#7fae6e", "yellow": "#d7af5f", "blue": "#61afef", "magenta": "#c678dd", "cyan": "#4ec9b0", "white": "#c8d3d5", "brightBlack": "#5c6773", "brightRed": "#e06c75", "brightGreen": "#7fae6e", "brightYellow": "#d7af5f", "brightBlue": "#61afef", "brightMagenta": "#c678dd", "brightCyan": "#4ec9b0", "brightWhite": "#ffffff" }

Hide
Type "D=/tmp/fmuxdemo; rm -rf $D; mkdir -p $D/home; bash demo/fleet.sh $D/sock $D/home $HOME/.local/bin/fmux" Enter
Sleep 3s
Type "clear; HOME=$D/home tmux -S $D/sock attach -t api" Enter
Sleep 3s
Show

# ── the claim: the status bar already told you, without opening anything ──
Sleep 2500ms

# ── summon ──
Alt+g
Sleep 2500ms

# parser is the one waiting for a human
Down
Sleep 1800ms
Down
Sleep 2500ms

# ── dive in ──
Enter
Sleep 2500ms
