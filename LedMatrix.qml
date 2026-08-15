import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "LedMatrixModel.js" as Model

BarWidget {
  id: root
  moduleName: "godlewski.framework-led-matrix-helper"

  readonly property string ctlPath: Qt.resolvedUrl("bin/led-matrix-ctl").toString().replace(/^file:\/\//, "")
  readonly property bool swapped: {
    var v = setting("swapped", false)
    return v === true || v === "true"
  }

  property var devices: []
  property bool cliAvailable: false
  property string currentAnimation: ""
  property string target: "all"
  property string activeGame: ""
  property int brightness: 80
  property bool popupOpen: false
  property var panelState: ({})
  property var pendingAction: null

  visible: cliAvailable && devices.length > 0
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function close() { popupOpen = false }

  function ctlBase() {
    return swapped ? [ctlPath, "--swap"] : [ctlPath]
  }

  function refresh() {
    if (!listProc.running) listProc.running = true
    refreshStatus()
  }

  function refreshStatus() {
    if (cliAvailable && !statusProc.running) statusProc.running = true
  }

  onSwappedChanged: refresh()

  function runAction(args) {
    if (actionProc.running) {
      pendingAction = args
      return
    }
    var cmd = ctlBase()
    if (target !== "all") cmd = cmd.concat(["--device", target])
    actionProc.command = cmd.concat(args)
    actionProc.running = true
  }

  function blankState() {
    return { brightness: 80, pattern: "", animation: "none" }
  }

  function isOwningAnimation(a) {
    return a === "clock" || a === "eq" || a === "mic-eq" || a === "bounce"
  }

  function stateFor(t) {
    var s = panelState[t]
    return s ? s : blankState()
  }

  function record(key, value) {
    var ps = panelState
    var targets = target === "all" ? ["all"].concat(devices) : [target]
    for (var i = 0; i < targets.length; i++) {
      var t = targets[i]
      var s = ps[t] ? ps[t] : blankState()
      s[key] = value
      ps[t] = s
    }
    panelState = ps
  }

  function restoreControls() {
    var s = stateFor(target)
    brightness = s.brightness
    patternDropdown.value = s.pattern
    animDropdown.value = s.animation
  }

  function toggleSwap() {
    // No --json: it silently drops a false value (first-party CLI quirk)
    swapProc.command = ["omarchy", "bar", "set", "godlewski.framework-led-matrix-helper", "swapped", swapped ? "false" : "true"]
    if (!swapProc.running) swapProc.running = true
  }

  function targetOptions() {
    var opts = [{ value: "all", label: devices.length > 1 ? "Both" : "All" }]
    for (var i = 0; i < devices.length; i++)
      opts.push({ value: devices[i], label: Model.panelLabel(i) })
    return opts
  }

  IpcHandler {
    target: "godlewski.framework-led-matrix-helper"
    function refresh(): void { root.broadcast("refresh") }
    function toggle(): void { root.popupOpen = !root.popupOpen }
    function sleep(): void { root.runAction(["sleep"]) }
    function wake(): void { root.runAction(["wake"]) }
  }

  Process {
    id: listProc
    command: root.ctlBase().concat(["list"])
    property var found: []
    onStarted: found = []
    stdout: SplitParser {
      onRead: function(line) {
        var dev = String(line || "").trim()
        if (dev.length > 0) listProc.found.push(dev)
      }
    }
    onExited: function(exitCode) {
      root.cliAvailable = exitCode === 0
      root.devices = exitCode === 0 ? listProc.found : []
      if (root.target !== "all" && root.devices.indexOf(root.target) === -1)
        root.target = "all"
    }
  }

  Process {
    id: statusProc
    command: root.ctlBase().concat(["animation-status"])
    property string status: ""
    onStarted: status = ""
    stdout: SplitParser {
      onRead: function(line) { statusProc.status = String(line || "").trim() }
    }
    onExited: {
      root.currentAnimation = statusProc.status
      // Seed the "all" bucket so a reopened popup agrees with an animation
      // started outside this session
      if (statusProc.status.length > 0 && stateFor("all").animation === "none") {
        var ps = panelState
        var s = ps["all"] ? ps["all"] : blankState()
        s.animation = statusProc.status
        ps["all"] = s
        panelState = ps
        if (target === "all") animDropdown.value = statusProc.status
      }
    }
  }

  Process {
    id: actionProc
    onExited: {
      statusRefreshTimer.restart()
      root.broadcast("refreshStatus")
      if (root.pendingAction) {
        var next = root.pendingAction
        root.pendingAction = null
        root.runAction(next)
      }
    }
  }

  Process {
    id: swapProc
  }

  Timer {
    interval: 15000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    id: statusRefreshTimer
    interval: 400
    onTriggered: if (!statusProc.running) statusProc.running = true
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    slotSize: Style.bar.statusSlot
    fontSize: Style.font.caption
    tooltipText: "LED Matrix · " + Model.tooltip(root.devices.length, root.currentAnimation)
    onPressed: root.popupOpen = !root.popupOpen
  }

  PopupCard {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    contentWidth: popup.fittedContentWidth(Style.space(340))
    contentHeight: popup.fittedContentHeight(column.implicitHeight)

    Column {
      id: column
      anchors.fill: parent
      spacing: Style.space(10)

      Text {
        text: "LED Matrix"
        color: Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        font.bold: true
      }

      Text {
        text: Model.tooltip(root.devices.length, root.currentAnimation)
        color: Color.foreground
        opacity: 0.7
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      ButtonGroup {
        width: parent.width
        options: root.targetOptions()
        value: root.target
        onChanged: function(value) {
          root.target = value
          root.restoreControls()
        }
      }

      Button {
        width: parent.width
        leftAlign: true
        text: root.swapped ? "Panels swapped (Panel 1 = right)" : "Swap panels (fix left/right order)"
        selected: root.swapped
        tooltipText: "Panel order is random per boot — toggle if text or chips land on the wrong side"
        onClicked: root.toggleSwap()
      }

      Text {
        text: "Brightness · " + root.brightness + "%"
        color: Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      PanelSlider {
        width: parent.width
        bar: root.bar
        minimum: 0
        maximum: 100
        step: 1
        integer: true
        value: root.brightness
        onMoved: function(value) { root.brightness = value }
        onReleased: function(value) {
          root.brightness = value
          root.record("brightness", value)
          root.runAction(["brightness", String(value)])
        }
      }

      Dropdown {
        id: patternDropdown
        width: parent.width
        label: "Pattern"
        options: Model.patterns
        onChanged: function(value) {
          root.record("pattern", value)
          if (root.isOwningAnimation(root.stateFor(root.target).animation)) {
            root.record("animation", "none")
            animDropdown.value = "none"
          }
          if (root.activeGame !== "") root.activeGame = ""
          // All On forces the firmware brightness cap to max
          if (value === "all-on") {
            root.record("brightness", 100)
            root.brightness = 100
          }
          root.runAction(["pattern", value])
        }
      }

      Dropdown {
        id: animDropdown
        width: parent.width
        label: "Animation"
        options: Model.animations
        onChanged: function(value) {
          var prev = root.stateFor(root.target).animation
          root.record("animation", value)
          if (value !== "none" && root.activeGame !== "") root.activeGame = ""
          if (value === "none") {
            root.runAction(["stop-animation"])
          } else {
            root.runAction(["animate", value])
            // Breathing/blinking modulate the grid as-is; coming from a
            // frame-streamer the grid holds residue, so re-apply the
            // tracked pattern underneath (queued after the animate action)
            if ((value === "breathing" || value === "blinking") && root.isOwningAnimation(prev)) {
              var p = root.stateFor(root.target).pattern
              if (p) root.runAction(["pattern", p])
            }
          }
        }
      }

      Row {
        width: parent.width
        spacing: Style.space(8)

        TextField {
          id: textInput
          width: parent.width - sendButton.implicitWidth - Style.space(8)
          placeholderText: root.target === "all" && root.devices.length > 1 ? "TEXT (MAX 10)" : "TEXT (MAX 5)"
          maximumLength: root.target === "all" && root.devices.length > 1 ? 10 : 5
          onAccepted: sendButton.clicked()
        }

        Button {
          id: sendButton
          text: "Show"
          onClicked: {
            if (textInput.text.length > 0) {
              if (root.isOwningAnimation(root.stateFor(root.target).animation)) {
                root.record("animation", "none")
                animDropdown.value = "none"
              }
              if (root.activeGame !== "") root.activeGame = ""
              root.runAction(["text", textInput.text])
            }
          }
        }
      }

      Button {
        width: parent.width
        leftAlign: true
        text: "Game of Life"
        selected: root.activeGame !== ""
        tooltipText: "Snake/Pong/Tetris need physical input or are no-ops in this firmware — Life is the only self-running game"
        onClicked: {
          if (root.activeGame !== "") {
            root.activeGame = ""
            root.runAction(["stop-game"])
            // stop-game leaves the last game frame on the grid — restore the
            // tracked pattern, or blank the panel if none was set
            var p = root.stateFor(root.target).pattern
            root.runAction(p ? ["pattern", p] : ["percentage", "0"])
          } else {
            root.activeGame = "game-of-life"
            root.record("animation", "none")
            animDropdown.value = "none"
            root.runAction(["game", "game-of-life"])
          }
        }
      }

      Row {
        width: parent.width
        spacing: Style.space(8)

        Button {
          text: "Sleep"
          onClicked: root.runAction(["sleep"])
        }
        Button {
          text: "Wake"
          onClicked: root.runAction(["wake"])
        }
        Button {
          text: "Off"
          onClicked: root.runAction(["off"])
        }
      }
    }
  }
}
