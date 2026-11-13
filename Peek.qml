import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Workspace peek: a fullscreen overlay with a live, to-scale preview of every
// occupied workspace (plus the one you're on, and the scratchpad when it has
// windows). Windows are captured with Hyprland's toplevel export, so windows on
// workspaces you're not looking at still render.
//
//   Click a workspace      -> go there          Click a window -> focus it
//   1-9 / 0                -> go to workspace N (0 = 10)
//   Arrows / hjkl / Tab    -> move the selection, Enter goes there
//   Esc, a click outside, or Super+A again -> close
Item {
  id: root

  property var shell: null
  property var manifest: null

  property bool opened: false
  property int selectedIndex: 0
  property string hoverTitle: ""

  property color background: Commons.Color.menu.background
  property color foreground: Commons.Color.menu.text
  property color accent: Commons.Color.menu.selectedText
  property color selectedBackground: Commons.Color.menu.selectedBackground
  property var borderSpec: Border.surfaceSpec("menu", "border", Commons.Color.menu.border, Math.max(1, Style.space(2)))
  property string fontFamily: Style.font.menuFamily
  readonly property int cornerRadius: Style.cornerRadius

  readonly property int outerMargin: Style.space(48)
  readonly property int gap: Style.space(24)
  readonly property int labelHeight: Math.max(Style.space(28), Style.font.title + Style.space(12))
  readonly property int headerHeight: Style.font.heading + Style.space(24)

  // --- Lifecycle -----------------------------------------------------------

  function open(payloadJson) {
    Hyprland.refreshWorkspaces()
    Hyprland.refreshToplevels()
    Hyprland.refreshMonitors()
    root.refreshClients()
    root.hoverTitle = ""
    root.opened = true
    root.selectedIndex = Math.max(0, root.indexOfWorkspace(root.focusedWorkspaceId()))
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.opened = false
  }

  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "kov.workspace-peek")
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  // --- Data ----------------------------------------------------------------

  function focusedWorkspaceId() {
    var m = Hyprland.focusedMonitor
    return m && m.activeWorkspace ? m.activeWorkspace.id : -1
  }

  function isScratch(ws) {
    return ws && String(ws.name) === "special:scratchpad"
  }

  // Occupied normal workspaces, the focused one even when empty, then the
  // scratchpad if it holds anything. Bound, so it follows windows opening and
  // closing while the overlay is up.
  readonly property var cards: {
    if (!root.opened) return []
    var focused = root.focusedWorkspaceId()
    var values = Hyprland.workspaces.values
    var normal = []
    var scratch = null
    for (var i = 0; i < values.length; i++) {
      var ws = values[i]
      var count = ws.toplevels.values.length
      if (ws.id > 0) {
        if (count > 0 || ws.id === focused) normal.push(ws)
      } else if (root.isScratch(ws) && count > 0) {
        scratch = ws
      }
    }
    normal.sort(function(a, b) { return a.id - b.id })
    if (scratch) normal.push(scratch)
    return normal
  }

  function indexOfWorkspace(id) {
    for (var i = 0; i < root.cards.length; i++) if (root.cards[i].id === id) return i
    return -1
  }

  // Logical geometry of the monitor a workspace lives on.
  function monitorGeometry(ws) {
    var m = ws && ws.monitor ? ws.monitor : Hyprland.focusedMonitor
    if (!m) return { x: 0, y: 0, w: 1920, h: 1080 }
    var scale = m.scale > 0 ? m.scale : 1
    var w = m.width / scale
    var h = m.height / scale
    var ipc = m.lastIpcObject
    if (ipc && (ipc.transform === 1 || ipc.transform === 3 || ipc.transform === 5 || ipc.transform === 7)) {
      var t = w; w = h; h = t
    }
    return { x: m.x, y: m.y, w: w, h: h }
  }

  readonly property var focusedGeometry: root.monitorGeometry(null)
  readonly property real aspect: root.focusedGeometry.w / Math.max(1, root.focusedGeometry.h)

  // Pick the column count that gives the biggest previews that still fit.
  readonly property var layout: {
    var n = Math.max(1, root.cards.length)
    var W = panel.width - root.outerMargin * 2
    var H = panel.height - root.outerMargin * 2 - root.headerHeight
    var best = { cols: 1, w: 0 }
    for (var c = 1; c <= n; c++) {
      var rows = Math.ceil(n / c)
      var byWidth = (W - (c - 1) * root.gap) / c
      var byHeight = ((H - (rows - 1) * root.gap) / rows - root.labelHeight) * root.aspect
      var w = Math.min(byWidth, byHeight, W * 0.46)
      if (w > best.w + 0.5) best = { cols: c, w: w }
    }
    var cw = Math.max(80, Math.floor(best.w))
    return { cols: best.cols, w: cw, h: Math.round(cw / root.aspect) }
  }

  // Window geometry straight from `hyprctl clients -j`, keyed by address.
  // (Quickshell's per-toplevel lastIpcObject comes back empty for windows on
  // workspaces that aren't showing.)
  property var clients: ({})

  function normAddress(a) {
    a = String(a || "")
    return a.indexOf("0x") === 0 ? a : "0x" + a
  }

  function refreshClients() {
    if (clientsProc.running) clientsRefresh.restart()
    else clientsProc.running = true
  }

  Process {
    id: clientsProc
    command: ["hyprctl", "clients", "-j"]
    stdout: StdioCollector {
      onStreamFinished: {
        var next = ({})
        try {
          var list = JSON.parse(text)
          for (var i = 0; i < list.length; i++) next[root.normAddress(list[i].address)] = list[i]
        } catch (e) {
          console.warn("kov.workspace-peek: bad hyprctl clients output", e)
          return
        }
        root.clients = next
      }
    }
  }

  // Windows moving, opening or closing while the overlay is up.
  Timer {
    id: clientsRefresh
    interval: 120
    onTriggered: root.refreshClients()
  }

  Connections {
    target: Hyprland
    enabled: root.opened
    function onRawEvent(event) { clientsRefresh.restart() }
  }

  function appIdOf(t) {
    if (t.wayland && t.wayland.appId) return t.wayland.appId
    var ipc = t.lastIpcObject
    return ipc && ipc["class"] ? ipc["class"] : ""
  }

  function iconFor(appId) {
    var entry = DesktopEntries.heuristicLookup(appId)
    var name = entry && entry.icon ? entry.icon : appId
    if (String(name).charAt(0) === "/") return "file://" + name
    var path = Quickshell.iconPath(name, true)
    if (!path) path = Quickshell.iconPath(String(appId).toLowerCase(), true)
    return path || Quickshell.iconPath("application-x-executable", true)
  }

  // --- Actions -------------------------------------------------------------

  function dispatch(expression) {
    Quickshell.execDetached(["hyprctl", "dispatch", expression])
  }

  function goToWorkspace(ws) {
    if (!ws) return
    var scratch = root.isScratch(ws)
    var id = ws.id
    root.dismiss()
    if (scratch) root.dispatch("hl.dsp.workspace.toggle_special(\"scratchpad\")")
    else root.dispatch("hl.dsp.focus({ workspace = \"" + id + "\" })")
  }

  function focusWindow(t) {
    if (!t) return
    var address = root.normAddress(t.address)
    root.dismiss()
    root.dispatch("hl.dsp.focus({ window = \"address:" + address + "\" })")
  }

  function goToNumber(n) {
    for (var i = 0; i < root.cards.length; i++) {
      if (root.cards[i].id === n) { root.goToWorkspace(root.cards[i]); return }
    }
    // Not occupied: still go there, like Super+N would.
    root.dismiss()
    root.dispatch("hl.dsp.focus({ workspace = \"" + n + "\" })")
  }

  function moveSelection(dx, dy) {
    var n = root.cards.length
    if (n === 0) return
    var cols = root.layout.cols
    var next = root.selectedIndex + dx + dy * cols
    if (dy !== 0 && (next < 0 || next >= n)) return
    root.selectedIndex = (next + n) % n
  }

  // --- UI ------------------------------------------------------------------

  OverlayWindow {
    id: panel
    shown: root.opened
    WlrLayershell.namespace: "kov-workspace-peek"

    // Mostly opaque so the workspace underneath doesn't compete with the previews.
    Rectangle {
      anchors.fill: parent
      color: Qt.rgba(root.background.r, root.background.g, root.background.b, 0.96)
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true

      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) {
        var k = event.key
        if (k === Qt.Key_Escape || k === Qt.Key_Q) {
          root.dismiss()
        } else if (k >= Qt.Key_1 && k <= Qt.Key_9) {
          root.goToNumber(k - Qt.Key_0)
        } else if (k === Qt.Key_0) {
          root.goToNumber(10)
        } else if (k === Qt.Key_Left || k === Qt.Key_H || k === Qt.Key_Backtab) {
          root.moveSelection(-1, 0)
        } else if (k === Qt.Key_Right || k === Qt.Key_L || k === Qt.Key_Tab) {
          root.moveSelection(1, 0)
        } else if (k === Qt.Key_Up || k === Qt.Key_K) {
          root.moveSelection(0, -1)
        } else if (k === Qt.Key_Down || k === Qt.Key_J) {
          root.moveSelection(0, 1)
        } else if (k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_Space) {
          root.goToWorkspace(root.cards[root.selectedIndex])
        } else {
          return
        }
        event.accepted = true
      }
    }

    Text {
      id: header
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.top: parent.top
      anchors.topMargin: root.outerMargin
      height: root.headerHeight
      textFormat: Text.PlainText
      text: root.hoverTitle !== "" ? root.hoverTitle
        : root.cards.length + (root.cards.length === 1 ? " workspace" : " workspaces")
      color: root.foreground
      opacity: root.hoverTitle !== "" ? 1 : 0.6
      font.family: root.fontFamily
      font.pixelSize: Style.font.heading
      elide: Text.ElideRight
      width: Math.min(implicitWidth, parent.width - root.outerMargin * 2)
    }

    Grid {
      id: grid
      anchors.horizontalCenter: parent.horizontalCenter
      y: root.outerMargin + root.headerHeight
        + Math.max(0, (panel.height - root.outerMargin * 2 - root.headerHeight - implicitHeight) / 2)
      columns: root.layout.cols
      spacing: root.gap

      Repeater {
        model: root.cards

        delegate: Item {
          id: card
          required property var modelData
          required property int index

          readonly property var ws: modelData
          readonly property bool scratch: root.isScratch(ws)
          readonly property bool current: !scratch && ws.id === root.focusedWorkspaceId()
          readonly property bool selected: index === root.selectedIndex
          readonly property var geo: root.monitorGeometry(ws)

          width: root.layout.w
          height: root.layout.h + root.labelHeight

          // Workspace number + app icons
          Row {
            id: label
            height: root.labelHeight
            spacing: Style.space(8)
            anchors.left: parent.left

            Text {
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: card.scratch ? "S" : String(card.ws.id)
              color: card.current || card.selected ? root.accent : root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              visible: card.scratch || card.ws.toplevels.values.length === 0
              textFormat: Text.PlainText
              text: card.scratch ? "scratchpad" : "empty"
              color: root.foreground
              opacity: 0.55
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }
          }

          // Monitor-shaped frame
          Rectangle {
            id: frame
            anchors.top: label.bottom
            width: parent.width
            height: root.layout.h
            radius: root.cornerRadius
            color: Qt.darker(Qt.rgba(root.background.r, root.background.g, root.background.b, 1), 1.25)
            clip: true
            border.width: card.selected || card.current ? Math.max(2, Style.space(3)) : 1
            border.color: card.selected ? root.accent
              : card.current ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.5)
              : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.15)

            // Fit this workspace's monitor inside the frame.
            readonly property real s: Math.min(width / card.geo.w, height / card.geo.h)
            readonly property real ox: (width - card.geo.w * s) / 2
            readonly property real oy: (height - card.geo.h * s) / 2

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onContainsMouseChanged: if (containsMouse) root.selectedIndex = card.index
              onClicked: root.goToWorkspace(card.ws)
            }

            Repeater {
              model: card.ws.toplevels

              delegate: Item {
                id: win
                required property var modelData
                readonly property var t: modelData
                readonly property var ipc: root.clients[root.normAddress(t.address)]
                readonly property bool known: !!ipc && !!ipc.at && !!ipc.size
                readonly property string appId: root.appIdOf(t)

                visible: known && !ipc.hidden
                x: known ? frame.ox + (ipc.at[0] - card.geo.x) * frame.s : 0
                y: known ? frame.oy + (ipc.at[1] - card.geo.y) * frame.s : 0
                width: known ? Math.max(4, ipc.size[0] * frame.s) : 0
                height: known ? Math.max(4, ipc.size[1] * frame.s) : 0
                // Floating above fullscreen above tiled; recently focused on
                // top. Kept positive: a negative z would draw under the frame.
                z: (known && ipc.floating ? 2000 : 0) + (known && ipc.fullscreen > 0 ? 1000 : 0)
                  + Math.max(1, 500 - (known ? (ipc.focusHistoryID || 0) : 0))

                Rectangle {
                  anchors.fill: parent
                  color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06)
                  border.width: 1
                  border.color: winMouse.containsMouse ? root.accent
                    : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.2)
                  radius: Math.min(root.cornerRadius, 4)
                }

                ScreencopyView {
                  id: shot
                  anchors.fill: parent
                  anchors.margins: 1
                  captureSource: root.opened && win.visible ? win.t.wayland : null
                  live: true
                  paintCursor: false
                  constraintSize: Qt.size(Math.ceil(win.width * panel.devicePixelRatio),
                                          Math.ceil(win.height * panel.devicePixelRatio))
                }

                // App icon: big and centred until a frame arrives, then a
                // small corner badge.
                Image {
                  anchors.centerIn: parent
                  visible: !shot.hasContent && win.appId !== ""
                  width: Math.min(Style.space(48), Math.min(win.width, win.height) * 0.5)
                  height: width
                  source: win.appId ? root.iconFor(win.appId) : ""
                  sourceSize.width: width * 2
                  sourceSize.height: height * 2
                  asynchronous: true
                  smooth: true
                }

                Image {
                  anchors.right: parent.right
                  anchors.bottom: parent.bottom
                  anchors.margins: Style.space(5)
                  visible: shot.hasContent && win.appId !== "" && win.width > Style.space(60)
                  width: Math.min(Style.space(22), Math.min(win.width, win.height) * 0.3)
                  height: width
                  source: win.appId ? root.iconFor(win.appId) : ""
                  sourceSize.width: width * 2
                  sourceSize.height: height * 2
                  asynchronous: true
                  smooth: true
                }

                MouseArea {
                  id: winMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onContainsMouseChanged: {
                    if (containsMouse) {
                      root.selectedIndex = card.index
                      root.hoverTitle = win.t.title || win.appId
                    } else if (root.hoverTitle === (win.t.title || win.appId)) {
                      root.hoverTitle = ""
                    }
                  }
                  onClicked: root.focusWindow(win.t)
                }
              }
            }
          }
        }
      }
    }
  }
}
