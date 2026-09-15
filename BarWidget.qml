import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "kravens.btclock"

  // ---- settings -----------------------------------------------------------
  // Settings arrive from shell.json and are treated as input: every one is
  // clamped or matched against a closed set before it is used.
  readonly property int rotateSeconds: Math.min(3600, Math.max(2, parseInt(setting("rotateSeconds", 21), 10) || 21))
  readonly property int refreshSeconds: Math.min(3600, Math.max(15, parseInt(setting("refreshSeconds", 60), 10) || 60))
  // Only used while nothing can be reached: a dead instance is worth retrying
  // sooner than the full refresh interval.
  readonly property int retrySeconds: Math.min(600, Math.max(5, parseInt(setting("retrySeconds", 5), 10) || 5))
  // BTClock rev A/B drives seven e-paper panels, one character each.
  readonly property int cells: Math.max(3, Math.min(12, parseInt(setting("cells", 7), 10) || 7))
  readonly property bool lightMode: String(setting("mode", "dark")).toLowerCase() === "light"

  readonly property string currency: {
    var c = String(setting("currency", "USD")).toUpperCase()
    return /^[A-Z]{3}$/.test(c) ? c : "USD"
  }

  // A switch rather than a map lookup: the key comes from configuration, and
  // indexing an object with an arbitrary string reaches Object.prototype.
  readonly property string symbol: {
    switch (currency) {
    case "USD": return "$"
    case "EUR": return "€"
    case "GBP": return "£"
    case "JPY": return "¥"
    case "CHF": return "₣"
    case "CAD": return "C$"
    case "AUD": return "A$"
    default: return currency
    }
  }

  // ---- the bar's own appearance --------------------------------------------
  // Double clicking the bar makes it see-through and picks a foreground colour
  // that stays legible over whatever wallpaper is behind it. Both arrive from the
  // shell as live bindings, so the panels can follow the bar in and out of
  // transparency instead of sitting on it as slabs of theme background.
  readonly property bool barTransparent: root.bar ? root.bar.transparent === true : false
  readonly property color barForeground: root.bar ? root.bar.barForeground : Color.foreground

  // Closed set of mempool instances bin/btc-status knows how to read. Keeping
  // the list here as well means a typo lands on the default instance instead of
  // reaching the helper, which ignores unknown names for the same reason.
  readonly property var providers: ["mempool.space", "mempool.emzy.de"]

  // The configured preference, not the only instance: every other one is a
  // fallback, tried when the preference cannot be reached.
  readonly property string preferred: {
    var p = String(setting("provider", "mempool.space")).toLowerCase()
    return providers.indexOf(p) !== -1 ? p : "mempool.space"
  }

  // Whoever answered last is asked first, the preference next, then the rest.
  // The preference stays in the order rather than being dropped, so a widget
  // running on a fallback moves back the moment the preference answers again;
  // and a run of failures behind a dead origin costs one connect timeout per
  // refresh instead of stalling every fetch.
  readonly property var providerOrder: {
    var first = [lastGood, preferred]
    var out = []
    for (var i = 0; i < first.length; i++) {
      if (first[i] && providers.indexOf(first[i]) !== -1 && out.indexOf(first[i]) === -1) out.push(first[i])
    }
    for (var j = 0; j < providers.length; j++) {
      if (out.indexOf(providers[j]) === -1) out.push(providers[j])
    }
    return out
  }

  // The one place a provider name is accepted from outside, closed-set matched.
  function providerId(value) {
    var p = String(value || "").toLowerCase()
    return providers.indexOf(p) !== -1 ? p : ""
  }

  // ---- state --------------------------------------------------------------
  readonly property int frameCount: 4
  readonly property int maxBytes: 65536

  property var payload: null
  property bool stale: false
  // No instance could be reached on the last refresh: the panels say so rather
  // than showing numbers that may be hours old.
  property bool unreachable: false
  // One notification per outage: the first failure announces it, and only a
  // successful fetch clears the flag.
  property bool notified: false
  // Consecutive failed cycles. One blip keeps whatever numbers are on the panels
  // where they are; the dash state and the toast are for an outage.
  property int failures: 0
  property string lastGood: ""
  property int manualOffset: 0
  property bool paused: false
  property int frozenFrame: 0
  property double now: Date.now()
  property string buf: ""

  readonly property real fiat: payload && payload.prices && typeof payload.prices[currency] === "number"
    ? payload.prices[currency]
    : (payload ? payload.usd : 0)

  // Derived from the wall clock rather than an accumulating counter, so every
  // monitor's instance lands on the same frame without any shared state.
  readonly property int frame: paused
    ? frozenFrame
    : (payload ? (Math.floor(root.now / (rotateSeconds * 1000)) + manualOffset) % frameCount : 0)

  // Resolved next to this file, so the plugin works from any install path and
  // never depends on PATH or a hard-coded home directory.
  readonly property string helper: Qt.resolvedUrl("bin/btc-status").toString().replace(/^file:\/\//, "")

  // ---- formatting ---------------------------------------------------------
  // BTClock groups long numbers with spaces: "966 251", "1 269".
  function group(value) {
    var s = String(value)
    var out = ""
    for (var i = s.length - 1, c = 0; i >= 0; i--) {
      out = s.charAt(i) + out
      if (++c % 3 === 0 && i > 0) out = " " + out
    }
    return out
  }

  // Sats per unit of the selected fiat, as the device does it.
  function moscowTime() {
    return fiat > 0 ? Math.round(100000000 / fiat) : 0
  }

  // "1 270/$". Drops the digit grouping rather than the currency symbol if a
  // cheap bitcoin ever pushes the figure past the panel count.
  function moscowText() {
    var n = moscowTime()
    var full = group(n) + "/" + symbol
    return full.length <= cells ? full : n + "/" + symbol
  }

  // Longest form that still fits the panels wins, mirroring BTClock's
  // suffixPrice mode for currencies too large to spell out (JPY).
  function money() {
    var n = Math.round(fiat)
    var full = symbol + group(n)
    if (full.length <= cells) return full
    var unit = n >= 1000000 ? "M" : "k"
    var div = n >= 1000000 ? 1000000 : 1000
    var one = symbol + (n / div).toFixed(1) + unit
    if (one.length <= cells) return one
    return symbol + Math.round(n / div) + unit
  }

  // One panel per character, so these are written to fit `cells` exactly.
  function frameText() {
    if (!payload) return ""
    switch (frame) {
    case 0: return "₿" + payload.height
    case 1: return money()
    case 2: return moscowText()
    default: return payload.low + "/" + payload.med + "/" + payload.high
    }
  }

  // ---- panel colours -------------------------------------------------------
  // Normally a panel is a little e-paper screen: dark on the theme background in
  // dark mode, inverted in light mode. While the bar is transparent a panel is an
  // outline instead, drawn in the bar's own contrast colour at low alpha and with
  // the character in that same colour - the treatment the rest of the bar gets -
  // so nothing hangs over the wallpaper in a colour picked for a solid bar.
  function panelFill() {
    if (root.barTransparent) return "transparent"
    return root.lightMode ? Color.foreground : Qt.darker(Color.background, 1.6)
  }

  function panelBorder() {
    if (root.barTransparent) return Util.alpha(root.barForeground, 0.4)
    return root.lightMode
      ? Qt.darker(Color.foreground, 1.25)
      : Qt.rgba(Color.muted.r, Color.muted.g, Color.muted.b, 0.55)
  }

  function panelInk() {
    if (root.barTransparent) return root.barForeground
    return root.lightMode ? Color.background : Color.foreground
  }

  // Centre the string across the panels, blanks either side.
  function cellChars() {
    var n = root.cells
    // Every instance failed: all seven panels show a dash, which reads as one
    // state instead of blank panels that look like a rendering fault.
    if (root.unreachable) {
      var dashes = []
      for (var d = 0; d < n; d++) dashes.push("-")
      return dashes
    }
    var s = frameText()
    if (s.length > n) s = s.substring(0, n)
    var left = Math.floor((n - s.length) / 2)
    var out = []
    for (var i = 0; i < n; i++) {
      var j = i - left
      out.push(j >= 0 && j < s.length ? s.charAt(j) : "")
    }
    return out
  }

  // bar.showTooltip is rendered by the shell with AutoText, which this plugin
  // cannot pin to PlainText, so markup characters and control codes are
  // removed and the length is capped before handoff.
  function plain(value) {
    return String(value)
      .replace(/[<>&]/g, "")
      .replace(/[\u0000-\u001f\u007f-\u009f\u200e\u200f\u202a-\u202e\u2066-\u2069]/g, "")
      .substring(0, 200)
  }

  function tooltip() {
    if (root.unreachable) {
      return plain("Cannot reach " + providerOrder.join(" or ") + "  ·  retrying every " + retrySeconds + "s")
    }
    if (!payload) return ""
    return plain("Block " + group(payload.height)
      + "  ·  " + symbol + group(Math.round(fiat)) + " " + currency
      + "  ·  " + group(moscowTime()) + " sat/" + symbol
      + "  ·  fees " + payload.low + "/" + payload.med + "/" + payload.high + " sat/vB"
      + (payload.provider && payload.provider !== "mempool.space" ? "  ·  " + payload.provider : "")
      + (paused ? "  ·  paused" : "")
      + (stale ? "  ·  stale" : ""))
  }

  // ---- data ---------------------------------------------------------------
  function finite(value, low, high) {
    return typeof value === "number" && isFinite(value) && value >= low && value <= high
  }

  // The helper's output is input like any other: shape, types and ranges are
  // checked here too, and the whole document is rejected rather than repaired.
  function applyPayload(raw) {
    var text = String(raw || "").trim()
    if (!text || text.length > maxBytes) return false

    var parsed
    try {
      parsed = JSON.parse(text)
    } catch (e) {
      return false
    }
    if (!parsed || typeof parsed !== "object" || !finite(parsed.height, 0, 1e9)) return false

    // Null-prototype map: these keys came off the wire.
    var prices = Object.create(null)
    var kept = 0
    if (parsed.prices && typeof parsed.prices === "object") {
      var keys = Object.keys(parsed.prices)
      for (var i = 0; i < keys.length && kept < 10; i++) {
        var k = keys[i]
        if (!/^[A-Z]{3}$/.test(k)) continue
        if (!finite(parsed.prices[k], 0.000001, 1e12)) continue
        prices[k] = parsed.prices[k]
        kept++
      }
    }

    root.stale = parsed.ok !== true
    root.payload = {
      height: Math.floor(parsed.height),
      prices: prices,
      usd: finite(parsed.usd, 0, 1e12) ? parsed.usd : 0,
      low: finite(parsed.low, 0, 100000) ? Math.floor(parsed.low) : 0,
      med: finite(parsed.med, 0, 100000) ? Math.floor(parsed.med) : 0,
      high: finite(parsed.high, 0, 100000) ? Math.floor(parsed.high) : 0,
      provider: providerId(parsed.provider)
    }
    return true
  }

  function refresh() {
    if (!statusProc.running) statusProc.running = true
  }

  // One notification per outage: a bar widget that quietly shows dashes is
  // easier to miss than the numbers it stopped showing. The shell's own
  // notification helper is used, so the message respects Do Not Disturb and is
  // formatted like everything else on this desktop.
  function notifyUnreachable() {
    if (notified) return
    // A bar surface exists per monitor, so this widget is live once per screen
    // and every instance sees the same outage: without this, two monitors mean
    // two identical toasts. Only the first live instance speaks - the same
    // slot-ordered lookup the base class uses to broadcast, with the same
    // fallback for a host that cannot enumerate peers, so a widget that really
    // is on its own still gets to say so.
    var peers = bar && typeof bar.moduleWidgets === "function" ? bar.moduleWidgets(moduleName) : [root]
    if (peers[0] !== root) return
    var base = String(Quickshell.env("OMARCHY_PATH") || "")
    if (!base) return
    notified = true
    // An argv vector through the shell's own runner: nothing here is ever
    // re-tokenized, even if a future provider name were to contain a space.
    Util.execArgv([
      base + "/bin/omarchy-notification-send",
      "-u", "normal",
      "--app-name", "BTClock",
      "BTClock cannot reach a mempool instance",
      "Tried " + providerOrder.join(", ") + ". Retrying every " + retrySeconds + "s."])
  }

  function advance() {
    if (paused) frozenFrame = (frozenFrame + 1) % frameCount
    else manualOffset = (manualOffset + 1) % frameCount
  }

  function retreat() {
    if (paused) frozenFrame = (frozenFrame + frameCount - 1) % frameCount
    else manualOffset = (manualOffset + frameCount - 1) % frameCount
  }

  // BTClock's button 1: hold one screen instead of rotating.
  function togglePause() {
    if (!paused) frozenFrame = frame
    paused = !paused
  }

  // Visible for the dashes too: a widget that has nothing to report is worth
  // seeing, or its absence is indistinguishable from a plugin that is not
  // installed.
  visible: payload !== null || unreachable
  implicitWidth: vertical ? barSize : strip.width + Style.spaceReal(6)
  implicitHeight: vertical ? strip.height + Style.spaceReal(6) : barSize

  // Parameterless and non-destructive: both only trigger the widget's own
  // ordinary behaviour.
  IpcHandler {
    target: "kravens.btclock"

    function refresh(): void {
      root.broadcast("refresh")
    }

    function pause(): void {
      root.broadcast("togglePause")
    }
  }

  Process {
    id: statusProc
    // Absolute paths only. setsid gives the fetch its own process group and
    // timeout an absolute deadline with KILL escalation, so nothing is left
    // behind when a request hangs. The instance order is the only value passed
    // on, and the helper matches each name against its own closed set.
    command: ["/usr/bin/setsid", "-w", "/usr/bin/timeout", "-k", "2", "--", "30",
              "/usr/bin/bash", root.helper, "--providers", root.providerOrder.join(",")]

    // SplitParser with an empty marker delivers raw chunks, so the budget is
    // enforced while the data arrives instead of after it is all in memory.
    stdout: SplitParser {
      splitMarker: ""
      onRead: function (chunk) {
        if (root.buf.length + chunk.length > root.maxBytes) {
          root.buf = ""
          statusProc.signal(15)
          killTimer.restart()
          return
        }
        root.buf += chunk
      }
    }

    onExited: function (code, status) {
      killTimer.stop()
      var raw = root.buf
      root.buf = ""
      if (code === 0 && root.applyPayload(raw)) {
        // An instance answered: the panels are live again, and the next outage
        // is news the user has not had yet.
        root.unreachable = false
        root.notified = false
        root.failures = 0
        root.lastGood = providerId(root.payload.provider) || root.lastGood
        return
      }
      // The helper only exits non-zero once it has run out of instances to try,
      // so this is every instance failing at once - or one of them answering
      // with a document that could not be trusted, which is the same thing as
      // far as the bar is concerned: no data.
      //
      // Counted rather than acted on at once: one unanswered cycle is usually a
      // blip, and replacing the panels with dashes for it throws away an answer
      // that is well under a refresh old. The second in a row is an outage worth
      // saying out loud.
      root.failures += 1
      if (root.failures >= 2) {
        root.unreachable = true
        root.notifyUnreachable()
      } else if (root.payload) {
        root.stale = true
      } else {
        // Nothing on the panels to keep: the one case where a single failure has
        // to show the dash state anyway, because a blank widget cannot be told
        // apart from one that is not installed. It still waits for the retry
        // before it notifies.
        root.unreachable = true
      }
      retryTimer.restart()
    }
  }

  Timer {
    id: killTimer
    interval: 2000
    repeat: false
    onTriggered: statusProc.signal(9)
  }

  Timer {
    interval: root.refreshSeconds * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    id: retryTimer
    interval: root.retrySeconds * 1000
    repeat: false
    onTriggered: root.refresh()
  }

  Timer {
    interval: 1000
    running: !root.paused
    repeat: true
    onTriggered: root.now = Date.now()
  }

  // ---- rendering ----------------------------------------------------------
  Row {
    id: strip
    anchors.centerIn: parent
    spacing: Math.max(1, Math.round(root.barSize * 0.10))
    // Dimmed while the numbers are stale, and while there are no numbers at
    // all, so the panels never read as current when they are not.
    opacity: (root.stale || root.unreachable) ? 0.45 : 1

    readonly property real cellHeight: Math.max(10, root.barSize - Style.spaceReal(7))
    readonly property real cellWidth: Math.round(cellHeight * 0.74)

    Behavior on opacity {
      NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
    }

    Repeater {
      model: root.cells

      Rectangle {
        width: strip.cellWidth
        height: strip.cellHeight
        radius: Math.max(1, Math.round(strip.cellWidth * 0.12))
        // Each panel is its own little screen, inverted in light mode, and an
        // outline while the bar is transparent.
        color: root.panelFill()
        border.width: 1
        border.color: root.panelBorder()
        // The bar fades in and out of transparency; the panels fade with it,
        // using the bar's own duration and easing.
        Behavior on color {
          enabled: !root.bar || root.bar.foregroundAnimationEnabled
          ColorAnimation { duration: 420; easing.type: Easing.InOutCubic }
        }

        Behavior on border.color {
          enabled: !root.bar || root.bar.foregroundAnimationEnabled
          ColorAnimation { duration: 420; easing.type: Easing.InOutCubic }
        }

        Text {
          anchors.centerIn: parent
          // Pinned on every Text, literal or not, so the invariant is auditable.
          textFormat: Text.PlainText
          text: root.cellChars()[index] || ""
          color: root.panelInk()
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Math.max(7, Math.round(strip.cellHeight * 0.74))
          renderType: Text.NativeRendering

          Behavior on color {
            enabled: !root.bar || root.bar.foregroundAnimationEnabled
            ColorAnimation { duration: 420; easing.type: Easing.InOutCubic }
          }
        }
      }
    }
  }

  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor

    // Mirrors BTClock's buttons: 1 pauses, 2 advances, 3 goes back.
    onClicked: function (mouse) {
      if (root.bar) root.bar.hideTooltip(root)
      if (mouse.button === Qt.LeftButton) root.broadcast("togglePause")
      else if (mouse.button === Qt.MiddleButton) root.broadcast("refresh")
      else root.broadcast("advance")
    }
    onWheel: function (wheel) {
      root.broadcast(wheel.angleDelta.y > 0 ? "advance" : "retreat")
    }
    onEntered: if (root.bar) root.bar.showTooltip(root, root.tooltip())
    onExited: if (root.bar) root.bar.hideTooltip(root)
  }

  // Keep bar drag-to-reorder working, the way WidgetButton does.
  property var registeredBar: null
  function syncClickRegistration() {
    if (registeredBar && registeredBar.unregisterClickTarget) registeredBar.unregisterClickTarget(root)
    registeredBar = root.bar
    if (registeredBar && registeredBar.registerClickTarget) registeredBar.registerClickTarget(root)
  }
  onBarChanged: syncClickRegistration()
  Component.onCompleted: syncClickRegistration()
  Component.onDestruction: {
    if (registeredBar && registeredBar.unregisterClickTarget) registeredBar.unregisterClickTarget(root)
    statusProc.signal(15)
  }
}
