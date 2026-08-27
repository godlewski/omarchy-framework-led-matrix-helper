import QtQuick
import qs.Commons
import qs.Ui
import "LedMatrixModel.js" as Model

// Pattern editor tab: a big interactive 9x34 grid (click toggles, drag
// paints, Enter on the grid starts a keyboard draw mode) plus save/load.
// Saved patterns are 9x34 PNGs — the exact format `inputmodule-control
// --image-bw` consumes, so the library doubles as the export: every saved
// file works standalone and appears in the Display picker as "★ name".
//
// The editor bypasses the staging model on purpose: the grid IS the preview.
// "Send to panels" (or live paint) transmits immediately via the ctl's
// `frame` action.
Column {
  id: tab

  required property var widget
  readonly property bool keysBlocked: nameInput.activeFocus || loadDropdown.popupOpen

  spacing: Style.space(10)

  Row {
    width: parent.width
    spacing: Style.space(14)

    // ---- interactive grid --------------------------------------------------

    Item {
      id: gridHolder
      width: editGrid.implicitWidth
      height: editGrid.implicitHeight

      PanelPreview {
        id: editGrid
        cellPx: 8
        fg: widget.fg
        lit: true
        frame: Model.bitsToFrame(widget.editorBits)
      }

      // Keyboard draw-mode cell cursor
      Rectangle {
        visible: widget.drawMode
        readonly property real step: editGrid.cellPx + editGrid.cellGap
        x: editGrid.pad + widget.editorCursorX * step - 1
        y: editGrid.pad + widget.editorCursorY * step - 1
        width: editGrid.cellPx + 2
        height: editGrid.cellPx + 2
        color: "transparent"
        border.color: Color.accent
        border.width: Math.max(1, Style.normalBorderWidth)
      }

      MouseArea {
        anchors.fill: parent
        // First cell of a stroke decides whether the drag paints or erases
        property int paintValue: 1

        function cellAt(mx, my) {
          var step = editGrid.cellPx + editGrid.cellGap
          var cx = Math.floor((mx - editGrid.pad) / step)
          var cy = Math.floor((my - editGrid.pad) / step)
          return (cx >= 0 && cx < 9 && cy >= 0 && cy < 34) ? { x: cx, y: cy } : null
        }

        onPressed: function(mouse) {
          widget.setCursor("editor")
          var c = cellAt(mouse.x, mouse.y)
          if (!c) return
          paintValue = widget.editorCellAt(c.x, c.y) ? 0 : 1
          widget.editorSetCell(c.x, c.y, paintValue)
        }

        onPositionChanged: function(mouse) {
          if (!pressed) return
          var c = cellAt(mouse.x, mouse.y)
          if (c) widget.editorSetCell(c.x, c.y, paintValue)
        }
      }
    }

    // ---- toolbar -----------------------------------------------------------

    Column {
      width: parent.width - gridHolder.width - Style.space(14)
      spacing: Style.spacing.lg

      Button {
        width: parent.width
        text: "Send to panels"
        bordered: true
        selected: true
        foreground: widget.fg
        hasCursor: widget.cursorActive && widget.cursorRow === "edapply"
        tooltipText: "Sends the drawing to: "
          + Model.optionLabel(widget.targetOpts, widget.target)
        onClicked: widget.applyEditor()
        onHovered: function(isHovered) { if (isHovered) widget.setCursor("edapply") }
      }

      CursorSurface {
        width: parent.width
        implicitHeight: liveRow.implicitHeight + Style.spacing.md
        hasCursor: widget.cursorActive && widget.cursorRow === "edlive"
        foreground: widget.fg

        Row {
          id: liveRow
          anchors.left: parent.left
          anchors.leftMargin: Style.spacing.xs
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.spacing.md

          ToggleSwitch {
            anchors.verticalCenter: parent.verticalCenter
            trackHeight: 16
            cursorPad: Style.space(3)
            checked: widget.editorLive
            foreground: widget.fg
            onToggled: widget.editorLive = !widget.editorLive
            onHovered: function(isHovered) { if (isHovered) widget.setCursor("edlive") }
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "Live paint"
            color: widget.fg
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }
        }
      }

      Button {
        width: parent.width
        text: "Clear"
        bordered: true
        leftAlign: true
        foreground: widget.fg
        onClicked: widget.clearEditor()
      }

      Button {
        width: parent.width
        text: "Invert"
        bordered: true
        leftAlign: true
        foreground: widget.fg
        onClicked: widget.invertEditor()
      }

      Button {
        width: parent.width
        text: "Grab current display"
        bordered: true
        leftAlign: true
        foreground: widget.fg
        tooltipText: "Copy what the current target is showing into the editor"
        onClicked: widget.grabEditor()
      }

      Button {
        width: parent.width
        text: "Import PNG…"
        bordered: true
        leftAlign: true
        foreground: widget.fg
        tooltipText: "Pick any 9x34 PNG — it's added to the library and loaded here"
        onClicked: widget.importPatternFile()
      }

      Text {
        visible: widget.importError !== ""
        width: parent.width
        text: widget.importError
        color: Color.urgent
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }

      Text {
        width: parent.width
        text: widget.drawMode
          ? "Draw: h/j/k/l or arrows move, Space toggles, Esc done"
          : "Click to toggle, drag to paint. Enter on the grid draws by keyboard."
        color: Qt.darker(widget.fg, 1.4)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
    }
  }

  PanelSeparator { foreground: widget.fg }

  // ---- save --------------------------------------------------------------

  Row {
    width: parent.width
    spacing: Style.spacing.lg

    TextField {
      id: nameInput
      width: parent.width - saveButton.implicitWidth - Style.spacing.lg
      placeholderText: "Pattern name"
      maximumLength: 32
      foreground: widget.fg
      onAccepted: saveButton.clicked()
      Keys.onEscapePressed: widget.focusPanelKeys()

      Binding on text {
        value: widget.editorName
      }
    }

    Button {
      id: saveButton
      text: "Save"
      bordered: true
      foreground: widget.fg
      enabled: nameInput.text.trim().length > 0
      opacity: enabled ? 1.0 : 0.5
      anchors.verticalCenter: nameInput.verticalCenter
      onClicked: {
        widget.saveEditor(nameInput.text)
        widget.focusPanelKeys()
      }
    }
  }

  // ---- load / delete ------------------------------------------------------

  Row {
    visible: widget.customPatterns.length > 0
    width: parent.width
    spacing: Style.spacing.lg

    Dropdown {
      id: loadDropdown
      width: parent.width - deleteButton.implicitWidth - Style.spacing.lg
      showLabel: false
      options: {
        var opts = []
        for (var i = 0; i < widget.customPatterns.length; i++)
          opts.push({ value: widget.customPatterns[i].name, label: "★ " + widget.customPatterns[i].name })
        return opts
      }
      foreground: widget.fg
      onChanged: function(value) { widget.loadPattern(value) }
    }

    Binding {
      target: loadDropdown
      property: "value"
      value: widget.editorName
    }

    Button {
      id: deleteButton
      text: "Delete"
      bordered: true
      foreground: widget.fg
      enabled: loadDropdown.value !== ""
      opacity: enabled ? 1.0 : 0.5
      anchors.verticalCenter: loadDropdown.verticalCenter
      tooltipText: "Delete the selected saved pattern"
      onClicked: {
        widget.deletePattern(loadDropdown.value)
        widget.editorName = ""
      }
    }
  }

}
