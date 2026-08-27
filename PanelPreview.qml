import QtQuick
import qs.Commons
import qs.Ui

// Emulated 9x34 LED Matrix module — the on-screen twin of one physical panel.
// Renders a frame (flat array of 306 values in [0,1], row-major; see
// LedMatrixModel.js) as LED dots inside a module bezel.
//
// `level` multiplies every LED (brightness x effect); `lit: false` blacks the
// LEDs out (sleep) while keeping the bezel and dot grid visible. A gamma
// curve keeps dim hardware values (e.g. the gradient pattern's 1-34/255 ramp)
// perceptible on screen the way they are on the physical LEDs.
BorderSurface {
  id: root

  property var frame: null
  property real level: 1.0
  property bool lit: true
  property color fg: Color.foreground
  property bool pending: false

  property real cellPx: 6
  property real cellGap: 1
  property int pad: Style.space(4)

  radius: Style.cornerRadius
  color: Util.alpha(fg, 0.05)
  borderSpec: pending
    ? Border.flat(Color.accent, Math.max(1, Style.normalBorderWidth))
    : Border.flat(Util.alpha(fg, 0.25), Math.max(1, Style.normalBorderWidth))

  implicitWidth: pad * 2 + 9 * cellPx + 8 * cellGap
  implicitHeight: pad * 2 + 34 * cellPx + 33 * cellGap

  onFrameChanged: canvas.requestPaint()
  onLevelChanged: canvas.requestPaint()
  onLitChanged: canvas.requestPaint()
  onFgChanged: canvas.requestPaint()

  Canvas {
    id: canvas
    anchors.fill: parent
    anchors.margins: root.pad

    onPaint: {
      var ctx = getContext("2d")
      ctx.clearRect(0, 0, width, height)
      var step = root.cellPx + root.cellGap
      for (var y = 0; y < 34; y++) {
        for (var x = 0; x < 9; x++) {
          var v = root.frame ? (root.frame[y * 9 + x] || 0) : 0
          var a = 0.07 // unlit LED: faint dot so the module grid reads
          if (root.lit && v > 0) {
            var lvl = Math.max(0, Math.min(1, v * root.level))
            a = Math.max(a, Math.pow(lvl, 0.45))
          }
          ctx.fillStyle = Qt.rgba(root.fg.r, root.fg.g, root.fg.b, a)
          ctx.fillRect(x * step, y * step, root.cellPx, root.cellPx)
        }
      }
    }
  }
}
