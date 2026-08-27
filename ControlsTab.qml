import QtQuick
import qs.Commons
import qs.Ui
import "LedMatrixModel.js" as Model

// Controls tab. The emulated twin panels at the top render STAGED state —
// picking a display/effect or typing text paints the twins only; Apply sends
// the staged diff to hardware (brightness and power stay immediate). All
// values bind to widget.stagedFor(widget.target), so switching targets
// re-renders the controls from that target's state with no imperative step.
//
// Keyboard: the widget owns the cursor (widget.cursorRow); rows here paint
// from it and report mouse hover back through widget.setCursor so keyboard
// and mouse share a single highlight (the kit's CursorSurface contract).
Column {
  id: tab

  required property var widget
  readonly property var ts: widget.stagedFor(widget.target)
  readonly property bool effectsAvailable: !Model.ownsDisplay(ts.display)

  // While either of these owns the keys, the panel's PanelKeyCatcher must not
  // interpret j/k/Enter (see its `blocked` binding in LedMatrix.qml).
  readonly property bool keysBlocked: displayDropdown.popupOpen || textInput.activeFocus

  function openDisplayDropdown() { displayDropdown.toggle() }
  function focusText() {
    textInput.forceActiveFocus()
    textInput.selectAll()
  }

  spacing: Style.space(10)

  // ---- Emulated panels ------------------------------------------------------

  Item {
    width: parent.width
    implicitHeight: twinRow.implicitHeight

    Row {
      id: twinRow
      anchors.horizontalCenter: parent.horizontalCenter
      spacing: Style.space(18)

      Repeater {
        model: Math.min(2, Math.max(1, widget.devices.length))

        delegate: Column {
          id: twin

          required property int index

          readonly property string dev: widget.devices[twin.index] || "all"
          readonly property var st: widget.stagedFor(twin.dev)
          readonly property var appliedSt: widget.stateFor(twin.dev)

          // Text spans panels (5 chars each) exactly when both panels carry
          // the same staged text — mirroring how the ctl splits target=all.
          readonly property string chunk: {
            if (widget.devices.length < 2) return Model.textChunkFor(twin.st.text, 0)
            var other = widget.stagedFor(widget.devices[1 - twin.index])
            return other.text === twin.st.text
              ? Model.textChunkFor(twin.st.text, twin.index)
              : Model.textChunkFor(twin.st.text, 0)
          }

          spacing: Style.spacing.labelGap

          PanelPreview {
            anchors.horizontalCenter: parent.horizontalCenter
            fg: widget.fg
            lit: widget.awake && widget.panelOn(twin.dev)
            pending: widget.pending
            frame: {
              if (Model.ownsDisplay(twin.st.display))
                return Model.streamFrame(twin.st.display, widget.animTick)
              if (Model.isCustomDisplay(twin.st.display))
                return Model.bitsToFrame(widget.customBitsFor(twin.st.display))
              return Model.staticFrame(twin.st.display, twin.chunk, twin.st.textDx, twin.st.textDy)
            }
            level: {
              var base = twin.appliedSt.brightness / 100
              return twin.st.effect !== "none"
                ? base * Model.effectLevel(twin.st.effect, widget.animTick)
                : base
            }
          }

          Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Style.spacing.md
            visible: widget.devices.length > 1

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: widget.targetOpts[twin.index + 1] ? widget.targetOpts[twin.index + 1].label : ""
              color: Qt.darker(widget.fg, 1.4)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
            }

            ToggleSwitch {
              anchors.verticalCenter: parent.verticalCenter
              trackHeight: 16
              cursorPad: Style.space(3)
              checked: widget.panelOn(twin.dev)
              // A running effect's brightness loop would immediately undo an
              // off — the commit path re-lights all panels when an effect
              // starts, and this stays inert until the effect stops.
              busy: widget.stateFor(twin.dev).effect !== "none"
              hasCursor: widget.cursorActive && widget.cursorRow === "panelpower:" + twin.index
              foreground: widget.fg
              onToggled: widget.setPanelOn(twin.dev, !widget.panelOn(twin.dev))
              onHovered: function(isHovered) { if (isHovered) widget.setCursor("panelpower:" + twin.index) }
            }
          }
        }
      }
    }
  }

  // ---- Target ---------------------------------------------------------------

  CursorSurface {
    visible: widget.devices.length > 1
    width: parent.width
    implicitHeight: targetGroup.implicitHeight + Style.spacing.md
    hasCursor: widget.cursorActive && widget.cursorRow === "target"
    foreground: widget.fg

    ButtonGroup {
      id: targetGroup
      anchors.centerIn: parent
      options: widget.targetOpts
      value: widget.target
      focusable: false
      foreground: widget.fg
      onChanged: function(value) { widget.target = value }
      onHovered: function(index, isHovered) { if (isHovered) widget.setCursor("target") }
    }
  }

  // ---- Brightness -----------------------------------------------------------

  Item {
    width: parent.width
    implicitHeight: brightnessHeader.implicitHeight

    PanelSectionHeader {
      id: brightnessHeader
      text: "BRIGHTNESS"
      foreground: widget.fg
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      text: (brightnessSlider.dragging ? Math.round(brightnessSlider.liveValue) : widget.stateFor(widget.target).brightness) + "%"
      color: Qt.darker(widget.fg, 1.4)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: true
      anchors.right: parent.right
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  CursorSurface {
    width: parent.width
    height: brightnessSlider.implicitHeight + Style.spacing.controlGap
    hasCursor: widget.cursorActive && widget.cursorRow === "brightness"
    foreground: widget.fg
    outline: true

    PanelSlider {
      id: brightnessSlider
      bar: widget.bar
      anchors.fill: parent
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(6)
      minimum: 0
      maximum: 100
      step: 5
      integer: true
      value: widget.stateFor(widget.target).brightness
      onMoved: function(v) { widget.applyBrightness(v) }
    }

    HoverHandler {
      onHoveredChanged: if (hovered) widget.setCursor("brightness")
    }
  }

  PanelSeparator { foreground: widget.fg }

  // ---- Display --------------------------------------------------------------

  Dropdown {
    id: displayDropdown
    width: parent.width
    label: "DISPLAY"
    options: Model.displayOptionsWith(widget.customPatterns, tab.ts.display)
    hasCursor: widget.cursorActive && widget.cursorRow === "display"
    foreground: widget.fg
    onChanged: function(value) { widget.stageDisplay(value) }
    onHovered: function(isHovered) { if (isHovered) widget.setCursor("display") }
  }

  // Dropdown assigns its own `value` on selection, which would sever a plain
  // binding — a Binding element re-asserts the staged state afterwards, so
  // target switches and reverts keep winning.
  Binding {
    target: displayDropdown
    property: "value"
    value: tab.ts.display
  }

  TextField {
    id: textInput
    visible: tab.ts.display === "text"
    width: parent.width
    placeholderText: widget.target === "all" && widget.devices.length > 1
      ? "Text (5 chars per panel)" : "Text (max 5 chars)"
    maximumLength: widget.target === "all" && widget.devices.length > 1 ? 10 : 5
    hasCursor: widget.cursorActive && widget.cursorRow === "text"
    foreground: widget.fg
    onTextChanged: if (text !== widget.stagedFor(widget.target).text) widget.stageText(text)
    onAccepted: {
      widget.commitStaged()
      widget.focusPanelKeys()
    }
    Keys.onEscapePressed: widget.focusPanelKeys()
    onHoveredChanged: if (hovered) widget.setCursor("text")

    // Typing severs a plain `text` binding; the Binding element re-seeds
    // the field from staged state whenever the target switches or edits
    // are reverted.
    Binding on text {
      value: tab.ts.text
    }
  }

  // ---- Text position --------------------------------------------------------

  Column {
    visible: tab.ts.display === "text"
    width: parent.width
    spacing: Style.spacing.labelGap

    Item {
      width: parent.width
      implicitHeight: positionHeader.implicitHeight

      PanelSectionHeader {
        id: positionHeader
        text: "POSITION"
        foreground: widget.fg
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        visible: tab.ts.textDx !== 0 || tab.ts.textDy !== 0
        text: "x " + (tab.ts.textDx >= 0 ? "+" : "") + tab.ts.textDx
          + " · y +" + tab.ts.textDy
        color: Qt.darker(widget.fg, 1.4)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        font.bold: true
        anchors.right: parent.right
        anchors.rightMargin: Style.space(6)
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    CursorSurface {
      width: parent.width
      implicitHeight: shiftRow.implicitHeight + Style.spacing.md
      hasCursor: widget.cursorActive && (widget.cursorRow === "shift" || widget.shiftMode)
      foreground: widget.fg

      Row {
        id: shiftRow
        anchors.left: parent.left
        anchors.leftMargin: Style.spacing.xs
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.spacing.md

        Repeater {
          model: [
            { glyph: "◀", dx: -1, dy: 0 },
            { glyph: "▶", dx: 1, dy: 0 },
            { glyph: "▲", dx: 0, dy: -1 },
            { glyph: "▼", dx: 0, dy: 1 }
          ]

          Button {
            required property var modelData
            text: modelData.glyph
            bordered: true
            foreground: widget.fg
            onClicked: widget.stageTextShift(modelData.dx, modelData.dy)
            onHovered: function(isHovered) { if (isHovered) widget.setCursor("shift") }
          }
        }

        Button {
          text: "Center"
          bordered: true
          foreground: widget.fg
          onClicked: {
            var b = Model.textShiftBounds(tab.ts.text)
            widget.stageRecord({ display: "text", textDx: 0, textDy: Math.floor(b.dyMax / 2) })
          }
          onHovered: function(isHovered) { if (isHovered) widget.setCursor("shift") }
        }
      }
    }

    Text {
      visible: widget.shiftMode
      width: parent.width
      text: "Nudge with h/j/k/l or arrows · Enter or Esc to finish"
      color: Qt.darker(widget.fg, 1.4)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }
  }

  // ---- Effect ---------------------------------------------------------------

  Column {
    width: parent.width
    spacing: Style.spacing.labelGap

    PanelSectionHeader {
      text: "EFFECT"
      foreground: widget.fg
    }

    CursorSurface {
      width: parent.width
      implicitHeight: effectGroup.implicitHeight + Style.spacing.md
      hasCursor: widget.cursorActive && widget.cursorRow === "effect"
      foreground: widget.fg
      opacity: tab.effectsAvailable ? 1.0 : 0.4

      Behavior on opacity { NumberAnimation { duration: 120 } }

      ButtonGroup {
        id: effectGroup
        anchors.left: parent.left
        anchors.leftMargin: Style.spacing.xs
        anchors.verticalCenter: parent.verticalCenter
        options: Model.effectOptions
        value: tab.ts.effect
        enabled: tab.effectsAvailable
        focusable: false
        foreground: widget.fg
        onChanged: function(value) { if (tab.effectsAvailable) widget.stageEffect(value) }
        onHovered: function(index, isHovered) { if (isHovered && tab.effectsAvailable) widget.setCursor("effect") }
      }
    }

    Text {
      visible: !tab.effectsAvailable
      text: "Paused while " + (Model.displayLabel(tab.ts.display) || "an animation") + " owns the display"
      color: Qt.darker(widget.fg, 1.4)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
      width: parent.width
    }
  }

  // ---- Apply / Revert -------------------------------------------------------

  CursorSurface {
    visible: widget.pending
    width: parent.width
    implicitHeight: applyRow.implicitHeight + Style.spacing.md
    hasCursor: widget.cursorActive && widget.cursorRow === "apply"
    foreground: widget.fg

    Row {
      id: applyRow
      anchors.centerIn: parent
      spacing: Style.spacing.lg

      Button {
        text: "Apply to panels"
        bordered: true
        selected: true
        enabled: widget.canApply
        opacity: enabled ? 1.0 : 0.5
        foreground: widget.fg
        onClicked: widget.commitStaged()
        onHovered: function(isHovered) { if (isHovered) widget.setCursor("apply") }
      }

      Button {
        text: "Revert"
        bordered: true
        foreground: widget.fg
        onClicked: widget.revertStaged()
        onHovered: function(isHovered) { if (isHovered) widget.setCursor("apply") }
      }
    }
  }

  Text {
    visible: widget.pending
    width: parent.width
    horizontalAlignment: Text.AlignHCenter
    text: "Preview only — nothing sent to the panels yet"
    color: Qt.darker(widget.fg, 1.4)
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
  }
}
