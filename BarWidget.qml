import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Garmin health chip for the bar.
//
// The chip is the whole widget for people who never click it, so it has to say
// something honest in every state the helper can be in: a number when we have
// one we still stand behind, an em dash when we do not, a trailing dot when
// the number is older than it should be. Left click opens the detail panel,
// middle click forces a refresh.
//
// Which number it carries is a setting; the honesty rules above are not.
BarWidget {
  id: root
  moduleName: "io.github.n1byn1kt.garmin"

  // ---- Which metric the chip carries
  //
  // Case-insensitive and typo-tolerant: anything that is not one of the four
  // known metrics falls back to Body Battery rather than blanking the chip,
  // for the same reason an unknown panel token drops a card instead of the
  // panel.
  // Precedence: the panel's edit mode (prefs.json) beats the shell.json
  // setting, which beats the default. The pref is what the user picked most
  // recently and by hand, so it wins; deleting prefs.json hands control back to
  // shell.json with nothing else to undo.
  readonly property var knownBarMetrics: ["bodyBattery", "steps", "sleep", "readiness"]
  readonly property string barMetric: {
    var pref = String(service.prefBarMetric || "")
    var raw = (pref !== "" ? pref : String(root.setting("barMetric", "bodyBattery")))
      .replace(/^\s+|\s+$/g, "").toLowerCase()
    for (var i = 0; i < root.knownBarMetrics.length; i++)
      if (root.knownBarMetrics[i].toLowerCase() === raw) return root.knownBarMetrics[i]
    return "bodyBattery"
  }

  // Steps as the headline figure and steps as the trailing figure is the same
  // number twice, so the setting quietly loses to the metric choice.
  readonly property bool showSteps:
    setting("showSteps", false) === true && root.barMetric !== "steps"

  // Monochrome nerd-font glyphs (nf-md-*) rather than emoji: fontconfig hands
  // emoji to a colour font, which ignores the theme entirely and paints an
  // orange blob next to the monochrome glyphs every other bar widget uses.
  // Each codepoint was checked against the cmap of the box's actual bar font,
  // and each matches the icon the panel's card for the same metric uses.
  readonly property string boltGlyph: "󱐋"
  readonly property string metricGlyph: {
    switch (root.barMetric) {
    case "steps": return "󰖃"      // nf-md-walk, U+F0583
    case "sleep": return "󰒲"      // nf-md-sleep, U+F04B2
    case "readiness": return "󰓅"  // nf-md-speedometer, U+F04C5
    default: return root.boltGlyph // nf-md-lightning-bolt, U+F140B
    }
  }

  // Nerd-font md glyphs are drawn at ~1.4 cells wide but advance one cell, so
  // the wide ones paint straight over the first digit. Measured against the
  // box's bar font (hmtx advance 600 vs glyf xMax): bolt 550 and walk 571 fit,
  // sleep 918 and speedometer 832 do not — those two get a space to sit in.
  readonly property string metricGap:
    (root.barMetric === "sleep" || root.barMetric === "readiness") ? " " : ""

  readonly property string metricLabel: {
    switch (root.barMetric) {
    case "steps": return "Steps"
    case "sleep": return "Sleep score"
    case "readiness": return "Training readiness"
    default: return "Body Battery"
    }
  }

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
    // A pref written on this screen is a pref every screen's chip and panel
    // must honour, so the write fans out as a re-read rather than a copy.
    onPrefsWritten: root.broadcast("reloadPrefs")
  }

  // ---- prefs (panel edit mode)
  function setPref(key, value) { return service.setPref(key, value) }
  function reloadPrefs() { service.loadPrefs() }

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
        items[i].acceptPayload(service.state, service.payload, service.lastError)
    }
  }

  function acceptPayload(state, payload, lastError) {
    service.adopt(state, payload, lastError)
  }

  // ---- State → presentation
  // Coerced through Number() rather than displayed raw. The payload comes from
  // Garmin via a JSON file on disk, and a string where a number belongs would
  // be rendered verbatim — widening the chip and shoving every widget to its
  // left along the bar. Anything that will not coerce reads as no data at all.
  function num(raw) {
    if (raw === null || raw === undefined || raw === "") return null
    var n = Number(raw)
    return isFinite(n) ? n : null
  }

  readonly property var bb: {
    var n = root.num(service.payload && service.payload.bodyBattery ? service.payload.bodyBattery.current : null)
    return n === null ? null : Math.round(n)
  }

  readonly property var stepCount:
    root.num(service.payload && service.payload.steps ? service.payload.steps.count : null)

  readonly property var stepGoal: {
    var g = root.num(service.payload && service.payload.steps ? service.payload.steps.goal : null)
    if (g !== null && g > 0) return g
    var fallback = root.num(root.setting("stepsGoalFallback", 10000))
    return fallback !== null && fallback > 0 ? fallback : 10000
  }

  readonly property var sleepScore: {
    var n = root.num(service.payload && service.payload.sleep ? service.payload.sleep.score : null)
    return n === null ? null : Math.round(n)
  }

  readonly property var readinessScore: {
    var n = root.num(service.payload && service.payload.readiness ? service.payload.readiness.score : null)
    return n === null ? null : Math.round(n)
  }

  // The chosen metric's number, and how it reads on a bar where every pixel is
  // contested: steps go to `8.0k` the way the secondary figure always has,
  // everything else is a bare score.
  readonly property var metricValue: {
    switch (root.barMetric) {
    case "steps": return root.stepCount
    case "sleep": return root.sleepScore
    case "readiness": return root.readinessScore
    default: return root.bb
    }
  }
  readonly property bool hasValue: root.metricValue !== null

  readonly property string metricText: {
    if (!root.hasValue) return "—"
    if (root.barMetric === "steps") return (root.metricValue / 1000).toFixed(1) + "k"
    return String(root.metricValue)
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

  readonly property bool showNumbers: root.hasValue && !root.authBlocked
  readonly property bool showStaleMark:
    root.showNumbers && (service.state === "stale" || root.transientFailure)
  readonly property bool degraded:
    root.authBlocked || root.transientFailure || service.state === "stale"

  readonly property string displayText: {
    var t = root.metricGlyph + root.metricGap + (root.showNumbers ? root.metricText : "—")
    if (root.showNumbers && root.showSteps && root.stepCount !== null)
      t += "  " + (root.stepCount / 1000).toFixed(1) + "k"
    if (root.showStaleMark) t += " ·"
    return t
  }

  readonly property var verticalLines: root.displayText.split("  ")

  // Colour carries the reading, not the state: accent when the number is good
  // news, urgent when it is bad news, plain in between. Degraded states stay
  // plain and dim so a broken helper never looks like a health alarm.
  //
  // The bands are per metric and match the panel's cards, so the chip and the
  // card for the same metric never disagree about whether today is good.
  // Steps are the one metric with no urgent band: being short of a step goal
  // at 11am is not an emergency, it is the middle of a day.
  readonly property string levelTone: {
    if (!root.showNumbers || root.degraded) return ""
    var v = root.metricValue
    switch (root.barMetric) {
    case "steps": return root.stepGoal > 0 && v >= root.stepGoal ? "accent" : ""
    case "readiness": return v >= 75 ? "accent" : (v < 35 ? "urgent" : "")
    default: return v >= 60 ? "accent" : (v < 30 ? "urgent" : "")
    }
  }

  readonly property bool levelIsNotable: root.levelTone !== ""

  // Taken off the bar where the bar defines it, so a transparent bar's
  // recoloured foreground carries through instead of being overpainted.
  readonly property color levelColor: root.levelTone === "urgent"
    ? (root.bar ? root.bar.urgent : Color.urgent)
    : (root.bar && root.bar.accent !== undefined ? root.bar.accent : Color.accent)

  readonly property string asOfText: service.payload && service.payload.asOf ? String(service.payload.asOf) : ""

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
    var lines = [root.metricLabel + (root.showNumbers ? " " + root.metricText : "")]
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
