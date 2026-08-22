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

  function refresh() {
    if (root.service && typeof root.service.refresh === "function") root.service.refresh()
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
  readonly property var payload: root.service ? root.service.data : null
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
  readonly property string depsCommand: "pip install garminconnect"

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
    var d = new Date(s)
    return isNaN(d.getTime()) ? s : Qt.formatDateTime(d, "HH:mm")
  }

  property bool copied: false

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

  // ---- Payload accessors (every one tolerates a missing branch)
  readonly property var bodyBattery: root.payload && root.payload.bodyBattery ? root.payload.bodyBattery : null
  readonly property var sleepInfo: root.payload && root.payload.sleep ? root.payload.sleep : null
  readonly property var stepsInfo: root.payload && root.payload.steps ? root.payload.steps : null

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
  readonly property string stepsValue:
    !root.hasSteps ? "—" : root.fmtSteps(root.stepsCount) + " / " + root.fmtSteps(root.stepsGoal)
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

  // Rows are data, not markup: one model keeps the label column aligned and
  // makes "which rows exist" a single readable list.
  readonly property var detailRows: [
    { "label": "Body Battery", "value": root.batteryValue, "meta": root.batteryMeta, "bar": false },
    { "label": "Sleep", "value": root.sleepValue, "meta": "", "bar": false },
    { "label": "Steps", "value": root.stepsValue, "meta": "", "bar": true },
    { "label": "Resting HR", "value": root.restingHrValue, "meta": "", "bar": false }
  ]

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
    // Wide enough for the full helper path on two lines rather than three;
    // fittedContentWidth still shrinks it on a narrow screen.
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.refresh()
        else if ((t === "c" || t === "C") && root.showGuidance) root.copy(root.guidanceCommand)
      }

      Column {
        id: column
        width: parent.width
        spacing: Style.space(12)

        PanelHero {
          width: parent.width
          title: "Garmin"
          meta: root.heroMeta
          foreground: root.foreground
          fontFamily: root.fontFamily
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
          visible: root.showGuidance
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
              color: Style.normalFill
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
          visible: root.showUnreachable
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
          visible: root.showLoading
          width: parent.width
          text: "Checking…"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }

        // ---- Detail rows: live / stale
        Column {
          id: rowsColumn
          visible: root.showRows
          width: parent.width
          spacing: Style.space(10)

          // No section header here: the hero already says "Today", and two
          // TODAY labels stacked on top of each other just read as a bug.
          PanelSeparator { foreground: root.foreground }

          Repeater {
            model: root.detailRows

            // Label left, value right, with an optional goal bar underneath —
            // the same two-column read on every row, so the numbers line up
            // into one scannable column.
            Column {
              id: row
              required property var modelData

              width: rowsColumn.width
              spacing: Style.space(4)

              Item {
                width: parent.width
                implicitHeight: Math.max(rowLabel.implicitHeight, rowValue.implicitHeight)

                Text {
                  id: rowLabel
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  text: row.modelData.label
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }

                Row {
                  id: rowValue
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(8)

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: text !== ""
                    text: row.modelData.meta
                    color: Qt.darker(root.foreground, 2.0)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: row.modelData.value
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }
                }
              }

              // Thin progress track against the step goal. Hidden when there is
              // no step count at all, so an empty track never implies "zero
              // steps today".
              Rectangle {
                visible: row.modelData.bar === true && root.hasSteps
                width: parent.width
                height: Math.max(2, Style.space(3))
                radius: height / 2
                color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)

                Rectangle {
                  width: parent.width * root.stepsProgress
                  height: parent.height
                  radius: parent.radius
                  color: root.showStale ? root.dim : root.accentColor
                  Behavior on width { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
                }
              }
            }
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
            text: root.busy ? "Refreshing…" : root.asOfText
            color: root.showStale ? root.urgentColor : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Button {
            id: refreshButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: "Refresh"
            enabled: !root.busy
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
