import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Ui

// Detail panel for the Garmin bar chip.
//
// The chip can only ever show one number, so this is where the widget gets to
// be honest: what today's figures are, how old they are, and — when there are
// no figures — exactly which command fixes it. Every broken state ends in a
// copyable line rather than an apology, because "not signed in" is only useful
// if it comes with the login command attached.
//
// Bound to the Service instance the bar widget already owns (handed over by
// BarWidget.injectPanel), never its own — a second poller would double the
// Garmin API traffic for a panel that is shut most of the time.
Panel {
  id: root
  moduleName: "io.github.n1byn1kt.garmin"
  // The bar widget owns the IpcHandler for target "garmin", so this panel must
  // not claim it too. `manageIpc: false` alone is not enough: the base Panel's
  // handler still carries the target string through registration, and two
  // handlers naming "garmin" segfaulted Quickshell 0.3.0 in
  // IpcHandler::updateRegistration when the plugin hot-reloaded. Leaving
  // ipcTarget empty makes the inherited handler completely inert.
  ipcTarget: ""
  manageIpc: false

  // ---- Injected by BarWidget.injectPanel()
  property var anchorItem: null
  // The bar tracks the widget mounted in its slot — BarWidget.qml — not this
  // nested panel, so the popout coordinator and switchPanelFrom must both be
  // handed that widget rather than `root`.
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root
  property var service: null

  function open() {
    root.controller.show()
    root.refreshIfStale()
  }

  // The bar-widget contract prefers openFromHotkey() when present. There is no
  // hover-reveal state to suppress here, so it is plain open().
  function openFromHotkey() { root.open() }

  function close() { root.controller.hide() }
  function toggle() { root.opened ? root.close() : root.open() }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  // Refreshing goes through the bar widget, not straight at the Service: on a
  // multi-monitor bar this panel's Service is whichever screen's instance
  // happens to own it, and asking it directly would spawn a helper on a
  // non-primary instance whose result nobody ever publishes. requestRefresh()
  // routes the intent to the primary, which fans the payload back out.
  //
  // `week` re-fetches the trailing seven days too. It is what the user's
  // explicit refresh (button, `r`) asks for; the panel-open retry below does
  // not, because opening a panel on a stale morning must not become a
  // fourteen-call burst every time.
  function refresh(week) {
    var burst = week === true
    if (root.hostWidget && typeof root.hostWidget.requestRefresh === "function") root.hostWidget.requestRefresh(burst)
    else if (root.service && typeof root.service.refresh === "function") root.service.refresh(burst)
  }

  // Opening the panel is a request to look at today's numbers, so a broken or
  // outdated state gets one free retry. A `live` state does not — the poller
  // already has it covered, and clicking the chip should not become a way to
  // hammer Garmin's API.
  function refreshIfStale() {
    if (root.svcState !== "live" && root.svcState !== "loading") root.refresh(false)
  }

  // ---- State
  //
  // Named svcState rather than `state`: Item.state already exists here and is
  // a string too, so a same-named property would be a silent trap for anyone
  // who later adds a QML state to this panel.
  readonly property string svcState: root.service ? String(root.service.state) : "loading"
  readonly property var payload: root.service ? root.service.payload : null
  readonly property string lastError: root.service ? String(root.service.lastError || "") : ""
  readonly property bool busy: root.service ? root.service.busy === true : false

  // Same split the chip makes: a missing dependency or a dead login means we
  // have no route to today's number at all, so old data must not be shown as if
  // it were current. A network blip is a hole in a working pipe — the numbers
  // stay up, marked stale.
  readonly property bool authBlocked:
    ["deps", "no-tokens", "auth-expired"].indexOf(root.svcState) !== -1
  readonly property bool unreachable:
    ["offline", "api-error"].indexOf(root.svcState) !== -1

  readonly property bool hasData: !!root.payload && root.payload.ok === true
  readonly property bool showRows: root.hasData && !root.authBlocked
  readonly property bool showStale: root.showRows && (root.svcState === "stale" || root.unreachable)

  // ---- Guidance copy (final strings — these appear in the README screenshots)
  //
  // The login path is derived from the helper the Service actually runs, so a
  // plugin unpacked somewhere unusual still prints a command that works. Only
  // the standard install directory is abbreviated back to `~`.
  readonly property string helperPath: root.service ? String(root.service.helperPath || "") : ""
  readonly property string helperDisplayPath: {
    var p = root.helperPath
    var marker = "/.config/omarchy/plugins/"
    var at = p.indexOf(marker)
    return at === -1 ? p : "~" + p.substring(at)
  }
  readonly property string loginCommand: root.helperDisplayPath + " login"
  // Arch and every other PEP 668 distro refuse `pip install` into the system
  // python, so the command has to build the dedicated venv the helper re-execs
  // into. Prefer the helper's own `hint` — it is the one string guaranteed to
  // match the interpreter that will actually run — and keep the literal below
  // byte-identical to DEPS_HINT in bin/garmin-widget for the case where the
  // hint never arrived (a secondary monitor's adopted payload, an older
  // helper).
  readonly property string depsCommand:
    root.service && String(root.service.lastHint || "") !== ""
      ? String(root.service.lastHint)
      : "python3 -m venv ~/.local/share/garmin-widget/venv && ~/.local/share/garmin-widget/venv/bin/pip install --require-hashes -r ~/.config/omarchy/plugins/io.github.n1byn1kt.garmin/requirements.txt"

  readonly property string guidanceTitle: {
    switch (root.svcState) {
    case "deps": return "Install the helper's dependency:"
    case "no-tokens": return "Connect your Garmin account — run in a terminal:"
    case "auth-expired": return "Garmin session expired — log in again:"
    default: return ""
    }
  }
  readonly property string guidanceCommand: root.svcState === "deps" ? root.depsCommand : root.loginCommand
  readonly property bool showGuidance: root.guidanceTitle !== ""

  // offline / api-error with nothing cached: no numbers and no command to run,
  // just the truth and a retry.
  readonly property bool showUnreachable: root.unreachable && !root.hasData
  readonly property bool showLoading: root.svcState === "loading" && !root.hasData

  readonly property string heroMeta: {
    switch (root.svcState) {
    case "loading": return "Checking…"
    case "deps": return "Helper dependency missing"
    case "no-tokens": return "Not signed in"
    case "auth-expired": return "Session expired"
    case "offline": return "Offline"
    case "api-error": return "Garmin API error"
    case "stale": return "Showing last known data"
    default: return "Today"
    }
  }

  // ---- Formatting
  //
  // Null is a normal answer, not a failure: a night without the watch on has no
  // sleep score, and Garmin simply omits it. Everything renders "—" rather than
  // 0, which would read as a very bad night.
  function fmtNumber(n) {
    return (n === null || n === undefined || !isFinite(Number(n))) ? "—" : String(Math.round(Number(n)))
  }

  function fmtDuration(min) {
    if (min === null || min === undefined || !isFinite(Number(min))) return "—"
    var total = Math.max(0, Math.round(Number(min)))
    return Math.floor(total / 60) + "h" + String(total % 60).padStart(2, "0") + "m"
  }

  function fmtSteps(n) {
    return (n === null || n === undefined || !isFinite(Number(n))) ? "—" : Number(n).toLocaleString()
  }

  // asOf is an ISO-ish local stamp the helper writes ("2026-08-22T14:32"), but
  // it arrives from a cache file that a future helper version may write
  // differently, so nothing here assumes a shape it has not checked.
  function fmtClock(value) {
    var s = String(value || "")
    if (s === "") return ""
    var m = s.match(/(\d{1,2}):(\d{2})/)
    if (m) return ("0" + m[1]).slice(-2) + ":" + m[2]
    // No clock in the string, so show it verbatim. Handing it to `new Date()`
    // instead would parse a date-only stamp fine and render a confident,
    // entirely invented "00:00".
    return s
  }

  property bool copied: false

  // execDetached does take an argv, so `["wl-copy", value]` would avoid the
  // shell entirely — but wl-copy detaches a clipboard-owning child, and going
  // through `bash -c` is the idiom Omarchy's own tailscale and network panels
  // use (shell/plugins/panels/{tailscale/Service,network/Panel}.qml). Matching
  // the shipped pattern is worth more here than dropping one process; the
  // value is shell-quoted, so it is not an injection surface either way.
  function copy(text) {
    var value = String(text || "")
    if (value === "") return
    Quickshell.execDetached(["bash", "-c", "printf %s " + Util.shellQuote(value) + " | wl-copy"])
    root.copied = true
    copiedFlash.restart()
  }

  Timer {
    id: copiedFlash
    interval: 1400
    onTriggered: root.copied = false
  }

  // Numbers arrive from a JSON file on disk, so "is this a number" is asked
  // once, here, and every caller downstream deals in `null` or a real value.
  function num(v) {
    if (v === null || v === undefined || v === "") return null
    var n = Number(v)
    return isFinite(n) ? n : null
  }

  // Garmin sends SCREAMING_SNAKE enum values ("VERY_HIGH", "BALANCED"). They
  // are shouted at the user verbatim nowhere in this panel.
  function titleCase(value) {
    var s = String(value || "").replace(/_/g, " ").toLowerCase()
    if (s === "") return ""
    return s.replace(/(^|\s)([a-z])/g, function (m, lead, ch) { return lead + ch.toUpperCase() })
  }

  // "2026-06-20" → a local Date at midnight. Deliberately not `new Date(str)`:
  // that parses a date-only string as UTC and lands on the previous day for
  // everyone west of Greenwich, which would shift every strip label by one.
  function parseDay(value) {
    var m = String(value || "").match(/^(\d{4})-(\d{2})-(\d{2})/)
    if (!m) return null
    return new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3]))
  }

  function dayKey(d) {
    return d.getFullYear() + "-" + ("0" + (d.getMonth() + 1)).slice(-2) + "-" + ("0" + d.getDate()).slice(-2)
  }

  readonly property var weekdayNames: ["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"]
  readonly property var monthNames: ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

  function fmtDay(value) {
    var d = root.parseDay(value)
    if (!d) return String(value || "")
    return root.monthNames[d.getMonth()] + " " + d.getDate()
  }

  function fmtTimeOfDay(epochMs) {
    var n = root.num(epochMs)
    if (n === null) return ""
    var d = new Date(n)
    return ("0" + d.getHours()).slice(-2) + ":" + ("0" + d.getMinutes()).slice(-2)
  }

  // ---- Activity formatting
  //
  // `start` is the helper's local "YYYY-MM-DDTHH:MM" (older caches are
  // migrated to it helper-side, so the legacy `date` field is never read
  // here). A short or odd string still yields a day where it has one and no
  // invented clock where it does not.
  function activityDay(a) { return a ? root.parseDay(a.start) : null }

  function activityClock(a) {
    var m = String(a && a.start ? a.start : "").match(/T(\d{2}):(\d{2})/)
    return m ? m[1] + ":" + m[2] : ""
  }

  // "Sep 22", with the year only when it is not this one — the list reaches
  // back months for an infrequent exerciser, and "Jan 7" alone would claim
  // the most recent January.
  function activityDate(a) {
    var d = root.activityDay(a)
    if (!d) return ""
    var s = root.monthNames[d.getMonth()] + " " + d.getDate()
    return d.getFullYear() === new Date().getFullYear() ? s : s + " '" + String(d.getFullYear()).slice(-2)
  }

  // Name first (the one thing the user chose or saw as the title), then the
  // type. `activityNames: false` makes the helper drop names entirely.
  function activityTitle(a) {
    if (!a) return ""
    var n = typeof a.name === "string" ? a.name.replace(/^\s+|\s+$/g, "") : ""
    if (n !== "") return n
    var t = root.titleCase(a.type)
    return t !== "" ? t : "Activity"
  }

  // Substring matches, because Garmin's typeKeys come in families
  // (trail_running, treadmill_running, road_biking, indoor_cycling …) and
  // the family is what the glyph means. Every codepoint was checked against
  // the bar font's cmap with fc-list :charset= on the box, and
  // rendered with pango-view to confirm it is the icon its name says
  // (U+F01E5, the plan's dumbbell guess, is a duck).
  function typeGlyph(typeKey) {
    var t = String(typeKey || "").toLowerCase()
    if (t.indexOf("run") !== -1) return "󰜎"          // nf-md-run, U+F070E
    if (t.indexOf("cycl") !== -1 || t.indexOf("bik") !== -1) return "󰂣"  // nf-md-bike, U+F00A3
    if (t.indexOf("hik") !== -1) return "󰵿"         // nf-md-hiking, U+F0D7F
    if (t.indexOf("walk") !== -1) return "󰖃"        // nf-md-walk, U+F0583
    if (t.indexOf("swim") !== -1) return "󰓣"        // nf-md-swim, U+F04E3
    if (t.indexOf("strength") !== -1) return "󱅝"    // nf-md-weight_lifter, U+F115D
    // Yoga, breathwork and meditation share the seated figure: all three are
    // "sat still on purpose", and a runner for a breathing session reads wrong.
    if (t.indexOf("yoga") !== -1 || t.indexOf("breath") !== -1 || t.indexOf("meditat") !== -1)
      return "󱅻"                                     // nf-md-meditation, U+F117B
    return "󰜎"
  }

  function fmtKm(km) {
    var n = root.num(km)
    return n === null ? "" : n.toFixed(2) + " km"
  }

  // ---- Payload accessors (every one tolerates a missing branch)
  readonly property var bodyBattery: root.payload && root.payload.bodyBattery ? root.payload.bodyBattery : null
  readonly property var sleepInfo: root.payload && root.payload.sleep ? root.payload.sleep : null
  readonly property var stepsInfo: root.payload && root.payload.steps ? root.payload.steps : null
  readonly property var curveData: root.payload && root.payload.curve ? root.payload.curve : null
  readonly property var hrvInfo: root.payload && root.payload.hrvStatus ? root.payload.hrvStatus : null
  readonly property var readinessInfo: root.payload && root.payload.readiness ? root.payload.readiness : null
  readonly property var intensityInfo: root.payload && root.payload.intensityMinutes ? root.payload.intensityMinutes : null
  readonly property var floorsInfo: root.payload && root.payload.floors ? root.payload.floors : null
  readonly property var caloriesInfo: root.payload && root.payload.calories ? root.payload.calories : null
  // The helper persists only as many activities as the list page can show
  // (ACTIVITY_ROWS in bin/garmin-widget), so every row here is reachable —
  // no "and N more" line pointing at rows nobody can open. The input cap is
  // the historyInputCap idea again: last.json is a file on disk, and a
  // planted 100k-entry list must not be walked on every repaint.
  readonly property int activityRows: 10
  readonly property int activitiesInputCap: 100
  readonly property var activities: {
    var a = root.payload && root.payload.activities ? root.payload.activities : null
    if (!a || a.length === undefined) return []
    var n = Math.min(a.length, root.activitiesInputCap)
    var out = []
    for (var i = 0; i < n && out.length < root.activityRows; i++)
      if (a[i] && typeof a[i] === "object") out.push(a[i])
    return out
  }
  // The card shows the newest row. `lastActivity` is the same object as
  // activities[0] in every 0.5 payload; it is only read as a fallback for a
  // payload that somehow has the one without the other.
  readonly property var activityInfo: root.activities.length > 0 ? root.activities[0]
    : (root.payload && root.payload.lastActivity ? root.payload.lastActivity : null)

  // ---- Carried-forward domains
  //
  // A secondary endpoint that failed on this fetch keeps its last cached value,
  // and the helper lists its payload key in `carried`. Payload keys and card
  // tokens are spelled differently, and this is the one place that knows the
  // mapping — tests/test_hardening.py checks it against the helper's
  // CARRY_KEYS, so a key added there without a token here fails a test rather
  // than silently never dimming its card.
  readonly property var carriedTokenMap: ({
    "hrvStatus": "hrv",
    "intensityMinutes": "intensity",
    "activities": "activity",
    "readiness": "readiness"
  })
  readonly property var carriedTokens: {
    var c = root.payload && root.payload.carried ? root.payload.carried : null
    var out = []
    if (!c || c.length === undefined) return out
    for (var i = 0; i < Math.min(c.length, 20); i++) {
      // hasOwnProperty, not a bare lookup: a planted "toString" would
      // otherwise find Object.prototype's function and count as a token.
      var key = String(c[i])
      if (!Object.prototype.hasOwnProperty.call(root.carriedTokenMap, key)) continue
      var t = root.carriedTokenMap[key]
      if (out.indexOf(t) === -1) out.push(t)
    }
    return out
  }
  function isCarried(token) { return root.carriedTokens.indexOf(String(token)) !== -1 }
  // A carried card keeps its number but says it is old, on the card itself:
  // the footer's freshness stamp is about the fetch, which did succeed.
  function staleCaption(caption, token) {
    if (!root.isCarried(token)) return caption
    return caption === "" ? "stale" : caption + " · stale"
  }

  // The custom card is not part of the Garmin payload at all — the Service
  // runs the user's command beside the fetch and hands over an already
  // sanitised {title, value, caption, tone, meterPercent}, or null.
  readonly property var customCard: root.service && root.service.customCard ? root.service.customCard : null
  readonly property string customCommand: root.service ? String(root.service.customCommand || "") : ""
  readonly property string customError: root.service ? String(root.service.customError || "") : ""

  // History is a list of daily snapshots the helper keeps in its cache. It can
  // be missing entirely (an older helper), empty (first run), or one entry
  // long — every consumer below has to survive all three.
  //
  // Bounded on the way in, at the one place the payload enters the panel: the
  // helper already trims to seven days, but the cache file is just a file on
  // disk, and a hand-edited (or planted) 100k-entry list would otherwise be
  // sorted and key-mapped on every repaint. The seven-newest cut happens in
  // `historySorted` below, once the entries are actually in date order.
  readonly property int historyDays: 7
  readonly property int historyInputCap: 500
  readonly property var history: {
    var h = root.payload && root.payload.history ? root.payload.history : null
    if (!h || h.length === undefined) return []
    return h.length > root.historyInputCap ? h.slice(0, root.historyInputCap) : h
  }

  readonly property var bbSeries: root.curveData && root.curveData.bodyBattery ? root.curveData.bodyBattery : null
  readonly property var stressSeries: root.curveData && root.curveData.stress ? root.curveData.stress : null

  // The same filter CurveCard.clean() applies before it draws. Counting raw
  // array entries here instead let a two-entry garbage series pass the gate
  // and put a card with an empty plot on screen: the panel said "there is a
  // curve", the card disagreed, and the user got the rectangle without the
  // line. Both sides now count points that could actually be plotted.
  //
  // Bounded at both ends: the helper downsamples to 96 points per series, so
  // for any real payload these caps are no-ops, but the series arrives from a
  // cache file and a 200k-point array would sort-and-repaint the panel into a
  // stall. Read at most 500 entries, keep at most the 96 newest.
  readonly property int curveInputCap: 500
  readonly property int curvePointCap: 96
  function cleanSeries(series) {
    var out = []
    if (!series || series.length === undefined) return out
    var n = Math.min(series.length, root.curveInputCap)
    for (var i = 0; i < n; i++) {
      var p = series[i]
      if (!p || p.length === undefined || p.length < 2) continue
      var t = root.num(p[0])
      var v = root.num(p[1])
      if (t === null || v === null) continue
      out.push([t, v])
    }
    out.sort(function (a, b) { return a[0] - b[0] })
    return out.length > root.curvePointCap
      ? out.slice(out.length - root.curvePointCap) : out
  }

  readonly property var bbPoints: root.cleanSeries(root.bbSeries)
  readonly property var stressPoints: root.cleanSeries(root.stressSeries)
  readonly property bool bbDrawn: root.bbPoints.length >= 2
  readonly property bool stressDrawn: root.stressPoints.length >= 2
  readonly property bool hasCurve: root.bbDrawn || root.stressDrawn

  // The last stress sample, for the days Garmin gives us a stress curve but
  // no Body Battery to head the card with.
  readonly property var lastStress: {
    var s = root.stressPoints
    return s.length < 1 ? null : s[s.length - 1][1]
  }

  // The clock range the curve actually covers, so nobody reads a half-day of
  // samples as a full day.
  readonly property string curveSpan: {
    var pick = root.bbDrawn ? root.bbPoints : root.stressPoints
    if (pick.length < 2) return ""
    var a = root.fmtTimeOfDay(pick[0][0])
    var b = root.fmtTimeOfDay(pick[pick.length - 1][0])
    return (a === "" || b === "") ? "" : a + "–" + b
  }

  // Body Battery has something to show even when today's curve is missing:
  // any one of current / low / high being a real number is a card's worth.
  readonly property bool hasBatteryValues:
    root.num(root.bodyBattery ? root.bodyBattery.current : null) !== null
    || root.num(root.bodyBattery ? root.bodyBattery.low : null) !== null
    || root.num(root.bodyBattery ? root.bodyBattery.high : null) !== null

  // ---- The empty morning
  //
  // Before the watch has synced, the helper answers ok:true with every one of
  // today's figures null while the cached week behind them is intact. Each
  // card hides on its own missing value, so that payload emptied the whole
  // Garmin section — seven days of real data on disk and nothing on screen.
  //
  // When the payload has exactly that shape — nothing for today, something for
  // the week — the enabled cards render in empty form instead: "—" where the
  // figure goes, meters and delta arrows suppressed, and the seven-day strips
  // (which are history-fed and were always correct) still drawn. Every one of
  // those allowances is gated on `emptyToday`, so a payload with any today
  // value in it renders exactly as it did before.
  //
  // Weekly and historical metrics are deliberately not part of this test:
  // intensity minutes is a week-to-date total and the last activity can be
  // weeks old, so either can be present on a morning with no today data at
  // all. Only figures that describe today count as today data.
  readonly property bool hasTodayValues:
    root.hasBatteryValues
    || root.hasCurve
    || root.num(root.sleepInfo ? root.sleepInfo.score : null) !== null
    || root.num(root.sleepInfo ? root.sleepInfo.durationMin : null) !== null
    || root.hasSteps
    || root.num(root.payload ? root.payload.restingHr : null) !== null
    || root.num(root.readinessInfo ? root.readinessInfo.score : null) !== null
    || root.titleCase(root.readinessInfo ? root.readinessInfo.level : "") !== ""
    || root.num(root.hrvInfo ? root.hrvInfo.lastNightAvg : null) !== null
    || root.titleCase(root.hrvInfo ? root.hrvInfo.status : "") !== ""
    || root.num(root.floorsInfo ? root.floorsInfo.count : null) !== null
    || root.num(root.caloriesInfo ? root.caloriesInfo.total : null) !== null
    || root.num(root.caloriesInfo ? root.caloriesInfo.active : null) !== null

  readonly property bool emptyToday:
    root.showRows && !root.hasTodayValues && root.historySorted.length > 0

  // ---- History-derived views
  //
  // Entries are keyed by date so a gap in the week stays a gap: the strip is
  // built by walking seven calendar days back from the newest entry, not by
  // taking the last seven rows of a list that may be missing days.
  readonly property var historyByDate: {
    var map = {}
    for (var i = 0; i < root.historySorted.length; i++) {
      var e = root.historySorted[i]
      map[String(e.date)] = e
    }
    return map
  }

  // Dated entries, oldest first, seven at most — the shape the delta
  // comparison wants. The cut is here rather than on the raw list because
  // "newest" only means anything once the entries are in date order.
  readonly property var historySorted: {
    var out = []
    for (var i = 0; i < root.history.length; i++) {
      var e = root.history[i]
      if (e && String(e.date || "") !== "") out.push(e)
    }
    out.sort(function (a, b) { return String(a.date) < String(b.date) ? -1 : 1 })
    return out.length > root.historyDays
      ? out.slice(out.length - root.historyDays) : out
  }

  readonly property string newestHistoryDate:
    root.historySorted.length > 0 ? String(root.historySorted[root.historySorted.length - 1].date) : ""

  // Seven slots ending on the newest entry we have. `fixedMax` pins the scale
  // where the metric has a natural ceiling (a sleep score is out of 100); zero
  // means "scale to the week", which is what a step count wants.
  //
  // Labels are weekdays, never "today": when the payload is stale the newest
  // entry may be yesterday's, and the footer is the one place that says how
  // old the data is.
  //
  // `opts.goal` names a per-day field (a step goal Garmin moves every day) to
  // scale each bar against its own target instead of one week-wide max;
  // `opts.fmt` formats the value for the hover tooltip. Both optional.
  function stripFor(field, fixedMax, opts) {
    if (root.newestHistoryDate === "") return []
    var end = root.parseDay(root.newestHistoryDate)
    if (!end) return []
    opts = opts || {}

    var slots = []
    var max = Number(fixedMax) > 0 ? Number(fixedMax) : 0
    for (var back = 6; back >= 0; back--) {
      var day = new Date(end.getFullYear(), end.getMonth(), end.getDate() - back)
      var key = root.dayKey(day)
      var entry = root.historyByDate[key]
      var value = entry ? root.historyValue(entry, field) : null
      var goal = entry && opts.goal ? root.historyValue(entry, opts.goal) : null
      if (value !== null && Number(fixedMax) <= 0 && !(goal !== null && goal > 0) && value > max) max = value
      var shown = value === null ? "—" : (typeof opts.fmt === "function" ? String(opts.fmt(value)) : root.fmtNumber(value))
      slots.push({
        "label": root.weekdayNames[day.getDay()],
        "date": key,
        "value": value,
        "goal": goal,
        "present": value !== null,
        "frac": 0,
        "tip": root.weekdayNames[day.getDay()] + " " + root.fmtDay(key) + " · " + shown
      })
    }

    for (var i = 0; i < slots.length; i++) {
      var s = slots[i]
      var scale = (s.goal !== null && s.goal > 0) ? s.goal : max
      s.frac = (s.present && scale > 0) ? Math.max(0, Math.min(1, s.value / scale)) : 0
    }
    return slots
  }

  // One history value, by its 0.4 name. Older cached rows (a stale last.json
  // written before the upgrade) still carry `bodyBatteryHigh`; `calTotal` is
  // not stored at all but is the figure the calories card shows.
  function historyValue(entry, field) {
    if (!entry) return null
    if (field === "calTotal") {
      var a = root.num(entry.calActive), r = root.num(entry.calResting)
      return (a === null || r === null) ? null : a + r
    }
    var v = root.num(entry[field])
    if (v === null && field === "bbHigh") v = root.num(entry.bodyBatteryHigh)
    return v
  }

  // Change against the previous day we have a reading for. Only the two most
  // recent entries are compared, and only if they are within two days of each
  // other — an arrow against a reading from last week is not a trend.
  //
  // Colour marks improvement only. A slightly shorter walk is not an alarm,
  // and painting it urgent would make the panel cry wolf every evening.
  function deltaFor(field, lowerIsBetter) {
    var dated = []
    for (var i = 0; i < root.historySorted.length; i++) {
      var v = root.historyValue(root.historySorted[i], field)
      if (v !== null) dated.push({ "date": String(root.historySorted[i].date), "value": v })
    }
    if (dated.length < 2) return { "glyph": "", "tone": "" }

    var latest = dated[dated.length - 1]
    var prev = dated[dated.length - 2]
    var a = root.parseDay(prev.date)
    var b = root.parseDay(latest.date)
    if (!a || !b) return { "glyph": "", "tone": "" }
    var gapDays = Math.round((b.getTime() - a.getTime()) / 86400000)
    if (gapDays < 1 || gapDays > 2) return { "glyph": "", "tone": "" }

    if (latest.value === prev.value) return { "glyph": "→", "tone": "" }
    var rose = latest.value > prev.value
    var better = lowerIsBetter ? !rose : rose
    return { "glyph": rose ? "↗" : "↘", "tone": better ? "accent" : "" }
  }

  // ---- Threshold bands (the same ones the chip colours by)
  function batteryTone(v) {
    if (v === null) return ""
    if (v >= 60) return "accent"
    if (v < 30) return "urgent"
    return ""
  }

  function readinessTone(v) {
    if (v === null) return ""
    if (v >= 75) return "accent"
    if (v < 35) return "urgent"
    return ""
  }

  function hrvTone(status) {
    var s = String(status || "").toUpperCase()
    if (s === "BALANCED") return "accent"
    if (s === "UNBALANCED" || s === "LOW" || s === "POOR") return "urgent"
    return ""
  }

  readonly property string batteryValue: root.fmtNumber(root.bodyBattery ? root.bodyBattery.current : null)
  readonly property string batteryMeta: {
    if (!root.bodyBattery) return ""
    var lo = root.bodyBattery.low
    var hi = root.bodyBattery.high
    if (lo === null || lo === undefined || hi === null || hi === undefined) return ""
    return "day " + root.fmtNumber(lo) + "–" + root.fmtNumber(hi)
  }

  readonly property string sleepValue: {
    if (!root.sleepInfo) return "—"
    var score = root.fmtNumber(root.sleepInfo.score)
    var dur = root.fmtDuration(root.sleepInfo.durationMin)
    if (score === "—" && dur === "—") return "—"
    return score + " · " + dur
  }

  readonly property real stepsGoal: {
    if (root.stepsInfo && root.stepsInfo.goal !== null && root.stepsInfo.goal !== undefined) {
      var g = Number(root.stepsInfo.goal)
      if (isFinite(g) && g > 0) return g
    }
    var fallback = Number(root.setting("stepsGoalFallback", 10000))
    return isFinite(fallback) && fallback > 0 ? fallback : 10000
  }
  readonly property var stepsCount: root.stepsInfo && root.stepsInfo.count !== null && root.stepsInfo.count !== undefined
    ? Number(root.stepsInfo.count) : null
  readonly property bool hasSteps: root.stepsCount !== null && isFinite(root.stepsCount)
  readonly property real stepsProgress:
    !root.hasSteps || root.stepsGoal <= 0 ? 0 : Math.max(0, Math.min(1, root.stepsCount / root.stepsGoal))

  readonly property string restingHrValue: {
    var v = root.fmtNumber(root.payload ? root.payload.restingHr : null)
    return v === "—" ? "—" : v + " bpm"
  }

  readonly property string asOfText: {
    // Only rows that are actually on screen get a timestamp. A dead login can
    // still have this morning's payload sitting in memory, and "as of 14:32"
    // under a "not signed in" panel claims a freshness the panel is otherwise
    // refusing to show.
    if (!root.showRows) return ""
    var clock = root.fmtClock(root.payload ? root.payload.asOf : "")
    if (clock === "") return root.showStale ? "stale" : ""
    return "as of " + clock + (root.showStale ? " · stale" : "")
  }

  // ---- Which cards, in which order
  //
  // The setting is a comma-separated string rather than a list because that is
  // what the shell's settings schema can round-trip. Unknown tokens are
  // dropped instead of erroring — a typo should cost you one card, not the
  // whole panel — and a string that survives none of that falls back to the
  // default set rather than leaving the body empty.
  readonly property var knownMetrics: [
    "curve", "battery", "sleep", "steps", "readiness",
    "rhr", "hrv", "intensity", "floors", "calories", "activity", "custom"
  ]
  readonly property string defaultMetrics: "curve,sleep,steps,readiness,rhr"

  // Names for the edit list. The cards themselves title from `cardFor`, which
  // has nothing to say about a metric this account has no data for — the edit
  // list has to name every token whether or not it can render today.
  readonly property var metricLabels: ({
    "curve": "Day curve", "battery": "Body Battery", "sleep": "Sleep",
    "steps": "Steps", "readiness": "Training readiness", "rhr": "Resting HR",
    "hrv": "HRV", "intensity": "Intensity minutes", "floors": "Floors",
    "calories": "Calories", "activity": "Last activity",
    "custom": "Custom command"
  })

  // The custom row is the one edit-list entry whose meaning the user chose
  // themselves, so it names their card once the command has actually produced
  // one — "Custom: Disk" reads as a thing they configured, where "Custom
  // command" reads as a slot they never filled. Before the first payload (or
  // when the command is unset or failing) there is no title to show and the
  // plain label is the honest answer.
  function editLabel(token) {
    if (token === "custom") {
      var title = root.customCard ? String(root.customCard.title || "") : ""
      return title !== "" ? "Custom: " + title : "Custom command"
    }
    return root.metricLabels[token] || token
  }

  // Precedence: prefs.json (the panel's own edit mode) > the shell.json
  // setting > the built-in default. The pref is the most recent thing the user
  // chose by hand, so it wins; deleting prefs.json hands control straight back
  // to shell.json.
  readonly property string effectivePanelMetrics: {
    var pref = root.service ? String(root.service.prefPanelMetrics || "") : ""
    return pref !== "" ? pref : String(root.setting("panelMetrics", root.defaultMetrics))
  }

  readonly property var metricTokens: {
    var parsed = root.parseMetrics(root.effectivePanelMetrics)
    return parsed.length > 0 ? parsed : root.parseMetrics(root.defaultMetrics)
  }

  // The tokens that will actually put a card on screen. Counted with
  // dense=false so this never reads denseLayout, which is derived from it —
  // `show` is independent of density, so the count is exact either way.
  readonly property var visibleTokens: {
    var out = []
    for (var i = 0; i < root.metricTokens.length; i++) {
      if (root.cardFor(root.metricTokens[i], false).show === true) out.push(root.metricTokens[i])
    }
    return out
  }

  // Past six cards the panel is taller than the numbers are worth, and there
  // is no scrolling here by design. Density is what gets cut: the seven-day
  // strips are the first thing to go, since the figure above each one is the
  // part people actually came for.
  //
  // Counted over the cards that are on screen, not the tokens asked for: a
  // long list of metrics this account has no data for produced a cramped,
  // strip-less layout for the three cards that did render.
  readonly property bool denseLayout: root.visibleTokens.length > 6

  function parseMetrics(raw) {
    var parts = String(raw || "").split(",")
    var out = []
    for (var i = 0; i < parts.length; i++) {
      var token = parts[i].replace(/^\s+|\s+$/g, "").toLowerCase()
      if (token === "") continue
      if (root.knownMetrics.indexOf(token) === -1) continue
      if (out.indexOf(token) !== -1) continue
      out.push(token)
    }
    return out
  }

  // The body laid out as rows of tokens. A card whose metric is missing never
  // enters the layout at all, so a hidden card leaves no hole and no gap.
  //
  // In dense mode the metric cards pair up two to a row. There is no scrolling
  // in this panel by design, and eleven full-width cards run off the bottom of
  // a 1080p screen — a second column buys back the height that the strips
  // alone could not.
  readonly property var cardRows: {
    var rows = []
    var pending = ""
    for (var i = 0; i < root.visibleTokens.length; i++) {
      var token = root.visibleTokens[i]
      // Only `kind` is needed here, and it does not depend on density.
      var card = root.cardFor(token, false)

      // The curve is a chart, not a figure: it always gets the full width.
      if (card.kind === "curve") {
        if (pending !== "") { rows.push([pending]); pending = "" }
        rows.push([token])
        continue
      }
      if (!root.denseLayout) { rows.push([token]); continue }
      if (pending === "") pending = token
      else { rows.push([pending, token]); pending = "" }
    }
    if (pending !== "") rows.push([pending])
    return rows
  }

  // A payload can be `ok` and still carry nothing we were asked to show — a
  // watch left on the charger all day, or a metric set nobody's account has.
  // The body says so rather than leaving a hero floating above a separator.
  readonly property int visibleCardCount: root.visibleTokens.length

  // The custom card is the one card in the list that does not come from Garmin,
  // so it is the one card that still has something to say when the Garmin rows
  // are gated off. `showRows` false plus a card that parsed cleanly is exactly
  // that case; when the rows are on it renders in its normal place instead.
  readonly property bool showCustomAlone:
    !root.showRows && root.customCard !== null
    && root.metricTokens.indexOf("custom") !== -1

  readonly property var customAloneCard: root.cardFor("custom", true)

  // ---- Card descriptors
  //
  // One function, one card, every string already formatted: the delegate below
  // only decides where things sit, never what they say. `show: false` means
  // the payload had nothing for this metric, and the card disappears rather
  // than sitting there full of em dashes.
  //
  // `denseOverride` exists so the visible-card count can be taken without
  // reading root.denseLayout — which is itself derived from that count, and
  // would be a binding loop. Nothing about `show` depends on density, so
  // counting with dense=false is exact.
  function cardFor(token, denseOverride) {
    var dense = denseOverride === undefined ? root.denseLayout : denseOverride === true
    switch (token) {
    case "curve": {
      // No curve today does not mean no Body Battery: the figures can arrive
      // without the intraday series behind them. Rather than dropping the
      // panel's headline metric entirely, the slot falls back to the plain
      // battery card — unless the user's own list already asks for one, in
      // which case it would be the same card twice.
      //
      // On an empty morning the same fallback runs with no figure behind it:
      // the battery card comes back as "—" over its seven-day strip, which is
      // more use in this slot than a hole where the panel's headline was.
      if (!root.hasCurve) {
        if ((root.hasBatteryValues || root.emptyToday) && root.metricTokens.indexOf("battery") === -1)
          return root.cardFor("battery", dense)
        return { "kind": "metric", "show": false }
      }
      // The header names whichever line is actually drawn. Garmin can return
      // a stress day with no Body Battery at all, and a "Body Battery 71"
      // header over a lone stress curve claims the wrong line.
      var bb = root.num(root.bodyBattery ? root.bodyBattery.current : null)
      return {
        "kind": "curve",
        "show": true,
        "title": root.bbDrawn ? "Body Battery" : "Stress",
        "icon": root.bbDrawn ? "󱐋" : "󰐰",
        "value": root.bbDrawn ? root.batteryValue : root.fmtNumber(root.lastStress),
        "tone": root.bbDrawn ? root.batteryTone(bb) : "",
        "caption": root.curveSpan
      }
    }
    case "battery": {
      var current = root.num(root.bodyBattery ? root.bodyBattery.current : null)
      return {
        "kind": "metric",
        // `bodyBattery !== null` was always true — the helper emits the dict
        // whether or not it found anything to put in it.
        "show": root.hasBatteryValues || root.emptyToday,
        "icon": "󱐋",
        "title": "Body Battery",
        "value": root.batteryValue,
        "caption": root.batteryMeta,
        "tone": root.batteryTone(current),
        "strip": dense ? [] : root.stripFor("bbHigh", 100)
      }
    }
    case "sleep": {
      var score = root.num(root.sleepInfo ? root.sleepInfo.score : null)
      var duration = root.num(root.sleepInfo ? root.sleepInfo.durationMin : null)
      var d = root.deltaFor("sleepScore", false)
      return {
        "kind": "metric",
        "show": score !== null || duration !== null || root.emptyToday,
        "icon": "󰒲",
        "title": "Sleep",
        "value": root.sleepValue,
        // An arrow on an empty card would be comparing two history entries
        // neither of which is the figure the card is showing.
        "delta": root.emptyToday ? "" : d.glyph,
        "deltaTone": root.emptyToday ? "" : d.tone,
        "strip": dense ? [] : root.stripFor("sleepScore", 100)
      }
    }
    case "steps": {
      var d2 = root.deltaFor("steps", false)
      return {
        "kind": "metric",
        "show": root.hasSteps || root.emptyToday,
        "icon": "󰖃",
        "title": "Steps",
        "value": root.fmtSteps(root.stepsCount),
        "caption": "goal " + root.fmtSteps(root.stepsGoal),
        // A zero-length meter under an em dash reads as "you have walked
        // nothing today", which is a claim the payload has not made.
        "meterPercent": root.emptyToday ? -1 : root.stepsProgress * 100,
        "delta": root.emptyToday ? "" : d2.glyph,
        "deltaTone": root.emptyToday ? "" : d2.tone,
        "strip": dense ? [] : root.stripFor("steps", Math.max(root.stepsGoal, 0),
                                             { "goal": "stepGoal", "fmt": root.fmtSteps })
      }
    }
    case "readiness": {
      var rs = root.num(root.readinessInfo ? root.readinessInfo.score : null)
      var level = root.titleCase(root.readinessInfo ? root.readinessInfo.level : "")
      return {
        "kind": "metric",
        "show": rs !== null || level !== "" || root.emptyToday,
        "icon": "󰓅",
        "title": "Training readiness",
        "value": root.fmtNumber(rs),
        "caption": level,
        "tone": root.readinessTone(rs),
        "strip": dense ? [] : root.stripFor("readiness", 100)
      }
    }
    case "rhr": {
      var d3 = root.deltaFor("restingHr", true)
      return {
        "kind": "metric",
        "show": root.num(root.payload ? root.payload.restingHr : null) !== null || root.emptyToday,
        "icon": "󰗶",
        "title": "Resting HR",
        "value": root.restingHrValue,
        "delta": root.emptyToday ? "" : d3.glyph,
        "deltaTone": root.emptyToday ? "" : d3.tone,
        "strip": dense ? [] : root.stripFor("restingHr", 0,
                                             { "fmt": function (v) { return root.fmtNumber(v) + " bpm" } })
      }
    }
    case "hrv": {
      var last = root.num(root.hrvInfo ? root.hrvInfo.lastNightAvg : null)
      var weekly = root.num(root.hrvInfo ? root.hrvInfo.weeklyAvg : null)
      var status = root.titleCase(root.hrvInfo ? root.hrvInfo.status : "")
      var parts = []
      if (status !== "") parts.push(status)
      if (weekly !== null) parts.push("7-day avg " + root.fmtNumber(weekly) + " ms")
      return {
        "kind": "metric",
        "show": last !== null || status !== "" || root.emptyToday,
        "icon": "󰐰",
        "title": "HRV",
        "value": last === null ? "—" : root.fmtNumber(last) + " ms",
        "caption": parts.join(" · "),
        "tone": root.hrvTone(root.hrvInfo ? root.hrvInfo.status : ""),
        "strip": dense ? [] : root.stripFor("hrvNight", 0,
                                             { "fmt": function (v) { return root.fmtNumber(v) + " ms" } })
      }
    }
    case "intensity": {
      var weeklyMin = root.num(root.intensityInfo ? root.intensityInfo.weekly : null)
      var goal = root.num(root.intensityInfo ? root.intensityInfo.goal : null)
      return {
        "kind": "metric",
        "show": weeklyMin !== null,
        "icon": "󰑮",
        "title": "Intensity minutes",
        "value": root.fmtNumber(weeklyMin),
        "caption": goal === null ? "this week" : "weekly goal " + root.fmtNumber(goal),
        "meterPercent": (goal === null || goal <= 0 || weeklyMin === null)
          ? -1 : Math.min(100, weeklyMin / goal * 100)
      }
    }
    case "floors": {
      var count = root.num(root.floorsInfo ? root.floorsInfo.count : null)
      var fgoal = root.num(root.floorsInfo ? root.floorsInfo.goal : null)
      return {
        "kind": "metric",
        "show": count !== null || root.emptyToday,
        "icon": "󱊽",  // nf-md-stairs_up, U+F12BD
        "title": "Floors",
        "value": root.fmtNumber(count),
        "caption": fgoal === null ? "" : "goal " + root.fmtNumber(fgoal),
        "meterPercent": (fgoal === null || fgoal <= 0 || count === null)
          ? -1 : Math.min(100, count / fgoal * 100)
      }
    }
    case "calories": {
      var total = root.num(root.caloriesInfo ? root.caloriesInfo.total : null)
      var active = root.num(root.caloriesInfo ? root.caloriesInfo.active : null)
      return {
        "kind": "metric",
        "show": total !== null || active !== null || root.emptyToday,
        "icon": "󰈸",
        "title": "Calories",
        "value": total === null ? "—" : root.fmtSteps(total) + " kcal",
        "caption": active === null ? "" : root.fmtSteps(active) + " active",
        "strip": dense ? [] : root.stripFor("calTotal", 0,
                                             { "fmt": function (v) { return root.fmtSteps(v) + " kcal" } })
      }
    }
    case "activity": {
      // The date is not decoration. The last activity can be weeks old, and a
      // duration with no date on it reads as "you did this today".
      var act = root.activityInfo
      var type = root.titleCase(act ? act.type : "")
      var mins = root.num(act ? act.durationMin : null)
      var km = root.num(act ? act.distanceKm : null)
      var bpm = root.num(act ? act.avgHr : null)
      var kcal = root.num(act ? act.kcal : null)
      var when = root.activityDate(act)
      // Date first: the caption elides from the right, and on a half-width
      // dense card the tail is what goes. Heart rate and calories are
      // dropped there outright — the list page one click away has them.
      var meta = [when === "" ? "date unknown" : when]
      if (mins !== null) meta.push(root.fmtDuration(mins))
      if (km !== null) meta.push(root.fmtKm(km))
      if (!dense && bpm !== null) meta.push(root.fmtNumber(bpm) + " bpm")
      if (!dense && kcal !== null) meta.push(root.fmtSteps(kcal) + " kcal")
      // The figure slot does not elide (MetricCard sizes it to its text), so
      // a 48-character name would push the title off the card. The list page
      // and its tooltip carry the full name.
      var shown = act ? root.activityTitle(act) : ""
      var fit = dense ? 12 : 24
      if (shown.length > fit) shown = shown.slice(0, fit - 1) + "…"
      return {
        "kind": "metric",
        "show": act !== null && (type !== "" || mins !== null || km !== null || root.activityTitle(act) !== "Activity"),
        "icon": root.typeGlyph(act ? act.type : ""),
        // Two cards to a row leaves no space for "Last activity" — it elides
        // to "Last a…", which reads like a rendering bug rather than a title.
        "title": dense ? "Activity" : "Last activity",
        "value": shown === "" ? "—" : shown,
        "caption": meta.join(" · ")
      }
    }
    case "custom": {
      // Nothing here is trusted enough to be shown as-is except what the
      // Service already cleaned: it capped the lengths, stripped control
      // characters and whitelisted the tone. A card that failed any of that
      // arrives as null and simply does not exist.
      var c = root.customCard
      return {
        "kind": "metric",
        "show": c !== null,
        "icon": "󰆍",  // nf-md-console, U+F018D
        "title": c ? String(c.title || "") : "",
        "value": c ? String(c.value || "—") : "—",
        "caption": c ? String(c.caption || "") : "",
        "tone": c ? String(c.tone || "") : "",
        "meterPercent": c && c.meterPercent !== undefined ? c.meterPercent : -1
      }
    }
    }
    return { "kind": "metric", "show": false }
  }

  // ---- Edit mode
  //
  // The panel is where people look at these cards, so it is also where they
  // should be able to rearrange them — settings for a widget you are staring
  // at should not live in a JSON file in another window. The edit view replaces
  // the card list rather than sitting beside it: the panel has no scrolling by
  // design, and twelve rows plus twelve cards would not fit on a 1080p screen.
  //
  // Everything written here goes through the helper's `prefs set`, which
  // validates and owns the file. QML never touches disk.
  property bool editMode: false

  // ---- Detail view: one metric, the last seven days
  //
  // Replaces the card deck the way edit mode does, rather than expanding a
  // card in place: with eleven cards the deck already fills the screen, and
  // a full-width page has room for a chart that is actually readable.
  property string detailToken: ""
  readonly property bool detailMode: root.detailToken !== ""
  readonly property var expandableTokens: ["battery", "sleep", "steps", "readiness", "rhr", "hrv", "calories", "curve", "activity"]
  function expandable(token) { return root.expandableTokens.indexOf(String(token)) !== -1 }

  function openDetail(token) {
    token = String(token || "")
    if (!root.expandable(token)) return
    // The curve slot draws the battery card when there is no curve; the
    // detail follows what is on screen, not the token.
    if (token === "curve" && !root.hasCurve) token = "battery"
    // A detail page replaces the deck, and edit mode replaces it too — an IPC
    // `detail` arriving mid-edit must not leave both flags up, with the edit
    // list's key handling still live under a page that is not showing it.
    root.editMode = false
    root.activityCursor = 0
    root.detailToken = token
  }
  function closeDetail() { root.detailToken = "" }
  // A reopened panel starts on the deck, not on whatever was last inspected.
  onOpenedChanged: if (!root.opened) root.detailToken = ""

  // ---- Activity list page
  //
  // The activity card's page is a list, not a week chart, so it branches off
  // the shared detail chrome in a few places: the hero meta, the header
  // figure and the footer hint below all check `activityPage`.
  readonly property bool activityPage: root.detailToken === "activity"
  property int activityCursor: 0

  // Keyboard model: one integer, as in edit mode. Clamped here so a refresh
  // that shortens the list never leaves the cursor on a row that is gone.
  function activityMove(dy) {
    var n = root.activityListRows.length
    if (n === 0) return
    root.activityCursor = Math.max(0, Math.min(n - 1, root.activityCursor + (dy > 0 ? 1 : -1)))
  }

  // Rows fully formatted here, like every other card and page: ActivityList
  // only places them.
  readonly property var activityListRows: {
    var out = []
    for (var i = 0; i < root.activities.length; i++) {
      var a = root.activities[i]
      var mins = root.num(a.durationMin), bpm = root.num(a.avgHr), kcal = root.num(a.kcal)
      var title = root.activityTitle(a)
      var type = root.titleCase(a.type)
      var day = root.activityDay(a)
      var clock = root.activityClock(a)
      var row = {
        "glyph": root.typeGlyph(a.type),
        "title": title,
        "dateText": root.activityDate(a),
        // Bare numbers: the unit sits once in the column header rather
        // than ten times down the column, which is what buys the name room.
        "durationText": mins === null ? "" : root.fmtDuration(mins),
        "distanceText": root.num(a.distanceKm) === null ? "" : root.num(a.distanceKm).toFixed(2),
        "hrText": bpm === null ? "" : root.fmtNumber(bpm),
        "kcalText": kcal === null ? "" : root.fmtSteps(kcal)
      }
      // The tooltip is the whole line, unelided: the one place a long name
      // or a clipped column can be read in full.
      var tip = [title]
      if (type !== "" && type !== title) tip.push(type)
      if (day) tip.push(root.weekdayNames[day.getDay()] + " " + row.dateText + (clock === "" ? "" : " " + clock))
      if (row.durationText !== "") tip.push(row.durationText)
      if (row.distanceText !== "") tip.push(row.distanceText + " km")
      if (row.hrText !== "") tip.push(row.hrText + " bpm")
      if (row.kcalText !== "") tip.push(row.kcalText + " kcal")
      row.tip = tip.join(" · ")
      out.push(row)
    }
    return out
  }

  // "this week 4 · 3h12m · 28.6 km" — but only when the list provably
  // covers the whole week, i.e. its oldest row is older than six days ago.
  // Otherwise a busy week could have more activities than the list holds,
  // and the honest summary is just how many rows these are.
  readonly property string activityWeekSummary: {
    var rows = root.activities
    if (rows.length === 0) return ""
    var now = new Date()
    var from = new Date(now.getFullYear(), now.getMonth(), now.getDate() - 6)
    var oldest = root.activityDay(rows[rows.length - 1])
    if (!oldest || oldest.getTime() >= from.getTime())
      return rows.length + " most recent"
    var n = 0, mins = 0, km = 0
    for (var i = 0; i < rows.length; i++) {
      var d = root.activityDay(rows[i])
      if (!d || d.getTime() < from.getTime()) continue
      n++
      mins += root.minutesOr0(rows[i].durationMin)
      var k = root.num(rows[i].distanceKm)
      if (k !== null) km += k
    }
    if (n === 0) return "none this week"
    var parts = ["this week " + n, root.fmtDuration(mins)]
    if (km > 0) parts.push(km.toFixed(1) + " km")
    return parts.join(" · ")
  }

  readonly property string activityListHeading: {
    var n = root.activityListRows.length
    var h = n === 1 ? "Last activity" : "Last " + n + " activities"
    return root.isCarried("activity") ? h + " · stale" : h
  }

  // Seven calendar days ending on the newest history entry, each with its
  // history row (or null). The same walk stripFor does, kept separate so the
  // detail page can carry richer per-day objects than a strip slot.
  function weekDays() {
    if (root.newestHistoryDate === "") return []
    var end = root.parseDay(root.newestHistoryDate)
    if (!end) return []
    var out = []
    for (var back = 6; back >= 0; back--) {
      var day = new Date(end.getFullYear(), end.getMonth(), end.getDate() - back)
      var key = root.dayKey(day)
      out.push({ "date": key, "label": root.weekdayNames[day.getDay()],
                 "dayLabel": root.fmtDay(key), "entry": root.historyByDate[key] || null })
    }
    return out
  }

  // `build(entry)` returns { value, lo?, parts?, goal?, valueText, tipText? }
  // or null for a day with nothing to show.
  function weekSlots(build) {
    var days = root.weekDays()
    var out = []
    for (var i = 0; i < days.length; i++) {
      var d = days[i]
      var s = d.entry ? build(d.entry) : null
      var present = !!s && root.num(s.value) !== null
      var when = d.label + " " + d.dayLabel
      out.push({
        "label": d.label, "dayLabel": d.dayLabel, "present": present,
        "value": present ? s.value : null,
        "lo": present && s.lo !== undefined ? s.lo : null,
        "parts": present && s.parts ? s.parts : [],
        "goal": present && s.goal !== undefined ? s.goal : null,
        "valueText": present ? String(s.valueText) : "",
        "tip": present ? when + " · " + String(s.tipText || s.valueText) : when + " · no data"
      })
    }
    return out
  }

  function weekStats(slots, pick) {
    var vals = []
    for (var i = 0; i < slots.length; i++) {
      if (!slots[i].present) continue
      var v = root.num(pick ? pick(slots[i]) : slots[i].value)
      if (v !== null) vals.push(v)
    }
    if (vals.length === 0) return null
    var sum = 0, min = Infinity, max = -Infinity
    for (var j = 0; j < vals.length; j++) {
      sum += vals[j]
      if (vals[j] < min) min = vals[j]
      if (vals[j] > max) max = vals[j]
    }
    return { "n": vals.length, "sum": sum, "min": min, "max": max, "avg": sum / vals.length }
  }

  function minutesOr0(v) { var n = root.num(v); return n === null ? 0 : n }

  readonly property var detail: root.detailFor(root.detailToken)

  function detailFor(token) {
    // `headline` overrides the card's own figure at the top of the page;
    // null means "show what the card shows".
    var empty = { "title": "", "icon": "", "variant": "bars", "days": [], "fixedMax": 0,
                  "axisMin": 0, "band": null, "partColors": [], "legend": [], "summary": "",
                  "headline": null }
    var fg = root.foreground, ac = root.accentColor
    var slots, st
    switch (token) {
    case "battery": {
      slots = root.weekSlots(function (e) {
        var hi = root.num(e.bbHigh), lo = root.num(e.bbLow)
        if (hi === null) return null
        var tip = root.fmtNumber(hi) + " high" + (lo === null ? "" : " · " + root.fmtNumber(lo) + " low")
        var c = root.num(e.bbCharged), dr = root.num(e.bbDrained)
        // Print only the side that actually exists — a "+0" or "−0" on a day
        // that just never reported the other half reads as "nothing charged"
        // rather than "no data", which is a different claim than the source
        // is making.
        if (c !== null && dr !== null) tip += " · +" + root.fmtNumber(c) + " / −" + root.fmtNumber(dr)
        else if (c !== null) tip += " · +" + root.fmtNumber(c)
        else if (dr !== null) tip += " · −" + root.fmtNumber(dr)
        // `lo` stays null rather than 0 when the source has no low reading —
        // the range draw and the avg-low stat both skip a null rather than
        // treating a missing low as "drained to zero."
        return { "value": hi, "lo": lo, "valueText": root.fmtNumber(hi), "tipText": tip }
      })
      st = root.weekStats(slots)
      var lo = root.weekStats(slots, function (s) { return s.lo })
      return Object.assign({}, empty, {
        "title": "Body Battery", "icon": "󱐋", "variant": "range", "days": slots, "fixedMax": 100,
        "summary": st ? "avg high " + root.fmtNumber(Math.round(st.avg)) + (lo ? " · avg low " + root.fmtNumber(Math.round(lo.avg)) : "") : ""
      })
    }
    case "sleep": {
      slots = root.weekSlots(function (e) {
        var total = root.num(e.sleepMin), score = root.num(e.sleepScore)
        if (total === null && score === null) return null
        var stages = [root.num(e.deepMin), root.num(e.lightMin), root.num(e.remMin), root.num(e.awakeMin)]
        var hasStages = stages.some(function (v) { return v !== null })
        var parts = hasStages ? stages.map(function (v) { return v === null ? 0 : v }) : [total === null ? 0 : total]
        // A score with no duration and no stages keeps its slot (the score is
        // real and stays readable) on a flat bar; the duration average below
        // skips it, so it can't drag the week toward a zero-length night.
        var height = hasStages ? parts.reduce(function (a, b) { return a + b }, 0) : (total === null ? 0 : total)
        var tip = (score === null ? "" : "score " + root.fmtNumber(score) + " · ") + root.fmtDuration(total === null ? height : total)
        if (hasStages) tip += " · deep " + root.fmtDuration(parts[0]) + " · light " + root.fmtDuration(parts[1])
          + " · REM " + root.fmtDuration(parts[2]) + " · awake " + root.fmtDuration(parts[3])
        return { "value": height, "parts": parts,
                 "valueText": score === null ? root.fmtDuration(total) : root.fmtNumber(score), "tipText": tip }
      })
      st = root.weekStats(slots, function (s) { return s.value > 0 ? s.value : null })
      var sc = root.weekStats(slots, function (s) { return /^\d+$/.test(s.valueText) ? Number(s.valueText) : null })
      return Object.assign({}, empty, {
        "title": "Sleep", "icon": "󰒲", "variant": "stacked", "days": slots,
        "partColors": [ac, Util.alpha(ac, 0.55), Util.alpha(ac, 0.3), Util.alpha(fg, 0.25)],
        "legend": [{ "label": "Deep", "color": ac }, { "label": "Light", "color": Util.alpha(ac, 0.55) },
                   { "label": "REM", "color": Util.alpha(ac, 0.3) }, { "label": "Awake", "color": Util.alpha(fg, 0.25) }],
        "summary": st ? "avg " + root.fmtDuration(Math.round(st.avg)) + (sc ? " · avg score " + root.fmtNumber(Math.round(sc.avg)) : "") : ""
      })
    }
    case "steps": {
      slots = root.weekSlots(function (e) {
        var n = root.num(e.steps)
        if (n === null) return null
        var g = root.num(e.stepGoal)
        return { "value": n, "goal": g, "valueText": root.fmtSteps(n),
                 "tipText": root.fmtSteps(n) + (g === null ? "" : " · goal " + root.fmtSteps(g)) }
      })
      st = root.weekStats(slots)
      var met = 0
      for (var i = 0; i < slots.length; i++)
        if (slots[i].present && slots[i].goal !== null && slots[i].value >= slots[i].goal) met++
      return Object.assign({}, empty, {
        "title": "Steps", "icon": "󰖃", "variant": "bars", "days": slots,
        "summary": st ? "avg " + root.fmtSteps(Math.round(st.avg)) + " · total " + root.fmtSteps(st.sum) + " · goal met " + met + "/" + st.n : ""
      })
    }
    case "readiness": {
      slots = root.weekSlots(function (e) {
        var n = root.num(e.readiness)
        return n === null ? null : { "value": n, "valueText": root.fmtNumber(n) }
      })
      st = root.weekStats(slots)
      return Object.assign({}, empty, {
        "title": "Training readiness", "icon": "󰓅", "variant": "bars", "days": slots, "fixedMax": 100,
        "summary": st ? "min " + root.fmtNumber(st.min) + " · avg " + root.fmtNumber(Math.round(st.avg)) + " · max " + root.fmtNumber(st.max) : ""
      })
    }
    case "rhr": {
      slots = root.weekSlots(function (e) {
        var n = root.num(e.restingHr)
        return n === null ? null : { "value": n, "valueText": root.fmtNumber(n), "tipText": root.fmtNumber(n) + " bpm" }
      })
      st = root.weekStats(slots)
      return Object.assign({}, empty, {
        "title": "Resting HR", "icon": "󰗶", "variant": "bars", "days": slots,
        // A resting heart rate lives in a ten-beat window; from zero every
        // bar is the same height. The axis starts a few beats under the
        // week's low so the shape is visible, and the labels carry the truth.
        "axisMin": st ? Math.max(0, st.min - 6) : 0,
        "summary": st ? "min " + root.fmtNumber(st.min) + " · avg " + root.fmtNumber(Math.round(st.avg)) + " · max " + root.fmtNumber(st.max) + " bpm" : ""
      })
    }
    case "hrv": {
      var band = null
      var days = root.weekDays()
      for (var k = days.length - 1; k >= 0; k--) {
        var en = days[k].entry
        if (en && root.num(en.hrvBalLow) !== null && root.num(en.hrvBalHigh) !== null) {
          band = { "lo": root.num(en.hrvBalLow), "hi": root.num(en.hrvBalHigh) }
          break
        }
      }
      slots = root.weekSlots(function (e) {
        var n = root.num(e.hrvNight)
        if (n === null) return null
        var w = root.num(e.hrvWeekly)
        return { "value": n, "valueText": root.fmtNumber(n),
                 "tipText": root.fmtNumber(n) + " ms" + (w === null ? "" : " · weekly avg " + root.fmtNumber(w)) }
      })
      st = root.weekStats(slots)
      var floor = st ? st.min : 0
      if (band && band.lo < floor) floor = band.lo
      return Object.assign({}, empty, {
        "title": "HRV", "icon": "󰐰", "variant": "bars", "days": slots, "band": band,
        "axisMin": Math.max(0, floor - 12),
        "summary": (st ? "avg " + root.fmtNumber(Math.round(st.avg)) + " ms" : "")
          + (band ? (st ? " · " : "") + "balanced " + root.fmtNumber(band.lo) + "–" + root.fmtNumber(band.hi) : "")
      })
    }
    case "calories": {
      slots = root.weekSlots(function (e) {
        var a = root.num(e.calActive), r = root.num(e.calResting)
        // Matches historyValue()'s "calTotal" rule above: a total is only
        // ever the sum of both halves, never one half plus an assumed zero
        // for the other — a resting-only day is not "0 active calories."
        if (a === null || r === null) return null
        var parts = [r, a]
        var total = parts[0] + parts[1]
        return { "value": total, "parts": parts, "valueText": root.fmtSteps(total),
                 "tipText": root.fmtSteps(total) + " kcal" + (a === null ? "" : " · " + root.fmtSteps(a) + " active") }
      })
      st = root.weekStats(slots)
      var act = root.weekStats(slots, function (s) { return s.parts.length > 1 ? s.parts[1] : null })
      return Object.assign({}, empty, {
        "title": "Calories", "icon": "󰈸", "variant": "stacked", "days": slots,
        "partColors": [Util.alpha(fg, 0.28), ac],
        "legend": [{ "label": "Resting", "color": Util.alpha(fg, 0.28) }, { "label": "Active", "color": ac }],
        "summary": st ? "avg " + root.fmtSteps(Math.round(st.avg)) + " kcal" + (act ? " · avg active " + root.fmtSteps(Math.round(act.avg)) : "") : ""
      })
    }
    case "curve": {
      slots = root.weekSlots(function (e) {
        var avg = root.num(e.stressAvg)
        // Kept as real nulls, not minutesOr0'd, so a bucket the day never
        // reported stays out of its own average below (weekStats skips a
        // null pick) and out of the tooltip — the stacked draw in
        // WeekView.qml treats a null part the same as 0 already (nothing to
        // stack), so "draws as zero height" needs no extra handling here.
        var rest = root.num(e.stressRestMin), low = root.num(e.stressLowMin)
        var med = root.num(e.stressMedMin), high = root.num(e.stressHighMin)
        var parts = [rest, low, med, high]
        var measured = root.minutesOr0(rest) + root.minutesOr0(low) + root.minutesOr0(med) + root.minutesOr0(high)
        if (avg === null && measured === 0) return null
        var tipParts = []
        if (rest !== null) tipParts.push("rest " + root.fmtDuration(rest))
        if (low !== null) tipParts.push("low " + root.fmtDuration(low))
        if (med !== null) tipParts.push("medium " + root.fmtDuration(med))
        if (high !== null) tipParts.push("high " + root.fmtDuration(high))
        return { "value": measured, "parts": parts,
                 "valueText": avg === null ? "—" : root.fmtNumber(avg),
                 "tipText": (avg === null ? "" : "avg " + root.fmtNumber(avg) + " · ") + tipParts.join(" · ") }
      })
      var av = root.weekStats(slots, function (s) { return s.valueText === "—" ? null : Number(s.valueText) })
      var hi = root.weekStats(slots, function (s) { return s.parts.length > 3 ? s.parts[3] : null })
      // The curve card's figure is Body Battery; this page is about stress.
      var todayStress = slots.length > 0 && slots[slots.length - 1].present ? slots[slots.length - 1].valueText : "—"
      return Object.assign({}, empty, {
        "title": "Stress", "icon": "󰐰", "variant": "stacked", "days": slots, "headline": todayStress,
        "partColors": [Util.alpha(fg, 0.22), Util.alpha(ac, 0.35), Util.alpha(ac, 0.7), root.urgentColor],
        "legend": [{ "label": "Rest", "color": Util.alpha(fg, 0.22) }, { "label": "Low", "color": Util.alpha(ac, 0.35) },
                   { "label": "Medium", "color": Util.alpha(ac, 0.7) }, { "label": "High", "color": root.urgentColor }],
        "summary": (av ? "avg stress " + root.fmtNumber(Math.round(av.avg)) : "")
          + (hi ? (av ? " · " : "") + "high " + root.fmtDuration(Math.round(hi.avg)) + "/day" : "")
      })
    }
    default:
      return empty
    }
  }

  // Every token in display order — chosen ones first, then the rest — plus the
  // subset that is actually on. Only the enabled part is persisted, so the
  // parked position of a hidden card lasts as long as the panel is open and
  // then goes back to the tail of the list. That is deliberate: a persisted
  // order for cards nobody can see is state the user cannot inspect.
  property var editOrder: []
  property var editEnabled: []

  // 0 is the chip-metric row; 1..n are the card rows. One integer is the whole
  // keyboard model — PanelKeyCatcher takes arrows before any child sees them,
  // so Tab-focus on the buttons would never receive Space or Return anyway.
  property int editCursor: 0

  // `custom` only exists when there is a command to run.
  readonly property var editableTokens: {
    var out = []
    for (var i = 0; i < root.knownMetrics.length; i++) {
      var t = root.knownMetrics[i]
      if (t === "custom" && root.customCommand === "") continue
      out.push(t)
    }
    return out
  }

  readonly property int editRowCount: 1 + root.editOrder.length

  function beginEdit() {
    var order = []
    for (var i = 0; i < root.metricTokens.length; i++)
      if (root.editableTokens.indexOf(root.metricTokens[i]) !== -1)
        order.push(root.metricTokens[i])
    var enabled = order.slice()
    for (var j = 0; j < root.editableTokens.length; j++)
      if (order.indexOf(root.editableTokens[j]) === -1) order.push(root.editableTokens[j])
    root.editOrder = order
    root.editEnabled = enabled
    root.editCursor = 0
    root.savedOrder = order.slice()
    root.savedEnabled = enabled.slice()
    root.editMode = true
  }

  // The last edit state the helper actually accepted. Every toggle and move
  // changes the UI first and asks the helper second, so a rejected `prefs set`
  // would otherwise leave the panel showing a configuration that exists nowhere
  // but on screen — and survives until the panel is reopened. On a rejection
  // the rows go back to these, and the "Couldn't save:" line says why.
  property var savedOrder: []
  property var savedEnabled: []

  function revertEdit() {
    root.editOrder = root.savedOrder.slice()
    root.editEnabled = root.savedEnabled.slice()
    if (root.editCursor > root.editOrder.length) root.editCursor = root.editOrder.length
  }

  Connections {
    target: root.service
    function onPrefsWritten() {
      root.savedOrder = root.editOrder.slice()
      root.savedEnabled = root.editEnabled.slice()
    }
    function onPrefsRejected() { root.revertEdit() }
  }

  function endEdit() { root.editMode = false }
  function toggleEdit() { root.editMode ? root.endEdit() : root.beginEdit() }

  function isEnabled(token) { return root.editEnabled.indexOf(token) !== -1 }

  function toggleToken(token) {
    var list = root.editEnabled.slice()
    var at = list.indexOf(token)
    if (at === -1) list.push(token)
    // The last visible card cannot be turned off: an empty list is rejected by
    // the helper (it would read back as "no pref" and fall through to
    // shell.json), so allowing it here would just produce a silent no-op.
    else if (list.length > 1) list.splice(at, 1)
    else return
    root.editEnabled = list
    root.commitEdit()
  }

  function moveToken(token, delta) {
    var order = root.editOrder.slice()
    var at = order.indexOf(token)
    var to = at + delta
    if (at === -1 || to < 0 || to >= order.length) return
    order[at] = order[to]
    order[to] = token
    root.editOrder = order
    if (root.editCursor === at + 1) root.editCursor = to + 1
    root.commitEdit()
  }

  function commitEdit() {
    var list = []
    for (var i = 0; i < root.editOrder.length; i++)
      if (root.isEnabled(root.editOrder[i])) list.push(root.editOrder[i])
    if (list.length === 0) return
    if (!root.applyPref("panelMetrics", list.join(","))) commitRetry.restart()
  }

  // A `prefs set` already in flight makes the next one a no-op — clicking two
  // toggles quickly would otherwise lose the second. The retry re-derives the
  // whole list from the current edit state, so it always writes the latest
  // intent rather than replaying a stale one.
  Timer {
    id: commitRetry
    interval: 200
    repeat: false
    onTriggered: root.commitEdit()
  }

  function applyPref(key, value) {
    // Through the host widget, so the write fans out to every screen's copy of
    // the widget rather than only the one whose panel is open.
    if (root.hostWidget && typeof root.hostWidget.setPref === "function")
      return root.hostWidget.setPref(key, value) !== false
    if (root.service && typeof root.service.setPref === "function")
      return root.service.setPref(key, value) !== false
    return false
  }

  readonly property var barMetricOptions: [
    { "token": "bodyBattery", "label": "Body Battery" },
    { "token": "steps", "label": "Steps" },
    { "token": "sleep", "label": "Sleep" },
    { "token": "readiness", "label": "Readiness" }
  ]

  // Asked of the bar widget rather than re-derived here, so the highlighted
  // chip is by definition the one the bar is actually showing.
  readonly property string currentBarMetric:
    root.hostWidget && root.hostWidget.barMetric ? String(root.hostWidget.barMetric) : "bodyBattery"

  function pickBarMetric(token) {
    barMetricRetry.pending = ""
    if (root.applyPref("barMetric", token)) return
    // Same one-in-flight problem the card list has: park the intent and try
    // again in a moment rather than dropping the click.
    barMetricRetry.pending = token
    barMetricRetry.restart()
  }

  Timer {
    id: barMetricRetry
    property string pending: ""
    interval: 200
    repeat: false
    onTriggered: if (barMetricRetry.pending !== "") root.pickBarMetric(barMetricRetry.pending)
  }

  // Arrow keys: up/down walk the rows, left/right act on the row under the
  // cursor — reorder on a card row, pick on the chip row.
  function editMove(dx, dy) {
    if (dy !== 0) {
      var next = root.editCursor + (dy > 0 ? 1 : -1)
      root.editCursor = Math.max(0, Math.min(root.editRowCount - 1, next))
      return
    }
    if (dx === 0) return
    if (root.editCursor === 0) {
      var at = -1
      for (var i = 0; i < root.barMetricOptions.length; i++)
        if (root.barMetricOptions[i].token === root.currentBarMetric) at = i
      var to = Math.max(0, Math.min(root.barMetricOptions.length - 1, at + (dx > 0 ? 1 : -1)))
      if (to !== at) root.pickBarMetric(root.barMetricOptions[to].token)
      return
    }
    root.moveToken(root.editOrder[root.editCursor - 1], dx > 0 ? 1 : -1)
  }

  function editActivate() {
    if (root.editCursor === 0) return
    root.toggleToken(root.editOrder[root.editCursor - 1])
  }

  // ---- Palette (taken off the bar so a recoloured bar carries through)
  readonly property color foreground: root.bar ? root.bar.foreground : Color.foreground
  readonly property color urgentColor: root.bar ? root.bar.urgent : Color.urgent
  readonly property color accentColor:
    root.bar && root.bar.accent !== undefined ? root.bar.accent : Color.accent
  readonly property color dim: Qt.darker(root.foreground, 1.55)
  readonly property string fontFamily: root.bar ? root.bar.fontFamily : Style.font.family

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    // Wide enough that the full helper path wraps at its own slashes rather
    // than mid-word, and that seven day-bars still read as bars rather than
    // hairlines. fittedContentWidth shrinks this further on a narrow screen.
    contentWidth: panel.fittedContentWidth(Style.space(440))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // Escape leaves edit mode first and only closes the panel on a second
      // press — the same shape every modal editor has, and the alternative
      // (panel vanishes mid-rearrange) loses the user their place.
      onCloseRequested: root.detailMode ? root.closeDetail() : root.editMode ? root.endEdit() : root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      // The activity list's cursor is checked first: openDetail clears edit
      // mode, so the two never overlap, but the order makes that impossible
      // to get wrong from here.
      onMoveRequested: function(dx, dy) {
        if (root.activityPage) { if (dy !== 0) root.activityMove(dy) }
        else if (root.editMode) root.editMove(dx, dy)
      }
      onActivateRequested: if (!root.activityPage && root.editMode) root.editActivate()
      onTextKey: function(t) {
        if (root.detailMode) {
          // The week view is read-only; refresh still works, edit does not.
          if (t === "r" || t === "R") root.refresh(true)
          return
        }
        if (root.editMode) {
          // j/k/h/l already arrive as moveRequested; only the exits matter here.
          if (t === "e" || t === "E") root.endEdit()
          return
        }
        if (t === "r" || t === "R") root.refresh(true)
        else if (t === "e" || t === "E") root.beginEdit()
        else if ((t === "c" || t === "C") && root.showGuidance) root.copy(root.guidanceCommand)
      }

      Column {
        id: column
        width: parent.width
        spacing: Style.space(12)

        PanelHero {
          width: parent.width
          title: "Garmin"
          meta: root.activityPage ? "Recent activities"
              : root.detailMode ? root.detail.title + " · last 7 days"
              : root.editMode ? "Editing cards" : root.heroMeta
          foreground: root.foreground
          fontFamily: root.fontFamily
          // The pencil sits in the hero's own trailing slot, which reserves
          // the space and centres the control against the labels.
          trailingControl: Component {
            PanelActionButton {
              // nf-md-pencil while looking, nf-md-check while editing,
              // nf-md-arrow_left on a detail page.
              iconText: root.detailMode ? "󰁍" : root.editMode ? "󰄬" : "󰏫"
              tooltipText: root.detailMode ? "Back" : root.editMode ? "Done" : "Edit cards"
              foreground: root.editMode ? root.accentColor : root.foreground
              hoverColor: root.foreground
              fontFamily: root.fontFamily
              bordered: true
              onClicked: root.detailMode ? root.closeDetail() : root.toggleEdit()
            }
          }
          iconComponent: Component {
            Text {
              textFormat: Text.PlainText
              // nf-md-triangle (U+F0536): evokes Garmin's delta mark without
              // reproducing the trademarked logo. Metric glyphs stay per-metric.
              text: "󰔶"
              color: root.showRows && !root.showStale ? root.accentColor : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
            }
          }
        }

        // ---- Stale footer: cached data is showing, so the hero already says
        // "Showing last known data" — this line adds *why*, when the helper
        // sent one (the failing call's exception class, never a raw string).
        Text {
          textFormat: Text.PlainText
          visible: root.showStale && !root.editMode && root.lastError !== ""
          width: parent.width
          text: root.lastError
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        // ---- Guidance: deps / no-tokens / auth-expired
        Column {
          visible: root.showGuidance && !root.editMode
          width: parent.width
          spacing: Style.space(8)

          PanelSeparator { foreground: root.foreground }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: root.guidanceTitle
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
          }

          // The command sits in its own bordered strip with a copy button
          // beside it: the login path is far too long to retype off a
          // screenshot, and a typo in it produces a confusing "no such file"
          // rather than a login prompt.
          Item {
            width: parent.width
            implicitHeight: Math.max(commandBox.implicitHeight, copyButton.implicitHeight)

            BorderSurface {
              id: commandBox
              anchors.left: parent.left
              anchors.right: copyButton.left
              anchors.rightMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
              implicitHeight: commandText.implicitHeight + Style.spacing.controlPaddingY * 2
              height: implicitHeight
              radius: Style.cornerRadius
              // Off the bar's own colours, not the global tokens, so a
              // recoloured bar carries through to the command strip.
              color: Style.normalFillFor(root.foreground, root.accentColor, root.urgentColor)
              borderSpec: Border.controlSpec("normal", root.foreground, root.accentColor)

              Text {
                textFormat: Text.PlainText
                id: commandText
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.leftMargin: Style.spacing.controlPaddingX
                anchors.rightMargin: Style.spacing.controlPaddingX
                anchors.verticalCenter: parent.verticalCenter
                text: root.guidanceCommand
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                // Text.Wrap, not WrapAnywhere: the login line is one long path
                // followed by " login", so word wrapping breaks it at the space
                // and keeps the path intact. WrapAnywhere split it mid-word
                // ("logi / n"), which reads like a typo in a command you are
                // being asked to trust.
                wrapMode: Text.Wrap
              }
            }

            PanelActionButton {
              id: copyButton
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              // nf-md-check while the flash is up, nf-md-clipboard otherwise.
              iconText: root.copied ? "󰄬" : "󰆏"
              tooltipText: root.copied ? "Copied" : "Copy command"
              foreground: root.copied ? root.accentColor : root.foreground
              hoverColor: root.foreground
              fontFamily: root.fontFamily
              bordered: true
              onClicked: root.copy(root.guidanceCommand)
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: root.lastError !== ""
            width: parent.width
            text: root.lastError
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }

        // ---- Unreachable with nothing cached
        Column {
          visible: root.showUnreachable && !root.editMode
          width: parent.width
          spacing: Style.space(8)

          PanelSeparator { foreground: root.foreground }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: "Can't reach Garmin Connect."
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
          }

          Text {
            textFormat: Text.PlainText
            visible: root.lastError !== ""
            width: parent.width
            text: root.lastError
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }

        Text {
          textFormat: Text.PlainText
          visible: root.showLoading && !root.editMode
          width: parent.width
          text: "Checking…"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }

        // ---- Metric cards: live / stale
        //
        // Rows come from `cardRows`, which has already dropped the metrics
        // this payload has nothing for and decided how many cards share a
        // row. Everything a card shows is a formatted string by the time it
        // gets here — the delegates only place things.
        Column {
          id: cardsColumn
          visible: root.showRows && !root.editMode && !root.detailMode
          width: parent.width
          spacing: Style.space(8)

          // No section header here: the hero already says "Today", and two
          // TODAY labels stacked on top of each other just read as a bug.
          PanelSeparator { foreground: root.foreground }

          // One line of explanation for the empty morning, so the row of em
          // dashes reads as "the watch hasn't uploaded" rather than as a
          // broken panel. Caption styling on purpose: nothing has gone wrong.
          Text {
            textFormat: Text.PlainText
            visible: root.emptyToday && root.visibleCardCount > 0
            width: parent.width
            text: "No data from your watch yet today — showing your week."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Text {
            textFormat: Text.PlainText
            visible: root.visibleCardCount === 0
            width: parent.width
            text: "No figures for today yet."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          Repeater {
            model: root.cardRows

            // A RowLayout rather than a Row so both cards in a dense pair end
            // up the same height: the layout's own height is the taller card's
            // implicit height, and `Layout.fillHeight` stretches the shorter
            // one to match. With a plain Row each card kept its own height and
            // a meter-less card next to a metered one left a visible step in
            // the tinted background. Single-card rows are unaffected — one
            // child means the max is that child.
            RowLayout {
              id: cardRow
              required property var modelData

              width: cardsColumn.width
              spacing: Style.space(8)

              readonly property real cellWidth:
                (cardRow.width - cardRow.spacing * (cardRow.modelData.length - 1)) / cardRow.modelData.length

              Repeater {
                model: cardRow.modelData

                Item {
                  id: cardSlot
                  required property string modelData

                  readonly property var card: root.cardFor(cardSlot.modelData)
                  readonly property bool isCurve: cardSlot.card.kind === "curve"

                  // implicitHeight is what the layout measures; `height` is
                  // what it hands back, equalised across the row. Neither card
                  // derives its implicitHeight from its height, so there is no
                  // binding loop here.
                  Layout.preferredWidth: cardRow.cellWidth
                  Layout.fillWidth: true
                  Layout.fillHeight: true
                  implicitHeight: cardSlot.isCurve ? curveCard.implicitHeight : metricCard.implicitHeight

                  CurveCard {
                    id: curveCard
                    width: parent.width
                    height: cardSlot.height
                    visible: cardSlot.isCurve
                    // Gates the Canvas: only the card that is actually on
                    // screen pays for a paint texture.
                    active: visible
                    icon: cardSlot.card.icon || ""
                    title: cardSlot.card.title || ""
                    value: cardSlot.card.value || "—"
                    tone: cardSlot.card.tone || ""
                    caption: cardSlot.card.caption || ""
                    bodyBatterySeries: root.bbSeries
                    stressSeries: root.stressSeries
                    clickable: root.expandable(cardSlot.modelData)
                    onClicked: root.openDetail(cardSlot.modelData)
                    foreground: root.foreground
                    accentColor: root.accentColor
                    urgentColor: root.urgentColor
                    dim: root.dim
                    fontFamily: root.fontFamily
                    muted: root.showStale
                  }

                  MetricCard {
                    id: metricCard
                    width: parent.width
                    height: cardSlot.height
                    visible: !cardSlot.isCurve
                    icon: cardSlot.card.icon || ""
                    title: cardSlot.card.title || ""
                    value: cardSlot.card.value || "—"
                    caption: root.staleCaption(cardSlot.card.caption || "", cardSlot.modelData)
                    delta: cardSlot.card.delta || ""
                    deltaTone: cardSlot.card.deltaTone || ""
                    tone: cardSlot.card.tone || ""
                    meterPercent: cardSlot.card.meterPercent === undefined ? -1 : cardSlot.card.meterPercent
                    strip: cardSlot.card.strip === undefined ? [] : cardSlot.card.strip
                    clickable: root.expandable(cardSlot.modelData)
                    onClicked: root.openDetail(cardSlot.modelData)
                    foreground: root.foreground
                    accentColor: root.accentColor
                    urgentColor: root.urgentColor
                    dim: root.dim
                    fontFamily: root.fontFamily
                    // Garmin staleness says nothing about somebody's own
                    // command, which was re-run on this very tick. Dimming it
                    // alongside the Garmin cards claims its number is old too.
                    muted: (root.showStale || root.isCarried(cardSlot.modelData)) && cardSlot.modelData !== "custom"
                  }
                }
              }
            }
          }
        }

        // ---- Detail page: one metric, the last seven days
        Column {
          visible: root.detailMode
          width: parent.width
          spacing: Style.space(10)

          PanelSeparator { foreground: root.foreground }

          // The week pages' header: icon, title, today's figure. The activity
          // list has its own heading row (count + week summary) instead — the
          // card's figure is one activity's name, not a figure for the page.
          Item {
            visible: !root.activityPage
            width: parent.width
            implicitHeight: visible ? Math.max(detailIcon.implicitHeight, detailTitle.implicitHeight, detailValue.implicitHeight) : 0

            Text {
              textFormat: Text.PlainText
              id: detailIcon
              text: root.detail.icon
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.icon
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              textFormat: Text.PlainText
              id: detailTitle
              text: root.detail.title
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
              anchors.left: detailIcon.right
              anchors.leftMargin: Style.space(8)
              anchors.right: detailValue.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
            }

            // Today's figure, as the card shows it, so the page opens on the
            // number the user just clicked.
            Text {
              textFormat: Text.PlainText
              id: detailValue
              readonly property var card: root.detailMode ? root.cardFor(root.detailToken, false) : null
              text: root.detail.headline !== null && root.detail.headline !== undefined
                ? String(root.detail.headline) : (card && card.value ? String(card.value) : "—")
              color: root.showStale ? root.dim : root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.subtitle
              font.bold: true
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          WeekView {
            visible: !root.activityPage
            width: parent.width
            days: root.detail.days
            variant: root.detail.variant
            fixedMax: root.detail.fixedMax
            axisMin: root.detail.axisMin
            band: root.detail.band
            partColors: root.detail.partColors
            legend: root.detail.legend
            summary: root.detail.summary
            foreground: root.foreground
            accentColor: root.accentColor
            urgentColor: root.urgentColor
            dim: root.dim
            fontFamily: root.fontFamily
            muted: root.showStale
          }

          ActivityList {
            visible: root.activityPage
            width: parent.width
            rows: root.activityListRows
            cursor: root.activityCursor
            heading: root.activityListHeading
            summary: root.activityWeekSummary
            foreground: root.foreground
            accentColor: root.accentColor
            dim: root.dim
            fontFamily: root.fontFamily
            muted: root.showStale || root.isCarried("activity")
            onHovered: function(index) { root.activityCursor = index }
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: root.activityPage ? "↑↓ choose · Esc or the arrow to go back"
                                    : "Hover a day for detail · Esc or the arrow to go back"
            color: root.dim
            opacity: 0.7
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        // ---- Custom card on its own, when the Garmin cards cannot render
        //
        // The card list above is gated on having a Garmin payload, which the
        // custom card has nothing to do with: it is the user's own command,
        // and a dead login or an unreachable API is no reason to hide it. In
        // every degraded state it comes back here as a single full-width row
        // under the guidance block, so "not signed in" costs you the Garmin
        // cards and only those.
        Column {
          visible: root.showCustomAlone && !root.editMode && !root.detailMode
          width: parent.width
          spacing: Style.space(8)

          PanelSeparator { foreground: root.foreground }

          MetricCard {
            width: parent.width
            height: implicitHeight
            icon: root.customAloneCard.icon || ""
            title: root.customAloneCard.title || ""
            value: root.customAloneCard.value || "—"
            caption: root.customAloneCard.caption || ""
            tone: root.customAloneCard.tone || ""
            meterPercent: root.customAloneCard.meterPercent === undefined
              ? -1 : root.customAloneCard.meterPercent
            foreground: root.foreground
            accentColor: root.accentColor
            urgentColor: root.urgentColor
            dim: root.dim
            fontFamily: root.fontFamily
          }
        }

        // ---- Edit mode: chip metric, then every card with a toggle and arrows
        Column {
          id: editColumn
          visible: root.editMode
          width: parent.width
          spacing: Style.space(8)

          PanelSeparator { foreground: root.foreground }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: "BAR CHIP"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 1.2
          }

          Row {
            width: parent.width
            spacing: Style.space(6)

            Repeater {
              model: root.barMetricOptions

              Button {
                required property var modelData
                text: modelData.label
                selected: root.currentBarMetric === modelData.token
                // The keyboard cursor sits on the row, not on one option, so
                // it shows on whichever chip is currently chosen.
                hasCursor: root.editCursor === 0 && root.currentBarMetric === modelData.token
                foreground: root.foreground
                accent: root.accentColor
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                bordered: true
                onClicked: root.pickBarMetric(modelData.token)
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: "PANEL CARDS"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 1.2
          }

          Repeater {
            model: root.editOrder

            Item {
              id: editRow
              required property string modelData
              required property int index

              readonly property bool on: root.isEnabled(editRow.modelData)
              readonly property bool cursored: root.editCursor === editRow.index + 1

              width: editColumn.width
              implicitHeight: Math.max(nameButton.implicitHeight, upButton.implicitHeight)

              Button {
                id: nameButton
                anchors.left: parent.left
                anchors.right: upButton.left
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                // The eye glyph carries the state, so the row reads the same
                // whether the theme paints `selected` strongly or subtly.
                text: (editRow.on ? "󰛐  " : "󰛑  ") + root.editLabel(editRow.modelData)
                leftAlign: true
                selected: editRow.on
                hasCursor: editRow.cursored
                opacity: editRow.on ? 1.0 : 0.55
                foreground: root.foreground
                accent: root.accentColor
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                bordered: true
                onClicked: root.toggleToken(editRow.modelData)
              }

              PanelActionButton {
                id: upButton
                anchors.right: downButton.left
                anchors.rightMargin: Style.space(4)
                anchors.verticalCenter: parent.verticalCenter
                iconText: "󰁝"  // nf-md-arrow-up-thin
                tooltipText: "Move up"
                enabled: editRow.index > 0
                opacity: enabled ? 1.0 : 0.35
                foreground: root.foreground
                hoverColor: root.foreground
                fontFamily: root.fontFamily
                bordered: true
                onClicked: root.moveToken(editRow.modelData, -1)
              }

              PanelActionButton {
                id: downButton
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                iconText: "󰁅"  // nf-md-arrow-down-thin
                tooltipText: "Move down"
                enabled: editRow.index < root.editOrder.length - 1
                opacity: enabled ? 1.0 : 0.35
                foreground: root.foreground
                hoverColor: root.foreground
                fontFamily: root.fontFamily
                bordered: true
                onClicked: root.moveToken(editRow.modelData, 1)
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            visible: root.customCommand === ""
            text: "Set customCommand in the widget's settings to add your own card."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: "↑↓ row · ←→ reorder · space show/hide · Esc done"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            visible: root.service && String(root.service.prefsError || "") !== ""
            text: "Couldn't save: " + (root.service ? String(root.service.prefsError || "") : "")
            color: root.urgentColor
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }

        // ---- Footer: freshness on the left, refresh on the right
        PanelSeparator { foreground: root.foreground }

        Item {
          width: parent.width
          implicitHeight: Math.max(footerText.implicitHeight, refreshButton.implicitHeight)

          Text {
            textFormat: Text.PlainText
            id: footerText
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: root.editMode ? "Changes save as you make them"
                                : (root.busy ? "Refreshing…" : root.asOfText)
            color: root.showStale && !root.editMode ? root.urgentColor : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          // Edit mode has its own exit here as well as the hero's check and
          // Escape: a button labelled Done is the one affordance nobody has to
          // discover.
          Button {
            id: doneButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            visible: root.editMode
            text: "Done"
            foreground: root.foreground
            accent: root.accentColor
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            bordered: true
            focusable: true
            onClicked: root.endEdit()
          }

          Button {
            id: refreshButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            visible: !root.editMode
            text: "Refresh"
            // Ui/Button paints `enabled` nowhere, so dim it by hand — otherwise
            // a fetch already in flight looks like a button that ignored you.
            enabled: !root.busy
            opacity: root.busy ? 0.45 : 1.0
            Behavior on opacity { NumberAnimation { duration: 120 } }
            foreground: root.foreground
            accent: root.accentColor
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            bordered: true
            focusable: true
            onClicked: root.refresh(true)
          }
        }
      }
    }
  }
}
