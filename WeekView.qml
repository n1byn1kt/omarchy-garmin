import QtQuick
import qs.Commons
import qs.Ui

// One metric, seven days, full panel width: the detail page a card opens.
//
// Everything is pre-formatted by Panel.qml — this component only places
// things and paints bars. `days` is always seven slots, oldest first:
//   { label: "Tu", dayLabel: "Sep 2", present: true,
//     value: 8953,          // bar height (or the top of a range)
//     lo: null,             // bottom of a range (variant "range")
//     parts: [90, 254, 59], // bottom-up segments (variant "stacked")
//     goal: 8950,           // per-day tick, or null
//     valueText: "8,953",   // the label above the column
//     tip: "Tu Sep 2 · 8,953" }
// Absent days keep a faint track so a three-day week reads as three days,
// not as four days of nothing.
Item {
  id: view

  property var days: []
  // "bars" | "stacked" | "range"
  property string variant: "bars"
  // Fixed axis ceiling (scores are out of 100); zero scales to the week.
  property real fixedMax: 0
  // Axis floor. Zero for anything that starts at nothing (steps, minutes);
  // a resting heart rate sets it under the week's low so the bars have a
  // shape — the value labels carry the real numbers either way.
  property real axisMin: 0
  // Shaded horizontal band, e.g. an HRV balanced range: { lo, hi } or null.
  property var band: null
  // Colours for stacked parts, bottom-up; the panel builds them off the theme.
  property var partColors: []
  // [{ label, color }] drawn under the chart for stacked variants.
  property var legend: []
  // One line of week statistics under the chart.
  property string summary: ""

  property color foreground: Color.foreground
  property color accentColor: Color.accent
  property color urgentColor: Color.urgent
  property color dim: Qt.darker(foreground, 1.55)
  property string fontFamily: Style.font.family
  property bool muted: false

  readonly property int count: view.days ? view.days.length : 0
  readonly property real chartHeight: Style.space(150)
  readonly property color barColor: view.muted ? view.dim : view.accentColor
  readonly property color pastColor: Util.alpha(view.foreground, view.muted ? 0.2 : 0.3)

  // The axis ceiling. Per-day goals count too, so a day that missed its goal
  // shows the tick above the bar instead of clipping it at the top.
  readonly property real axisMax: {
    if (Number(view.fixedMax) > 0) return Number(view.fixedMax)
    var m = 0
    for (var i = 0; i < view.count; i++) {
      var d = view.days[i]
      if (!d || d.present !== true) continue
      var v = Number(d.value)
      if (isFinite(v) && v > m) m = v
      var g = Number(d.goal)
      if (isFinite(g) && g > m) m = g
    }
    if (view.band) {
      var hi = Number(view.band.hi)
      if (isFinite(hi) && hi > m) m = hi
    }
    return m > 0 ? m : 1
  }

  implicitHeight: column.implicitHeight

  Column {
    id: column
    width: parent.width
    spacing: Style.space(4)

    // ---- Value labels, one per column, above the chart so they never
    //      collide with a neighbouring bar.
    Row {
      width: parent.width
      readonly property real colWidth: width / Math.max(1, view.count)

      Repeater {
        model: view.days

        Text {
          textFormat: Text.PlainText
          required property var modelData
          required property int index
          width: parent.colWidth
          horizontalAlignment: Text.AlignHCenter
          text: modelData.present === true ? String(modelData.valueText || "") : "—"
          color: index === view.count - 1 ? view.foreground : view.dim
          opacity: modelData.present === true ? 1.0 : 0.45
          font.family: view.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: index === view.count - 1
          elide: Text.ElideRight
        }
      }
    }

    // ---- The chart: one Canvas for every bar, plus a hover overlay per day.
    Item {
      id: chart
      width: parent.width
      height: view.chartHeight

      Canvas {
        id: plot
        anchors.fill: parent

        readonly property var days: view.days
        readonly property string variant: view.variant
        readonly property real axisMax: view.axisMax
        readonly property real axisMin: Math.max(0, Math.min(view.axisMin, view.axisMax - 1))
        readonly property var band: view.band
        readonly property var partColors: view.partColors
        readonly property color barColor: view.barColor
        readonly property color pastColor: view.pastColor
        readonly property color trackColor: Util.alpha(view.foreground, 0.07)
        readonly property color tickColor: Util.alpha(view.foreground, 0.55)
        readonly property color bandColor: Util.alpha(view.foreground, 0.09)

        onDaysChanged: requestPaint()
        onVariantChanged: requestPaint()
        onAxisMaxChanged: requestPaint()
        onAxisMinChanged: requestPaint()
        onBandChanged: requestPaint()
        onPartColorsChanged: requestPaint()
        onBarColorChanged: requestPaint()
        onPastColorChanged: requestPaint()
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()

        onPaint: {
          var ctx = getContext("2d")
          ctx.reset()
          ctx.clearRect(0, 0, width, height)

          var n = days ? days.length : 0
          if (n === 0) return
          var colW = width / n
          var barW = Math.max(4, Math.floor(colW * 0.62))
          var top = 1
          var bottom = height - 1
          var span = bottom - top
          function yFor(v) {
            var c = Math.max(axisMin, Math.min(axisMax, Number(v) || 0))
            return bottom - ((c - axisMin) / (axisMax - axisMin)) * span
          }
          function xFor(i) { return Math.round(i * colW + (colW - barW) / 2) }

          // Faint tracks first: every day has one, so the week keeps its
          // shape however many days are actually present.
          ctx.fillStyle = trackColor
          for (var t = 0; t < n; t++) ctx.fillRect(xFor(t), top, barW, span)

          // A shaded band (HRV's balanced range) sits behind the bars.
          if (band && isFinite(Number(band.lo)) && isFinite(Number(band.hi))) {
            var y1 = yFor(band.hi), y2 = yFor(band.lo)
            ctx.fillStyle = bandColor
            ctx.fillRect(0, y1, width, Math.max(1, y2 - y1))
          }

          for (var i = 0; i < n; i++) {
            var d = days[i]
            if (!d || d.present !== true) continue
            var x = xFor(i)
            var latest = i === n - 1
            var solid = latest ? barColor : pastColor

            if (variant === "stacked") {
              var parts = d.parts || []
              var acc = 0
              for (var p = 0; p < parts.length; p++) {
                var seg = Number(parts[p]) || 0
                if (seg <= 0) continue
                var yTop = yFor(acc + seg), yBot = yFor(acc)
                var c = partColors && p < partColors.length ? partColors[p] : solid
                ctx.fillStyle = c   // the ladder is the distinction; no latest/past split
                ctx.fillRect(x, yTop, barW, Math.max(1, yBot - yTop))
                acc += seg
              }
            } else if (variant === "range") {
              // `d.lo` is a real null, not a missing-number placeholder, when
              // the source never reported a low for the day — drawing it as
              // 0 would extend the bar all the way to the floor, claiming a
              // full drain that never happened. Draw just the high mark
              // instead, the same thin bar an ordinary "bars" day gets.
              var hi = Number(d.value)
              var yh = yFor(hi)
              var yl = d.lo === null ? yh : yFor(Number(d.lo))
              ctx.fillStyle = solid
              ctx.fillRect(x, yh, barW, Math.max(2, yl - yh))
            } else {
              var y = yFor(d.value)
              ctx.fillStyle = solid
              ctx.fillRect(x, y, barW, Math.max(2, bottom - y))
            }

            // The day's own goal, as a tick across the bar.
            var g = Number(d.goal)
            if (isFinite(g) && g > 0) {
              var yg = Math.round(yFor(g)) + 0.5
              ctx.strokeStyle = tickColor
              ctx.lineWidth = 1
              ctx.beginPath()
              ctx.moveTo(x - 2, yg)
              ctx.lineTo(x + barW + 2, yg)
              ctx.stroke()
            }
          }
        }
      }

      // Hover targets, one per column, over the whole chart height so the
      // tooltip answers for a short bar as readily as for a tall one.
      Row {
        anchors.fill: parent
        readonly property real colWidth: width / Math.max(1, view.count)

        Repeater {
          model: view.days

          Item {
            required property var modelData
            width: parent.colWidth
            height: parent.height

            MouseArea {
              id: colMouse
              anchors.fill: parent
              hoverEnabled: true
              acceptedButtons: Qt.NoButton

              PanelToolTip {
                visible: colMouse.containsMouse && String(modelData.tip || "") !== ""
                text: String(modelData.tip || "")
                fontFamily: view.fontFamily
              }
            }
          }
        }
      }
    }

    // ---- Day labels: weekday over the date.
    Row {
      width: parent.width
      readonly property real colWidth: width / Math.max(1, view.count)

      Repeater {
        model: view.days

        Column {
          required property var modelData
          required property int index
          width: parent.colWidth

          Text {
            textFormat: Text.PlainText
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: String(modelData.label || "")
            color: index === view.count - 1 ? view.foreground : view.dim
            opacity: modelData.present === true ? 1.0 : 0.45
            font.family: view.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: String(modelData.dayLabel || "")
            color: view.dim
            opacity: modelData.present === true ? 0.8 : 0.4
            font.family: view.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }

    // ---- Legend (stacked variants) and the week's statistics.
    Item {
      width: parent.width
      implicitHeight: Math.max(legendRow.implicitHeight, summaryText.implicitHeight) + Style.space(6)

      Row {
        id: legendRow
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(10)

        Repeater {
          model: view.legend

          Row {
            required property var modelData
            spacing: Style.space(4)

            Rectangle {
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(8)
              height: Style.space(8)
              radius: Style.space(2)
              color: modelData.color
            }

            Text {
              textFormat: Text.PlainText
              anchors.verticalCenter: parent.verticalCenter
              text: String(modelData.label || "")
              color: view.dim
              font.family: view.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }
      }

      Text {
        textFormat: Text.PlainText
        id: summaryText
        anchors.right: parent.right
        anchors.left: legendRow.right
        anchors.leftMargin: Style.space(10)
        anchors.verticalCenter: parent.verticalCenter
        horizontalAlignment: Text.AlignRight
        text: view.summary
        color: view.dim
        font.family: view.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideLeft
      }
    }
  }
}
