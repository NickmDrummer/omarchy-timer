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

  // ---- presets (editable, persisted in JSON) ----------------------------
  property var presets: Logic.defaultPresets()
  property bool presetsReady: false

  function loadPresets(text) {
    var parsed = null;
    try { parsed = JSON.parse(String(text || "")); } catch (e) { parsed = null; }
    if (parsed) root.presets = Logic.cleanPresets(parsed);
    else root.presets = Logic.defaultPresets();
    root.presetsReady = true;
  }

  function savePresets() {
    if (!root.presetsReady) return;
    presetsSave.restart();
  }

  function addPreset(label, minutes) {
    var m = Logic.clampMinutes(minutes);
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
      var payload = JSON.stringify({ version: 1, presets: root.presets }, null, 2) + "\n";
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
    if (st === "idle") root.stagedSec = Logic.clampSeconds(o.staged !== undefined ? o.staged : total);
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

  function startStaged() { root.startSeconds(root.stagedSec); }

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
      root.stagedSec = Logic.clampSeconds(root.stagedSec + d);
      root.remainingSec = root.stagedSec;
      root.totalSec = root.stagedSec;
    }
    root.writeState();
  }

  function stageSeconds(sec) {
    if (root.tState === "running" || root.tState === "paused") return;
    root.stagedSec = Logic.clampSeconds(sec);
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
    root.tState = "finished";
    root.remainingSec = 0;
    root.endAt = 0;
    root.writeState();
    // The pill returns to its inactive background when the notification
    // expires (~15 s): red does not stay stuck until the click.
    finishCalm.restart();
    // The alarm self-dedups across monitors with flock inside the script.
    if (root.soundOn) alarmProc.running = true;
    else notifyProc.running = true;
    if (root.bar && root.bar.shell && typeof root.bar.shell.summon === "function") {
      // Do not force opening: only pulse in the bar + floating window.
    }
  }

  Process {
    id: alarmProc
    command: ["bash", root.alarmScript]
  }

  Process {
    id: notifyProc
    // Goes through the script to reuse its flock: a single notification
    // even with one bar per monitor.
    command: ["bash", root.alarmScript, "--silent"]
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
    function start(minutes: string): void { root.startSeconds(Number(minutes) * 60 || 600); }
    function stop(): void { root.resetAll(); }
    function detach(): void { root.setDetached(true); }
    function attach(): void { root.setDetached(false); }
    function status(): string {
      return JSON.stringify({ state: root.tState, remaining: root.remainingSec, total: root.totalSec, detached: root.detached, detachedScreen: root.detachedScreen, screenName: root.screenName, monitors: root.monitorMap.length, presets: root.presets.length, opened: root.opened, sync: root.runDirSafe });
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
  readonly property color pillBg: {
    if (root.tState === "finished") return Util.alpha(root.bar ? root.bar.urgent : Color.urgent, 0.62);
    if (root.urgentPhase) return Qt.rgba(0.10, 0.45, 0.24, 0.78);
    if (root.tState === "running") return Util.alpha(root.accent, 0.55);
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
    if (root.tState === "finished") return "TIMER 00:00";
    if (root.tState === "idle") return "TIMER " + Logic.fmt(root.stagedSec);
    return "TIMER " + Logic.fmt(root.remainingSec);
  }

  readonly property color pillFg: {
    if (root.tState === "finished") return root.contrastOn(root.bar ? root.bar.urgent : Color.urgent);
    if (root.urgentPhase) return Qt.rgba(1, 1, 1, 0.96);
    if (root.tState === "running") return root.contrastOn(root.accent);
    return root.topbarFg;
  }

  implicitWidth: pill.implicitWidth
  implicitHeight: pill.implicitHeight

  Item {
    id: pill
    anchors.fill: parent
    implicitWidth: pillButton.implicitWidth + 4
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

    WidgetButton {
      id: pillButton
      anchors.centerIn: parent
      bar: root.bar
      text: root.pillText
      fontFamily: root.face
      fontSize: Style.font.body
      foreground: root.pillFg
      active: false
      useActiveColor: false
      tooltipText: {
        if (root.tState === "running") return "Timer running — click to open, wheel ±1 min";
        if (root.tState === "paused") return "Timer paused — click to resume";
        if (root.tState === "finished") return "Time's up! Click to dismiss";
        return "Timer — click to configure";
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
  }
}
