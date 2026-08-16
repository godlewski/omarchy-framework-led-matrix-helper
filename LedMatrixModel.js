var patterns = [
  { value: "logo", label: "Omarchy Logo" },
  { value: "text", label: "Text" },
  { value: "gradient", label: "Gradient" },
  { value: "double-gradient", label: "Double Gradient" },
  { value: "lotus-sideways", label: "Lotus Sideways" },
  { value: "lotus-top-down", label: "Lotus Top Down" },
  { value: "zigzag", label: "Zigzag" },
  { value: "all-on", label: "All On" }
]

var animations = [
  { value: "none", label: "None" },
  { value: "breathing", label: "Breathing" },
  { value: "blinking", label: "Blinking" },
  { value: "clock", label: "Clock" },
  { value: "eq", label: "Random EQ" },
  { value: "mic-eq", label: "Mic EQ" },
  { value: "bounce", label: "Bounce (Omarchy)" }
]

function panelLabel(index) {
  return "Panel " + (index + 1)
}

function tooltip(deviceCount, animation) {
  if (deviceCount === 0)
    return "No LED Matrix panels detected"
  var state = animation && animation.length > 0 ? animation : "idle"
  return deviceCount + (deviceCount === 1 ? " panel" : " panels") + " · " + state
}
