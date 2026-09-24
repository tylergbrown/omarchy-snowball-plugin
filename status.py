#!/usr/bin/env python3
"""Snowball status for the bar. Reads balances, or restarts the container. Prints no secrets."""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone
from urllib.parse import urlparse

HEALTH_TIMEOUT = 3
SNAPSHOT_TIMEOUT = 22
RESTART_TIMEOUT = 60
BOOKS = ("stocks", "futures", "crash", "fed")
LEDGER_FILES = {
    "crypto": "/app/data/snowball.db",
    "stocks": "/app/data/snowball_stocks.db",
    "futures": "/app/data/snowball_futures.db",
    "crash": "/app/data/snowball_crash.db",
    "fed": "/app/data/snowball_fed.db",
}
NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]*$")


def emit(payload: dict) -> None:
    json.dump(payload, sys.stdout)
    sys.stdout.write("\n")


def fetch(url: str, timeout: float) -> dict:
    request = urllib.request.Request(url, headers={"Accept": "application/json"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        payload = json.loads(response.read().decode())
    if not isinstance(payload, dict):
        raise ValueError("expected a JSON object")
    return payload


def age_seconds(iso: object) -> int | None:
    if not isinstance(iso, str) or not iso:
        return None
    text = iso.replace("Z", "+00:00")
    try:
        moment = datetime.fromisoformat(text)
    except ValueError:
        return None
    if moment.tzinfo is None:
        moment = moment.replace(tzinfo=timezone.utc)
    return max(0, int((datetime.now(timezone.utc) - moment).total_seconds()))


def age_label(seconds: int | None) -> str | None:
    if seconds is None:
        return None
    if seconds < 60:
        return f"{seconds}s"
    if seconds < 3600:
        return f"{seconds // 60}m"
    return f"{seconds // 3600}h {(seconds % 3600) // 60}m"


_OUT = threading.Lock()


def emit_line(payload: dict) -> None:
    line = json.dumps(payload, default=str) + "\n"
    with _OUT:
        sys.stdout.write(line)
        sys.stdout.flush()


def progress_until(stop: threading.Event, start: int, end: int, seconds: float, stage: str) -> None:
    began = time.time()
    while not stop.wait(0.4):
        frac = min(1.0, (time.time() - began) / seconds) if seconds > 0 else 1.0
        emit_line({"progress": int(start + (end - start) * frac), "stage": stage})
        if frac >= 1.0:
            return


def pnl_fraction(side: object, entry: object, mark: object) -> float | None:
    try:
        entry_price = float(entry)
        marked = float(mark)
    except (TypeError, ValueError):
        return None
    if entry_price <= 0 or marked <= 0:
        return None
    if str(side or "").lower() == "short":
        return (entry_price - marked) / entry_price
    return (marked - entry_price) / entry_price


def pnl_percent(pos: dict) -> float | None:
    given = pos.get("pnl_pct")
    if given is None:
        given = pos.get("short_pnl_pct")
    if given is not None:
        try:
            frac = float(given)
        except (TypeError, ValueError):
            frac = None
        if frac is not None:
            # Snapshot fractions are about 0.03 for 3%. A value already in
            # percent would be larger than a couple of hundred only for a blow-up.
            return round(frac * 100, 2) if abs(frac) <= 3 else round(frac, 2)
    frac = pnl_fraction(pos.get("side"), pos.get("entry_price"), pos.get("mark"))
    if frac is None and pos.get("unrealized_pnl") is not None and pos.get("notional_usd"):
        try:
            notional = float(pos["notional_usd"])
            frac = float(pos["unrealized_pnl"]) / notional if notional else None
        except (TypeError, ValueError, ZeroDivisionError):
            frac = None
    return None if frac is None else round(frac * 100, 2)


def position_value(pos: dict) -> float | None:
    """Current value is size times the latest mark. Entry cost is the fallback."""
    try:
        qty = abs(float(pos.get("qty")))
        mark = float(pos.get("mark"))
    except (TypeError, ValueError):
        qty = None
        mark = None
    if qty is not None and mark is not None and mark > 0:
        return round(qty * mark, 2)
    try:
        return round(abs(float(pos["notional_usd"])), 2)
    except (TypeError, ValueError, KeyError):
        return None


def slim_positions(raw: object) -> list[dict]:
    if not isinstance(raw, list):
        return []
    rows = []
    for pos in raw:
        if not isinstance(pos, dict):
            continue
        row = {
            "product": pos.get("product"),
            "side": pos.get("side"),
            "qty": pos.get("qty"),
            "entry_price": pos.get("entry_price"),
            "mark": pos.get("mark"),
            "unrealized_pnl": pos.get("unrealized_pnl"),
            "notional_usd": pos.get("notional_usd"),
            "strategy": pos.get("strategy"),
            "pnl_pct": pos.get("pnl_pct", pos.get("short_pnl_pct")),
        }
        row["pnl_pct"] = pnl_percent(row)
        row["value_usd"] = position_value(row)
        rows.append(row)
    return rows


def _quote_json(url: str) -> dict | None:
    request = urllib.request.Request(url, headers={"Accept": "application/json", "User-Agent": "snowball-bar"})
    try:
        with urllib.request.urlopen(request, timeout=4) as response:
            payload = json.loads(response.read().decode())
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, ValueError, OSError):
        return None
    return payload if isinstance(payload, dict) else None


def quote_price(product: str, book: str) -> float | None:
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,40}", product):
        return None
    if product.endswith("-CDE"):
        payload = _quote_json(f"https://api.coinbase.com/api/v3/brokerage/market/products/{product}")
        price = None if payload is None else payload.get("price")
    elif book == "crypto" or product.endswith("-USD"):
        payload = _quote_json(f"https://api.exchange.coinbase.com/products/{product}/ticker")
        price = None if payload is None else payload.get("price")
    else:
        payload = _quote_json(
            f"https://query1.finance.yahoo.com/v8/finance/chart/{product}?interval=1m&range=1d"
        )
        try:
            price = payload["chart"]["result"][0]["meta"]["regularMarketPrice"]
        except (TypeError, KeyError, IndexError):
            price = None
    try:
        return float(price) if price is not None else None
    except (TypeError, ValueError):
        return None


def attach_marks(books: list[dict]) -> None:
    from concurrent.futures import ThreadPoolExecutor, as_completed

    wanted: dict[str, str] = {}
    for book in books:
        for pos in book.get("positions") or []:
            if isinstance(pos, dict) and pos.get("mark") is None and pos.get("product"):
                wanted.setdefault(str(pos["product"]), str(book.get("name") or ""))
    prices: dict[str, float | None] = {}
    if wanted:
        with ThreadPoolExecutor(max_workers=8) as pool:
            futures = {pool.submit(quote_price, product, book): product for product, book in wanted.items()}
            try:
                for future in as_completed(futures, timeout=12):
                    product = futures[future]
                    try:
                        prices[product] = future.result()
                    except Exception:
                        prices[product] = None
            except TimeoutError:
                pass
    for book in books:
        for pos in book.get("positions") or []:
            if not isinstance(pos, dict):
                continue
            if pos.get("mark") is None:
                pos["mark"] = prices.get(str(pos.get("product")))
            pos["pnl_pct"] = pnl_percent(pos)
            pos["value_usd"] = position_value(pos)


def portfolio_week(books: list[dict]) -> list[dict]:
    """Sum each book's start-of-day equity into one portfolio value per day."""
    totals: dict[str, float] = {}
    for book in books:
        for point in book.get("history") or []:
            if not isinstance(point, dict) or point.get("equity") is None:
                continue
            totals[str(point["date"])] = totals.get(str(point["date"]), 0.0) + float(point["equity"])
    series = []
    for day in sorted(totals)[-7:]:
        parsed = datetime.fromisoformat(day)
        series.append(
            {
                "date": day,
                "label": f"{parsed.strftime('%b')} {parsed.day}",
                "value": round(totals[day], 2),
            }
        )
    return series


def reasons(status: dict) -> list[str]:
    raw = status.get("block_reasons")
    if not isinstance(raw, list):
        return []
    return [str(item) for item in raw if item]


def book_row(name: str, payload: dict) -> dict | None:
    if payload.get("enabled") is False:
        return None
    risk = payload.get("risk") if isinstance(payload.get("risk"), dict) else {}
    status = payload.get("status") if isinstance(payload.get("status"), dict) else {}
    if not any(key in risk for key in ("equity_usd", "cash_usd", "account_value_usd")):
        return None
    return {
        "name": name,
        "mode": payload.get("mode") or status.get("mode"),
        "trading_enabled": status.get("trading_enabled"),
        "halt_active": status.get("halt_active"),
        "equity_usd": risk.get("equity_usd"),
        "cash_usd": risk.get("cash_usd"),
        "bankroll_usd": risk.get("bankroll_usd"),
        "account_value_usd": risk.get("account_value_usd"),
        "budget_usd": risk.get("budget_usd"),
        "daily_pnl_usd": risk.get("daily_pnl_usd"),
        "daily_loss_kill_usd": risk.get("daily_loss_kill_usd"),
        "open_positions": risk.get("open_positions"),
        "max_book_positions": risk.get("max_book_positions"),
        "positions": slim_positions(payload.get("positions")),
        "block_reasons": reasons(status),
    }


def ledger_balances(base: str, user: str, container: str) -> dict:
    """Cash and open cost from the sqlite ledgers. Marked equity stays on the status feed."""
    host = urlparse(base).hostname or ""
    if not host or not NAME_RE.fullmatch(user) or not NAME_RE.fullmatch(container):
        return {"kind": "snapshot", "detail": False, "detail_error": "bad ledger target"}
    try:
        key = ssh_key()
    except FileNotFoundError:
        return {"kind": "snapshot", "detail": False, "detail_error": "ssh key missing"}
    reader = r"""
import json, sqlite3
books = [
    ("crypto", "/app/data/snowball.db"),
    ("stocks", "/app/data/snowball_stocks.db"),
    ("futures", "/app/data/snowball_futures.db"),
    ("crash", "/app/data/snowball_crash.db"),
    ("fed", "/app/data/snowball_fed.db"),
]
rows = []
for name, path in books:
    con = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    cash = con.execute("select cash_usd from account where id=1").fetchone()
    opens = con.execute(
        "select count(*), coalesce(sum(notional_usd), 0) from positions where status='open'"
    ).fetchone()
    held = []
    for row in con.execute(
        "select product, side, qty, entry_price, notional_usd, strategy "
        "from positions where status='open' order by opened_at"
    ):
        held.append({
            "product": row[0],
            "side": row[1],
            "qty": row[2],
            "entry_price": row[3],
            "notional_usd": row[4],
            "strategy": row[5],
        })
    history = []
    for utc_date, equity in con.execute(
        "select utc_date, start_equity from daily_state order by utc_date desc limit 7"
    ):
        history.append({"date": utc_date, "equity": float(equity)})
    rows.append({
        "name": name,
        "cash_usd": None if cash is None else float(cash[0]),
        "open_positions": int(opens[0]),
        "open_cost_usd": float(opens[1]),
        "positions": held,
        "history": history,
    })
print(json.dumps(rows))
"""
    remote = f"DOCKER_CONFIG=/tmp/docker-cfg-tb docker exec -i {container} python -"
    try:
        completed = subprocess.run(
            [
                "ssh",
                "-o",
                "IdentitiesOnly=yes",
                "-o",
                "BatchMode=yes",
                "-o",
                "ConnectTimeout=8",
                "-i",
                key,
                f"{user}@{host}",
                remote,
            ],
            input=reader,
            check=False,
            capture_output=True,
            text=True,
            timeout=20,
        )
    except subprocess.TimeoutExpired:
        return {"kind": "snapshot", "detail": False, "detail_error": "ledger timed out"}
    except OSError as exc:
        return {"kind": "snapshot", "detail": False, "detail_error": type(exc).__name__}
    if completed.returncode != 0:
        detail = (completed.stderr or "").strip().splitlines()
        return {
            "kind": "snapshot",
            "detail": False,
            "detail_error": detail[-1][:180] if detail else f"ledger exit {completed.returncode}",
        }
    try:
        rows = json.loads(completed.stdout.strip().splitlines()[-1])
    except (json.JSONDecodeError, IndexError):
        return {"kind": "snapshot", "detail": False, "detail_error": "bad ledger payload"}
    books = [row for row in rows if isinstance(row, dict)]
    emit_line({"progress": 88, "stage": "Marking open positions"})
    attach_marks(books)
    crypto = next((row for row in books if row.get("name") == "crypto"), {})
    return {
        "kind": "snapshot",
        "detail": True,
        "source": "ledger",
        "mode": None,
        "equity_usd": None,
        "cash_usd": crypto.get("cash_usd"),
        "daily_pnl_usd": None,
        "open_positions": crypto.get("open_positions"),
        "books": books,
        "portfolio": portfolio_week(books),
    }


def snapshot(base: str, user: str = "tylerbrown", container: str = "snowball") -> dict:
    out: dict = {"kind": "snapshot", "detail": False, "source": "snapshot"}
    emit_line({"progress": 2, "stage": "Asking the status feed"})
    stop = threading.Event()
    ticker = threading.Thread(
        target=progress_until,
        args=(stop, 2, 70, SNAPSHOT_TIMEOUT, "Asking the status feed"),
        daemon=True,
    )
    ticker.start()
    try:
        data = fetch(base + "/api/snapshot", SNAPSHOT_TIMEOUT)
    except Exception as exc:
        stop.set()
        ticker.join(timeout=1)
        emit_line({"progress": 74, "stage": "Reading open positions"})
        fallback = ledger_balances(base, user, container)
        if fallback.get("detail"):
            fallback["progress"] = 100
            return fallback
        out["detail_error"] = fallback.get("detail_error") or type(exc).__name__
        out["progress"] = 100
        return out
    else:
        stop.set()
        ticker.join(timeout=1)

    status = data.get("status") if isinstance(data.get("status"), dict) else {}
    risk = data.get("risk") if isinstance(data.get("risk"), dict) else {}
    tick_age = age_seconds(data.get("last_tick_at"))
    books = []
    crypto = book_row(
        "crypto",
        {
            "risk": risk,
            "status": status,
            "mode": status.get("mode"),
            "positions": data.get("positions"),
        },
    )
    if crypto is not None:
        books.append(crypto)
    for name in BOOKS:
        nested = data.get(name)
        if isinstance(nested, dict):
            row = book_row(name, nested)
            if row is not None:
                books.append(row)
    out.update(
        {
            "detail": True,
            "mode": status.get("mode"),
            "paper": status.get("paper"),
            "trading_enabled": status.get("trading_enabled"),
            "live_orders_permitted": status.get("live_orders_permitted"),
            "halt_active": status.get("halt_active"),
            "daily_killed": status.get("daily_killed"),
            "running": status.get("running"),
            "block_reasons": reasons(status),
            "equity_usd": risk.get("equity_usd"),
            "cash_usd": risk.get("cash_usd"),
            "daily_pnl_usd": risk.get("daily_pnl_usd"),
            "open_positions": risk.get("open_positions"),
            "unrealized_pnl_usd": risk.get("unrealized_pnl_usd"),
            "last_error": data.get("last_error"),
            "tick_age_sec": tick_age,
            "tick_age_label": age_label(tick_age),
            "books": books,
            "source": "snapshot",
            "progress": 100,
            "portfolio": portfolio_week(books) or portfolio_history(base, user, container),
        }
    )
    return out


def portfolio_history(base: str, user: str, container: str) -> list[dict]:
    host = urlparse(base).hostname or ""
    if not host or not NAME_RE.fullmatch(user) or not NAME_RE.fullmatch(container):
        return []
    try:
        key = ssh_key()
    except FileNotFoundError:
        return []
    reader = r"""
import json, sqlite3
books = [
    ("crypto", "/app/data/snowball.db"),
    ("stocks", "/app/data/snowball_stocks.db"),
    ("futures", "/app/data/snowball_futures.db"),
    ("crash", "/app/data/snowball_crash.db"),
    ("fed", "/app/data/snowball_fed.db"),
]
rows = []
for name, path in books:
    con = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    history = [
        {"date": utc_date, "equity": float(equity)}
        for utc_date, equity in con.execute(
            "select utc_date, start_equity from daily_state order by utc_date desc limit 7"
        )
    ]
    rows.append({"name": name, "history": history})
print(json.dumps(rows))
"""
    remote = f"DOCKER_CONFIG=/tmp/docker-cfg-tb docker exec -i {container} python -"
    try:
        completed = subprocess.run(
            [
                "ssh", "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=8", "-i", key, f"{user}@{host}", remote,
            ],
            input=reader,
            check=False,
            capture_output=True,
            text=True,
            timeout=20,
        )
    except (subprocess.TimeoutExpired, OSError):
        return []
    if completed.returncode != 0:
        return []
    try:
        rows = json.loads(completed.stdout.strip().splitlines()[-1])
    except (json.JSONDecodeError, IndexError):
        return []
    return portfolio_week([row for row in rows if isinstance(row, dict)])


def health(base: str) -> dict:
    out: dict = {"kind": "health", "reachable": False}
    try:
        payload = fetch(base + "/health", HEALTH_TIMEOUT)
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, ValueError, OSError) as exc:
        out["error"] = type(exc).__name__
        return out
    out.update({"reachable": True, "ok": bool(payload.get("ok")), "mode": payload.get("mode")})
    return out


def ssh_key() -> str:
    for path in ("/home/tb/.ssh/id_ed25519", "/home/tyler/.ssh/id_ed25519"):
        try:
            with open(path, "rb"):
                return path
        except OSError:
            continue
    raise FileNotFoundError("ssh key")


def restart(base: str, user: str, container: str) -> dict:
    host = urlparse(base).hostname or ""
    if not host or not NAME_RE.fullmatch(user) or not NAME_RE.fullmatch(container):
        return {"kind": "restart", "ok": False, "error": "bad restart target"}
    try:
        key = ssh_key()
    except FileNotFoundError:
        return {"kind": "restart", "ok": False, "error": "ssh key missing"}
    remote = f"DOCKER_CONFIG=/tmp/docker-cfg-tb docker restart {container}"
    try:
        completed = subprocess.run(
            [
                "ssh",
                "-o",
                "IdentitiesOnly=yes",
                "-o",
                "BatchMode=yes",
                "-o",
                "ConnectTimeout=8",
                "-i",
                key,
                f"{user}@{host}",
                remote,
            ],
            check=False,
            capture_output=True,
            text=True,
            timeout=RESTART_TIMEOUT,
        )
    except subprocess.TimeoutExpired:
        return {"kind": "restart", "ok": False, "error": "timed out"}
    except OSError as exc:
        return {"kind": "restart", "ok": False, "error": type(exc).__name__}
    if completed.returncode != 0:
        detail = (completed.stderr or completed.stdout or "").strip().splitlines()
        return {"kind": "restart", "ok": False, "error": detail[-1][:180] if detail else f"exit {completed.returncode}"}
    return {"kind": "restart", "ok": True, "container": container}


COINBASE_READER = r"""
import json, os
from snowball.futures.market import CoinbaseFuturesMarket

STABLES = {"USD", "USDC", "USDT", "DAI", "PYUSD"}
m = CoinbaseFuturesMarket(
    api_key=os.environ.get("COINBASE_API_KEY", ""),
    api_secret=os.environ.get("COINBASE_API_SECRET", ""),
    api_passphrase=os.environ.get("COINBASE_API_PASSPHRASE", ""),
    allow_orders=False,
)
bal = m.fetch_balance_raw()
totals = bal.get("total") if isinstance(bal.get("total"), dict) else {}
holdings = []
cash = 0.0
account = 0.0
for ccy, amt in totals.items():
    try:
        qty = float(amt or 0.0)
    except (TypeError, ValueError):
        continue
    if qty <= 1e-8:
        continue
    code = str(ccy).upper()
    if code in STABLES:
        value = qty
    else:
        value = None
        for pair in (f"{code}/USD", f"{code}/USDC"):
            try:
                ticker = m.exchange.fetch_ticker(pair)
                last = float(ticker.get("last") or 0)
            except Exception:
                last = 0.0
            if last > 0:
                value = qty * last
                break
        if value is None:
            continue
    if value < 1:
        continue
    if code in STABLES:
        cash += value
    account += value
    holdings.append({"currency": code, "qty": qty, "value_usd": round(value, 2)})
futures = []
futures_cash = 0.0
futures_pnl = 0.0
try:
    summary = m.exchange.v3PrivateGetBrokerageCfmBalanceSummary()
    bal_sum = summary.get("balance_summary") if isinstance(summary, dict) else {}
    if isinstance(bal_sum, dict):
        futures_cash = float((bal_sum.get("cfm_usd_balance") or {}).get("value") or 0)
        futures_pnl = float((bal_sum.get("unrealized_pnl") or {}).get("value") or 0)
    raw = m.exchange.v3PrivateGetBrokerageCfmPositions()
    for pos in (raw.get("positions") or []) if isinstance(raw, dict) else []:
        if not isinstance(pos, dict):
            continue
        contracts = float(pos.get("number_of_contracts") or 0)
        if abs(contracts) < 1e-12:
            continue
        entry = float(pos.get("avg_entry_price") or 0)
        mark = float(pos.get("current_price") or 0)
        upl = float(pos.get("unrealized_pnl") or 0)
        side = str(pos.get("side") or "").lower() or "long"
        pnl_pct = (upl / (entry * contracts) * 100) if entry and contracts else None
        futures.append({
            "product": pos.get("product_id"),
            "side": side,
            "qty": contracts,
            "entry_price": entry,
            "mark": mark,
            "unrealized_pnl": round(upl, 2),
            "value_usd": round(abs(contracts * mark), 2) if mark else None,
            "pnl_pct": None if pnl_pct is None else round(pnl_pct, 2),
        })
except Exception:
    futures = []
print(json.dumps({
    "account_value_usd": round(account, 2),
    "cash_usd": round(cash, 2),
    "futures_cash_usd": round(futures_cash, 2),
    "futures_pnl_usd": round(futures_pnl, 2),
    "holdings": holdings,
    "futures": futures,
}))
"""


def _daily_closes(product: str) -> dict[str, float]:
    """UTC date to daily close for a Coinbase spot or dated-futures product."""
    if product.endswith("-CDE"):
        url = (
            "https://api.coinbase.com/api/v3/brokerage/market/products/"
            f"{product}/candles?granularity=ONE_DAY&limit=10"
        )
    else:
        url = f"https://api.exchange.coinbase.com/products/{product}/candles?granularity=86400"
    request = urllib.request.Request(url, headers={"Accept": "application/json", "User-Agent": "snowball-bar"})
    try:
        with urllib.request.urlopen(request, timeout=8) as response:
            payload = json.loads(response.read().decode())
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, ValueError, OSError):
        payload = None
    rows = []
    if isinstance(payload, dict):
        rows = payload.get("candles") or []
    elif isinstance(payload, list):
        rows = payload
    closes: dict[str, float] = {}
    for row in rows:
        if isinstance(row, dict):
            ts = int(row.get("start") or 0)
            close = float(row.get("close") or 0)
        elif isinstance(row, list) and len(row) >= 5:
            ts = int(row[0])
            close = float(row[4])
        else:
            continue
        if ts <= 0 or close <= 0:
            continue
        day = datetime.fromtimestamp(ts, timezone.utc).date().isoformat()
        closes[day] = close
    return closes


def _price_on(closes: dict[str, float], day: str, fallback: float | None) -> float | None:
    if day in closes:
        return closes[day]
    prior = [value for key, value in sorted(closes.items()) if key <= day]
    if prior:
        return prior[-1]
    return fallback


def trailing_week(holdings: list[dict], futures: list[dict], spot_cash: float, futures_cash: float, anchor: float) -> list[dict]:
    """Mark the live Coinbase book at each of the last 7 daily closes."""
    stables = {"USD", "USDC", "USDT", "DAI", "PYUSD"}
    coins = []
    for row in holdings:
        currency = str(row.get("currency") or "")
        if currency in stables:
            continue
        try:
            qty = float(row.get("qty") or 0)
            value = float(row.get("value_usd") or 0)
        except (TypeError, ValueError):
            continue
        if qty <= 0 or value < 1:
            continue
        coins.append((f"{currency}-USD", qty, value / qty))
    contracts = []
    for row in futures:
        try:
            qty = float(row.get("qty") or 0)
            entry = float(row.get("entry_price") or 0)
            mark = float(row.get("mark") or 0)
        except (TypeError, ValueError):
            continue
        if qty <= 0 or entry <= 0:
            continue
        contracts.append((str(row.get("product")), str(row.get("side") or "long").lower(), qty, entry, mark))
    series_closes = {product: _daily_closes(product) for product, _, _ in coins}
    for product, _, _, _, _ in contracts:
        series_closes[product] = _daily_closes(product)
    today = datetime.now(timezone.utc).date()
    days = [(today - timedelta(days=offset)).isoformat() for offset in range(6, -1, -1)]
    points = []
    for day in days:
        crypto = 0.0
        for product, qty, spot in coins:
            price = _price_on(series_closes.get(product) or {}, day, spot)
            crypto += qty * float(price or spot)
        upl = 0.0
        for product, side, qty, entry, mark in contracts:
            price = _price_on(series_closes.get(product) or {}, day, mark)
            marked = float(price or mark)
            upl += (entry - marked) * qty if side == "short" else (marked - entry) * qty
        value = spot_cash + crypto + futures_cash + upl
        parsed = datetime.fromisoformat(day)
        points.append({"date": day, "label": f"{parsed.strftime('%b')} {parsed.day}", "value": round(value, 2)})
    if points:
        points[-1]["value"] = round(float(anchor), 2)
    return points


def _remember_portfolio(value: float) -> list[dict]:
    path = os.path.join(os.path.expanduser("~"), ".local", "state", "omarchy", "snowball-coinbase-portfolio.json")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    points: list[dict] = []
    try:
        loaded = json.loads(open(path).read())
        if isinstance(loaded, dict) and isinstance(loaded.get("points"), list):
            points = [row for row in loaded["points"] if isinstance(row, dict)]
    except (OSError, json.JSONDecodeError):
        points = []
    today = datetime.now(timezone.utc).date().isoformat()
    points = [row for row in points if str(row.get("date")) != today]
    points.append({"date": today, "value": round(float(value), 2)})
    points = sorted(points, key=lambda row: str(row.get("date")))[-7:]
    with open(path, "w") as handle:
        json.dump({"points": points}, handle)
    series = []
    for row in points:
        day = datetime.fromisoformat(str(row["date"]))
        series.append({"date": row["date"], "label": f"{day.strftime('%b')} {day.day}", "value": row["value"]})
    return series


def coinbase_status(base: str, user: str, container: str) -> dict:
    host = urlparse(base).hostname or ""
    out: dict = {"kind": "snapshot", "detail": False, "source": "coinbase"}
    if not host or not NAME_RE.fullmatch(user) or not NAME_RE.fullmatch(container):
        out["detail_error"] = "bad coinbase target"
        return out
    try:
        key = ssh_key()
    except FileNotFoundError:
        out["detail_error"] = "ssh key missing"
        return out
    emit_line({"progress": 8, "stage": "Reading Coinbase"})
    stop = threading.Event()
    ticker = threading.Thread(
        target=progress_until,
        args=(stop, 8, 92, 30, "Reading Coinbase"),
        daemon=True,
    )
    ticker.start()
    remote = f"DOCKER_CONFIG=/tmp/docker-cfg-tb docker exec -i {container} python -"
    try:
        completed = subprocess.run(
            [
                "ssh", "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=8", "-i", key, f"{user}@{host}", remote,
            ],
            input=COINBASE_READER,
            check=False,
            capture_output=True,
            text=True,
            timeout=60,
        )
    except subprocess.TimeoutExpired:
        out["detail_error"] = "coinbase timed out"
        return out
    except OSError as exc:
        out["detail_error"] = type(exc).__name__
        return out
    finally:
        stop.set()
        ticker.join(timeout=1)
    if completed.returncode != 0:
        out["detail_error"] = "coinbase request failed"
        return out
    try:
        payload = json.loads((completed.stdout or "").strip().splitlines()[-1])
    except (json.JSONDecodeError, IndexError):
        out["detail_error"] = "bad coinbase payload"
        return out
    holdings = payload.get("holdings") if isinstance(payload.get("holdings"), list) else []
    futures = [row for row in payload.get("futures") or [] if isinstance(row, dict)]
    cash_positions = []
    spot_positions = []
    stables = {"USD", "USDC", "USDT", "DAI", "PYUSD"}
    for row in holdings:
        if not isinstance(row, dict):
            continue
        currency = str(row.get("currency") or "")
        line = {
            "product": currency,
            "side": "cash",
            "qty": row.get("qty"),
            "value_usd": row.get("value_usd"),
            "pnl_pct": None,
        }
        if currency in stables:
            cash_positions.append(line)
        else:
            spot_positions.append({
                "product": f"{currency}-USD",
                "side": "long",
                "qty": row.get("qty"),
                "value_usd": row.get("value_usd"),
                "pnl_pct": None,
            })
    futures_cash = float(payload.get("futures_cash_usd") or 0)
    futures_pnl = float(payload.get("futures_pnl_usd") or 0)
    if futures_cash > 0:
        cash_positions.append({
            "product": "Futures USD",
            "side": "cash",
            "qty": futures_cash,
            "value_usd": round(futures_cash, 2),
            "pnl_pct": None,
        })
    spot_value = float(payload.get("account_value_usd") or 0)
    account = round(spot_value + futures_cash + futures_pnl, 2)
    books = []
    if futures:
        books.append({
            "name": "futures",
            "mode": "live",
            "equity_usd": round(futures_cash + futures_pnl, 2),
            "cash_usd": round(futures_cash, 2),
            "daily_pnl_usd": round(futures_pnl, 2),
            "open_positions": len(futures),
            "positions": futures,
        })
    if cash_positions:
        books.append({
            "name": "cash",
            "mode": "live",
            "equity_usd": round(float(payload.get("cash_usd") or 0) + futures_cash, 2),
            "cash_usd": round(float(payload.get("cash_usd") or 0) + futures_cash, 2),
            "open_positions": len(cash_positions),
            "positions": cash_positions,
        })
    if spot_positions:
        books.append({
            "name": "coinbase",
            "mode": "live",
            "equity_usd": round(spot_value - float(payload.get("cash_usd") or 0), 2),
            "cash_usd": payload.get("cash_usd"),
            "open_positions": len(spot_positions),
            "positions": spot_positions,
        })
    # Health supplies mode/ok; optional short snapshot fills status flags only.
    h = health(base)
    mode = h.get("mode") or "live"
    flags = {
        "mode": mode,
        "ok": h.get("ok") if h.get("reachable") else None,
        "paper": False,
        "trading_enabled": True,
        "running": True,
        "halt_active": False,
        "daily_killed": False,
        "block_reasons": [],
        "last_error": None,
        "tick_age_sec": None,
        "tick_age_label": None,
    }
    try:
        snap = fetch(base + "/api/snapshot", 5)
        status = snap.get("status") if isinstance(snap.get("status"), dict) else {}
        tick_age = age_seconds(snap.get("last_tick_at"))
        for key in ("halt_active", "daily_killed", "trading_enabled", "paper", "running"):
            if key in status:
                flags[key] = status[key]
        if status.get("mode"):
            flags["mode"] = status["mode"]
        flags["block_reasons"] = reasons(status)
        if "last_error" in snap:
            flags["last_error"] = snap.get("last_error")
        flags["tick_age_sec"] = tick_age
        flags["tick_age_label"] = age_label(tick_age)
    except Exception:
        pass  # keep Coinbase money; leave flags from health/defaults

    daily_pnl = round(futures_pnl, 2)
    out.update({
        "detail": True,
        "source": "coinbase",
        "mode": flags["mode"],
        "ok": flags.get("ok"),
        "paper": flags["paper"],
        "trading_enabled": flags["trading_enabled"],
        "running": flags["running"],
        "halt_active": flags["halt_active"],
        "daily_killed": flags["daily_killed"],
        "block_reasons": flags["block_reasons"],
        "last_error": flags["last_error"],
        "tick_age_sec": flags["tick_age_sec"],
        "tick_age_label": flags["tick_age_label"],
        "equity_usd": account,
        "cash_usd": round(float(payload.get("cash_usd") or 0) + futures_cash, 2),
        "daily_pnl_usd": daily_pnl,
        "unrealized_pnl_usd": daily_pnl,
        "books": books,
        "portfolio": trailing_week(
            holdings,
            futures,
            float(payload.get("cash_usd") or 0),
            futures_cash,
            account,
        ),
        "progress": 100,
    })
    return out


def main() -> int:
    action = sys.argv[1] if len(sys.argv) > 1 else "health"
    base = (sys.argv[2] if len(sys.argv) > 2 else "http://192.168.1.24:8080").rstrip("/")
    if action == "snapshot":
        user = sys.argv[3] if len(sys.argv) > 3 else "tylerbrown"
        container = sys.argv[4] if len(sys.argv) > 4 else "snowball"
        emit(coinbase_status(base, user, container))
    elif action == "restart":
        user = sys.argv[3] if len(sys.argv) > 3 else "tylerbrown"
        container = sys.argv[4] if len(sys.argv) > 4 else "snowball"
        emit(restart(base, user, container))
    else:
        emit(health(base))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
