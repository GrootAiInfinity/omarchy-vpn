import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

// VPN bar module.
//   Left click  - open the panel (tunnels, kill switch, import)
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
  // Pre-1.2.0 this was an `autoConnect` enum carrying its own "Off" member and
  // covering the tunnel only. It is still read as the seed for the new option
  // so an existing "On login" / "At boot" setup survives the update untouched.
  readonly property string cfgLegacyAutoConnect: String(setting("autoConnect", ""))
  // The one switch for everything that outlives a reboot: which tunnel comes
  // back, and whether the kill switch is still armed when the machine starts.
  readonly property bool cfgRemember: {
    var v = settings ? settings["rememberSession"] : undefined
    if (v === undefined || v === null)
      return cfgLegacyAutoConnect !== "" && cfgLegacyAutoConnect !== "Off"
    return v === true || String(v) === "true"
  }
  // How the tunnel comes back. Only consulted while cfgRemember is on, so it
  // has no "off" member of its own.
  readonly property string cfgRestoreMethod:
    setting("restoreMethod", cfgLegacyAutoConnect === "On login" ? "On login" : "At boot")
  readonly property var backendEnv: ({
    "OMARCHY_VPN_PUBLICIPLOOKUP": cfgIpLookup ? "true" : "false",
    "OMARCHY_VPN_PUBLICIPURL": cfgIpUrl,
    "OMARCHY_VPN_KEEPORIGINALCONFIGS": cfgKeepConf ? "true" : "false",
    "OMARCHY_VPN_REMEMBERSESSION": cfgRemember ? "true" : "false",
    "OMARCHY_VPN_RESTOREMETHOD": cfgRestoreMethod
  })

  // ---- state ----
  property var st: ({})
  property string busyAction: ""      // non-empty while a mutation is running
  property string lastError: ""
  property string lastNotice: ""      // transient "Imported 3 tunnels" line
  // Seeded from the backend so a right-click still offers the last tunnel after
  // the shell (or the machine) has restarted.
  property string lastConnectedId: ""
  property string filterText: ""      // tunnel-list search box

  readonly property var servers: st.servers || []
  // The list gets long once a provider's whole server pack is imported, so it
  // is searchable by name, endpoint host or id.
  readonly property var filteredServers: {
    var q = filterText.trim().toLowerCase()
    if (q === "") return servers
    var out = []
    for (var i = 0; i < servers.length; i++) {
      var s = servers[i]
      var hay = (stripFlag(s.label) + " " + (s.endpoint_host || "") + " " + s.id).toLowerCase()
      if (hay.indexOf(q) !== -1) out.push(s)
    }
    return out
  }
  readonly property var activeId: st.active_id || null
  readonly property var activeServer: {
    for (var i = 0; i < servers.length; i++)
      if (servers[i].id === activeId) return servers[i]
    return null
  }
  readonly property bool integration: st.integration === true
  // Installed root helper differs from the one shipped in this plugin folder.
  readonly property bool helperStale: st.helper_stale === true
  readonly property string ksState: st.killswitch || "unknown"   // on | off | unknown
  readonly property bool ksOn: ksState === "on"
  readonly property bool ksPersisted: st.killswitch_persisted === true
  readonly property int inboxCount: Number(st.inbox_count) || 0

  // "off" | "login" | "boot", normalised by the backend from the settings above.
  readonly property string autoMode: st.autoconnect || "off"
  readonly property bool autoOn: root.cfgRemember
  // The tunnel that will come back on its own. Cleared by an explicit disconnect.
  readonly property var autostartId: st.autostart_id || null
  readonly property var autostartServer: {
    for (var i = 0; i < servers.length; i++)
      if (servers[i].id === autostartId) return servers[i]
    return null
  }
  // The kill switch is enabled but its rules are not loaded — the state a
  // missed boot leaves behind.
  readonly property bool ksPending: ksPersisted && ksState !== "on"
  readonly property var pub: st.public || ({})

  // kill switch is armed but nothing is carrying traffic -> you are offline
  readonly property bool leakedOpen: false
  readonly property bool strandedByKillswitch: ksOn && !activeServer

  readonly property color fg: Color.popups.text

  // ---- bar glyph state ----
  readonly property string barGlyph: "" // nf-fa-shield
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
    if (cfgRemember)
      l.push("After a reboot  " + (autostartServer ? stripFlag(autostartServer.label) : "nothing armed")
             + (autoMode === "boot" ? "  (at boot)" : "  (on login)")
             + (ksPersisted ? "  ·  kill switch" : ""))
    else if (activeServer || ksOn)
      l.push("After a reboot  starts clean")
    if (!integration) l.push("System integration not set up")
    else if (helperStale) l.push("System files are out of date — re-run Setup")
    else if (ksPending) l.push("Kill switch enabled but not loaded — re-run Setup")
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
    root.lastNotice = ""
    actionProc.command = ["bash", root.script].concat(args)
    actionProc.running = true
  }

  function connectServer(id) { root.runAction(["connect", id], "connect:" + id) }
  function disconnectAll()   { root.runAction(["disconnect"], "disconnect") }
  function forgetServer(id)  { root.runAction(["forget", id], "forget:" + id) }
  function importInbox()     { root.runAction(["import-all"], "import") }
  function pickConfig()      { root.runAction(["pick-import"], "import") }
  function toggleKillswitch() { root.runAction(["killswitch", root.ksOn ? "off" : "on"], "killswitch") }
  function runSetup()        { root.runAction(["setup"], "setup") }
  // Reconciling is the only way a change to the reboot option reaches the
  // things that actually implement it: NetworkManager's autoconnect flags and
  // the kill switch's boot-time flag. Only the second can need a polkit prompt,
  // and only when the switch is on and its retention actually has to change.
  function applySession()    { root.runAction(["apply-session"], "session") }

  // The panel's option button writes straight into this widget's shell.json
  // entry — the same place the settings UI writes — so the choice is still
  // there after a shell restart. Applied locally first so the panel redraws on
  // the click itself; the write comes back through the bar as the same value.
  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    for (var key in values) entry[key] = values[key]
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  // A reconcile that needs root can be refused or cancelled. `apply-session`
  // is all-or-nothing, so when that happens the honest thing is to put the
  // setting back rather than leave the panel claiming a state the machine is
  // not in — that contradiction is what a second "fix this" button would be
  // papering over.
  property bool rememberReverting: false
  property bool rememberPrev: false
  function setRemember(on) {
    if (on === root.cfgRemember) return
    root.rememberPrev = root.cfgRemember
    // Pin the method down at the same time: leaving it implicit would mean a
    // later change to the legacy key silently moved it.
    root.persistSettings({ rememberSession: on, restoreMethod: root.cfgRestoreMethod })
  }
  function revertRemember() {
    root.rememberReverting = true
    root.persistSettings({ rememberSession: root.rememberPrev, restoreMethod: root.cfgRestoreMethod })
  }

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
        else if (!root.lastConnectedId && d.last_id) root.lastConnectedId = String(d.last_id)
      }
    } catch (e) { /* keep last good */ }
  }

  // Import and delete both report on a batch now, so say what actually landed
  // and give a reason per rejected file instead of one blunt error.
  function parseAction(text) {
    var d = null
    try { d = JSON.parse(text) } catch (e) {}
    if (d && d.cancelled) {
      // file chooser dismissed — nothing to report
    } else if (d && d.imported !== undefined) {
      var parts = []
      if (d.imported > 0) parts.push("Imported " + d.imported + (d.imported === 1 ? " tunnel" : " tunnels"))
      if (d.failed > 0) parts.push(d.failed + (d.failed === 1 ? " file rejected" : " files rejected"))
      root.lastNotice = parts.length ? parts.join("  ·  ") : "Nothing to import"
      if (d.errors && d.errors.length) {
        var lines = []
        for (var i = 0; i < d.errors.length; i++)
          lines.push(String(d.errors[i].name) + " — " + String(d.errors[i].error))
        root.lastError = lines.join("\n")
      }
      if (d.imported > 0) noticeTimer.restart()
    } else if (d && d.ok === false && d.error) {
      root.lastError = String(d.error)
      if (root.busyAction === "session") root.revertRemember()
    } else if (d && d.forgot) {
      root.lastNotice = "Deleted " + root.stripFlag(d.forgot)
      noticeTimer.restart()
    } else if (d && d.killswitch_change) {
      root.lastNotice = d.killswitch_change === "persist"
        ? "The kill switch will now survive reboots"
        : "The kill switch will no longer survive reboots"
      noticeTimer.restart()
    }
    // Advisory, not a failure: the change went through, but not the way the
    // current setting asks for (an out-of-date root helper).
    if (d && d.ok !== false && d.note) root.lastError = String(d.note)
    root.busyAction = ""
    root.refresh()
  }

  // Run once per shell start, and again if the setting is turned on later.
  property bool autoStartDone: false
  function maybeAutoConnect() {
    if (root.autoStartDone || autoProc.running) return
    if (!root.cfgRemember) return
    root.autoStartDone = true
    autoProc.command = ["bash", root.script, "autoconnect"]
    autoProc.running = true
  }

  // A settings change has to reach NetworkManager and the kill switch flag, and
  // switching restore *on* should take effect now rather than at the next login.
  onCfgRememberChanged: {
    if (!root.completed) return
    if (root.rememberReverting) { root.rememberReverting = false; return }
    root.applySession()
    if (!root.cfgRemember) root.autoStartDone = false
    else Qt.callLater(root.maybeAutoConnect)
  }
  onCfgRestoreMethodChanged: if (root.completed && root.cfgRemember) root.applySession()

  property bool completed: false
  Component.onCompleted: { refresh(); completed = true }
  onOpenedChanged: if (opened) { refresh(); refreshIp() }

  Timer { id: noticeTimer; interval: 6000; onTriggered: root.lastNotice = "" }

  Timer {
    interval: root.opened ? 2000 : 5000
    running: true; repeat: true; triggeredOnStart: true
    onTriggered: root.refresh()
  }
  // Give the network a moment to come up before asking for a tunnel; at login
  // wifi is often still associating.
  Timer {
    interval: 4000
    running: true; repeat: false
    onTriggered: root.maybeAutoConnect()
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
  // Deliberately not actionProc: bringing a tunnel up and proving it carries
  // traffic can take ~20s, and that must not grey out the whole panel.
  Process {
    id: autoProc
    environment: root.backendEnv
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var d = null
        try { d = JSON.parse(text) } catch (e) {}
        if (d && d.ok === false && d.error) root.lastError = String(d.error)
        root.refresh()
      }
    }
  }

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
      // let the search box receive j/k/h/l/x/space instead of the panel cursor
      blocked: filterField.activeFocus
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

          // -------------------------------------------------- notice strip
          Rectangle {
            width: parent.width
            visible: root.lastNotice !== ""
            implicitHeight: noticeText.implicitHeight + Style.space(12)
            radius: Style.space(4)
            color: Qt.rgba(0.25, 0.72, 0.31, 0.14)
            border.width: 1
            border.color: Qt.rgba(0.25, 0.72, 0.31, 0.4)
            Text {
              id: noticeText
              anchors { fill: parent; margins: Style.space(6) }
              textFormat: Text.PlainText
              text: root.lastNotice
              wrapMode: Text.WordWrap
              color: root.fg
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
            }
            MouseArea { anchors.fill: parent; onClicked: root.lastNotice = "" }
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
            visible: !root.integration || root.helperStale
            spacing: Style.space(6)
            PanelSeparator { width: parent.width; foreground: root.fg }
            SectionHead { title: "SYSTEM INTEGRATION" }
            Text {
              width: parent.width
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              text: root.helperStale
                    ? "The plugin has been updated but its root-owned system files "
                      + "(helper, systemd unit, dispatcher hook) are still the old ones "
                      + "— a plugin update cannot replace them on its own. Re-run the "
                      + "installer to pick them up."
                    : "The kill switch needs a small root helper (nftables). This runs "
                      + "install-system.sh once via a polkit prompt. Connecting to a VPN "
                      + "works without it."
              color: Qt.darker(root.fg, 1.3)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
            }
            ActionButton {
              width: parent.width
              label: root.busyAction === "setup" ? "Authorising…"
                     : root.helperStale ? "Update system integration"
                     : "Set up kill switch"
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
              detail: root.ksPending ? "not loaded" : root.ksOn ? "armed" : "off"
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
                text: root.ksOn ? "Only the tunnel, LAN and the WireGuard handshake get out."
                                : "Blocks anything not going through a tunnel."
                color: Qt.darker(root.fg, 1.35)
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.caption
              }
            }
            // Only the two states the user has to do something about. What the
            // switch does at the next boot is the section below's business.
            Text {
              width: parent.width
              visible: root.strandedByKillswitch
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              text: "⚠  No tunnel connected — you are offline except on the local network."
              color: Color.urgent
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
            }
            Text {
              width: parent.width
              visible: root.ksPending
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              text: "⚠  The rules are not loaded, so nothing is being filtered. Re-run Setup above."
              color: Color.urgent
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
            }
          }

          // -------------------------------------------------- after a reboot
          Column {
            width: parent.width
            spacing: Style.space(6)
            PanelSeparator { width: parent.width; foreground: root.fg }
            SectionHead {
              title: "AFTER A REBOOT"
              detail: !root.cfgRemember ? "starts clean"
                      : root.cfgRestoreMethod === "On login" ? "restores on login"
                      : "restores at boot"
            }
            Row {
              width: parent.width
              spacing: Style.space(10)
              ActionButton {
                width: (parent.width - Style.space(10)) / 2
                label: root.busyAction === "session"
                       ? "…" : (root.cfgRemember ? "Start clean" : "Remember session")
                enabled: root.busyAction === ""
                accent: !root.cfgRemember
                onTriggered: root.setRemember(!root.cfgRemember)
              }
              // Name what actually comes back. Describing the setting in the
              // abstract would just make this section something to read twice.
              Text {
                width: (parent.width - Style.space(10)) / 2
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                wrapMode: Text.WordWrap
                text: {
                  if (!root.cfgRemember) return "Starts with no tunnel and the kill switch off."
                  var who = root.autostartServer ? root.stripFlag(root.autostartServer.label) : ""
                  var ks = root.ksPersisted
                  if (who && ks) return who + " and the kill switch come back."
                  if (who) return who + " comes back."
                  if (ks) return "The kill switch comes back — no tunnel armed yet."
                  return "Nothing is running to come back yet."
                }
                color: Qt.darker(root.fg, 1.35)
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.caption
              }
            }
          }

          // -------------------------------------------------- servers
          Column {
            width: parent.width
            spacing: Style.space(6)
            PanelSeparator { width: parent.width; foreground: root.fg }
            SectionHead {
              title: "TUNNELS"
              detail: root.filterText.trim() !== ""
                      ? root.filteredServers.length + " of " + root.servers.length
                      : root.servers.length + (root.servers.length === 1 ? " server" : " servers")
            }

            Text {
              width: parent.width
              visible: root.servers.length === 0
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              text: "No tunnels yet. Import one or more WireGuard .conf files below."
              color: Qt.darker(root.fg, 1.35)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
            }

            // Only worth the space once a provider's server pack is in.
            TextField {
              id: filterField
              width: parent.width
              visible: root.servers.length >= 6
              placeholderText: "Search tunnels…"
              foreground: root.fg
              // one-way, field -> root: binding root.filterText back into `text`
              // would be torn down the first time anything assigns to `text`.
              onTextChanged: root.filterText = text
              onVisibleChanged: if (!visible) text = ""   // a hidden box must not keep filtering
              Keys.onEscapePressed: function (e) {
                if (text !== "") text = ""
                else keyCatcher.forceActiveFocus()
                e.accepted = true
              }
            }

            Text {
              width: parent.width
              visible: root.servers.length > 0 && root.filteredServers.length === 0
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              text: "No tunnel matches that search."
              color: Qt.darker(root.fg, 1.35)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
            }

            Repeater {
              model: root.filteredServers
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
                  Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: root.autoOn && row.modelData.id === root.autostartId
                    implicitWidth: autoTag.implicitWidth + Style.space(8)
                    implicitHeight: autoTag.implicitHeight + Style.space(3)
                    radius: Style.space(3)
                    color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.18)
                    border.width: 1
                    border.color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.45)
                    Text {
                      id: autoTag
                      anchors.centerIn: parent
                      textFormat: Text.PlainText
                      text: "AUTO"
                      color: root.fg
                      font.family: root.bar ? root.bar.fontFamily : Style.font.family
                      font.pixelSize: Style.font.caption
                      font.bold: true
                    }
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
                  text: confirmDel ? "delete?" : ""   // nf-fa-trash
                  property bool confirmDel: false
                  // Keep a real hit target even if the glyph ever goes missing
                  // from the font: an empty Text is zero-width and unclickable.
                  width: Math.max(implicitWidth, Style.space(12))
                  horizontalAlignment: Text.AlignRight
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

          // -------------------------------------------------- add a tunnel
          Column {
            width: parent.width
            spacing: Style.space(6)
            PanelSeparator { width: parent.width; foreground: root.fg }
            SectionHead {
              title: "ADD A TUNNEL"
              detail: root.inboxCount > 0 ? root.inboxCount + " in inbox" : ""
            }
            Text {
              width: parent.width
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              text: "Import WireGuard .conf files from your provider (Surfshark, Mullvad, "
                    + "ProtonVPN, self-hosted) — pick as many as you like at once with "
                    + "ctrl/shift-click. You can also drop files into "
                    + "~/.config/omarchy/vpn/inbox/ and import them from here."
              color: Qt.darker(root.fg, 1.35)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
            }
            ActionButton {
              width: parent.width
              label: root.busyAction === "import" ? "Importing…" : "Import .conf files…"
              enabled: root.busyAction === ""
              accent: true
              onTriggered: root.pickConfig()
            }
            ActionButton {
              width: parent.width
              visible: root.inboxCount > 0
              label: root.busyAction === "import" ? "Importing…"
                     : "Import " + root.inboxCount + (root.inboxCount === 1 ? " file from inbox" : " files from inbox")
              enabled: root.busyAction === ""
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
