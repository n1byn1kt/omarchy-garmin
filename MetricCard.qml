import QtQuick
import qs.Commons
import qs.Ui

// One metric, one tinted card: icon + title on the left, the figure on the
// right, and — when the payload has them — a goal meter, a caption, and a
// seven-day bar strip underneath.
//
// The card is deliberately dumb. Every string is formatted by Panel.qml and
// every bar arrives pre-normalised, so nothing here has to know what a Body
// Battery is or which direction a good resting heart rate moves in.
Rectangle {
  id: card

  property string icon: ""
  property string title: ""
  property string value: "—"
  property string caption: ""

  // Delta glyph vs the previous day, with its own tone: a rising resting
  // heart rate and a rising step count are not the same news, so the arrow
  // and its colour are decided by the caller.
  property string delta: ""
  property string deltaTone: ""

  // "" | "accent" | "urgent" — threshold banding for the figure itself.
  property string tone: ""

  // Below zero hides the meter entirely. Zero is a real reading (no steps
  // yet today) and still draws an empty track.
  property real meterPercent: -1

  // [{ label: "Tu", frac: 0.62, present: true, tip: "Tu Sep 2 · 8,953" }, …]
  // — always seven entries when present at all; absent days keep their faint
  // track so a two-day history reads as "we only have two days", not as five
  // zero days. `tip` is the hover text; it is pre-formatted by the caller.
  property var strip: []

  property color foreground: Color.foreground
  property color accentColor: Color.accent
  property color urgentColor: Color.urgent
  property color dim: Qt.darker(foreground, 1.55)
  property string fontFamily: Style.font.family

  // Stale data keeps its numbers but loses its colour: a cached reading must
  // not look like a live alarm or a live achievement.
  property bool muted: false

  function toneColor(name) {
    if (card.muted) return name === "" ? card.foreground : card.dim
    if (name === "urgent") return card.urgentColor
    if (name === "accent") return card.accentColor
    return card.foreground
  }

  readonly property color fillColor: card.muted ? card.dim : card.accentColor

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
      implicitHeight: Math.max(iconText.implicitHeight, titleText.implicitHeight, valueRow.implicitHeight)

      Text {
        textFormat: Text.PlainText
        id: iconText
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
        id: titleText
        text: card.title
        color: card.dim
        font.family: card.fontFamily
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
        anchors.left: iconText.visible ? iconText.right : parent.left
        anchors.leftMargin: iconText.visible ? Style.space(8) : 0
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
          anchors.verticalCenter: parent.verticalCenter
          text: card.value
          color: card.toneColor(card.tone)
          font.family: card.fontFamily
          font.pixelSize: Style.font.subtitle
          font.bold: true
        }
      }
    }

    Meter {
      visible: card.meterPercent >= 0
      width: parent.width
      percent: Math.max(0, card.meterPercent)
      foreground: card.foreground
      fillColor: card.fillColor
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

    // ---- Seven-day strip (the screentime bar idiom)
    //
    // Bars sit on the baseline so the eye reads height, and every day —
    // including the ones we have no entry for — keeps a faint track so the
    // week's shape stays legible at one or two days of history.
    Row {
      id: stripRow
      visible: card.strip !== undefined && card.strip !== null && card.strip.length > 0
      width: parent.width
      spacing: Style.space(3)
      topPadding: Style.space(2)

      readonly property real slotWidth:
        (width - spacing * Math.max(0, card.strip.length - 1)) / Math.max(1, card.strip.length)

      Repeater {
        model: stripRow.visible ? card.strip : []

        Item {
          id: slot
          required property var modelData
          required property int index

          readonly property bool isLatest: slot.index === card.strip.length - 1
          readonly property bool present: modelData.present === true

          width: stripRow.slotWidth
          height: track.height + Style.space(2) + slotLabel.implicitHeight

          Rectangle {
            id: track
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            height: Style.space(22)
            radius: Style.space(2)
            color: Util.alpha(card.foreground, 0.09)
          }

          Rectangle {
            visible: slot.present
            anchors.left: track.left
            anchors.right: track.right
            anchors.bottom: track.bottom
            radius: track.radius
            height: Math.max(2, track.height * Math.max(0, Math.min(1, Number(slot.modelData.frac) || 0)))
            color: slot.isLatest ? card.fillColor : Util.alpha(card.foreground, 0.28)
          }

          // Hover to read the bar. The tooltip is the cheapest answer to "what
          // was Tuesday" and needs no expanded view behind it.
          MouseArea {
            id: slotMouse
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.NoButton
            cursorShape: Qt.ArrowCursor

            PanelToolTip {
              visible: slotMouse.containsMouse && String(slot.modelData.tip || "") !== ""
              text: String(slot.modelData.tip || "")
              fontFamily: card.fontFamily
            }
          }

          Text {
            textFormat: Text.PlainText
            id: slotLabel
            anchors.top: track.bottom
            anchors.topMargin: Style.space(2)
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: String(slot.modelData.label || "")
            color: card.dim
            opacity: slot.present ? 1.0 : 0.45
            font.family: card.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}
