import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import "TimerLogic.js" as Logic

// Ventana flotante del Timer: cuadrada, grande y minimalista, siempre
// visible por encima (layer overlay) con blur del compositor y fondo
// translucido. Se mueve arrastrando la zona de la hora. El latido de los
// ultimos 5 segundos solo afecta a la fuente, nunca al fondo.
PanelWindow {
  id: root

  required property var host

  screen: {
    // Anclar a la pantalla de la barra que hospeda el widget.
    try {
      var w = host && host.pillButton ? host.pillButton.QsWindow.window : null;
      return w && w.screen ? w.screen : null;
    } catch (e) { return null; }
  }

  // Uno solo en todo el sistema: solo la pantalla dueña muestra la
  // tarjeta. La pantalla destino del preview muestra un fantasma.
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

  // Fullscreen estatica: la tarjeta se mueve DENTRO sin tocar la
  // superficie. Durante el arrastre la mascara se abre a toda la pantalla
  // UNA vez (al presionar) y se cierra al soltar: cero commits por evento,
  // el grab no se corta y no hay stutter. Fuera del drag, la mascara es
  // solo la tarjeta y el resto traspasa los clics.
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
  readonly property color ink: host && host.bar ? host.bar.foreground : Color.foreground
  readonly property color beatGreen: Qt.rgba(0.29, 0.87, 0.5, 1)
  readonly property bool phase: host && host.urgentPhase === true
  readonly property real screenW: root.screen ? root.screen.width : 1920
  readonly property real screenH: root.screen ? root.screen.height : 1080
  // Siempre quedan 80 px visibles: el flotante nunca se pierde fuera
  // de la pantalla (tampoco intentando pasarlo al monitor vecino:
  // las ventanas layer viven en un solo output).
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
      // Respaldo: si la ventana se oculta a mitad de un preview,
      // no dejar el fantasma colgado en el vecino.
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

  // Aplica el aterrizaje una sola vez: la tarjeta aparece donde cruzo
  // el puntero, asi el salto se siente continuo.
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
    color: Qt.rgba(0, 0, 0, 0.34)
    border.width: 1
    border.color: (host && host.tState === "finished")
      ? (host.bar ? host.bar.urgent : Color.urgent)
      : Qt.rgba(1, 1, 1, 0.14)

    // Volver a la barra (arriba a la derecha).
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
        text: "TIMER"
        color: Util.alpha(root.ink, 0.5)
        font.family: root.face
        font.pixelSize: Style.font.caption
        font.bold: true
        font.letterSpacing: 2
      }

      // Zona de hora: clic abre el panel, arrastrar mueve la ventana.
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

        // Arrastre ABSOLUTO 1:1 sobre ventana estatica. La posicion se
        // calcula en coords de la ventana (estable), no con deltas
        // relativos: asi los eventos sinteticos que Qt emite al moverse
        // el item bajo el cursor no se acumulan (eso causaba el shaking).
        // Todo redondeado a enteros para no shimmear texto/blur.
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
          // Resto sin aplicar por el clamp = empuje contra el borde
          // (para saltar de monitor hay que EMPUJAR, ver onReleased).
          property real edgePX: 0
          property real edgePY: 0
          property bool previewMine: false
          property double lastPreview: 0
          function rootPos(m) { return dragZone.mapToItem(card.parent, m.x, m.y); }
          // Fantasma en el vecino mientras se empuja (max ~8 escrituras/s).
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
            var nb = host.findNeighborObj(pdir);
            if (!nb) { unpreview(); return; }
            if (Date.now() - lastPreview < 120) return;
            var L = host.landingFor(pdir, p.x, p.y, nb.name);
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
            // Salto de monitor por empuje al borde (si hay vecino),
            // aterrizando donde esta el puntero.
            if (dir !== "" && host && typeof host.hopFloating === "function") {
              if (host.hopFloating(dir, dragZone.lastPX, dragZone.lastPY)) return;
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

    // Acciones abajo: pausar / parar.
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

  // Fantasma en el monitor destino mientras se empuja al borde: clon
  // visual sin interaccion, en la misma posicion donde aterrizaria.
  // Al soltar, la tarjeta real aparece exactamente ahi (transicion
  // imperceptible).
  Rectangle {
    id: ghost
    visible: root.isPreview
    x: host ? host.previewX : 0
    y: host ? host.previewY : 0
    width: 244
    height: 244
    radius: 30
    color: Qt.rgba(0, 0, 0, 0.34)
    border.width: 1
    border.color: Qt.rgba(1, 1, 1, 0.14)

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
