.pragma library

// Pure Timer helpers: stateless, only formatting and validation.
// Imported as `import "TimerLogic.js" as Logic`.
var _uidCounter = 0;

function clampMinutes(m) {
  var n = Number(m);
  if (!isFinite(n)) return 10;
  return Math.max(1, Math.min(720, Math.round(n)));
}

function clampSeconds(s) {
  var n = Number(s);
  if (!isFinite(n)) return 600;
  return Math.max(5, Math.min(43200, Math.round(n)));
}

// 90 -> "01:30", 3661 -> "1:01:01"
function fmt(totalSec) {
  var s = Math.max(0, Math.ceil(Number(totalSec) || 0));
  var h = Math.floor(s / 3600);
  var m = Math.floor((s % 3600) / 60);
  var r = s % 60;
  function p(n) { return (n < 10 ? "0" : "") + n; }
  if (h > 0) return h + ":" + p(m) + ":" + p(r);
  return p(m) + ":" + p(r);
}

function fmtLong(totalSec) {
  var s = Math.max(0, Math.round(Number(totalSec) || 0));
  var h = Math.floor(s / 3600);
  var m = Math.floor((s % 3600) / 60);
  if (h > 0) return h + " h " + m + " min";
  if (m > 0) {
    var rest = s % 60;
    return rest > 0 ? m + " min " + rest + " s" : m + " min";
  }
  return s + " s";
}

function uid(prefix) {
  _uidCounter += 1;
  return (prefix || "p") + Date.now().toString(36) + "-" + _uidCounter;
}

function defaultPresets() {
  return [
    { id: "preset-10", label: "10", minutes: 10 },
    { id: "preset-15", label: "15", minutes: 15 },
    { id: "preset-30", label: "30", minutes: 30 },
    { id: "preset-40", label: "40", minutes: 40 }
  ];
}

// Normalize what is read from JSON: only valid {id,label,minutes} entries.
function cleanPresets(raw) {
  var list = Array.isArray(raw) ? raw : (raw && Array.isArray(raw.presets) ? raw.presets : []);
  var out = [];
  var seen = {};
  for (var i = 0; i < list.length; i++) {
    var p = list[i];
    if (!p || typeof p !== "object") continue;
    var minutes = clampMinutes(p.minutes);
    var label = String(p.label || minutes).trim().slice(0, 12) || String(minutes);
    var id = String(p.id || ("p-" + label + "-" + minutes)).trim() || uid("p");
    if (seen[id]) id = uid("p");
    seen[id] = true;
    out.push({ id: id, label: label, minutes: minutes });
  }
  if (out.length === 0) return defaultPresets();
  return out.slice(0, 24);
}

// Pomodoro phase configuration. Durations are stored in seconds so short
// phases can be used in tests; the panel presents them as minutes.
function defaultPomodoro() {
  return {
    focusSec: 1500,
    shortSec: 300,
    longSec: 900,
    cyclesBeforeLong: 4,
    autoStartBreaks: true,
    autoStartFocus: false
  };
}

function clampPhaseSeconds(s, fallback) {
  var n = Number(s);
  if (!isFinite(n)) return fallback;
  return Math.max(3, Math.min(43200, Math.round(n)));
}

// Normalize the `pomodoro` key of the config file. Unknown keys are dropped
// and missing ones fall back to defaults, so old configs keep working.
function cleanPomodoro(raw) {
  var d = defaultPomodoro();
  var o = (raw && typeof raw === "object") ? raw : {};
  var cycles = Number(o.cyclesBeforeLong);
  return {
    focusSec: clampPhaseSeconds(o.focusSec, d.focusSec),
    shortSec: clampPhaseSeconds(o.shortSec, d.shortSec),
    longSec: clampPhaseSeconds(o.longSec, d.longSec),
    cyclesBeforeLong: isFinite(cycles) ? Math.max(2, Math.min(12, Math.round(cycles))) : d.cyclesBeforeLong,
    autoStartBreaks: o.autoStartBreaks !== undefined ? !!o.autoStartBreaks : d.autoStartBreaks,
    autoStartFocus: o.autoStartFocus !== undefined ? !!o.autoStartFocus : d.autoStartFocus
  };
}

// ---- alarms --------------------------------------------------------------
var ALARM_DAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];

// Empty by default: the panel starts with no alarms configured.
function defaultAlarms() {
  return [];
}

function clampAlarmHour(h) {
  var n = Number(h);
  if (!isFinite(n)) return 8;
  return Math.max(0, Math.min(23, Math.round(n)));
}

function clampAlarmMinute(m) {
  var n = Number(m);
  if (!isFinite(n)) return 0;
  return Math.max(0, Math.min(59, Math.round(n)));
}

function alarmName(raw) {
  return String(raw || "").trim().slice(0, 10).toUpperCase();
}

// QML hands nested arrays over as list-like objects, where Array.isArray is
// false. Copy by index so both shapes behave the same.
function toList(raw) {
  var out = [];
  if (!raw || typeof raw.length !== "number") return out;
  for (var i = 0; i < raw.length; i++) out.push(raw[i]);
  return out;
}

function alarmDays(raw) {
  var list = toList(raw);
  var seen = {};
  var out = [];
  for (var i = 0; i < list.length; i++) {
    var d = Number(list[i]);
    if (!isFinite(d)) continue;
    d = Math.round(d);
    if (d < 0 || d > 6 || seen[d]) continue;
    seen[d] = true;
    out.push(d);
  }
  out.sort(function(a, b) { return a - b; });
  // "Every day" is the only complete set; an alarm without days has none.
  return out.length === 0 ? [0, 1, 2, 3, 4, 5, 6] : out;
}

// "Every day" | "Sun Mon Tue" — the caption under the alarm time.
function alarmRepeatLabel(days) {
  var list = alarmDays(days);
  if (list.length === 7) return "Every day";
  var names = [];
  for (var i = 0; i < list.length; i++) names.push(ALARM_DAYS[list[i]]);
  return names.join(" ");
}

// Normalize the `alarms` array read from JSON. Invalid entries are dropped so
// a hand-edited file can never break the panel.
function cleanAlarms(raw) {
  var list = Array.isArray(raw) ? raw : [];
  var out = [];
  var seen = {};
  for (var i = 0; i < list.length; i++) {
    var a = list[i];
    if (!a || typeof a !== "object") continue;
    var id = String(a.id || "").trim() || ("alarm-" + i + "-" + clampAlarmHour(a.hour) + clampAlarmMinute(a.minute));
    if (seen[id]) continue;
    seen[id] = true;
    out.push({
      id: id,
      name: alarmName(a.name) || "ALARM",
      hour: clampAlarmHour(a.hour),
      minute: clampAlarmMinute(a.minute),
      days: alarmDays(a.days),
      sound: a.sound !== false,
      enabled: a.enabled !== false
    });
  }
  return out.slice(0, 16);
}

function stateFile(dir) {
  return dir + "/state.json";
}

// Perceived brightness of a QML color (0..1). Used to pick the glass
// density: light themes need a darker scrim so content stays readable.
function luminance(c) {
  if (!c) return 0;
  var r = Number(c.r) || 0;
  var g = Number(c.g) || 0;
  var b = Number(c.b) || 0;
  return 0.299 * r + 0.587 * g + 0.114 * b;
}

function isLight(c) {
  return luminance(c) > 0.55;
}
