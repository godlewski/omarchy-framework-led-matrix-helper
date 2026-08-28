import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "LedMatrixModel.js" as Model

// Framework 16 LED Matrix bar widget: icon button + keyboard-driven panel.
//
// This file owns all state and every Process; the tabs (ControlsTab,
// FirmwareTab) are pure views over it. Domain rules — what composes with
// what on the hardware — live in LedMatrixModel.js; read its header before
// touching display/effect handling.
BarWidget {
  id: root
  moduleName: "godlewski.framework-led-matrix-helper"

  readonly property string ctlPath: Qt.resolvedUrl("bin/led-matrix-ctl").toString().replace(/^file:\/\//, "")
  readonly property color fg: bar ? bar.foreground : Color.foreground

  // ---- settings (shell.json, hot-reloaded) ---------------------------------

  readonly property string leftPort: String(setting("leftPort", ""))
  readonly property string rightPort: String(setting("rightPort", ""))
  readonly property bool swapped: {
    var v = setting("swapped", false)
    return v === true || v === "true"
  }

  // ---- state ---------------------------------------------------------------

  property var devices: []
  property bool cliAvailable: false
  property string currentAnimation: ""

  // Missing binaries from `led-matrix-ctl deps` (empty = ready). While
  // anything is missing the widget shows a guided-setup state instead of
  // silently hiding, and offers the Omarchy-style install path (yay in a
  // floating presentation terminal — inputmodule-control lives in the AUR,
  // so pacman-only omarchy-pkg-add can't fetch it).
  property var missingDeps: []
  readonly property bool needsSetup: missingDeps.length > 0

  readonly property var depPackages: ({
    "inputmodule-control": "inputmodule-control",
    "python3": "python"
  })

  function installDeps() {
    if (!bar || missingDeps.length === 0) return
    var pkgs = []
    for (var i = 0; i < missingDeps.length; i++)
      pkgs.push(depPackages[missingDeps[i]] || missingDeps[i])
    bar.run("omarchy-launch-floating-terminal-with-presentation \"echo 'Installing LED Matrix dependencies...'; yay -S --needed "
      + pkgs.join(" ") + "\"")
  }

  function refreshDeps() {
    if (!depsProc.running) depsProc.running = true
  }
  property string target: "all"
  property bool awake: true
  property string activeTab: "controls"

  // Per-panel "off" — implemented as brightness 0 rather than firmware sleep,
  // because any serial command (even a status query) wakes a sleeping module,
  // so a sleeping panel under a running animation would immediately re-wake.
  // Brightness 0 keeps the panel dark while streams keep running elsewhere.
  // Session-local; the recorded brightness in panelState is left untouched so
  // turning a panel back on restores the user's level.
  property var panelOnMap: ({})

  function panelOn(dev) { return panelOnMap[dev] !== false }

  function setPanelOn(dev, on) {
    var m = {}
    for (var k in panelOnMap) m[k] = panelOnMap[k]
    m[dev] = on
    panelOnMap = m
    runActionFor(dev, ["brightness", on ? String(stateFor(dev).brightness) : "0"])
  }

  // Send a brightness value to a scope, skipping panels that are switched off
  // (so re-assertions after `animate` never re-light them).
  function sendBrightness(scope, value) {
    var scopeDevs = scope === "all" && devices.length > 0 ? devices : [scope]
    for (var i = 0; i < scopeDevs.length; i++) {
      if (scopeDevs[i] !== "all" && !panelOn(scopeDevs[i]))
        runActionFor(scopeDevs[i], ["brightness", "0"])
      else
        runActionFor(scopeDevs[i], ["brightness", String(value)])
    }
  }

  // Per-target { display, effect, text, brightness } — optimistic, since the
  // firmware has no readback for pattern/text/brightness.
  property var panelState: ({})

  // Staged edits (same shape/bucketing as panelState). The controls and the
  // emulated twin panels render staged state; nothing touches hardware until
  // commitStaged(). A bucket only exists once something was staged —
  // stagedFor() falls back to applied state, so revert is just clearing this.
  property var stagedState: ({})

  // ---- pattern editor ------------------------------------------------------

  // Saved drawings from `led-matrix-ctl list-patterns`: [{name, bits}]
  property var customPatterns: []

  // The working drawing (306 chars of 0/1) — survives panel close/reopen
  property string editorBits: Model.frameToBits(null)
  property string editorName: ""
  property bool editorLive: false
  property bool drawMode: false
  property int editorCursorX: 4
  property int editorCursorY: 17

  function customBitsFor(display) {
    return Model.customBits(display, customPatterns, editorBits)
  }

  function editorCellAt(x, y) {
    return editorBits.charAt(y * 9 + x) === "1"
  }

  function editorSetCell(x, y, v) {
    var i = y * 9 + x
    var c = v ? "1" : "0"
    if (editorBits.charAt(i) === c) return
    editorBits = editorBits.substring(0, i) + c + editorBits.substring(i + 1)
    if (editorLive) livePaintTimer.restart()
  }

  function clearEditor() {
    editorBits = Model.frameToBits(null)
    if (editorLive) livePaintTimer.restart()
  }

  function invertEditor() {
    var out = ""
    for (var i = 0; i < editorBits.length; i++)
      out += editorBits.charAt(i) === "1" ? "0" : "1"
    editorBits = out
    if (editorLive) livePaintTimer.restart()
  }

  // Seed the editor from whatever the current target is showing/staging
  function grabEditor() {
    var s = stagedFor(target)
    var f
    if (Model.ownsDisplay(s.display)) f = Model.streamFrame(s.display, animTick)
    else if (Model.isCustomDisplay(s.display)) f = Model.bitsToFrame(customBitsFor(s.display))
    else f = Model.staticFrame(s.display, Model.textChunkFor(s.text, 0), s.textDx, s.textDy)
    if (f) editorBits = Model.frameToBits(f)
  }

  // Editor bypasses staging — the grid IS the preview; sending is explicit
  // (or continuous with live paint). Records the applied display so the twins
  // and reopened panels agree with the hardware.
  function applyEditor() {
    runActionFor(target, ["frame", editorBits])
    record({ display: editorName ? Model.CUSTOM_PREFIX + editorName : Model.CUSTOM_UNSAVED })
    stagedState = {}
  }

  function saveEditor(name) {
    var n = String(name || "").trim()
    if (n.length === 0 || savePatternProc.running) return
    savePatternProc.pendingName = n
    savePatternProc.command = [ctlPath, "save-pattern", n, editorBits]
    savePatternProc.running = true
  }

  function loadPattern(name) {
    var bits = Model.customBits(Model.CUSTOM_PREFIX + name, customPatterns, "")
    if (!bits) return
    editorBits = bits
    editorName = name
  }

  function deletePattern(name) {
    if (deletePatternProc.running || !name) return
    deletePatternProc.command = [ctlPath, "delete-pattern", name]
    deletePatternProc.running = true
  }

  function refreshPatterns() {
    if (!patternsProc.running) patternsProc.running = true
  }

  // Import flow: desktop file chooser -> ctl import-pattern -> refresh the
  // library and load the result into the editor. Errors (wrong size, bad
  // name, unsupported PNG) surface in the editor tab via importError.
  property string importError: ""

  function importPatternFile() {
    if (importPickProc.running || importFileProc.running) return
    importError = ""
    importPickProc.running = true
  }

  property var deviceInfo: []
  property var flashStatus: ({})
  // Firmware flow is deliberately manual: the user downloads a .uf2 from
  // Framework's official releases and picks the file; led-matrix-flash
  // validates it (bounded regular-file read, UF2 magics, RP2040 family,
  // SHA-256 allowlist of Framework's v0.2.0 release images) before flashing.
  // No auto-fetching — the plugin never selects firmware on its own.
  property string flashFile: ""
  property string flashConfirmDev: ""
  property bool flashing: false

  readonly property var targetOpts: Model.targetOptions(devices, deviceInfo, leftPort, rightPort)

  visible: (cliAvailable && devices.length > 0) || needsSetup
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // ---- panel contract (Bar.findPanelWidget: opened/open/close on the root,
  // closeForPopoutSwitch + popoutSwitchClosing for popout coordination) ------

  property bool panelOpen: false
  readonly property bool opened: panelOpen
  property bool popoutSwitchClosing: false

  function open() { panelOpen = true }
  function close() { panelOpen = false }
  function toggle() { panelOpen ? close() : open() }
  function closeForPopoutSwitch() {
    popoutSwitchClosing = true
    close()
    Qt.callLater(function() { root.popoutSwitchClosing = false })
  }

  onPanelOpenChanged: {
    if (panelOpen) {
      cursorActive = false
      cursorRow = "power"
      flashConfirmDev = ""
      shiftMode = false
      drawMode = false
      stagedState = {}
      refresh()
      refreshPatterns()
      if (activeTab === "firmware") refreshFirmwareTab()
    }
  }

  // ---- per-target state helpers --------------------------------------------

  function stateFor(t) {
    var s = panelState[t]
    if (s) return s
    // A device with no bucket of its own inherits what was applied to "all"
    // (record() fans out on writes; this covers the status-reconcile path,
    // which only maintains the "all" bucket).
    if (t !== "all" && panelState["all"]) return panelState["all"]
    return Model.blankState()
  }

  // Merge `patch` into the given buckets. Always reassigns a fresh top-level
  // object: mutating in place keeps the same reference, QML sees no change,
  // and dependent bindings never re-evaluate.
  function recordFor(targets, patch) {
    var ps = {}
    for (var k in panelState) ps[k] = panelState[k]
    for (var i = 0; i < targets.length; i++) {
      var s = Model.blankState()
      var prev = ps[targets[i]]
      if (prev) for (var pk in prev) s[pk] = prev[pk]
      for (var key in patch) s[key] = patch[key]
      ps[targets[i]] = s
    }
    panelState = ps
  }

  // Record against the current target ("all" fans out to every bucket so a
  // later target switch shows what that panel is actually doing).
  function record(patch) {
    recordFor(target === "all" ? ["all"].concat(devices) : [target], patch)
  }

  // ---- staged edits --------------------------------------------------------

  function stagedFor(t) {
    var s = stagedState[t]
    return s ? s : stateFor(t)
  }

  // Merge `patch` into staged buckets for the current target (same "all"
  // fan-out as record()), seeding each bucket from its effective state.
  function stageRecord(patch) {
    var ps = {}
    for (var k in stagedState) ps[k] = stagedState[k]
    var targets = target === "all" ? ["all"].concat(devices) : [target]
    for (var i = 0; i < targets.length; i++) {
      var s = Model.blankState()
      var base = stagedFor(targets[i])
      for (var bk in base) s[bk] = base[bk]
      for (var key in patch) s[key] = patch[key]
      ps[targets[i]] = s
    }
    stagedState = ps
  }

  function stageDisplay(v) {
    // Streamers evict any effect (single host animation slot)
    if (Model.ownsDisplay(v)) stageRecord({ display: v, effect: "none" })
    else stageRecord({ display: v })
  }

  function stageEffect(v) { stageRecord({ effect: v }) }

  function stageText(t) { stageRecord({ display: "text", text: String(t || "") }) }

  function revertStaged() { stagedState = {} }

  function stageTextShift(ddx, ddy) {
    var s = stagedFor(target)
    var c = Model.clampShift(s.text, s.textDx + ddx, s.textDy + ddy)
    stageRecord({ display: "text", textDx: c.dx, textDy: c.dy })
  }

  readonly property bool pending: {
    var scopes = ["all"].concat(devices)
    for (var i = 0; i < scopes.length; i++) {
      var a = stateFor(scopes[i])
      var s = stagedFor(scopes[i])
      if (a.display !== s.display || a.effect !== s.effect) return true
      if (s.display === "text"
          && (a.text !== s.text || a.textDx !== s.textDx || a.textDy !== s.textDy)) return true
    }
    return false
  }

  readonly property bool canApply: pending
    && !(stagedFor(target).display === "text" && stagedFor(target).text.length === 0)

  // Send the staged diff to hardware, then fold it into the applied state.
  // Uniform diffs go out as one all-target command (so text spans panels);
  // otherwise each device gets its own.
  function commitStaged() {
    if (!canApply) return
    var scopes
    if (devices.length < 2) {
      scopes = ["all"]
    } else {
      var s0 = stagedFor(devices[0])
      var s1 = stagedFor(devices[1])
      scopes = (s0.display === s1.display && s0.effect === s1.effect && s0.text === s1.text)
        ? ["all"] : devices.slice()
    }
    for (var i = 0; i < scopes.length; i++) commitScope(scopes[i])
    stagedState = {}
  }

  function commitScope(scope) {
    var applied = stateFor(scope)
    var staged = stagedFor(scope)
    var patch = { display: staged.display, effect: staged.effect, text: staged.text }
    var displayChanged = staged.display !== applied.display
      || (staged.display === "text" && staged.text !== applied.text)

    if (displayChanged && staged.display !== "") {
      if (Model.ownsDisplay(staged.display)) {
        // The ctl forces brightness to 80 on animate so the stream is
        // visible; re-assert per-panel levels (including off panels at 0).
        runActionFor(scope, ["animate", staged.display])
        sendBrightness(scope, applied.brightness)
      } else if (staged.display === "text") {
        // Text goes out as rendered frames so pixel shifts apply; a uniform
        // "all" commit splits the string across panels, 5 chars each.
        var scopeDevs = scope === "all" && devices.length > 0 ? devices : [scope]
        for (var i = 0; i < scopeDevs.length; i++) {
          var chunk = Model.textChunkFor(staged.text, scope === "all" ? i : 0)
          var f = Model.frameText(chunk, staged.textDx, staged.textDy)
          runActionFor(scopeDevs[i], ["frame", Model.frameToBits(f)])
        }
      } else if (Model.isCustomDisplay(staged.display)) {
        var cb = customBitsFor(staged.display)
        if (cb) runActionFor(scope, ["frame", cb])
      } else {
        // All On lifts the firmware brightness cap to max — reflect that.
        if (staged.display === "all-on") patch.brightness = 100
        runActionFor(scope, ["pattern", staged.display])
      }
    }

    if (!Model.ownsDisplay(staged.display) && staged.effect !== applied.effect) {
      if (staged.effect === "none") {
        runActionFor(scope, ["stop-animation"])
        // A killed modulator leaves brightness wherever the loop last put it.
        sendBrightness(scope, applied.brightness)
      } else {
        // Modulator loops own brightness on every panel they run on, so a
        // per-panel "off" cannot survive an effect — reflect that honestly.
        panelOnMap = {}
        runActionFor(scope, ["animate", staged.effect])
      }
    }

    recordFor(scope === "all" ? ["all"].concat(devices) : [scope], patch)
  }

  // ---- immediate actions (not staged) --------------------------------------

  function applyBrightness(v) {
    var b = Math.max(0, Math.min(100, Math.round(v)))
    record({ brightness: b })
    // Off panels only get the recorded value once they're switched back on
    sendBrightness(target, b)
  }

  function setAwake(on) {
    awake = on
    runAction([on ? "wake" : "sleep"])
  }

  function identify(dev) {
    identifyProc.command = [ctlPath, "--device", dev, "identify"]
    if (!identifyProc.running) identifyProc.running = true
  }

  // ---- serialized action queue ---------------------------------------------

  property var pendingActions: []

  function ctlBase() {
    return swapped ? [ctlPath, "--swap"] : [ctlPath]
  }

  function runActionFor(scope, args) {
    if (actionProc.running) {
      pendingActions = pendingActions.concat([{ scope: scope, args: args }])
      return
    }
    var cmd = ctlBase()
    if (scope !== "all") cmd = cmd.concat(["--device", scope])
    actionProc.command = cmd.concat(args)
    actionProc.running = true
  }

  function runAction(args) { runActionFor(target, args) }

  // ---- refresh -------------------------------------------------------------

  function refresh() {
    if (!listProc.running) listProc.running = true
    refreshStatus()
    // Re-probe dependencies until healthy so finishing the guided install
    // flips the widget into its normal state within one refresh cycle
    if (!cliAvailable) refreshDeps()
  }

  function refreshStatus() {
    if (cliAvailable && !statusProc.running) statusProc.running = true
  }

  function refreshFirmwareTab() {
    if (!infoProc.running) infoProc.running = true
  }

  function openFirmwareReleases() {
    if (bar) bar.run("xdg-open https://github.com/FrameworkComputer/inputmodule-rs/releases")
  }

  function setActiveTab(tabId) {
    activeTab = tabId
    drawMode = false
    if (tabId === "firmware") refreshFirmwareTab()
    if (tabId === "editor") refreshPatterns()
  }

  onSwappedChanged: refresh()
  onSettingsChanged: deriveSwap()
  Component.onCompleted: if (!infoProc.running) infoProc.running = true

  // ---- settings writes (serialized through `omarchy bar set`) --------------

  property var pendingSettings: []

  function barSet(key, value) {
    pendingSettings.push([key, value])
    if (!settingsProc.running) runNextSetting()
  }

  function runNextSetting() {
    var next = pendingSettings.shift()
    if (!next) return
    // No --json: it silently drops a false value (first-party CLI quirk)
    settingsProc.command = ["omarchy", "bar", "set", root.moduleName, next[0], String(next[1])]
    settingsProc.running = true
  }

  function assignSide(port, side) {
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
    if (!leftPort) return
    // Unconditional write: comparing against the swapped binding races the
    // hot-reload of that very value. Identical writes produce no file change,
    // so this converges immediately instead of oscillating.
    barSet("swapped", deviceInfo[0].port !== leftPort ? "true" : "false")
  }

  function toggleSwap() {
    barSet("swapped", swapped ? "false" : "true")
  }

  // ---- flashing ------------------------------------------------------------

  // Flash flow: pick a .uf2 with the desktop chooser, then confirm, then
  // hand it to led-matrix-flash (which validates before touching hardware).
  function beginFlashConfirm(dev) {
    if (flashing || flashPickProc.running) return
    flashPickProc.forDev = dev
    flashPickProc.running = true
  }

  function startFlash(dev) {
    flashConfirmDev = ""
    if (flashing || flashFile === "" || dev === "") return
    flashing = true
    setFlashStatus(dev, "Validating " + flashFile.split("/").pop() + "…")
    runAction(["stop-animation"])
    flashProc.forDev = dev
    flashProc.command = [ctlPath.replace(/led-matrix-ctl$/, "led-matrix-flash"), dev, flashFile]
    flashProc.running = true
  }

  function setFlashStatus(dev, msg) {
    var fs = {}
    for (var k in flashStatus) fs[k] = flashStatus[k]
    fs[dev] = msg
    flashStatus = fs
  }

  // ---- keyboard cursor -----------------------------------------------------
  //
  // Flat row list per active tab; PanelKeyCatcher drives it, mouse hover
  // syncs into it via setCursor, and every row paints only from cursorRow
  // (the CursorSurface contract — one highlight on screen at a time).

  property bool cursorActive: false
  property string cursorRow: "power"

  // While true, hjkl/arrows nudge the staged text instead of moving the
  // cursor; Enter or Esc leaves the mode.
  property bool shiftMode: false

  readonly property var cursorRows: {
    if (needsSetup) return ["install"]
    var rows = ["power", "tabs"]
    if (activeTab === "controls") {
      if (devices.length > 1)
        for (var d = 0; d < devices.length; d++) rows.push("panelpower:" + d)
      if (devices.length > 1) rows.push("target")
      rows.push("brightness", "display")
      var s = stagedFor(target)
      if (s.display === "text") rows.push("text", "shift")
      if (!Model.ownsDisplay(s.display)) rows.push("effect")
      if (pending) rows.push("apply")
    } else if (activeTab === "editor") {
      rows.push("editor", "edapply", "edlive")
    } else {
      for (var i = 0; i < deviceInfo.length; i++) {
        rows.push("identify:" + i)
        if (deviceInfo.length > 1) rows.push("side:" + i)
        rows.push("flash:" + i)
      }
    }
    return rows
  }

  function setCursor(row) {
    cursorActive = true
    cursorRow = row
  }

  function focusPanelKeys() {
    keyCatcher.forceActiveFocus()
  }

  function moveCursor(dy) {
    if (!cursorActive) {
      cursorActive = true
      if (cursorRows.indexOf(cursorRow) < 0) cursorRow = cursorRows[0]
      return
    }
    var i = cursorRows.indexOf(cursorRow)
    if (i < 0) { cursorRow = cursorRows[0]; return }
    cursorRow = cursorRows[Math.max(0, Math.min(cursorRows.length - 1, i + dy))]
  }

  function rowIndex(row) {
    return parseInt(row.split(":")[1], 10)
  }

  function adjustCursor(dx) {
    if (!cursorActive) { cursorActive = true; return }
    if (cursorRow === "tabs") {
      setActiveTab(dx > 0 ? "firmware" : "controls")
    } else if (cursorRow === "target") {
      target = Model.stepValue(targetOpts, target, dx)
    } else if (cursorRow === "brightness") {
      applyBrightness(stateFor(target).brightness + dx * 5)
    } else if (cursorRow === "effect") {
      stageEffect(Model.stepValue(Model.effectOptions, stagedFor(target).effect, dx))
    } else if (cursorRow === "shift") {
      stageTextShift(dx, 0)
    } else if (cursorRow.indexOf("side:") === 0) {
      var row = deviceInfo[rowIndex(cursorRow)]
      if (row) assignSide(row.port, dx > 0 ? "right" : "left")
    }
  }

  function activateCursor() {
    if (!cursorActive) { cursorActive = true; return }
    if (cursorRow === "install") {
      installDeps()
    } else if (cursorRow === "power") {
      setAwake(!awake)
    } else if (cursorRow === "tabs") {
      setActiveTab(activeTab === "controls" ? "firmware" : "controls")
    } else if (cursorRow === "display") {
      controlsTab.openDisplayDropdown()
    } else if (cursorRow === "text") {
      controlsTab.focusText()
    } else if (cursorRow === "shift") {
      shiftMode = true
    } else if (cursorRow === "apply") {
      commitStaged()
    } else if (cursorRow === "editor") {
      drawMode = true
    } else if (cursorRow === "edapply") {
      applyEditor()
    } else if (cursorRow === "edlive") {
      editorLive = !editorLive
    } else if (cursorRow.indexOf("panelpower:") === 0) {
      var pdev = devices[rowIndex(cursorRow)]
      if (pdev) setPanelOn(pdev, !panelOn(pdev))
    } else if (cursorRow.indexOf("identify:") === 0) {
      var row = deviceInfo[rowIndex(cursorRow)]
      if (row) identify(row.dev)
    } else if (cursorRow.indexOf("flash:") === 0) {
      var frow = deviceInfo[rowIndex(cursorRow)]
      if (frow) beginFlashConfirm(frow.dev)
    }
  }

  // ---- IPC -----------------------------------------------------------------

  IpcHandler {
    target: "godlewski.framework-led-matrix-helper"
    function refresh(): void { root.broadcast("refresh") }
    function toggle(): void { root.toggle() }
    function open(): void { root.open() }
    function close(): void { root.close() }
    function sleep(): void { root.setAwake(false) }
    function wake(): void { root.setAwake(true) }
  }

  // ---- processes -----------------------------------------------------------

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
      if (root.devices.length <= 1 || root.devices.indexOf(root.target) === -1)
        root.target = "all"
      // The bar icon hides when no panels are present — close an open popup
      // too, or it lingers orphaned with ghost state after an unplug. The
      // setup state keeps its popup: it has no devices by definition.
      if (root.devices.length === 0 && !root.needsSetup && root.panelOpen)
        root.close()
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
      // Reconcile the "all" bucket with hardware truth so a reopened panel
      // agrees with an animation started (or killed) outside this session.
      var s = root.stateFor("all")
      var status = statusProc.status
      if (status.length > 0) {
        if (Model.ownsDisplay(status)) {
          if (s.display !== status) root.recordFor(["all"], { display: status, effect: "none" })
        } else if (s.effect !== status) {
          root.recordFor(["all"], { effect: status })
        }
      } else if (Model.ownsDisplay(s.display) || s.effect !== "none") {
        // The animator died (or was stopped outside this session).
        root.recordFor(["all"], {
          display: Model.ownsDisplay(s.display) ? "" : s.display,
          effect: "none"
        })
      }
    }
  }

  Process {
    id: actionProc
    onExited: function(exitCode) {
      statusRefreshTimer.restart()
      root.broadcast("refreshStatus")
      if (root.pendingActions.length > 0) {
        var queue = root.pendingActions
        var next = queue[0]
        root.pendingActions = queue.slice(1)
        root.runActionFor(next.scope, next.args)
      }
    }
  }

  Process { id: identifyProc }

  Process {
    id: depsProc
    command: [root.ctlPath, "deps"]
    property var found: []
    onStarted: found = []
    stdout: SplitParser {
      onRead: function(line) {
        var dep = String(line || "").trim()
        if (dep.length > 0) depsProc.found.push(dep)
      }
    }
    onExited: function(exitCode) {
      if (exitCode === 0) root.missingDeps = depsProc.found
    }
  }

  // Set before refreshPatterns() to load a pattern into the editor as soon
  // as the refreshed library arrives (the import flow uses this).
  property string pendingLoadName: ""

  Process {
    id: patternsProc
    command: [root.ctlPath, "list-patterns"]
    property var rows: []
    onStarted: rows = []
    stdout: SplitParser {
      onRead: function(line) {
        var idx = String(line || "").indexOf("|")
        if (idx > 0)
          patternsProc.rows.push({ name: String(line).substring(0, idx), bits: String(line).substring(idx + 1) })
      }
    }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.customPatterns = patternsProc.rows
        if (root.pendingLoadName.length > 0) {
          root.loadPattern(root.pendingLoadName)
          root.pendingLoadName = ""
        }
      }
    }
  }

  Process {
    id: savePatternProc
    property string pendingName: ""
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.editorName = savePatternProc.pendingName
        root.refreshPatterns()
      }
    }
  }

  Process {
    id: deletePatternProc
    onExited: root.refreshPatterns()
  }

  Process {
    id: importPickProc
    command: ["omarchy-file-select", "--title", "Import 9x34 PNG pattern", "--extensions", "png"]
    property string picked: ""
    onStarted: picked = ""
    stdout: SplitParser {
      onRead: function(line) {
        var p = String(line || "").trim()
        if (p.length > 0) importPickProc.picked = p
      }
    }
    onExited: function(exitCode) {
      if (exitCode === 0 && importPickProc.picked.length > 0) {
        importFileProc.command = [root.ctlPath, "import-pattern", importPickProc.picked]
        importFileProc.running = true
      }
    }
  }

  Process {
    id: importFileProc
    property string savedPath: ""
    property string errText: ""
    onStarted: { savedPath = ""; errText = "" }
    stdout: SplitParser {
      onRead: function(line) {
        var p = String(line || "").trim()
        if (p.length > 0) importFileProc.savedPath = p
      }
    }
    stderr: SplitParser {
      onRead: function(line) {
        var e = String(line || "").trim()
        if (e.length > 0) importFileProc.errText = e
      }
    }
    onExited: function(exitCode) {
      if (exitCode === 0 && importFileProc.savedPath.length > 0) {
        var base = importFileProc.savedPath.split("/").pop()
        root.pendingLoadName = base.replace(/\.png$/, "")
        root.refreshPatterns()
      } else {
        root.importError = importFileProc.errText || "Import failed"
      }
    }
  }

  // Coalesces live-paint strokes into one frame send; waits out a busy
  // action queue instead of piling frames into it.
  Timer {
    id: livePaintTimer
    interval: 200
    onTriggered: {
      if (actionProc.running) restart()
      else root.applyEditor()
    }
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
    id: flashPickProc
    command: ["omarchy-file-select", "--title", "Choose ledmatrix firmware (.uf2)", "--extensions", "uf2"]
    property string forDev: ""
    property string picked: ""
    onStarted: picked = ""
    stdout: SplitParser {
      onRead: function(line) {
        var p = String(line || "").trim()
        if (p.length > 0) flashPickProc.picked = p
      }
    }
    onExited: function(exitCode) {
      if (exitCode === 0 && flashPickProc.picked.length > 0) {
        root.flashFile = flashPickProc.picked
        root.flashConfirmDev = flashPickProc.forDev
      }
    }
  }

  Process {
    id: flashProc
    property string forDev: ""
    stdout: SplitParser {
      onRead: function(line) {
        var msg = String(line || "")
        if (msg.length > 0) root.setFlashStatus(flashProc.forDev, msg)
      }
    }
    onExited: {
      root.flashing = false
      root.flashFile = ""
      root.refreshFirmwareTab()
      root.refresh()
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
    onTriggered: root.refreshStatus()
  }

  // The firmware sleeps 60s after the last received command (SLEEP_TIMEOUT in
  // ledmatrix main.rs) and every command resets that timer. Host animations
  // keep it awake by streaming; static displays (patterns/text/drawings) go
  // silent and would fade out — so nudge each lit panel with its current
  // brightness (write-only, grid untouched) before the timeout hits. Panels
  // switched off are skipped: firmware sleep is fine for them (they're dark
  // either way, and the on-toggle's brightness command wakes them).
  Timer {
    interval: 45000
    running: root.visible && root.awake && root.currentAnimation === "" && !root.flashing
    repeat: true
    onTriggered: {
      for (var i = 0; i < root.devices.length; i++) {
        var d = root.devices[i]
        if (root.panelOn(d))
          root.runActionFor(d, ["brightness", String(root.stateFor(d).brightness)])
      }
    }
  }

  // ---- twin animation clock ------------------------------------------------
  // 100ms ticks drive the emulated panels' streams and effects. Static
  // displays never reference animTick, so their bindings stay quiet, and the
  // timer only runs while something animated is actually staged.

  property int animTick: 0

  readonly property bool twinsAnimating: {
    var scopes = ["all"].concat(devices)
    for (var i = 0; i < scopes.length; i++) {
      var s = stagedFor(scopes[i])
      if (Model.ownsDisplay(s.display) || s.effect !== "none") return true
    }
    return false
  }

  Timer {
    interval: 100
    running: root.panelOpen && root.awake && root.twinsAnimating
    repeat: true
    onTriggered: root.animTick++
  }

  // ---- bar button ----------------------------------------------------------

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    slotSize: Style.bar.statusSlot
    fontSize: Style.font.caption
    active: root.currentAnimation !== ""
    tooltipText: root.needsSetup
      ? "LED Matrix · setup needed (missing: " + root.missingDeps.join(", ") + ")"
      : "LED Matrix · " + Model.tooltip(root.devices.length, root.currentAnimation)
    onPressed: function(b) {
      if (b === Qt.RightButton) root.setAwake(!root.awake)
      else root.toggle()
    }
    onWheelMoved: function(delta) {
      root.applyBrightness(root.stateFor(root.target).brightness + (delta > 0 ? 5 : -5))
    }
  }

  // ---- panel ---------------------------------------------------------------

  KeyboardPanel {
    id: popup
    anchorItem: button
    bar: root.bar
    owner: root
    open: root.panelOpen
    focusTarget: keyCatcher
    contentWidth: popup.fittedContentWidth(Style.space(360))
    // No fixed cap — track the content and let fittedContentHeight clamp to
    // the screen; the ScrollView inside picks up any remainder.
    contentHeight: popup.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: (root.activeTab === "controls" && controlsTab.keysBlocked)
        || (root.activeTab === "editor" && editorTab.keysBlocked)

      onCloseRequested: {
        if (root.shiftMode) { root.shiftMode = false; return }
        if (root.drawMode) { root.drawMode = false; return }
        if (root.flashConfirmDev !== "") { root.flashConfirmDev = ""; return }
        root.close()
      }
      onTabRequested: function(direction) {
        if (root.flashConfirmDev !== "") {
          flashConfirm.selectedIndex = flashConfirm.selectedIndex === 0 ? 1 : 0
          return
        }
        root.switchPanel(direction)
      }
      onMoveRequested: function(dx, dy) {
        if (root.shiftMode) { root.stageTextShift(dx, dy); return }
        if (root.drawMode) {
          root.editorCursorX = Math.max(0, Math.min(8, root.editorCursorX + dx))
          root.editorCursorY = Math.max(0, Math.min(33, root.editorCursorY + dy))
          return
        }
        if (root.flashConfirmDev !== "") {
          if (dx !== 0) flashConfirm.selectedIndex = flashConfirm.selectedIndex === 0 ? 1 : 0
          return
        }
        if (dy !== 0) root.moveCursor(dy)
        else if (dx !== 0) root.adjustCursor(dx)
      }
      onActivateRequested: {
        if (root.shiftMode) { root.shiftMode = false; return }
        if (root.drawMode) {
          root.editorSetCell(root.editorCursorX, root.editorCursorY,
            root.editorCellAt(root.editorCursorX, root.editorCursorY) ? 0 : 1)
          return
        }
        if (root.flashConfirmDev !== "") {
          if (flashConfirm.selectedIndex === 0) root.flashConfirmDev = ""
          else root.startFlash(root.flashConfirmDev)
          return
        }
        root.activateCursor()
      }
      // 'x' discards staged edits (PanelKeyCatcher's delete gesture)
      onDeleteRequested: if (root.pending) root.revertStaged()

      // Scroll is a safety net for short screens — the panel normally sizes
      // itself to the content via contentHeight above, so the view only
      // becomes interactive when the screen clamp actually cuts content off.
      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: column.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff

        Binding {
          target: scrollArea.contentItem
          property: "interactive"
          value: column.implicitHeight > scrollArea.height
        }

        Column {
          id: column
          width: scrollArea.availableWidth
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: "LED Matrix"
            meta: root.needsSetup ? "setup needed"
              : Model.statusMeta(root.devices.length, root.currentAnimation, root.awake)
            foreground: root.fg
            iconComponent: Component {
              Text {
                text: ""
                color: root.fg
                font.family: Style.font.family
                font.pixelSize: Style.font.display
                opacity: root.awake ? 1.0 : 0.5
              }
            }
            trailingControl: Component {
              ToggleSwitch {
                checked: root.awake
                hasCursor: root.cursorActive && root.cursorRow === "power"
                foreground: root.fg
                onToggled: root.setAwake(!root.awake)
                onHovered: function(isHovered) { if (isHovered) root.setCursor("power") }

                PanelToolTip {
                  visible: parent.containsMouse
                  text: root.awake ? "Sleep panels" : "Wake panels"
                  fontFamily: Style.font.family
                }
              }
            }
          }

          PanelSeparator { foreground: root.fg }

          // ---- guided setup (missing dependencies) ----
          Column {
            visible: root.needsSetup
            width: parent.width
            spacing: Style.space(10)

            Text {
              width: parent.width
              text: "This widget drives the LED Matrix panels through "
                + root.missingDeps.join(", ")
                + (root.missingDeps.length === 1 ? ", which isn't" : ", which aren't")
                + " installed yet."
              color: root.fg
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
            }

            Button {
              text: "Install dependencies"
              bordered: true
              selected: true
              foreground: root.fg
              hasCursor: root.cursorActive && root.cursorRow === "install"
              tooltipText: "Runs yay in a floating terminal (inputmodule-control comes from the AUR)"
              onClicked: root.installDeps()
              onHovered: function(isHovered) { if (isHovered) root.setCursor("install") }
            }

            Text {
              width: parent.width
              text: "The widget switches to its controls automatically once the install finishes and the panels are detected."
              color: Qt.darker(root.fg, 1.4)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          CursorSurface {
            visible: !root.needsSetup
            width: parent.width
            implicitHeight: tabGroup.implicitHeight + Style.spacing.md
            hasCursor: root.cursorActive && root.cursorRow === "tabs"
            foreground: root.fg

            ButtonGroup {
              id: tabGroup
              anchors.centerIn: parent
              options: [
                { value: "controls", label: "Controls" },
                { value: "editor", label: "Editor" },
                { value: "firmware", label: "Panels" }
              ]
              value: root.activeTab
              focusable: false
              foreground: root.fg
              onChanged: function(value) { root.setActiveTab(value) }
              onHovered: function(index, isHovered) { if (isHovered) root.setCursor("tabs") }
            }
          }

          ControlsTab {
            id: controlsTab
            visible: root.activeTab === "controls" && !root.needsSetup
            width: parent.width
            widget: root
          }

          EditorTab {
            id: editorTab
            visible: root.activeTab === "editor" && !root.needsSetup
            width: parent.width
            widget: root
          }

          FirmwareTab {
            visible: root.activeTab === "firmware" && !root.needsSetup
            width: parent.width
            widget: root
          }
        }
      }

      ConfirmDialog {
        id: flashConfirm
        anchors.fill: parent
        z: 10
        opened: root.flashConfirmDev !== ""
        message: "Flash " + root.flashFile.split("/").pop() + " to the "
          + Model.deviceLabel(root.flashConfirmDev, root.devices, root.deviceInfo, root.leftPort, root.rightPort).toLowerCase()
          + "? It goes dark for a moment during the update."
        confirmText: "Flash"
        foreground: root.fg
        onOpenedChanged: if (opened) selectedIndex = 1
        onCanceled: root.flashConfirmDev = ""
        onConfirmed: root.startFlash(root.flashConfirmDev)
      }
    }
  }
}
