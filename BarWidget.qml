import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Garmin Body Battery chip for the bar.
//
// The chip is the whole widget for people who never click it, so it has to say
// something honest in every state the helper can be in: a number when we have
// one we still stand behind, an em dash when we do not, a trailing dot when
// the number is older than it should be. Left click opens the detail panel,
// middle click forces a refresh.
BarWidget {
  id: root
  moduleName: "io.github.n1byn1kt.garmin"

  readonly property bool showSteps: setting("showSteps", false) === true

  // Monochrome nerd-font bolt (nf-md-lightning-bolt, U+F140B) rather than the
  // U+26A1 emoji: fontconfig hands emoji to a colour font, which ignores the
  // theme entirely and paints an orange blob next to the monochrome glyphs
  // every other bar widget uses.
  readonly property string boltGlyph: "󱐋"

  Service {
    id: service
    pollMinutes: Number(root.setting("pollMinutes", 30)) || 30
    // One helper process per bar, not one per screen. Re-asked on every tick,
    // so losing a monitor promotes a surviving instance instead of stopping.
    canPoll: function () { return root.isPrimaryInstance() }
    onRefreshed: {
      root.publish()
      root.syncIpc()
    }
  }

  // ---- On-demand refresh
  //
  // A refresh request is an *intent*, not a fetch. Every entry point — the
  // chip's middle click, the panel's Refresh button, `qs ipc call garmin
  // refresh` — goes through requestRefresh(), which fans the intent out to
  // every instance of this widget; only the primary acts on it, and it then
  // publishes the payload to its peers exactly as it does for a poll. Without
  // that guard, three monitors meant three helper processes and three Garmin
  // sessions per click, and the two extra results were thrown away.
  //
  // On a single screen the fan-out is a list of one, so the primary handles
  // its own request directly and nothing about the behaviour changes.
  function requestRefresh() {
    root.broadcast("refresh")
  }

  // The broadcast target. Named `refresh` because that is the string
  // BarWidget.broadcast() looks up on each peer.
  function refresh() {
    if (!root.isPrimaryInstance()) return
    service.refresh()
  }

  // ---- Multi-screen coordination
  //
  // The bar builds one copy of this widget per monitor. Only the first may
  // talk to Garmin; the rest are handed the result so all screens agree
  // without paying for the fetch three times.
  function peers() {
    return root.bar && typeof root.bar.moduleWidgets === "function"
      ? root.bar.moduleWidgets(root.moduleName) : [root]
  }

  function isPrimaryInstance() {
    var items = root.peers()
    return items.length === 0 || items[0] === root
  }

  function publish() {
    if (!root.isPrimaryInstance()) return
    var items = root.peers()
    for (var i = 0; i < items.length; i++) {
      if (items[i] && items[i] !== root && typeof items[i].acceptPayload === "function")
        items[i].acceptPayload(service.state, service.data, service.lastError)
    }
  }

  function acceptPayload(state, data, lastError) {
    service.adopt(state, data, lastError)
  }

  // ---- State → presentation
  // Coerced through Number() rather than displayed raw. The payload comes from
  // Garmin via a JSON file on disk, and a string where a number belongs would
  // be rendered verbatim — widening the chip and shoving every widget to its
  // left along the bar. Anything that will not coerce reads as no data at all.
  readonly property var bb: {
    var raw = service.data && service.data.bodyBattery ? service.data.bodyBattery.current : null
    if (raw === null || raw === undefined || raw === "") return null
    var n = Number(raw)
    return isFinite(n) ? Math.round(n) : null
  }
  readonly property bool hasBattery: bb !== null

  readonly property var stepCount: {
    var raw = service.data && service.data.steps ? service.data.steps.count : null
    if (raw === null || raw === undefined || raw === "") return null
    var n = Number(raw)
    return isFinite(n) ? n : null
  }

  // Two kinds of broken, and they must not look alike. A missing dependency or
  // a dead login means we have no route to today's number at all, so showing
  // the last one we happen to remember would be a lie the user cannot see
  // through — those states blank to an em dash. A network blip or a bad API
  // response is a temporary hole in an otherwise working pipe, so the last
  // number stays up with a stale mark on it.
  readonly property bool authBlocked:
    ["deps", "no-tokens", "auth-expired"].indexOf(service.state) !== -1
  readonly property bool transientFailure:
    ["offline", "api-error"].indexOf(service.state) !== -1

  readonly property bool showNumbers: root.hasBattery && !root.authBlocked
  readonly property bool showStaleMark:
    root.showNumbers && (service.state === "stale" || root.transientFailure)
  readonly property bool degraded:
    root.authBlocked || root.transientFailure || service.state === "stale"

  readonly property string displayText: {
    var t = root.boltGlyph + (root.showNumbers ? root.bb : "—")
    if (root.showNumbers && root.showSteps && root.stepCount !== null)
      t += "  " + (root.stepCount / 1000).toFixed(1) + "k"
    if (root.showStaleMark) t += " ·"
    return t
  }

  readonly property var verticalLines: root.displayText.split("  ")

  // Colour carries the reading, not the state: accent when you have battery
  // left, urgent when you are nearly empty, plain in between. Degraded states
  // stay plain and dim so a broken helper never looks like a health alarm.
  // Taken off the bar where the bar defines it, so a transparent bar's
  // recoloured foreground carries through instead of being overpainted.
  readonly property bool levelIsNotable:
    root.showNumbers && !root.degraded && (root.bb >= 60 || root.bb < 30)
  readonly property color levelColor: root.bb >= 60
    ? (root.bar && root.bar.accent !== undefined ? root.bar.accent : Color.accent)
    : (root.bar ? root.bar.urgent : Color.urgent)

  readonly property string asOfText: service.data && service.data.asOf ? String(service.data.asOf) : ""

  readonly property string stateLabel: {
    switch (service.state) {
    case "loading": return "checking…"
    case "deps": return "helper dependencies missing"
    case "no-tokens": return "not signed in — run garmin-widget login"
    case "auth-expired": return "session expired — run garmin-widget login"
    case "offline": return root.asOfText !== "" ? "offline — as of " + root.asOfText : "offline"
    case "api-error": return root.asOfText !== "" ? "Garmin API error — as of " + root.asOfText : "Garmin API error"
    case "stale": return root.asOfText !== "" ? "stale — as of " + root.asOfText : "stale — showing last known data"
    default: return root.asOfText !== "" ? "as of " + root.asOfText : "up to date"
    }
  }

  readonly property string tooltip: {
    var lines = ["Body Battery" + (root.showNumbers ? " " + root.bb : "")]
    lines.push(root.stateLabel)
    if (service.lastError !== "" && service.state !== "live") lines.push(service.lastError)
    lines.push("left detail · middle refresh")
    return lines.join("\n")
  }

  // ---- Panel wiring.
  //
  // Panel.qml is loaded lazily, the way the built-in weather/clock plugins do
  // it, and every accessor below guards on `panelLoader.item` so the chip keeps
  // working if the panel ever fails to load. Shape contract for
  // shell.summon/hide/toggle routing: Bar.findPanelWidget requires
  // open/close/opened on the bar-widget root.
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

  onBarChanged: {
    injectPanel()
    Qt.callLater(root.syncIpc)
  }
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: active ? Qt.resolvedUrl("Panel.qml") : ""
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  // ---- IPC
  //
  // `qs ipc call garmin …` addresses one target name, but the bar builds one
  // copy of this widget per monitor and each would try to claim it. Two
  // handlers on one target is the same duplicate-registration shape that
  // crashed the shell before, so only the primary instance registers; the
  // handlers it exposes already fan out to the others through broadcast().
  //
  // Re-checked rather than bound: peers() is empty while the bar is still
  // registering widgets, so an eager binding would have every instance decide
  // it was primary. syncIpc() runs once the bar has settled and again on every
  // poll, so unplugging the primary's screen promotes a survivor within a
  // cycle instead of leaving `qs ipc call garmin` permanently dead.
  property bool ipcEnabled: false

  function syncIpc() {
    root.ipcEnabled = root.isPrimaryInstance()
  }

  Timer {
    id: ipcSettleTimer
    interval: 1500
    repeat: false
    running: true
    onTriggered: root.syncIpc()
  }

  IpcHandler {
    target: "garmin"
    enabled: root.ipcEnabled

    function refresh(): void { root.requestRefresh() }
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
    dimmed: root.degraded || service.state === "loading"
    horizontalMargin: 8.75
    verticalPadding: 8.75

    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.requestRefresh()
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
