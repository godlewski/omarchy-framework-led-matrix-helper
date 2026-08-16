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
  property int brightness: 80
  property bool popupOpen: false
  property var panelState: ({})
  property var pendingAction: null
  property string activeTab: "controls"
  property var deviceInfo: []
  property string latestFirmware: ""
  property string latestUrl: ""
  property var flashStatus: ({})
  property var flashArmed: ({})
  property bool flashing: false

  property var pendingSettings: []
  function barSet(key, value) {
    pendingSettings.push([key, value])
    if (!settingsProc.running) runNextSetting()
  }
  function runNextSetting() {
    var next = pendingSettings.shift()
    if (!next) return
    settingsProc.command = ["omarchy", "bar", "set", "godlewski.framework-led-matrix-helper", next[0], String(next[1])]
    settingsProc.running = true
  }

  function sideForPort(port) {
    if (String(setting("leftPort", "")) === port) return "left"
    if (String(setting("rightPort", "")) === port) return "right"
    return ""
  }

  function assignSide(dev, port, side) {
    var otherPort = ""
    for (var i = 0; i < deviceInfo.length; i++)
      if (deviceInfo[i].port !== port) otherPort = deviceInfo[i].port
    barSet(side === "left" ? "leftPort" : "rightPort", port)
    if (otherPort) barSet(side === "left" ? "rightPort" : "leftPort", otherPort)
    // Re-derive once the settings land in shell.json (hot-reload triggers
    // onSettingsChanged); do an immediate best-effort pass too
    Qt.callLater(deriveSwap)
  }

  // device-info runs WITHOUT --swap: raw discovery order is a physical fact
  // (port ↔ slot), independent of the current swap state — so the derivation
  // is a stable absolute comparison with no binding-ordering race.
  function deriveSwap() {
    if (deviceInfo.length < 2) return
    var lp = String(setting("leftPort", ""))
    if (!lp) return
    // Unconditional write: comparing against the swapped binding races the
    // hot-reload of that very value. Identical writes produce no file change,
    // so this converges immediately instead of oscillating.
    barSet("swapped", deviceInfo[0].port !== lp ? "true" : "false")
  }

  function refreshDeviceInfo() {
    if (!infoProc.running) infoProc.running = true
  }

  function refreshLatest() {
    if (!latestProc.running) latestProc.running = true
  }

  function requestFlash(dev) {
    if (flashing) return
    var armed = flashArmed[dev] === true
    if (!armed) {
      var a = {}
      for (var k in flashArmed) a[k] = flashArmed[k]
      a[dev] = true
      flashArmed = a
      setFlashStatus(dev, "Tap Flash again to confirm — the panel will go dark during the update")
      disarmTimer.start()
      return
    }
    var aa = {}
    for (var k2 in flashArmed) aa[k2] = flashArmed[k2]
    aa[dev] = false
    flashArmed = aa
    flashing = true
    setFlashStatus(dev, "Resolving download…")
    downloadProc.deviceToFlash = dev
    downloadProc.command = [ctlPath, "download-firmware", latestFirmware]
    downloadProc.running = true
  }

  function setFlashStatus(dev, msg) {
    var fs = {}
    for (var k in flashStatus) fs[k] = flashStatus[k]
    fs[dev] = msg
    flashStatus = fs
  }

  visible: cliAvailable && devices.length > 0
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function close() { popupOpen = false }

  onPopupOpenChanged: {
    if (popupOpen && activeTab === "firmware") {
      refreshDeviceInfo()
      refreshLatest()
    }
  }

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

  onSettingsChanged: deriveSwap()

  Component.onCompleted: refreshDeviceInfo()

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
    // Reassign a fresh top-level object: mutating in place reassigns the same
    // reference, QML sees no change, and dependent bindings never re-evaluate
    var ps = {}
    for (var k in panelState) ps[k] = panelState[k]
    var targets = target === "all" ? ["all"].concat(devices) : [target]
    for (var i = 0; i < targets.length; i++) {
      var t = targets[i]
      var s = blankState()
      var prev = ps[t]
      if (prev) for (var pk in prev) s[pk] = prev[pk]
      s[key] = value
      ps[t] = s
    }
    panelState = ps
  }

  function restoreControls() {
    var s = stateFor(target)
    brightness = s.brightness
    patternPicker.value = s.pattern
    animPicker.value = s.animation
    if (s.pattern === "text" && s.text) textInput.text = s.text
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
      if (root.devices.length <= 1)
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
        if (target === "all") animPicker.value = statusProc.status
      }
    }
  }

  Process {
    id: actionProc
    onExited: function(exitCode) {
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

  Process {
    id: identifyProc
  }

  Process {
    id: settingsProc
    onExited: {
      if (root.pendingSettings.length > 0)
        root.runNextSetting()
      else
        root.deriveSwap()
    }
  }

  Process {
    id: infoProc
    command: [root.ctlPath, "device-info"]
    property var rows: []
    onStarted: rows = []
    stdout: SplitParser {
      onRead: function(line) {
        var parts = String(line || "").split("|")
        if (parts.length === 3 && parts[0].length > 0)
          infoProc.rows.push({ dev: parts[0], port: parts[1], version: parts[2] })
      }
    }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.deviceInfo = infoProc.rows
        root.deriveSwap()
      }
    }
  }

  Process {
    id: latestProc
    command: root.ctlBase().concat(["latest-firmware"])
    property string buf: ""
    onStarted: buf = ""
    stdout: SplitParser {
      onRead: function(line) { latestProc.buf += String(line || "") }
    }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        var parts = latestProc.buf.split("|")
        if (parts.length === 2) {
          root.latestFirmware = parts[0].trim()
          root.latestUrl = parts[1].trim()
        }
      }
    }
  }

  Process {
    id: downloadProc
    property string deviceToFlash: ""
    property string uf2Path: ""
    stdout: SplitParser {
      onRead: function(line) {
        var p = String(line || "").trim()
        if (p.length > 0) downloadProc.uf2Path = p
      }
    }
    onExited: function(exitCode) {
      if (exitCode === 0 && uf2Path.length > 0) {
        root.setFlashStatus(deviceToFlash, "Starting flash…")
        root.runAction(["stop-animation"])
        flashProc.command = [root.ctlPath.replace(/led-matrix-ctl$/, "led-matrix-flash"), deviceToFlash, uf2Path]
        flashProc.running = true
      } else {
        root.setFlashStatus(deviceToFlash, "Download failed — check network")
        root.flashing = false
      }
    }
  }

  Process {
    id: flashProc
    stdout: SplitParser {
      onRead: function(line) {
        var msg = String(line || "")
        if (msg.length > 0) root.setFlashStatus(flashTarget(), msg)
      }
    }
    onExited: function(exitCode) {
      root.flashing = false
      root.refreshDeviceInfo()
      root.refresh()
    }
  }

  function flashTarget() {
    return downloadProc.deviceToFlash
  }

  Timer {
    id: disarmTimer
    interval: 5000
    onTriggered: {
      var a = {}
      for (var k in root.flashArmed) a[k] = false
      root.flashArmed = a
      root.setFlashStatus("", "")
    }
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

  KeyboardPanel {
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
        options: [
          { value: "controls", label: "Controls" },
          { value: "firmware", label: "Firmware" }
        ]
        value: root.activeTab
        onChanged: function(value) {
          root.activeTab = value
          if (value === "firmware") {
            root.refreshDeviceInfo()
            root.refreshLatest()
          }
        }
      }

      ButtonGroup {
        visible: root.activeTab === "controls" && root.devices.length > 1
        width: parent.width
        options: root.targetOptions()
        value: root.target
        onChanged: function(value) {
          root.target = value
          root.restoreControls()
        }
      }

      Button {
        visible: root.activeTab === "controls" && root.devices.length > 1
        width: parent.width
        leftAlign: true
        text: {
          var lp = String(setting("leftPort", "")), rp = String(setting("rightPort", ""))
          if (lp && rp) return "Left: port " + lp + " · Right: port " + rp
          return root.swapped ? "Panels swapped" : "Swap panels (fix left/right order)"
        }
        selected: root.swapped
        tooltipText: "Panel order is random per boot — toggle if text or chips land on the wrong side"
        onClicked: root.toggleSwap()
      }

      Text {
        visible: root.activeTab === "controls"
        text: "Brightness · " + root.brightness + "%"
        color: Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      PanelSlider {
        visible: root.activeTab === "controls"
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

      Column {
        id: patternPicker
        visible: root.activeTab === "controls"
        width: parent.width
        spacing: 0
        property string value: ""
        property bool expanded: false
        property var options: Model.patterns
        signal changed(string value)
        onChanged: function(value) {
          // "Text" is a mode, not a firmware pattern — reveal the input and
          // leave the display untouched until the user sends text
          if (value === "text") {
            root.record("pattern", value)
            return
          }
          root.record("pattern", value)
          if (root.isOwningAnimation(root.stateFor(root.target).animation)) {
            root.record("animation", "none")
            animPicker.value = "none"
          }
          // All On forces the firmware brightness cap to max
          if (value === "all-on") {
            root.record("brightness", 100)
            root.brightness = 100
          }
          root.runAction(["pattern", value])
        }
        function optionLabel(v) {
          for (var i = 0; i < options.length; i++)
            if (String(options[i].value) === v) return String(options[i].label)
          return ""
        }

        Rectangle {
          width: parent.width
          height: Style.spacing.controlHeight
          radius: Style.cornerRadius
          color: headerMa.containsMouse ? Color.accent : Color.popups.background
          border.width: Style.normalBorderWidth
          border.color: Color.popups.border

          Text {
            anchors.left: parent.left
            anchors.leftMargin: Style.spacing.controlPaddingX
            anchors.verticalCenter: parent.verticalCenter
            text: "Pattern: " + (patternPicker.optionLabel(patternPicker.value) || "—")
            color: headerMa.containsMouse ? Color.background : Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }
          Text {
            anchors.right: parent.right
            anchors.rightMargin: Style.spacing.controlPaddingX
            anchors.verticalCenter: parent.verticalCenter
            text: patternPicker.expanded ? "▴" : "▾"
            color: headerMa.containsMouse ? Color.background : Color.foreground
            font.pixelSize: Style.font.caption
          }
          MouseArea {
            id: headerMa
            anchors.fill: parent
            hoverEnabled: true
            onClicked: patternPicker.expanded = !patternPicker.expanded
          }
        }

        ListView {
          width: parent.width
          visible: patternPicker.expanded
          height: patternPicker.expanded ? Math.min(count, 7) * (Style.spacing.controlHeight + Style.spacing.labelGap) : 0
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          model: patternPicker.options
          spacing: Style.spacing.labelGap
          delegate: Rectangle {
            width: parent.width
            height: Style.spacing.controlHeight
            radius: Style.cornerRadius
            color: optMa.containsMouse ? Color.accent : Color.popups.background
            Text {
              anchors.left: parent.left
              anchors.leftMargin: Style.spacing.controlPaddingX
              anchors.verticalCenter: parent.verticalCenter
              text: String(modelData.label)
              color: optMa.containsMouse ? Color.background : Color.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.body
            }
            MouseArea {
              id: optMa
              anchors.fill: parent
              hoverEnabled: true
              onClicked: {
                patternPicker.expanded = false
                if (patternPicker.value !== String(modelData.value)) {
                  patternPicker.value = String(modelData.value)
                  patternPicker.changed(patternPicker.value)
                }
              }
            }
          }
        }
      }

      Column {
        id: animPicker
        visible: root.activeTab === "controls"
        width: parent.width
        spacing: 0
        property string value: ""
        property bool expanded: false
        property var options: Model.animations
        signal changed(string value)
        onChanged: function(value) {
          var prev = root.stateFor(root.target).animation
          root.record("animation", value)
          if (value === "none") {
            root.runAction(["stop-animation"])
          } else {
            root.runAction(["animate", value])
            // Breathing/blinking modulate the grid as-is; coming from a
            // frame-streamer the grid holds residue, so re-apply the
            // tracked pattern underneath (queued after the animate action)
            if ((value === "breathing" || value === "blinking") && root.isOwningAnimation(prev)) {
              var p = root.stateFor(root.target).pattern
              if (p && p !== "text") root.runAction(["pattern", p])
            }
          }
        }
        function optionLabel(v) {
          for (var i = 0; i < options.length; i++)
            if (String(options[i].value) === v) return String(options[i].label)
          return ""
        }

        Rectangle {
          width: parent.width
          height: Style.spacing.controlHeight
          radius: Style.cornerRadius
          color: animHeaderMa.containsMouse ? Color.accent : Color.popups.background
          border.width: Style.normalBorderWidth
          border.color: Color.popups.border

          Text {
            anchors.left: parent.left
            anchors.leftMargin: Style.spacing.controlPaddingX
            anchors.verticalCenter: parent.verticalCenter
            text: "Animation: " + (animPicker.optionLabel(animPicker.value) || "None")
            color: animHeaderMa.containsMouse ? Color.background : Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }
          Text {
            anchors.right: parent.right
            anchors.rightMargin: Style.spacing.controlPaddingX
            anchors.verticalCenter: parent.verticalCenter
            text: animPicker.expanded ? "▴" : "▾"
            color: animHeaderMa.containsMouse ? Color.background : Color.foreground
            font.pixelSize: Style.font.caption
          }
          MouseArea {
            id: animHeaderMa
            anchors.fill: parent
            hoverEnabled: true
            onClicked: animPicker.expanded = !animPicker.expanded
          }
        }

        ListView {
          width: parent.width
          visible: animPicker.expanded
          height: animPicker.expanded ? Math.min(count, 7) * (Style.spacing.controlHeight + Style.spacing.labelGap) : 0
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          model: animPicker.options
          spacing: Style.spacing.labelGap
          delegate: Rectangle {
            width: parent.width
            height: Style.spacing.controlHeight
            radius: Style.cornerRadius
            color: animOptMa.containsMouse ? Color.accent : Color.popups.background
            Text {
              anchors.left: parent.left
              anchors.leftMargin: Style.spacing.controlPaddingX
              anchors.verticalCenter: parent.verticalCenter
              text: String(modelData.label)
              color: animOptMa.containsMouse ? Color.background : Color.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.body
            }
            MouseArea {
              id: animOptMa
              anchors.fill: parent
              hoverEnabled: true
              onClicked: {
                animPicker.expanded = false
                if (animPicker.value !== String(modelData.value)) {
                  animPicker.value = String(modelData.value)
                  animPicker.changed(animPicker.value)
                }
              }
            }
          }
        }
      }

      Row {
        width: parent.width
        spacing: Style.space(8)
        visible: root.activeTab === "controls" && root.stateFor(root.target).pattern === "text"

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
                animPicker.value = "none"
              }
              root.record("text", textInput.text)
              root.runAction(["text", textInput.text])
            }
          }
        }
      }

      Row {
        visible: root.activeTab === "controls"
        width: parent.width
        spacing: Style.space(8)

        Repeater {
          model: ["Sleep", "Wake", "Off"]
          delegate: Rectangle {
            width: (parent.width - 2 * Style.space(8)) / 3
            height: Style.spacing.controlHeight
            radius: Style.cornerRadius
            color: powerMa.containsMouse ? Color.accent : Color.popups.background
            border.width: Style.normalBorderWidth
            border.color: Color.popups.border

            Text {
              anchors.centerIn: parent
              text: modelData
              color: powerMa.containsMouse ? Color.background : Color.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.body
            }
            MouseArea {
              id: powerMa
              anchors.fill: parent
              hoverEnabled: true
              onClicked: root.runAction([modelData.toLowerCase()])
            }
          }
        }
      }

      Column {
        id: fwCol
        visible: root.activeTab === "firmware"
        onVisibleChanged: if (visible) { root.refreshDeviceInfo(); root.refreshLatest() }
        width: parent.width
        spacing: Style.space(10)

        Repeater {
          model: root.deviceInfo
          width: fwCol.width
          delegate: Column {
            width: fwCol.width
            spacing: Style.space(4)
            property var devRow: modelData

            Text {
              text: devRow.dev + " · port " + devRow.port
              color: Color.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.body
            }
            Text {
              text: "Firmware " + devRow.version +
                (root.latestFirmware === "" ? "" :
                 ("v" + devRow.version) === root.latestFirmware ? " · latest" :
                 devRow.version === "unknown" ? "" : " · update available: " + root.latestFirmware)
              color: Color.foreground
              opacity: 0.7
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }

            Row {
              width: parent.width
              spacing: Style.space(8)

              Button {
                text: "Identify"
                tooltipText: "Pulse this physical panel's brightness so you can tell which side it is"
                onClicked: {
                  identifyProc.command = [root.ctlPath, "--device", devRow.dev, "identify"]
                  if (!identifyProc.running) identifyProc.running = true
                }
              }

              ButtonGroup {
                visible: root.deviceInfo.length > 1
                options: [
                  { value: "left", label: "Left" },
                  { value: "right", label: "Right" }
                ]
                value: root.sideForPort(devRow.port)
                onChanged: function(value) { root.assignSide(devRow.dev, devRow.port, value) }
              }

              Button {
                text: root.flashArmed[devRow.dev] === true ? "Confirm flash" :
                      (root.latestFirmware ? "Flash " + root.latestFirmware : "Flash (offline)")
                tooltipText: root.latestFirmware === "" ? "Latest version unknown — check network and reopen this tab" : ""
                opacity: (root.latestFirmware === "" || root.flashing) ? 0.5 : 1.0
                onClicked: {
                  if (root.latestFirmware === "" || root.flashing) return
                  root.requestFlash(devRow.dev)
                }
              }
            }

            Text {
              visible: (root.flashStatus[devRow.dev] || "") !== ""
              text: root.flashStatus[devRow.dev] || ""
              color: Color.foreground
              opacity: 0.7
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
              width: fwCol.width
            }
          }
        }

        Text {
          text: root.latestFirmware === "" ? "Checking latest firmware…" :
                "Latest ledmatrix firmware: " + root.latestFirmware
          color: Color.foreground
          opacity: 0.6
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}
