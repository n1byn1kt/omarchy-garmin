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
  property string state: "loading"

  // Last payload we were happy with, kept across later failures so an offline
  // blip keeps showing yesterday's numbers instead of blanking the chip.
  property var data: null

  property string lastError: ""
  property int pollMinutes: 30

  // Every error code the helper is allowed to emit. Anything outside this set
  // is a helper we do not understand, which is an api-error by definition.
  readonly property var knownErrors: ["deps", "no-tokens", "auth-expired", "offline", "api-error"]

  readonly property bool busy: fetchProcess.running

  // The helper ships inside the plugin directory, so it is located relative to
  // this file rather than through PATH — the plugin must work unpacked
  // anywhere under ~/.config/omarchy/plugins/.
  readonly property string helperPath:
    decodeURIComponent(String(Qt.resolvedUrl("bin/garmin-widget")).replace(/^file:\/\//, ""))

  signal refreshed()

  function refresh() {
    if (fetchProcess.running) return
    _stdout = ""
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
      root.data = payload
      root.lastError = ""
      root.state = payload.stale === true ? "stale" : "live"
      root.refreshed()
      return
    }

    var code = String(payload.error || "")
    if (root.knownErrors.indexOf(code) === -1) code = "api-error"
    root.fail(code, String(payload.detail || payload.hint || payload.error || ""))
  }

  // A failure never discards `data`. Losing the network is not a reason to
  // forget this morning's Body Battery — it is a reason to mark it stale.
  function fail(code, detail) {
    root.lastError = detail
    root.state = (code === "offline" && root.data !== null) ? "stale" : code
    root.refreshed()
  }

  property string _stdout: ""

  Process {
    id: fetchProcess
    running: false
    command: []
    stdout: StdioCollector { id: fetchStdout; waitForEnd: true; onStreamFinished: root._stdout = text }
    onExited: {
      watchdog.stop()
      root.applyPayload(String(fetchStdout.text || root._stdout || ""))
    }
  }

  // The helper has its own network timeouts, but a wedged subprocess would
  // otherwise block every later refresh through the `running` guard. Cutting
  // it loose leaves the last good data on screen and lets the next tick try.
  Timer {
    id: watchdog
    interval: 45000
    repeat: false
    onTriggered: if (fetchProcess.running) fetchProcess.running = false
  }

  Timer {
    id: pollTimer
    // Floored rather than trusted: a mis-typed pollMinutes of 0 would hammer
    // Garmin's API from a widget nobody is looking at.
    interval: Math.max(5, Number(root.pollMinutes) || 30) * 60 * 1000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  Component.onCompleted: root.refresh()
}
