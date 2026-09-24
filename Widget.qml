import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Status chip for the Snowball auto trader. One /api/snapshot carries every
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

    var strokeGreen = "#3cba7a"
    var strokeRed = "#e07a7a"

    if (points.length === 1) {
      var cx = canvas.width / 2
      var cy = canvas.height / 2
      ctx.beginPath()
      ctx.arc(cx, cy, 10, 0, Math.PI * 2)
      ctx.fillStyle = "rgba(60, 186, 122, 0.18)"
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
      ctx.strokeStyle = "rgba(255, 255, 255, 0.10)"
      ctx.lineWidth = 1
      ctx.stroke()
      ctx.fillStyle = "rgba(255, 255, 255, 0.45)"
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
    var fillRgb = rising ? "60, 186, 122" : "224, 122, 122"
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
    var rows = payload && payload.books ? payload.books : []
    var sections = []
    for (var i = 0; i < rows.length; i++) {
      var book = rows[i]
      var open = (book.open_positions === undefined || book.open_positions === null) ? "—" : String(book.open_positions)
      if (book.max_book_positions) open += " / " + book.max_book_positions
      var day = (book.daily_pnl_usd === undefined || book.daily_pnl_usd === null) ? "—" : dollars(book.daily_pnl_usd, true)
      if (book.daily_loss_kill_usd !== undefined && book.daily_loss_kill_usd !== null)
        day += " / " + dollars(book.daily_loss_kill_usd, false)
      var cards = [
        { label: "Equity", value: (book.equity_usd === undefined || book.equity_usd === null) ? "—" : dollars(book.equity_usd, false), color: Color.popups.text },
        { label: "Cash", value: dollars(book.cash_usd, false), color: Color.popups.text },
        { label: "Day", value: day, color: cardTone(book.daily_pnl_usd) },
        { label: "Open", value: open, color: Color.popups.text }
      ]
      if (book.bankroll_usd !== undefined && book.bankroll_usd !== null
          && amountsDiffer(book.bankroll_usd, book.equity_usd)
          && amountsDiffer(book.bankroll_usd, book.cash_usd))
        cards.splice(1, 0, { label: "Bankroll", value: dollars(book.bankroll_usd, false), color: Color.popups.text })
      if (book.account_value_usd !== undefined && book.account_value_usd !== null
          && amountsDiffer(book.account_value_usd, book.equity_usd)
          && amountsDiffer(book.account_value_usd, book.cash_usd))
        cards.push({ label: "Account", value: dollars(book.account_value_usd, false), color: Color.popups.text })
      if (book.budget_usd !== undefined && book.budget_usd !== null
          && amountsDiffer(book.budget_usd, book.equity_usd)
          && amountsDiffer(book.budget_usd, book.cash_usd))
        cards.push({ label: "Budget", value: dollars(book.budget_usd, false), color: Color.popups.text })
      var title = bookTitle(book.name)
      if (book.mode) title += " · " + book.mode
      var positions = []
      var held = book.positions || []
      var positionTotal = 0
      var valued = 0
      for (var p = 0; p < held.length; p++) {
        var heldValue = Number(held[p].value_usd)
        if (isFinite(heldValue)) {
          positionTotal += heldValue
          valued += 1
        }
        positions.push({ text: positionLine(held[p]), color: cardTone(held[p].pnl_pct) })
      }
      var showPositions = positions.length > 0
      var positionLabel = valued > 0
        ? ("Open positions · " + dollars(positionTotal, false))
        : "Open positions"
      sections.push({
        title: title,
        cards: cards,
        positions: positions,
        positionLabel: positionLabel,
        showPositions: showPositions
      })
    }
    return sections
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

  PopupCard {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    contentWidth: popup.fittedContentWidth(Style.space(720))
    contentHeight: popup.fittedContentHeight(bodyCol.implicitHeight, Style.space(640))

    Flickable {
      id: bodyScroll
      anchors.fill: parent
      contentWidth: width
      contentHeight: bodyCol.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      flickableDirection: Flickable.VerticalFlick
      interactive: contentHeight > height

      Column {
        id: bodyCol
        width: bodyScroll.width
        spacing: Style.space(10)

      Column {
        width: parent.width
        spacing: Style.space(4)

        Item {
          width: parent.width
          height: Math.max(titleText.implicitHeight, refreshText.implicitHeight)

          Text {
            id: titleText
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "Snowball Robo Trader"
            color: Color.popups.text
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.subtitle
            font.bold: true
            renderType: Text.NativeRendering
          }

          Text {
            id: refreshText
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.refreshedAt === "" ? "—" : root.refreshedAt
            color: Color.muted
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            renderType: Text.NativeRendering
          }
        }

        Row {
          spacing: Style.space(6)

          Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(8)
            height: Style.space(8)
            radius: width / 2
            color: root.tone
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: {
              var parts = [root.stateWord(), root.tradingLabel()]
              if (root.hasDetail && root.detail.tick_age_label)
                parts.push(root.detail.tick_age_label)
              else if (root.tickAge >= 0)
                parts.push(root.tickAge + "s")
              return parts.join(" · ")
            }
            color: Color.muted
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            renderType: Text.NativeRendering
          }
        }
      }

      Item {
        id: chartBox
        width: parent.width
        height: root.portfolio.length >= 1 ? Style.space(180) : 0
        visible: root.portfolio.length >= 1

        Item {
          id: chartHeader
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          height: Math.max(chartTitleRow.implicitHeight, chartWeekChange.implicitHeight)

          Row {
            id: chartTitleRow
            anchors.left: parent.left
            anchors.right: chartWeekChange.left
            anchors.rightMargin: Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(8)

            Text {
              id: chartTitle
              anchors.verticalCenter: parent.verticalCenter
              text: "Portfolio"
              color: Color.popups.text
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
              font.bold: true
              renderType: Text.NativeRendering
            }

            Text {
              id: chartEquity
              anchors.verticalCenter: parent.verticalCenter
              text: root.dollars(root.portfolioValue(-1), false)
              color: Color.popups.text
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.subtitle * 2
              font.bold: true
              renderType: Text.NativeRendering
            }

            Text {
              id: chartRangeCaption
              anchors.verticalCenter: parent.verticalCenter
              text: "7d"
              color: Color.muted
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
              renderType: Text.NativeRendering
            }
          }

          Text {
            id: chartWeekChange
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.weekChangeText()
            color: root.cardTone(root.portfolioValue(-1) - root.portfolioValue(0))
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            renderType: Text.NativeRendering
          }
        }

        Canvas {
          id: chartCanvas
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: chartHeader.bottom
          anchors.topMargin: Style.space(8)
          anchors.bottom: chartDates.top
          onPaint: root.paintPortfolio(chartCanvas)
          onWidthChanged: requestPaint()
          onHeightChanged: requestPaint()
        }

        Item {
          id: chartDates
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          height: chartStart.implicitHeight

          Text {
            id: chartStart
            anchors.left: parent.left
            text: root.portfolio.length ? root.portfolio[0].label : ""
            color: Color.muted
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            renderType: Text.NativeRendering
          }
          Text {
            anchors.right: parent.right
            text: root.portfolio.length ? root.portfolio[root.portfolio.length - 1].label : ""
            color: Color.muted
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            renderType: Text.NativeRendering
          }
        }
      }

      Text {
        width: parent.width
        visible: root.headline.length > 0
        text: root.headline
        wrapMode: Text.WordWrap
        color: Color.popups.text
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.body
        renderType: Text.NativeRendering
      }

      Text {
        width: parent.width
        visible: root.facts.length > 0
        text: root.facts
        wrapMode: Text.WordWrap
        color: Color.muted
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.caption
        renderType: Text.NativeRendering
      }

      Column {
        visible: root.snapBusy
        width: parent.width
        spacing: Style.space(4)

        Text {
          width: parent.width
          text: root.loadPercent + "%  ·  " + (root.loadStage || "Loading")
          color: Color.muted
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
          renderType: Text.NativeRendering
        }

        Rectangle {
          width: parent.width
          height: Style.space(6)
          radius: height / 2
          color: Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.12)

          Rectangle {
            width: parent.width * Math.max(0, Math.min(100, root.loadPercent)) / 100
            height: parent.height
            radius: parent.radius
            color: "#3cba7a"
          }
        }
      }

      Column {
        id: boardCol
        width: parent.width
        spacing: Style.space(10)

          Text {
            visible: root.sections.length === 0
            width: parent.width
            text: root.snapBusy ? "Reading cards…" : "No cards yet."
            color: Color.muted
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            renderType: Text.NativeRendering
          }

          Repeater {
            model: root.sections
            delegate: Rectangle {
              required property var modelData
              width: boardCol.width
              radius: Style.space(8)
              color: Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.06)
              border.width: 1
              border.color: Color.popups.border
              implicitHeight: sectionInner.implicitHeight + Style.space(20)

              Column {
                id: sectionInner
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: Style.space(10)
                spacing: Style.space(8)

                Text {
                  width: parent.width
                  text: modelData.title
                  color: Color.muted
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  font.capitalization: Font.AllUppercase
                  renderType: Text.NativeRendering
                }

                Grid {
                  width: parent.width
                  columns: 4
                  columnSpacing: Style.space(6)
                  rowSpacing: Style.space(6)

                  Repeater {
                    model: modelData.cards
                    delegate: Rectangle {
                      required property var modelData
                      width: (sectionInner.width - Style.space(6) * 3) / 4
                      height: Style.space(60)
                      radius: Style.space(6)
                      color: Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.06)
                      border.width: 1
                      border.color: Color.popups.border

                      Column {
                        anchors.fill: parent
                        anchors.margins: Style.space(6)
                        spacing: Style.space(2)

                        Text {
                          width: parent.width
                          text: modelData.label
                          color: Color.muted
                          font.family: root.bar ? root.bar.fontFamily : Style.font.family
                          font.pixelSize: Style.font.caption
                          font.capitalization: Font.AllUppercase
                          elide: Text.ElideRight
                          renderType: Text.NativeRendering
                        }

                        Text {
                          width: parent.width
                          text: modelData.value
                          color: modelData.color
                          font.family: root.bar ? root.bar.fontFamily : Style.font.family
                          font.pixelSize: Style.font.body
                          font.bold: true
                          elide: Text.ElideRight
                          renderType: Text.NativeRendering
                        }
                      }
                    }
                  }
                }

                Column {
                  visible: modelData.showPositions === true
                  width: parent.width
                  spacing: Style.space(2)

                  Text {
                    width: parent.width
                    text: modelData.positionLabel || "Open positions"
                    color: Color.muted
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.caption
                    font.capitalization: Font.AllUppercase
                    renderType: Text.NativeRendering
                  }

                  Repeater {
                    model: modelData.positions
                    delegate: Text {
                      required property var modelData
                      width: sectionInner.width
                      text: modelData.text
                      wrapMode: Text.WordWrap
                      color: modelData.color
                      font.family: root.bar ? root.bar.fontFamily : Style.font.family
                      font.pixelSize: Style.font.caption
                      renderType: Text.NativeRendering
                    }
                  }
                }
              }
            }
          }
        }

      Row {
        spacing: Style.space(10)

        Button {
          text: root.snapBusy ? "Refreshing" : "Refresh"
          enabled: !root.snapBusy && !root.restartBusy
          bordered: true
          foreground: Color.popups.text
          onClicked: root.refresh()
        }

        Button {
          text: root.restartBusy ? "Restarting" : (root.armRestart ? "Restart now" : "Restart")
          enabled: !root.restartBusy
          bordered: true
          foreground: root.armRestart ? Color.urgent : Color.popups.text
          onClicked: root.onRestartClicked()
        }

        Button {
          visible: root.armRestart && !root.restartBusy
          text: "Cancel"
          bordered: true
          foreground: Color.popups.text
          onClicked: root.armRestart = false
        }
      }

      // Bottom pad so the last cards/actions clear the clip edge
      Item { width: 1; height: Style.space(8) }
      }
    }
  }
}
