# Timer — countdown plugin for Omarchy

[![Timer preview](preview.png)](https://plugins.omarchy.org/plugin.html?id=nickmdrummer.timer)

*Original mode: custom glass + blur. Omarchy theme mode:*

<img src="preview-omarchy.png" alt="Timer following the Omarchy theme" width="70%">

Countdown pill on the top bar, with a gentle alarm,
editable presets and an always-on-top floating mode.

Listed on the [Omarchy plugin marketplace](https://plugins.omarchy.org/plugin.html?id=nickmdrummer.timer).

## Install

```bash
omarchy plugin add https://github.com/NickmDrummer/omarchy-timer.git --enable --yes
bash ~/.config/omarchy/plugins/nickmdrummer.timer/setup.sh
```

The script adds one blur hook line to `~/.config/hypr/hyprland.lua`
(with a backup, never duplicated) and reloads Hyprland. No shell restart
needed. Manual alternative: append this line yourself, then `hyprctl reload`:

```lua
dofile(os.getenv("HOME") .. "/.config/omarchy/plugins/nickmdrummer.timer/timer-hypr.lua")
```

## Remove

```bash
bash ~/.config/omarchy/plugins/nickmdrummer.timer/setup.sh --remove
omarchy plugin remove nickmdrummer.timer --yes
```

`--remove` deletes only the marked blur block (with a backup) and reloads
Hyprland, so your config is left clean. Your presets
(`~/.config/nickmdrummer-timer/presets.json`) are kept.

## Dependencies

All standard on Omarchy, no setup needed:

- `paplay` (or `pw-play`) for the alarm, `notify-send` for the alert,
  `hyprctl` for monitor layout, `python3` (stdlib only) to generate the chime.

## Usage

- **Click** the pill: opens the panel.
- **Middle click**: pause / resume directly.
- **Mouse wheel** over the pill: ±5 min (idle) or ±1 min (running).
- **Panel shortcuts**: `space` pause · `+`/`-` adjust ±5 min · `R` reset · `F` float · `Esc` close.

## Features

- Accent-colored pill **only while running**; idle/paused uses the topbar
  background with an accent border. System typeface (same as the bar).
  Green heartbeat during the last 5 seconds.
- 10, 15, 30 and 40 min presets + manual H/M/S picker and +5/−5 buttons
  (live while running).
- Presets can be **created, renamed and deleted** from the panel (✎);
  stored in `~/.config/nickmdrummer-timer/presets.json`:

```json
{ "version": 1, "presets": [{ "id": "preset-10", "label": "10", "minutes": 10 }] }
```

- **Floating mode** (⇗ or `F`): a single 244×244 square window with blur,
  always on top on the screen it was detached from, with start/pause/resume,
  stop and ↩ to go back to the bar. Click the time to open the panel.
  Drag the time to move it (the card slides inside a static fullscreen
  layer with a drag-wide input mask, so dragging never stutters or loses
  grab; it stays on screen). Push against a screen edge to peek a live
  ghost on the neighboring monitor, and release to hop there — the real
  card lands exactly where the ghost was (layer windows live on one
  output, so the press itself can't travel). The final heartbeat only hits the typeface.
- **Theme mode** (`Theme: Original [toggle] Omarchy` in the panel):
  **Original** keeps the custom dark glass; **Omarchy** uses the active
  theme's popup tokens (native look and the theme's own blur amount).
  In Original mode the glass gets denser on light themes for contrast.
- **Alarm**: three-note chime (~3 s) at high volume, three passes +
  critical notification.
- Real blur via `timer-hypr.lua` (hook in `~/.config/hypr/hyprland.lua`,
  reload with `hyprctl reload`): blur + `ignore_alpha 0.3` per namespace,
  so only the card gets frosted — never the whole desktop or the corners.
- State syncs across monitors via
  `$XDG_RUNTIME_DIR/nickmdrummer-timer/state.json`.

## Settings

Stored in the bar entry of `~/.config/omarchy/shell.json` and editable from
the panel footer:

- `sound` — `On` / `Off` for the alarm.
- `theme` — `Original` (custom dark glass) or `Omarchy` (theme tokens).

## IPC

```
omarchy-shell nickmdrummer.timer toggle
omarchy-shell nickmdrummer.timer start 25
omarchy-shell nickmdrummer.timer stop
omarchy-shell nickmdrummer.timer detach
omarchy-shell nickmdrummer.timer attach
omarchy-shell nickmdrummer.timer hop left|right|up|down
omarchy-shell nickmdrummer.timer screens
omarchy-shell nickmdrummer.timer status
```

`screens` prints the logical monitor layout the floating window uses;
`hop` moves the floating card to the neighboring monitor.
