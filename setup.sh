#!/usr/bin/env bash
# One-time optional setup for nickmdrummer.timer.
#
# Adds the frosted-blur hook to your Hyprland config and reloads it.
# Without this step the plugin still works, but the popup and floating
# window use flat translucent backgrounds instead of blur.
#
# Safe to run multiple times: it never duplicates the hook and it keeps
# a timestamped backup of your config before touching it.
#
# Usage:
#   bash ~/.config/omarchy/plugins/nickmdrummer.timer/setup.sh
set -u

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_LINE="$PLUGIN_DIR/timer-hypr.lua"
HYPR_LUA="$HOME/.config/hypr/hyprland.lua"

if [[ ! -f "$PLUGIN_DIR/timer-hypr.lua" ]]; then
  echo "setup: timer-hypr.lua not found in $PLUGIN_DIR" >&2
  exit 1
fi

if [[ -f "$HYPR_LUA" ]] && grep -qF "nickmdrummer.timer/timer-hypr.lua" "$HYPR_LUA"; then
  echo "setup: blur hook already present, nothing to do."
else
  if [[ ! -f "$HYPR_LUA" ]]; then
    echo "setup: $HYPR_LUA not found, cannot install the hook." >&2
    exit 1
  fi
  BACKUP="$HYPR_LUA.bak.$(date +%Y%m%d-%H%M%S)"
  cp "$HYPR_LUA" "$BACKUP" || { echo "setup: backup failed, aborting." >&2; exit 1; }
  cat >> "$HYPR_LUA" <<'EOF'
-- [nickmdrummer.timer] blur for popup and floating (managed by the plugin; safe to remove)
local timer_blur_path = os.getenv("HOME") .. "/.config/omarchy/plugins/nickmdrummer.timer/timer-hypr.lua"
local timer_blur_file = io.open(timer_blur_path, "r")
if timer_blur_file then
	timer_blur_file:close()
	dofile(timer_blur_path)
end
EOF
  echo "setup: hook added (backup at $BACKUP)."
fi

if command -v hyprctl >/dev/null 2>&1; then
  hyprctl reload >/dev/null 2>&1 && echo "setup: Hyprland reloaded, blur is live." \
    || echo "setup: hook installed but 'hyprctl reload' failed; run it manually." >&2
else
  echo "setup: hook installed; run 'hyprctl reload' inside your Hyprland session." >&2
fi
