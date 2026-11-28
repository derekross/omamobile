// SPDX-License-Identifier: MIT
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import qs.Commons as Commons
import "Readable.js" as Readable

// The mobile network card a tap on the bar's signal opens, built from
// Omarchy's own panel parts (Panel, KeyboardPanel, ToggleSwitch and the
// label/value rows of its power and network cards), since Omarchy has no
// cellular card of its own. It reads omamobile-sitd's public state, and its
// switch turns the cellular radio on and off with omamobile-sit, as the Wi-Fi
// card's switch does Wi-Fi (mobile data stays on its quick-settings tile).
Panel {
  id: root
  moduleName: "omamobile.cellular"
  ipcTarget: "omamobile.cellular"

  property string glyph: ""
  property var modem: ({})
  property bool dataOn: false
  // The data service is wanted but not up: systemd is starting it, or
  // starting it again after it failed (a reconnect that brought no IPv4
  // address, say). That is data on and not connected, never "off".
  property bool dataTrying: false
  // The radio switch: the state sitd publishes lags the command by a few
  // seconds, so the switch shows what was asked until the state agrees.
  property bool radioBusy: false
  property bool radioWant: true
  property int radioWaits: 0

  readonly property bool present: !!modem && modem.present === true
  readonly property bool radioOff: present && modem.radio === "off"
  readonly property bool registered: present && (modem.registration === "home" || modem.registration === "roaming")
  readonly property int signal: registered ? Math.max(0, Math.min(100, Number(modem.signal) || 0)) : 0

  // sitd gives the network's name when the network sends one; otherwise the
  // name comes from mobile-broadband-provider-info by the network code
  // (carrier-name.py, beside this file).
  property string lookedUpName: ""
  property string lookedUpCode: ""
  // The data link's own details (cell-stats.sh), while the card is open
  property var link: ({})
  // Omarchy's DNS setting (the Wi-Fi card's pills): it covers cellular too
  property string dnsProvider: ""
  // As the Wi-Fi card: rates from the change between two samples, ping as the
  // average of the last 5, packet loss over the last 24
  property var lastSample: null
  property real downloadRate: 0
  property real uploadRate: 0
  property var pingSamples: []
  readonly property bool hasPing: pingSamples.length > 0
  readonly property real pingLatency: {
    var got = pingSamples.slice(-5).filter(function(v) { return v !== null })
    if (got.length === 0) return -1
    return got.reduce(function(a, b) { return a + b }, 0) / got.length
  }
  readonly property int packetLoss: {
    if (pingSamples.length === 0) return 0
    var lost = pingSamples.filter(function(v) { return v === null }).length
    return Math.round(lost / pingSamples.length * 100)
  }
  onLinkChanged: {
    var now = Date.now()
    if (!linkUp) { lastSample = null; downloadRate = 0; uploadRate = 0; pingSamples = []; return }
    if (lastSample && lastSample.iface === link.iface && now > lastSample.at) {
      var dt = (now - lastSample.at) / 1000
      downloadRate = Math.max(0, (link.rx - lastSample.rx) / dt)
      uploadRate = Math.max(0, (link.tx - lastSample.tx) / dt)
    }
    if (lastSample && lastSample.iface !== link.iface) pingSamples = []
    lastSample = { iface: link.iface, rx: link.rx, tx: link.tx, at: now }
    var p = Number(link.ping)
    pingSamples = pingSamples.concat([p >= 0 ? p : null]).slice(-24)
  }
  readonly property bool linkUp: !!link && !!link.iface
  readonly property string statsScript: String(Qt.resolvedUrl("cell-stats.sh")).replace(/^file:\/\//, "")
  readonly property string carrierScript: String(Qt.resolvedUrl("carrier-name.py")).replace(/^file:\/\//, "")

  function title() {
    if (!present) return "Cellular Network"
    if (modem.operator_name) return modem.operator_name
    if (lookedUpName && lookedUpCode === modem.plmn) return lookedUpName
    return "Cellular Network"
  }

  onModemChanged: {
    var code = modem && modem.plmn ? String(modem.plmn) : ""
    if (!modem.operator_name && /^[0-9]{5,6}$/.test(code) && code !== lookedUpCode && !nameProc.running) {
      nameProc.command = ["python3", "-I", root.carrierScript, code]
      nameProc.running = true
    }
  }

  Process {
    id: nameProc
    stdout: StdioCollector {
      onStreamFinished: {
        var parts = text.trim().split("\t")
        if (parts.length === 2) { root.lookedUpCode = parts[0]; root.lookedUpName = parts[1] }
      }
    }
  }

  function status() {
    if (!present) return "No modem"
    var sim = modem.sim || {}
    if (sim.state === "absent") return "No SIM"
    if (sim.state === "locked" || sim.state === "pin") return "SIM locked"
    // The switch turns everything cellular off, so the card says so from the
    // tap on: while the radio goes down the data link is already gone and the
    // network still reads registered, which read "Mobile data off".
    if (radioOff || (radioBusy && !radioWant)) return "Cellular off"
    if (radioBusy && radioWant) return "Searching"
    if (!registered) return "Searching"
    // As Omarchy's Wi-Fi card says "Not connected" with its switch off.
    if (!dataOn && dataTrying) return "No data connection"
    if (!dataOn) return modem.registration === "roaming" ? "Roaming · cellular data off" : "Cellular data off"
    return modem.registration === "roaming" ? "Roaming" : "Connected"
  }

  function yesNo(value) { return value === true ? "Yes" : (value === false ? "No" : "--") }

  function refresh() {
    if (!stateFile.running) stateFile.running = true
    if (!dataProc.running) dataProc.running = true
    if (root.opened && !statsProc.running) statsProc.running = true
  }

  function setRadio(on) {
    if (radioBusy) return
    radioBusy = true
    radioWant = on
    radioWaits = 0
    radioSet.command = ["omamobile-sit", "radio", on ? "on" : "off"]
    radioSet.running = true
  }

  onOpenedChanged: {
    if (opened) { refresh(); if (!dnsProc.running) dnsProc.running = true; return }
    lastSample = null; downloadRate = 0; uploadRate = 0; pingSamples = []
  }

  Process {
    id: stateFile
    command: ["cat", Quickshell.env("OMAMOBILE_SIT_STATE") || "/run/omamobile-sit/state.json"]
    stdout: StdioCollector {
      onStreamFinished: {
        try { root.modem = JSON.parse(text).modem || {} } catch (e) { root.modem = {} }
      }
    }
  }

  Process {
    id: statsProc
    command: ["bash", root.statsScript]
    stdout: StdioCollector {
      onStreamFinished: {
        try { root.link = text.trim() ? JSON.parse(text) : ({}) } catch (e) { root.link = ({}) }
      }
    }
  }

  // What the Wi-Fi card's DNS pills read: "omarchy-dns" alone names the choice
  Process {
    id: dnsProc
    command: ["omarchy-dns"]
    stdout: StdioCollector {
      onStreamFinished: root.dnsProvider = String(text || "").trim().split("\n")[0]
    }
  }

  // The DNS line: who answers lookups on cellular, and where that is chosen.
  // With DHCP chosen the network's own servers answer, here the carrier's.
  function dnsText() {
    if (dnsProvider === "") return "--"
    return (dnsProvider === "DHCP" ? "The carrier's" : dnsProvider) + ", set on Wi-Fi card"
  }

  // The Wi-Fi card's own formats (Omarchy's network Model.js)
  function formatBytes(bytes) {
    var f = Commons.I18n.formatNumber
    var n = Number(bytes)
    if (!isFinite(n) || n < 0) n = 0
    if (n < 1024) return f(Math.round(n)) + " B"
    if (n < 1024 * 1024) return f(n / 1024, 1) + " KB"
    if (n < 1024 * 1024 * 1024) return f(n / (1024 * 1024), 1) + " MB"
    return f(n / (1024 * 1024 * 1024), 2) + " GB"
  }
  function formatRate(n) { return formatBytes(n) + "/s" }
  function formatPing(ms) {
    if (!hasPing) return "--"
    if (!isFinite(ms) || ms < 0) return Commons.I18n.t("network.timeout")
    return Commons.I18n.formatNumber(ms, ms > 0 && ms < 10 ? 1 : 0) + " ms"
  }
  function formatLoss(percent) { return hasPing ? Commons.I18n.formatNumber(percent || 0) + "%" : "--" }
  function copyToClipboard(value) {
    if (!value) return
    Quickshell.execDetached(["bash", "-c", "printf %s \"$1\" | wl-copy", "copy", value])
  }
  // Omarchy's speed test card, as the Wi-Fi card's hero button opens it; only
  // while the cellular link carries the internet, since it tests that route.
  function summonSpeedTest() {
    root.close()
    if (root.bar && root.bar.shell) root.bar.shell.summon("omarchy.speedtest", JSON.stringify({ connection: root.title() }))
  }

  Process {
    id: dataProc
    command: ["systemctl", "is-active", "omamobile-sit-data.service"]
    stdout: StdioCollector {
      onStreamFinished: {
        var state = String(text || "").trim()
        root.dataOn = state === "active"
        root.dataTrying = state === "activating"
      }
    }
  }

  Process {
    id: radioSet
    onExited: function(code) {
      if (code !== 0) { root.radioBusy = false; root.refresh(); return }
      radioWait.start()
    }
  }

  // Until sitd's state shows the radio as asked, or 15 s
  Timer {
    id: radioWait
    interval: 1000
    repeat: true
    onTriggered: {
      root.refresh()
      root.radioWaits += 1
      if (root.radioOff === !root.radioWant || root.radioWaits >= 15) { stop(); root.radioBusy = false }
    }
  }

  Timer { interval: 3000; running: root.opened; repeat: true; onTriggered: root.refresh() }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.glyph
    tooltipText: ""
    onPressed: function(b) { root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight)

    content: PanelKeyCatcher {
      anchors.fill: parent
      implicitHeight: column.implicitHeight
      onCloseRequested: root.close()

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        // ---------- Hero: signal glyph · carrier and state · data switch ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, heroActions.implicitHeight)

          Text {
            id: heroIcon
            textFormat: Text.PlainText
            // The bars are drawn (CellBars.qml, the font has no four-bar set); a
            // transparent glyph keeps the slot's size.
            readonly property bool cellBars: root.glyph.indexOf("cell-bars:") === 0
            text: cellBars ? String.fromCodePoint(0xF001D) : root.glyph
            color: cellBars ? "transparent" : root.bar.foreground
            CellBars {
              anchors.centerIn: parent
              visible: parent.cellBars
              level: parent.cellBars ? (parseInt(root.glyph.slice(10), 10) || 0) : 0
              color: root.bar.foreground
              size: parent.font.pixelSize * 0.74
            }
            opacity: root.registered && root.dataOn ? 1.0 : 0.5
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.display
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: heroActions.left
            anchors.rightMargin: Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              // The network's kind rides after the name, as the Wi-Fi card's band does
              text: root.registered && modem.tech ? root.title() + " (" + modem.tech + ")" : root.title()
              textFormat: Text.PlainText
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              text: root.status().toUpperCase()
              textFormat: Text.PlainText
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Readable.px(Style.font.caption)
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
              width: parent.width
            }
          }

          RowLayout {
            id: heroActions
            spacing: Style.space(8)
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter

            PanelActionButton {
              visible: root.linkUp && root.link.default === true
              iconText: "󰓅"
              tooltipText: Commons.I18n.t("network.runSpeedTest")
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              fontSize: Style.font.subtitle * 1.5
              Layout.alignment: Qt.AlignVCenter
              onClicked: root.summonSpeedTest()
            }

            ToggleSwitch {
              id: cellSwitch
              visible: root.present
              checked: root.radioBusy ? root.radioWant : !root.radioOff
              busy: root.radioBusy
              foreground: root.bar.foreground
              Layout.alignment: Qt.AlignVCenter
              onToggled: root.setRadio(root.radioOff)
            }
          }
        }

        // ---------- Signal bar, as the power card's charge bar ----------
        Item {
          visible: root.present
          width: parent.width
          implicitHeight: Style.space(8)

          Rectangle {
            id: barTrack
            anchors.fill: parent
            radius: height / 2
            color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.12)
          }

          Rectangle {
            anchors.left: barTrack.left
            anchors.verticalCenter: barTrack.verticalCenter
            height: barTrack.height
            radius: barTrack.radius
            color: root.bar.foreground
            visible: root.signal > 0
            width: Math.max(barTrack.height, barTrack.width * root.signal / 100)
            Behavior on width { NumberAnimation { duration: Style.duration(320); easing.type: Easing.OutCubic } }
          }
        }

        // ---------- Details, as the Wi-Fi card's: the cell first, then the link ----------
        // What only a cellular link has (signal, calls, texts, mobile data),
        // then the same rows and labels as Omarchy's Wi-Fi card (its grid,
        // two pairs a row, one on a narrow card as patch 0033 has it). "--"
        // until there is a sample.
        // The grid and the DNS line under it, spaced as one list
        Column {
          visible: root.present
          width: parent.width
          spacing: Style.spacing.labelGap

          GridLayout {
            width: parent.width
            columns: panel.contentWidth < Style.space(380) ? 2 : 4
            columnSpacing: Style.space(20)
            rowSpacing: Style.spacing.labelGap

            // What only a cellular link has comes first
            InfoLabel { text: "Signal" }
            DetailValue { text: root.registered ? root.signal + "%" : "--" }
            InfoLabel { text: "Calls" }
            DetailValue { text: root.yesNo(modem.voice) }

            InfoLabel { text: "Texts" }
            DetailValue { text: root.yesNo(modem.sms) }
            InfoLabel { text: "Cellular data" }
            DetailValue { text: root.dataOn ? (modem.data ? "On" : "Connecting") : (root.dataTrying ? "Connecting" : "Off") }

            InfoLabel { text: Commons.I18n.t("network.ping") }
            DetailValue {
              text: root.linkUp ? root.formatPing(root.pingLatency) : "--"
              color: root.hasPing && root.packetLoss > 0 ? root.bar.urgent : root.bar.foreground
            }
            InfoLabel { text: Commons.I18n.t("network.packetLoss") }
            DetailValue {
              text: root.linkUp ? root.formatLoss(root.packetLoss) : "--"
              color: root.hasPing && root.packetLoss > 0 ? root.bar.urgent : root.bar.foreground
            }

            InfoLabel { text: Commons.I18n.t("network.receiving") }
            DetailValue { text: root.linkUp && root.lastSample ? root.formatRate(root.downloadRate) : "--" }
            InfoLabel { text: Commons.I18n.t("network.sending") }
            DetailValue { text: root.linkUp && root.lastSample ? root.formatRate(root.uploadRate) : "--" }

            InfoLabel { text: Commons.I18n.t("network.downloaded") }
            DetailValue { text: root.linkUp ? root.formatBytes(root.link.rx) : "--" }
            InfoLabel { text: Commons.I18n.t("network.uploaded") }
            DetailValue { text: root.linkUp ? root.formatBytes(root.link.tx) : "--" }

            InfoLabel { text: Commons.I18n.t("network.ipAddress") }
            DetailValue { text: root.linkUp ? root.link.address : "--"; copyable: root.linkUp }
          }

          // DNS is one setting for every connection, and its pills are on the
          // Wi-Fi card: say so here, where nobody would look for it. Read-only.
          RowLayout {
            width: parent.width
            spacing: Style.space(20)
            InfoLabel { text: "DNS" }
            DetailValue { text: root.dnsText(); elide: Text.ElideLeft }
          }
        }
      }
    }
  }

  // The Wi-Fi card's value: right-aligned, a tap copies it where it says so
  component DetailValue: InfoValue {
    property bool copyable: false
    Layout.fillWidth: true
    horizontalAlignment: Text.AlignRight
    MouseArea {
      anchors.fill: parent
      enabled: parent.copyable && parent.text !== "" && parent.text !== "--"
      onClicked: root.copyToClipboard(parent.text)
    }
  }

  component InfoLabel: Text {
    textFormat: Text.PlainText
    color: root.bar.foreground
    opacity: 0.6
    font.family: root.bar.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  component InfoValue: Text {
    textFormat: Text.PlainText
    color: root.bar.foreground
    font.family: root.bar.fontFamily
    font.pixelSize: Style.font.bodySmall
  }
}
