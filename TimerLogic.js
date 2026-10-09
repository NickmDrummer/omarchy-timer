.pragma library

// Helpers puros del Timer: sin estado, solo formato y validacion.
// Se importa como `import "TimerLogic.js" as Logic`.
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

// Normaliza lo leido del JSON: solo entradas validas {id,label,minutes}.
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

function stateFile(dir) {
  return dir + "/state.json";
}
