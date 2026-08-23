import QtQuick
import Quickshell
import Quickshell.Io

// Runs bin/garmin-widget and turns its JSON-always output into a small state
// machine the bar chip and the detail panel can both bind to.
//
// The helper is contractually incapable of failing loudly — it exits 0 and
// prints one JSON object whatever happens — so everything here is about
// classifying that object. Parsing is deliberately defensive: garbage on
// stdout, a killed process, or an error code we have never heard of all land
// on "api-error" rather than throwing, because a bar widget that throws takes
// the whole bar down with it.
Item {
  id: root

  // deps | no-tokens | auth-expired | offline | api-error | stale | live | loading
  //
  // Deliberately shadows Item.state. Nothing here uses QML states or
  // transitions, and "state" is the name the panel and chip both want to bind;
  // renaming it now would ripple through both for no gain.
  property string state: "loading"

  // Last payload we were happy with, kept across later failures so an offline
  // blip keeps showing yesterday's numbers instead of blanking the chip.
  //
  // Named `payload`, not `data`: Item.data is QML's default property — the
  // children list — and a `property var data` here does not replace it. It
  // reads back as a non-null list object until something assigns to it, so
  // `data !== null` was true on a brand-new shell and the very first offline
  // failure classified itself as "stale, showing last known data" over a
  // payload that did not exist.
  property var payload: null

  property string lastError: ""

  // The helper's own remediation string, when it sends one — so the panel
  // prints the command that actually fixes *this* install rather than a
  // literal the helper has since moved on from.
  property string lastHint: ""

  property int pollMinutes: 30

  // Gate the owner can use to decide, at each tick, whether this instance is
  // allowed to spawn the helper. The bar builds one widget per screen, and
  // three monitors should not mean three Garmin API clients. Checked at fire
  // time rather than bound once, so unplugging the primary screen's bar
  // silently promotes whoever is left instead of stopping the polling.
  property var canPoll: function () { return true }

  // Every error code the helper is allowed to emit. Anything outside this set
  // is a helper we do not understand, which is an api-error by definition.
  readonly property var knownErrors: ["deps", "no-tokens", "auth-expired", "offline", "api-error"]

  readonly property bool busy: fetchProcess.running

  // The helper ships inside the plugin directory, so it is located relative to
  // this file rather than through PATH — the plugin must work unpacked
  // anywhere under ~/.config/omarchy/plugins/.
  //
  // decodeURIComponent throws URIError on a stray "%" in a path — a plugin
  // unpacked under a directory with one in its name would take the whole
  // widget down at construction. The percent-encoded path still runs fine as
  // an argv[0] in the overwhelming majority of cases, so a failed decode falls
  // back to it rather than leaving the Service with no helper at all.
  readonly property string helperPath: {
    var raw = String(Qt.resolvedUrl("bin/garmin-widget")).replace(/^file:\/\//, "")
    try {
      return decodeURIComponent(raw)
    } catch (e) {
      return raw
    }
  }

  // ---- Preferences (written by the panel's edit mode, owned by the helper)
  //
  // QML never writes prefs.json itself: `garmin-widget prefs set` does, so the
  // atomic-replace/0600 discipline every other file in this plugin gets applies
  // here too. What comes back is already validated — unknown keys and unknown
  // tokens are dropped helper-side — so the panel can bind it directly.
  property var prefs: ({})
  property string prefsError: ""

  readonly property string prefPanelMetrics: {
    var m = root.prefs ? root.prefs.panelMetrics : null
    return (m && m.length !== undefined && m.length > 0) ? m.join(",") : ""
  }
  readonly property string prefBarMetric:
    root.prefs && typeof root.prefs.barMetric === "string" ? root.prefs.barMetric : ""

  // ---- Custom card
  //
  // The user's own command line, run on the poll cadence. Everything about it
  // is deliberately walled off from the Garmin state machine above: its own
  // Process, its own watchdog, its own error string. A command that hangs,
  // exits 3, or prints a megabyte of noise costs its card and nothing else —
  // `state` and `payload` never hear about it.
  property string customCommand: ""
  property var customCard: null
  property string customError: ""

  // 8 KB is already two orders of magnitude more than a card needs. Past it we
  // stop reading rather than truncate: half a JSON object parses as garbage,
  // and "your command printed too much" is the more useful thing to say.
  readonly property int customOutputCap: 8192

  signal refreshed()

  function poll() {
    var allowed = true
    try {
      allowed = root.canPoll()
    } catch (e) {
      allowed = true
    }
    if (allowed) root.refresh()
  }

  function refresh() {
    if (fetchProcess.running) return
    _stdout = ""
    root.lastHint = ""
    fetchProcess.command = [root.helperPath, "fetch"]
    fetchProcess.running = true
    watchdog.restart()
  }

  function applyPayload(text) {
    var payload
    try {
      payload = JSON.parse(String(text))
    } catch (e) {
      root.fail("api-error", "unparseable helper output")
      return
    }

    if (!payload || typeof payload !== "object") {
      root.fail("api-error", "helper output was not an object")
      return
    }

    if (payload.ok === true) {
      root.payload = payload
      root.lastError = ""
      root.lastHint = ""
      root.state = payload.stale === true ? "stale" : "live"
      root.refreshed()
      return
    }

    root.lastHint = String(payload.hint || "")
    var code = String(payload.error || "")
    if (root.knownErrors.indexOf(code) === -1) code = "api-error"
    root.fail(code, String(payload.detail || payload.hint || payload.error || ""))
  }

  // A failure never discards `payload`. Losing the network is not a reason to
  // forget this morning's Body Battery — it is a reason to mark it stale.
  function fail(code, detail) {
    root.lastError = detail
    root.state = (code === "offline" && root.payload !== null) ? "stale" : code
    root.refreshed()
  }

  // ---- prefs plumbing
  //
  // One Process for both get and set: they are the same short-lived helper call
  // and a set answers with the full prefs object, so the reply handling is
  // identical. Both are fire-and-forget from the caller's point of view; the
  // panel re-renders when `prefs` changes.
  function loadPrefs() {
    if (prefsProcess.running) return false
    _prefsOut = ""
    prefsProcess.command = [root.helperPath, "prefs", "get"]
    prefsProcess.running = true
    prefsWatchdog.restart()
    return true
  }

  function setPref(key, value) {
    if (prefsProcess.running) return false
    _prefsOut = ""
    root._prefsWasSet = true
    prefsProcess.command = [root.helperPath, "prefs", "set", String(key), String(value)]
    prefsProcess.running = true
    prefsWatchdog.restart()
    return true
  }

  // Emitted only after a successful `prefs set`, so the owner can tell its
  // peers to re-read. A plain prefs *read* must not emit it: `prefs` changing
  // would then trigger another read, which would change `prefs` again.
  signal prefsWritten()

  property bool _prefsWasSet: false

  function applyPrefs(text) {
    var wasSet = root._prefsWasSet
    root._prefsWasSet = false
    var obj
    try {
      obj = JSON.parse(String(text))
    } catch (e) {
      root.prefsError = "unreadable prefs output"
      return
    }
    if (!obj || typeof obj !== "object" || obj.ok !== true
        || !obj.prefs || typeof obj.prefs !== "object") {
      // The helper's one rejection detail ("InvalidPref") or nothing at all.
      root.prefsError = String((obj && obj.detail) || "prefs rejected")
      return
    }
    root.prefsError = ""
    root.prefs = obj.prefs
    if (wasSet) root.prefsWritten()
  }

  property string _prefsOut: ""

  Process {
    id: prefsProcess
    running: false
    command: []
    stdout: StdioCollector { id: prefsStdout; waitForEnd: true; onStreamFinished: root._prefsOut = text }
    onExited: {
      var timedOut = prefsWatchdog.tripped
      prefsWatchdog.stop()
      prefsWatchdog.tripped = false
      if (timedOut) return
      root.applyPrefs(String(prefsStdout.text || root._prefsOut || ""))
    }
  }

  // prefs get/set is a local file read — if it has not answered in ten seconds
  // something is very wrong, and leaving `running` latched would make every
  // later edit silently do nothing.
  Timer {
    id: prefsWatchdog
    property bool tripped: false
    interval: 10000
    repeat: false
    onTriggered: {
      if (!prefsProcess.running) return
      prefsWatchdog.tripped = true
      prefsProcess.running = false
      root._prefsWasSet = false
      root.prefsError = "prefs helper timed out"
    }
  }

  // Take a result the primary instance already paid for. Deliberately silent —
  // emitting `refreshed()` here would bounce the payload straight back out
  // through the publisher and loop the bar.
  function adopt(state, payload, lastError) {
    root.payload = payload
    root.state = String(state)
    root.lastError = String(lastError || "")
  }

  property string _stdout: ""

  Process {
    id: fetchProcess
    running: false
    command: []
    stdout: StdioCollector { id: fetchStdout; waitForEnd: true; onStreamFinished: root._stdout = text }
    onExited: {
      var timedOut = watchdog.tripped
      watchdog.stop()
      watchdog.tripped = false
      if (timedOut) return  // the watchdog already recorded the failure
      root.applyPayload(String(fetchStdout.text || root._stdout || ""))
    }
  }

  // The helper has its own network timeouts, but a wedged subprocess would
  // otherwise block every later refresh through the `running` guard. Cutting
  // it loose leaves the last good data on screen and lets the next tick try.
  Timer {
    id: watchdog
    property bool tripped: false
    interval: 45000
    repeat: false
    onTriggered: {
      if (!fetchProcess.running) return
      watchdog.tripped = true
      fetchProcess.running = false
      // Named explicitly rather than left to onExited's empty stdout, so the
      // tooltip says "timed out" instead of "unparseable helper output".
      root.fail("api-error", "helper timed out")
    }
  }

  Timer {
    id: pollTimer
    // Floored rather than trusted: a mis-typed pollMinutes of 0 would hammer
    // Garmin's API from a widget nobody is looking at.
    interval: Math.max(5, Number(root.pollMinutes) || 30) * 60 * 1000
    running: true
    repeat: true
    onTriggered: root.poll()
  }

  // The bar registers its widgets a moment after they finish constructing, so
  // an immediate first poll would run before `canPoll()` can tell primary from
  // secondary — and every screen would fetch once. A short delay costs nothing
  // on a 30-minute cycle and makes the very first tick honour the gate too.
  // Prefs are a local file read, so they are fetched immediately rather than
  // behind the poll gate: every instance needs them (the bar chip's metric
  // comes from here too), and none of them talk to Garmin to get them.
  Component.onCompleted: root.loadPrefs()

  Timer {
    id: startupTimer
    interval: 1500
    repeat: false
    running: true
    onTriggered: root.poll()
  }
}
