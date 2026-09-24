import QtQuick
import qs.Commons

// Last month of weigh-ins on one Canvas. Same "clean, then paint" shape as
// CurveCard, but the Y axis auto-scales around the readings — weight is not
// a 0–100 score — and each sample is a dot, because weigh-ins are sparse
// enough that a line alone hides how few points there actually are.
//
// Ported from PR #1 (@xshatx) onto the current card conventions: no
// `clickable`/`onClicked` here (unlike CurveCard) — there is no detail page
// for weight in this pass, so the card is display-only.
Rectangle {
  id: card

  // [[epochMs, kg-or-lb], …] — anything else in the array is skipped, so a
  // half-written cache file costs a few points rather than the whole panel.
  // Already in the display unit; this card does no unit math of its own.
  property var series: null

  property string icon: "󰔻"
  property string title: "Weight"
  property string value: "—"
  property string tone: ""
  property string caption: ""
  property string delta: ""
  property string deltaTone: ""

  // Canvas keeps a texture per instance, so it is only built for the card
  // that is actually on screen.
  property bool active: true

  property color foreground: Color.foreground
  property color accentColor: Color.accent
  property color urgentColor: Color.urgent
  property color dim: Qt.darker(foreground, 1.55)
  property string fontFamily: Style.font.family
  property bool muted: false

  function toneColor(name) {
    if (card.muted) return name === "" ? card.foreground : card.dim
    if (name === "urgent") return card.urgentColor
    if (name === "accent") return card.accentColor
    return card.foreground
  }

  // Caps mirror Panel.cleanSeries / CurveCard.clean: the helper ships at most
  // 96 points, so a real payload is never touched, but this data comes off
  // disk and the Canvas would happily try to stroke a 200k-point path.
  readonly property int inputCap: 500
  readonly property int pointCap: 96
  function clean(raw) {
    var out = []
    if (!raw || raw.length === undefined) return out
    var n = Math.min(raw.length, card.inputCap)
    for (var i = 0; i < n; i++) {
      var p = raw[i]
      if (!p || p.length === undefined || p.length < 2) continue
      var t = Number(p[0])
      var v = Number(p[1])
      if (!isFinite(t) || !isFinite(v) || v <= 0) continue
      out.push([t, v])
    }
    out.sort(function (a, b) { return a[0] - b[0] })
    return out.length > card.pointCap
      ? out.slice(out.length - card.pointCap) : out
  }

  readonly property var points: card.clean(card.series)
  // Two samples at the same instant have no x-span; onPaint would reserve a
  // rectangle and then return, so "drawable" is a positive time range.
  readonly property bool hasLine: {
    var p = card.points
    return p.length >= 2 && p[p.length - 1][0] > p[0][0]
  }
  readonly property color lineColor: card.muted ? card.dim : card.accentColor

  color: Util.alpha(card.foreground, 0.075)
  radius: Style.cornerRadius
  implicitHeight: content.implicitHeight + Style.space(10) * 2

  Column {
    id: content
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.leftMargin: Style.space(10)
    anchors.rightMargin: Style.space(10)
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(6)

    Item {
      width: parent.width
      implicitHeight: Math.max(weightIcon.implicitHeight, weightTitle.implicitHeight, valueRow.implicitHeight)

      Text {
        textFormat: Text.PlainText
        id: weightIcon
        visible: card.icon !== ""
        text: card.icon
        color: card.dim
        font.family: card.fontFamily
        font.pixelSize: Style.font.icon
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        textFormat: Text.PlainText
        id: weightTitle
        text: card.title
        color: card.dim
        font.family: card.fontFamily
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
        anchors.left: weightIcon.visible ? weightIcon.right : parent.left
        anchors.leftMargin: weightIcon.visible ? Style.space(8) : 0
        anchors.right: valueRow.left
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
      }

      Row {
        id: valueRow
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(5)

        Text {
          textFormat: Text.PlainText
          anchors.verticalCenter: parent.verticalCenter
          visible: card.delta !== ""
          text: card.delta
          color: card.toneColor(card.deltaTone)
          font.family: card.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Text {
          textFormat: Text.PlainText
          text: card.value
          color: card.toneColor(card.tone)
          font.family: card.fontFamily
          font.pixelSize: Style.font.subtitle
          font.bold: true
        }
      }
    }

    Loader {
      width: parent.width
      visible: card.hasLine
      height: card.hasLine ? Style.space(58) : 0
      active: card.active && card.hasLine

      sourceComponent: Canvas {
        id: plot

        readonly property var pts: card.points
        readonly property color stroke: card.lineColor

        onPtsChanged: requestPaint()
        onStrokeChanged: requestPaint()
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()

        onPaint: {
          var ctx = getContext("2d")
          ctx.reset()
          ctx.clearRect(0, 0, width, height)
          if (!pts || pts.length < 2) return

          var tMin = pts[0][0]
          var tMax = pts[0][0]
          var yMin = pts[0][1]
          var yMax = pts[0][1]
          for (var i = 1; i < pts.length; i++) {
            if (pts[i][0] < tMin) tMin = pts[i][0]
            if (pts[i][0] > tMax) tMax = pts[i][0]
            if (pts[i][1] < yMin) yMin = pts[i][1]
            if (pts[i][1] > yMax) yMax = pts[i][1]
          }
          // Two samples at the same instant have no x-span to draw across.
          if (tMax <= tMin) return

          // Auto-scale with a floor so a small wobble still has a slope
          // rather than filling the plot. A perfectly flat series becomes a
          // centred line instead of a divide-by-zero.
          var span = yMax - yMin
          if (span < 1) {
            var mid = (yMax + yMin) / 2
            yMin = mid - 0.5
            yMax = mid + 0.5
          } else {
            var pad = span * 0.12
            yMin -= pad
            yMax += pad
          }

          function xFor(t) { return width * (t - tMin) / (tMax - tMin) }
          function yFor(v) {
            return height - 1 - ((v - yMin) / (yMax - yMin)) * (height - 2)
          }

          ctx.beginPath()
          for (var j = 0; j < pts.length; j++) {
            var x = xFor(pts[j][0])
            var y = yFor(pts[j][1])
            if (j === 0) ctx.moveTo(x, y)
            else ctx.lineTo(x, y)
          }
          ctx.lineTo(xFor(pts[pts.length - 1][0]), height)
          ctx.lineTo(xFor(pts[0][0]), height)
          ctx.closePath()
          ctx.fillStyle = Util.alpha(stroke, 0.18)
          ctx.fill()

          ctx.beginPath()
          for (var k = 0; k < pts.length; k++) {
            var x2 = xFor(pts[k][0])
            var y2 = yFor(pts[k][1])
            if (k === 0) ctx.moveTo(x2, y2)
            else ctx.lineTo(x2, y2)
          }
          ctx.strokeStyle = stroke
          ctx.lineWidth = 1.4
          ctx.stroke()

          // Dots last, so they sit on the stroke. A series of two still
          // earns them: that is the whole reason this is a timeline and
          // not a sparkline of implied daily values.
          var r = 2.2
          ctx.fillStyle = stroke
          for (var d = 0; d < pts.length; d++) {
            ctx.beginPath()
            ctx.arc(xFor(pts[d][0]), yFor(pts[d][1]), r, 0, Math.PI * 2)
            ctx.fill()
          }
        }
      }
    }

    Text {
      textFormat: Text.PlainText
      visible: card.caption !== ""
      width: parent.width
      text: card.caption
      color: card.dim
      font.family: card.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }
  }
}
