import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

// VPN bar module.
//   Left click  - open the panel (servers, kill switch, inbox)
//   Right click - connect / disconnect the last-used tunnel
// Backend: vpn.sh, bundled alongside this file. Privileged bits go through
// pkexec -> /usr/local/lib/omarchy-vpn/omarchy-vpn-helper (kill switch only).
Panel {
  id: root
  moduleName: "groot.vpn"
  ipcTarget: "groot.vpn"

  readonly property string pluginDir: {
    var dir = String(Qt.resolvedUrl("."))
    return dir.replace(/^file:\/\//, "").replace(/\/$/, "")
  }
  readonly property string script: pluginDir + "/vpn.sh"

  // ---- settings (handed to vpn.sh as OMARCHY_VPN_* env; Process.environment
  //      is a hash that merges over the inherited env) ----
  readonly property bool cfgIpLookup: setting("publicIpLookup", true)
  readonly property string cfgIpUrl: setting("publicIpUrl", "https://ipinfo.io/json")
  readonly property bool cfgKeepConf: setting("keepOriginalConfigs", true)
  readonly property var backendEnv: ({
    "OMARCHY_VPN_PUBLICIPLOOKUP": cfgIpLookup ? "true" : "false",
    "OMARCHY_VPN_PUBLICIPURL": cfgIpUrl,
    "OMARCHY_VPN_KEEPORIGINALCONFIGS": cfgKeepConf ? "true" : "false"
  })

  // ---- state ----
  property var st: ({})
  property string busyAction: ""      // non-empty while a mutation is running
  property string lastError: ""
  property string lastConnectedId: ""

  readonly property var servers: st.servers || []
  readonly property var activeId: st.active_id || null
  readonly property var activeServer: {
    for (var i = 0; i < servers.length; i++)
      if (servers[i].id === activeId) return servers[i]
    return null
  }
  readonly property bool integration: st.integration === true
  readonly property string ksState: st.killswitch || "unknown"   // on | off | unknown
  readonly property bool ksOn: ksState === "on"
  readonly property bool ksPersisted: st.killswitch_persisted === true
  readonly property int inboxCount: Number(st.inbox_count) || 0
  readonly property var pub: st.public || ({})

  // kill switch is armed but nothing is carrying traffic -> you are offline
  readonly property bool leakedOpen: false
  readonly property bool strandedByKillswitch: ksOn && !activeServer

  readonly property color fg: Color.popups.text

  // ---- bar glyph state ----
  readonly property string barGlyph: "" // nf-fa-shield
  readonly property color barColor: {
    if (activeServer) return "#3fb950"                       // connected
    if (strandedByKillswitch) return Color.urgent            // armed, no tunnel
    if (ksOn) return "#d29922"                               // armed
    return root.bar ? Qt.darker(root.bar.barForeground, 1.5) : Color.foreground
  }
  readonly property string barLabel: {
    if (activeServer) return shortCode(activeServer)
    if (ksOn) return "KS"
    return "off"
  }

  readonly property string tooltipText: {
    var l = []
    if (activeServer) {
      l.push("Connected  " + stripFlag(activeServer.label))
      if (pub && pub.ok && pub.ip) l.push("Exit IP  " + pub.ip + (pub.city ? "  ·  " + pub.city : ""))
    } else if (strandedByKillswitch) {
      l.push("Kill switch ON — no tunnel — traffic blocked")
    } else if (ksOn) {
      l.push("Kill switch armed, VPN off")
    } else {
      l.push("VPN off")
    }
    if (!integration) l.push("System integration not set up")
    l.push("")
    l.push("Left click: panel   ·   Right click: toggle " + (lastConnectedId ? "last tunnel" : "VPN"))
    return l.join("\n")
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight
  readonly property real openPanelIndicatorWidth: Math.round(button.implicitWidth * 0.5)

  // ---------------------------------------------------------------- helpers
  function shortCode(s) {
    if (!s) return "on"
    if (s.cc && String(s.cc).length === 2) return String(s.cc).toUpperCase()
    return stripFlag(s.label).split(/\s+/)[0].slice(0, 4)
  }
  function stripFlag(s) {
    return String(s || "").replace(/[\u{1F1E6}-\u{1F1FF}\u{1F310}]/gu, "").trim()
  }
  function ageText(sec) {
    var n = Number(sec)
    if (!isFinite(n) || n <= 0) return ""
    if (n < 90) return n + "s ago"
    if (n < 5400) return Math.round(n / 60) + "m ago"
    return Math.round(n / 3600) + "h ago"
  }

  function refresh() {
    if (statusProc.running) return
    statusProc.command = ["bash", root.script, "status"]
    statusProc.running = true
  }
  function refreshIp() {
    if (!root.cfgIpLookup || ipProc.running) return
    ipProc.command = ["bash", root.script, "refresh-ip"]
    ipProc.running = true
  }

  function runAction(args, tag) {
    if (root.busyAction || actionProc.running) return
    root.busyAction = tag
    root.lastError = ""
    actionProc.command = ["bash", root.script].concat(args)
    actionProc.running = true
  }

  function connectServer(id) { root.runAction(["connect", id], "connect:" + id) }
  function disconnectAll()   { root.runAction(["disconnect"], "disconnect") }
  function forgetServer(id)  { root.runAction(["forget", id], "forget:" + id) }
  function importInbox()     { root.runAction(["import-all"], "import") }
  function toggleKillswitch() { root.runAction(["killswitch", root.ksOn ? "off" : "on"], "killswitch") }
  function runSetup()        { root.runAction(["setup"], "setup") }

  function rightClickToggle() {
    if (activeServer) { disconnectAll(); return }
    if (lastConnectedId) { connectServer(lastConnectedId); return }
    if (servers.length === 1) connectServer(servers[0].id)
  }

  function parseStatus(text) {
    try {
      var d = JSON.parse(text)
      if (d && typeof d === "object") {
        root.st = d
        if (root.activeId) root.lastConnectedId = root.activeId
      }
    } catch (e) { /* keep last good */ }
  }

  function parseAction(text) {
    var d = null
    try { d = JSON.parse(text) } catch (e) {}
    if (d && d.ok === false && d.error) root.lastError = String(d.error)
    root.busyAction = ""
    root.refresh()
  }

  Component.onCompleted: refresh()
  onOpenedChanged: if (opened) { refresh(); refreshIp() }

  Timer {
    interval: root.opened ? 2000 : 5000
    running: true; repeat: true; triggeredOnStart: true
    onTriggered: root.refresh()
  }
  Timer {   // refresh public IP occasionally while the panel is open
    interval: 300000
    running: root.opened && root.cfgIpLookup; repeat: true
    onTriggered: root.refreshIp()
  }

  Process {
    id: statusProc
    environment: root.backendEnv
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.parseStatus(text) }
  }
  Process {
    id: actionProc
    environment: root.backendEnv
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.parseAction(text) }
    stderr: StdioCollector { waitForEnd: true }
  }
  Process { id: ipProc; environment: root.backendEnv }

  // ================================================================ bar button
  Item {
    id: button
    anchors.fill: parent
    implicitWidth: readout.implicitWidth + Style.space(17)
    implicitHeight: root.bar ? root.bar.barSize : Style.bar.sizeHorizontal

    Row {
      id: readout
      anchors.centerIn: parent
      spacing: Style.space(5)

      Text {
        text: root.barGlyph
        color: root.barColor
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.body
        anchors.verticalCenter: parent.verticalCenter
        // subtle pulse when armed-but-stranded
        SequentialAnimation on opacity {
          running: root.strandedByKillswitch
          loops: Animation.Infinite
          NumberAnimation { to: 0.35; duration: 700; easing.type: Easing.InOutQuad }
          NumberAnimation { to: 1.0;  duration: 700; easing.type: Easing.InOutQuad }
        }
      }
      Text {
        text: root.barLabel
        color: root.barColor
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.body
        font.bold: root.activeServer !== null || root.strandedByKillswitch
        anchors.verticalCenter: parent.verticalCenter
      }
      BusyIndicator {
        visible: root.busyAction !== ""
        running: visible
        implicitWidth: Style.font.body; implicitHeight: Style.font.body
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: function (mouse) {
        if (mouse.button === Qt.LeftButton) root.toggle()
        else root.rightClickToggle()
      }
      onEntered: if (root.bar) root.bar.showTooltip(button, root.tooltipText)
      onExited: if (root.bar) root.bar.hideTooltip(button)
    }
  }

  // ================================================================ panel
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(col.implicitHeight, Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function (d) { root.switchPanel(d) }

      ScrollView {
        id: scroller
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: col.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff

        Column {
          id: col
          width: scroller.availableWidth
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: "VPN"
            meta: {
              if (root.activeServer) {
                if (root.pub && root.pub.ok && root.pub.ip)
                  return root.pub.ip + (root.pub.city ? "  ·  " + root.pub.city : "")
                return "connected"
              }
              if (root.strandedByKillswitch) return "kill switch on — offline"
              return "not connected"
            }
            foreground: root.fg
            iconComponent: Component {
              Text {
                text: ""
                color: root.activeServer ? "#3fb950" : root.fg
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.display
              }
            }
          }

          // -------------------------------------------------- error strip
          Rectangle {
            width: parent.width
            visible: root.lastError !== ""
            implicitHeight: errText.implicitHeight + Style.space(12)
            radius: Style.space(4)
            color: Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.14)
            border.width: 1
            border.color: Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.4)
            Text {
              id: errText
              anchors { fill: parent; margins: Style.space(6) }
              textFormat: Text.PlainText
              text: root.lastError
              wrapMode: Text.WordWrap
              color: root.fg
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
            }
            MouseArea { anchors.fill: parent; onClicked: root.lastError = "" }
          }

          // -------------------------------------------------- setup prompt
          Column {
            width: parent.width
            visible: !root.integration
            spacing: Style.space(6)
            PanelSeparator { width: parent.width; foreground: root.fg }
            SectionHead { title: "SYSTEM INTEGRATION" }
            Text {
              width: parent.width
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              text: "The kill switch needs a small root helper (nftables). This runs "
                    + "install-system.sh once via a polkit prompt. Connecting to a VPN "
                    + "works without it."
              color: Qt.darker(root.fg, 1.3)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
            }
            ActionButton {
              width: parent.width
              label: root.busyAction === "setup" ? "Authorising…" : "Set up kill switch"
              enabled: root.busyAction === ""
              accent: true
              onTriggered: root.runSetup()
            }
          }

          // -------------------------------------------------- kill switch
          Column {
            width: parent.width
            visible: root.integration
            spacing: Style.space(6)
            PanelSeparator { width: parent.width; foreground: root.fg }
            SectionHead {
              title: "KILL SWITCH"
              detail: root.ksOn ? (root.strandedByKillswitch ? "blocking all traffic" : "armed") : "off"
            }
            Row {
              width: parent.width
              spacing: Style.space(10)
              ActionButton {
                width: (parent.width - Style.space(10)) / 2
                label: root.busyAction === "killswitch"
                       ? "…" : (root.ksOn ? "Turn OFF" : "Turn ON")
                enabled: root.busyAction === ""
                danger: root.ksOn
                accent: !root.ksOn
                onTriggered: root.toggleKillswitch()
              }
              Text {
                width: (parent.width - Style.space(10)) / 2
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                wrapMode: Text.WordWrap
                text: root.ksOn
                      ? "Fail-closed: only the tunnel, LAN and the WireGuard handshake are allowed."
                      : "When on, all traffic is blocked unless it goes through a tunnel."
                color: Qt.darker(root.fg, 1.35)
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.caption
              }
            }
            Text {
              width: parent.width
              visible: root.strandedByKillswitch
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              text: "⚠  Kill switch is on and no tunnel is connected — you have no internet "
                    + "except on the local network. Connect a server below or turn it off."
              color: Color.urgent
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
            }
          }

          // -------------------------------------------------- servers
          Column {
            width: parent.width
            spacing: Style.space(6)
            PanelSeparator { width: parent.width; foreground: root.fg }
            SectionHead {
              title: "TUNNELS"
              detail: root.servers.length + (root.servers.length === 1 ? " server" : " servers")
            }

            Text {
              width: parent.width
              visible: root.servers.length === 0
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              text: "No tunnels yet. Drop a WireGuard .conf into the inbox below."
              color: Qt.darker(root.fg, 1.35)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
            }

            Repeater {
              model: root.servers
              Rectangle {
                id: row
                required property var modelData
                width: col.width
                implicitHeight: Style.space(38)
                radius: Style.space(4)
                readonly property bool isActive: modelData.id === root.activeId
                readonly property bool isBusy: root.busyAction === ("connect:" + modelData.id)
                                               || root.busyAction === ("forget:" + modelData.id)
                color: isActive ? Qt.rgba(0.25, 0.72, 0.31, 0.16)
                       : hov.hovered ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.07)
                       : "transparent"
                border.width: isActive ? 1 : 0
                border.color: Qt.rgba(0.25, 0.72, 0.31, 0.5)

                HoverHandler { id: hov }

                Row {
                  anchors { left: parent.left; right: delBtn.left; verticalCenter: parent.verticalCenter
                            leftMargin: Style.space(8); rightMargin: Style.space(6) }
                  spacing: Style.space(8)
                  Rectangle {
                    width: Style.space(7); height: Style.space(7); radius: width / 2
                    anchors.verticalCenter: parent.verticalCenter
                    color: row.modelData.state === "connected" ? "#3fb950"
                         : row.modelData.state === "activating" ? "#d29922"
                         : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.3)
                  }
                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    text: row.modelData.label
                    color: root.fg
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.body
                  }
                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    text: row.isBusy ? "…"
                          : row.modelData.state === "connected" ? "connected"
                          : row.modelData.state === "activating" ? "connecting…"
                          : row.modelData.endpoint_host
                    color: Qt.darker(root.fg, 1.4)
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.caption
                  }
                }

                MouseArea {
                  anchors { left: parent.left; right: delBtn.left; top: parent.top; bottom: parent.bottom }
                  cursorShape: Qt.PointingHandCursor
                  enabled: root.busyAction === ""
                  onClicked: row.isActive ? root.disconnectAll() : root.connectServer(row.modelData.id)
                }

                // delete
                Text {
                  id: delBtn
                  anchors { right: parent.right; verticalCenter: parent.verticalCenter; rightMargin: Style.space(8) }
                  text: confirmDel ? "delete?" : ""   // nf-fa-trash
                  property bool confirmDel: false
                  color: confirmDel ? Color.urgent : Qt.darker(root.fg, 1.5)
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: confirmDel ? Style.font.caption : Style.font.body
                  MouseArea {
                    anchors.fill: parent; anchors.margins: -Style.space(4)
                    cursorShape: Qt.PointingHandCursor
                    enabled: root.busyAction === ""
                    onClicked: {
                      if (delBtn.confirmDel) { delBtn.confirmDel = false; root.forgetServer(row.modelData.id) }
                      else { delBtn.confirmDel = true; delReset.restart() }
                    }
                  }
                  Timer { id: delReset; interval: 3000; onTriggered: delBtn.confirmDel = false }
                }
              }
            }
          }

          // -------------------------------------------------- inbox
          Column {
            width: parent.width
            spacing: Style.space(6)
            PanelSeparator { width: parent.width; foreground: root.fg }
            SectionHead {
              title: "INBOX"
              detail: root.inboxCount > 0 ? root.inboxCount + " waiting" : "empty"
            }
            Text {
              width: parent.width
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              text: "Drop WireGuard .conf files into  ~/.config/omarchy/vpn/inbox/  then import."
              color: Qt.darker(root.fg, 1.35)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
            }
            ActionButton {
              width: parent.width
              visible: root.inboxCount > 0
              label: root.busyAction === "import" ? "Importing…"
                     : "Import " + root.inboxCount + (root.inboxCount === 1 ? " config" : " configs")
              enabled: root.busyAction === ""
              accent: true
              onTriggered: root.importInbox()
            }
          }

          Item { width: parent.width; height: Style.space(4) }
        }
      }
    }
  }

  // ---------------------------------------------------------------- components
  component SectionHead: Item {
    property string title: ""
    property string detail: ""
    width: parent ? parent.width : 0
    implicitHeight: Math.max(th.implicitHeight, dh.implicitHeight)
    PanelSectionHeader {
      id: th
      text: parent.title
      foreground: root.fg
      fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
      fontSize: Style.font.bodySmall
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
    }
    Text {
      id: dh
      textFormat: Text.PlainText
      text: parent.detail
      visible: text !== ""
      color: Qt.darker(root.fg, 1.35)
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: true
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  component ActionButton: Rectangle {
    property string label: ""
    property bool accent: false
    property bool danger: false
    property bool enabled: true
    signal triggered()
    implicitHeight: Style.space(30)
    radius: Style.space(4)
    opacity: enabled ? 1 : 0.45
    color: danger ? Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, ah.hovered ? 0.28 : 0.16)
         : accent ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, ah.hovered ? 0.30 : 0.18)
         : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, ah.hovered ? 0.14 : 0.08)
    border.width: 1
    border.color: danger ? Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.45)
                : accent ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.45)
                : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.18)
    HoverHandler { id: ah }
    Text {
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: parent.label
      color: parent.danger ? Color.urgent : root.fg
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: true
    }
    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      enabled: parent.enabled
      onClicked: parent.triggered()
    }
  }
}
