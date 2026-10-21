#!/usr/bin/env bash
# Optional setup for nickmdrummer.timer.
#
# Adds (or removes) the frosted-blur hook in your Hyprland config and
# reloads it. Without the hook the plugin still works, but the popup and
# floating window use flat translucent backgrounds instead of blur.
#
# Safe to run multiple times: it never duplicates the hook, it keeps a
# timestamped backup before touching the config and it only removes its
# own marked block.
#
# Usage:
#   bash setup.sh            # install the hook
#   bash setup.sh --remove   # remove the hook (run it before uninstalling)
set -u

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HYPR_LUA="$HOME/.config/hypr/hyprland.lua"
MARKER="nickmdrummer.timer/timer-hypr.lua"
MODE="${1:-install}"

if [[ "$MODE" != "install" && "$MODE" != "--remove" ]]; then
  echo "usage: bash setup.sh [--remove]" >&2
  exit 2
fi

reload_hyprland() {
  if command -v hyprctl >/dev/null 2>&1; then
    hyprctl reload >/dev/null 2>&1 && echo "setup: Hyprland reloaded." \
      || echo "setup: config changed but 'hyprctl reload' failed; run it manually." >&2
  else
    echo "setup: config changed; run 'hyprctl reload' inside your Hyprland session." >&2
  fi
}

backup() {
  local path="$1"
  local dest="$path.bak.$(date +%Y%m%d-%H%M%S)"
  cp "$path" "$dest" || { echo "setup: backup failed, aborting." >&2; exit 1; }
  echo "setup: backup at $dest"
}

if [[ ! -f "$HYPR_LUA" ]]; then
  echo "setup: $HYPR_LUA not found." >&2
  exit 1
fi

if [[ "$MODE" == "--remove" ]]; then
  if ! grep -qF "$MARKER" "$HYPR_LUA"; then
    echo "setup: blur hook not present, nothing to remove."
    exit 0
  fi
  backup "$HYPR_LUA"
  python3 - "$HYPR_LUA" <<'PY'
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as handle:
    lines = handle.readlines()

out = []
skipping = False
for line in lines:
    if line.startswith("-- [nickmdrummer.timer]"):
        skipping = True
        continue
    if skipping:
        if line.strip() == "end":
            skipping = False
        continue
    out.append(line)

with open(path, "w", encoding="utf-8") as handle:
    handle.writelines(out)
PY
  echo "setup: blur hook removed."
  reload_hyprland
  exit 0
fi

if [[ ! -f "$PLUGIN_DIR/timer-hypr.lua" ]]; then
  echo "setup: timer-hypr.lua not found in $PLUGIN_DIR" >&2
  exit 1
fi

if grep -qF "$MARKER" "$HYPR_LUA"; then
  echo "setup: blur hook already present, nothing to do."
else
  backup "$HYPR_LUA"
  cat >> "$HYPR_LUA" <<'EOF'
-- [nickmdrummer.timer] blur for popup and floating (managed by the plugin; safe to remove)
local timer_blur_path = os.getenv("HOME") .. "/.config/omarchy/plugins/nickmdrummer.timer/timer-hypr.lua"
local timer_blur_file = io.open(timer_blur_path, "r")
if timer_blur_file then
	timer_blur_file:close()
	dofile(timer_blur_path)
end
EOF
  echo "setup: blur hook added."
fi

reload_hyprland
