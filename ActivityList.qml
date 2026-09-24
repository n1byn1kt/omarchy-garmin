import QtQuick
import qs.Commons
import qs.Ui

// The activity card's page: the most recent activities, one row each.
//
// Dumb, like WeekView: Panel.qml formats every string and owns the cursor.
// `rows` entries are
//   { glyph, title, dateText, durationText, distanceText, hrText, kcalText, tip }
// with "" for anything the activity did not record. Every row the helper
// persisted is drawn — the helper keeps exactly as many as fit here, so there
// is no "and N more" line for rows nobody could open.
//
// Hover moves the panel's cursor rather than painting its own highlight (the
// CursorSurface contract), so mouse and keyboard can never show two rows lit.
Item {
  id: list

  property var rows: []
  property int cursor: 0
  property string heading: ""
  property string summary: ""

  property color foreground: Color.foreground
  property color accentColor: Color.accent
  property color dim: Qt.darker(foreground, 1.55)
  property string fontFamily: Style.font.family
  property bool muted: false

  signal hovered(int index)
  signal activated(int index)

  implicitHeight: column.implicitHeight

  // Column widths come from the widest thing each column can hold, measured
  // in the real font, so a theme with a wider face widens the columns rather
  // than clipping them. The title column takes whatever is left.
  readonly property real gap: Style.space(8)
  readonly property real padX: Style.space(8)
  TextMetrics { id: mGlyph; font.family: list.fontFamily; font.pixelSize: Style.font.bodySmall; text: "󰜎" }
  TextMetrics { id: mDate; font.family: list.fontFamily; font.pixelSize: Style.font.caption; text: "Sep 30 '26" }
  TextMetrics { id: mDur; font.family: list.fontFamily; font.pixelSize: Style.font.caption; text: "10h00m" }
  TextMetrics { id: mKm; font.family: list.fontFamily; font.pixelSize: Style.font.caption; text: "100.00" }
  TextMetrics { id: mHr; font.family: list.fontFamily; font.pixelSize: Style.font.caption; text: "1000" }
  TextMetrics { id: mKcal; font.family: list.fontFamily; font.pixelSize: Style.font.caption; text: "1,000" }
  readonly property real wGlyph: Math.ceil(mGlyph.advanceWidth) + Style.space(2)
  readonly property real wDate: Math.ceil(mDate.advanceWidth)
  readonly property real wDur: Math.ceil(mDur.advanceWidth)
  readonly property real wKm: Math.ceil(mKm.advanceWidth)
  readonly property real wHr: Math.ceil(mHr.advanceWidth)
  readonly property real wKcal: Math.ceil(mKcal.advanceWidth)

  Column {
    id: column
    width: parent.width
    spacing: Style.space(2)

    // ---- Heading: how many rows these are, and the week they cover (or,
    //      when the rows cannot prove they cover it, just "N most recent").
    Item {
      width: parent.width
      implicitHeight: Math.max(headingText.implicitHeight, summaryText.implicitHeight) + Style.space(4)

      Text {
        textFormat: Text.PlainText
        id: headingText
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        text: list.heading
        color: list.dim
        font.family: list.fontFamily
        font.pixelSize: Style.font.bodySmall
      }

      Text {
        textFormat: Text.PlainText
        id: summaryText
        anchors.left: headingText.right
        anchors.leftMargin: Style.space(10)
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        horizontalAlignment: Text.AlignRight
        text: list.summary
        color: list.muted ? list.dim : list.foreground
        font.family: list.fontFamily
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideLeft
      }
    }

    // ---- Column headers carry the units, once.
    Row {
      x: list.padX + list.wGlyph + list.gap
      width: parent.width - x - list.padX
      spacing: list.gap
      readonly property real wTitle: Math.max(0, width - list.wDate - list.wDur - list.wKm - list.wHr - list.wKcal - spacing * 5)

      Repeater {
        model: [
          { "t": "", "w": "title", "r": false }, { "t": "date", "w": "date", "r": false },
          { "t": "time", "w": "dur", "r": true }, { "t": "km", "w": "km", "r": true },
          { "t": "bpm", "w": "hr", "r": true }, { "t": "kcal", "w": "kcal", "r": true }
        ]

        Text {
          textFormat: Text.PlainText
          required property var modelData
          width: modelData.w === "title" ? parent.wTitle : modelData.w === "date" ? list.wDate
            : modelData.w === "dur" ? list.wDur : modelData.w === "km" ? list.wKm
            : modelData.w === "hr" ? list.wHr : list.wKcal
          horizontalAlignment: modelData.r ? Text.AlignRight : Text.AlignLeft
          text: modelData.t
          color: list.dim
          opacity: 0.7
          font.family: list.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }

    Repeater {
      model: list.rows

      CursorSurface {
        id: rowSurface
        required property var modelData
        required property int index

        width: column.width
        implicitHeight: rowContent.implicitHeight + Style.space(5) * 2
        hasCursor: list.cursor === rowSurface.index
        foreground: list.foreground
        accent: list.accentColor

        MouseArea {
          id: rowMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onContainsMouseChanged: if (rowMouse.containsMouse) list.hovered(rowSurface.index)
          onClicked: list.activated(rowSurface.index)

          PanelToolTip {
            visible: rowMouse.containsMouse && String(rowSurface.modelData.tip || "") !== ""
            text: String(rowSurface.modelData.tip || "")
            fontFamily: list.fontFamily
          }
        }

        Row {
          id: rowContent
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.leftMargin: list.padX
          anchors.rightMargin: list.padX
          anchors.verticalCenter: parent.verticalCenter
          spacing: list.gap
          readonly property real wTitle: Math.max(0, width - list.wGlyph - list.wDate - list.wDur - list.wKm - list.wHr - list.wKcal - spacing * 6)

          Text {
            textFormat: Text.PlainText
            anchors.verticalCenter: parent.verticalCenter
            width: list.wGlyph
            text: String(rowSurface.modelData.glyph || "")
            color: list.dim
            font.family: list.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Text {
            textFormat: Text.PlainText
            anchors.verticalCenter: parent.verticalCenter
            width: rowContent.wTitle
            text: String(rowSurface.modelData.title || "")
            color: list.foreground
            font.family: list.fontFamily
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
          }

          Text {
            textFormat: Text.PlainText
            anchors.verticalCenter: parent.verticalCenter
            width: list.wDate
            text: String(rowSurface.modelData.dateText || "")
            color: list.dim
            font.family: list.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          Text {
            textFormat: Text.PlainText
            anchors.verticalCenter: parent.verticalCenter
            width: list.wDur
            horizontalAlignment: Text.AlignRight
            text: String(rowSurface.modelData.durationText || "")
            color: list.dim
            font.family: list.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideLeft
          }

          Text {
            textFormat: Text.PlainText
            anchors.verticalCenter: parent.verticalCenter
            width: list.wKm
            horizontalAlignment: Text.AlignRight
            text: String(rowSurface.modelData.distanceText || "")
            color: list.dim
            font.family: list.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideLeft
          }

          Text {
            textFormat: Text.PlainText
            anchors.verticalCenter: parent.verticalCenter
            width: list.wHr
            horizontalAlignment: Text.AlignRight
            text: String(rowSurface.modelData.hrText || "")
            color: list.dim
            font.family: list.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideLeft
          }

          Text {
            textFormat: Text.PlainText
            anchors.verticalCenter: parent.verticalCenter
            width: list.wKcal
            horizontalAlignment: Text.AlignRight
            text: String(rowSurface.modelData.kcalText || "")
            color: list.dim
            font.family: list.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideLeft
          }
        }
      }
    }

    Text {
      textFormat: Text.PlainText
      visible: list.rows.length === 0
      width: parent.width
      text: "No activities recorded."
      color: list.dim
      font.family: list.fontFamily
      font.pixelSize: Style.font.body
    }
  }
}
