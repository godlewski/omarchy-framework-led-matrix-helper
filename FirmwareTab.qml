import QtQuick
import qs.Commons
import qs.Ui
import "LedMatrixModel.js" as Model

// Panels tab: per-panel identity (which physical side is which), USB-port
// side assignment, and firmware updates. Rows key off widget.deviceInfo,
// which preserves raw discovery order — the port shown per row is a physical
// fact independent of the swap state.
Column {
  id: tab

  required property var widget

  spacing: Style.space(12)

  Repeater {
    model: widget.deviceInfo

    delegate: Column {
      id: deviceRow

      required property var modelData
      required property int index

      readonly property string side: Model.deviceSide(
        modelData.dev, widget.deviceInfo, widget.leftPort, widget.rightPort)

      width: tab.width
      spacing: Style.spacing.sm

      Text {
        text: (Model.sideLabel(deviceRow.side) || Model.panelLabel(deviceRow.index))
          + " · " + deviceRow.modelData.dev + " · port " + deviceRow.modelData.port
        color: widget.fg
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        font.bold: true
      }

      Text {
        text: "Firmware " + deviceRow.modelData.version
        color: Qt.darker(widget.fg, 1.4)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      Row {
        width: parent.width
        spacing: Style.spacing.lg

        Button {
          text: "Identify"
          bordered: true
          foreground: widget.fg
          hasCursor: widget.cursorActive && widget.cursorRow === "identify:" + deviceRow.index
          tooltipText: "Pulse this panel's brightness so you can tell which side it is"
          onClicked: widget.identify(deviceRow.modelData.dev)
          onHovered: function(isHovered) { if (isHovered) widget.setCursor("identify:" + deviceRow.index) }
        }

        CursorSurface {
          visible: widget.deviceInfo.length > 1
          implicitWidth: sideGroup.implicitWidth + Style.spacing.md
          implicitHeight: sideGroup.implicitHeight + Style.spacing.md
          hasCursor: widget.cursorActive && widget.cursorRow === "side:" + deviceRow.index
          foreground: widget.fg
          anchors.verticalCenter: parent.verticalCenter

          ButtonGroup {
            id: sideGroup
            anchors.centerIn: parent
            options: [
              { value: "left", label: "Left" },
              { value: "right", label: "Right" }
            ]
            value: deviceRow.side
            focusable: false
            foreground: widget.fg
            onChanged: function(value) { widget.assignSide(deviceRow.modelData.port, value) }
            onHovered: function(index, isHovered) { if (isHovered) widget.setCursor("side:" + deviceRow.index) }
          }
        }

        Button {
          text: "Flash firmware…"
          bordered: true
          foreground: widget.fg
          hasCursor: widget.cursorActive && widget.cursorRow === "flash:" + deviceRow.index
          enabled: !widget.flashing
          opacity: enabled ? 1.0 : 0.5
          tooltipText: "Pick a .uf2 you downloaded from Framework's releases; it's validated before flashing"
          onClicked: widget.beginFlashConfirm(deviceRow.modelData.dev)
          onHovered: function(isHovered) { if (isHovered) widget.setCursor("flash:" + deviceRow.index) }
        }
      }

      Text {
        visible: (widget.flashStatus[deviceRow.modelData.dev] || "") !== ""
        text: widget.flashStatus[deviceRow.modelData.dev] || ""
        color: Qt.darker(widget.fg, 1.3)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
        width: tab.width
      }
    }
  }

  // Fallback for setups without port assignment: the enumeration order is
  // random per boot, so offer the manual swap toggle. Once ports are
  // assigned, the swap state derives automatically and the toggle would
  // just be overwritten — hide it.
  Button {
    visible: widget.deviceInfo.length > 1 && widget.leftPort === ""
    width: parent.width
    leftAlign: true
    bordered: true
    text: widget.swapped ? "Panels swapped" : "Swap panels (fix left/right order)"
    selected: widget.swapped
    foreground: widget.fg
    tooltipText: "Panel order is random per boot — assign Left/Right above to fix it permanently"
    onClicked: widget.toggleSwap()
  }

  Button {
    text: "Get firmware from Framework's releases"
    bordered: true
    leftAlign: true
    width: parent.width
    foreground: widget.fg
    tooltipText: "Opens github.com/FrameworkComputer/inputmodule-rs/releases — download ledmatrix.uf2, then Flash firmware…"
    onClicked: widget.openFirmwareReleases()
  }
}
