import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "TimerLogic.js" as Logic

// Timer — countdown pill in the bar.
// State lives here (source of truth) and syncs across monitors
// via a state file in XDG_RUNTIME_DIR. The Panel and the floating
// window read and act through hostWidget.
BarWidget {
  id: root
  moduleName: "nickmdrummer.timer"

  // ---- state ------------------------------------------------------------
  // idle | running | paused | finished
  property string tState: "idle"
  property int totalSec: 600
  property int remainingSec: 600
  property double endAt: 0
  property int stagedSec: 600
  // Timer staged value is remembered while pomodoro mode borrows stagedSec.
  property int timerStagedSec: 600
  // ---- pomodoro ----------------------------------------------------------
  // Same countdown engine; pomodoro only changes what happens at zero.
  // mode: "timer" | "pomodoro". phase: focus | short | long.
  // pomoDone counts COMPLETED focus blocks in the current set (0..cycles),
  // so a skipped focus block never counts as done.
  property string mode: "timer"
  property string phase: "focus"
  property int pomoDone: 0
  // Only the instance on this screen advances phases and rings, so two
  // bars never complete the same phase twice.
  property string pomoOwner: ""
  property bool detached: false
  // Screen owning the floating window: only that instance shows it (just one).
  property string detachedScreen: ""
  property string screenName: ""
  // Landing after a monitor jump: the owning instance places the
  // card where the pointer crossed instead of the default corner.
  property int landX: -1
  property int landY: -1
  property int landSeq: 0
  property int landSeenSeq: 0
  // Ghost preview on the neighboring monitor while pushing to the edge.
  property string previewScreen: ""
  property int previewX: -1
  property int previewY: -1
  // Monitor map {name,x,y,w,h} for the floating window jump.
  property var monitorMap: []
  function updateScreenName() {
    try {
      var w = pillButton && pillButton.QsWindow ? pillButton.QsWindow.window : null;
      root.screenName = (w && w.screen && w.screen.name) ? String(w.screen.name) : "";
    } catch (e) { root.screenName = ""; }
  }
  property string lastWriter: ""
  property double lastApplied: 0

  readonly property bool soundOn: {
    var v = root.setting("sound", "On");
    return v === true || v === 1 || v === "On" || v === "on" || v === "true";
  }

  // Theme mode: "Original" keeps the custom dark glass look; "Omarchy"
  // follows the active Omarchy theme tokens (native-looking surfaces).
  readonly property bool omarchyTheme: root.setting("theme", "Original") === "Omarchy"
  readonly property bool lightTheme: Logic.isLight(root.bar ? root.bar.background : Color.background)

  // ---- paths ------------------------------------------------------------
  readonly property string homeDir: Quickshell.env("HOME")
  // XDG_RUNTIME_DIR is private per user (0700) by spec. If a session lacks
  // it, fall back to the user's own state dir: never a shared path like
  // /tmp, where another local user could precreate state.json.
  readonly property string runDir: {
    var runtime = Quickshell.env("XDG_RUNTIME_DIR");
    if (runtime && runtime !== "") return runtime + "/nickmdrummer-timer";
    var state = Quickshell.env("XDG_STATE_HOME");
    var base = (state && state !== "") ? state : (root.homeDir + "/.local/state");
    return base + "/nickmdrummer-timer";
  }
  // File-based sync stays off until the run dir passes the ownership/type
  // checks below, so a hostile path is never read into the shell.
  property bool runDirSafe: false
  readonly property string statePath: root.runDirSafe ? (root.runDir + "/state.json") : ""
  readonly property string configDir: (Quickshell.env("XDG_CONFIG_HOME") || (root.homeDir + "/.config")) + "/nickmdrummer-timer"
  readonly property string presetsPath: root.configDir + "/presets.json"
  readonly property string pluginDir: decodeURIComponent(String(Qt.resolvedUrl(".")).replace(/^file:\/\//, ""))
  readonly property string alarmScript: root.pluginDir + "scripts/timer-alarm.sh"

  // ---- presets + pomodoro config (editable, persisted in JSON) ----------
  property var presets: Logic.defaultPresets()
  property var pomodoro: Logic.defaultPomodoro()
  property var alarms: Logic.defaultAlarms()
  property bool presetsReady: false

  function loadPresets(text) {
    var parsed = null;
    try { parsed = JSON.parse(String(text || "")); } catch (e) { parsed = null; }
    if (parsed) root.presets = Logic.cleanPresets(parsed);
    else root.presets = Logic.defaultPresets();
    root.pomodoro = Logic.cleanPomodoro(parsed ? parsed.pomodoro : null);
    root.alarms = Logic.cleanAlarms(parsed ? parsed.alarms : null);
    root.presetsReady = true;
    root.refreshAlarmSchedule();
    // External config edits retarget an idle pomodoro display, but never
    // rewrite the shared state (that would bounce between monitors).
    if (root.mode === "pomodoro" && root.tState === "idle") {
      root.stagedSec = root.pomodoro.focusSec;
      root.totalSec = root.stagedSec;
      root.remainingSec = root.stagedSec;
    }
  }

  function savePresets() {
    if (!root.presetsReady) return;
    presetsSave.restart();
  }

  // Merge a partial pomodoro config, normalize it and persist it together
  // with the presets (single config file, single debounced write).
  function updatePomodoro(patch) {
    var merged = {};
    var key;
    for (key in root.pomodoro) merged[key] = root.pomodoro[key];
    for (key in patch) merged[key] = patch[key];
    root.pomodoro = Logic.cleanPomodoro(merged);
    root.savePresets();
  }

  // ---- alarms (add/edit/remove, persisted with the rest of the config) ---
  function addAlarm(alarm) {
    var next = root.alarms.slice();
    var id = Logic.uid("a");
    var clean = Logic.cleanAlarms([{
      id: id,
      name: alarm && alarm.name,
      hour: alarm && alarm.hour,
      minute: alarm && alarm.minute,
      days: alarm && alarm.days,
      sound: alarm && alarm.sound,
      enabled: true
    }]);
    if (clean.length === 0) return "";
    next.push(clean[0]);
    root.alarms = next.slice(0, 16);
    root.refreshAlarmSchedule();
    root.savePresets();
    return clean[0].id;
  }

  function updateAlarm(id, patch) {
    root.alarms = root.alarms.map(function(a) {
      if (String(a.id) !== String(id)) return a;
      var merged = { id: a.id, name: a.name, hour: a.hour, minute: a.minute, days: a.days, sound: a.sound, enabled: a.enabled };
      for (var k in patch) merged[k] = patch[k];
      var clean = Logic.cleanAlarms([merged]);
      return clean.length ? clean[0] : a;
    });
    root.refreshAlarmSchedule();
    root.savePresets();
  }

  function removeAlarm(id) {
    root.alarms = root.alarms.filter(function(a) { return String(a.id) !== String(id); });
    root.refreshAlarmSchedule();
    root.savePresets();
  }

  function setAlarmEnabled(id, on) {
    root.updateAlarm(id, { enabled: on === true });
  }

  // ---- alarms: schedule engine ------------------------------------------
  // Each monitor computes the same next occurrence; a per-occurrence claim
  // directory in the private run dir makes sure only one of them rings.
  property var alarmNextMap: ({})

  function alarmTimeLabel(a) {
    var h = a.hour < 10 ? "0" + a.hour : String(a.hour);
    var m = a.minute < 10 ? "0" + a.minute : String(a.minute);
    return h + ":" + m;
  }

  // Next epoch for the given alarm, strictly after `fromMs`, local time.
  // Day arithmetic goes through the Date constructor so DST shifts keep the
  // wall-clock hour instead of drifting by an hour.
  function nextAlarmAt(alarm, fromMs) {
    var now = new Date(fromMs);
    var best = 0;
    for (var i = 0; i < alarm.days.length; i++) {
      var delta = (alarm.days[i] - now.getDay() + 7) % 7;
      var day = now.getDate() + delta;
      var cand = new Date(now.getFullYear(), now.getMonth(), day, alarm.hour, alarm.minute, 0, 0).getTime();
      if (cand <= fromMs) cand = new Date(now.getFullYear(), now.getMonth(), day + 7, alarm.hour, alarm.minute, 0, 0).getTime();
      if (best === 0 || cand < best) best = cand;
    }
    return best;
  }

  // Signature of what defines the schedule: time + days. Kept with each
  // pending occurrence so a config reload does not forget an alarm that was
  // already due while the session was frozen.
  function alarmSignature(a) {
    return a.hour + ":" + a.minute + ":" + a.days.join(",");
  }

  function refreshAlarmSchedule() {
    var prev = root.alarmNextMap || {};
    var map = {};
    var now = Date.now();
    for (var i = 0; i < root.alarms.length; i++) {
      var a = root.alarms[i];
      if (!a.enabled) continue;
      var sig = root.alarmSignature(a);
      var old = prev[a.id];
      if (old && old.at && old.sig === sig) map[a.id] = old;
      else map[a.id] = { at: root.nextAlarmAt(a, now), sig: sig };
    }
    root.alarmNextMap = map;
  }

  // Fires anything due. Overdue by more than 2 minutes (laptop was suspended)
  // only notifies: no chime for something you already missed.
  function checkAlarms() {
    var now = Date.now();
    var map = root.alarmNextMap;
    var due = [];
    var changed = false;
    for (var i = 0; i < root.alarms.length; i++) {
      var a = root.alarms[i];
      if (!a.enabled) {
        if (map[a.id] !== undefined) { delete map[a.id]; changed = true; }
        continue;
      }
      var entry = map[a.id];
      if (!entry) {
        entry = { at: root.nextAlarmAt(a, now), sig: root.alarmSignature(a) };
        map[a.id] = entry;
        changed = true;
      }
      if (now >= entry.at) {
        due.push({ alarm: a, at: entry.at, late: now - entry.at });
        entry.at = root.nextAlarmAt(a, now + 1000);
        entry.sig = root.alarmSignature(a);
        changed = true;
      }
    }
    if (changed) root.alarmNextMap = map;
    if (due.length === 0) return;
    root.claimAlarms(due);
  }

  // One mkdir per occurrence decides the single instance that rings.
  readonly property string alarmClaimScript: [
    "set -u",
    "dir=\"$0\"",
    "claims=\"$dir/alarm-claims\"",
    "mkdir -p \"$claims\" 2>/dev/null || exit 0",
    "for key in \"$@\"; do",
    "  if mkdir \"$claims/$key\" 2>/dev/null; then echo \"$key\"; fi",
    "done",
    "find \"$claims\" -mindepth 1 -maxdepth 1 -mtime +2 -exec rm -rf {} + 2>/dev/null || true"
  ].join("\n")

  function claimAlarms(due) {
    if (!root.runDirSafe) return;
    alarmClaimProc.pending = due;
    var args = ["bash", "-c", root.alarmClaimScript, root.runDir];
    for (var i = 0; i < due.length; i++) args.push(String(due[i].alarm.id) + "@" + String(due[i].at));
    alarmClaimProc.command = args;
    alarmClaimProc.running = true;
  }

  function fireClaimedAlarms(pending, keys) {
    var claimed = [];
    for (var i = 0; i < pending.length; i++) {
      var p = pending[i];
      if (keys.indexOf(String(p.alarm.id) + "@" + String(p.at)) >= 0) claimed.push(p);
    }
    if (claimed.length === 0) return;
    var loud = false;
    for (var j = 0; j < claimed.length; j++) {
      if (claimed[j].late <= 120000 && claimed[j].alarm.sound && root.soundOn) loud = true;
    }
    if (loud) Quickshell.execDetached(["bash", root.alarmScript, "--no-notify"]);
    for (var k = 0; k < claimed.length; k++) {
      var c = claimed[k];
      var missed = c.late > 120000;
      var body = (missed ? "Missed " : "") + c.alarm.name + " — " + root.alarmTimeLabel(c.alarm);
      Quickshell.execDetached([
        "notify-send", "Looper", body,
        "-u", missed ? "normal" : "critical",
        "-t", "15000"
      ]);
    }
  }

  Process {
    id: alarmClaimProc
    property var pending: []
    command: []
    stdout: StdioCollector { id: alarmClaimOut; waitForEnd: true }
    onExited: function(code) {
      var raw = String(alarmClaimOut.text || "").trim();
      var keys = raw.length > 0 ? raw.split("\n") : [];
      root.fireClaimedAlarms(alarmClaimProc.pending, keys);
    }
  }

  Timer {
    id: alarmTick
    interval: 5000
    repeat: true
    running: root.alarms.length > 0
    onTriggered: root.checkAlarms()
  }

  function addPreset(label, minutes) {    var m = Logic.clampMinutes(minutes);
    var name = String(label || m).trim().slice(0, 12) || String(m);
    var next = root.presets.slice();
    next.push({ id: Logic.uid("p"), label: name, minutes: m });
    root.presets = next.slice(0, 24);
    root.savePresets();
  }

  function removePreset(id) {
    root.presets = root.presets.filter(function(p) { return String(p.id) !== String(id); });
    if (root.presets.length === 0) root.presets = Logic.defaultPresets();
    root.savePresets();
  }

  function renamePreset(id, label, minutes) {
    var m = Logic.clampMinutes(minutes);
    var name = String(label || m).trim().slice(0, 12) || String(m);
    root.presets = root.presets.map(function(p) {
      if (String(p.id) === String(id)) return { id: p.id, label: name, minutes: m };
      return p;
    });
    root.savePresets();
  }

  function resetPresets() {
    root.presets = Logic.defaultPresets();
    root.savePresets();
  }

  FileView {
    id: presetsView
    path: root.presetsPath
    printErrors: false
    onLoaded: root.loadPresets(presetsView.text())
    onLoadFailed: { root.loadPresets(""); }
    onFileChanged: {
      // Re-read without overwriting a local edit in progress.
      presetsReload.restart();
    }
  }

  Timer {
    id: presetsReload
    interval: 400
    onTriggered: {
      if (presetsSave.running) return;
      presetsView.reload();
    }
  }

  Timer {
    id: presetsSave
    interval: 500
    onTriggered: {
      var payload = JSON.stringify({ version: 1, presets: root.presets, pomodoro: root.pomodoro, alarms: root.alarms }, null, 2) + "\n";
      presetsView.setText(payload);
    }
  }

  // ---- shared state file (multi-monitor sync) ---------------------------
  FileView {
    id: stateView
    path: root.statePath
    printErrors: false
    watchChanges: true
    onLoaded: root.applyStateText(stateView.text())
    onLoadFailed: root.writeState()
    onFileChanged: stateApplyDebounce.restart()
  }
  Timer {
    id: stateApplyDebounce
    interval: 120
    onTriggered: {
      if (!root.runDirSafe) return;
      stateView.reload();
      root.applyStateText(stateView.text());
    }
  }

  function applyStateText(text) {
    // Never consume sync data unless the run dir passed validation.
    if (!root.runDirSafe) return;
    var o = null;
    try { o = JSON.parse(String(text || "")); } catch (e) { return; }
    if (!o || typeof o !== "object") return;
    var stamp = Number(o.updatedAt || 0);
    if (!(stamp > root.lastApplied)) return;
    // Do not overwrite an already-alarmed local finished with a stale echo.
    root.lastApplied = stamp;
    root.lastWriter = String(o.writer || "");
    var mode = o.mode === "pomodoro" ? "pomodoro" : "timer";
    if (mode !== root.mode) {
      // Keep each mode's own staged duration without writing state back.
      if (mode === "pomodoro") root.timerStagedSec = root.stagedSec;
      else root.stagedSec = root.timerStagedSec;
      root.mode = mode;
    }
    var phase = String(o.phase || "focus");
    if (["focus", "short", "long"].indexOf(phase) < 0) phase = "focus";
    root.phase = phase;
    root.pomoDone = Math.max(0, Math.min(root.pomodoro.cyclesBeforeLong, Math.round(Number(o.done) || 0)));
    root.pomoOwner = String(o.owner || "");
    var st = String(o.state || "idle");
    if (["idle", "running", "paused", "finished"].indexOf(st) < 0) st = "idle";
    var total = Logic.clampSeconds(o.total);
    var rem = Logic.clampSeconds(o.remaining !== undefined ? o.remaining : total);
    root.totalSec = total;
    root.endAt = Number(o.endAt || 0);
    root.detached = o.detached === true;
    root.detachedScreen = String(o.detachedScreen || "");
    root.landX = Math.round(Number(o.landX !== undefined ? o.landX : -1));
    root.landY = Math.round(Number(o.landY !== undefined ? o.landY : -1));
    root.landSeq = Math.round(Number(o.landSeq || 0));
    root.previewScreen = String(o.previewScreen || "");
    root.previewX = Math.round(Number(o.previewX !== undefined ? o.previewX : -1));
    root.previewY = Math.round(Number(o.previewY !== undefined ? o.previewY : -1));
    if (st === "running" && root.endAt > 0) {
      var left = Math.max(0, Math.round((root.endAt - Date.now()) / 1000));
      root.remainingSec = left;
      if (left <= 0) {
        root.finish(true);
        return;
      }
    } else {
      root.remainingSec = Math.min(rem, 43200);
    }
    if (root.tState !== "finished" || st !== "running") root.tState = st;
    if (st === "idle") {
      root.stagedSec = root.mode === "pomodoro"
        ? root.pomodoro.focusSec
        : Logic.clampSeconds(o.staged !== undefined ? o.staged : total);
    }
    // If we load a "finished" state (e.g. shell restart), still calm it down.
    if (st === "finished") finishCalm.restart();
    else finishCalm.stop();
  }

  function writeState() {
    if (!root.runDirSafe) return;
    var stamp = Date.now() + Math.random();
    root.lastApplied = stamp;
    root.lastWriter = root.moduleName;
    var payload = JSON.stringify({
      version: 1,
      state: root.tState,
      total: root.totalSec,
      remaining: root.remainingSec,
      staged: root.stagedSec,
      mode: root.mode,
      phase: root.phase,
      done: root.pomoDone,
      owner: root.pomoOwner,
      endAt: root.endAt,
      detached: root.detached,
      detachedScreen: root.detachedScreen,
      landX: root.landX,
      landY: root.landY,
      landSeq: root.landSeq,
      previewScreen: root.previewScreen,
      previewX: root.previewX,
      previewY: root.previewY,
      writer: root.moduleName,
      updatedAt: stamp
    });
    stateView.setText(payload);
  }

  // ---- actions ----------------------------------------------------------
  function startSeconds(sec) {
    var s = Logic.clampSeconds(sec);
    finishCalm.stop();
    root.totalSec = s;
    root.stagedSec = s;
    root.remainingSec = s;
    root.endAt = Date.now() + s * 1000;
    root.tState = "running";
    root.writeState();
  }

  // Persists a bar-widget setting (same path the shell uses for the bar) and
  // updates the live instances, so the panel reflects it without a restart.
  function setSetting(key, value) {
    var entry = { id: root.moduleName };
    for (var k in root.settings) if (k !== "id") entry[k] = root.settings[k];
    entry[key] = value;
    root.settings = entry;
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function") {
      try { root.bar.shell.updateEntryInline(root.moduleName, entry); } catch (e) {}
    }
  }

  function startStaged() {
    if (root.mode === "pomodoro") { root.startPomodoro(); return; }
    root.startSeconds(root.stagedSec);
  }

  // ---- pomodoro engine ---------------------------------------------------
  function phaseSeconds(phase) {
    var cfg = root.pomodoro;
    if (phase === "short") return cfg.shortSec;
    if (phase === "long") return cfg.longSec;
    return cfg.focusSec;
  }

  function setMode(m) {
    var next = (m === "pomodoro") ? "pomodoro" : "timer";
    if (next === root.mode) return;
    finishCalm.stop();
    if (next === "pomodoro") {
      root.timerStagedSec = root.stagedSec;
      root.mode = "pomodoro";
      root.pomoOwner = root.screenName;
      root.stagedSec = root.pomodoro.focusSec;
    } else {
      root.mode = "timer";
      root.pomoOwner = "";
      root.stagedSec = root.timerStagedSec;
    }
    root.phase = "focus";
    root.pomoDone = 0;
    root.tState = "idle";
    root.endAt = 0;
    root.totalSec = root.stagedSec;
    root.remainingSec = root.stagedSec;
    root.writeState();
  }

  // True only on the instance allowed to advance phases. If the recorded
  // owner screen is gone (unplugged, shell restart) or stalled, the first
  // screen in alphabetical order takes over.
  function pomoDriver() {
    if (root.pomoOwner !== "" && root.pomoOwner === root.screenName) return true;
    root.refreshMonitors();
    var names = [];
    for (var i = 0; i < root.monitorMap.length; i++) names.push(root.monitorMap[i].name);
    if (names.length === 0) return root.pomoOwner === "";
    names.sort();
    if (names[0] !== root.screenName) return false;
    if (root.pomoOwner === "") return true;
    if (!root.rectFor(root.pomoOwner)) return true;
    return root.endAt > 0 && (Date.now() - root.endAt) > 4000;
  }

  // running=false leaves the next phase paused, waiting for a click.
  function enterPhase(phase, running) {
    finishCalm.stop();
    root.phase = phase;
    var s = root.phaseSeconds(phase);
    root.totalSec = s;
    root.remainingSec = s;
    if (running) {
      root.endAt = Date.now() + s * 1000;
      root.tState = "running";
    } else {
      root.endAt = 0;
      root.tState = "paused";
    }
    root.writeState();
  }

  function startPomodoro() {
    root.pomoDone = 0;
    root.pomoOwner = root.screenName;
    root.enterPhase("focus", true);
  }

  function pomodoroReset() {
    root.pomoDone = 0;
    root.pomoOwner = root.screenName;
    root.enterPhase("focus", false);
  }

  // A phase reached zero on the driving instance: chime, notify, advance.
  // A finished long break ends the whole set (idle) instead of staging a
  // new focus: Start begins the next set, like everywhere else.
  function completePhase() {
    var cfg = root.pomodoro;
    var ended = root.phase;
    if (ended === "long") {
      root.alarmTitle = "Pomodoro";
      root.alarmBody = "Set complete — " + cfg.cyclesBeforeLong + " focus blocks done";
      root.alarmUrgency = "critical";
      if (root.soundOn) alarmProc.running = true;
      else notifyProc.running = true;
      root.endPomodoroSet();
      return;
    }
    if (ended === "focus") root.pomoDone = Math.min(cfg.cyclesBeforeLong, root.pomoDone + 1);
    var next;
    if (ended === "focus") next = (root.pomoDone >= cfg.cyclesBeforeLong) ? "long" : "short";
    else next = "focus";
    var auto = (next === "focus") ? cfg.autoStartFocus : cfg.autoStartBreaks;
    var mins = Math.round(root.phaseSeconds(next) / 60);
    root.alarmTitle = "Pomodoro";
    if (ended === "focus") {
      root.alarmBody = (next === "long") ? "Cycle complete — long break" : "Focus done — " + mins + " min break";
      root.alarmUrgency = (next === "long") ? "critical" : "normal";
    } else {
      root.alarmBody = "Break over — back to focus";
      root.alarmUrgency = "normal";
    }
    if (root.soundOn) alarmProc.running = true;
    else notifyProc.running = true;
    root.enterPhase(next, auto);
  }

  // The set is over: back to an idle focus, keeping the completed count so
  // the panel can announce it until the next set starts.
  function endPomodoroSet() {
    finishCalm.stop();
    root.phase = "focus";
    root.pomoDone = root.pomodoro.cyclesBeforeLong;
    root.stagedSec = root.pomodoro.focusSec;
    root.totalSec = root.stagedSec;
    root.remainingSec = root.stagedSec;
    root.endAt = 0;
    root.tState = "idle";
    root.writeState();
  }

  // Skip advances without ringing; an early skipped focus block does not
  // count as completed, so the set does not move forward either.
  // Skipping the long break ends the set, like finishing it.
  function skipPhase() {
    if (root.mode !== "pomodoro") return;
    if (root.phase === "focus") {
      root.enterPhase(root.pomoDone >= root.pomodoro.cyclesBeforeLong ? "long" : "short", false);
    } else if (root.phase === "long") {
      root.endPomodoroSet();
    } else {
      root.enterPhase("focus", false);
    }
  }

  function pause() {
    if (root.tState !== "running") return;
    finishCalm.stop();
    root.remainingSec = Math.max(0, Math.round((root.endAt - Date.now()) / 1000));
    root.tState = "paused";
    root.writeState();
  }

  function resume() {
    if (root.tState !== "paused") return;
    finishCalm.stop();
    root.endAt = Date.now() + Math.max(1, root.remainingSec) * 1000;
    root.tState = "running";
    root.writeState();
  }

  function togglePause() {
    if (root.tState === "running") root.pause();
    else if (root.tState === "paused") root.resume();
    else if (root.tState === "finished") root.dismiss();
    else root.startStaged();
  }

  function resetAll() {
    finishCalm.stop();
    root.tState = "idle";
    if (root.mode === "pomodoro") {
      root.phase = "focus";
      root.pomoDone = 0;
      root.stagedSec = root.pomodoro.focusSec;
    }
    root.remainingSec = root.stagedSec;
    root.totalSec = root.stagedSec;
    root.endAt = 0;
    root.writeState();
  }

  function dismiss() {
    finishCalm.stop();
    root.tState = "idle";
    root.remainingSec = root.stagedSec;
    root.endAt = 0;
    root.writeState();
  }

  // +5 / -5 live (works in idle on staged, or while running/paused).
  function nudge(deltaSec) {
    var d = Number(deltaSec) || 0;
    finishCalm.stop();
    if (root.tState === "running") {
      root.endAt += d * 1000;
      var left = Math.max(0, Math.round((root.endAt - Date.now()) / 1000));
      root.remainingSec = left;
      if (left > root.totalSec) root.totalSec = left;
      if (left <= 0) { root.finish(true); return; }
    } else if (root.tState === "paused" || root.tState === "finished") {
      root.remainingSec = Logic.clampSeconds(root.remainingSec + d);
      if (root.remainingSec > root.totalSec) root.totalSec = root.remainingSec;
      if (root.tState === "finished" && root.remainingSec > 0) root.tState = "paused";
    } else {
      // Idle in pomodoro mode stages the focus duration itself, so the
      // wheel and the panel steppers edit the same value.
      if (root.mode === "pomodoro") {
        root.updatePomodoro({ focusSec: Logic.clampPhaseSeconds(root.pomodoro.focusSec + d, root.pomodoro.focusSec) });
        root.stagedSec = root.pomodoro.focusSec;
      } else {
        root.stagedSec = Logic.clampSeconds(root.stagedSec + d);
      }
      root.remainingSec = root.stagedSec;
      root.totalSec = root.stagedSec;
    }
    root.writeState();
  }

  function stageSeconds(sec) {
    if (root.tState === "running" || root.tState === "paused") return;
    if (root.mode === "pomodoro") {
      root.updatePomodoro({ focusSec: Logic.clampPhaseSeconds(sec, root.pomodoro.focusSec) });
      root.stagedSec = root.pomodoro.focusSec;
    } else {
      root.stagedSec = Logic.clampSeconds(sec);
    }
    root.remainingSec = root.stagedSec;
    root.totalSec = root.stagedSec;
    root.writeState();
  }

  function setDetached(v) {
    root.detached = v === true;
    // Only the screen where the floating window was requested shows it.
    root.detachedScreen = root.detached ? root.screenName : "";
    // Manual detach: no landing (default position).
    root.landX = -1;
    root.landY = -1;
    if (root.detached) root.refreshMonitors();
    root.writeState();
    // Persist in shell.json to survive restarts.
    var entry = { id: root.moduleName };
    for (var k in root.settings) if (k !== "id") entry[k] = root.settings[k];
    entry.detached = root.detached;
    root.settings = entry;
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function") {
      try { root.bar.shell.updateEntryInline(root.moduleName, entry); } catch (e) {}
    }
  }

  function finish(fromTick) {
    if (root.mode === "pomodoro") {
      // Non-driving instances wait for the owner's state write instead of
      // advancing (and ringing) a second time.
      if (!root.pomoDriver()) { root.remainingSec = 0; return; }
      root.completePhase();
      return;
    }
    root.tState = "finished";
    root.remainingSec = 0;
    root.endAt = 0;
    root.writeState();
    // The pill returns to its inactive background when the notification
    // expires (~15 s): red does not stay stuck until the click.
    finishCalm.restart();
    root.alarmTitle = "Timer";
    root.alarmBody = "Time's up";
    root.alarmUrgency = "critical";
    // The alarm self-dedups across monitors with flock inside the script.
    if (root.soundOn) alarmProc.running = true;
    else notifyProc.running = true;
    if (root.bar && root.bar.shell && typeof root.bar.shell.summon === "function") {
      // Do not force opening: only pulse in the bar + floating window.
    }
  }

  property string alarmTitle: "Timer"
  property string alarmBody: "Time's up"
  property string alarmUrgency: "critical"

  Process {
    id: alarmProc
    command: ["bash", root.alarmScript, "--title", root.alarmTitle, "--body", root.alarmBody, "--urgency", root.alarmUrgency]
  }
  Process {
    id: notifyProc
    // Goes through the script to reuse its flock: a single notification
    // even with one bar per monitor.
    command: ["bash", root.alarmScript, "--silent", "--title", root.alarmTitle, "--body", root.alarmBody, "--urgency", root.alarmUrgency]
  }

  // Creates/validates the private dirs. Refuses symlinks, foreign ownership
  // and non-regular state files, and locks permissions down to 0700.
  readonly property string runDirSetup: [
    "set -eu",
    "umask 077",
    "dir=\"$0\"",
    "cfg=\"$1\"",
    "if [ -L \"$dir\" ]; then echo 'run dir is a symlink' >&2; exit 1; fi",
    "if [ -e \"$dir\" ] && [ ! -d \"$dir\" ]; then echo 'run dir is not a directory' >&2; exit 1; fi",
    "install -d -m 700 -- \"$dir\"",
    "[ -O \"$dir\" ] || { echo 'run dir is not owned by this user' >&2; exit 1; }",
    "chmod 700 -- \"$dir\"",
    "state=\"$dir/state.json\"",
    "if [ -e \"$state\" ] || [ -L \"$state\" ]; then",
    "  if [ ! -f \"$state\" ] || [ -L \"$state\" ] || [ ! -O \"$state\" ]; then",
    "    rm -f -- \"$state\"",
    "  fi",
    "fi",
    "if [ -f \"$state\" ]; then chmod 600 -- \"$state\"; fi",
    "if [ -L \"$cfg\" ]; then echo 'config dir is a symlink' >&2; exit 1; fi",
    "if [ -e \"$cfg\" ] && [ ! -d \"$cfg\" ]; then echo 'config dir is not a directory' >&2; exit 1; fi",
    "install -d -m 700 -- \"$cfg\"",
    "[ -O \"$cfg\" ] || { echo 'config dir is not owned by this user' >&2; exit 1; }"
  ].join("\n")

  Process {
    id: mkdirProc
    command: ["bash", "-c", root.runDirSetup, root.runDir, root.configDir]
    onExited: function(code) {
      root.runDirSafe = (code === 0);
      if (!root.runDirSafe) {
        console.warn("nickmdrummer.timer: unsafe state dir, cross-monitor sync disabled");
        return;
      }
      presetsView.reload();
      stateView.reload();
    }
  }

  // Monitor geometry for the floating window jump across screens.
  // Quickshell.screens reports logical coordinates (scale already applied),
  // exactly the space the layer surfaces and the pointer live in. Using
  // hyprctl width/height here mixed physical pixels with the logical x/y
  // and broke the neighbor detection on scaled displays.
  function screenRects() {
    var out = [];
    var ss = Quickshell.screens || [];
    for (var i = 0; i < ss.length; i++) {
      var s = ss[i];
      if (!s || !s.name) continue;
      out.push({
        name: String(s.name),
        x: Math.round(s.x),
        y: Math.round(s.y),
        w: Math.round(s.width),
        h: Math.round(s.height)
      });
    }
    return out;
  }

  function refreshMonitors() {
    var list = root.screenRects();
    if (list.length > 0) root.monitorMap = list;
  }

  function rectFor(name) {
    if (!name) return null;
    for (var i = 0; i < root.monitorMap.length; i++)
      if (root.monitorMap[i].name === name) return root.monitorMap[i];
    return null;
  }

  // Pointer position (local to the owner screen) -> absolute layout coords.
  function globalPoint(lx, ly) {
    var cur = root.rectFor(root.detachedScreen) || root.rectFor(root.screenName);
    if (!cur) return { x: Number(lx) || 0, y: Number(ly) || 0 };
    return { x: cur.x + (Number(lx) || 0), y: cur.y + (Number(ly) || 0) };
  }

  // Signed distance from the current monitor edge to the candidate.
  function edgeGap(dir, cur, m) {
    if (dir === "right") return m.x - (cur.x + cur.w);
    if (dir === "left") return cur.x - (m.x + m.w);
    if (dir === "down") return m.y - (cur.y + cur.h);
    return cur.y - (m.y + m.h);
  }

  // How far the pointer line falls outside the candidate (0 = aligned).
  function perpendicularGap(dir, m, absX, absY) {
    var horizontal = (dir === "right" || dir === "left");
    var p = horizontal ? absY : absX;
    var lo = horizontal ? m.y : m.x;
    var hi = horizontal ? (m.y + m.h) : (m.x + m.w);
    if (p < lo) return lo - p;
    if (p > hi) return p - hi;
    return 0;
  }

  // Neighboring monitor in the given direction (map object or null).
  // Prefers the monitor the pointer is pushing towards; falls back to the
  // nearest monitor centered in that direction so regular layouts work.
  function findNeighborObj(dir, absX, absY) {
    var cur = root.rectFor(root.detachedScreen);
    if (!cur) return null;
    var px = Number(absX) || 0;
    var py = Number(absY) || 0;
    var best = null;
    var bestScore = 1e18;
    var i, m, gap, perp, score;
    for (i = 0; i < root.monitorMap.length; i++) {
      m = root.monitorMap[i];
      if (m.name === cur.name) continue;
      gap = root.edgeGap(dir, cur, m);
      // Allow a few pixels of overlap: fractional layout positions.
      if (gap < -8) continue;
      perp = root.perpendicularGap(dir, m, px, py);
      score = Math.max(0, gap) + perp * 1.5;
      if (score < bestScore) { bestScore = score; best = m; }
    }
    if (best) return best;
    // Fallback: closest monitor whose center lies in the pushed direction.
    var cx = cur.x + cur.w / 2;
    var cy = cur.y + cur.h / 2;
    for (i = 0; i < root.monitorMap.length; i++) {
      m = root.monitorMap[i];
      if (m.name === cur.name) continue;
      var dx = (m.x + m.w / 2) - cx;
      var dy = (m.y + m.h / 2) - cy;
      var inDir = (dir === "right" && dx > 0) || (dir === "left" && dx < 0)
        || (dir === "down" && dy > 0) || (dir === "up" && dy < 0);
      if (!inDir) continue;
      score = Math.abs(dx) + Math.abs(dy) + Math.abs(root.edgeGap(dir, cur, m)) * 4;
      if (score < bestScore) { bestScore = score; best = m; }
    }
    return best;
  }

  // Landing position inside the target monitor, in that screen's local
  // coords. Keeps the pointer's relative position and sticks to the edge
  // the card crossed.
  function landingFor(dir, absX, absY, tgtName) {
    var cur = root.rectFor(root.detachedScreen);
    var tgt = root.rectFor(tgtName);
    if (!cur || !tgt) return null;
    var card = 244;
    var pad = 12;
    var rx = cur.w > 0 ? ((Number(absX) || 0) - cur.x) / cur.w : 0.5;
    var ry = cur.h > 0 ? ((Number(absY) || 0) - cur.y) / cur.h : 0.5;
    rx = Math.max(0, Math.min(1, rx));
    ry = Math.max(0, Math.min(1, ry));
    var gx, gy;
    if (dir === "right") {
      gx = tgt.x + pad;
      gy = tgt.y + ry * tgt.h - card / 2;
    } else if (dir === "left") {
      gx = tgt.x + tgt.w - card - pad;
      gy = tgt.y + ry * tgt.h - card / 2;
    } else if (dir === "down") {
      gy = tgt.y + pad;
      gx = tgt.x + rx * tgt.w - card / 2;
    } else {
      gy = tgt.y + tgt.h - card - pad;
      gx = tgt.x + rx * tgt.w - card / 2;
    }
    var lx = gx - tgt.x;
    var ly = gy - tgt.y;
    var maxX = Math.max(pad, tgt.w - card - pad);
    var maxY = Math.max(pad, tgt.h - card - pad);
    lx = Math.max(pad, Math.min(maxX, lx));
    ly = Math.max(pad, Math.min(maxY, ly));
    return { x: Math.round(lx), y: Math.round(ly) };
  }

  // Moves the floating window to the neighboring monitor in the given direction,
  // landing where the pointer crossed (absolute layout coords).
  function hopFloating(dir, absX, absY) {
    var best = root.findNeighborObj(dir, absX, absY);
    if (!best) return false;
    var L = root.landingFor(dir, absX, absY, best.name);
    if (!L) return false;
    root.detachedScreen = best.name;
    root.landX = L.x;
    root.landY = L.y;
    root.landSeq = root.landSeq + 1;
    root.previewScreen = "";
    root.previewX = -1;
    root.previewY = -1;
    root.writeState();
    return true;
  }

  // Ghost on the neighbor while pushing (throttled by the caller).
  function writePreview(screen, x, y) {
    root.previewScreen = String(screen || "");
    root.previewX = Math.round(Number(x) || 0);
    root.previewY = Math.round(Number(y) || 0);
    root.writeState();
  }

  function clearPreview() {
    if (root.previewScreen === "") return;
    root.previewScreen = "";
    root.previewX = -1;
    root.previewY = -1;
    root.writeState();
  }

  Connections {
    target: Quickshell
    function onScreensChanged() { root.refreshMonitors(); }
  }

  Timer {
    id: tick
    interval: 250
    running: root.tState === "running"
    repeat: true
    onTriggered: {
      if (root.endAt <= 0) return;
      var left = Math.round((root.endAt - Date.now()) / 1000);
      if (left <= 0) root.finish(true);
      else root.remainingSec = left;
    }
  }

  // Calms the "finished" red (back to idle/inactive).
  Timer {
    id: finishCalm
    interval: 15000
    repeat: false
    onTriggered: {
      if (root.tState === "finished") root.dismiss();
    }
  }

  // ---- embedded panel ---------------------------------------------------
  readonly property bool opened: panelItem ? panelItem.opened === true : false
  readonly property bool popoutSwitchClosing: panelItem ? panelItem.popoutSwitchClosing === true : false
  function open() { if (panelItem) panelItem.open(); }
  function close() { if (panelItem) panelItem.close(); }
  function togglePanel() { if (panelItem) panelItem.toggle(); }
  function closeForPopoutSwitch() { if (panelItem) panelItem.closeForPopoutSwitch(); }

  property var panelItem: null
  function injectPanel() {
    var target = panelLoader.item;
    if (!target) return;
    root.panelItem = target;
    if ("bar" in target) target.bar = root.bar;
    if ("settings" in target) target.settings = root.settings;
    if ("anchorItem" in target) target.anchorItem = pillButton;
    if ("hostWidget" in target) target.hostWidget = root;
  }
  onBarChanged: {
    injectPanel();
    updateScreenName();
  }
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel();
      Qt.callLater(root.injectPanel);
    }
  }

  IpcHandler {
    target: "nickmdrummer.timer"
    function open(): void { root.open(); }
    function close(): void { root.close(); }
    function show(): void { root.open(); }
    function hide(): void { root.close(); }
    function toggle(): void { root.togglePanel(); }
    function start(minutes: string): void { root.setMode("timer"); root.startSeconds(Number(minutes) * 60 || 600); }
    function stop(): void { root.resetAll(); }
    function mode(m: string): void { root.setMode(m); }
    function pomodoro(action: string): void {
      if (action === "start") {
        if (root.mode !== "pomodoro") root.setMode("pomodoro");
        root.startPomodoro();
      } else if (action === "pause") root.pause();
      else if (action === "resume") root.resume();
      else if (action === "skip") root.skipPhase();
      else if (action === "reset") {
        if (root.mode !== "pomodoro") root.setMode("pomodoro");
        root.pomodoroReset();
      } else if (action === "stop") root.resetAll();
    }
    function detach(): void { root.setDetached(true); }
    function attach(): void { root.setDetached(false); }
    // Alarms: list includes the computed next occurrence, for scripting and
    // for the panel to show "next at".
    function alarmList(): string {
      var out = [];
      for (var i = 0; i < root.alarms.length; i++) {
        var a = root.alarms[i];
        out.push({
          id: a.id, name: a.name, hour: a.hour, minute: a.minute, days: a.days,
          sound: a.sound, enabled: a.enabled, repeat: Logic.alarmRepeatLabel(a.days),
          nextAt: (root.alarmNextMap[a.id] && root.alarmNextMap[a.id].at) || 0
        });
      }
      return JSON.stringify({ now: Date.now(), sync: root.runDirSafe, alarms: out });
    }
    function alarmAdd(json: string): string {
      var o = null;
      try { o = JSON.parse(String(json || "")); } catch (e) { return ""; }
      return root.addAlarm(o);
    }
    function alarmRemove(id: string): void { root.removeAlarm(id); }
    function alarmEnable(id: string, on: string): void {
      var v = String(on || "").toLowerCase();
      root.setAlarmEnabled(id, v === "true" || v === "1" || v === "on");
    }
    function alarmCheck(): void { root.checkAlarms(); }
    function status(): string {
      return JSON.stringify({ state: root.tState, mode: root.mode, phase: root.phase, done: root.pomoDone, cycles: root.pomodoro.cyclesBeforeLong, owner: root.pomoOwner, remaining: root.remainingSec, total: root.totalSec, detached: root.detached, detachedScreen: root.detachedScreen, screenName: root.screenName, monitors: root.monitorMap.length, presets: root.presets.length, alarms: root.alarms.length, opened: root.opened, sync: root.runDirSafe, pomodoro: root.pomodoro });
    }
    // Logical monitor layout (same units the floating window uses).
    function screens(): string {
      root.refreshMonitors();
      return JSON.stringify(root.monitorMap);
    }
    // Moves the floating card to the neighboring monitor (scripting/debug).
    function hop(dir: string): string {
      if (!root.detached) return "not-detached";
      var cur = root.rectFor(root.detachedScreen);
      var cx = cur ? cur.x + cur.w / 2 : 0;
      var cy = cur ? cur.y + cur.h / 2 : 0;
      return root.hopFloating(String(dir), cx, cy) ? "ok" : "no-neighbor";
    }
  }

  // ---- pill in the bar (glass accent + green heartbeat) ------------------
  // The topbar accent is `bar.urgent` (= Color.bar.active).
  readonly property color accent: root.bar ? root.bar.urgent : Color.accent
  // Phase colors are deliberately NOT always the theme accent: a blue, cyan
  // or white accent would make focus and break indistinguishable.
  //   Original: fixed amber focus, fixed calm-blue break (custom look).
  //   Omarchy:  theme-accent focus, the SAME fixed calm-blue break.
  readonly property color focusAmber: Qt.rgba(0.957, 0.706, 0.0, 1)
  readonly property color calmBlue: Qt.rgba(0.114, 0.608, 0.941, 1)
  readonly property color phaseAccent: {
    if (root.mode === "pomodoro") {
      if (root.phase !== "focus") return root.calmBlue;
      return root.omarchyTheme ? Color.accent : root.focusAmber;
    }
    return root.omarchyTheme ? root.accent : root.focusAmber;
  }
  readonly property string phaseLabel: {
    if (root.mode !== "pomodoro") return "TIMER";
    if (root.phase === "long") return "LONG";
    return root.phase === "focus" ? "FOCUS" : "BREAK";
  }
  // Long form for the floating card and tooltips (room to spare there);
  // the pill keeps the short label so its width stays stable.
  readonly property string phaseLongLabel: {
    if (root.mode !== "pomodoro") return "TIMER";
    if (root.phase === "long") return "LONG BREAK";
    return root.phaseLabel;
  }
  readonly property string pomoProgress: {
    var cycles = root.pomodoro.cyclesBeforeLong;
    var current = root.phase === "focus" ? Math.min(cycles, root.pomoDone + 1) : root.pomoDone;
    return current + "/" + cycles;
  }
  function contrastOn(c) {
    var lum = 0.299 * c.r + 0.587 * c.g + 0.114 * c.b;
    return lum > 0.55 ? Qt.rgba(0, 0, 0, 0.92) : Qt.rgba(1, 1, 1, 0.96);
  }
  // Alert phase: last 5 running seconds -> heartbeat every second.
  readonly property bool urgentPhase: root.tState === "running" && root.remainingSec <= 5 && root.remainingSec > 0
  property int beat: 0
  property int _lastBeatSec: -1
  onRemainingSecChanged: {
    if (root.urgentPhase && root.remainingSec !== root._lastBeatSec) {
      root._lastBeatSec = root.remainingSec;
      root.beat++;
    }
  }
  onBeatChanged: {
    greenPulse.restart();
    pillThump.restart();
  }
  readonly property color topbarBg: root.bar ? root.bar.background : Color.background
  readonly property color topbarFg: root.bar ? root.bar.foreground : Color.foreground
  // Accent fill ONLY while the timer is active (running). Idle/paused use
  // the topbar background (slightly darker on light themes) and no border;
  // Omarchy mode drops the glass entirely, like a native bar widget.
  // Pomodoro phases in Original mode use the SOLID accent: at 0.55 alpha
  // over the dark bar the amber read as #8a6706 instead of #f4b400.
  readonly property color pillBg: {
    if (root.tState === "finished") return Util.alpha(root.bar ? root.bar.urgent : Color.urgent, 0.62);
    if (root.urgentPhase) return Qt.rgba(0.10, 0.45, 0.24, 0.78);
    if (root.tState === "running") {
      // Solid in Original for every function: at 0.55 alpha the amber/blue
      // read as muddy (#8a6706 / #14598a) against the dark bar.
      if (!root.omarchyTheme) return root.phaseAccent;
      return Util.alpha(root.phaseAccent, 0.55);
    }
    if (root.omarchyTheme) return "transparent";
    if (root.lightTheme) return root.shade(root.topbarBg, 0.10);
    return root.topbarBg;
  }
  // Darkens a color while keeping its alpha (light-theme scrim).
  function shade(c, amount) {
    var k = 1 - Math.max(0, Math.min(1, Number(amount) || 0));
    return Qt.rgba(c.r * k, c.g * k, c.b * k, c.a === undefined ? 1 : c.a);
  }
  readonly property string face: root.bar && root.bar.fontFamily ? root.bar.fontFamily : Style.font.family

  readonly property string pillText: {
    if (root.tState === "finished") return root.phaseLabel + " 00:00";
    if (root.tState === "idle") return "LOOPER";
    return root.phaseLabel + " " + Logic.fmt(root.remainingSec);
  }

  readonly property color pillFg: {
    if (root.tState === "finished") return root.contrastOn(root.bar ? root.bar.urgent : Color.urgent);
    if (root.urgentPhase) return Qt.rgba(1, 1, 1, 0.96);
    if (root.tState === "running") return root.contrastOn(root.phaseAccent);
    return root.topbarFg;
  }

  implicitWidth: pill.implicitWidth
  implicitHeight: pill.implicitHeight

  Item {
    id: pill
    anchors.fill: parent
    implicitWidth: pillContent.implicitWidth + (cycleDots.visible ? 12 : 4)
    implicitHeight: barSize
    transformOrigin: Item.Center

    SequentialAnimation {
      id: pillThump
      NumberAnimation { target: pill; property: "scale"; to: 1.08; duration: 120; easing.type: Easing.OutQuad }
      NumberAnimation { target: pill; property: "scale"; to: 1.0; duration: 240; easing.type: Easing.InOutQuad }
    }

    Rectangle {
      id: glass
      anchors.centerIn: parent
      width: parent.width - 4
      height: Math.min(parent.height - 6, Style.space(24))
      radius: height / 2
      color: root.pillBg
      border.width: 0
      border.color: "transparent"

      // Green heartbeat: one flash per second in the last 5 s.
      Rectangle {
        id: greenFlash
        anchors.fill: parent
        radius: height / 2
        color: Qt.rgba(0.29, 0.87, 0.5, 1)
        opacity: 0
        visible: root.urgentPhase
      }

      SequentialAnimation {
        id: greenPulse
        NumberAnimation { target: greenFlash; property: "opacity"; to: 0.55; duration: 130; easing.type: Easing.OutQuad }
        NumberAnimation { target: greenFlash; property: "opacity"; to: 0.0; duration: 480; easing.type: Easing.InOutQuad }
      }

      // Red pulse on finish.
      Rectangle {
        id: finishedFlash
        anchors.fill: parent
        radius: height / 2
        color: "transparent"
        border.width: 2
        border.color: (root.bar ? root.bar.urgent : Color.urgent)
        opacity: 0
        visible: root.tState === "finished"
      }

      SequentialAnimation {
        id: finishedPulse
        running: root.tState === "finished"
        loops: Animation.Infinite
        NumberAnimation { target: finishedFlash; property: "opacity"; to: 1; duration: 550; easing.type: Easing.InOutQuad }
        NumberAnimation { target: finishedFlash; property: "opacity"; to: 0.25; duration: 550; easing.type: Easing.InOutQuad }
      }
    }

    Row {
      id: pillContent
      anchors.centerIn: parent
      spacing: 7

      WidgetButton {
        id: pillButton
        bar: root.bar
        text: root.pillText
        fontFamily: root.face
        fontSize: Style.font.body
        foreground: root.pillFg
        active: false
        useActiveColor: false
        tooltipText: {
          var what = root.mode === "pomodoro" ? ("Pomodoro " + root.phaseLongLabel.toLowerCase() + " " + root.pomoProgress) : "Timer";
          if (root.tState === "running") return what + " running — click to open, wheel ±1 min";
          if (root.tState === "paused") return what + " paused — click to resume";
          if (root.tState === "finished") return "Time's up! Click to dismiss";
          return "Looper — click to open";
        }
        onPressed: function(btn) {
          if (root.tState === "finished") { root.dismiss(); return; }
          if (btn === Qt.MiddleButton) root.togglePause();
          else root.togglePanel();
        }
        onWheelMoved: function(delta) {
          var steps = delta > 0 ? 1 : -1;
          if (root.tState === "idle") root.stageSeconds(root.stagedSec + steps * 300);
          else root.nudge(steps * 60);
        }
      }

      // Cycle dots: filled = completed focus blocks, outlined = the current
      // one, faint = upcoming. Only while a pomodoro session exists, so the
      // plain timer pill keeps exactly its previous width. The trailing gap
      // mirrors the button's inner margin so the dots sit optically centered
      // instead of hugging the right edge.
      Row {
        id: cycleDots
        visible: root.mode === "pomodoro" && root.tState !== "idle"
        width: visible ? implicitWidth : 0
        anchors.verticalCenter: parent.verticalCenter
        spacing: 3
        Repeater {
          model: cycleDots.visible ? root.pomodoro.cyclesBeforeLong : 0
          Rectangle {
            required property int index
            readonly property bool filled: index < root.pomoDone
            readonly property bool current: index === root.pomoDone && root.phase === "focus"
            width: 4
            height: 4
            radius: 2
            anchors.verticalCenter: parent.verticalCenter
            color: filled ? root.pillFg : "transparent"
            border.width: filled ? 0 : 1
            border.color: Util.alpha(root.pillFg, current ? 0.9 : 0.3)
          }
        }
        Item { width: cycleDots.visible ? pillButton.scaledHorizontalMargin : 0; height: 1 }
      }
    }
  }

  // Always-visible floating window (overlay layer).
  Floating {
    id: floatingWin
    host: root
  }

  Component.onCompleted: {
    root.detached = root.setting("detached", false) === true;
    root.updateScreenName();
    root.refreshMonitors();
    // After a restart, the floating window returns to its screen if still active.
    if (root.detached && root.detachedScreen === "") root.detachedScreen = root.screenName;
    // The PillButton path may not be ready yet; retry one beat later.
    Qt.callLater(root.updateScreenName);
    mkdirProc.running = true;
    root.refreshAlarmSchedule();
  }
}
