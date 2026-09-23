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
  //
  // The settings panel writes through `omarchy bar set`, which lands back here
  // a moment later as a new `settings` object. Until it does, the value just
  // chosen is held in `pending`, so a switch flips the instant it is clicked.
  property var pending: ({})
  // Deferred: clearing it while bindings are still reading the new settings
  // would re-enter them.
  onSettingsChanged: Qt.callLater(function () { root.pending = ({}) })

  function opt(name, fallback) {
    return pending[name] !== undefined ? pending[name] : setting(name, fallback)
  }

  // `omarchy bar set` without --json stores every value as a string.
  function flag(name, fallback) {
    var v = opt(name, fallback)
    return v === true || v === "true"
  }

  readonly property int rotateSeconds: Math.min(3600, Math.max(2, parseInt(opt("rotateSeconds", 21), 10) || 21))
  readonly property int refreshSeconds: Math.min(3600, Math.max(15, parseInt(opt("refreshSeconds", 60), 10) || 60))
  // Only used while nothing can be reached: a dead instance is worth retrying
  // sooner than the full refresh interval.
  readonly property int retrySeconds: Math.min(600, Math.max(5, parseInt(opt("retrySeconds", 5), 10) || 5))
  // BTClock rev A/B drives seven e-paper panels, one character each.
  readonly property int cells: Math.max(3, Math.min(12, parseInt(opt("cells", 7), 10) || 7))
  readonly property bool lightMode: String(opt("mode", "dark")).toLowerCase() === "light"

  // What the device does when a block arrives: `stealFocus` jumps to the block
  // height, `ledFlashOnUpd` flashes the LEDs. The notification is this
  // widget's own addition, off by default.
  readonly property bool stealFocus: flag("stealFocus", true)
  readonly property bool blockFlash: flag("blockFlash", true)
  readonly property bool blockNotify: flag("blockNotify", false)

  readonly property var currencies: ["USD", "EUR", "GBP", "JPY", "CHF", "CAD", "AUD"]

  readonly property string currency: {
    var c = String(opt("currency", "USD")).toUpperCase()
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

  // A Bitaxe on the local network, as a bare host or IPv4 address with an
  // optional port. bin/btc-status applies the same pattern again.
  // A function, not a property: a RegExp stored in a QML property becomes a
  // QRegularExpression, which has no test().
  function validHost(h) {
    return /^[A-Za-z0-9][A-Za-z0-9.-]{0,252}(:[0-9]{1,5})?$/.test(h)
  }
  readonly property string bitaxeHost: {
    var h = String(opt("bitaxeHost", "")).trim()
    return validHost(h) ? h : ""
  }

  // ---- screens --------------------------------------------------------------
  // The closed set, in the order a fresh screen list offers them. Ids are what
  // shell.json stores; the glyphs are the Material Design icons the firmware
  // itself puts on its panels, which every Omarchy Nerd Font carries.
  readonly property var catalogue: [
    { id: "height", name: "Block height" },
    { id: "price", name: "Price" },
    { id: "moscow", name: "Moscow time" },
    { id: "fees", name: "Fee rates" },
    { id: "nextfee", name: "Next block fee" },
    { id: "halving", name: "Halving countdown" },
    { id: "mcap", name: "Market cap" },
    { id: "supply", name: "Supply" },
    { id: "bitaxeHash", name: "Bitaxe hashrate" },
    { id: "bitaxeBest", name: "Bitaxe best difficulty" }
  ]
  readonly property var defaultScreens: ["height", "price", "moscow", "fees"]

  function screenName(id) {
    for (var i = 0; i < catalogue.length; i++) if (catalogue[i].id === id) return catalogue[i].name
    return ""
  }

  // The rotation as configured: known ids only, each once. Stored as a
  // space-separated string, because `qs ipc call` - which `omarchy bar set`
  // goes through - splits every argument on commas, so a JSON array cannot
  // survive the trip. Commas and arrays are still read, for hand edits.
  readonly property var screens: {
    var raw = opt("screens", defaultScreens)
    var list = Array.isArray(raw) ? raw : String(raw).split(/[\s,]+/)
    var out = []
    for (var i = 0; i < list.length && out.length < catalogue.length; i++) {
      var id = String(list[i]).trim()
      if (screenName(id) && out.indexOf(id) === -1) out.push(id)
    }
    return out.length ? out : defaultScreens
  }

  readonly property bool wantsBitaxe: bitaxeHost !== ""
    && (screens.indexOf("bitaxeHash") !== -1 || screens.indexOf("bitaxeBest") !== -1)

  // The rotation as shown: a screen with nothing to say (no Bitaxe configured,
  // no price yet) is skipped rather than showing blank panels.
  readonly property var activeScreens: {
    var out = []
    for (var i = 0; i < screens.length; i++) if (available(screens[i])) out.push(screens[i])
    return out.length ? out : ["height"]
  }

  function available(id) {
    if (!payload) return false
    switch (id) {
    case "price":
    case "moscow":
    case "mcap": return fiat > 0
    case "nextfee": return payload.next !== null
    case "bitaxeHash": return payload.bitaxe !== null
    case "bitaxeBest": return payload.bitaxe !== null && payload.bitaxe.best !== null
    default: return true
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
    var p = String(opt("provider", "mempool.space")).toLowerCase()
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
  // Paused on a screen by id, not by position, so enabling or reordering
  // screens leaves the held one where it is.
  property string frozenId: ""
  property double now: Date.now()
  property string buf: ""
  // Highest block seen, so a failover to an instance one block behind is not
  // mistaken for a new block when the leader answers again.
  property int lastHeight: 0
  // Until this wall-clock time the block height holds the panels: the
  // firmware's stealFocus, which also restarts the rotation timer.
  property double focusUntil: 0
  // 0..1, driven by flashAnim: how far the panels are tinted towards the accent.
  property real flash: 0

  readonly property real fiat: payload && payload.prices && typeof payload.prices[currency] === "number"
    ? payload.prices[currency]
    : (payload ? payload.usd : 0)

  // Derived from the wall clock rather than an accumulating counter, so every
  // monitor's instance lands on the same screen without any shared state.
  readonly property string currentId: {
    if (!payload) return ""
    if (now < focusUntil) return "height"
    var list = activeScreens
    if (paused) return list.indexOf(frozenId) !== -1 ? frozenId : list[0]
    var n = list.length
    return list[((Math.floor(now / (rotateSeconds * 1000)) + manualOffset) % n + n) % n]
  }

  // Resolved next to this file, so the plugin works from any install path and
  // never depends on PATH or a hard-coded home directory.
  readonly property string helper: Qt.resolvedUrl("bin/btc-status").toString().replace(/^file:\/\//, "")

  // ---- formatting ---------------------------------------------------------
  // Panels hold one character each, and the icon glyphs sit outside the Basic
  // Multilingual Plane, so strings are measured in code points, not UTF-16.
  // Matched by hand: Qt's engine iterates strings by UTF-16 unit, so
  // Array.from would split each glyph across two panels.
  function chars(s) {
    return String(s).match(/[\uD800-\uDBFF][\uDC00-\uDFFF]|[\s\S]/g) || []
  }

  function fits(s) {
    return chars(s).length <= cells
  }

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

  readonly property var moneyUnits: [["T", 1e12], ["B", 1e9], ["M", 1e6], ["k", 1e3]]
  readonly property var siUnits: [["P", 1e15], ["T", 1e12], ["G", 1e9], ["M", 1e6], ["K", 1e3]]

  // "4.29G": the most precision that still fits the panels, trailing zeros
  // dropped - the firmware's formatNumberWithSuffix.
  function compact(prefix, n, units) {
    for (var i = 0; i < units.length; i++) {
      if (n < units[i][1]) continue
      var best = ""
      for (var d = 2; d >= 0; d--) {
        var s = prefix + String(Number((n / units[i][1]).toFixed(d))) + units[i][0]
        if (fits(s)) return s
        best = s
      }
      return best
    }
    return prefix + Math.round(n)
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
    return fits(full) ? full : n + "/" + symbol
  }

  // Longest form that still fits the panels wins, mirroring BTClock's
  // suffixPrice mode for currencies too large to spell out (JPY).
  function money() {
    var n = Math.round(fiat)
    var full = symbol + group(n)
    return fits(full) ? full : compact(symbol, n, moneyUnits)
  }

  // Coins issued once the block at `height` is mined: 50 BTC per block, halved
  // every 210 000 blocks, in whole satoshis the way the protocol rounds them.
  function supplyAt(height) {
    var sats = 0
    var reward = 5000000000
    for (var left = height + 1; left > 0 && reward > 0; left -= 210000) {
      sats += Math.min(left, 210000) * reward
      reward = Math.floor(reward / 2)
    }
    return sats / 100000000
  }

  function blocksToHalving() {
    return payload ? 210000 - payload.height % 210000 : 0
  }

  // "~1y 202d" at ten minutes a block, the firmware's own estimate.
  function halvingEta() {
    var days = Math.round(blocksToHalving() * 10 / 1440)
    var years = Math.floor(days / 365)
    return "~" + (years > 0 ? years + "y " : "") + (days % 365) + "d"
  }

  // The firmware shows two decimals below 10 sat/vB.
  function feeRate(v) {
    return v < 10 ? v.toFixed(2) : String(Math.round(v))
  }

  // AxeOS reports hashrate in GH/s.
  function hashText(prefix) {
    return compact(prefix, payload.bitaxe.hash * 1e9, siUnits)
  }

  // Written to fit `cells`: one panel per character.
  function screenText(id) {
    if (!payload || !available(id)) return ""
    switch (id) {
    case "height": return "₿" + payload.height
    case "price": return money()
    case "moscow": return moscowText()
    case "fees": return payload.low + "/" + payload.med + "/" + payload.high
    case "nextfee": return "󰊘" + feeRate(payload.next)
    case "halving":
      var g = "󰚭" + group(blocksToHalving())
      return fits(g) ? g : "󰚭" + blocksToHalving()
    case "mcap": return compact(symbol, supplyAt(payload.height) * fiat, moneyUnits)
    case "supply": return compact("₿", supplyAt(payload.height), [["M", 1e6]])
    case "bitaxeHash": return hashText("󰢷")
    case "bitaxeBest": return compact("󰑣", payload.bitaxe.best, siUnits)
    }
    return ""
  }

  // The same value spelled out, for the tooltip and the settings panel.
  function screenLong(id) {
    if (!payload || !available(id)) return ""
    switch (id) {
    case "height": return "Block " + group(payload.height)
    case "price": return symbol + group(Math.round(fiat)) + " " + currency
    case "moscow": return group(moscowTime()) + " sat/" + symbol
    case "fees": return "fees " + payload.low + "/" + payload.med + "/" + payload.high + " sat/vB"
    case "nextfee": return "next block " + feeRate(payload.next) + " sat/vB"
    case "halving": return "halving in " + group(blocksToHalving()) + " blocks, " + halvingEta()
    case "mcap": return "market cap " + compact(symbol, supplyAt(payload.height) * fiat, moneyUnits)
    case "supply":
      var s = supplyAt(payload.height)
      return "supply " + group(Math.floor(s)) + " BTC, " + (s / 210000).toFixed(2) + "%"
    case "bitaxeHash": return "Bitaxe " + hashText("") + "H/s"
    case "bitaxeBest": return "best difficulty " + compact("", payload.bitaxe.best, siUnits)
    }
    return ""
  }

  // ---- panel colours -------------------------------------------------------
  // Normally a panel is a little e-paper screen: dark on the theme background in
  // dark mode, inverted in light mode. While the bar is transparent a panel is an
  // outline instead, drawn in the bar's own contrast colour at low alpha and with
  // the character in that same colour - the treatment the rest of the bar gets -
  // so nothing hangs over the wallpaper in a colour picked for a solid bar.
  //
  // A new block tints every panel towards the theme accent, the bar's version
  // of the orange LED flash (blockFlashColor 0xE04300) on the device.
  // Light mode on a transparent bar inverts the outline: panels filled solid
  // in the bar's contrast colour, characters in whichever theme colour stands
  // out against it.
  function panelFill(solid) {
    var a = Color.accent
    var flashTint = Qt.rgba(a.r, a.g, a.b, root.flash * 0.85)
    if (root.barTransparent && !solid) {
      if (!root.lightMode) return Qt.rgba(a.r, a.g, a.b, root.flash * 0.8)
      var fg = root.barForeground
      return root.flash > 0 ? Qt.tint(fg, flashTint) : fg
    }
    var base = root.lightMode ? Color.foreground : Qt.darker(Color.background, 1.6)
    return root.flash > 0 ? Qt.tint(base, flashTint) : base
  }

  function panelBorder(solid) {
    if (root.barTransparent && !solid) return Util.alpha(root.barForeground, root.lightMode ? 0.9 : 0.4)
    return root.lightMode
      ? Qt.darker(Color.foreground, 1.25)
      : Qt.rgba(Color.muted.r, Color.muted.g, Color.muted.b, 0.55)
  }

  function panelInk(solid) {
    if (root.barTransparent && !solid) {
      if (!root.lightMode) return root.barForeground
      return root.barForeground.hslLightness > 0.5 ? Color.background : Color.foreground
    }
    return root.lightMode ? Color.background : Color.foreground
  }

  // Centre the string across the panels, blanks either side.
  function cellChars() {
    var n = root.cells
    var out = []
    // Every instance failed: all seven panels show a dash, which reads as one
    // state instead of blank panels that look like a rendering fault.
    if (root.unreachable) {
      for (var d = 0; d < n; d++) out.push("-")
      return out
    }
    var s = chars(screenText(currentId)).slice(0, n)
    var left = Math.floor((n - s.length) / 2)
    for (var i = 0; i < n; i++) {
      var j = i - left
      out.push(j >= 0 && j < s.length ? s[j] : "")
    }
    return out
  }

  // bar.showTooltip is rendered by the shell with AutoText, which this plugin
  // cannot pin to PlainText, so markup characters and control codes are
  // removed and the length is capped before handoff.
  function plain(value) {
    return String(value)
      .replace(/[<>&]/g, "")
      .replace(/[\u0000-\u001f\u007f-\u009f‎‏‪-‮⁦-⁩]/g, "")
      .substring(0, 400)
  }

  function statusLine() {
    if (root.unreachable) return "Cannot reach " + providerOrder.join(" or ") + ", retrying every " + retrySeconds + "s"
    if (!payload) return "Loading"
    return (payload.provider ? "via " + payload.provider : "")
      + (paused ? "  ·  paused" : "")
      + (stale ? "  ·  stale" : "")
  }

  function tooltip() {
    if (root.unreachable) return plain(statusLine())
    if (!payload) return ""
    var parts = []
    for (var i = 0; i < activeScreens.length; i++) parts.push(screenLong(activeScreens[i]))
    return plain(parts.join("  ·  ")
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
  // The optional parts - next block fee, tip block, Bitaxe - fall back to null
  // on their own, since each has its own way of being absent.
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

    var b = parsed.block
    var block = b && typeof b === "object" && finite(b.height, 0, 1e9) ? {
      height: Math.floor(b.height),
      tx: finite(b.tx, 0, 1e7) ? Math.floor(b.tx) : 0,
      median: finite(b.median, 0, 100000) ? b.median : null,
      pool: typeof b.pool === "string" && /^[A-Za-z0-9 .+_-]{0,32}$/.test(b.pool) ? b.pool : ""
    } : null

    var m = parsed.bitaxe
    var bitaxe = m && typeof m === "object" && finite(m.hash, 0, 1e9) ? {
      hash: m.hash,
      best: finite(m.best, 0, 1e21) ? m.best : null
    } : null

    root.stale = parsed.ok !== true
    root.payload = {
      height: Math.floor(parsed.height),
      prices: prices,
      usd: finite(parsed.usd, 0, 1e12) ? parsed.usd : 0,
      low: finite(parsed.low, 0, 100000) ? Math.floor(parsed.low) : 0,
      med: finite(parsed.med, 0, 100000) ? Math.floor(parsed.med) : 0,
      high: finite(parsed.high, 0, 100000) ? Math.floor(parsed.high) : 0,
      next: finite(parsed.next, 0, 100000) ? parsed.next : null,
      block: block,
      bitaxe: bitaxe,
      provider: providerId(parsed.provider)
    }
    return true
  }

  // A refresh asked for mid-fetch runs once that fetch ends, so a setting
  // changed while one is in flight is not left waiting a whole interval.
  property bool refreshQueued: false

  function refresh() {
    if (statusProc.running) refreshQueued = true
    else statusProc.running = true
  }

  // Every live instance of this widget, one per monitor; `[root]` for a host
  // that cannot enumerate them.
  function peers() {
    return bar && typeof bar.moduleWidgets === "function" ? bar.moduleWidgets(moduleName) : [root]
  }

  // A bar surface exists per monitor, so this widget is live once per screen
  // and every instance sees the same event: without this, two monitors mean
  // two identical toasts. Only the first live instance speaks. An empty list
  // (this widget not yet an active slot item) must not silence it either.
  function speaksForPeers() {
    var list = peers()
    return !list.length || list[0] === root
  }

  // The shell's own notification helper is used, so the message respects Do
  // Not Disturb and is formatted like everything else on this desktop. An argv
  // vector through the shell's own runner: nothing is ever re-tokenized.
  function notify(summary, body) {
    var base = String(Quickshell.env("OMARCHY_PATH") || "")
    if (!base) return
    Util.execArgv([base + "/bin/omarchy-notification-send", "-u", "normal", "--app-name", "BTClock",
                   plain(summary), plain(body)])
  }

  // One notification per outage: a bar widget that quietly shows dashes is
  // easier to miss than the numbers it stopped showing.
  function notifyUnreachable() {
    if (notified || !speaksForPeers()) return
    notified = true
    notify("BTClock cannot reach a mempool instance",
           "Tried " + providerOrder.join(", ") + ". Retrying every " + retrySeconds + "s.")
  }

  // The firmware's new-block moment. A jump of more than 100 blocks is the
  // widget catching up after sleep or an outage, and gets none of it - the
  // same guard the device applies.
  function checkNewBlock() {
    var h = payload.height
    var fresh = lastHeight > 0 && h > lastHeight && h - lastHeight <= 100
    lastHeight = Math.max(lastHeight, h)
    if (!fresh) return
    celebrate(false)
    // The other monitors fetch on their own clocks: ask them to look now, so
    // every screen flashes within a second or two instead of up to a minute
    // apart. They find the block themselves and flash on their own.
    var list = peers()
    for (var i = 0; i < list.length; i++) if (list[i] !== root && list[i].refresh) list[i].refresh()
  }

  // `preview` is the settings panel's Try button: every enabled reaction, but
  // on this monitor only.
  function celebrate(preview) {
    if (stealFocus) {
      now = Date.now()
      focusUntil = now + rotateSeconds * 1000
    }
    if (blockFlash) flashAnim.restart()
    if (blockNotify && (preview || speaksForPeers())) {
      var b = payload && payload.block && payload.block.height === payload.height ? payload.block : null
      notify("Block " + group(payload ? payload.height : 0),
             b ? [b.pool ? "Mined by " + b.pool : "", group(b.tx) + " transactions",
                  b.median !== null ? "median " + feeRate(b.median) + " sat/vB" : ""]
                   .filter(function (s) { return s !== "" }).join("  ·  ")
               : "")
    }
  }

  // ---- rotation controls ----------------------------------------------------
  function step(delta) {
    var list = activeScreens
    var n = list.length
    if (paused) {
      var at = Math.max(0, list.indexOf(frozenId))
      frozenId = list[((at + delta) % n + n) % n]
    } else {
      manualOffset = ((manualOffset + delta) % n + n) % n
    }
    focusUntil = 0
  }

  function advance() { step(1) }
  function retreat() { step(-1) }

  // BTClock's button 1: hold one screen instead of rotating.
  function togglePause() {
    if (!paused) frozenId = currentId
    paused = !paused
    focusUntil = 0
  }

  // Jump straight to a screen from the settings panel, keeping the rotation
  // running from there.
  function showScreen(id) {
    var list = activeScreens
    var at = list.indexOf(id)
    if (at === -1) return
    focusUntil = 0
    if (paused) {
      frozenId = id
      return
    }
    var n = list.length
    var base = Math.floor(now / (rotateSeconds * 1000)) % n
    manualOffset = ((at - base) % n + n) % n
  }

  // Every monitor, so the panels stay in step. broadcast() cannot carry an
  // argument, hence the loop.
  function showScreenEverywhere(id) {
    var list = peers()
    if (!list.length) list = [root]
    for (var i = 0; i < list.length; i++) if (list[i].showScreen) list[i].showScreen(id)
  }

  // ---- writing settings -----------------------------------------------------
  // Through `omarchy bar set`, the same path as typing it: the shell owns
  // shell.json, and every instance on every monitor picks the change up.
  function save(key, value) {
    var next = Object.assign({}, pending)
    next[key] = value
    pending = next
    var base = String(Quickshell.env("OMARCHY_PATH") || "")
    if (!base) return
    Util.execArgv([base + "/bin/omarchy-bar", "set", moduleName, key, JSON.stringify(value), "--json"])
  }

  function toggleScreen(id) {
    var list = screens.slice()
    var at = list.indexOf(id)
    if (at === -1) list.push(id)
    else if (list.length > 1) list.splice(at, 1)
    save("screens", list.join(" "))
  }

  function moveScreen(id, delta) {
    var list = screens.slice()
    var at = list.indexOf(id)
    var to = at + delta
    if (at === -1 || to < 0 || to >= list.length) return
    list.splice(at, 1)
    list.splice(to, 0, id)
    save("screens", list.join(" "))
  }

  // Enabled screens in rotation order, then the rest in catalogue order.
  function screenRows() {
    var out = screens.slice()
    for (var i = 0; i < catalogue.length; i++) if (out.indexOf(catalogue[i].id) === -1) out.push(catalogue[i].id)
    return out
  }

  // ---- settings panel lifecycle -------------------------------------------
  // The shape Bar.findPanelWidget and the popout coordinator route on:
  // open/close/opened on the widget mounted in the bar slot.
  PanelController { id: panelController }
  readonly property bool opened: panelController.open
  property bool popoutSwitchClosing: false

  function open() { panelController.show() }
  function close() { panelController.hide() }
  function togglePanel() { opened ? close() : open() }
  function closeForPopoutSwitch() {
    popoutSwitchClosing = true
    close()
    Qt.callLater(function () { popoutSwitchClosing = false })
  }

  // Visible for the dashes too: a widget that has nothing to report is worth
  // seeing, or its absence is indistinguishable from a plugin that is not
  // installed.
  visible: payload !== null || unreachable
  implicitWidth: vertical ? barSize : strip.width + Style.spaceReal(6)
  implicitHeight: vertical ? strip.height + Style.spaceReal(6) : barSize

  // Parameterless and non-destructive: each only triggers the widget's own
  // ordinary behaviour.
  IpcHandler {
    target: "kravens.btclock"

    function refresh(): void {
      root.broadcast("refresh")
    }

    function pause(): void {
      root.broadcast("togglePause")
    }

    function toggle(): void {
      root.togglePanel()
    }

    // Read-only: one line per enabled screen, "id<TAB>panels<TAB>spelled out",
    // the one on the panels now marked with a leading "*".
    function status(): string {
      var out = []
      for (var i = 0; i < root.screens.length; i++) {
        var id = root.screens[i]
        out.push((id === root.currentId ? "*" : "") + id + "\t" + root.screenText(id) + "\t" + root.screenLong(id))
      }
      return out.join("\n")
    }
  }

  Process {
    id: statusProc
    // Absolute paths only. setsid gives the fetch its own process group and
    // timeout an absolute deadline with KILL escalation, so nothing is left
    // behind when a request hangs. The instance order and the Bitaxe host are
    // the only values passed on, and the helper validates both again.
    command: ["/usr/bin/setsid", "-w", "/usr/bin/timeout", "-k", "2", "--", "30",
              "/usr/bin/bash", root.helper, "--providers", root.providerOrder.join(",")]
             .concat(root.wantsBitaxe ? ["--bitaxe", root.bitaxeHost] : [])

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
      if (root.refreshQueued) {
        root.refreshQueued = false
        Qt.callLater(root.refresh)
      }
      if (code === 0 && root.applyPayload(raw)) {
        // An instance answered: the panels are live again, and the next outage
        // is news the user has not had yet.
        root.unreachable = false
        root.notified = false
        root.failures = 0
        root.lastGood = providerId(root.payload.provider) || root.lastGood
        root.checkNewBlock()
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

  // A Bitaxe just configured should not wait out a full refresh interval.
  onWantsBitaxeChanged: if (wantsBitaxe) refresh()

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
    running: !root.paused || root.now < root.focusUntil
    repeat: true
    onTriggered: root.now = Date.now()
  }

  // Three pulses, like the device's LED block flash.
  SequentialAnimation {
    id: flashAnim
    loops: 3
    NumberAnimation { target: root; property: "flash"; to: 1; duration: 160; easing.type: Easing.OutCubic }
    NumberAnimation { target: root; property: "flash"; to: 0; duration: 440; easing.type: Easing.InCubic }
  }

  // ---- rendering ----------------------------------------------------------
  // One row of e-paper panels. Drawn in the bar and again, larger and always
  // solid, at the top of the settings panel; everything it shows arrives as a
  // property, so both copies render the same thing.
  component PanelRow: Row {
    id: panelRow
    property real cellHeight: 20
    property var cellText: []
    property color fill
    property color edge
    property color ink
    property string fontFamily: ""
    property bool animateColors: true
    readonly property real cellWidth: Math.round(cellHeight * 0.74)

    spacing: Math.max(1, Math.round(cellHeight * 0.14))

    Repeater {
      model: panelRow.cellText.length

      Rectangle {
        required property int index
        width: panelRow.cellWidth
        height: panelRow.cellHeight
        radius: Math.max(1, Math.round(panelRow.cellWidth * 0.12))
        color: panelRow.fill
        border.width: 1
        border.color: panelRow.edge
        // The bar fades in and out of transparency; the panels fade with it,
        // using the bar's own duration and easing.
        Behavior on color {
          enabled: panelRow.animateColors
          ColorAnimation { duration: 420; easing.type: Easing.InOutCubic }
        }

        Behavior on border.color {
          enabled: panelRow.animateColors
          ColorAnimation { duration: 420; easing.type: Easing.InOutCubic }
        }

        Text {
          anchors.centerIn: parent
          // Pinned on every Text, literal or not, so the invariant is auditable.
          textFormat: Text.PlainText
          text: panelRow.cellText[parent.index] || ""
          color: panelRow.ink
          font.family: panelRow.fontFamily
          font.pixelSize: Math.max(7, Math.round(panelRow.cellHeight * 0.74))
          renderType: Text.NativeRendering

          Behavior on color {
            enabled: panelRow.animateColors
            ColorAnimation { duration: 420; easing.type: Easing.InOutCubic }
          }
        }
      }
    }
  }

  readonly property string panelFont: root.bar ? root.bar.fontFamily : Style.font.family

  PanelRow {
    id: strip
    anchors.centerIn: parent
    cellHeight: Math.max(10, root.barSize - Style.spaceReal(7))
    spacing: Math.max(1, Math.round(root.barSize * 0.10))
    cellText: root.cellChars()
    fill: root.panelFill(false)
    edge: root.panelBorder(false)
    ink: root.panelInk(false)
    fontFamily: root.panelFont
    // The flash drives the colour every frame; a 420ms Behavior on top of it
    // would smear three pulses into one.
    animateColors: (!root.bar || root.bar.foregroundAnimationEnabled) && !flashAnim.running
    // Dimmed while the numbers are stale, and while there are no numbers at
    // all, so the panels never read as current when they are not.
    opacity: (root.stale || root.unreachable) ? 0.45 : 1

    Behavior on opacity {
      NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
    }
  }

  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor

    // Left opens the settings panel; the other two mirror BTClock's buttons:
    // middle holds the current screen, right and scroll step through.
    onClicked: function (mouse) {
      if (root.bar) root.bar.hideTooltip(root)
      if (mouse.button === Qt.LeftButton) root.togglePanel()
      else if (mouse.button === Qt.MiddleButton) root.broadcast("togglePause")
      else root.broadcast("advance")
    }
    onWheel: function (wheel) {
      root.broadcast(wheel.angleDelta.y > 0 ? "advance" : "retreat")
    }
    onEntered: if (root.bar && !root.opened) root.bar.showTooltip(root, root.tooltip())
    onExited: if (root.bar) root.bar.hideTooltip(root)
  }

  // ---- settings panel -------------------------------------------------------
  readonly property color ink: root.bar ? root.bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(ink, 1.4)

  // A row of pill buttons, one per option, the current one lit.
  component Choices: Flow {
    id: choices
    property color foreground
    property string fontFamily: ""
    property var options: []
    property var current
    signal chose(var value)
    width: parent ? parent.width : implicitWidth
    spacing: Style.spacing.xs

    Repeater {
      model: choices.options
      Button {
        required property var modelData
        text: String(modelData)
        foreground: choices.foreground
        fontFamily: choices.fontFamily
        fontSize: Style.font.caption
        bordered: true
        active: String(choices.current) === String(modelData)
        onClicked: choices.chose(modelData)
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root
    owner: root
    bar: root.bar
    open: root.opened
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(720))

    Flickable {
      id: scroller
      anchors.fill: parent
      clip: true
      contentWidth: width
      contentHeight: panelColumn.implicitHeight
      boundsBehavior: Flickable.StopAtBounds

      Column {
        id: panelColumn
        width: scroller.width
        spacing: Style.space(14)

        PanelHero {
          title: "BTClock"
          meta: root.statusLine()
          foreground: root.ink
          fontFamily: root.panelFont
          iconComponent: Component {
            Text {
              textFormat: Text.PlainText
              text: "󰠓"
              color: root.ink
              font.family: root.panelFont
              font.pixelSize: Style.font.display
            }
          }
          trailingControl: Component {
            Row {
              spacing: Style.spacing.xs
              Button {
                text: root.paused ? "Resume" : "Pause"
                foreground: root.ink
                fontFamily: root.panelFont
                fontSize: Style.font.caption
                bordered: true
                active: root.paused
                onClicked: root.broadcast("togglePause")
              }
              Button {
                text: "Refresh"
                foreground: root.ink
                fontFamily: root.panelFont
                fontSize: Style.font.caption
                bordered: true
                onClicked: root.broadcast("refresh")
              }
            }
          }
        }

        // The panels themselves, big enough to read, always solid.
        PanelRow {
          anchors.horizontalCenter: parent.horizontalCenter
          cellHeight: Style.space(34)
          cellText: root.cellChars()
          fill: root.panelFill(true)
          edge: root.panelBorder(true)
          ink: root.panelInk(true)
          fontFamily: root.panelFont
          animateColors: !flashAnim.running
          opacity: (root.stale || root.unreachable) ? 0.45 : 1
        }

        // ---------- Screens ----------
        PanelSeparator { foreground: root.ink }
        PanelSectionHeader { text: "SCREENS"; foreground: root.ink; fontFamily: root.panelFont }

        Column {
          width: parent.width
          spacing: Style.space(4)

          Repeater {
            model: root.screenRows()

            Item {
              id: screenRow
              required property string modelData
              required property int index
              readonly property bool enabled_: root.screens.indexOf(modelData) !== -1
              readonly property bool showing: root.currentId === modelData
              width: parent.width
              implicitHeight: Math.max(rowSwitch.implicitHeight, upButton.implicitHeight)

              ToggleSwitch {
                id: rowSwitch
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                checked: screenRow.enabled_
                foreground: root.ink
                trackHeight: Math.round(Style.spacing.controlHeight * 0.45)
                onToggled: root.toggleScreen(screenRow.modelData)
              }

              // The screen's name, and what it would show right now. Clicking
              // either jumps the panels to it.
              Column {
                anchors.left: rowSwitch.right
                anchors.leftMargin: Style.space(10)
                anchors.right: arrows.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter

                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  text: (screenRow.showing ? "▸ " : "") + root.screenName(screenRow.modelData)
                  color: screenRow.enabled_ ? root.ink : root.dim
                  font.family: root.panelFont
                  font.pixelSize: Style.font.body
                  font.bold: screenRow.showing
                  elide: Text.ElideRight
                }
                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  text: root.screenLong(screenRow.modelData)
                    || (screenRow.modelData.indexOf("bitaxe") === 0
                        ? (root.bitaxeHost ? "No answer from " + root.bitaxeHost : "Set a Bitaxe address below")
                        : "No data yet")
                  color: root.dim
                  font.family: root.panelFont
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
              }

              MouseArea {
                anchors.left: rowSwitch.right
                anchors.right: arrows.left
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                enabled: screenRow.enabled_
                cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: root.showScreenEverywhere(screenRow.modelData)
              }

              Row {
                id: arrows
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.spacing.xs
                opacity: screenRow.enabled_ ? 1 : 0.3

                Button {
                  id: upButton
                  text: "▲"
                  foreground: root.ink
                  fontFamily: root.panelFont
                  fontSize: Style.font.caption
                  bordered: true
                  enabled: screenRow.enabled_ && screenRow.index > 0
                  onClicked: root.moveScreen(screenRow.modelData, -1)
                }
                Button {
                  text: "▼"
                  foreground: root.ink
                  fontFamily: root.panelFont
                  fontSize: Style.font.caption
                  bordered: true
                  enabled: screenRow.enabled_ && screenRow.index < root.screens.length - 1
                  onClicked: root.moveScreen(screenRow.modelData, 1)
                }
              }
            }
          }
        }

        // ---------- New block ----------
        PanelSeparator { foreground: root.ink }
        Item {
          width: parent.width
          implicitHeight: Math.max(blockHeader.implicitHeight, tryButton.implicitHeight)
          PanelSectionHeader {
            id: blockHeader
            text: "NEW BLOCK"
            foreground: root.ink
            fontFamily: root.panelFont
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }
          Button {
            id: tryButton
            text: "Try it"
            foreground: root.ink
            fontFamily: root.panelFont
            fontSize: Style.font.caption
            bordered: true
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            enabled: root.payload !== null
            onClicked: root.celebrate(true)
          }
        }

        Toggle {
          width: parent.width
          label: "Jump to block height"
          description: "Show the new height for one full screen, then carry on."
          foreground: root.ink
          fontFamily: root.panelFont
          checked: root.stealFocus
          onClicked: root.save("stealFocus", !root.stealFocus)
        }
        Toggle {
          width: parent.width
          label: "Flash the panels"
          description: "Three pulses in the theme accent, like the device's LEDs."
          foreground: root.ink
          fontFamily: root.panelFont
          checked: root.blockFlash
          onClicked: root.save("blockFlash", !root.blockFlash)
        }
        Toggle {
          width: parent.width
          label: "Notification"
          description: "Height, pool, transaction count and median fee."
          foreground: root.ink
          fontFamily: root.panelFont
          checked: root.blockNotify
          onClicked: root.save("blockNotify", !root.blockNotify)
        }

        // ---------- Display ----------
        PanelSeparator { foreground: root.ink }
        PanelSectionHeader { text: "CURRENCY"; foreground: root.ink; fontFamily: root.panelFont }
        Choices {
          foreground: root.ink
          fontFamily: root.panelFont
          options: root.currencies
          current: root.currency
          onChose: function (value) { root.save("currency", value) }
        }

        PanelSectionHeader { text: "SECONDS PER SCREEN"; foreground: root.ink; fontFamily: root.panelFont }
        Choices {
          foreground: root.ink
          fontFamily: root.panelFont
          options: [5, 10, 21, 30, 60]
          current: root.rotateSeconds
          onChose: function (value) { root.save("rotateSeconds", value) }
        }

        PanelSectionHeader { text: "PANELS"; foreground: root.ink; fontFamily: root.panelFont }
        Row {
          width: parent.width
          spacing: Style.spacing.xs
          Choices {
          foreground: root.ink
          fontFamily: root.panelFont
            width: implicitWidth
            options: ["Dark", "Light"]
            current: root.lightMode ? "Light" : "Dark"
            onChose: function (value) { root.save("mode", value.toLowerCase()) }
          }
          Item { width: Style.space(12); height: 1 }
          Button {
            text: "−"
            foreground: root.ink
            fontFamily: root.panelFont
            bordered: true
            enabled: root.cells > 3
            onClicked: root.save("cells", root.cells - 1)
          }
          Text {
            textFormat: Text.PlainText
            text: root.cells + " panels"
            color: root.ink
            font.family: root.panelFont
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
            width: Style.space(76)
            anchors.verticalCenter: parent.verticalCenter
          }
          Button {
            text: "+"
            foreground: root.ink
            fontFamily: root.panelFont
            bordered: true
            enabled: root.cells < 12
            onClicked: root.save("cells", root.cells + 1)
          }
        }

        PanelSectionHeader { text: "MEMPOOL INSTANCE"; foreground: root.ink; fontFamily: root.panelFont }
        Choices {
          foreground: root.ink
          fontFamily: root.panelFont
          options: root.providers
          current: root.preferred
          onChose: function (value) { root.save("provider", value) }
        }

        // ---------- Bitaxe ----------
        PanelSeparator { foreground: root.ink }
        PanelSectionHeader { text: "BITAXE"; foreground: root.ink; fontFamily: root.panelFont }
        TextField {
          id: hostField
          width: parent.width
          foreground: root.ink
          font.family: root.panelFont
          font.pixelSize: Style.font.body
          placeholderText: "bitaxe.local or 192.168.1.40"
          text: root.bitaxeHost
          // Only a bare host[:port] is ever saved; anything else stays in the
          // field, marked, and is not written.
          readonly property bool acceptable: text.trim() === "" || root.validHost(text.trim())
          color: acceptable ? root.ink : Color.urgent
          onEditingFinished: {
            var h = text.trim()
            if (acceptable && h !== root.bitaxeHost) root.save("bitaxeHost", h)
          }
        }
        Text {
          width: parent.width
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          color: root.dim
          font.family: root.panelFont
          font.pixelSize: Style.font.caption
          text: !hostField.acceptable ? "A host name or IP address, optionally with :port."
            : !root.bitaxeHost ? "Your miner's address on the local network. Asked for /api/system/info over HTTP, nothing else."
            : !root.wantsBitaxe ? "Turn on a Bitaxe screen above to start asking it."
            : root.payload && root.payload.bitaxe ? root.screenLong("bitaxeHash") + "  ·  " + root.screenLong("bitaxeBest")
            : "No answer from " + root.bitaxeHost + " yet."
        }

        Item { width: parent.width; height: Style.space(4) }
      }
    }
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
