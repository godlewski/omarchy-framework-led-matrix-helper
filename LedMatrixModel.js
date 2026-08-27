// Pure presentation/domain logic for the LED Matrix widget. No QML types in
// here — everything takes plain values so it stays trivially testable and the
// QML files stay declarative.
//
// The core domain model ("display" vs "effect") mirrors what the firmware and
// led-matrix-ctl actually do:
//
//   display — what owns the 9x34 grid. Exactly one at a time:
//     kind "pattern"  firmware pattern / rendered image, static
//     kind "text"     firmware string render, static
//     kind "stream"   host-side frame streamer (clock, eq, mic-eq, bounce);
//                     continuously overwrites the grid, so selecting one
//                     replaces whatever pattern/text was showing
//   effect — a host-side brightness modulator (breathing, blinking). It never
//     touches the grid, so it composes with pattern/text displays. It cannot
//     run alongside a stream: both are host animation loops and the ctl keeps
//     a single animation slot (one PID file).
//
// The UI enforces those rules (effects disabled while a stream owns the
// display) instead of patching up conflicts after the fact.

.pragma library

var displayOptions = [
  { value: "logo", label: "Omarchy Logo", kind: "pattern" },
  { value: "gradient", label: "Gradient", kind: "pattern" },
  { value: "double-gradient", label: "Double Gradient", kind: "pattern" },
  { value: "lotus-sideways", label: "Lotus Sideways", kind: "pattern" },
  { value: "lotus-top-down", label: "Lotus Top Down", kind: "pattern" },
  { value: "zigzag", label: "Zigzag", kind: "pattern" },
  { value: "all-on", label: "All On", kind: "pattern" },
  { value: "text", label: "Text…", kind: "text" },
  { value: "clock", label: "Clock", kind: "stream" },
  { value: "eq", label: "Random EQ", kind: "stream" },
  { value: "mic-eq", label: "Mic EQ", kind: "stream" },
  { value: "bounce", label: "Bounce Logo", kind: "stream" }
]

var effectOptions = [
  { value: "none", label: "None" },
  { value: "breathing", label: "Breathe" },
  { value: "blinking", label: "Blink" }
]

function displayKind(value) {
  for (var i = 0; i < displayOptions.length; i++)
    if (displayOptions[i].value === value) return displayOptions[i].kind
  return ""
}

// True for displays that stream frames and own the grid (selecting a pattern
// under one is meaningless; effects can't run alongside one).
function ownsDisplay(value) {
  return displayKind(value) === "stream"
}

function optionLabel(options, value) {
  for (var i = 0; i < options.length; i++)
    if (String(options[i].value) === String(value)) return String(options[i].label)
  return ""
}

// Step through option values by delta with clamping at the ends.
function stepValue(options, current, delta) {
  var idx = 0
  for (var i = 0; i < options.length; i++)
    if (String(options[i].value) === String(current)) { idx = i; break }
  var next = Math.max(0, Math.min(options.length - 1, idx + delta))
  return String(options[next].value)
}

// Per-target optimistic UI state. There is no firmware readback for
// pattern/text/brightness, so this is the session's best knowledge.
function blankState() {
  return { display: "", effect: "none", text: "", textDx: 0, textDy: 0, brightness: 80 }
}

// ---- device labeling -------------------------------------------------------
//
// `devices` is the effective (possibly swapped) order from `led-matrix-ctl
// list`; `deviceInfo` rows ({dev, port, version}) come from `device-info`,
// which always runs unswapped. Both share /dev/tty paths, so matching on the
// path is safe. Physical sides only exist once the user has assigned USB
// ports (leftPort/rightPort settings) — until then panels are just "Panel N".

function sideForPort(port, leftPort, rightPort) {
  if (leftPort && String(port) === String(leftPort)) return "left"
  if (rightPort && String(port) === String(rightPort)) return "right"
  return ""
}

function deviceSide(dev, deviceInfo, leftPort, rightPort) {
  for (var i = 0; i < deviceInfo.length; i++)
    if (deviceInfo[i].dev === dev)
      return sideForPort(deviceInfo[i].port, leftPort, rightPort)
  return ""
}

function sideLabel(side) {
  if (side === "left") return "Left"
  if (side === "right") return "Right"
  return ""
}

function panelLabel(index) {
  return "Panel " + (index + 1)
}

// Short human name for one device: assigned side if known, positional otherwise.
function deviceLabel(dev, devices, deviceInfo, leftPort, rightPort) {
  var side = sideLabel(deviceSide(dev, deviceInfo, leftPort, rightPort))
  if (side) return side + " panel"
  var idx = devices.indexOf(dev)
  return idx >= 0 ? panelLabel(idx) : String(dev)
}

function targetOptions(devices, deviceInfo, leftPort, rightPort) {
  var opts = [{ value: "all", label: devices.length > 1 ? "Both" : "All" }]
  for (var i = 0; i < devices.length; i++) {
    var side = sideLabel(deviceSide(devices[i], deviceInfo, leftPort, rightPort))
    opts.push({ value: devices[i], label: side || panelLabel(i) })
  }
  return opts
}

// ---- status text -----------------------------------------------------------

function tooltip(deviceCount, animation) {
  if (deviceCount === 0)
    return "No LED Matrix panels detected"
  var state = animation && animation.length > 0 ? animation : "idle"
  return deviceCount + (deviceCount === 1 ? " panel" : " panels") + " · " + state
}

// Hero meta line, e.g. "2 panels · clock" (PanelHero uppercases it).
function statusMeta(deviceCount, animation, awake) {
  if (!awake) return deviceCount + (deviceCount === 1 ? " panel" : " panels") + " · sleeping"
  return tooltip(deviceCount, animation)
}

// Firmware row subtitle: version plus how it relates to the latest release.
function firmwareLine(version, latestTag) {
  var line = "Firmware " + version
  if (!latestTag || version === "unknown") return line
  if ("v" + version === latestTag) return line + " · latest"
  return line + " · update available: " + latestTag
}

// ---- panel emulation -------------------------------------------------------
//
// Frame generators that replicate what the hardware draws, for the emulated
// twin panels in the UI. A frame is a flat array of 306 values in [0,1],
// row-major (index = y * 9 + x), x left→right, y top→bottom as the module
// sits in the laptop. Sources: FrameworkComputer/inputmodule-rs —
// inputmodule-control/src/{font.rs,inputmodule.rs} (5x6 font, show_font
// stacking, clock, eq) and fl16-inputmodules/src/patterns.rs (gradient,
// double-gradient, zigzag, lotus, percentage). Exact where the source is
// deterministic; eq/lotus-sideways are close approximations.

var GRID_W = 9
var GRID_H = 34

// 5x6 row-major bitstrings extracted from font.rs convert_font()
var FONT = {
  " ": "000000000000000000000000000000",
  "!": "001000010000100001000000000100",
  "%": "110011101100110011001101110011",
  "*": "000000101000100010100000000000",
  "+": "001000010011111001000010000000",
  ",": "000000000000000001000000000000",
  "-": "000000000011111000000000000000",
  ".": "000000000000000001000000000000",
  "/": "000010001100110011001100010000",
  "0": "011101000110101101011000101110",
  "1": "001000110010100001000010011111",
  "2": "111100000111111100001000011111",
  "3": "111100000111111000010000111110",
  "4": "000100011001010111110001000010",
  "5": "111111000011111000010000111110",
  "6": "011101000011111100011000101110",
  "7": "111110000100010001000010000100",
  "8": "011101000101110100011000101110",
  "9": "011101000111111000010000101110",
  ":": "000000000000100000000010000000",
  "=": "000001111100000111110000000000",
  "?": "011000001000010001000000000100",
  "A": "011101000111111100011000110001",
  "B": "111001001011100100101001011100",
  "C": "111101000010000100001000011110",
  "D": "111101000110001100011000111110",
  "E": "111111000011111100001000011111",
  "F": "111101000011110100001000010000",
  "G": "011101000010111100011000101110",
  "H": "100011000111111100011000110001",
  "I": "111110010000100001000010011111",
  "J": "011110000100001000010000101110",
  "K": "100101010011000110001010010010",
  "L": "100001000010000100001000011111",
  "M": "000000101010101101011010110101",
  "N": "100011100110101100111000110001",
  "O": "011101000110001100011000101110",
  "P": "111001001010010111001000010000",
  "Q": "011101000110001101011001001101",
  "R": "111101001011110110001010010010",
  "S": "011111000010000011100000111110",
  "T": "111110010000100001000010000100",
  "U": "100011000110001100011000101110",
  "V": "100011000110001010100101000100",
  "W": "101011010110101101010101001010",
  "X": "000001000101010001000101010001",
  "Y": "100011000101010001000010000100",
  "Z": "111110001000100010001000011111"
}

// display_lotus2() from patterns.rs — "LOTUS" reading top-down
var LOTUS_TOPDOWN = [
  "001000000",
  "001000000",
  "001000000",
  "001000000",
  "001000000",
  "001111100",
  "000000000",
  "001111100",
  "001000100",
  "001000100",
  "001000100",
  "001000100",
  "001111100",
  "000000000",
  "001111100",
  "000010000",
  "000010000",
  "000010000",
  "000010000",
  "000010000",
  "000000000",
  "001000100",
  "001000100",
  "001000100",
  "001000100",
  "001000100",
  "001111100",
  "000000000",
  "001111100",
  "001000000",
  "001111100",
  "000000100",
  "000000100",
  "001111100"
]

// 9x9 Omarchy logo (matches assets/omarchy-logo-9x34.png rows 12-20)
var LOGO = [
  "111111111",
  "100010001",
  "101110111",
  "101000101",
  "111000101",
  "101000101",
  "101111101",
  "100010001",
  "111110111"
]

function emptyFrame() {
  var f = new Array(GRID_W * GRID_H)
  for (var i = 0; i < f.length; i++) f[i] = 0
  return f
}

function setPx(f, x, y, v) {
  if (x >= 0 && x < GRID_W && y >= 0 && y < GRID_H) f[y * GRID_W + x] = v
}

function blitRows(f, rows, y0) {
  for (var y = 0; y < rows.length; y++)
    for (var x = 0; x < GRID_W && x < rows[y].length; x++)
      if (rows[y].charAt(x) === "1") setPx(f, x, y0 + y, 1)
}

// show_font(): glyphs are 5 wide at x offset 2, stacked at y = i * 7
function blitGlyph(f, ch, y0) {
  var bits = FONT[ch] || FONT["?"]
  for (var gy = 0; gy < 6; gy++)
    for (var gx = 0; gx < 5; gx++)
      if (bits.charAt(gy * 5 + gx) === "1") setPx(f, 2 + gx, y0 + gy, 1)
}

// dx/dy pixel-shift the whole string within the panel. Glyphs start at x=2
// (5 wide in 9 columns) so dx spans [-2, 2]; dy spans [0, slack below the
// last glyph]. setPx clips, but shiftBounds/clampShift keep the UI honest.
function frameText(text, dx, dy) {
  var f = emptyFrame()
  var s = String(text || "").toUpperCase().substring(0, 5)
  var ox = dx === undefined ? 0 : dx
  var oy = dy === undefined ? 0 : dy
  for (var i = 0; i < s.length; i++) {
    var bits = FONT[s.charAt(i)] || FONT["?"]
    for (var gy = 0; gy < 6; gy++)
      for (var gx = 0; gx < 5; gx++)
        if (bits.charAt(gy * 5 + gx) === "1") setPx(f, 2 + ox + gx, i * 7 + oy + gy, 1)
  }
  return f
}

function textShiftBounds(text) {
  var n = Math.min(5, Math.max(1, String(text || "").length))
  return { dxMin: -2, dxMax: 2, dyMin: 0, dyMax: Math.max(0, GRID_H - (n * 7 - 1)) }
}

function clampShift(text, dx, dy) {
  var b = textShiftBounds(text)
  return {
    dx: Math.max(b.dxMin, Math.min(b.dxMax, dx)),
    dy: Math.max(b.dyMin, Math.min(b.dyMax, dy))
  }
}

// Serialize a frame for `led-matrix-ctl frame` (306 chars of 0/1)
function frameToBits(frame) {
  var bits = ""
  for (var i = 0; i < GRID_W * GRID_H; i++)
    bits += frame && frame[i] > 0.5 ? "1" : "0"
  return bits
}

function bitsToFrame(bits) {
  var f = emptyFrame()
  if (!bits) return f
  for (var i = 0; i < f.length && i < bits.length; i++)
    if (bits.charAt(i) === "1") f[i] = 1
  return f
}

// ---- custom patterns -------------------------------------------------------
//
// Saved drawings are 9x34 PNGs managed by `led-matrix-ctl save-pattern /
// list-patterns / delete-pattern`. In the UI they are display values of the
// form "custom:<name>" — static (kind pattern), so effects compose. The
// editor's unsaved drawing travels as CUSTOM_UNSAVED, resolved from the
// widget's live editor grid.

var CUSTOM_PREFIX = "custom:"
var CUSTOM_UNSAVED = "custom:~editor"

function isCustomDisplay(value) {
  return String(value || "").indexOf(CUSTOM_PREFIX) === 0
}

function customName(value) {
  return isCustomDisplay(value) ? String(value).substring(CUSTOM_PREFIX.length) : ""
}

// `patterns` is [{name, bits}]; returns bits or null
function customBits(value, patterns, editorBits) {
  if (!isCustomDisplay(value)) return null
  if (value === CUSTOM_UNSAVED) return editorBits || null
  var name = customName(value)
  for (var i = 0; i < patterns.length; i++)
    if (patterns[i].name === name) return patterns[i].bits
  return null
}

// `current` (the selected display value) is included so an unsaved editor
// drawing gets a readable label instead of the dropdown falling back to the
// raw "custom:~editor" value.
function displayOptionsWith(patterns, current) {
  var opts = displayOptions.slice()
  for (var i = 0; i < patterns.length; i++)
    opts.push({ value: CUSTOM_PREFIX + patterns[i].name, label: "★ " + patterns[i].name, kind: "pattern" })
  if (current === CUSTOM_UNSAVED)
    opts.push({ value: CUSTOM_UNSAVED, label: "★ Editor drawing (unsaved)", kind: "pattern" })
  return opts
}

// Label lookup that also understands custom values (for hints/labels)
function displayLabel(value, patterns) {
  if (value === CUSTOM_UNSAVED) return "Editor drawing"
  if (isCustomDisplay(value)) return "★ " + customName(value)
  return optionLabel(displayOptions, value)
}

function frameClock() {
  var d = new Date()
  var hh = ("0" + d.getHours()).slice(-2)
  var mm = ("0" + d.getMinutes()).slice(-2)
  return frameText(hh + ":" + mm)
}

function frameLogo() {
  var f = emptyFrame()
  blitRows(f, LOGO, 12)
  return f
}

// gradient(): row brightness (y+1)/255 — a deliberately subtle ramp
function frameGradient() {
  var f = emptyFrame()
  for (var y = 0; y < GRID_H; y++)
    for (var x = 0; x < GRID_W; x++)
      f[y * GRID_W + x] = (y + 1) / 255
  return f
}

function frameDoubleGradient() {
  var f = emptyFrame()
  for (var y = 0; y < GRID_H; y++) {
    var v = y < GRID_H / 2 ? (y + 1) : (GRID_H - (y + 1))
    for (var x = 0; x < GRID_W; x++) f[y * GRID_W + x] = v / 255
  }
  return f
}

// zigzag() from patterns.rs, with the draw() x-mirror applied so it matches
// what the module shows
function frameZigzag() {
  var f = emptyFrame()
  for (var i = 0; i < GRID_W; i++) {
    setPx(f, GRID_W - 1 - i, i, 1)
    setPx(f, i, GRID_W + i, 1)
    setPx(f, GRID_W - 1 - i, 2 * GRID_W + i, 1)
    if (3 * GRID_W + i < GRID_H) setPx(f, i, 3 * GRID_W + i, 1)
  }
  setPx(f, GRID_W - 2, 33, 1)
  return f
}

function frameAllOn() {
  var f = emptyFrame()
  for (var i = 0; i < f.length; i++) f[i] = 1
  return f
}

function frameLotusTopDown() {
  var f = emptyFrame()
  blitRows(f, LOTUS_TOPDOWN, 0)
  return f
}

// display_lotus(): letters stacked to read "LOTUS" bottom-up (approximated
// with the 5x6 font; firmware uses 8x8 glyphs at the same anchors)
function frameLotusSideways() {
  var f = emptyFrame()
  var letters = ["S", "U", "T", "O", "L"]
  var anchors = [0, 5, 12, 20, 26]
  for (var i = 0; i < letters.length; i++) blitGlyph(f, letters[i], anchors[i])
  return f
}

// Deterministic pseudo-random in [0,1) so eq animation is stable per tick
function prand(seed) {
  var t = (seed + 0x6d2b79f5) | 0
  t = Math.imul(t ^ (t >>> 15), t | 1)
  t ^= t + Math.imul(t ^ (t >>> 7), t | 61)
  return ((t ^ (t >>> 14)) >>> 0) / 4294967296
}

// random_eq_cmd()/eq_cmd(): 9 low-biased values 1..33, bars growing from the
// middle row; hardware updates every 200ms (= 2 ticks at 100ms)
function frameEq(tick) {
  var f = emptyFrame()
  var seed = Math.floor(tick / 2)
  for (var x = 0; x < GRID_W; x++) {
    var r = prand(seed * 97 + x)
    var v = 1 + Math.floor(32 * r * r)
    var above = Math.floor(v / 2)
    var below = v - above
    var mid = Math.floor(GRID_H / 2)
    for (var i = 0; i < above; i++) setPx(f, x, mid + i, 1)
    for (var j = 0; j < below; j++) setPx(f, x, mid - 1 - j, 1)
  }
  return f
}

// led-matrix-bounce trajectory: y walks 0..25 then 24..1, 100ms per frame
function frameBounce(tick) {
  var f = emptyFrame()
  var i = tick % 50
  var y = i <= 25 ? i : 50 - i
  blitRows(f, LOGO, y)
  return f
}

// One entry point for the twins: static displays ignore `tick` so their
// bindings don't re-evaluate on animation ticks.
function staticFrame(display, text, dx, dy) {
  if (display === "text") return frameText(text, dx, dy)
  if (display === "logo") return frameLogo()
  if (display === "gradient") return frameGradient()
  if (display === "double-gradient") return frameDoubleGradient()
  if (display === "lotus-sideways") return frameLotusSideways()
  if (display === "lotus-top-down") return frameLotusTopDown()
  if (display === "zigzag") return frameZigzag()
  if (display === "all-on") return frameAllOn()
  return null
}

function streamFrame(display, tick) {
  if (display === "clock") return frameClock()
  if (display === "eq" || display === "mic-eq") return frameEq(tick)
  if (display === "bounce") return frameBounce(tick)
  return null
}

// Brightness multiplier for effects; tick is 100ms units
function effectLevel(effect, tick) {
  if (effect === "breathing") {
    var t = (tick % 40) / 40
    return 0.25 + 0.75 * (0.5 - 0.5 * Math.cos(2 * Math.PI * t))
  }
  if (effect === "blinking") return (tick % 10) < 5 ? 1 : 0.08
  return 1
}

// How text splits across panels in effective order (5 chars each)
function textChunkFor(text, panelIndex) {
  return String(text || "").substring(panelIndex * 5, panelIndex * 5 + 5)
}
