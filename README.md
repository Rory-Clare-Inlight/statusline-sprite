<h1 align="center">
  🤠
  <br>statusline-sprite
</h1>
<p align="center">
    A Claude Code statusline that renders a sprite next to your status text using the kitty graphics protocol. The sprite changes as context window usage grows.
</p>

<img alt="doomguy" src="https://github.com/user-attachments/assets/14738443-7e6a-4ea9-93e8-3805eeaceb2c" />

## Build

```sh
just build      # debug build
just install    # release build -> ~/.local/bin
```

## Try it

```sh
just demo
```

## Configure

Copy `config.example.toml` to `~/.config/statusline-sprite/config.toml` and point `sprite.dir` at a directory of tiered sprite PNGs. Each `[lineN]` section sets a shell command or color for that statusline row.

## Sprites

Sprites are PNG files (max 1 MB), one per tier, named `face0.png` through `face{tiers-1}.png` inside `sprite.dir`:

```
sprites/
  face0.png   # tier 0: empty context
  ...
  face4.png   # top tier: full context (tiers = 5)
```

The tier is `floor(tokens / scale_tokens * tiers)`, clamped to the top tier — so with the defaults (`tiers = 5`, `scale_tokens = 200000`) each face covers a 40k-token band. To use arbitrary paths instead of the naming convention, set an explicit list:

```toml
[sprite]
faces = ["/path/to/calm.png", "/path/to/worried.png", "/path/to/panic.png"]
```

If `faces` has fewer entries than tiers, the last entry is reused for the higher tiers. Each face is rendered in a box `box_cols` terminal cells wide, so roughly square images look best.

## Alignment

By default the sprite sits at the left edge with the text beside it. To pin it to the horizontal center of the terminal, like the face in the game's status bar (text stays at the left edge):

```toml
[sprite]
align = "center"
```

The terminal width is probed again on every statusline refresh, so the face re-centers itself when the window is resized or a tmux pane is split. Width comes from `#{pane_width}` inside tmux, from TIOCGWINSZ on /dev/tty otherwise, then from `$COLUMNS`; when no width can be found the layout falls back to left alignment.

## Gaze animation

While Claude is working, the face can play the game's idle animation: a random gaze (forward, left, right) roughly every half second, going still only when the turn ends and the session sits waiting for your next input. Drop two extra frames per tier next to the forward faces and it activates automatically:

```
sprites/
  face0.png    # tier 0, looking forward
  face0l.png   # tier 0, looking left (optional)
  face0r.png   # tier 0, looking right (optional)
```

A missing gaze frame just means a static face for that tier. Busy versus waiting is read from the tail of the session transcript (`transcript_path` in the statusline JSON): a pending tool call, a running subagent, or an in-flight response all count as busy; a completed turn counts as waiting. When no transcript path is available it falls back to statusline JSON fields that only change during API work (a small state file per session lives in `$TMPDIR`). Opt out entirely with:

```toml
[sprite]
animate = false
```

## tmux

Inside tmux the graphics escapes are wrapped in DCS passthrough sequences, which tmux silently drops by default. The sprite will never show until you enable passthrough in `~/.tmux.conf`:

```
set -g allow-passthrough on
```

## Claude Code

Then set it as your Claude Code statusline command in `~/.claude/settings.json`:

```json
{ "statusLine": { "type": "command", "command": "statusline-sprite" } }
```

---

Doom guy sprite © id Software, shown for demo purposes only — not covered by this project's MIT license.
