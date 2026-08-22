import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Garmin Body Battery chip for the bar.
//
// The chip is the whole widget for people who never click it, so it has to say
// something honest in every state the helper can be in: a number when we have
// one, an em dash when we do not, a trailing dot when the number is yesterday's.
// Left click opens the detail panel, middle click forces a refresh.
BarWidget {
  id: root
  moduleName: "io.github.n1byn1kt.garmin"

  readonly property bool showSteps: setting("showSteps", false) === true

  Service {
    id: service
    pollMinutes: Number(root.setting("pollMinutes", 30)) || 30
  }

  function refresh() {
    service.refresh()
  }

  // ---- State → presentation
  readonly property var bb: service.data && service.data.bodyBattery ? service.data.bodyBattery.current : null
  readonly property bool hasBattery: bb !== null && bb !== undefined

  // Every state where the number on screen cannot be trusted as "now".
  readonly property bool degraded:
    ["deps", "no-tokens", "auth-expired", "api-error", "offline"].indexOf(service.state) !== -1

  readonly property string displayText: {
    var t = "⚡" + (root.hasBattery ? root.bb : "—")
    if (root.showSteps && service.data && service.data.steps
        && service.data.steps.count !== null && service.data.steps.count !== undefined)
      t += "  " + (service.data.steps.count / 1000).toFixed(1) + "k"
    if (service.state === "stale") t += " ·"
    return t
  }

  readonly property var verticalLines: root.displayText.split("  ")

  // Colour carries the reading, not the state: green-ish when you have battery
  // left, urgent when you are nearly empty, plain in between. Degraded states
  // stay plain and dim so a broken helper never looks like a health alarm.
  readonly property bool levelIsNotable: root.hasBattery && !root.degraded && (root.bb >= 60 || root.bb < 30)
  readonly property color levelColor: root.bb >= 60 ? Color.accent : Color.urgent

  readonly property string stateLabel: {
    switch (service.state) {
    case "loading": return "checking…"
    case "deps": return "helper dependencies missing"
    case "no-tokens": return "not signed in — run garmin-widget login"
    case "auth-expired": return "session expired — run garmin-widget login"
    case "offline": return "offline"
    case "api-error": return "Garmin API error"
    case "stale": return "showing last known data"
    default: return service.data && service.data.asOf ? "as of " + service.data.asOf : "up to date"
    }
  }

  readonly property string tooltip: {
    var lines = ["Body Battery" + (root.hasBattery ? " " + root.bb : "")]
    lines.push(root.stateLabel)
    if (service.lastError !== "" && service.state !== "live") lines.push(service.lastError)
    lines.push("left detail · middle refresh")
    return lines.join("\n")
  }

  // ---- Panel groundwork (Task 7 supplies Panel.qml).
  //
  // The loader is wired but parked: pointing it at a file that does not exist
  // yet would spray QML errors into the shell log on every reload. Task 7
  // flips `active` to true and drops Panel.qml in beside this file; every
  // accessor below already guards on `panelLoader.item`, so nothing else here
  // needs to change. Shape contract for shell.summon/hide/toggle routing:
  // Bar.findPanelWidget requires open/close/opened on the bar-widget root.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item && panelLoader.item.openFromHotkey) panelLoader.item.openFromHotkey()
    else if (panelLoader.item && panelLoader.item.open) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item && panelLoader.item.closeForPopoutSwitch) panelLoader.item.closeForPopoutSwitch()
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
    if ("service" in target) target.service = service
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: false                       // Task 7: set true alongside Panel.qml
    source: active ? Qt.resolvedUrl("Panel.qml") : ""
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    target: "garmin"

    function refresh(): void { root.broadcast("refresh") }
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.togglePanel() }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.vertical ? "" : root.displayText
    labelVisible: !root.vertical
    hasVisualContent: root.vertical ? root.verticalLines.length > 0 : text !== ""
    fixedHeight: root.vertical ? root.verticalLines.length * Style.bar.iconSlot : -1
    tooltipText: root.tooltip
    active: root.levelIsNotable
    activeColor: root.levelColor
    dimmed: root.degraded || service.state === "stale" || service.state === "loading"
    horizontalMargin: 8.75
    verticalPadding: 8.75

    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.broadcast("refresh")
      else root.togglePanel()
    }

    Column {
      visible: root.vertical
      anchors.fill: parent

      Repeater {
        model: root.verticalLines

        OpticalGlyph {
          required property string modelData
          width: button.width
          height: Style.bar.iconSlot
          text: modelData
          fontFamily: button.fontFamily
          fontSize: button.fontSize
          color: button.foreground
        }
      }
    }
  }
}
