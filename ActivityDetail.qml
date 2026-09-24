import QtQuick
import qs.Commons
import qs.Ui

// One activity: what it was, when, and the figures Garmin recorded for it.
//
// Dumb, like ActivityList and WeekView: Panel.qml formats every string and
// decides whether the Connect link may be offered at all (`linkable`: a
// well-formed id, not demo data). This file never sees the id — it asks for
// the link with `openRequested()` and Panel.openInConnect builds the URL, so
// there is exactly one place in the plugin that can hand a URL to the
// desktop.
//
// `metrics` is [{ label, value }], only the ones this activity has: a
// strength session has no distance, and a grid of em dashes would say
// "missing" about things that were never going to exist.
Item {
  id: detail

  property string glyph: ""
  property string title: ""
  property string subtitle: ""
  property var metrics: []
  property bool linkable: false
  property bool failed: false

  property color foreground: Color.foreground
  property color accentColor: Color.accent
  property color urgentColor: Color.urgent
  property color dim: Qt.darker(foreground, 1.55)
  property string fontFamily: Style.font.family
  property bool muted: false

  signal openRequested()

  implicitHeight: column.implicitHeight

  Column {
    id: column
    width: parent.width
    spacing: Style.space(10)

    // ---- Title block: glyph, name (or type), then type · day · clock.
    Item {
      width: parent.width
      implicitHeight: Math.max(glyphText.implicitHeight, titleColumn.implicitHeight)

      Text {
        textFormat: Text.PlainText
        id: glyphText
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        text: detail.glyph
        color: detail.dim
        font.family: detail.fontFamily
        font.pixelSize: Style.font.subtitle
      }

      Column {
        id: titleColumn
        anchors.left: glyphText.right
        anchors.leftMargin: Style.space(10)
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(2)

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: detail.title
          color: detail.muted ? detail.dim : detail.foreground
          font.family: detail.fontFamily
          font.pixelSize: Style.font.subtitle
          font.bold: true
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: detail.subtitle
          color: detail.dim
          font.family: detail.fontFamily
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }
      }
    }

    // ---- The figures, two to a row, on the same tinted ground as a card.
    Rectangle {
      visible: detail.metrics.length > 0
      width: parent.width
      implicitHeight: grid.implicitHeight + Style.space(10) * 2
      height: implicitHeight
      radius: Style.cornerRadius
      color: Util.alpha(detail.foreground, 0.075)

      Grid {
        id: grid
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: Style.space(12)
        anchors.rightMargin: Style.space(12)
        anchors.verticalCenter: parent.verticalCenter
        columns: 2
        columnSpacing: Style.space(20)
        rowSpacing: Style.space(10)
        readonly property real cellWidth: (width - columnSpacing) / 2

        Repeater {
          model: detail.metrics

          Item {
            required property var modelData
            width: grid.cellWidth
            implicitHeight: Math.max(labelText.implicitHeight, valueText.implicitHeight)

            Text {
              textFormat: Text.PlainText
              id: labelText
              anchors.left: parent.left
              anchors.right: valueText.left
              anchors.rightMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
              text: String(modelData.label || "")
              color: detail.dim
              font.family: detail.fontFamily
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
            }

            Text {
              textFormat: Text.PlainText
              id: valueText
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: String(modelData.value || "")
              color: detail.muted ? detail.dim : detail.foreground
              font.family: detail.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
            }
          }
        }
      }
    }

    Text {
      textFormat: Text.PlainText
      visible: detail.metrics.length === 0
      width: parent.width
      text: "Garmin recorded no figures for this activity."
      color: detail.dim
      font.family: detail.fontFamily
      font.pixelSize: Style.font.body
    }

    // ---- Leaving the desktop is always a click on a labelled button. Hidden,
    //      not disabled, when there is no id to link to or the data is demo.
    Button {
      visible: detail.linkable
      iconText: "󰏌"  // nf-md-open_in_new, U+F03CC
      text: "Open in Garmin Connect"
      foreground: detail.foreground
      accent: detail.accentColor
      fontFamily: detail.fontFamily
      fontSize: Style.font.bodySmall
      bordered: true
      onClicked: detail.openRequested()
    }

    // Panel.openInConnect learns whether an opener took the URL; when none
    // did, say so rather than leaving a button that silently did nothing.
    Text {
      textFormat: Text.PlainText
      visible: detail.linkable && detail.failed
      width: parent.width
      text: "Could not open a browser"
      color: detail.urgentColor
      font.family: detail.fontFamily
      font.pixelSize: Style.font.caption
    }
  }
}
