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

  // The panel's card list as it comes from shell.json, injected by the owner
  // the same way `pollMinutes` and `customCommand` are. The Service needs it
  // for one reason only: a `custom` token the user has turned off in edit mode
  // must stop the command from *running*, not merely stop its card from being
  // drawn. Somebody's script is not a rendering detail.
  //
  // Precedence mirrors the panel's own: prefs.json > shell.json > the built-in
  // default (which contains no `custom` token, so an unconfigured install never
  // runs anything).
  property string panelMetricsSetting: ""

  readonly property string effectivePanelMetrics: {
    var pref = String(root.prefPanelMetrics || "")
    return pref !== "" ? pref : String(root.panelMetricsSetting || "")
  }

  readonly property bool customEnabled: {
    var parts = String(root.effectivePanelMetrics || "").split(",")
    for (var i = 0; i < parts.length; i++)
      if (parts[i].replace(/^\s+|\s+$/g, "").toLowerCase() === "custom") return true
    return false
  }

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
    // The custom command is not part of the Garmin fetch, so it is kicked off
    // before the `running` guard below — a fetch already in flight must not
    // also swallow the refresh of a card that has nothing to do with it.
    root.runCustom()
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

  // The mirror image: a `prefs set` that did not stick. The edit UI has already
  // moved to the state the user asked for, and nothing on disk agrees with it —
  // the owner uses this to put its toggles back where they were.
  signal prefsRejected()

  property bool _prefsWasSet: false

  function applyPrefs(text) {
    var wasSet = root._prefsWasSet
    root._prefsWasSet = false
    var obj
    try {
      obj = JSON.parse(String(text))
    } catch (e) {
      root.prefsError = "unreadable prefs output"
      if (wasSet) root.prefsRejected()
      return
    }
    if (!obj || typeof obj !== "object" || obj.ok !== true
        || !obj.prefs || typeof obj.prefs !== "object") {
      // The helper's one rejection detail ("InvalidPref") or nothing at all.
      root.prefsError = String((obj && obj.detail) || "prefs rejected")
      if (wasSet) root.prefsRejected()
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
      var wasSet = root._prefsWasSet
      root._prefsWasSet = false
      root.prefsError = "prefs helper timed out"
      if (wasSet) root.prefsRejected()
    }
  }

  // ---- custom card plumbing
  function runCustom() {
    // No command, or the card switched off in edit mode: nothing runs and any
    // card left over from the last configuration goes away with it.
    if (String(root.customCommand) === "" || !root.customEnabled) {
      root.customCard = null
      root.customError = ""
      return
    }
    if (customProcess.running) return
    _customOut = ""
    // The user's own command line, so it gets a shell — that is what a command
    // line is. Nothing here is interpolated into it.
    //
    // `head -c 8193` is a hard bound on what a runaway command can push into
    // this process: one byte past the cap is enough for applyCustom() to see it
    // is over and reject the output, and nothing bigger is ever buffered. The
    // QML-side check stays — it is what turns the excess into a message.
    //
    // Deliberately no `set -o pipefail`: it would apply inside the brace group
    // as well, and a perfectly good command line with an early-terminating pipe
    // of its own (`foo | head -5`, `x | grep -m1`) exits 141 on a benign
    // SIGPIPE. The tradeoff is that the command's own non-zero exit is masked
    // by head's 0 — acceptable, because what decides whether a card renders is
    // the *content*: over-cap is measured on the bytes collected, and anything
    // that is not a well-formed card fails the parse regardless of exit status.
    // The user's command line is passed via argv ($1), never spliced into the
    // wrapper source below — a value containing `}; anything; {` cannot escape
    // the parsed script this way, so the head -c cap always bounds output.
    customProcess.command = ["bash", "-c",
      "bash -c \"$1\" | head -c 8193", "garmin-custom", String(root.customCommand)]
    customProcess.running = true
    customWatchdog.restart()
  }

  // Property changes must not make every screen run somebody's script. The poll
  // path is gated by `canPoll()` (the owner's primary-instance test); the
  // command/enabled triggers below go through the same gate. `_started` keeps
  // them quiet until the bar has registered its widgets — before that every
  // instance still looks primary, which is exactly the fan-out being avoided.
  property bool _started: false

  function runCustomIfPrimary() {
    if (!root._started) return
    var allowed = false
    try {
      allowed = root.canPoll()
    } catch (e) {
      allowed = false
    }
    if (allowed) root.runCustom()
  }

  function customFail(detail) {
    root.customCard = null
    root.customError = String(detail || "")
  }

  // One short single-line string, or "". Everything on this path ends up in a
  // panel card or a bar tooltip, and the command's output is not ours: control
  // characters, newlines and unbounded length all get taken out here rather
  // than at each of the four places that render it.
  function customText(value, limit) {
    if (typeof value === "number" && isFinite(value)) value = String(value)
    if (typeof value !== "string") return ""
    var s = value.replace(/[\x00-\x1f\x7f]+/g, " ").replace(/^\s+|\s+$/g, "")
    return s.length > limit ? s.substring(0, limit) : s
  }

  // The exit code is advisory only — see runCustom() for why it cannot be
  // trusted as a verdict. It is appended to whatever the content check has to
  // say, so a script that both failed and printed nothing still names the code.
  function customFailWithCode(detail, exitCode) {
    root.customFail(Number(exitCode) ? detail + " (exited " + exitCode + ")" : detail)
  }

  function applyCustom(text, exitCode) {
    var raw = String(text || "")
    // `head -c 8193` guarantees this is the over-cap signal and the only one:
    // 8193 bytes collected means the command had at least one more to give.
    if (raw.length > root.customOutputCap) {
      root.customFail("command printed more than 8 KB")
      return
    }
    if (raw.replace(/^\s+|\s+$/g, "") === "") {
      root.customFailWithCode("command printed nothing", exitCode)
      return
    }
    var obj
    try {
      obj = JSON.parse(raw)
    } catch (e) {
      root.customFailWithCode("command output was not JSON", exitCode)
      return
    }
    // Arrays are objects in JS, and an array's `.title` is undefined, so this
    // would otherwise fall through to the missing-fields branch with a
    // misleading message.
    if (!obj || typeof obj !== "object" || obj.length !== undefined) {
      root.customFailWithCode("command output was not a JSON object", exitCode)
      return
    }
    var title = root.customText(obj.title, 40)
    var value = root.customText(obj.value, 24)
    if (title === "" || value === "") {
      root.customFailWithCode("output needs both title and value", exitCode)
      return
    }
    var tone = root.customText(obj.tone, 8)
    if (tone !== "accent" && tone !== "urgent") tone = ""

    // A meter is optional and only means anything with a positive max.
    var percent = -1
    var meter = obj.meter
    if (meter && typeof meter === "object") {
      var mv = Number(meter.value)
      var mx = Number(meter.max)
      if (isFinite(mv) && isFinite(mx) && mx > 0)
        percent = Math.max(0, Math.min(100, mv / mx * 100))
    }

    root.customError = ""
    root.customCard = {
      "title": title,
      "value": value,
      "caption": root.customText(obj.caption, 60),
      "tone": tone,
      "meterPercent": percent
    }
  }

  property string _customOut: ""

  Process {
    id: customProcess
    running: false
    command: []
    stdout: StdioCollector { id: customStdout; waitForEnd: true; onStreamFinished: root._customOut = text }
    onExited: function (exitCode, exitStatus) {
      var timedOut = customWatchdog.tripped
      customWatchdog.stop()
      customWatchdog.tripped = false
      if (timedOut) return
      // No exit-code gate: what the command printed is the verdict, and the
      // status of a pipeline ending in `head` is not the command's own. The
      // code is passed along only so a failure message can mention it.
      root.applyCustom(String(customStdout.text || root._customOut || ""), exitCode)
    }
  }

  Timer {
    id: customWatchdog
    property bool tripped: false
    interval: 10000
    repeat: false
    onTriggered: {
      if (!customProcess.running) return
      customWatchdog.tripped = true
      customProcess.running = false
      root.customFail("command timed out after 10s")
    }
  }

  onCustomCommandChanged: root.runCustomIfPrimary()
  onCustomEnabledChanged: root.runCustomIfPrimary()

  // Take a result the primary instance already paid for. Deliberately silent —
  // emitting `refreshed()` here would bounce the payload straight back out
  // through the publisher and loop the bar.
  // The custom card rides along: it is the primary that ran the command, and a
  // second screen re-running it would be a second copy of somebody's script on
  // every tick. `undefined` (an older peer) leaves this instance's card alone.
  function adopt(state, payload, lastError, customCard, customError) {
    root.payload = payload
    root.state = String(state)
    root.lastError = String(lastError || "")
    if (customCard !== undefined) root.customCard = customCard
    if (customError !== undefined) root.customError = String(customError || "")
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
    onTriggered: {
      // From here on `canPoll()` can tell primary from secondary, so the
      // custom-card property triggers are allowed to fire.
      root._started = true
      root.poll()
    }
  }
}
