pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "TimerLogic.js" as Logic

// Timer configuration Panel: presets, manual picker, +5/-5,
// preset editor (persisted in JSON) and floating mode.
Panel {
  id: root
  moduleName: "nickmdrummer.timer"
  ipcTarget: ""
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property bool omarchyTheme: hostWidget ? hostWidget.omarchyTheme === true : false
  readonly property bool pomodoroMode: hostWidget ? hostWidget.mode === "pomodoro" : false
  // Panel tab (UI only): alarms are a schedule, not a running mode.
  property string panelTab: "timer"
  readonly property bool alarmsMode: root.panelTab === "alarms"
  readonly property var tabModel: [
    { key: "timer", label: "TIMER" },
    { key: "pomodoro", label: "POMODORO" },
    { key: "alarms", label: "ALARMS" }
  ]
  readonly property bool lightTheme: hostWidget ? hostWidget.lightTheme === true : false
  // Original mode has its own palette (white ink over dark glass) so it keeps
  // the same identity on light themes; Omarchy mode follows theme tokens.
  readonly property color fg: root.omarchyTheme ? Color.popups.text : Qt.rgba(1, 1, 1, 0.92)
  readonly property string face: bar && bar.fontFamily ? bar.fontFamily : Style.font.family
  // A bit denser on light themes so the white ink keeps its contrast.
  readonly property color glassBlack: Qt.rgba(0, 0, 0, (!root.omarchyTheme && root.lightTheme) ? 0.52 : 0.42)
  function ink(a) { return Util.alpha(root.fg, a); }

  property bool editing: false
  property string newLabel: ""
  property int newMinutes: 25
  property string editId: ""
  property string editLabel: ""
  property int editMinutes: 10

  // Manual picker (seconds). Synced on open.
  property int pickSec: 600

  // ---- alarm editor state -----------------------------------------------
  property bool alarmEditing: false
  property string alarmEditId: ""
  property string alarmName: ""
  property int alarmHour: 8
  property int alarmMinute: 0
  property var alarmDays: [1, 2, 3, 4, 5]
  property bool alarmSound: true
  property bool alarmEveryDay: false

  function pad2(n) { return (Number(n) < 10 ? "0" : "") + Number(n); }

  function openAlarmEditor(alarm) {
    root.alarmEditing = true;
    if (alarm) {
      root.alarmEditId = String(alarm.id);
      root.alarmName = String(alarm.name || "");
      root.alarmHour = Number(alarm.hour) || 0;
      root.alarmMinute = Number(alarm.minute) || 0;
      root.alarmDays = Logic.toList(alarm.days);
      root.alarmSound = alarm.sound !== false;
    } else {
      var now = new Date();
      root.alarmEditId = "";
      root.alarmName = "";
      root.alarmHour = (now.getHours() + 1) % 24;
      root.alarmMinute = 0;
      root.alarmDays = [1, 2, 3, 4, 5];
      root.alarmSound = true;
    }
    root.alarmEveryDay = root.alarmDays.length === 7;
  }

  function closeAlarmEditor() {
    root.alarmEditing = false;
    root.alarmEditId = "";
  }

  function toggleAlarmDay(d) {
    if (root.alarmEveryDay) return;
    var list = Logic.toList(root.alarmDays);
    var i = list.indexOf(d);
    if (i >= 0) list.splice(i, 1);
    else list.push(d);
    list.sort(function(a, b) { return a - b; });
    if (list.length === 0) list = [d];
    root.alarmDays = list;
  }

  function setEveryDay(on) {
    root.alarmEveryDay = on === true;
    // Turning it off keeps the seven days selected otherwise, which makes the
    // row keep reading "Every day" no matter what the user picks.
    if (root.alarmEveryDay) root.alarmDays = [0, 1, 2, 3, 4, 5, 6];
    else root.alarmDays = [1, 2, 3, 4, 5];
  }

  function saveAlarm() {
    if (!hostWidget) return;
    var days = root.alarmEveryDay ? [0, 1, 2, 3, 4, 5, 6] : root.alarmDays;
    var payload = {
      name: root.alarmName,
      hour: root.alarmHour,
      minute: root.alarmMinute,
      days: days,
      sound: root.alarmSound
    };
    if (root.alarmEditId !== "") hostWidget.updateAlarm(root.alarmEditId, payload);
    else hostWidget.addAlarm(payload);
    root.closeAlarmEditor();
  }

  function deleteAlarm() {
    if (hostWidget && root.alarmEditId !== "") hostWidget.removeAlarm(root.alarmEditId);
    root.closeAlarmEditor();
  }

  function open() {
    root.pickSec = hostWidget ? hostWidget.stagedSec : 600;
    root.editing = false;
    root.editId = "";
    root.panelTab = (hostWidget && hostWidget.mode === "pomodoro") ? "pomodoro" : "timer";
    root.controller.show();
    Qt.callLater(function() { keyCatcher.forceActiveFocus(); });
  }
  function close() { root.controller.hide(); }
  function toggle() { root.opened ? root.close() : root.open(); }
  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction);
    return false;
  }

  function fmt(sec) { return Logic.fmt(sec); }

  readonly property string bigTime: {
    if (!hostWidget) return "--:--";
    if (hostWidget.tState === "finished") return "00:00";
    if (hostWidget.tState === "idle") return Logic.fmt(hostWidget.stagedSec);
    return Logic.fmt(hostWidget.remainingSec);
  }

  readonly property string stateLabel: {
    if (!hostWidget) return "";
    if (root.pomodoroMode) {
      var what = hostWidget.phase === "focus" ? ("Focus " + hostWidget.pomoProgress) : (hostWidget.phase === "long" ? "Long break" : "Short break");
      if (hostWidget.tState === "running") return what + " · running";
      if (hostWidget.tState === "paused") return what + " · paused";
      if (hostWidget.pomoDone >= hostWidget.pomodoro.cyclesBeforeLong) return "Set complete · Start begins a new set";
      return "Ready · focus " + Logic.fmtLong(hostWidget.pomodoro.focusSec) + ", long break every " + hostWidget.pomodoro.cyclesBeforeLong;
    }
    if (hostWidget.tState === "running") return "Running · ends in " + Logic.fmtLong(hostWidget.remainingSec);
    if (hostWidget.tState === "paused") return "Paused · " + Logic.fmtLong(hostWidget.remainingSec) + " left";
    if (hostWidget.tState === "finished") return "Time's up!";
    return "Ready · pick a duration";
  }

  readonly property real progress: {
    if (!hostWidget || hostWidget.totalSec <= 0) return 0;
    if (hostWidget.tState === "idle") return 0;
    if (hostWidget.tState === "finished") return 1;
    return Math.max(0, Math.min(1, 1 - (hostWidget.remainingSec / hostWidget.totalSec)));
  }

  function applyPick() {
    if (hostWidget) hostWidget.stageSeconds(root.pickSec);
  }

  function bumpPick(delta) {
    root.pickSec = Logic.clampSeconds(root.pickSec + delta);
    applyPick();
  }

  // Persists a bar widget setting through the host (same path the shell uses).
  function setSetting(key, value) {
    if (!hostWidget) return;
    hostWidget.setSetting(key, value);
  }

  TimerPopup {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    cardRadius: 20
    cardColor: root.omarchyTheme ? Color.popups.background : root.glassBlack
    frameSpec: root.omarchyTheme
      ? Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(1)))
      : Border.none()
    contentWidth: panel.fittedContentWidth(Style.space(344))
    contentHeight: panel.fittedContentHeight(body.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: newLabelInput.activeFocus || editLabelInput.activeFocus
      onCloseRequested: root.close()
      onActivateRequested: if (hostWidget) hostWidget.togglePause()
      onTabRequested: function(dir) { root.switchPanel(dir); }
      onTextKey: function(t) {
        if (!hostWidget) return;
        if (t === " ") hostWidget.togglePause();
        else if (t === "+") hostWidget.nudge(300);
        else if (t === "-") hostWidget.nudge(-300);
        else if (t === "r" || t === "R") hostWidget.resetAll();
        else if ((t === "s" || t === "S") && root.pomodoroMode) hostWidget.skipPhase();
        else if (t === "f" || t === "F") hostWidget.setDetached(!hostWidget.detached);
      }

      Column {
        id: body
        width: parent.width
        spacing: Style.space(12)

        // ---- header + mode tabs ------------------------------------
        Row {
          width: parent.width
          height: Style.space(26)
          Row {
            id: modeTabs
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(4)
            Repeater {
              model: root.tabModel
              Rectangle {
                required property var modelData
                readonly property bool activeTab: root.panelTab === modelData.key
                width: tabLabel.implicitWidth + 20
                height: Style.space(26)
                radius: height / 2
                color: activeTab ? root.ink(0.16) : "transparent"
                border.width: activeTab ? 1 : 0
                border.color: root.ink(0.18)
                Text {
                  id: tabLabel
                  anchors.centerIn: parent
                  text: modelData.label
                  color: activeTab ? root.fg : Util.alpha(root.fg, 0.5)
                  font.family: root.face
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  font.letterSpacing: 1.4
                }
                HoverHandler { cursorShape: Qt.PointingHandCursor }
                TapHandler {
                  acceptedButtons: Qt.LeftButton
                  onTapped: {
                    if (!hostWidget) return;
                    root.editing = false;
                    root.editId = "";
                    root.closeAlarmEditor();
                    root.panelTab = modelData.key;
                    if (modelData.key !== "alarms") hostWidget.setMode(modelData.key);
                  }
                }
              }
            }
          }
          Item { width: parent.width - modeTabs.width - headerBtns.width; height: 1 }
          Row {
            id: headerBtns
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(4)
            PanelActionButton {
              iconText: hostWidget && hostWidget.detached ? "↩" : "↗"
              tooltipText: hostWidget && hostWidget.detached ? "Back to the bar" : "Floating always on top (F)"
              foreground: root.fg
              fontFamily: root.face
              onClicked: if (hostWidget) hostWidget.setDetached(!hostWidget.detached)
            }
            PanelActionButton {
              iconText: "✕"
              tooltipText: "Close (Esc)"
              foreground: root.fg
              fontFamily: root.face
              onClicked: root.close()
            }
          }
        }

        // ---- big time + progress + heartbeat ---------------------------
        Rectangle {
          id: timeCard
          visible: !root.alarmsMode
          width: parent.width
          height: 118
          radius: 16
          color: root.omarchyTheme ? root.ink(0.05) : root.glassBlack
          border.width: 0
          border.color: "transparent"

          // Green heartbeat flash (last 5 s).
          Rectangle {
            id: beatFlash
            anchors.fill: parent
            radius: 16
            color: Qt.rgba(0.29, 0.87, 0.5, 1)
            opacity: 0
          }
          SequentialAnimation {
            id: beatAnim
            NumberAnimation { target: beatFlash; property: "opacity"; to: 0.35; duration: 130; easing.type: Easing.OutQuad }
            NumberAnimation { target: beatFlash; property: "opacity"; to: 0.0; duration: 480; easing.type: Easing.InOutQuad }
          }

          Connections {
            target: root.hostWidget
            function onBeatChanged() {
              if (root.hostWidget && root.hostWidget.urgentPhase) {
                beatAnim.restart();
                timeThump.restart();
              }
            }
            function onModeChanged() {
              if (!root.hostWidget) return;
              root.pickSec = root.hostWidget.stagedSec;
              root.editing = false;
              root.editId = "";
            }
            // setMode() switches the mode before restoring the staged value,
            // so follow the staged duration itself too.
            function onStagedSecChanged() {
              if (!root.hostWidget) return;
              if (root.hostWidget.tState === "idle") root.pickSec = root.hostWidget.stagedSec;
            }
          }

          Column {
            anchors.centerIn: parent
            spacing: 6
            Text {
              id: bigTimeText
              anchors.horizontalCenter: parent.horizontalCenter
              transformOrigin: Item.Center
              text: root.bigTime
              color: !hostWidget ? root.fg
                : hostWidget.tState === "finished" ? (bar ? bar.urgent : Color.urgent)
                : hostWidget.urgentPhase ? Qt.rgba(0.29, 0.87, 0.5, 1) : root.fg
              font.family: root.face
              font.pixelSize: 44
              font.bold: true
            }
            SequentialAnimation {
              id: timeThump
              NumberAnimation { target: bigTimeText; property: "scale"; to: 1.06; duration: 120; easing.type: Easing.OutQuad }
              NumberAnimation { target: bigTimeText; property: "scale"; to: 1.0; duration: 240; easing.type: Easing.InOutQuad }
            }
            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              text: root.stateLabel
              color: Util.alpha(root.fg, 0.66)
              font.family: root.face
              font.pixelSize: Style.font.bodySmall
            }
          }

          // Thin progress bar at the bottom.
          Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.leftMargin: 14
            anchors.rightMargin: 14
            anchors.bottomMargin: 10
            height: 4
            radius: 2
            color: root.ink(0.12)
            Rectangle {
              anchors.left: parent.left
              anchors.top: parent.top
              anchors.bottom: parent.bottom
              width: parent.width * root.progress
              radius: 2
              color: (hostWidget && hostWidget.urgentPhase)
                ? Qt.rgba(0.29, 0.87, 0.5, 0.9)
                : root.pomodoroMode ? Util.alpha(hostWidget.phaseAccent, 0.85) : root.ink(0.75)
            }
          }
        }

        // ---- transport ----------------------------------------------
        // Exact widths: 2 large + 2 small of 46 + 3 gaps of 8 = width.
        Row {
          visible: !root.alarmsMode
          width: parent.width
          spacing: Style.space(8)

          TimerButton {
            width: (parent.width - Style.space(8) * 3 - 92) / 2
            primary: true
            label: !hostWidget || hostWidget.tState === "idle" ? "▶\uFE0E  Start"
              : hostWidget.tState === "running" ? "❚❚\uFE0E  Pause"
              : hostWidget.tState === "paused" ? "▶\uFE0E  Resume" : "▶\uFE0E  Done"
            tip: "Space"
            fg: root.fg
            face: root.face
            onFired: {
              if (!hostWidget) return;
              if (hostWidget.tState === "idle") hostWidget.startStaged();
              else hostWidget.togglePause();
            }
          }
          TimerButton {
            width: (parent.width - Style.space(8) * 3 - 92) / 2
            label: "⟲  Reset"
            tip: "R"
            fg: root.fg
            face: root.face
            onFired: if (hostWidget) hostWidget.resetAll()
          }
          TimerButton {
            width: 46
            label: "+5"
            tip: "+5 min while running"
            fg: root.fg
            face: root.face
            onFired: {
              if (!hostWidget) return;
              if (hostWidget.tState === "idle") root.bumpPick(300);
              else hostWidget.nudge(300);
            }
          }
          TimerButton {
            width: 46
            label: "−5"
            tip: "−5 min while running"
            fg: root.fg
            face: root.face
            onFired: {
              if (!hostWidget) return;
              if (hostWidget.tState === "idle") root.bumpPick(-300);
              else hostWidget.nudge(-300);
            }
          }
        }

        PanelSeparator { foreground: root.fg }

        // Timer mode: presets + manual tune. Switching modes swaps this
        // block for the pomodoro settings with a short fade + slide.
        Column {
          id: timerView
          width: parent.width
          spacing: Style.space(12)
          visible: root.panelTab === "timer"
          opacity: visible ? 1 : 0
          x: visible ? 0 : -6
          Behavior on opacity { NumberAnimation { duration: 120; easing.type: Easing.OutQuad } }
          Behavior on x { NumberAnimation { duration: 120; easing.type: Easing.OutQuad } }

          // ---- presets ---------------------------------------------------
          Row {
            width: parent.width
            height: Style.space(22)
            Text {
              width: parent.width - editToggle.width
              anchors.verticalCenter: parent.verticalCenter
              text: "PRESETS"
              color: Util.alpha(root.fg, 0.6)
              font.family: root.face
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.4
            }
            PanelActionButton {
              id: editToggle
              anchors.verticalCenter: parent.verticalCenter
              iconText: root.editing ? "✓" : "✎"
              tooltipText: root.editing ? "Done editing" : "Edit presets"
              foreground: root.fg
              fontFamily: root.face
              onClicked: { root.editing = !root.editing; root.editId = ""; }
            }
          }

          Flow {
            width: parent.width
            spacing: Style.space(8)
            Repeater {
              model: hostWidget ? hostWidget.presets : []
              delegate: Rectangle {
                id: chip
                required property var modelData
                required property int index
                width: chipLabel.implicitWidth + 28
                height: Style.space(34)
                radius: 17
                color: chipHover.hovered ? root.ink(0.16)
                  : (root.omarchyTheme ? root.ink(0.05) : Qt.rgba(0, 0, 0, 0.5))
                border.width: 1
                border.color: root.ink(0.14)

                Row {
                  id: chipRow
                  anchors.centerIn: parent
                  spacing: 6
                  Text {
                    id: chipLabel
                    anchors.verticalCenter: parent.verticalCenter
                    text: chip.modelData.label
                    color: root.fg
                    font.family: root.face
                    font.pixelSize: Style.font.body
                    font.bold: true
                  }
                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: root.editing
                    text: "✕"
                    color: Util.alpha(root.fg, 0.6)
                    font.family: root.face
                    font.pixelSize: Style.font.bodySmall
                  }
                }

                HoverHandler { id: chipHover; cursorShape: Qt.PointingHandCursor }
                TapHandler {
                  acceptedButtons: Qt.LeftButton
                  onTapped: {
                    if (!hostWidget) return;
                    if (root.editing) {
                      root.editId = chip.modelData.id;
                      root.editLabel = chip.modelData.label;
                      root.editMinutes = chip.modelData.minutes;
                    } else {
                      hostWidget.startSeconds(Number(chip.modelData.minutes) * 60);
                    }
                  }
                }
                PanelToolTip {
                  visible: chipHover.hovered
                  text: root.editing ? "Edit preset" : "Start " + chip.modelData.minutes + " min"
                }
              }
            }
          }

          // Selected preset editor.
          Column {
            width: parent.width
            spacing: Style.space(8)
            visible: root.editing && root.editId !== ""

            Row {
              width: parent.width
              spacing: Style.space(8)
              Rectangle {
                width: (parent.width - Style.space(8)) / 2
                height: Style.space(32)
                radius: Style.cornerRadius
                color: root.ink(0.06)
                border.width: 1
                border.color: root.ink(editLabelInput.activeFocus ? 0.35 : 0.14)
                TextInput {
                  id: editLabelInput
                  anchors.fill: parent
                  anchors.leftMargin: 10
                  anchors.rightMargin: 10
                  verticalAlignment: TextInput.AlignVCenter
                  text: root.editLabel
                  maximumLength: 12
                  color: root.fg
                  font.family: root.face
                  font.pixelSize: Style.font.body
                  selectByMouse: true
                  onTextEdited: root.editLabel = text
                }
              }
              Stepper {
                width: (parent.width - Style.space(8)) / 2
                value: root.editMinutes
                min: 1
                max: 720
                suffix: " min"
                fg: root.fg
                face: root.face
                onChanged: function(v) { root.editMinutes = v; }
              }
            }
            Row {
              width: parent.width
              spacing: Style.space(8)
              TimerButton {
                width: (parent.width - Style.space(16)) / 3
                label: "Save"
                primary: true
                fg: root.fg
                face: root.face
                onFired: {
                  if (hostWidget) hostWidget.renamePreset(root.editId, root.editLabel, root.editMinutes);
                  root.editId = "";
                }
              }
              TimerButton {
                width: (parent.width - Style.space(16)) / 3
                label: "Delete"
                danger: true
                fg: root.fg
                face: root.face
                onFired: {
                  if (hostWidget) hostWidget.removePreset(root.editId);
                  root.editId = "";
                }
              }
              TimerButton {
                width: (parent.width - Style.space(16)) / 3
                label: "Close"
                fg: root.fg
                face: root.face
                onFired: root.editId = ""
              }
            }
          }

          // New preset.
          Column {
            width: parent.width
            spacing: Style.space(8)
            visible: root.editing
            Text {
              width: parent.width
              text: root.editId !== "" ? "EDIT PRESET" : "NEW PRESET"
              color: Util.alpha(root.fg, 0.55)
              font.family: root.face
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
            }
            Row {
              width: parent.width
              spacing: Style.space(8)
              Rectangle {
                width: parent.width - Style.space(8) - addMin.width - addBtn.width
                height: Style.space(32)
                radius: Style.cornerRadius
                color: root.ink(0.06)
                border.width: 1
                border.color: root.ink(newLabelInput.activeFocus ? 0.35 : 0.14)
                TextInput {
                  id: newLabelInput
                  anchors.fill: parent
                  anchors.leftMargin: 10
                  anchors.rightMargin: 10
                  verticalAlignment: TextInput.AlignVCenter
                  text: root.newLabel
                  maximumLength: 12
                  color: root.fg
                  font.family: root.face
                  font.pixelSize: Style.font.body
                  selectByMouse: true
                  onTextEdited: root.newLabel = text
                }
                Text {
                  anchors.fill: parent
                  anchors.leftMargin: 10
                  verticalAlignment: Text.AlignVCenter
                  visible: root.newLabel === "" && !newLabelInput.activeFocus
                  text: "Name…"
                  color: Util.alpha(root.fg, 0.4)
                  font.family: root.face
                  font.pixelSize: Style.font.body
                }
              }
              Stepper {
                id: addMin
                width: 118
                value: root.newMinutes
                min: 1
                max: 720
                suffix: " ′"
                fg: root.fg
                face: root.face
                onChanged: function(v) { root.newMinutes = v; }
              }
              TimerButton {
                id: addBtn
                width: Style.space(52)
                label: "＋"
                primary: true
                fg: root.fg
                face: root.face
                onFired: {
                  if (hostWidget) hostWidget.addPreset(root.newLabel || String(root.newMinutes), root.newMinutes);
                  root.newLabel = "";
                }
              }
            }
            Text {
              width: parent.width
              text: "Stored in ~/.config/nickmdrummer-timer/presets.json  ·  <a href=\"reset\">reset</a>"
              textFormat: Text.RichText
              wrapMode: Text.WordWrap
              color: Util.alpha(root.fg, 0.5)
              font.family: root.face
              font.pixelSize: Style.font.caption
              linkColor: root.fg
              onLinkActivated: if (hostWidget) hostWidget.resetPresets()
            }
          }

          PanelSeparator { foreground: root.fg }

          // ---- manual tune ---------------------------------------------
          Text {
            width: parent.width
            text: "MANUAL TUNE"
            color: Util.alpha(root.fg, 0.6)
            font.family: root.face
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 1.4
          }

          Row {
            width: parent.width
            spacing: Style.space(8)
            Stepper {
              title: "HRS"
              width: (parent.width - Style.space(16)) / 3
              value: Math.floor(root.pickSec / 3600)
              min: 0
              max: 12
              fg: root.fg
              face: root.face
              onChanged: function(v) {
                root.pickSec = Logic.clampSeconds(v * 3600 + (root.pickSec % 3600));
                applyPick();
              }
            }
            Stepper {
              title: "MIN"
              width: (parent.width - Style.space(16)) / 3
              value: Math.floor((root.pickSec % 3600) / 60)
              min: 0
              max: 59
              fg: root.fg
              face: root.face
              onChanged: function(v) {
                var h = Math.floor(root.pickSec / 3600);
                root.pickSec = Logic.clampSeconds(h * 3600 + v * 60 + (root.pickSec % 60));
                applyPick();
              }
            }
            Stepper {
              title: "SEC"
              width: (parent.width - Style.space(16)) / 3
              value: root.pickSec % 60
              min: 0
              max: 59
              step: 5
              fg: root.fg
              face: root.face
              onChanged: function(v) {
                var h = Math.floor(root.pickSec / 3600);
                var m = Math.floor((root.pickSec % 3600) / 60);
                root.pickSec = Logic.clampSeconds(h * 3600 + m * 60 + v);
                applyPick();
              }
            }
          }

          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: "Mouse wheel over the pill: ±5 min"
            color: Util.alpha(root.fg, 0.45)
            font.family: root.face
            font.pixelSize: Style.font.caption
          }

        }

        // Pomodoro mode: cycle progress, phase durations and automation.
        Column {
          id: pomoView
          width: parent.width
          spacing: Style.space(12)
          visible: root.panelTab === "pomodoro"
          opacity: visible ? 1 : 0
          x: visible ? 0 : 6
          Behavior on opacity { NumberAnimation { duration: 120; easing.type: Easing.OutQuad } }
          Behavior on x { NumberAnimation { duration: 120; easing.type: Easing.OutQuad } }

          // Cycle row: the dots are also the long-break interval control
          // (click a dot while idle). They read as progress during a session.
          Item {
            width: parent.width
            height: Style.space(34)

            Row {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(10)

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "CYCLE"
                color: Util.alpha(root.fg, 0.6)
                font.family: root.face
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.4
              }

              Row {
                anchors.verticalCenter: parent.verticalCenter
                spacing: 4
                Repeater {
                  model: 8
                  Item {
                    required property int index
                    readonly property bool filled: hostWidget && index < hostWidget.pomoDone
                    readonly property bool current: hostWidget && index === hostWidget.pomoDone && hostWidget.phase === "focus"
                    readonly property bool threshold: hostWidget && index === hostWidget.pomodoro.cyclesBeforeLong - 1
                    readonly property bool editable: hostWidget && hostWidget.tState === "idle"
                    width: 10
                    height: 22
                    Rectangle {
                      anchors.centerIn: parent
                      width: 9
                      height: 9
                      radius: 4.5
                      color: parent.filled ? hostWidget.phaseAccent : "transparent"
                      border.width: parent.filled ? 0 : (parent.threshold ? 1.6 : 1)
                      border.color: parent.threshold ? hostWidget.phaseAccent : root.ink(parent.current ? 0.55 : 0.28)
                    }
                    HoverHandler { cursorShape: parent.editable ? Qt.PointingHandCursor : Qt.ArrowCursor }
                    TapHandler {
                      acceptedButtons: Qt.LeftButton
                      onTapped: {
                        if (!parent.editable || index < 1) return;
                        hostWidget.updatePomodoro({ cyclesBeforeLong: index + 1 });
                      }
                    }
                  }
                }
              }

              Column {
                id: cycleAdjust
                anchors.verticalCenter: parent.verticalCenter
                spacing: 1
                readonly property bool editable: hostWidget && hostWidget.tState === "idle"
                opacity: editable ? 1 : 0.35

                Item {
                  width: 20
                  height: 14
                  Rectangle {
                    anchors.fill: parent
                    radius: 4
                    color: root.ink(0.10)
                  }
                  Text {
                    anchors.centerIn: parent
                    text: "+"
                    color: Util.alpha(root.fg, 0.8)
                    font.family: root.face
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }
                  HoverHandler { cursorShape: cycleAdjust.editable ? Qt.PointingHandCursor : Qt.ArrowCursor }
                  TapHandler {
                    acceptedButtons: Qt.LeftButton
                    onTapped: {
                      if (!cycleAdjust.editable) return;
                      hostWidget.updatePomodoro({ cyclesBeforeLong: Math.min(8, hostWidget.pomodoro.cyclesBeforeLong + 1) });
                    }
                  }
                }
                Item {
                  width: 20
                  height: 14
                  Rectangle {
                    anchors.fill: parent
                    radius: 4
                    color: root.ink(0.10)
                  }
                  Text {
                    anchors.centerIn: parent
                    text: "−"
                    color: Util.alpha(root.fg, 0.8)
                    font.family: root.face
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }
                  HoverHandler { cursorShape: cycleAdjust.editable ? Qt.PointingHandCursor : Qt.ArrowCursor }
                  TapHandler {
                    acceptedButtons: Qt.LeftButton
                    onTapped: {
                      if (!cycleAdjust.editable) return;
                      hostWidget.updatePomodoro({ cyclesBeforeLong: Math.max(2, hostWidget.pomodoro.cyclesBeforeLong - 1) });
                    }
                  }
                }
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: hostWidget ? hostWidget.pomoProgress : ""
                color: Util.alpha(root.fg, 0.6)
                font.family: root.face
                font.pixelSize: Style.font.bodySmall
              }
            }

            Row {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(6)

              TimerButton {
                width: 58
                label: "Skip"
                tip: "Skip phase (S): an early skipped focus does not count"
                fg: root.fg
                face: root.face
                onFired: if (hostWidget) hostWidget.skipPhase()
              }
              TimerButton {
                width: 66
                label: "Restart"
                tip: "Back to focus 1, paused"
                fg: root.fg
                face: root.face
                onFired: if (hostWidget) hostWidget.pomodoroReset()
              }
            }
          }

          // Only shown while the dots can be edited.
          Text {
            width: parent.width
            visible: hostWidget && hostWidget.tState === "idle"
            text: "Click a dot to set the long-break interval"
            color: Util.alpha(root.fg, 0.35)
            font.family: root.face
            font.pixelSize: Style.font.caption
          }

          Row {
            width: parent.width
            spacing: Style.space(8)
            Stepper {
              title: "FOCUS"
              width: (parent.width - Style.space(16)) / 3
              value: hostWidget ? Math.round(hostWidget.pomodoro.focusSec / 60) : 25
              min: 1
              max: 180
              suffix: " \u2032"
              fg: root.fg
              face: root.face
              onChanged: function(v) { if (hostWidget) hostWidget.updatePomodoro({ focusSec: v * 60 }); }
            }
            Stepper {
              title: "SHORT"
              width: (parent.width - Style.space(16)) / 3
              value: hostWidget ? Math.round(hostWidget.pomodoro.shortSec / 60) : 5
              min: 1
              max: 60
              suffix: " \u2032"
              fg: root.fg
              face: root.face
              onChanged: function(v) { if (hostWidget) hostWidget.updatePomodoro({ shortSec: v * 60 }); }
            }
            Stepper {
              title: "LONG"
              width: (parent.width - Style.space(16)) / 3
              value: hostWidget ? Math.round(hostWidget.pomodoro.longSec / 60) : 15
              min: 1
              max: 120
              suffix: " \u2032"
              fg: root.fg
              face: root.face
              onChanged: function(v) { if (hostWidget) hostWidget.updatePomodoro({ longSec: v * 60 }); }
            }
          }

          Row {
            width: parent.width
            spacing: Style.space(8)

            Row {
              width: (parent.width - Style.space(8)) / 2
              spacing: Style.space(6)
              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "Auto-start focus"
                color: Util.alpha(root.fg, 0.75)
                font.family: root.face
                font.pixelSize: Style.font.bodySmall
              }
              ToggleRow {
                width: 36
                height: Style.space(20)
                on: hostWidget ? hostWidget.pomodoro.autoStartFocus : false
                fg: root.fg
                face: root.face
                onToggled: function(v) { if (hostWidget) hostWidget.updatePomodoro({ autoStartFocus: v }); }
              }
            }

            Row {
              width: (parent.width - Style.space(8)) / 2
              spacing: Style.space(6)
              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "Auto-start break"
                color: Util.alpha(root.fg, 0.75)
                font.family: root.face
                font.pixelSize: Style.font.bodySmall
              }
              ToggleRow {
                width: 36
                height: Style.space(20)
                on: hostWidget ? hostWidget.pomodoro.autoStartBreaks : true
                fg: root.fg
                face: root.face
                onToggled: function(v) { if (hostWidget) hostWidget.updatePomodoro({ autoStartBreaks: v }); }
              }
            }
          }

          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: "Chime + notification at each phase change  ·  S = skip"
            color: Util.alpha(root.fg, 0.45)
            font.family: root.face
            font.pixelSize: Style.font.caption
          }
        }

        // ---- alarms --------------------------------------------------------
        // Default view is the list; ADD swaps it for the editor in place.
        Column {
          id: alarmsView
          width: parent.width
          spacing: Style.space(12)
          visible: root.panelTab === "alarms"

          Column {
            width: parent.width
            spacing: Style.space(10)
            visible: !root.alarmEditing

            TimerButton {
              width: parent.width
              label: "＋  Add alarm"
              primary: true
              fg: root.fg
              face: root.face
              onFired: root.openAlarmEditor(null)
            }

            Text {
              width: parent.width
              visible: !hostWidget || hostWidget.alarms.length === 0
              horizontalAlignment: Text.AlignHCenter
              topPadding: Style.space(8)
              text: "No alarms yet"
              color: Util.alpha(root.fg, 0.45)
              font.family: root.face
              font.pixelSize: Style.font.bodySmall
            }

            Repeater {
              model: hostWidget ? hostWidget.alarms : []
              Column {
                required property var modelData
                required property int index
                width: alarmsView.width
                spacing: Style.space(8)

                Rectangle {
                  width: parent.width
                  height: 1
                  visible: index > 0
                  color: root.ink(0.10)
                }

                Item {
                  id: alarmRow
                  width: alarmsView.width
                  height: Math.max(74, alarmRowInfo.implicitHeight)

                  // The click target lives on the Item, not inside the Column:
                  // positioners ignore anchors, which is why taps did nothing.
                  MouseArea {
                    anchors.left: parent.left
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    width: parent.width - 46
                    acceptedButtons: Qt.LeftButton
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.openAlarmEditor(modelData)
                  }

                  HoverHandler { id: alarmRowHover }
                  Rectangle {
                    id: alarmHint
                    visible: alarmRowHover.hovered
                    z: 1000
                    readonly property real desiredX: alarmRowHover.point.position.x + 12
                    x: Math.max(2, Math.min(alarmRow.width - width - 2, desiredX))
                    y: Math.max(2, alarmRowHover.point.position.y - height - 10)
                    width: hintLabel.implicitWidth + 16
                    height: hintLabel.implicitHeight + 8
                    radius: 6
                    color: Color.tooltip.background
                    border.width: 1
                    border.color: Util.alpha(Color.tooltip.border, 0.55)
                    Text {
                      id: hintLabel
                      anchors.centerIn: parent
                      text: "Click to edit"
                      color: Color.tooltip.text
                      font.family: root.face
                      font.pixelSize: Style.font.bodySmall
                    }
                  }

                  Column {
                    id: alarmRowInfo
                    anchors.left: parent.left
                    anchors.top: parent.top
                    width: parent.width - 46
                    spacing: 2

                    Text {
                      width: alarmRowInfo.width
                      text: modelData.name
                      elide: Text.ElideRight
                      color: Util.alpha(root.fg, 0.62)
                      font.family: root.face
                      font.pixelSize: Style.font.caption
                      font.bold: true
                      font.letterSpacing: 1.2
                    }
                    Text {
                      text: root.pad2(modelData.hour) + ":" + root.pad2(modelData.minute)
                      color: Util.alpha(root.fg, modelData.enabled ? 1.0 : 0.45)
                      font.family: root.face
                      font.pixelSize: Style.font.display
                      font.bold: true
                    }
                    Text {
                      width: alarmRowInfo.width
                      text: Logic.alarmRepeatLabel(modelData.days)
                      elide: Text.ElideRight
                      color: Util.alpha(root.fg, 0.45)
                      font.family: root.face
                      font.pixelSize: Style.font.caption
                    }
                  }

                  ToggleRow {
                    id: alarmRowToggle
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    width: 36
                    height: Style.space(20)
                    on: modelData.enabled
                    fg: root.fg
                    face: root.face
                    onToggled: function(v) { if (hostWidget) hostWidget.setAlarmEnabled(modelData.id, v); }
                  }
                }

              }
            }
          }

          Column {
            width: parent.width
            spacing: Style.space(10)
            visible: root.alarmEditing

            Text {
              width: parent.width
              text: root.alarmEditId === "" ? "NEW ALARM" : "EDIT ALARM"
              color: Util.alpha(root.fg, 0.6)
              font.family: root.face
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.4
            }

            Text {
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              text: root.pad2(root.alarmHour) + ":" + root.pad2(root.alarmMinute)
              color: root.fg
              font.family: root.face
              font.pixelSize: 44
              font.bold: true
            }

            Row {
              width: parent.width
              spacing: Style.space(8)
              Stepper {
                title: "HRS"
                width: (parent.width - Style.space(8)) / 2
                value: root.alarmHour
                min: 0
                max: 23
                fg: root.fg
                face: root.face
                onChanged: function(v) { root.alarmHour = v; }
              }
              Stepper {
                title: "MIN"
                width: (parent.width - Style.space(8)) / 2
                value: root.alarmMinute
                min: 0
                max: 59
                fg: root.fg
                face: root.face
                onChanged: function(v) { root.alarmMinute = v; }
              }
            }

            Rectangle {
              width: parent.width
              height: Style.space(32)
              radius: Style.cornerRadius
              color: root.omarchyTheme ? root.ink(0.05) : Qt.rgba(0, 0, 0, 0.5)
              border.width: 1
              border.color: root.ink(alarmNameInput.activeFocus ? 0.35 : 0.14)
              TextInput {
                id: alarmNameInput
                anchors.fill: parent
                anchors.leftMargin: 10
                anchors.rightMargin: 10
                verticalAlignment: TextInput.AlignVCenter
                text: root.alarmName
                maximumLength: 20
                color: root.fg
                font.family: root.face
                font.pixelSize: Style.font.body
                font.capitalization: Font.AllUppercase
                selectByMouse: true
                onTextEdited: root.alarmName = text.toUpperCase()
              }
              Text {
                anchors.fill: parent
                anchors.leftMargin: 10
                verticalAlignment: Text.AlignVCenter
                visible: root.alarmName === "" && !alarmNameInput.activeFocus
                text: "Name…"
                color: Util.alpha(root.fg, 0.4)
                font.family: root.face
                font.pixelSize: Style.font.body
              }
            }

            Row {
              width: parent.width
              Text {
                width: parent.width - 46
                anchors.verticalCenter: parent.verticalCenter
                text: "Every day"
                color: Util.alpha(root.fg, 0.75)
                font.family: root.face
                font.pixelSize: Style.font.bodySmall
              }
              ToggleRow {
                width: 36
                height: Style.space(20)
                on: root.alarmEveryDay
                fg: root.fg
                face: root.face
                onToggled: function(v) { root.setEveryDay(v); }
              }
            }

            Row {
              id: alarmDayRow
              width: parent.width
              spacing: Style.space(4)
              Repeater {
                model: Logic.ALARM_DAYS
                Rectangle {
                  required property var modelData
                  required property int index
                  readonly property bool selected: root.alarmDays.indexOf(index) >= 0
                  width: (alarmDayRow.width - Style.space(4) * 6) / 7
                  height: Style.space(30)
                  radius: height / 2
                  color: selected ? root.ink(0.18) : "transparent"
                  border.width: 1
                  border.color: selected ? root.ink(0.35) : root.ink(0.12)
                  opacity: root.alarmEveryDay ? 0.4 : 1
                  Text {
                    anchors.centerIn: parent
                    text: modelData
                    color: selected ? root.fg : Util.alpha(root.fg, 0.5)
                    font.family: root.face
                    font.pixelSize: Style.font.caption
                    font.bold: selected
                  }
                  HoverHandler { cursorShape: Qt.PointingHandCursor }
                  TapHandler {
                    acceptedButtons: Qt.LeftButton
                    onTapped: if (!root.alarmEveryDay) root.toggleAlarmDay(index)
                  }
                }
              }
            }

            Row {
              width: parent.width
              Text {
                width: parent.width - 46
                anchors.verticalCenter: parent.verticalCenter
                text: "Sound"
                color: Util.alpha(root.fg, 0.75)
                font.family: root.face
                font.pixelSize: Style.font.bodySmall
              }
              ToggleRow {
                width: 36
                height: Style.space(20)
                on: root.alarmSound
                fg: root.fg
                face: root.face
                onToggled: function(v) { root.alarmSound = v; }
              }
            }

            Row {
              width: parent.width
              spacing: Style.space(8)
              TimerButton {
                width: (parent.width - Style.space(16)) / 3
                label: "Save"
                primary: true
                fg: root.fg
                face: root.face
                onFired: root.saveAlarm()
              }
              TimerButton {
                width: (parent.width - Style.space(16)) / 3
                label: "Delete"
                danger: true
                visible: root.alarmEditId !== ""
                fg: root.fg
                face: root.face
                onFired: root.deleteAlarm()
              }
              TimerButton {
                width: (parent.width - Style.space(16)) / 3
                label: "Cancel"
                fg: root.fg
                face: root.face
                onFired: root.closeAlarmEditor()
              }
            }
          }
        }

        PanelSeparator { foreground: root.fg }

        // ---- theme mode ---------------------------------------------------
        // Original keeps the custom dark glass; Omarchy follows the active
        // theme tokens (native look, and as much blur as the theme wants).
        Row {
          width: parent.width
          spacing: Style.space(10)
          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "Theme:"
            color: Util.alpha(root.fg, 0.55)
            font.family: root.face
            font.pixelSize: Style.font.bodySmall
          }
          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "Original"
            color: root.omarchyTheme ? Util.alpha(root.fg, 0.45) : root.fg
            font.family: root.face
            font.pixelSize: Style.font.bodySmall
            HoverHandler { cursorShape: Qt.PointingHandCursor }
            TapHandler { acceptedButtons: Qt.LeftButton; onTapped: root.setSetting("theme", "Original") }
          }
          ToggleRow {
            width: 36
            height: Style.space(20)
            on: root.omarchyTheme
            fg: root.fg
            face: root.face
            onToggled: function(v) { root.setSetting("theme", v ? "Omarchy" : "Original"); }
          }
          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "Omarchy"
            color: root.omarchyTheme ? root.fg : Util.alpha(root.fg, 0.45)
            font.family: root.face
            font.pixelSize: Style.font.bodySmall
            HoverHandler { cursorShape: Qt.PointingHandCursor }
            TapHandler { acceptedButtons: Qt.LeftButton; onTapped: root.setSetting("theme", "Omarchy") }
          }
        }

        // ---- footer: sound + floating --------------------------------------
        Row {
          width: parent.width
          spacing: Style.space(16)
          ToggleRow {
            width: (parent.width - Style.space(16)) / 2
            label: "Subtle alarm"
            on: hostWidget ? hostWidget.soundOn : true
            fg: root.fg
            face: root.face
            onToggled: function(v) {
              root.setSetting("sound", v);
            }
          }
          ToggleRow {
            width: (parent.width - Style.space(16)) / 2
            label: "↗ Floating"
            on: hostWidget ? hostWidget.detached : false
            fg: root.fg
            face: root.face
            onToggled: function(v) { if (hostWidget) hostWidget.setDetached(v); }
          }
        }

        Text {
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          wrapMode: Text.WordWrap
          text: "Shortcuts: space pause · +/− adjust · R reset · F float"
          color: Util.alpha(root.fg, 0.45)
          font.family: root.face
          font.pixelSize: Style.font.caption
        }
      }
    }
  }

  // ---- reusable pieces ---------------------------------------------
  component TimerButton: Rectangle {
    id: tbtn
    property string label: ""
    property string tip: ""
    property bool primary: false
    property bool danger: false
    property color fg: "white"
    property string face: "monospace"
    signal fired()
    height: Style.space(34)
    radius: 10
    color: {
      if (tbtn.danger) return tbtnHover.hovered ? Qt.rgba(1, 0.35, 0.35, 0.22) : Qt.rgba(1, 0.35, 0.35, 0.10);
      if (tbtn.primary) return root.ink(tbtnHover.hovered ? 0.24 : 0.13);
      return root.ink(tbtnHover.hovered ? 0.14 : 0.06);
    }
    border.width: 1
    border.color: root.ink(tbtn.primary ? 0.22 : 0.12)
    Text {
      anchors.centerIn: parent
      text: tbtn.label
      color: tbtn.fg
      font.family: tbtn.face
      font.pixelSize: Style.font.body
      font.bold: tbtn.primary
    }
    HoverHandler { id: tbtnHover; cursorShape: Qt.PointingHandCursor }
    TapHandler { acceptedButtons: Qt.LeftButton; onTapped: tbtn.fired() }
    PanelToolTip { visible: tbtn.tip !== "" && tbtnHover.hovered; text: tbtn.tip }
  }

  component Stepper: Rectangle {
    id: step
    property string title: ""
    property int value: 0
    property int min: 0
    property int max: 59
    property int step: 1
    property string suffix: ""
    property color fg: "white"
    property string face: "monospace"
    signal changed(int v)
    height: title !== "" ? Style.space(64) : Style.space(32)
    radius: Style.cornerRadius
    color: root.omarchyTheme ? root.ink(0.05) : Qt.rgba(0, 0, 0, 0.5)
    border.width: 1
    border.color: root.ink(0.12)
    function emitClamped(v) {
      v = Math.max(step.min, Math.min(step.max, v));
      if (v !== step.value) step.changed(v);
    }
    // Wheel: one unit per notch, five with Shift. Shared by every stepper
    // (timer tune, pomodoro phases, alarm editor). Quickshell delivers wheel
    // through MouseArea.onWheel, not WheelHandler; declared before the Column
    // so the +/- taps stay on top and clicks keep working.
    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.NoButton
      onWheel: function(wheel) {
        var delta = wheel.angleDelta.y;
        if (delta === 0) return;
        var mult = (wheel.modifiers & Qt.ShiftModifier) ? 5 : 1;
        step.emitClamped(step.value + (delta > 0 ? mult : -mult));
        wheel.accepted = true;
      }
    }
    Column {
      anchors.centerIn: parent
      spacing: 2
      Text {
        visible: step.title !== ""
        anchors.horizontalCenter: parent.horizontalCenter
        text: step.title
        color: Util.alpha(step.fg, 0.55)
        font.family: step.face
        font.pixelSize: Style.font.caption
        font.bold: true
        font.letterSpacing: 1.2
      }
      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: 8
        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: "−"
          color: Util.alpha(step.fg, 0.8)
          font.family: step.face
          font.pixelSize: Style.font.title
          HoverHandler { cursorShape: Qt.PointingHandCursor }
          TapHandler { acceptedButtons: Qt.LeftButton; onTapped: step.emitClamped(step.value - step.step) }
        }
        Text {
          anchors.verticalCenter: parent.verticalCenter
          width: Math.max(34, implicitWidth)
          horizontalAlignment: Text.AlignHCenter
          text: step.value + step.suffix
          color: step.fg
          font.family: step.face
          font.pixelSize: Style.font.title
          font.bold: true
        }
        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: "+"
          color: Util.alpha(step.fg, 0.8)
          font.family: step.face
          font.pixelSize: Style.font.title
          HoverHandler { cursorShape: Qt.PointingHandCursor }
          TapHandler { acceptedButtons: Qt.LeftButton; onTapped: step.emitClamped(step.value + step.step) }
        }
      }
    }
  }

  component ToggleRow: Item {
    id: trow
    property string label: ""
    property bool on: false
    property color fg: "white"
    property string face: "monospace"
    signal toggled(bool v)
    height: Style.space(26)
    Row {
      anchors.verticalCenter: parent.verticalCenter
      spacing: 8
      Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        width: 36
        height: 20
        radius: 10
        color: root.ink(trow.on ? 0.75 : 0.12)
        Rectangle {
          x: trow.on ? parent.width - width - 3 : 3
          anchors.verticalCenter: parent.verticalCenter
          width: 14
          height: 14
          radius: 7
          color: trow.on ? (root.omarchyTheme ? Color.popups.background : "black") : root.fg
          Behavior on x { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
        }
        HoverHandler { cursorShape: Qt.PointingHandCursor }
        TapHandler { acceptedButtons: Qt.LeftButton; onTapped: trow.toggled(!trow.on) }
      }
      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: trow.label
        color: trow.fg
        font.family: trow.face
        font.pixelSize: Style.font.bodySmall
      }
    }
  }
}
