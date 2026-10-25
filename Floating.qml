import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import "TimerLogic.js" as Logic

// Floating Timer window: square, large and minimalist, always
// visible on top (overlay layer) with compositor blur and a
// translucent background. It moves by dragging the time area. The
// last-5-seconds heartbeat only affects the font, never the background.
PanelWindow {
  id: root

  required property var host

  screen: {
    // Anchor to the screen of the bar hosting the widget.
    try {
      var w = host && host.pillButton ? host.pillButton.QsWindow.window : null;
      return w && w.screen ? w.screen : null;
    } catch (e) { return null; }
  }

  // Only one across the whole system: only the owning screen shows
  // the card. The preview target screen shows a ghost.
  readonly property bool isOwner: host && host.detached === true
    && host.detachedScreen !== "" && host.screenName === host.detachedScreen
  readonly property bool isPreview: host && !isOwner
    && host.previewScreen !== "" && host.previewScreen === host.screenName
  visible: host && (isOwner || isPreview)
  color: "transparent"
  exclusionMode: ExclusionMode.Ignore

  WlrLayershell.namespace: "nickmdrummer-timer-float"
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

  // Static fullscreen: the card moves INSIDE without touching the
  // surface. While dragging, the mask opens to the whole screen
  // ONCE (on press) and closes on release: zero commits per event,
  // the grab is not cut off and there is no stutter. Outside the drag,
  // the mask is just the card and the rest lets clicks through.
  property bool dragging: false
  anchors {
    top: true
    bottom: true
    left: true
    right: true
  }
  mask: Region {
    x: dragging ? 0 : (isOwner ? card.x : ghost.x)
    y: dragging ? 0 : (isOwner ? card.y : ghost.y)
    width: dragging ? root.screenW : (isOwner ? card.width : ghost.width)
    height: dragging ? root.screenH : (isOwner ? card.height : ghost.height)
  }

  readonly property string face: host ? host.face : Style.font.family
  readonly property bool omarchyTheme: host && host.omarchyTheme === true
  readonly property bool lightTheme: host && host.lightTheme === true
  readonly property color ink: root.omarchyTheme ? Color.popups.text : Qt.rgba(1, 1, 1, 0.94)
  // Original mode: dark glass, a bit denser on light themes. Omarchy mode:
  // the theme popup surface, so it looks native (and the compositor blur
  // is as subtle as the theme intends).
  readonly property color cardColor: root.omarchyTheme
    ? Color.popups.background
    : Qt.rgba(0, 0, 0, root.lightTheme ? 0.44 : 0.34)
  readonly property color edgeColor: root.omarchyTheme
    ? Util.alpha(Color.popups.border, 0.55)
    : Qt.rgba(1, 1, 1, 0.14)
  readonly property color beatGreen: Qt.rgba(0.29, 0.87, 0.5, 1)
  readonly property bool phase: host && host.urgentPhase === true
  readonly property real screenW: root.screen ? root.screen.width : 1920
  readonly property real screenH: root.screen ? root.screen.height : 1080
  // Always keep 80 px visible: the floating window never gets lost off
  // the screen (not even when trying to push it to the neighboring monitor:
  // layer windows live on a single output).
  readonly property real keepVisible: 80
  function clampCard() {
    card.x = Math.max(-(card.width - root.keepVisible),
      Math.min(root.screenW - root.keepVisible, card.x));
    card.y = Math.max(-(card.height - root.keepVisible),
      Math.min(root.screenH - root.keepVisible, card.y));
  }
  onVisibleChanged: {
    if (visible) {
      root.clampCard();
      root.tryLand();
    } else if (dragZone.previewMine) {
      // Fallback: if the window hides mid-preview,
      // do not leave the ghost hanging on the neighbor.
      dragZone.previewMine = false;
      if (host && typeof host.clearPreview === "function") host.clearPreview();
    }
  }
  readonly property string timeText: {
    if (!host) return "--:--";
    if (host.tState === "finished") return "00:00";
    if (host.tState === "idle") return Logic.fmt(host.stagedSec);
    return Logic.fmt(host.remainingSec);
  }
  readonly property string subText: {
    if (!host) return "";
    if (host.tState === "running") return "running";
    if (host.tState === "paused") return "paused";
    if (host.tState === "finished") return "time's up";
    return "ready";
  }
  readonly property string primaryWord: {
    if (!host) return "start";
    if (host.tState === "running") return "pause";
    if (host.tState === "paused") return "resume";
    if (host.tState === "finished") return "done";
    return "start";
  }

  Connections {
    target: root.host
    function onBeatChanged() {
      if (root.phase) floatThump.restart();
    }
    function onLandSeqChanged() { root.tryLand(); }
  }

  // Apply the landing only once: the card appears where the
  // pointer crossed, so the jump feels seamless.
  function tryLand() {
    if (!root.visible || !host) return;
    if (host.landSeq <= host.landSeenSeq) return;
    host.landSeenSeq = host.landSeq;
    if (host.landX < 0 || host.detachedScreen !== host.screenName) return;
    card.x = host.landX;
    card.y = host.landY;
    root.clampCard();
  }

  Rectangle {
    id: card
    visible: root.isOwner
    x: root.screenW - width - 12
    y: (host && host.bar ? host.bar.barSize : 26) + 10
    width: 244
    height: 244
    radius: 30
    color: root.cardColor
    border.width: 1
    border.color: (host && host.tState === "finished")
      ? (host.bar ? host.bar.urgent : Color.urgent)
      : root.edgeColor

    // Back to the bar (top right).
    Text {
      anchors.top: parent.top
      anchors.right: parent.right
      anchors.topMargin: 14
      anchors.rightMargin: 18
      text: "↩"
      color: Util.alpha(root.ink, backHover.hovered ? 1.0 : 0.55)
      font.family: root.face
      font.pixelSize: 15
      HoverHandler { id: backHover; cursorShape: Qt.PointingHandCursor }
      TapHandler {
        acceptedButtons: Qt.LeftButton
        onTapped: if (host) host.setDetached(false)
      }
    }

    Column {
      anchors.centerIn: parent
      anchors.verticalCenterOffset: -10
      spacing: 10

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: (host && host.mode === "pomodoro") ? (host.phaseLabel + " · " + host.pomoProgress) : "TIMER"
        color: (host && host.mode === "pomodoro") ? Util.alpha(host.phaseAccent, 0.85) : Util.alpha(root.ink, 0.5)
        font.family: root.face
        font.pixelSize: Style.font.caption
        font.bold: true
        font.letterSpacing: 2
      }

      // Time area: click opens the panel, dragging moves the window.
      Item {
        id: timeZone
        anchors.horizontalCenter: parent.horizontalCenter
        width: timeTextItem.implicitWidth + 32
        height: timeTextItem.implicitHeight + 16

        Text {
          id: timeTextItem
          anchors.centerIn: parent
          transformOrigin: Item.Center
          text: root.timeText
          color: (host && host.tState === "finished")
            ? (host.bar ? host.bar.urgent : Color.urgent)
            : root.phase ? root.beatGreen : root.ink
          font.family: root.face
          font.pixelSize: 56
          font.bold: true
        }

        SequentialAnimation {
          id: floatThump
          NumberAnimation { target: timeTextItem; property: "scale"; to: 1.07; duration: 120; easing.type: Easing.OutQuad }
          NumberAnimation { target: timeTextItem; property: "scale"; to: 1.0; duration: 240; easing.type: Easing.InOutQuad }
        }

        // ABSOLUTE 1:1 dragging over a static window. The position is
        // computed in window coords (stable), not with relative
        // deltas: this way the synthetic events Qt emits as the
        // item moves under the cursor do not accumulate (that caused the shaking).
        // Everything rounded to integers to avoid text/blur shimmer.
        MouseArea {
          id: dragZone
          anchors.fill: parent
          acceptedButtons: Qt.LeftButton
          hoverEnabled: true
          cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
          property real pressPX: 0
          property real pressPY: 0
          property real lastPX: 0
          property real lastPY: 0
          property real grabDX: 0
          property real grabDY: 0
          property bool moved: false
          // Remainder not applied due to clamp = push against the edge
          // (to jump monitors you must PUSH, see onReleased).
          property real edgePX: 0
          property real edgePY: 0
          property bool previewMine: false
          property double lastPreview: 0
          function rootPos(m) { return dragZone.mapToItem(card.parent, m.x, m.y); }
          // Ghost on the neighbor while pushing (max ~8 writes/s).
          function updatePreview(p) {
            var pdir = "";
            if (Math.abs(edgePX) > 24) pdir = edgePX > 0 ? "right" : "left";
            else if (Math.abs(edgePY) > 24) pdir = edgePY > 0 ? "down" : "up";
            function unpreview() {
              if (previewMine) {
                previewMine = false;
                if (host && typeof host.clearPreview === "function") host.clearPreview();
              }
            }
            if (pdir === "" || !host) { unpreview(); return; }
            if (typeof host.findNeighborObj !== "function"
                || typeof host.landingFor !== "function"
                || typeof host.writePreview !== "function") { unpreview(); return; }
            var g = typeof host.globalPoint === "function"
              ? host.globalPoint(p.x, p.y) : { x: p.x, y: p.y };
            var nb = host.findNeighborObj(pdir, g.x, g.y);
            if (!nb) { unpreview(); return; }
            if (Date.now() - lastPreview < 120) return;
            var L = host.landingFor(pdir, g.x, g.y, nb.name);
            if (!L) { unpreview(); return; }
            lastPreview = Date.now();
            previewMine = true;
            host.writePreview(nb.name, L.x, L.y);
          }
          onPressed: function(m) {
            var p = dragZone.rootPos(m);
            pressPX = p.x;
            pressPY = p.y;
            lastPX = p.x;
            lastPY = p.y;
            grabDX = p.x - card.x;
            grabDY = p.y - card.y;
            edgePX = 0;
            edgePY = 0;
            moved = false;
            root.dragging = true;
            if (host && typeof host.refreshMonitors === "function") host.refreshMonitors();
          }
          onPositionChanged: function(m) {
            if (!pressed) return;
            var p = dragZone.rootPos(m);
            lastPX = p.x;
            lastPY = p.y;
            if (!moved && Math.abs(p.x - pressPX) < 4 && Math.abs(p.y - pressPY) < 4) return;
            moved = true;
            var wantX = p.x - grabDX;
            var wantY = p.y - grabDY;
            card.x = Math.round(wantX);
            card.y = Math.round(wantY);
            root.clampCard();
            edgePX = wantX - card.x;
            edgePY = wantY - card.y;
            dragZone.updatePreview(p);
          }
          onReleased: function(m) {
            root.dragging = false;
            if (!moved) {
              if (host) host.open();
              return;
            }
            var dir = "";
            if (Math.abs(edgePX) > 120) dir = edgePX > 0 ? "right" : "left";
            else if (Math.abs(edgePY) > 120) dir = edgePY > 0 ? "down" : "up";
            dragZone.edgePX = 0;
            dragZone.edgePY = 0;
            dragZone.previewMine = false;
            if (host && typeof host.clearPreview === "function") host.clearPreview();
            // Monitor jump by pushing against the edge (if there is a neighbor),
            // landing where the pointer is.
            if (dir !== "" && host && typeof host.hopFloating === "function") {
              var g = typeof host.globalPoint === "function"
                ? host.globalPoint(dragZone.lastPX, dragZone.lastPY)
                : { x: dragZone.lastPX, y: dragZone.lastPY };
              if (host.hopFloating(dir, g.x, g.y)) return;
            }
          }
        }
      }

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: root.subText
        color: Util.alpha(root.ink, 0.6)
        font.family: root.face
        font.pixelSize: Style.font.bodySmall
      }
    }

    // Actions at the bottom: pause / stop.
    Row {
      anchors.bottom: parent.bottom
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.bottomMargin: 22
      spacing: 26

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: root.primaryWord
        color: pauseHover.hovered ? root.ink : Util.alpha(root.ink, 0.75)
        font.family: root.face
        font.pixelSize: Style.font.title
        font.underline: pauseHover.hovered
        HoverHandler { id: pauseHover; cursorShape: Qt.PointingHandCursor }
        TapHandler {
          acceptedButtons: Qt.LeftButton
          onTapped: if (host) host.togglePause()
        }
      }

      Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        width: 1
        height: 16
        color: Qt.rgba(1, 1, 1, 0.2)
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: "stop"
        color: stopHover.hovered ? root.ink : Util.alpha(root.ink, 0.75)
        font.family: root.face
        font.pixelSize: Style.font.title
        font.underline: stopHover.hovered
        HoverHandler { id: stopHover; cursorShape: Qt.PointingHandCursor }
        TapHandler {
          acceptedButtons: Qt.LeftButton
          onTapped: if (host) host.resetAll()
        }
      }
    }
  }

  // Ghost on the target monitor while pushing against the edge: a
  // visual clone without interaction, at the same position where it would land.
  // On release, the real card appears exactly there (imperceptible
  // transition).
  Rectangle {
    id: ghost
    visible: root.isPreview
    x: host ? host.previewX : 0
    y: host ? host.previewY : 0
    width: 244
    height: 244
    radius: 30
    color: root.cardColor
    border.width: 1
    border.color: root.edgeColor

    Column {
      anchors.centerIn: parent
      spacing: 10

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: root.timeText
        color: root.phase ? root.beatGreen : root.ink
        font.family: root.face
        font.pixelSize: 56
        font.bold: true
      }

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: root.subText
        color: Util.alpha(root.ink, 0.6)
        font.family: root.face
        font.pixelSize: Style.font.bodySmall
      }
    }
  }
}
