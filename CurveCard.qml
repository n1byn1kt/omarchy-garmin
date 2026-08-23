import QtQuick
import qs.Commons

// Today's two curves on one Canvas: Body Battery as a filled line, stress as
// a thinner line behind it. Adapted from the vitals plugin's paintTileGraph —
// same "normalise, then draw one series per pass" shape, but plotted against
// wall-clock time rather than a fixed sample count, because Garmin's samples
// are irregular and stop whenever the watch comes off.
//
// Both series are optional. The card is hidden by the panel when neither
// exists; when only one does, it draws alone and the legend follows.
Rectangle {
  id: card

  // [[epochMs, value], …] — anything else in the array is skipped, so a
  // half-written cache file costs a few points rather than the whole panel.
  property var bodyBatterySeries: null
  property var stressSeries: null

  property string icon: "󱐋"
  property string title: "Body Battery"
  property string value: "—"
  property string tone: ""
  property string caption: ""

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

  // Points are [timestamp, value] pairs; both have to be finite numbers for
  // the point to mean anything, and the series has to have two of them before
  // there is a line to draw at all.
  //
  // The caps mirror Panel.cleanSeries: the helper ships at most 96 points per
  // series, so a real payload is never touched, but this data comes off disk
  // and the Canvas would happily try to stroke a 200k-point path.
  readonly property int inputCap: 500
  readonly property int pointCap: 96
  function clean(series) {
    var out = []
    if (!series || series.length === undefined) return out
    var n = Math.min(series.length, card.inputCap)
    for (var i = 0; i < n; i++) {
      var p = series[i]
      if (!p || p.length === undefined || p.length < 2) continue
      var t = Number(p[0])
      var v = Number(p[1])
      if (!isFinite(t) || !isFinite(v)) continue
      out.push([t, v])
    }
    out.sort(function (a, b) { return a[0] - b[0] })
    return out.length > card.pointCap
      ? out.slice(out.length - card.pointCap) : out
  }

  readonly property var bbPoints: card.clean(card.bodyBatterySeries)
  readonly property var stressPoints: card.clean(card.stressSeries)
  readonly property bool hasBb: card.bbPoints.length >= 2
  readonly property bool hasStress: card.stressPoints.length >= 2
  readonly property bool hasAny: card.hasBb || card.hasStress

  readonly property color bbColor: card.muted ? card.dim : card.accentColor
  readonly property color stressColor: Util.alpha(card.foreground, card.muted ? 0.32 : 0.5)

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
      implicitHeight: Math.max(curveIcon.implicitHeight, curveTitle.implicitHeight, curveValue.implicitHeight)

      Text {
        id: curveIcon
        visible: card.icon !== ""
        text: card.icon
        color: card.dim
        font.family: card.fontFamily
        font.pixelSize: Style.font.icon
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        id: curveTitle
        text: card.title
        color: card.dim
        font.family: card.fontFamily
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
        anchors.left: curveIcon.visible ? curveIcon.right : parent.left
        anchors.leftMargin: curveIcon.visible ? Style.space(8) : 0
        anchors.right: curveValue.left
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        id: curveValue
        text: card.value
        color: card.toneColor(card.tone)
        font.family: card.fontFamily
        font.pixelSize: Style.font.subtitle
        font.bold: true
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    Loader {
      width: parent.width
      // Height follows the cleaned data, not just `active`: a series that
      // survives the payload but not clean() would otherwise reserve a plot
      // rectangle that nothing ever paints into.
      height: card.hasAny ? Style.space(58) : 0
      active: card.active && card.hasAny

      sourceComponent: Canvas {
        id: plot

        readonly property var bb: card.bbPoints
        readonly property var stress: card.stressPoints
        readonly property color bbStroke: card.bbColor
        readonly property color stressStroke: card.stressColor

        onBbChanged: requestPaint()
        onStressChanged: requestPaint()
        onBbStrokeChanged: requestPaint()
        onStressStrokeChanged: requestPaint()
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()

        onPaint: {
          var ctx = getContext("2d")
          ctx.reset()
          ctx.clearRect(0, 0, width, height)

          // One shared time axis, so the two curves line up hour for hour
          // even when the watch sampled them at different moments.
          var tMin = Infinity
          var tMax = -Infinity
          function span(points) {
            for (var i = 0; i < points.length; i++) {
              if (points[i][0] < tMin) tMin = points[i][0]
              if (points[i][0] > tMax) tMax = points[i][0]
            }
          }
          // Only the series that will actually be drawn may stretch the axis.
          // drawSeries() skips anything shorter than two points, so letting a
          // lone stray sample into the span would slide the drawn curve into a
          // corner of a plot whose other half stays empty.
          if (bb && bb.length >= 2) span(bb)
          if (stress && stress.length >= 2) span(stress)
          if (!isFinite(tMin) || !isFinite(tMax) || tMax <= tMin) return

          // Both series are 0–100 scores, so the axis is fixed rather than
          // auto-scaled: a flat, low-stress day should look flat and low.
          function xFor(t) { return width * (t - tMin) / (tMax - tMin) }
          function yFor(v) {
            var c = Math.max(0, Math.min(100, v))
            return height - 1 - (c / 100) * (height - 2)
          }

          function trace(points) {
            for (var i = 0; i < points.length; i++) {
              var x = xFor(points[i][0])
              var y = yFor(points[i][1])
              if (i === 0) ctx.moveTo(x, y)
              else ctx.lineTo(x, y)
            }
          }

          function drawSeries(points, stroke, lineWidth, filled) {
            if (!points || points.length < 2) return
            if (filled) {
              ctx.beginPath()
              trace(points)
              ctx.lineTo(xFor(points[points.length - 1][0]), height)
              ctx.lineTo(xFor(points[0][0]), height)
              ctx.closePath()
              ctx.fillStyle = Util.alpha(stroke, 0.18)
              ctx.fill()
            }
            ctx.beginPath()
            trace(points)
            ctx.strokeStyle = stroke
            ctx.lineWidth = lineWidth
            ctx.stroke()
          }

          // Stress first: it is context for the Body Battery line, not the
          // headline, so it must never paint over it.
          drawSeries(stress, stressStroke, 1.0, false)
          drawSeries(bb, bbStroke, 1.4, true)
        }
      }
    }

    // ---- Legend + span
    Item {
      width: parent.width
      implicitHeight: Math.max(legend.implicitHeight, spanText.implicitHeight)

      Row {
        id: legend
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(10)

        // The header already says "Body Battery", so its swatch only earns its
        // place when there is a second line to tell it apart from.
        Row {
          visible: card.hasBb && card.hasStress
          spacing: Style.space(4)

          Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(8)
            height: Style.space(3)
            radius: height / 2
            color: card.bbColor
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "Body Battery"
            color: card.dim
            font.family: card.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Row {
          visible: card.hasStress
          spacing: Style.space(4)

          Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(8)
            height: Style.space(3)
            radius: height / 2
            color: card.stressColor
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "Stress"
            color: card.dim
            font.family: card.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }

      Text {
        id: spanText
        visible: card.caption !== ""
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        text: card.caption
        color: card.dim
        font.family: card.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }
}
