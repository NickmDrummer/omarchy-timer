# Timer — countdown plugin for Omarchy

Countdown pill on the top bar, with a gentle alarm,
editable presets and an always-on-top floating mode.

## Install

```bash
omarchy plugin add https://github.com/nickmdrummer/omarchy-timer.git --enable --yes
```

Then enable the real blur (one line at the end of `~/.config/hypr/hyprland.lua`):

```lua
dofile(os.getenv("HOME") .. "/.config/omarchy/plugins/nickmdrummer.timer/timer-hypr.lua")
```

and reload:

```bash
hyprctl reload
omarchy-restart-shell
```

Without that hook the plugin still works, but the popup and floating
window won't get frosted blur (flat translucent backgrounds instead).

## Remove

```bash
omarchy plugin remove nickmdrummer.timer --yes
```

This keeps your presets (`~/.config/nickmdrummer-timer/presets.json`) and
the Hyprland hook line (delete it manually if you want a clean removal).

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
- **Alarm**: three-note chime (~3 s) at high volume, three passes +
  critical notification.
- Real blur via `timer-hypr.lua` (hook in `~/.config/hypr/hyprland.lua`,
  reload with `hyprctl reload`): blur + `ignore_alpha 0.3` per namespace,
  so only the card gets frosted — never the whole desktop or the corners.
- State syncs across monitors via
  `$XDG_RUNTIME_DIR/nickmdrummer-timer/state.json`.

## IPC

```
omarchy-shell nickmdrummer.timer toggle
omarchy-shell nickmdrummer.timer start 25
omarchy-shell nickmdrummer.timer stop
omarchy-shell nickmdrummer.timer detach
omarchy-shell nickmdrummer.timer attach
omarchy-shell nickmdrummer.timer status
```
