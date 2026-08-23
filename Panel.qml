import QtQuick
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
  function refresh() {
    if (root.hostWidget && typeof root.hostWidget.requestRefresh === "function") root.hostWidget.requestRefresh()
    else if (root.service && typeof root.service.refresh === "function") root.service.refresh()
  }

  // Opening the panel is a request to look at today's numbers, so a broken or
  // outdated state gets one free retry. A `live` state does not — the poller
  // already has it covered, and clicking the chip should not become a way to
  // hammer Garmin's API.
  function refreshIfStale() {
    if (root.svcState !== "live" && root.svcState !== "loading") root.refresh()
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
      : "python3 -m venv ~/.local/share/garmin-widget/venv && ~/.local/share/garmin-widget/venv/bin/pip install garminconnect==0.3.11"

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
  readonly property var activityInfo: root.payload && root.payload.lastActivity ? root.payload.lastActivity : null

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
  function stripFor(field, fixedMax) {
    if (root.newestHistoryDate === "") return []
    var end = root.parseDay(root.newestHistoryDate)
    if (!end) return []

    var slots = []
    var max = Number(fixedMax) > 0 ? Number(fixedMax) : 0
    for (var back = 6; back >= 0; back--) {
      var day = new Date(end.getFullYear(), end.getMonth(), end.getDate() - back)
      var entry = root.historyByDate[root.dayKey(day)]
      var value = entry ? root.num(entry[field]) : null
      if (value !== null && Number(fixedMax) <= 0 && value > max) max = value
      slots.push({ "label": root.weekdayNames[day.getDay()], "value": value, "present": value !== null, "frac": 0 })
    }

    for (var i = 0; i < slots.length; i++)
      slots[i].frac = (slots[i].present && max > 0) ? Math.max(0, Math.min(1, slots[i].value / max)) : 0
    return slots
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
      var v = root.num(root.historySorted[i][field])
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
      if (!root.hasCurve) {
        if (root.hasBatteryValues && root.metricTokens.indexOf("battery") === -1)
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
        "show": root.hasBatteryValues,
        "icon": "󱐋",
        "title": "Body Battery",
        "value": root.batteryValue,
        "caption": root.batteryMeta,
        "tone": root.batteryTone(current),
        "strip": dense ? [] : root.stripFor("bodyBatteryHigh", 100)
      }
    }
    case "sleep": {
      var score = root.num(root.sleepInfo ? root.sleepInfo.score : null)
      var duration = root.num(root.sleepInfo ? root.sleepInfo.durationMin : null)
      var d = root.deltaFor("sleepScore", false)
      return {
        "kind": "metric",
        "show": score !== null || duration !== null,
        "icon": "󰒲",
        "title": "Sleep",
        "value": root.sleepValue,
        "delta": d.glyph,
        "deltaTone": d.tone,
        "strip": dense ? [] : root.stripFor("sleepScore", 100)
      }
    }
    case "steps": {
      var d2 = root.deltaFor("steps", false)
      return {
        "kind": "metric",
        "show": root.hasSteps,
        "icon": "󰖃",
        "title": "Steps",
        "value": root.fmtSteps(root.stepsCount),
        "caption": "goal " + root.fmtSteps(root.stepsGoal),
        "meterPercent": root.stepsProgress * 100,
        "delta": d2.glyph,
        "deltaTone": d2.tone,
        "strip": dense ? [] : root.stripFor("steps", Math.max(root.stepsGoal, 0))
      }
    }
    case "readiness": {
      var rs = root.num(root.readinessInfo ? root.readinessInfo.score : null)
      var level = root.titleCase(root.readinessInfo ? root.readinessInfo.level : "")
      return {
        "kind": "metric",
        "show": rs !== null || level !== "",
        "icon": "󰓅",
        "title": "Training readiness",
        "value": root.fmtNumber(rs),
        "caption": level,
        "tone": root.readinessTone(rs)
      }
    }
    case "rhr": {
      var d3 = root.deltaFor("restingHr", true)
      return {
        "kind": "metric",
        "show": root.num(root.payload ? root.payload.restingHr : null) !== null,
        "icon": "󰗶",
        "title": "Resting HR",
        "value": root.restingHrValue,
        "delta": d3.glyph,
        "deltaTone": d3.tone
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
        "show": last !== null || status !== "",
        "icon": "󰐰",
        "title": "HRV",
        "value": last === null ? "—" : root.fmtNumber(last) + " ms",
        "caption": parts.join(" · "),
        "tone": root.hrvTone(root.hrvInfo ? root.hrvInfo.status : "")
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
        "show": count !== null,
        "icon": "󱅈",
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
        "show": total !== null || active !== null,
        "icon": "󰈸",
        "title": "Calories",
        "value": total === null ? "—" : root.fmtSteps(total) + " kcal",
        "caption": active === null ? "" : root.fmtSteps(active) + " active"
      }
    }
    case "activity": {
      // The date is not decoration. The last activity can be weeks old, and a
      // duration with no date on it reads as "you did this today".
      var type = root.titleCase(root.activityInfo ? root.activityInfo.type : "")
      var mins = root.num(root.activityInfo ? root.activityInfo.durationMin : null)
      var km = root.num(root.activityInfo ? root.activityInfo.distanceKm : null)
      var when = root.activityInfo ? String(root.activityInfo.date || "") : ""
      var meta = []
      if (mins !== null) meta.push(root.fmtDuration(mins))
      if (km !== null) meta.push(km.toFixed(2) + " km")
      meta.push(when === "" ? "date unknown" : root.fmtDay(when))
      return {
        "kind": "metric",
        "show": root.activityInfo !== null && (type !== "" || mins !== null || km !== null),
        "icon": "󰜎",
        // Two cards to a row leaves no space for "Last activity" — it elides
        // to "Last a…", which reads like a rendering bug rather than a title.
        "title": dense ? "Activity" : "Last activity",
        "value": type === "" ? "—" : type,
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
    root.editMode = true
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
      onCloseRequested: root.editMode ? root.endEdit() : root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) { if (root.editMode) root.editMove(dx, dy) }
      onActivateRequested: if (root.editMode) root.editActivate()
      onTextKey: function(t) {
        if (root.editMode) {
          // j/k/h/l already arrive as moveRequested; only the exits matter here.
          if (t === "e" || t === "E") root.endEdit()
          return
        }
        if (t === "r" || t === "R") root.refresh()
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
          meta: root.editMode ? "Editing cards" : root.heroMeta
          foreground: root.foreground
          fontFamily: root.fontFamily
          // The pencil sits in the hero's own trailing slot, which reserves
          // the space and centres the control against the labels.
          trailingControl: Component {
            PanelActionButton {
              // nf-md-pencil while looking, nf-md-check while editing.
              iconText: root.editMode ? "󰄬" : "󰏫"
              tooltipText: root.editMode ? "Done" : "Edit cards"
              foreground: root.editMode ? root.accentColor : root.foreground
              hoverColor: root.foreground
              fontFamily: root.fontFamily
              bordered: true
              onClicked: root.toggleEdit()
            }
          }
          iconComponent: Component {
            Text {
              // nf-md-lightning-bolt, the same glyph the bar chip uses.
              text: "󱐋"
              color: root.showRows && !root.showStale ? root.accentColor : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
            }
          }
        }

        // ---- Guidance: deps / no-tokens / auth-expired
        Column {
          visible: root.showGuidance && !root.editMode
          width: parent.width
          spacing: Style.space(8)

          PanelSeparator { foreground: root.foreground }

          Text {
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
            width: parent.width
            text: "Can't reach Garmin Connect."
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
          }

          Text {
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
          visible: root.showRows && !root.editMode
          width: parent.width
          spacing: Style.space(8)

          // No section header here: the hero already says "Today", and two
          // TODAY labels stacked on top of each other just read as a bug.
          PanelSeparator { foreground: root.foreground }

          Text {
            visible: root.visibleCardCount === 0
            width: parent.width
            text: "No figures for today yet."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          Repeater {
            model: root.cardRows

            Row {
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

                  width: cardRow.cellWidth
                  height: isCurve ? curveCard.implicitHeight : metricCard.implicitHeight

                  CurveCard {
                    id: curveCard
                    width: parent.width
                    height: implicitHeight
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
                    height: implicitHeight
                    visible: !cardSlot.isCurve
                    icon: cardSlot.card.icon || ""
                    title: cardSlot.card.title || ""
                    value: cardSlot.card.value || "—"
                    caption: cardSlot.card.caption || ""
                    delta: cardSlot.card.delta || ""
                    deltaTone: cardSlot.card.deltaTone || ""
                    tone: cardSlot.card.tone || ""
                    meterPercent: cardSlot.card.meterPercent === undefined ? -1 : cardSlot.card.meterPercent
                    strip: cardSlot.card.strip === undefined ? [] : cardSlot.card.strip
                    foreground: root.foreground
                    accentColor: root.accentColor
                    urgentColor: root.urgentColor
                    dim: root.dim
                    fontFamily: root.fontFamily
                    muted: root.showStale
                  }
                }
              }
            }
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
                text: (editRow.on ? "󰛐  " : "󰛑  ") + (root.metricLabels[editRow.modelData] || editRow.modelData)
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
            width: parent.width
            visible: root.customCommand === ""
            text: "Set customCommand in the widget's settings to add your own card."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Text {
            width: parent.width
            text: "↑↓ row · ←→ reorder · space show/hide · Esc done"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
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
            onClicked: root.refresh()
          }
        }
      }
    }
  }
}
