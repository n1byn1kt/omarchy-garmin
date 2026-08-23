import QtQuick
import qs.Commons

// A thin progress track — the hw-tooltip `Meter` idiom, with the colours
// lifted out to properties so the bar's palette (not the global tokens)
// decides what the fill looks like.
//
// `percent` is 0–100 and is clamped rather than trusted: goals arrive from
// Garmin and a zero goal would otherwise divide its way to Infinity.
Item {
  id: root

  property real percent: 0
  property color foreground: Color.foreground
  property color fillColor: Color.accent

  implicitHeight: Math.max(2, Style.space(5))

  readonly property real clamped: {
    var n = Number(root.percent)
    if (!isFinite(n)) return 0
    return Math.max(0, Math.min(100, n))
  }

  Rectangle {
    anchors.fill: parent
    radius: height / 2
    color: Util.alpha(root.foreground, 0.12)
  }

  Rectangle {
    anchors.left: parent.left
    anchors.verticalCenter: parent.verticalCenter
    height: parent.height
    radius: height / 2
    color: root.fillColor
    // A non-zero reading always shows at least a dot: a 1% fill rounded down
    // to nothing looks identical to no data at all.
    width: root.clamped <= 0 ? 0 : Math.max(parent.height, parent.width * root.clamped / 100)

    Behavior on width { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
  }
}
