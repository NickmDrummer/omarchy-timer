#!/usr/bin/env bash
# Alarm for the nickmdrummer.timer plugin.
# - Generates a modern three-note chime (sine with exponential decay) on
#   first run, then reuses it from ~/.cache. Lasts ~4.4 s.
# - Loud volume: present and audible.
# - Two passes ~2.2 s apart + sticky notification.
# - flock: with several bars (multi-monitor), only one rings.
set -u

LOCK="${XDG_RUNTIME_DIR:-/tmp}/nickmdrummer-timer-alarm.lock"
exec 9>"$LOCK"
flock -n 9 || exit 0

SILENT=0
NOTIFY=1
TITLE="Timer"
BODY="Time's up"
URGENCY="critical"
# Optional overrides let pomodoro phases announce themselves; with no
# arguments the timer alarm behaves exactly as before.
while [[ $# -gt 0 ]]; do
  case "$1" in
    --silent) SILENT=1; shift ;;
    --no-notify) NOTIFY=0; shift ;;
    --title) TITLE="${2:-$TITLE}"; shift 2 ;;
    --body) BODY="${2:-$BODY}"; shift 2 ;;
    --urgency) URGENCY="${2:-$URGENCY}"; shift 2 ;;
    *) shift ;;
  esac
done
[[ "$URGENCY" =~ ^(low|normal|critical)$ ]] || URGENCY="critical"

CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/nickmdrummer-timer"
CHIME="$CACHE/chime-v3.wav"
mkdir -p "$CACHE"

if [[ ! -s "$CHIME" ]]; then
  python3 - "$CHIME" <<'EOF' || true
import math, struct, sys, wave
path = sys.argv[1]
sr = 44100
# Tres notas ascendentes E5 -> B5 -> E6 a tempo 1.5x, campana moderna.
notes = [(659.25, 0.0, 1.07), (987.77, 0.57, 1.33), (1318.51, 1.27, 1.6)]
dur = 3.0
frames = int(sr * dur)
data = [0.0] * frames
for freq, start, length in notes:
    n0 = int(start * sr)
    n1 = min(frames, n0 + int(length * sr))
    for i in range(n0, n1):
        t = (i - n0) / sr
        env = min(1.0, t / 0.012) * math.exp(-2.2 * t)
        # Fundamental + soft partial for a round timbre.
        s = math.sin(2 * math.pi * freq * t) + 0.28 * math.sin(2 * math.pi * freq * 2 * t)
        data[i] += 0.42 * env * s
peak = max(1e-6, max(abs(v) for v in data))
with wave.open(path, "wb") as w:
    w.setnchannels(1)
    w.setsampwidth(2)
    w.setframerate(sr)
    w.writeframes(b"".join(struct.pack("<h", int(max(-1.0, min(1.0, v / peak)) * 30000)) for v in data))
EOF
fi

play_once() {
  local file="$1"
  [[ -s "$file" ]] || return 1
  if command -v paplay >/dev/null 2>&1; then
    # ~92% volume.
    paplay --volume=60000 "$file" 2>/dev/null && return 0
  fi
  if command -v pw-play >/dev/null 2>&1; then
    pw-play "$file" 2>/dev/null && return 0
  fi
  return 1
}

if [[ $SILENT -eq 0 ]]; then
  if ! play_once "$CHIME"; then
    # Fallback: desktop sound.
    FALLBACK=/usr/share/sounds/freedesktop/stereo/complete.oga
    if [[ -s "$FALLBACK" ]]; then
      play_once "$FALLBACK" || {
        command -v canberra-gtk-play >/dev/null 2>&1 && canberra-gtk-play -i complete 2>/dev/null
      }
    else
      command -v canberra-gtk-play >/dev/null 2>&1 && canberra-gtk-play -i complete 2>/dev/null
    fi
  fi

  sleep 1.5
  play_once "$CHIME" || true

  sleep 1.5
  play_once "$CHIME" || true
fi

if [[ $NOTIFY -eq 1 ]]; then
  command -v notify-send >/dev/null 2>&1 && \
    notify-send "$TITLE" "$BODY" -u "$URGENCY" -t 15000 2>/dev/null || true
fi
