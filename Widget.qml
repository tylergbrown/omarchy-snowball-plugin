import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Status chip for the Snowball auto trader. Popup styled after the Otter
// Robo Trader (warm dark cards, orange accents, status chips, 26px hero).
// One /api/snapshot carries every
// book's equity; that read often takes about twenty seconds, so the poll waits.
BarWidget {
  id: root
  moduleName: "tb.snowball"

  readonly property string script:
    Qt.resolvedUrl("status.py").toString().replace(/^file:\/\//, "")
  readonly property string baseUrl: String(setting("url", "http://192.168.1.24:8080")).replace(/\/+$/, "")
  readonly property int pollSec: clampedInteger("pollSec", 10, 5, 300)
  readonly property int snapshotSec: clampedInteger("snapshotSec", 120, 0, 3600)
  readonly property int staleTickSec: clampedInteger("staleTickSec", 300, 30, 3600)
  readonly property bool showPnl: Boolean(setting("showPnl", true))
  readonly property string sshUser: String(setting("sshUser", "tylerbrown"))
  readonly property string containerName: String(setting("container", "snowball"))

  property bool popupOpen: false
  onPopupOpenChanged: if (popupOpen) chartCanvas.requestPaint()
  property bool hovered: false
  property bool armRestart: false
  property var health: ({})
  property var detail: ({})
  property bool sawHealth: false
  property string healthError: ""
  property string detailError: ""
  property string restartMessage: ""
  property string refreshedAt: ""
  property var sections: []
  property var portfolio: []
  property int loadPercent: 0
  property string loadStage: ""

  readonly property bool snapBusy: snapProc.running
  readonly property bool restartBusy: restartProc.running
  readonly property bool reachable: health.reachable === true && health.ok === true
  readonly property bool hasDetail: detail.detail === true
  readonly property string mode: hasDetail && detail.mode ? String(detail.mode) : (health.mode ? String(health.mode) : "")
  readonly property bool paper: hasDetail && detail.paper === true
  readonly property bool halted: hasDetail && detail.halt_active === true
  readonly property bool killed: hasDetail && detail.daily_killed === true
  readonly property bool trading: hasDetail && detail.trading_enabled === true
  readonly property bool running: !hasDetail || detail.running !== false
  readonly property int tickAge: hasDetail && detail.tick_age_sec !== undefined && detail.tick_age_sec !== null
    ? Number(detail.tick_age_sec) : -1
  readonly property bool tickStale: tickAge >= 0 && tickAge > staleTickSec
  readonly property var blocks: hasDetail && detail.block_reasons ? detail.block_reasons : []
  readonly property var books: hasDetail && detail.books ? detail.books : []

  readonly property string level: computeLevel()
  readonly property color tone: level === "fault" ? "#e24b4b" : (level === "offline" ? "#f0d020" : "#3cba7a")
  readonly property string barLabel: computeLabel()
  readonly property string headline: computeHeadline()
  readonly property string facts: buildFacts()
  readonly property bool opened: popupOpen

  // ── Otter Robo Trader palette (warm dark + orange) ───────────────────
  readonly property color cBg: "#0C0B0A"
  readonly property color cSurface: "#15110E"
  readonly property color cSurfaceAlt: "#211813"
  readonly property color cFg: "#F2E8DE"
  readonly property color cMuted: "#B9A79A"
  readonly property color cAccent: "#FF8A1F"
  readonly property color cSelected: "#3D220A"
  readonly property color cBorder: "#C45C12"
  readonly property color cOk: "#4ADE80"
  readonly property color cWarn: "#FBBF24"
  readonly property color cBad: "#FF6B6B"
  readonly property string monoFont: "JetBrainsMono Nerd Font"

  readonly property var spotColumns: [
    { key: "product", title: "Product", align: "left", w: 110 },
    { key: "side", title: "Side", align: "left", w: 56 },
    { key: "qty", title: "Qty", align: "right", w: 88 },
    { key: "entry", title: "Entry", align: "right", w: 78 },
    { key: "mark", title: "Mark", align: "right", w: 78 },
    { key: "value", title: "Value", align: "right", w: 78 },
    { key: "pnl_pct", title: "P/L %", align: "right", w: 64 },
    { key: "pnl_usd", title: "P/L $", align: "right", w: 78 },
    { key: "strategy", title: "Strategy", align: "left", w: 90 }
  ]
  readonly property var cashColumns: [
    { key: "product", title: "Asset", align: "left", w: 120 },
    { key: "side", title: "Type", align: "left", w: 56 },
    { key: "qty", title: "Qty", align: "right", w: 100 },
    { key: "value", title: "Value", align: "right", w: 90 }
  ]
  readonly property var futuresColumns: [
    { key: "product", title: "Product", align: "left", w: 120 },
    { key: "side", title: "Side", align: "left", w: 56 },
    { key: "qty", title: "Contracts", align: "right", w: 80 },
    { key: "entry", title: "Entry", align: "right", w: 78 },
    { key: "mark", title: "Mark", align: "right", w: 78 },
    { key: "value", title: "Notional", align: "right", w: 78 },
    { key: "pnl_pct", title: "P/L %", align: "right", w: 64 },
    { key: "pnl_usd", title: "P/L $", align: "right", w: 78 }
  ]
  readonly property var treasuryColumns: [
    { key: "product", title: "Asset", align: "left", w: 90 },
    { key: "qty", title: "Holdings", align: "right", w: 100 },
    { key: "entry", title: "Avg cost", align: "right", w: 90 },
    { key: "mark", title: "Spot", align: "right", w: 90 },
    { key: "value", title: "Mark value", align: "right", w: 90 },
    { key: "pnl_pct", title: "P/L %", align: "right", w: 64 },
    { key: "pnl_usd", title: "P/L $", align: "right", w: 78 },
    { key: "strategy", title: "Kind", align: "left", w: 80 }
  ]
  readonly property var bookOrder: ["cash", "treasury", "futures", "coinbase", "crypto", "stocks", "crash", "fed"]

  readonly property var statusChips: computeStatusChips()
  readonly property string popupSubtitle: wittySubtitle()
  readonly property var flagList: computeFlags()
  readonly property real dayPnl: hasDetail && detail.daily_pnl_usd !== undefined && detail.daily_pnl_usd !== null
    ? Number(detail.daily_pnl_usd) : NaN

  function toneColor(tone) {
    if (tone === "ok") return cOk
    if (tone === "warn") return cWarn
    if (tone === "bad") return cBad
    if (tone === "accent") return cAccent
    return cFg
  }

  function toneFor(value) {
    if (value === undefined || value === null || value === "") return ""
    var amount = Number(value)
    if (!isFinite(amount) || amount === 0) return ""
    return amount > 0 ? "ok" : "bad"
  }

  function computeStatusChips() {
    var chips = []
    if (restartBusy) chips.push({ label: "RESTARTING", tone: "warn" })
    if (sawHealth) {
      if (health.reachable === true && health.ok !== false) chips.push({ label: "REACHABLE", tone: "ok" })
      else if (health.reachable !== true) chips.push({ label: "DOWN", tone: "bad" })
      if (health.ok === false) chips.push({ label: "FAULT", tone: "bad" })
    }
    if (mode) chips.push({ label: mode.toUpperCase(), tone: "accent" })
    if (halted) chips.push({ label: "HALT", tone: "bad" })
    if (killed) chips.push({ label: "KILL", tone: "bad" })
    if (paper && mode !== "paper") chips.push({ label: "PAPER", tone: "warn" })
    if (tickStale) chips.push({ label: "STALE TICK", tone: "warn" })
    if (chips.length === 0) chips.push({ label: "PENDING", tone: "warn" })
    return chips
  }

  function wittySubtitle() {
    if (restartBusy) return "restarting the container…"
    if (restartMessage) return restartMessage
    if (halted) return "halted — sitting this one out"
    if (killed) return "daily kill tripped — cool-off mode"
    if (sawHealth && health.ok === false) return "fault lights on — check FLAGS"
    if (sawHealth && health.reachable !== true) return "robo trader is AFK"
    if (isFinite(dayPnl) && dayPnl > 0) return "snowballing — day is green"
    if (isFinite(dayPnl) && dayPnl < 0) return "red day — still compounding"
    if (hasDetail && detail.equity_usd !== undefined && detail.equity_usd !== null) return "books open · chips stacked"
    if (reachable) return snapBusy ? "reachable · reading balances…" : "reachable · waiting on snapshot"
    return "warming up the bots…"
  }

  function computeFlags() {
    var out = []
    if (!hasDetail) return out
    var reasons = detail.block_reasons || []
    for (var i = 0; i < reasons.length; i++) out.push(String(reasons[i]))
    if (detail.last_error) out.push("err: " + String(detail.last_error))
    return out.slice(0, 8)
  }

  function tablePrice(value) {
    if (value === undefined || value === null || value === "") return "—"
    var amount = Number(value)
    if (!isFinite(amount)) return "—"
    var abs = Math.abs(amount)
    if (abs >= 1000) return amount.toFixed(2).replace(/\B(?=(\d{3})+(?!\d))/g, ",")
    if (abs >= 1) return amount.toFixed(4).replace(/\.?0+$/, "")
    return amount.toFixed(8).replace(/\.?0+$/, "") || "0"
  }

  function tableQty(value) {
    if (value === undefined || value === null || value === "") return "—"
    var amount = Number(value)
    if (!isFinite(amount)) return "—"
    var abs = Math.abs(amount)
    if (abs >= 1000000) return Math.round(amount).toString().replace(/\B(?=(\d{3})+(?!\d))/g, ",")
    if (abs >= 100) return amount.toFixed(2).replace(/\.?0+$/, "").replace(/\B(?=(\d{3})+(?!\d))/g, ",")
    return amount.toFixed(8).replace(/\.?0+$/, "") || "0"
  }

  function tablePct(value) {
    if (value === undefined || value === null || value === "") return "—"
    var amount = Number(value)
    if (!isFinite(amount)) return "—"
    return (amount > 0 ? "+" : "") + amount.toFixed(2) + "%"
  }

  function maybeDollars(value, signed) {
    if (value === undefined || value === null || value === "") return "—"
    return dollars(value, signed)
  }

  function cellFor(pos, key) {
    if (key === "product") return { text: String(pos.product || "—"), color: cFg }
    if (key === "side") return { text: String(pos.side || "—"), color: cFg }
    if (key === "qty") return { text: tableQty(pos.qty), color: cFg }
    if (key === "entry") return { text: tablePrice(pos.entry_price), color: cFg }
    if (key === "mark") return { text: tablePrice(pos.mark), color: cFg }
    if (key === "value") return { text: maybeDollars(pos.value_usd, false), color: cFg }
    if (key === "pnl_pct") return { text: tablePct(pos.pnl_pct), color: toneColor(toneFor(pos.pnl_pct)) }
    if (key === "pnl_usd") return { text: maybeDollars(pos.unrealized_pnl, true), color: toneColor(toneFor(pos.unrealized_pnl)) }
    if (key === "strategy") return { text: String(pos.strategy || "—"), color: cFg }
    return { text: "—", color: cFg }
  }

  function columnsFor(name) {
    if (name === "treasury") return treasuryColumns
    if (name === "cash") return cashColumns
    if (name === "futures") return futuresColumns
    return spotColumns
  }

  function columnWidth(columns, index, total) {
    var sum = 0
    for (var i = 0; i < columns.length; i++) sum += columns[i].w
    var usable = Math.max(1, total - 10 * (columns.length - 1))
    return Math.floor(usable * columns[index].w / Math.max(1, sum))
  }

  function spotNotional(pos) {
    var keys = ["value_usd", "notional_usd"]
    for (var i = 0; i < keys.length; i++) {
      var v = pos[keys[i]]
      if (v !== undefined && v !== null && isFinite(Number(v))) return Math.abs(Number(v))
    }
    var qty = Math.abs(Number(pos.qty))
    var mark = Number(pos.mark)
    if (isFinite(qty) && isFinite(mark) && mark > 0) return Math.abs(qty * mark)
    return 0
  }

  function metric(caption, value, tone) {
    return { caption: caption, value: value, color: toneColor(tone || "") }
  }

  function clampedInteger(key, fallback, minimum, maximum) {
    var value = Math.round(Number(setting(key, fallback)))
    if (!isFinite(value)) value = fallback
    return Math.max(minimum, Math.min(maximum, value))
  }

  // Green: live and answering. Red: a fault in a bot we can still reach.
  // Yellow: offline, or no answer yet.
  function hasFault() {
    // Treat coinbase like snapshot: halt/killed/paper apply when flags present.
    // Ledger has no trading flags, so it must not raise a fault.
    if (!(hasDetail && detail.source !== "ledger")) return false
    if (halted || killed || !running || !trading || paper || tickStale) return true
    if (blocks && blocks.length > 0) return true
    if (detail.last_error) return true
    return false
  }

  function computeLevel() {
    if (restartBusy) return "offline"
    if (!sawHealth || !reachable) return "offline"
    if (hasFault()) return "fault"
    if (mode === "live") return "live"
    return "fault"
  }

  function bookTitle(name) {
    if (name === "coinbase") return "Spot"
    if (name === "cash") return "Cash"
    if (name === "futures") return "Futures"
    if (name === "crypto") return "Crypto"
    if (name === "stocks") return "Stocks"
    if (name === "futures") return "Futures"
    if (name === "crash") return "Crash"
    if (name === "fed") return "Fed"
    if (name === "treasury") return "Bitcoin Treasury"
    return String(name || "Book")
  }

  function dollars(value, signed) {
    var amount = Number(value)
    if (!isFinite(amount)) return "—"
    var negative = amount < 0
    var absolute = Math.abs(amount)
    var body = absolute.toFixed(2)
    var parts = body.split(".")
    parts[0] = parts[0].replace(/\B(?=(\d{3})+(?!\d))/g, ",")
    var sign = ""
    if (signed && amount > 0) sign = "+"
    else if (negative) sign = "-"
    return sign + "$" + parts.join(".")
  }

  function chipDollars(value) {
    var amount = Number(value)
    if (!isFinite(amount)) return "—"
    var absolute = Math.abs(amount)
    var rounded = absolute >= 100 ? String(Math.round(absolute)) : absolute.toFixed(2)
    rounded = rounded.replace(/\B(?=(\d{3})+(?!\d))/g, ",")
    return (amount < 0 ? "-" : "") + "$" + rounded
  }

  function bookAmount(book) {
    if (book.equity_usd !== undefined && book.equity_usd !== null && isFinite(Number(book.equity_usd)))
      return Number(book.equity_usd)
    if (book.cash_usd !== undefined && book.cash_usd !== null && isFinite(Number(book.cash_usd)))
      return Number(book.cash_usd)
    return NaN
  }

  function balanceChip() {
    var parts = []
    for (var i = 0; i < books.length; i++) {
      var amount = bookAmount(books[i])
      if (!isFinite(amount)) continue
      parts.push(bookTitle(books[i].name) + " " + chipDollars(amount))
    }
    if (parts.length > 0) return parts.join(" · ")
    if (detail.equity_usd === undefined || detail.equity_usd === null) return ""
    return chipDollars(detail.equity_usd)
  }

  function stateWord() {
    if (restartBusy) return "RESTARTING"
    if (!sawHealth || !reachable) return "OFFLINE"
    if (hasDetail && detail.source !== "ledger") {
      if (halted) return "HALT"
      if (killed) return "STOP"
      if (paper) return "PAPER"
      if (!trading) return "PAUSED"
      if (tickStale || detail.last_error || (blocks && blocks.length > 0)) return "FAULT"
    }
    if (mode === "live") return "LIVE"
    return (mode || "FAULT").toUpperCase()
  }

  function computeLabel() {
    if (restartBusy) return "RESTARTING"
    if (!sawHealth || !reachable) return "OFFLINE"
    var percent = snapBusy ? (" · " + loadPercent + "%") : ""
    if (!hasDetail) return stateWord() + percent
    // Prefer compact total equity so Cash+Futures+Spot do not double-count.
    var balances = ""
    if (detail.equity_usd !== undefined && detail.equity_usd !== null && isFinite(Number(detail.equity_usd)))
      balances = chipDollars(detail.equity_usd)
    else
      balances = balanceChip()
    var pnl = showPnl && detail.daily_pnl_usd !== undefined && detail.daily_pnl_usd !== null
      ? "  " + dollars(detail.daily_pnl_usd, true) : ""
    return stateWord() + (balances ? "  " + balances : "") + pnl + percent
  }

  function computeHeadline() {
    if (restartBusy) return "Restarting container."
    if (restartMessage) return restartMessage
    if (!sawHealth) return "Checking…"
    if (!reachable && !hasDetail) return "No answer from host."
    if (!hasDetail) {
      return snapBusy ? "Reading balances…" : "Up, but no balances yet."
    }
    if (halted) return "Trading halted."
    if (killed) return "Daily loss stop on."
    // Healthy coinbase / live ledger: status row already covers it.
    if (detail.source === "coinbase") return ""
    if (detail.source === "ledger" && mode === "live" && reachable) return ""
    if (detail.source === "ledger") return "Ledger cash; equity when feed answers."
    return ""
  }

  // "off" only when a status feed explicitly says trading is disabled.
  // The ledger read has no trading flag, so it must not contradict the light.
  function tradingLabel() {
    if (!sawHealth || !reachable) return "offline"
    if (hasDetail && detail.source !== "ledger") {
      if (halted) return "halted"
      if (killed) return "stopped"
      if (paper) return "paper"
      if (detail.trading_enabled === false) return "off"
      if (detail.trading_enabled === true) return "live"
    }
    if (mode === "live") return "live"
    if (mode === "paper") return "paper"
    return mode || "unknown"
  }

  function priceText(value) {
    var amount = Number(value)
    if (!isFinite(amount)) return "—"
    var digits = Math.abs(amount) >= 100 ? 2 : 4
    return amount.toFixed(digits)
  }

  function qtyText(value) {
    var amount = Number(value)
    if (!isFinite(amount)) return "—"
    var digits = Math.abs(amount) >= 100 ? 2 : 6
    return amount.toFixed(digits).replace(/\.?0+$/, "")
  }

  function positionLine(pos) {
    var parts = [pos.product || "—"]
    if (pos.side) parts.push(String(pos.side))
    if (pos.qty !== undefined && pos.qty !== null) parts.push(qtyText(pos.qty))
    if (pos.entry_price !== undefined && pos.entry_price !== null) parts.push("@ " + priceText(pos.entry_price))
    if (pos.mark !== undefined && pos.mark !== null) parts.push("mark " + priceText(pos.mark))
    if (pos.value_usd !== undefined && pos.value_usd !== null) parts.push(dollars(pos.value_usd, false))
    parts.push(pctText(pos.pnl_pct))
    if (pos.unrealized_pnl !== undefined && pos.unrealized_pnl !== null) parts.push(dollars(pos.unrealized_pnl, true))
    if (pos.strategy) parts.push(String(pos.strategy))
    return parts.join(" · ")
  }

  function portfolioValue(index) {
    if (!portfolio.length) return 0
    var point = index < 0 ? portfolio[portfolio.length - 1] : portfolio[index]
    var amount = Number(point && point.value)
    return isFinite(amount) ? amount : 0
  }

  function weekChangeText() {
    if (portfolio.length < 2) return ""
    var delta = portfolioValue(-1) - portfolioValue(0)
    var base = portfolioValue(0)
    var pct = base ? (delta / base) * 100 : 0
    var pctSign = pct > 0 ? "+" : ""
    return dollars(delta, true) + " · " + pctSign + pct.toFixed(1) + "%"
  }

  function paintPortfolio(canvas) {
    var ctx = canvas.getContext("2d")
    if (!ctx) return
    ctx.reset()
    var points = portfolio
    if (!points || points.length < 1 || canvas.width < 2 || canvas.height < 2) return

    var strokeGreen = "#FF8A1F"
    var strokeRed = "#FF6B6B"

    if (points.length === 1) {
      var cx = canvas.width / 2
      var cy = canvas.height / 2
      ctx.beginPath()
      ctx.arc(cx, cy, 10, 0, Math.PI * 2)
      ctx.fillStyle = "rgba(255, 138, 31, 0.18)"
      ctx.fill()
      ctx.beginPath()
      ctx.arc(cx, cy, 4.5, 0, Math.PI * 2)
      ctx.fillStyle = strokeGreen
      ctx.fill()
      return
    }

    var low = Number(points[0].value)
    var high = low
    for (var i = 1; i < points.length; i++) {
      var amount = Number(points[i].value)
      if (amount < low) low = amount
      if (amount > high) high = amount
    }
    var span = high - low
    if (span <= 0) span = Math.max(1, Math.abs(high) * 0.02)
    low -= span * 0.12
    high += span * 0.12
    span = high - low

    var rising = Number(points[points.length - 1].value) >= Number(points[0].value)
    var stroke = rising ? strokeGreen : strokeRed
    var padL = 44
    var padR = 10
    var padT = 8
    var padB = 8
    var plotW = Math.max(1, canvas.width - padL - padR)
    var plotH = Math.max(1, canvas.height - padT - padB)

    function xAt(index) {
      return padL + plotW * index / (points.length - 1)
    }
    function yAt(value) {
      return padT + plotH * (1 - ((value - low) / span))
    }
    function fmtAxis(v) {
      var n = Number(v)
      if (!isFinite(n)) return ""
      var abs = Math.abs(n)
      if (abs >= 1000) return "$" + (n / 1000).toFixed(abs >= 10000 ? 0 : 1) + "k"
      return "$" + n.toFixed(abs >= 100 ? 0 : 2)
    }

    // Faint horizontal grid + muted dollar labels (high / mid / low)
    var gridVals = [high, low + span * 0.5, low]
    ctx.font = "10px monospace"
    ctx.textAlign = "right"
    ctx.textBaseline = "middle"
    for (var g = 0; g < gridVals.length; g++) {
      var gy = yAt(gridVals[g])
      ctx.beginPath()
      ctx.moveTo(padL, gy)
      ctx.lineTo(padL + plotW, gy)
      ctx.strokeStyle = "rgba(255, 255, 255, 0.07)"
      ctx.lineWidth = 1
      ctx.stroke()
      ctx.fillStyle = "rgba(185, 167, 154, 0.85)"
      ctx.fillText(fmtAxis(gridVals[g]), padL - 6, gy)
    }

    // Area fill under the line
    ctx.beginPath()
    ctx.moveTo(xAt(0), yAt(Number(points[0].value)))
    if (points.length >= 3) {
      for (var s = 1; s < points.length - 1; s++) {
        var x0 = xAt(s)
        var y0 = yAt(Number(points[s].value))
        var x1 = xAt(s + 1)
        var y1 = yAt(Number(points[s + 1].value))
        ctx.quadraticCurveTo(x0, y0, (x0 + x1) / 2, (y0 + y1) / 2)
      }
      ctx.lineTo(xAt(points.length - 1), yAt(Number(points[points.length - 1].value)))
    } else {
      for (var p = 1; p < points.length; p++)
        ctx.lineTo(xAt(p), yAt(Number(points[p].value)))
    }
    var lastX = xAt(points.length - 1)
    var bottomY = padT + plotH
    ctx.lineTo(lastX, bottomY)
    ctx.lineTo(xAt(0), bottomY)
    ctx.closePath()
    var grad = ctx.createLinearGradient(0, padT, 0, bottomY)
    var fillRgb = rising ? "255, 138, 31" : "255, 107, 107"
    grad.addColorStop(0, "rgba(" + fillRgb + ", 0.22)")
    grad.addColorStop(1, "rgba(" + fillRgb + ", 0.02)")
    ctx.fillStyle = grad
    ctx.fill()

    // Stroke line
    ctx.beginPath()
    ctx.moveTo(xAt(0), yAt(Number(points[0].value)))
    if (points.length >= 3) {
      for (var n = 1; n < points.length - 1; n++) {
        var nx0 = xAt(n)
        var ny0 = yAt(Number(points[n].value))
        var nx1 = xAt(n + 1)
        var ny1 = yAt(Number(points[n + 1].value))
        ctx.quadraticCurveTo(nx0, ny0, (nx0 + nx1) / 2, (ny0 + ny1) / 2)
      }
      ctx.lineTo(xAt(points.length - 1), yAt(Number(points[points.length - 1].value)))
    } else {
      for (var m = 1; m < points.length; m++)
        ctx.lineTo(xAt(m), yAt(Number(points[m].value)))
    }
    ctx.strokeStyle = stroke
    ctx.lineWidth = 2.5
    ctx.lineCap = "round"
    ctx.lineJoin = "round"
    ctx.stroke()

    // Interior dots (muted) + emphasized end point
    for (var d = 0; d < points.length; d++) {
      var dx = xAt(d)
      var dy = yAt(Number(points[d].value))
      var isEnd = d === points.length - 1
      if (isEnd) {
        ctx.beginPath()
        ctx.arc(dx, dy, 4.5, 0, Math.PI * 2)
        ctx.fillStyle = stroke
        ctx.fill()
        ctx.beginPath()
        ctx.arc(dx, dy, 4.5, 0, Math.PI * 2)
        ctx.strokeStyle = "rgba(255, 255, 255, 0.85)"
        ctx.lineWidth = 1.5
        ctx.stroke()
      } else if (d > 0) {
        ctx.beginPath()
        ctx.arc(dx, dy, 2, 0, Math.PI * 2)
        ctx.fillStyle = "rgba(255, 255, 255, 0.35)"
        ctx.fill()
      }
    }
  }

  function pctText(value) {
    if (value === undefined || value === null || value === "") return "P/L —"
    var amount = Number(value)
    if (!isFinite(amount)) return "P/L —"
    var sign = amount > 0 ? "+" : ""
    return "P/L " + sign + amount.toFixed(2) + "%"
  }

  function cardTone(value) {
    var amount = Number(value)
    if (!isFinite(amount) || amount === 0) return Color.popups.text
    return amount > 0 ? "#7dce82" : "#e07a7a"
  }

  function dashboardSections(payload) {
    var raw = payload && payload.books ? payload.books.slice(0) : []
    var indexed = []
    for (var r = 0; r < raw.length; r++) indexed.push({ book: raw[r], index: r })
    indexed.sort(function(a, b) {
      var ra = bookOrder.indexOf(String((a.book || {}).name || ""))
      var rb = bookOrder.indexOf(String((b.book || {}).name || ""))
      if (ra < 0) ra = 100
      if (rb < 0) rb = 100
      return ra !== rb ? ra - rb : a.index - b.index
    })
    var out = []
    for (var i = 0; i < indexed.length; i++) {
      var book = indexed[i].book
      if (!book || typeof book !== "object") continue
      var name = String(book.name || "")
      var metrics = []
      var extra = []
      if (name === "treasury") {
        metrics.push(metric("Mark value", maybeDollars(book.equity_usd, false)))
        metrics.push(metric("Cost basis", maybeDollars(book.bankroll_usd, false)))
        metrics.push(metric("Total P/L", maybeDollars(book.daily_pnl_usd, true), toneFor(book.daily_pnl_usd)))
        metrics.push(metric("Holdings", tableQty(book.holdings_btc) + " BTC"))
        if (book.avg_price_usd !== undefined && book.avg_price_usd !== null)
          extra.push(metric("Avg cost", dollars(book.avg_price_usd, false)))
        if (book.mark_btc_usd !== undefined && book.mark_btc_usd !== null)
          extra.push(metric("BTC spot", dollars(book.mark_btc_usd, false)))
        if (book.contribution_count !== undefined && book.contribution_count !== null)
          extra.push(metric("Contributions", String(book.contribution_count)))
      } else {
        var open = (book.open_positions === undefined || book.open_positions === null) ? "—" : String(book.open_positions)
        if (book.max_book_positions) open += " / " + book.max_book_positions
        metrics.push(metric("Equity", maybeDollars(book.equity_usd, false)))
        metrics.push(metric("Open lots", open))
        metrics.push(metric("Day P/L", maybeDollars(book.daily_pnl_usd, true), toneFor(book.daily_pnl_usd)))
        if (book.cash_usd !== undefined && book.cash_usd !== null && name !== "coinbase")
          metrics.push(metric("Cash", dollars(book.cash_usd, false)))
        if (book.daily_loss_kill_usd !== undefined && book.daily_loss_kill_usd !== null)
          extra.push(metric("Loss stop", dollars(book.daily_loss_kill_usd, false)))
        if (book.bankroll_usd !== undefined && book.bankroll_usd !== null
            && amountsDiffer(book.bankroll_usd, book.equity_usd) && amountsDiffer(book.bankroll_usd, book.cash_usd))
          extra.push(metric("Bankroll", dollars(book.bankroll_usd, false)))
        if (book.account_value_usd !== undefined && book.account_value_usd !== null
            && amountsDiffer(book.account_value_usd, book.equity_usd) && amountsDiffer(book.account_value_usd, book.cash_usd))
          extra.push(metric("Account", dollars(book.account_value_usd, false)))
        if (book.budget_usd !== undefined && book.budget_usd !== null
            && amountsDiffer(book.budget_usd, book.equity_usd) && amountsDiffer(book.budget_usd, book.cash_usd))
          extra.push(metric("Budget", dollars(book.budget_usd, false)))
      }

      var held = []
      var source = book.positions || []
      for (var p = 0; p < source.length; p++) {
        var pos = source[p]
        if (!pos || typeof pos !== "object") continue
        // Spot: hide dust lots worth $1 or less.
        if ((name === "coinbase" || name === "crypto") && spotNotional(pos) <= 1.0) continue
        held.push(pos)
      }
      var limit = (name === "coinbase" || name === "crypto" || name === "treasury") ? -1 : 20
      var shown = limit < 0 ? held : held.slice(0, limit)
      var columns = columnsFor(name)
      var rows = []
      for (var s = 0; s < shown.length; s++) {
        var cells = []
        for (var c = 0; c < columns.length; c++) cells.push(cellFor(shown[s], columns[c].key))
        rows.push(cells)
      }
      var title = bookTitle(name).toUpperCase()
      if (book.mode) title += "  ·  " + String(book.mode).toUpperCase()
      out.push({
        title: title,
        metrics: metrics,
        extra: extra,
        columns: columns,
        rows: rows,
        tableLabel: (name === "coinbase" || name === "crypto") ? "OPEN LOTS" : "HOLDINGS",
        more: (limit >= 0 && held.length > limit) ? ("… " + (held.length - limit) + " more not shown") : ""
      })
    }
    return out
  }

  function hostLabel() {
    var host = String(baseUrl || "").replace(/^https?:\/\//, "").replace(/\/.*$/, "")
    if (host.indexOf("192.168.1.24") === 0) return "Brown-02"
    if (host.indexOf("192.168.1.169") === 0) return "Brown-01"
    return host || "host"
  }

  function amountsDiffer(a, b) {
    if (a === undefined || a === null || b === undefined || b === null) return true
    var left = Number(a)
    var right = Number(b)
    if (!isFinite(left) || !isFinite(right)) return true
    return Math.abs(left - right) > 0.50
  }

  function brokerAccount() {
    var value = null
    for (var i = 0; i < books.length; i++) {
      var account = books[i].account_value_usd
      if (account === undefined || account === null || !isFinite(Number(account))) continue
      if (value === null) value = Number(account)
      else if (Math.abs(value - Number(account)) > 1) return null
    }
    return value
  }

  function buildFacts() {
    var parts = [hostLabel()]
    if (!sawHealth) return parts.join(" · ") + " · checking"
    if (!reachable) return parts.join(" · ") + " · offline · " + baseUrl
    if (!hasDetail) {
      parts.push(mode || "up")
      parts.push(snapBusy ? "reading" : (detailError || "waiting"))
      return parts.join(" · ")
    }
    parts.push(tradingLabel())
    if (detail.tick_age_label) parts.push("tick " + detail.tick_age_label)
    else if (tickAge >= 0) parts.push("tick " + tickAge + "s")
    if (halted) parts.push("halt")
    if (killed) parts.push("stop")
    if (detail.last_error) parts.push(String(detail.last_error))
    if (blocks && blocks.length > 0) parts.push("blocked " + blocks.join(", "))
    if (armRestart) parts.push("confirm restart")
    if (level === "fault" || level === "offline") parts.push(baseUrl)
    return parts.join(" · ")
  }

  function parsePayload(text) {
    var line = String(text || "").replace(/\s+$/, "")
    var start = line.lastIndexOf("\n")
    if (start >= 0) line = line.slice(start + 1)
    try {
      return JSON.parse(line)
    } catch (error) {
      return null
    }
  }

  function pollHealth() {
    if (!healthProc.running) healthProc.running = true
  }

  function pollDetail() {
    if (snapProc.running) return
    loadPercent = 0
    loadStage = "Starting"
    snapProc.running = true
  }

  function ingestSnapshotLine(line) {
    var payload = parsePayload(line)
    if (!payload) return
    if (payload.progress !== undefined && payload.detail !== true) {
      var percent = Math.round(Number(payload.progress))
      if (isFinite(percent)) loadPercent = Math.max(0, Math.min(100, percent))
      if (payload.stage) loadStage = String(payload.stage)
      return
    }
    if (payload.detail === true) {
      detail = payload
      detailError = ""
      sections = dashboardSections(payload)
      portfolio = payload.portfolio || []
      refreshedAt = Qt.formatDateTime(new Date(), "h:mm AP")
      chartCanvas.requestPaint()
      loadPercent = 100
      loadStage = "Done"
    } else if (payload.kind === "snapshot") {
      detailError = payload.detail_error || "no detail"
      loadPercent = 100
      loadStage = detailError
    }
  }

  function refresh() {
    armRestart = false
    restartMessage = ""
    pollHealth()
    pollDetail()
  }

  function onRestartClicked() {
    if (restartProc.running) return
    if (!armRestart) {
      armRestart = true
      return
    }
    armRestart = false
    restartMessage = "Restarting the snowball container."
    restartProc.running = true
  }

  function open() { popupOpen = true }
  function close() {
    popupOpen = false
    armRestart = false
  }
  function togglePopup() { popupOpen = !popupOpen }

  implicitWidth: vertical ? barSize : chip.implicitWidth + Style.space(8)
  implicitHeight: barSize

  Timer {
    interval: root.pollSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.pollHealth()
  }

  Timer {
    interval: Math.max(60, root.snapshotSec) * 1000
    running: root.snapshotSec > 0
    repeat: true
    triggeredOnStart: true
    onTriggered: root.pollDetail()
  }

  Process {
    id: healthProc
    command: ["python3", root.script, "health", root.baseUrl]
    stdout: StdioCollector {
      onStreamFinished: {
        var payload = root.parsePayload(text)
        root.sawHealth = true
        if (!payload) {
          root.healthError = "bad health payload"
          root.health = { reachable: false }
          return
        }
        root.health = payload
        root.healthError = payload.reachable ? "" : (payload.error || "unreachable")
      }
    }
  }

  Process {
    id: snapProc
    command: ["python3", root.script, "snapshot", root.baseUrl, root.sshUser, root.containerName]
    stdout: SplitParser {
      onRead: function(line) { root.ingestSnapshotLine(line) }
    }
  }

  Process {
    id: restartProc
    command: ["python3", root.script, "restart", root.baseUrl, root.sshUser, root.containerName]
    stdout: StdioCollector {
      onStreamFinished: {
        var payload = root.parsePayload(text)
        root.armRestart = false
        if (payload && payload.ok === true) {
          root.restartMessage = "Restarted. Waiting for the bot to answer."
          root.detail = ({})
        } else {
          root.restartMessage = "Restart failed. " + ((payload && payload.error) || "no answer")
        }
        root.pollHealth()
      }
    }
  }

  Rectangle {
    id: chip
    anchors.centerIn: parent
    implicitWidth: chipRow.implicitWidth + Style.space(16)
    implicitHeight: Math.min(root.barSize - Style.space(6), Style.space(28))
    radius: height / 2
    color: Color.notifications.background
    border.width: 1
    border.color: root.level === "fault" ? root.tone : Color.popups.border

    Row {
      id: chipRow
      anchors.centerIn: parent
      spacing: Style.space(6)

      Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(8)
        height: Style.space(8)
        radius: width / 2
        color: root.tone
      }

      Text {
        visible: !root.vertical
        anchors.verticalCenter: parent.verticalCenter
        text: root.barLabel
        color: Color.notifications.text
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.caption
        font.bold: true
        renderType: Text.NativeRendering
      }
    }
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onEntered: {
      root.hovered = true
      if (root.bar) root.bar.showTooltip(root, root.headline || root.facts || root.barLabel)
    }
    onExited: {
      root.hovered = false
      if (root.bar) root.bar.hideTooltip(root)
    }
    onClicked: root.togglePopup()
  }

  // ── Otter-style building blocks ─────────────────────────────────────
  // Inline components do not share the file's id scope, so the palette is
  // spelled out here rather than read from root.
  component OtterText: Text {
    color: "#F2E8DE"
    font.family: "JetBrainsMono Nerd Font"
    font.pixelSize: 11
    renderType: Text.NativeRendering
  }

  component OtterCard: Rectangle {
    id: card
    property color stripe: "#FF8A1F"
    property color wash: "#2A1810"
    property real washStop: 0.36
    default property alias content: cardInner.data
    width: parent ? parent.width : 0
    implicitHeight: cardInner.implicitHeight + 24
    radius: 10
    border.width: 1
    border.color: "#C45C12"
    gradient: Gradient {
      orientation: Gradient.Horizontal
      GradientStop { position: 0.0; color: card.wash }
      GradientStop { position: card.washStop; color: "#15110E" }
    }

    Rectangle {
      x: 1
      y: 1
      width: 4
      height: parent.height - 2
      radius: 2
      color: card.stripe
    }

    Column {
      id: cardInner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.leftMargin: 16
      anchors.rightMargin: 14
      anchors.topMargin: 12
      spacing: 8
    }
  }

  component OtterButton: Rectangle {
    id: btn
    property string text: ""
    property bool active: true
    property color tint: "#FF8A1F"
    signal clicked()
    implicitWidth: btnLabel.implicitWidth + 24
    implicitHeight: btnLabel.implicitHeight + 10
    radius: 6
    color: btnMouse.containsMouse && btn.active ? "#3D220A" : "#211813"
    border.width: 1
    border.color: btn.tint
    opacity: btn.active ? 1.0 : 0.55

    OtterText {
      id: btnLabel
      anchors.centerIn: parent
      text: btn.text
      color: btn.tint
    }

    MouseArea {
      id: btnMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: btn.active ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: if (btn.active) btn.clicked()
    }
  }

  component MetricRow: Row {
    id: mrow
    property var items: []
    property bool hero: false
    width: parent ? parent.width : 0
    spacing: 12
    Repeater {
      model: mrow.items
      delegate: Column {
        required property var modelData
        width: (mrow.width - mrow.spacing * Math.max(0, mrow.items.length - 1)) / Math.max(1, mrow.items.length)
        spacing: 2
        OtterText {
          width: parent.width
          text: modelData.caption
          color: "#B9A79A"
          font.pixelSize: 10
          elide: Text.ElideRight
        }
        OtterText {
          width: parent.width
          text: modelData.value
          color: modelData.color
          font.pixelSize: mrow.hero ? 26 : 18
          font.bold: true
          elide: Text.ElideRight
        }
      }
    }
  }

  PopupCard {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    padding: 0
    borderColor: root.cBorder
    readonly property real desiredHeight: header.height
      + (progressWrap.visible ? progressWrap.height : 0)
      + bodyCol.implicitHeight + 26
    contentWidth: popup.fittedContentWidth(860)
    contentHeight: popup.fittedContentHeight(desiredHeight, 760)

    Rectangle {
      id: shellBg
      anchors.fill: parent
      color: root.cBg
      radius: Style.cornerRadius
      clip: true

      Column {
        width: parent.width
        spacing: 0

        // Header: title, refresh, witty subtitle, status chips
        Rectangle {
          id: header
          width: parent.width
          height: headerCol.implicitHeight + 27
          color: root.cSurface

          Column {
            id: headerCol
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.leftMargin: 16
            anchors.rightMargin: 16
            anchors.topMargin: 14
            spacing: 4

            Item {
              width: parent.width
              height: Math.max(titleText.implicitHeight, refreshButton.implicitHeight)

              OtterText {
                id: titleText
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: "❄  Snowball Robo Trader"
                color: root.cAccent
                font.pixelSize: 15
                font.bold: true
              }

              Row {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: 8

                OtterText {
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.refreshedAt === "" ? "—" : root.refreshedAt
                  color: root.cMuted
                }

                OtterButton {
                  id: refreshButton
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.snapBusy ? "Refreshing" : "Refresh"
                  active: !root.snapBusy && !root.restartBusy
                  onClicked: root.refresh()
                }
              }
            }

            OtterText {
              width: parent.width
              text: root.popupSubtitle
              color: root.cMuted
              elide: Text.ElideRight
            }

            Row {
              spacing: 6
              topPadding: 2

              Repeater {
                model: root.statusChips
                delegate: Rectangle {
                  required property var modelData
                  readonly property color tc: root.toneColor(modelData.tone)
                  width: chipText.implicitWidth + 18
                  height: chipText.implicitHeight + 4
                  radius: height / 2
                  color: Qt.rgba(tc.r, tc.g, tc.b, 0.16)
                  border.width: 1
                  border.color: tc

                  OtterText {
                    id: chipText
                    anchors.centerIn: parent
                    text: modelData.label
                    color: parent.tc
                    font.pixelSize: 9
                    font.bold: true
                  }
                }
              }
            }
          }

          Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: 1
            color: root.cBorder
          }
        }

        // Loading strip while the Coinbase snapshot runs
        Rectangle {
          id: progressWrap
          visible: root.snapBusy
          width: parent.width
          height: visible ? progressCol.implicitHeight + 18 : 0
          color: root.cSurface

          Column {
            id: progressCol
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.leftMargin: 16
            anchors.rightMargin: 16
            anchors.topMargin: 8
            spacing: 4

            OtterText {
              text: root.loadPercent + "%  ·  " + (root.loadStage || "Loading")
              color: root.cMuted
              font.pixelSize: 10
            }

            Rectangle {
              width: parent.width
              height: 6
              radius: 4
              color: root.cSurfaceAlt

              Rectangle {
                width: parent.width * Math.max(0, Math.min(100, root.loadPercent)) / 100
                height: parent.height
                radius: parent.radius
                color: root.cAccent
              }
            }
          }

          Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: 1
            color: root.cBorder
          }
        }

        Flickable {
          id: bodyScroll
          width: parent.width
          height: Math.max(0, shellBg.height - header.height - progressWrap.height)
          contentWidth: width
          contentHeight: bodyCol.implicitHeight + 26
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          flickableDirection: Flickable.VerticalFlick
          interactive: contentHeight > height

          Column {
            id: bodyCol
            x: 14
            y: 12
            width: bodyScroll.width - 28
            spacing: 12

            // Portfolio 7d chart
            OtterCard {
              visible: root.portfolio.length >= 1
              washStop: 0.28

              Item {
                width: parent.width
                height: Math.max(chartTitleRow.implicitHeight, chartWeekChange.implicitHeight)

                Row {
                  id: chartTitleRow
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: 8

                  OtterText {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "PORTFOLIO 7D"
                    color: root.cAccent
                    font.pixelSize: 12
                    font.bold: true
                    font.letterSpacing: 0.6
                  }

                  OtterText {
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.dollars(root.portfolioValue(-1), false)
                    font.pixelSize: 28
                    font.bold: true
                  }

                  OtterText {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "7d"
                    color: root.cMuted
                    font.pixelSize: 10
                  }
                }

                OtterText {
                  id: chartWeekChange
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.weekChangeText()
                  color: {
                    var tone = root.toneFor(root.portfolioValue(-1) - root.portfolioValue(0))
                    return tone ? root.toneColor(tone) : root.cMuted
                  }
                  font.pixelSize: 10
                }
              }

              Canvas {
                id: chartCanvas
                width: parent.width
                height: 168
                onPaint: root.paintPortfolio(chartCanvas)
                onWidthChanged: requestPaint()
                onHeightChanged: requestPaint()
              }

              Item {
                width: parent.width
                height: chartStart.implicitHeight

                OtterText {
                  id: chartStart
                  anchors.left: parent.left
                  text: root.portfolio.length ? root.portfolio[0].label : ""
                  color: root.cMuted
                  font.pixelSize: 10
                }
                OtterText {
                  anchors.right: parent.right
                  text: root.portfolio.length ? root.portfolio[root.portfolio.length - 1].label : ""
                  color: root.cMuted
                  font.pixelSize: 10
                }
              }
            }

            // Portfolio hero metrics: Day P/L + Equity at 26px
            OtterCard {
              readonly property string pnlTone: root.toneFor(root.dayPnl)
              stripe: pnlTone === "ok" ? root.cOk : (pnlTone === "bad" ? root.cBad : root.cAccent)
              wash: pnlTone === "ok" ? "#102418" : (pnlTone === "bad" ? "#2A1212" : "#2A1810")

              OtterText {
                text: "PORTFOLIO"
                color: root.cAccent
                font.pixelSize: 12
                font.bold: true
                font.letterSpacing: 0.6
              }

              Row {
                width: parent.width
                spacing: 12

                MetricRow {
                  width: (parent.width - 12) * 2 / 3
                  hero: true
                  items: [
                    root.metric("Day P/L", root.hasDetail ? root.maybeDollars(root.detail.daily_pnl_usd, true) : "—", root.toneFor(root.dayPnl)),
                    root.metric("Equity", root.hasDetail ? root.maybeDollars(root.detail.equity_usd, false) : "—")
                  ]
                }

                MetricRow {
                  width: (parent.width - 12) / 3
                  items: [root.metric("Cash", root.hasDetail ? root.maybeDollars(root.detail.cash_usd, false) : "—")]
                }
              }

              OtterText {
                readonly property string footText: {
                  var parts = []
                  if (root.hasDetail && root.detail.tick_age_label) parts.push("tick " + root.detail.tick_age_label)
                  else if (root.tickAge >= 0) parts.push("tick " + root.tickAge + "s")
                  if (root.hasDetail && root.detail.source) parts.push(String(root.detail.source))
                  return parts.join(" · ")
                }
                visible: footText.length > 0
                text: footText
                color: root.cMuted
                font.pixelSize: 10
              }
            }

            // Flags: block reasons / last error
            OtterCard {
              visible: root.flagList.length > 0
              stripe: root.cWarn
              wash: "#2A2010"

              OtterText {
                text: "FLAGS"
                color: root.cAccent
                font.pixelSize: 12
                font.bold: true
                font.letterSpacing: 0.6
              }

              Repeater {
                model: root.flagList
                delegate: OtterText {
                  required property var modelData
                  width: parent ? parent.width : 0
                  text: "· " + modelData
                  color: root.cWarn
                  wrapMode: Text.WordWrap
                }
              }
            }

            // Waiting for the first snapshot
            OtterCard {
              visible: root.sections.length === 0
              stripe: root.cAccent

              OtterText {
                text: "SNAPSHOT"
                color: root.cAccent
                font.pixelSize: 12
                font.bold: true
                font.letterSpacing: 0.6
              }

              OtterText {
                width: parent.width
                text: root.snapBusy
                  ? "Reading Coinbase balances over SSH…"
                  : (root.detailError ? ("No detail yet: " + root.detailError) : "Detail snapshot not ready yet.\nChip fills once Coinbase SSH returns.")
                color: root.cMuted
                font.pixelSize: 10
                wrapMode: Text.WordWrap
              }
            }

            // Per-book cards
            Repeater {
              model: root.sections
              delegate: OtterCard {
                id: bookCard
                required property var modelData
                readonly property var sec: modelData
                stripe: root.cBorder
                wash: "#1C120C"
                washStop: 0.30

                OtterText {
                  text: bookCard.sec.title
                  color: root.cAccent
                  font.pixelSize: 12
                  font.bold: true
                  font.letterSpacing: 0.6
                }

                MetricRow {
                  items: bookCard.sec.metrics
                }

                MetricRow {
                  visible: bookCard.sec.extra.length > 0
                  items: bookCard.sec.extra
                }

                OtterText {
                  visible: bookCard.sec.rows.length > 0
                  text: bookCard.sec.tableLabel
                  color: root.cMuted
                  font.pixelSize: 10
                }

                Column {
                  id: table
                  visible: bookCard.sec.rows.length > 0
                  width: parent.width
                  spacing: 3

                  Row {
                    spacing: 10
                    Repeater {
                      model: bookCard.sec.columns
                      delegate: OtterText {
                        required property var modelData
                        required property int index
                        width: root.columnWidth(bookCard.sec.columns, index, table.width)
                        horizontalAlignment: modelData.align === "right" ? Text.AlignRight : Text.AlignLeft
                        text: modelData.title
                        color: root.cMuted
                        font.pixelSize: 9
                        font.bold: true
                        font.letterSpacing: 0.4
                        elide: Text.ElideRight
                      }
                    }
                  }

                  Repeater {
                    model: bookCard.sec.rows
                    delegate: Row {
                      id: posRow
                      required property var modelData
                      readonly property var cells: modelData
                      spacing: 10
                      Repeater {
                        model: posRow.cells
                        delegate: OtterText {
                          required property var modelData
                          required property int index
                          width: root.columnWidth(bookCard.sec.columns, index, table.width)
                          horizontalAlignment: bookCard.sec.columns[index].align === "right" ? Text.AlignRight : Text.AlignLeft
                          text: modelData.text
                          color: modelData.color
                          font.pixelSize: 10
                          elide: Text.ElideRight
                        }
                      }
                    }
                  }
                }

                OtterText {
                  visible: bookCard.sec.more.length > 0
                  text: bookCard.sec.more
                  color: root.cMuted
                  font.pixelSize: 10
                }
              }
            }

            // Host status + restart (kept from the Omarchy plugin)
            OtterCard {
              stripe: root.level === "fault" ? root.cBad : (root.level === "offline" ? root.cWarn : root.cBorder)
              wash: "#1C120C"
              washStop: 0.30

              OtterText {
                text: "HOST"
                color: root.cAccent
                font.pixelSize: 12
                font.bold: true
                font.letterSpacing: 0.6
              }

              OtterText {
                width: parent.width
                visible: root.headline.length > 0
                text: root.headline
                wrapMode: Text.WordWrap
              }

              OtterText {
                width: parent.width
                visible: root.facts.length > 0
                text: root.facts
                color: root.cMuted
                font.pixelSize: 10
                wrapMode: Text.WordWrap
              }

              Row {
                spacing: 10
                topPadding: 2

                OtterButton {
                  text: root.restartBusy ? "Restarting" : (root.armRestart ? "Restart now" : "Restart")
                  active: !root.restartBusy
                  tint: root.armRestart ? root.cBad : root.cAccent
                  onClicked: root.onRestartClicked()
                }

                OtterButton {
                  visible: root.armRestart && !root.restartBusy
                  text: "Cancel"
                  tint: root.cMuted
                  onClicked: root.armRestart = false
                }
              }
            }
          }
        }
      }
    }
  }
}
