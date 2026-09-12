import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Bar icon plus popup for Logitech devices managed by OpenLogi: one battery
// row per paired device and a button through to the full OpenLogi app.
Panel {
  id: root
  moduleName: "epicserve.openlogi-battery"
  ipcTarget: "epicserve.openlogi-battery"
  // Own the IpcHandler so refresh/status/launch can sit beside the popup ones.
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property bool problem: svc.agentDown || svc.parseFailed || svc.lastError !== ""
  // Hidden while the agent is fine and nothing is paired, like omarchy.power
  // with no battery. Shown for devices or for anything that needs attention.
  readonly property bool shown: svc.everPolled && (svc.hasDevices || root.problem)

  readonly property string icon: {
    if (svc.agentState === "down") return Model.ICON_ALERT
    var d = svc.lowestDevice
    if (!d) return Model.ICON_UNKNOWN
    return Model.batteryIcon(d.battery, d.charging)
  }
  readonly property bool iconUrgent: svc.agentState === "down" || svc.anyLow

  readonly property string stateText: {
    if (svc.agentState === "down") return "OpenLogi agent not running"
    if (svc.agentState === "direct") return "Agent unreachable · read hardware directly"
    if (svc.parseFailed && !svc.hasDevices) return "Could not read device list"
    if (!svc.hasDevices) return "No devices"
    var lowest = svc.lowestDevice
    var base = svc.devices.length + (svc.devices.length === 1 ? " device" : " devices")
    if (lowest) base += " · lowest " + lowest.battery + "%"
    if (svc.stale) base += " · stale"
    return base
  }

  readonly property string tooltip: {
    if (svc.agentState === "down") return "OpenLogi agent not running"
    return Model.summaryText(svc.devices)
  }

  // Keyboard cursor walks device rows (0..n-1) then the footer button (n).
  property int cursor: 0
  property bool cursorActive: false
  readonly property int openIndex: svc.devices.length

  visible: shown
  implicitWidth: shown ? button.implicitWidth : 0
  implicitHeight: shown ? button.implicitHeight : 0

  function focusOn(index) {
    cursorActive = true
    cursor = index
  }

  function moveCursor(dx, dy) {
    if (!cursorActive) { cursorActive = true; return }
    var delta = dy !== 0 ? dy : dx
    cursor = Model.clamp(cursor + delta, 0, openIndex)
  }

  function activateCursor() {
    if (!cursorActive) { cursorActive = true; return }
    if (cursor === openIndex) launch()
  }

  function launch() {
    svc.openApp()
    close()
  }

  onOpenedChanged: {
    if (!opened) return
    cursorActive = false
    cursor = openIndex
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  onShownChanged: if (!shown) close()

  Service {
    id: svc
    settings: root.settings
    opened: root.opened
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { svc.refresh(); return "ok" }
    function launch(): string { root.launch(); return "ok" }
    function status(): string { return svc.statusJson() }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.icon
    active: root.iconUrgent
    tooltipText: root.opened ? "" : root.tooltip
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) svc.refresh()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) { root.moveCursor(dx, dy) }
      onActivateRequested: root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") svc.refresh()
        else if (t === "o" || t === "O") root.launch()
      }

      Column {
        id: column
        width: parent.width
        spacing: Style.space(12)

        // ---------- Hero ----------
        PanelHero {
          width: parent.width
          title: "OpenLogi"
          meta: root.stateText
          detail: svc.busy ? "…" : ""
          foreground: root.foreground
          fontFamily: root.fontFamily
          iconComponent: Component {
            Text {
              textFormat: Text.PlainText
              text: root.icon
              color: root.iconUrgent ? root.urgent : root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
            }
          }
        }

        // ---------- Attention states ----------
        Column {
          visible: root.problem
          width: parent.width
          spacing: Style.space(4)

          Text {
            textFormat: Text.PlainText
            width: parent.width
            wrapMode: Text.WordWrap
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: true
            text: {
              if (svc.agentState === "down") return "The OpenLogi agent isn't running."
              if (svc.agentState === "direct") return "The OpenLogi agent didn't answer."
              if (svc.parseFailed) return "Couldn't parse `openlogi list` output."
              return svc.lastError
            }
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            wrapMode: Text.WordWrap
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            visible: text !== ""
            text: {
              if (svc.agentDown) return "Try: systemctl --user restart openlogi-agent"
              if (svc.parseFailed) return "OpenLogi may have changed its output format. The raw output is in the shell log."
              if (svc.stale) return "Showing the last successful read."
              return ""
            }
          }
        }

        // ---------- Device rows ----------
        Column {
          width: parent.width
          spacing: Style.space(2)
          visible: svc.hasDevices
          opacity: svc.stale ? 0.6 : 1.0

          Repeater {
            model: svc.devices

            CursorSurface {
              id: row
              required property var modelData
              required property int index

              readonly property bool low: modelData.online
                && typeof modelData.battery === "number"
                && modelData.battery <= svc.lowBatteryThreshold
                && !modelData.charging
              readonly property color rowColor: modelData.online ? root.foreground : root.dim

              width: parent.width
              implicitHeight: rowContent.implicitHeight + Style.spacing.rowPaddingX
              hasCursor: root.cursorActive && root.cursor === index
              foreground: root.foreground

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                onContainsMouseChanged: if (containsMouse) root.focusOn(row.index)
                onClicked: svc.refresh()
              }

              Item {
                id: rowContent
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(10)
                anchors.rightMargin: Style.space(10)
                implicitHeight: Math.max(kindIcon.implicitHeight, info.implicitHeight, percent.implicitHeight)

                Text {
                  id: kindIcon
                  textFormat: Text.PlainText
                  text: Model.kindIcon(row.modelData.kind)
                  color: row.rowColor
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.heading
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                }

                Column {
                  id: info
                  spacing: Style.space(1)
                  anchors.left: kindIcon.right
                  anchors.leftMargin: Style.space(10)
                  anchors.right: percent.left
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter

                  Text {
                    textFormat: Text.PlainText
                    text: row.modelData.name || "Device"
                    color: row.rowColor
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    elide: Text.ElideRight
                    width: parent.width
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: Model.statusText(row.modelData)
                    color: row.low ? root.urgent : root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                    width: parent.width
                  }
                }

                Row {
                  id: percent
                  spacing: Style.space(6)
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter

                  Text {
                    textFormat: Text.PlainText
                    text: row.modelData.online && typeof row.modelData.battery === "number"
                      ? Model.batteryIcon(row.modelData.battery, row.modelData.charging)
                      : (row.modelData.online ? Model.ICON_UNKNOWN : "")
                    color: row.low ? root.urgent : row.rowColor
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.title
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: Model.percentText(row.modelData)
                    color: row.low ? root.urgent : row.rowColor
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: true
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }
              }
            }
          }
        }

        // ---------- Empty ----------
        Text {
          visible: !svc.hasDevices && !root.problem
          textFormat: Text.PlainText
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          text: "No Logitech devices paired"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          topPadding: Style.space(8)
          bottomPadding: Style.space(8)
        }

        PanelSeparator { foreground: root.foreground }

        // ---------- Footer ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(openButton.implicitHeight, hintText.implicitHeight)

          Button {
            id: openButton
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "Open OpenLogi"
            iconText: "󰍽"
            tooltipText: "DPI, buttons, SmartShift, lighting"
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            bordered: true
            hasCursor: root.cursorActive && root.cursor === root.openIndex
            onClicked: root.launch()
            onHovered: function(on) { if (on) root.focusOn(root.openIndex) }
          }

          Text {
            id: hintText
            textFormat: Text.PlainText
            text: "r refresh · o open"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            anchors.right: parent.right
            anchors.rightMargin: Style.space(6)
            anchors.verticalCenter: parent.verticalCenter
          }
        }
      }
    }
  }
}
