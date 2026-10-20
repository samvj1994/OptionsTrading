"""Local Python server for the Option Trade Analyzer dashboard.

The browser still uses HTML, CSS, and JavaScript for its display. All server,
Groww API, preview, and data-processing code lives here in Python's standard
library so there are no Python packages to install.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import math
import os
import secrets
import threading
import time
from datetime import date, datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qs, quote, urlencode, urlparse
from urllib.request import Request, urlopen


def load_dotenv() -> None:
    """Load simple KEY=value settings from .env without overriding the shell."""
    env_file = Path(__file__).resolve().parent / ".env"
    if not env_file.is_file():
        return
    for line in env_file.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key, value = key.strip(), value.strip()
        if key and key.replace("_", "").isalnum():
            if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
                value = value[1:-1]
            os.environ.setdefault(key, value)


load_dotenv()
ROOT = Path(__file__).resolve().parent
IST = timezone(timedelta(hours=5, minutes=30))
SYMBOLS = ("NIFTY", "SENSEX")
EXCHANGES = {"NIFTY": "NSE", "SENSEX": "BSE"}
STRIKE_RANGES = {"NIFTY": 500.0, "SENSEX": 1000.0}
GROWW_URL = "https://api.groww.in/v1"
HOLIDAY_URL = "https://www.nseindia.com/api/holiday-master?type=trading"
HOLIDAY_SOURCE = "https://www.nseindia.com/resources/exchange-communication-holidays"
WEIGHTS = {
    "premiumMomentum": float(os.getenv("OI_SCORE_WEIGHT_PREMIUM", "20")),
    "underlyingTrend": float(os.getenv("OI_SCORE_WEIGHT_TREND", "20")),
    "volumeLiquidity": float(os.getenv("OI_SCORE_WEIGHT_LIQUIDITY", "15")),
    "oiPositioning": float(os.getenv("OI_SCORE_WEIGHT_OI", "15")),
    "volatility": float(os.getenv("OI_SCORE_WEIGHT_VOLATILITY", "15")),
    "greeksSuitability": float(os.getenv("OI_SCORE_WEIGHT_GREEKS", "10")),
    "riskReward": float(os.getenv("OI_SCORE_WEIGHT_RISK_REWARD", "5")),
}
MIN_DELTA = float(os.getenv("OI_MIN_ABSOLUTE_DELTA", "0.45"))
MAX_DELTA = float(os.getenv("OI_MAX_ABSOLUTE_DELTA", "0.70"))
MAX_SPREAD = float(os.getenv("OI_MAX_BID_ASK_SPREAD_PERCENT", "2"))
MIN_SCORE = float(os.getenv("OI_MIN_CANDIDATE_SCORE", "65"))
STRONG_SCORE = float(os.getenv("OI_STRONG_CANDIDATE_SCORE", "80"))
RSI_BULLISH = float(os.getenv("OI_RSI_BULLISH_THRESHOLD", "55"))
RSI_BEARISH = float(os.getenv("OI_RSI_BEARISH_THRESHOLD", "45"))
PREVIEW = os.getenv("DASHBOARD_TEST_PREVIEW") == "1"
GROWW_API_KEY = os.getenv("GROWW_API_KEY", "").strip()
GROWW_API_SECRET = os.getenv("GROWW_API_SECRET", "").strip()
GROWW_TOTP_SECRET = os.getenv("GROWW_TOTP_SECRET", "").strip()

_access_token = None
_access_token_date = None
_oi_history: list[dict] = []
_holiday_cache: tuple[float, dict] | None = None
_trading_cache: tuple[float, dict] | None = None
_cache_lock = threading.RLock()

if abs(sum(WEIGHTS.values()) - 100) > 0.001:
    raise ValueError("OI score weight settings must total 100.")
if not (0 <= MIN_DELTA <= MAX_DELTA <= 1 and MAX_SPREAD >= 0
        and RSI_BEARISH < RSI_BULLISH and 0 <= MIN_SCORE <= STRONG_SCORE <= 100):
    raise ValueError("Invalid OI score threshold settings.")


class FeedError(Exception):
    """An expected API/configuration error safe to show in the dashboard."""


def number(value, signed=False):
    try:
        result = float(value)
        return result if math.isfinite(result) and (signed or result >= 0) else None
    except (TypeError, ValueError):
        return None


def totp(secret: str, at: int | None = None) -> str:
    """Create the six-digit, 30-second TOTP code Groww accepts."""
    try:
        encoded = secret.upper().replace(" ", "").rstrip("=")
        encoded += "=" * ((-len(encoded)) % 8)
        key = base64.b32decode(encoded, casefold=True)
    except Exception as exc:
        raise FeedError("The TOTP secret is not valid Base32.") from exc
    counter = int((time.time() if at is None else at) // 30)
    digest = hmac.new(key, counter.to_bytes(8, "big"), hashlib.sha1).digest()
    offset = digest[-1] & 0x0F
    code = (int.from_bytes(digest[offset:offset + 4], "big") & 0x7FFFFFFF) % 1_000_000
    return f"{code:06d}"


def groww_headers(token: str) -> dict:
    return {
        "Accept": "application/json",
        "Content-Type": "application/json",
        "Authorization": f"Bearer {token}",
        "X-Request-Id": secrets.token_hex(16),
        "X-Client-Id": "growwapi",
        "X-Client-Platform": "growwapi-python-client",
        "X-Client-Platform-Version": "1.5.0",
        "X-Api-Version": "1.0",
    }


def request_json(url: str, *, headers=None, body=None, timeout=25):
    request = Request(url, data=body, headers=headers or {}, method="POST" if body else "GET")
    try:
        with urlopen(request, timeout=timeout) as response:
            raw = response.read().decode("utf-8")
            status = response.status
    except HTTPError as exc:
        raw, status = exc.read().decode("utf-8", "replace"), exc.code
    except (URLError, TimeoutError, OSError) as exc:
        raise FeedError("Could not connect to the requested market-data service.") from exc
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise FeedError(f"The service returned an unreadable response (HTTP {status}).") from exc
    if not 200 <= status < 300:
        detail = payload.get("error", {}).get("message") if isinstance(payload, dict) else None
        raise FeedError(detail or f"The service returned HTTP {status}.")
    return payload


def parse_groww_response(payload):
    if not isinstance(payload, dict):
        raise FeedError("Groww returned an unexpected response format.")
    if payload.get("status") == "FAILURE":
        detail = payload.get("error", {}).get("message") or payload.get("message")
        raise FeedError(f"Groww API request failed: {detail or 'unknown error'}.")
    return payload.get("payload", payload)


def groww_token() -> str:
    global _access_token, _access_token_date
    today = datetime.now(IST).date()
    if _access_token and _access_token_date == today:
        return _access_token
    if not GROWW_API_KEY:
        raise FeedError("Add GROWW_API_KEY and either GROWW_API_SECRET or GROWW_TOTP_SECRET to .env.")
    if GROWW_API_SECRET and GROWW_TOTP_SECRET:
        raise FeedError("Set only one of GROWW_API_SECRET or GROWW_TOTP_SECRET in .env.")
    timestamp = int(time.time())
    if GROWW_TOTP_SECRET:
        auth = {"key_type": "totp", "totp": totp(GROWW_TOTP_SECRET)}
    elif GROWW_API_SECRET:
        checksum = hashlib.sha256(f"{GROWW_API_SECRET}{timestamp}".encode()).hexdigest()
        auth = {"key_type": "approval", "checksum": checksum, "timestamp": timestamp}
    else:
        raise FeedError("Add either GROWW_API_SECRET or GROWW_TOTP_SECRET to .env.")
    payload = parse_groww_response(request_json(
        f"{GROWW_URL}/token/api/access", headers=groww_headers(GROWW_API_KEY),
        body=json.dumps(auth).encode(), timeout=20,
    ))
    token = payload.get("token") if isinstance(payload, dict) else None
    if not token:
        raise FeedError("Groww authentication did not return an access token.")
    _access_token, _access_token_date = token, today
    return token


def groww_get(path: str, params: dict, token: str):
    url = f"{GROWW_URL}{path}?{urlencode(params)}"
    return parse_groww_response(request_json(url, headers=groww_headers(token)))


def holidays():
    global _holiday_cache
    now = time.monotonic()
    with _cache_lock:
        if _holiday_cache and now - _holiday_cache[0] < 6 * 60 * 60:
            return _holiday_cache[1]
    try:
        payload = request_json(HOLIDAY_URL, headers={"Accept": "application/json", "User-Agent": "Mozilla/5.0"})
        rows = payload.get("CM", []) if isinstance(payload, dict) else []
        entries = []
        for row in rows:
            try:
                day = datetime.strptime(row.get("tradingDate", ""), "%d-%b-%Y").date()
                entries.append({"date": day.isoformat(), "day": row.get("weekDay"), "description": row.get("description")})
            except (ValueError, AttributeError):
                continue
        if not entries:
            raise FeedError("NSE holiday calendar contained no valid dates.")
        result = {"dates": sorted({item["date"] for item in entries}), "entries": sorted(entries, key=lambda x: x["date"]),
                  "source": HOLIDAY_SOURCE, "sourceName": "NSE India official trading holiday calendar",
                  "updatedAt": datetime.now(timezone.utc).isoformat(), "status": "live",
                  "scope": "NSE cash-market calendar; used as the shared NIFTY/SENSEX closure calendar."}
        with _cache_lock:
            _holiday_cache = (now, result)
        return result
    except (FeedError, ValueError, TypeError) as exc:
        return {"dates": [], "entries": [], "source": HOLIDAY_SOURCE,
                "sourceName": "NSE India official trading holiday calendar", "updatedAt": None,
                "status": "unavailable", "warning": f"Could not load NSE's holiday calendar: {exc}"}


def available_expiries(token, symbol, exchange, today):
    dates = set()
    for year in (today.year, today.year + 1):
        payload = groww_get("/historical/expiries", {"exchange": exchange, "underlying_symbol": symbol, "year": year}, token)
        def visit(value):
            if isinstance(value, dict):
                for child in value.values(): visit(child)
            elif isinstance(value, list):
                for child in value: visit(child)
            elif isinstance(value, str):
                try:
                    parsed = date.fromisoformat(value)
                    dates.add(parsed)
                except ValueError:
                    pass
        visit(payload)
    result = sorted(item for item in dates if item >= today)
    if not result:
        raise FeedError(f"Groww returned no upcoming expiry for {symbol}.")
    return result


def candle_data(token, symbol, exchange, today):
    groww_symbol = {"NIFTY": "NSE-NIFTY", "SENSEX": "BSE-SENSEX"}[symbol]
    start = datetime.combine(today - timedelta(days=14), datetime.min.time(), IST).replace(hour=9, minute=15)
    end = datetime.now(IST)
    payload = groww_get("/historical/candle/range", {
        "exchange": exchange, "segment": "CASH", "trading_symbol": groww_symbol,
        "start_time": start.strftime("%Y-%m-%d %H:%M:%S"), "end_time": end.strftime("%Y-%m-%d %H:%M:%S"),
        "interval_in_minutes": 5,
    }, token)
    rows = payload.get("candles") if isinstance(payload, dict) else None
    if not isinstance(rows, list):
        raise FeedError(f"Groww candle response for {symbol} is missing candles.")
    candles = []
    for row in rows:
        if not isinstance(row, list) or len(row) < 5:
            continue
        try:
            raw_time = row[0]
            if isinstance(raw_time, (int, float)) or str(raw_time).replace(".", "", 1).isdigit():
                stamp = datetime.fromtimestamp(float(raw_time), IST)
            else:
                stamp = datetime.fromisoformat(str(raw_time).replace("Z", "+00:00"))
                stamp = stamp.replace(tzinfo=IST) if stamp.tzinfo is None else stamp.astimezone(IST)
            o, h, low, close = [number(value) for value in row[1:5]]
            if stamp + timedelta(minutes=5) > end or not all((o, h, low, close)):
                continue
            if h < max(o, close, low) or low > min(o, close):
                continue
            candles.append({"time": stamp, "open": o, "high": h, "low": low, "close": close, "volume": number(row[5]) if len(row) > 5 else None})
        except (TypeError, ValueError):
            continue
    return sorted({item["time"]: item for item in candles}.values(), key=lambda item: item["time"])


def fetch_index(token, symbol, requested):
    today = datetime.now(IST).date()
    exchange = EXCHANGES[symbol]
    expiries = available_expiries(token, symbol, exchange, today)
    selected = requested.get(symbol)
    if selected:
        try:
            expiry = date.fromisoformat(selected)
        except ValueError as exc:
            raise FeedError(f"Invalid expiry selection for {symbol}.") from exc
        if expiry not in expiries:
            raise FeedError(f"Selected expiry {selected} is not available for {symbol}.")
    else:
        expiry = expiries[0]
    chain = groww_get(f"/option-chain/exchange/{exchange}/underlying/{quote(symbol)}", {"expiry_date": expiry.isoformat()}, token)
    strikes = chain.get("strikes") if isinstance(chain, dict) else None
    if not isinstance(strikes, dict):
        raise FeedError(f"Groww option chain for {symbol} is missing strike data.")
    contracts, best, total_oi = {}, {"call": None, "put": None}, {"call": 0, "put": 0}
    for strike_text, sides in strikes.items():
        strike = number(strike_text)
        if not strike or not isinstance(sides, dict):
            continue
        for side_key, side_name in (("CE", "call"), ("PE", "put")):
            contract = sides.get(side_key)
            if not isinstance(contract, dict):
                continue
            oi = number(contract.get("open_interest"))
            if oi is None:
                continue
            greeks = contract.get("greeks") if isinstance(contract.get("greeks"), dict) else contract
            record = {"oi": int(oi), "ltp": number(contract.get("ltp")), "volume": number(contract.get("volume")),
                      "tradingSymbol": contract.get("trading_symbol"), "delta": number(greeks.get("delta"), signed=True),
                      "gamma": number(greeks.get("gamma"), signed=True), "theta": number(greeks.get("theta"), signed=True),
                      "vega": number(greeks.get("vega"), signed=True), "iv": number(greeks.get("iv") or contract.get("implied_volatility")),
                      "oiDayChange": number(contract.get("oi_day_change"), signed=True),
                      "previousOi": number(contract.get("previous_open_interest")),
                      "lotSize": number(contract.get("lot_size") or contract.get("lot_size_quantity"))}
            contracts[f"{expiry.isoformat()}|{strike}|{side_key}"] = record
            total_oi[side_name] += oi
            if best[side_name] is None or oi > best[side_name]["oi"]:
                best[side_name] = {"strike": strike, "oi": int(oi)}
    if not best["call"] or not best["put"]:
        raise FeedError(f"Groww returned no call or put OI for {symbol} at expiry {expiry}.")
    candles = candle_data(token, symbol, exchange, today)
    return {"symbol": symbol, "expiry": expiry.strftime("%d %b %Y"), "expiryDate": expiry.isoformat(),
            "availableExpiries": [item.isoformat() for item in expiries], "spotPrice": number(chain.get("underlying_ltp")),
            "pcr": total_oi["put"] / total_oi["call"] if total_oi["call"] else None,
            "call": best["call"], "put": best["put"], "contracts": contracts, "candles": candles}


def preview_candidate(strike, rank, score, side, premium, oi_change, volume):
    component_values = {"premiumMomentum": 14, "underlyingTrend": 15, "volumeLiquidity": 11,
                        "oiPositioning": 9, "volatility": 9, "greeksSuitability": 6, "riskReward": 0}
    components = {key: {"score": value, "weight": WEIGHTS[key], "available": key != "riskReward",
                        "detail": "Illustrative display value only" if key != "riskReward" else "No real stop, target, costs, or risk sizing in this fixture"}
                  for key, value in component_values.items()}
    return {"strike": strike, "moneyness": "PREVIEW", "ltp": premium, "volume": volume,
            "oi": 12345 + volume, "oiChange": oi_change, "oiChangePercent": 2.4,
            "premiumChangePercent": 1.8, "premiumOiPattern": "SYNTHETIC UI PREVIEW ONLY",
            "delta": 0.56 if side == "call" else -0.54, "iv": 18.2, "bidAskSpreadPercent": 0.7,
            "score": score, "scoreOutOf": 100, "availableWeight": 95, "rank": rank,
            "status": "PREVIEW ONLY", "reason": "Synthetic UI fixture. This is not a market signal or trade recommendation.",
            "rejections": ["Preview-only fixture; no live market data or actual contract quote is used."],
            "scoreComponents": components}


def synthetic_preview_feed(requested=None):
    requested = requested or {}
    expiries = ["PREVIEW-A", "PREVIEW-B", "PREVIEW-C"]
    spots = {"NIFTY": 25100.0, "SENSEX": 82100.0}
    symbols, comparisons = [], []
    for symbol, spot in spots.items():
        expiry = requested.get(symbol, expiries[0])
        if expiry not in expiries:
            raise FeedError(f"Selected preview expiry {expiry} is not available for {symbol}.")
        symbols.append({"symbol": symbol, "spotPrice": spot, "expiry": expiry, "expiryDate": expiry,
                        "availableExpiries": expiries, "strikeRangePoints": STRIKE_RANGES[symbol],
                        "candidateCountWithinRange": 3,
                        "call": {"strike": spot + 100, "oi": 150000 if symbol == "NIFTY" else 89000},
                        "put": {"strike": spot - 100, "oi": 142000 if symbol == "NIFTY" else 84000}})
        calls = [preview_candidate(spot + d, i, score, "call", premium, oi, vol)
                 for i, (d, score, premium, oi, vol) in enumerate(((100,72.4,125.5,2100,18500),(0,68.1,148,1700,16200),(-100,61.6,182.5,800,12300)), 1)]
        puts = [preview_candidate(spot + d, i, score, "put", premium, oi, vol)
                for i, (d, score, premium, oi, vol) in enumerate(((-100,70.2,119,1900,17800),(0,66.8,146.5,1400,15500),(100,60.9,179,700,11900)), 1)]
        indicator = lambda close, vwap, ema20, ema50, rsi: {"close": close, "vwap": vwap, "ema20": ema20, "ema50": ema50, "rsi14": rsi, "rsi14Previous": rsi-1}
        comparisons.append({"symbol": symbol, "expiry": expiry, "strikeRangePoints": STRIKE_RANGES[symbol],
            "call": {"change": 3200, "largestIncrease": {"strike": spot+100, "change": 2100}},
            "put": {"change": 2800, "largestIncrease": {"strike": spot-100, "change": 1900}},
            "tradeAnalysis": {"regime": "PREVIEW ONLY", "supertrend": {"direction": "PREVIEW ONLY", "level": spot},
                "spotChange": 24.5, "pcr": 0.94, "pcrChange": 0.03, "support": spot-150, "resistance": spot+150,
                "indicators": {"fiveMinute": indicator(spot+25,spot,spot+10,spot-5,58),
                               "fifteenMinute": indicator(spot+15,spot-3,spot+7,spot-8,56)},
                "call": {**calls[0], "rankings": calls}, "put": {**puts[0], "rankings": puts}}})
    return {"source": "test-preview", "testPreview": True, "lastUpdated": None, "symbols": symbols,
            "selectedExpiries": {item["symbol"]: item["expiryDate"] for item in symbols},
            "oiChange": {"windowMinutes": 15, "referenceTime": None, "availableAt": None, "symbols": comparisons}}


def trade_cycles(fills):
    """Match same-session buy/sell fills into completed long/short cycles."""
    cycles = []
    positions = {}
    ordered = []
    for fill in fills:
        try:
            stamp = datetime.fromisoformat(str(fill.get("time", "")).replace("Z", "+00:00"))
        except ValueError:
            continue
        ordered.append((stamp, fill))
    for stamp, fill in sorted(ordered, key=lambda pair: pair[0]):
        symbol = str(fill.get("symbol") or "")
        side = str(fill.get("side") or "").upper()
        quantity = int(number(fill.get("quantity")) or 0)
        price = number(fill.get("price"))
        direction = 1 if side == "BUY" else -1 if side == "SELL" else 0
        if not symbol or not direction or quantity <= 0 or not price or price <= 0:
            continue
        position = positions.setdefault(symbol, {"quantity": 0, "cycle": None})
        remaining = quantity
        if position["quantity"] == 0 or position["quantity"] * direction > 0:
            if position["cycle"] is None:
                position["cycle"] = {"side": "LONG" if direction > 0 else "SHORT", "entryValue": 0.0,
                                     "entryQuantity": 0, "exitValue": 0.0, "quantity": 0,
                                     "realizedPnl": 0.0, "entryTime": stamp, "fillIds": []}
            cycle = position["cycle"]
            cycle["entryValue"] += price * remaining
            cycle["entryQuantity"] += remaining
            if fill.get("id"):
                cycle["fillIds"].append(fill["id"])
            position["quantity"] += direction * remaining
            continue
        cycle = position["cycle"]
        matched = min(abs(position["quantity"]), remaining)
        cycle["exitValue"] += price * matched
        cycle["quantity"] += matched
        average_entry = cycle["entryValue"] / cycle["entryQuantity"]
        cycle["realizedPnl"] += (price - average_entry) * matched * (1 if position["quantity"] > 0 else -1)
        if fill.get("id"):
            cycle["fillIds"].append(fill["id"])
        position["quantity"] += direction * matched
        remaining -= matched
        if position["quantity"] == 0:
            cycles.append({"id": ":".join(map(str, cycle["fillIds"])), "symbol": symbol,
                "side": cycle["side"], "quantity": cycle["quantity"],
                "entryPrice": cycle["entryValue"] / cycle["entryQuantity"],
                "exitPrice": cycle["exitValue"] / cycle["quantity"],
                "realizedPnl": round(cycle["realizedPnl"], 2),
                "entryTime": cycle["entryTime"].astimezone(timezone.utc).isoformat(),
                "exitTime": stamp.astimezone(timezone.utc).isoformat()})
            position["cycle"] = None
        if remaining:
            position["cycle"] = {"side": "LONG" if direction > 0 else "SHORT", "entryValue": price * remaining,
                "entryQuantity": remaining, "exitValue": 0.0, "quantity": 0, "realizedPnl": 0.0,
                "entryTime": stamp, "fillIds": [fill["id"]] if fill.get("id") else []}
            position["quantity"] = direction * remaining
    return cycles


def ema(values, period):
    """Return an exponential moving average aligned to the input list."""
    if len(values) < period:
        return []
    average = sum(values[:period]) / period
    result = [None] * (period - 1) + [average]
    smoothing = 2 / (period + 1)
    for value in values[period:]:
        average += (value - average) * smoothing
        result.append(average)
    return result


def rsi(values, period=14):
    if len(values) <= period:
        return None
    changes = [right - left for left, right in zip(values, values[1:])]
    gains = [max(change, 0) for change in changes[:period]]
    losses = [max(-change, 0) for change in changes[:period]]
    average_gain, average_loss = sum(gains) / period, sum(losses) / period
    for change in changes[period:]:
        average_gain = (average_gain * (period - 1) + max(change, 0)) / period
        average_loss = (average_loss * (period - 1) + max(-change, 0)) / period
    if average_loss == 0:
        return 100.0 if average_gain > 0 else 50.0
    return 100 - 100 / (1 + average_gain / average_loss)


def aggregate_candles(candles, minutes):
    """Combine complete consecutive five-minute candles into larger bars."""
    seconds = minutes * 60
    buckets = {}
    for candle in candles:
        buckets.setdefault(int(candle["time"].timestamp()) // seconds, []).append(candle)
    result = []
    expected_count = minutes // 5
    for bucket, rows in sorted(buckets.items()):
        rows.sort(key=lambda row: row["time"])
        if len(rows) != expected_count or any(
            (right["time"] - left["time"]).total_seconds() != 300
            for left, right in zip(rows, rows[1:])
        ):
            continue
        volumes = [row["volume"] for row in rows]
        result.append({
            "time": datetime.fromtimestamp(bucket * seconds, IST),
            "open": rows[0]["open"],
            "high": max(row["high"] for row in rows),
            "low": min(row["low"] for row in rows),
            "close": rows[-1]["close"],
            "volume": sum(volumes) if all(value is not None for value in volumes) else None,
        })
    return result


def candle_indicators(candles, vwap_candles=None):
    if not candles:
        return {}
    vwap_candles = candles if vwap_candles is None else vwap_candles
    closes = [row["close"] for row in candles]
    ema9, ema20, ema50 = ema(closes, 9), ema(closes, 20), ema(closes, 50)
    rsi_now = rsi(closes)
    rsi_before = rsi(closes[:-1]) if len(closes) > 1 else None
    total_volume = sum(row["volume"] or 0 for row in vwap_candles)
    vwap = None
    if vwap_candles and all(row["volume"] is not None for row in vwap_candles) and total_volume > 0:
        vwap = sum(((row["high"] + row["low"] + row["close"]) / 3) * row["volume"] for row in vwap_candles) / total_volume
    true_ranges = []
    for index, row in enumerate(candles):
        previous_close = candles[index - 1]["close"] if index else row["close"]
        true_ranges.append(max(row["high"] - row["low"], abs(row["high"] - previous_close), abs(row["low"] - previous_close)))
    adx = None
    if len(candles) > 28:
        plus_moves, minus_moves, ranges = [], [], []
        for prior, current in zip(candles, candles[1:]):
            up, down = current["high"] - prior["high"], prior["low"] - current["low"]
            plus_moves.append(up if up > down and up > 0 else 0.0)
            minus_moves.append(down if down > up and down > 0 else 0.0)
            ranges.append(max(current["high"] - current["low"], abs(current["high"] - prior["close"]), abs(current["low"] - prior["close"])))
        plus_sum, minus_sum, range_sum = sum(plus_moves[:14]), sum(minus_moves[:14]), sum(ranges[:14])
        dx_values = []
        for index in range(13, len(plus_moves)):
            if index >= 14:
                plus_sum += plus_moves[index] - plus_sum / 14
                minus_sum += minus_moves[index] - minus_sum / 14
                range_sum += ranges[index] - range_sum / 14
            if range_sum <= 0:
                continue
            plus_di, minus_di = 100 * plus_sum / range_sum, 100 * minus_sum / range_sum
            denominator = plus_di + minus_di
            dx_values.append(100 * abs(plus_di-minus_di) / denominator if denominator else 0.0)
        if len(dx_values) >= 14:
            adx_value = sum(dx_values[:14]) / 14
            for value in dx_values[14:]:
                adx_value = (adx_value * 13 + value) / 14
            adx = {"adx": adx_value, "plusDi": 100 * plus_sum / range_sum, "minusDi": 100 * minus_sum / range_sum}
    bands = None
    if len(closes) >= 20:
        window = closes[-20:]
        mean = sum(window) / 20
        deviation = math.sqrt(sum((value - mean) ** 2 for value in window) / 20)
        bands = {"upper": mean + 2 * deviation, "middle": mean, "lower": mean - 2 * deviation,
                 "widthPercent": 400 * deviation / mean if mean > 0 else None}
    result = {"close": closes[-1], "ema9": ema9[-1] if ema9 else None,
              "ema20": ema20[-1] if ema20 else None, "ema50": ema50[-1] if ema50 else None,
              "sma20": sum(closes[-20:]) / 20 if len(closes) >= 20 else None,
              "sma50": sum(closes[-50:]) / 50 if len(closes) >= 50 else None,
              "vwap": vwap, "rsi14": rsi_now, "rsi14Previous": rsi_before,
              "atr14": sum(true_ranges[-14:]) / 14 if len(true_ranges) >= 14 else None,
              "adx14": adx, "bollinger20": bands}
    return result


def market_indicators(candles, now):
    today = now.astimezone(IST).date()
    todays_candles = [row for row in candles if row["time"].astimezone(IST).date() == today]
    bars_15m = aggregate_candles(candles, 15)
    bars_15m_today = [row for row in bars_15m if row["time"].astimezone(IST).date() == today]
    opening = [row for row in todays_candles if row["time"].astimezone(IST).hour == 9 and 15 <= row["time"].astimezone(IST).minute < 30]
    prior_days = sorted({row["time"].astimezone(IST).date() for row in candles if row["time"].astimezone(IST).date() < today})
    prior_rows = [row for row in candles if prior_days and row["time"].astimezone(IST).date() == prior_days[-1]]
    recent = todays_candles[:-1][-3:]
    return {
        "fiveMinute": candle_indicators(candles, todays_candles),
        "fifteenMinute": candle_indicators(bars_15m, bars_15m_today),
        "openingRange": {"high": max(row["high"] for row in opening), "low": min(row["low"] for row in opening)} if len(opening) == 3 else None,
        "previousDay": {"high": max(row["high"] for row in prior_rows), "low": min(row["low"] for row in prior_rows), "close": prior_rows[-1]["close"]} if prior_rows else None,
        "recentSupport": min(row["low"] for row in recent) if recent else None,
        "recentResistance": max(row["high"] for row in recent) if recent else None,
        "completedCandles": len(candles),
        "latestCandleTime": candles[-1]["time"].astimezone(timezone.utc).isoformat() if candles else None,
    }


def supertrend(candles, period=10, multiplier=3):
    if len(candles) < period:
        return None
    ranges = []
    for index, row in enumerate(candles):
        previous = candles[index - 1]["close"] if index else row["close"]
        ranges.append(max(row["high"] - row["low"], abs(row["high"] - previous), abs(row["low"] - previous)))
    index = period - 1
    atr = sum(ranges[:period]) / period
    middle = (candles[index]["high"] + candles[index]["low"]) / 2
    upper, lower = middle + multiplier * atr, middle - multiplier * atr
    direction = "bullish" if candles[index]["close"] >= middle else "bearish"
    for index in range(period, len(candles)):
        atr = sum(ranges[index - period + 1:index + 1]) / period
        row, previous_close = candles[index], candles[index - 1]["close"]
        middle = (row["high"] + row["low"]) / 2
        basic_upper, basic_lower = middle + multiplier * atr, middle - multiplier * atr
        upper = basic_upper if basic_upper < upper or previous_close > upper else upper
        lower = basic_lower if basic_lower > lower or previous_close < lower else lower
        if direction == "bearish" and row["close"] > upper:
            direction = "bullish"
        elif direction == "bullish" and row["close"] < lower:
            direction = "bearish"
    return {"direction": direction, "level": lower if direction == "bullish" else upper}


def compare_values(left, right, positive):
    if left is None or right is None:
        return None
    return left > right if positive else left < right


def trend_checks(context, side):
    positive = side == "call"
    five, fifteen = context["indicators"].get("fiveMinute", {}), context["indicators"].get("fifteenMinute", {})
    opening = context["indicators"].get("openingRange") or {}
    close = five.get("close")
    levels = [opening.get("high" if positive else "low"),
              context["indicators"].get("recentResistance" if positive else "recentSupport")]
    breakout = None if close is None else any((close > level if positive else close < level) for level in levels if level is not None)
    checks = [
        ("15-min EMA20/50 alignment", compare_values(fifteen.get("ema20"), fifteen.get("ema50"), positive)),
        ("15-min close vs VWAP", compare_values(fifteen.get("close"), fifteen.get("vwap"), positive)),
        ("15-min RSI direction", None if fifteen.get("rsi14") is None or fifteen.get("rsi14Previous") is None else (fifteen["rsi14"] > RSI_BULLISH and fifteen["rsi14"] > fifteen["rsi14Previous"] if positive else fifteen["rsi14"] < RSI_BEARISH and fifteen["rsi14"] < fifteen["rsi14Previous"])),
        ("5-min close vs VWAP", compare_values(five.get("close"), five.get("vwap"), positive)),
        ("5-min EMA20/50 alignment", compare_values(five.get("ema20"), five.get("ema50"), positive)),
        ("5-min RSI direction", None if five.get("rsi14") is None or five.get("rsi14Previous") is None else (five["rsi14"] > RSI_BULLISH and five["rsi14"] > five["rsi14Previous"] if positive else five["rsi14"] < RSI_BEARISH and five["rsi14"] < five["rsi14Previous"])),
        ("5-min Supertrend", context.get("supertrend", {}).get("direction") == ("bullish" if positive else "bearish") if context.get("supertrend") else None),
        ("15-min index price change", None if not context.get("spotChange") else (context["spotChange"] > 0 if positive else context["spotChange"] < 0)),
        ("Opening-range or recent swing break", breakout),
    ]
    return checks


def percentile_rank(value, peer_values):
    values = sorted(item for item in peer_values if item is not None)
    if value is None or not values:
        return None
    if len(values) == 1:
        return 0.5
    lower = sum(item < value for item in values)
    equal = sum(item == value for item in values)
    return (lower + (equal - 1) / 2) / (len(values) - 1)


def score_candidate(candidate, peers, side, context):
    components = {}
    score, available_weight = 0.0, 0.0
    def add(name, points, detail, available=True, used_weight=None):
        nonlocal score, available_weight
        weight = WEIGHTS[name]
        components[name] = {"score": round(points, 2), "weight": weight, "available": available,
                            "availableWeight": used_weight if used_weight is not None else (weight if available else 0), "detail": detail}
        if available: score += points
        available_weight += components[name]["availableWeight"]

    premium, oi_change = candidate.get("premiumChangePercent"), candidate.get("oiChange")
    premium_rank = percentile_rank(premium, [peer.get("premiumChangePercent") for peer in peers])
    add("premiumMomentum", WEIGHTS["premiumMomentum"] * premium_rank if premium and premium > 0 and premium_rank is not None else 0,
        "15-minute premium history unavailable" if premium is None else f"{premium:.2f}% over 15 minutes", premium is not None)
    checks = trend_checks(context, side)
    known = [passed for _label, passed in checks if passed is not None]
    trend_points = WEIGHTS["underlyingTrend"] * sum(known) / len(checks) if known else 0
    add("underlyingTrend", trend_points, f"{sum(known)}/{len(checks)} checks aligned; {len(checks)-len(known)} unavailable",
        bool(known), WEIGHTS["underlyingTrend"] * len(known) / len(checks))
    volume_rank = percentile_rank(candidate.get("volume"), [peer.get("volume") for peer in peers])
    spread_rank = percentile_rank(-candidate["bidAskSpreadPercent"] if candidate.get("bidAskSpreadPercent") is not None else None,
                                 [-peer["bidAskSpreadPercent"] if peer.get("bidAskSpreadPercent") is not None else None for peer in peers])
    liquidity = (7.5 * (volume_rank or 0)) + (7.5 * (spread_rank or 0))
    add("volumeLiquidity", liquidity, f"volume rank {volume_rank if volume_rank is not None else 'n/a'}; spread unavailable",
        volume_rank is not None or spread_rank is not None, (7.5 if volume_rank is not None else 0) + (7.5 if spread_rank is not None else 0))
    oi_rank = percentile_rank(candidate.get("oiChangePercent"), [peer.get("oiChangePercent") for peer in peers])
    aligned = bool(oi_change and premium and oi_change > 0 and premium > 0 and context.get("spotChange") and ((context["spotChange"] > 0) == (side == "call")))
    oi_points = WEIGHTS["oiPositioning"] * (oi_rank or 0) if aligned else WEIGHTS["oiPositioning"] * 0.5 if oi_change is not None and oi_change < 0 and premium and premium > 0 else 0
    add("oiPositioning", oi_points, candidate.get("oiHypothesis", "15-minute OI snapshot unavailable; neutral"), oi_change is not None)
    iv_rank = percentile_rank(candidate.get("ivChange"), [peer.get("ivChange") for peer in peers])
    iv_points = WEIGHTS["volatility"] * (iv_rank or 0) if candidate.get("ivChange") and candidate["ivChange"] > 0 and premium and premium > 0 else 0
    add("volatility", iv_points, "Groww IV change unavailable" if candidate.get("ivChange") is None else f"IV change {candidate['ivChange']:.2f}", candidate.get("ivChange") is not None)
    absolute_delta = abs(candidate["delta"]) if candidate.get("delta") is not None else None
    delta_valid = absolute_delta is not None and MIN_DELTA <= absolute_delta <= MAX_DELTA
    delta_points = 6 * max(0, 1 - abs(absolute_delta - 0.575) / 0.125) if delta_valid else 0
    theta_ratio = abs(candidate["theta"]) / candidate["ltp"] if candidate.get("theta") is not None and candidate.get("ltp") else None
    theta_rank = percentile_rank(-theta_ratio if theta_ratio is not None else None,
        [-abs(peer["theta"]) / peer["ltp"] if peer.get("theta") is not None and peer.get("ltp") else None for peer in peers])
    delta_points += 4 * theta_rank if theta_rank is not None else 0
    greek_weight = (6 if absolute_delta is not None else 0) + (4 if theta_rank is not None else 0)
    greek_detail = "Groww delta unavailable" if absolute_delta is None else f"absolute delta {absolute_delta:.3f}"
    if theta_ratio is not None: greek_detail += f"; theta/premium {theta_ratio*100:.2f}%"
    add("greeksSuitability", delta_points, greek_detail, greek_weight > 0, greek_weight)
    add("riskReward", 0, "Premium-candle stop, verified lot size, and cost-aware target unavailable", False)
    candidate.update({"score": round(score, 1), "scoreOutOf": 100, "availableWeight": available_weight,
                      "scoreComponents": components, "trendChecks": [{"check": label, "passed": passed} for label, passed in checks],
                      "directionalTrendConfirmed": len(known) == len(checks) and bool(known) and all(known),
                      "deltaValid": delta_valid})
    return candidate


def rank_candidates(current, previous, side, context):
    side_key = "CE" if side == "call" else "PE"
    spot, symbol = current.get("spotPrice"), current["symbol"]
    if not spot:
        return {"status": "WAIT / NO TRADE", "reason": "Underlying price is unavailable.", "rankings": [], "candidateCountWithinRange": 0, "strikeRangePoints": STRIKE_RANGES[symbol]}
    candidates = []
    for key, contract in current["contracts"].items():
        expiry, strike_text, kind = key.split("|")
        if kind != side_key or expiry != current["expiryDate"]:
            continue
        strike, ltp = number(strike_text), number(contract.get("ltp"))
        if strike is None or abs(strike - spot) > STRIKE_RANGES[symbol]:
            continue
        record = dict(contract)
        record.update({"strike": strike, "ltp": ltp, "distance": abs(strike - spot),
                       "moneyness": "ATM" if abs(strike-spot)/spot <= .001 else ("ITM" if ((side == "call" and strike < spot) or (side == "put" and strike > spot)) else "OTM"),
                       "volume": int(contract["volume"]) if contract.get("volume") is not None else None,
                       "bidAskSpreadPercent": None})
        old = previous.get("contracts", {}).get(key) if previous else None
        if old:
            old_oi, old_ltp = number(old.get("oi")), number(old.get("ltp"))
            record["oiChange"] = record["oi"] - old_oi if old_oi is not None else None
            record["oiChangePercent"] = record["oiChange"] / old_oi * 100 if old_oi and record["oiChange"] is not None else None
            record["premiumChangePercent"] = (ltp-old_ltp)/old_ltp*100 if ltp is not None and old_ltp else None
            record["ivChange"] = record.get("iv") - old.get("iv") if record.get("iv") is not None and old.get("iv") is not None else None
        record["oiHypothesis"] = "15-minute OI snapshot unavailable; neutral"
        change = record.get("oiChange")
        premium = record.get("premiumChangePercent")
        if change is not None and premium is not None:
            if change > 0 and premium > 0: record["premiumOiPattern"] = "Premium ↑ · OI ↑"
            elif change > 0 and premium < 0: record["premiumOiPattern"] = "Premium ↓ · OI ↑"
            elif change < 0 and premium > 0: record["premiumOiPattern"] = "Premium ↑ · OI ↓"
            elif change < 0 and premium < 0: record["premiumOiPattern"] = "Premium ↓ · OI ↓"
            else: record["premiumOiPattern"] = "Premium/OI mixed"
        else:
            record["premiumOiPattern"] = "Collecting comparable premium/OI data"
        candidates.append(record)
    if not candidates:
        return {"status": "WAIT / NO TRADE", "reason": f"No {side_key} strikes found within ±{STRIKE_RANGES[symbol]:.0f} points of spot.",
                "rankings": [], "candidateCountWithinRange": 0, "strikeRangePoints": STRIKE_RANGES[symbol]}
    for item in candidates: score_candidate(item, candidates, side, context)
    candidates.sort(key=lambda item: (-item["score"], item["distance"]))
    for rank, item in enumerate(candidates, 1): item["rank"] = rank
    for item in candidates:
        gates = []
        if not context["live"]: gates.append("Market/candles are stale or market is closed")
        if not item.get("tradingSymbol"): gates.append("Contract symbol is unavailable")
        if not item.get("ltp") or not item.get("oi") or not item.get("volume"): gates.append("Candidate has no current premium, OI, or traded volume")
        if not item["deltaValid"]: gates.append(f"Absolute delta is unavailable or outside {MIN_DELTA}-{MAX_DELTA}")
        gates.append("Bid/ask quote is unavailable")
        if not item["directionalTrendConfirmed"]: gates.append("Required directional trend checks are not all confirmed")
        if not item.get("premiumChangePercent") or item["premiumChangePercent"] <= 0: gates.append("15-minute option premium confirmation is unavailable or not positive")
        if not item.get("lotSize"): gates.append("Verified contract lot size is unavailable")
        gates.append("Premium-candle stop, cost-adjusted target, and risk/reward are unavailable")
        item["rejections"] = gates
        item["status"] = "WAIT / NO TRADE"
        item["reason"] = ". ".join(gates) + "."
        item.pop("key", None)
    top = candidates[0]
    return {**top, "candidateCountWithinRange": len(candidates), "strikeRangePoints": STRIKE_RANGES[symbol],
            "rankings": [{key:value for key,value in item.items() if key not in ("scoreComponents", "trendChecks")} for item in candidates[:3]]}


def live_feed(requested=None):
    holidays()  # Keep the browser's calendar cache warm along with the market feed.
    current = {symbol: fetch_index(groww_token(), symbol, requested or {}) for symbol in SYMBOLS}
    # The OI comparison is held in process memory only and resets when the server stops.
    now = datetime.now(timezone.utc)
    current_sample = {"timestamp": now.isoformat(), "tradingDate": now.astimezone(IST).date().isoformat(),
                      "symbols": {symbol: {key: value for key, value in item.items() if key != "candles"}
                                  for symbol, item in current.items()}}
    with _cache_lock:
        if _oi_history and (now - datetime.fromisoformat(_oi_history[-1]["timestamp"])).total_seconds() < 60:
            current_sample["timestamp"] = _oi_history[-1]["timestamp"]
            _oi_history[-1] = current_sample
        else:
            _oi_history.append(current_sample)
        _oi_history[:] = [item for item in _oi_history if (now - datetime.fromisoformat(item["timestamp"])).total_seconds() <= 25 * 60]
        candidates = [item for item in _oi_history[:-1] if item["tradingDate"] == current_sample["tradingDate"]]
        baseline = min(candidates, key=lambda item: abs((now-datetime.fromisoformat(item["timestamp"])).total_seconds()-900), default=None)
        if baseline and abs((now-datetime.fromisoformat(baseline["timestamp"])).total_seconds()-900) > 300:
            baseline = None
    summaries = []
    for symbol in SYMBOLS:
        item = current[symbol]
        previous = baseline["symbols"].get(symbol) if baseline else None
        side_changes = {}
        for side_key, side_name in (("CE", "call"), ("PE", "put")):
            common = [key for key in item["contracts"] if key.endswith("|" + side_key) and previous and key in previous["contracts"]]
            delta = sum(item["contracts"][key]["oi"]-previous["contracts"][key]["oi"] for key in common) if common else None
            increases = []
            for key in common:
                change = item["contracts"][key]["oi"] - previous["contracts"][key]["oi"]
                if change > 0:
                    increases.append({"strike": float(key.split("|")[1]), "change": change,
                                      "oi": item["contracts"][key]["oi"]})
            largest = max(increases, key=lambda row: row["change"], default=None)
            side_changes[side_name] = {"change": delta, "largestIncrease": largest}

        analysis = build_trade_analysis(item, previous)
        summaries.append({"symbol": symbol, "expiry": item["expiry"], **side_changes, "tradeAnalysis": analysis})
    first_sample = min(_oi_history, key=lambda row: row["timestamp"], default=None)
    available_at = None
    if first_sample:
        available_at = (datetime.fromisoformat(first_sample["timestamp"]) + timedelta(minutes=15)).isoformat()
    return {"lastUpdated": datetime.now(timezone.utc).isoformat(),
            "symbols": [{key: value for key, value in item.items() if key != "contracts" and key != "candles"} for item in current.values()],
            "oiChange": {"windowMinutes": 15, "referenceTime": baseline["timestamp"] if baseline else None,
                          "availableAt": available_at, "symbols": summaries},
            "selectedExpiries": {key: item["expiryDate"] for key, item in current.items()}, "source": "groww"}


def build_trade_analysis(current, previous):
    """Build indicators, time context, and fail-closed candidate rankings."""
    candles = current.get("candles", [])
    now = datetime.now(IST)
    latest = candles[-1] if candles else None
    candle_age = (now - latest["time"].astimezone(IST)).total_seconds() if latest else float("inf")
    date_info = holidays()
    today = now.date()
    is_weekday = today.weekday() < 5
    calendar_ok = date_info.get("status") in ("live", "stale")
    not_holiday = today.isoformat() not in date_info.get("dates", [])
    seconds = now.hour * 3600 + now.minute * 60 + now.second
    market_open = is_weekday and calendar_ok and not_holiday and 9 * 3600 + 15 * 60 <= seconds <= 15 * 3600 + 30 * 60
    live = market_open and 0 <= candle_age <= 600
    indicators = market_indicators(candles, now)
    direction = supertrend(candles)
    reference = latest["time"] - timedelta(minutes=15) if latest else None
    baseline_candle = None
    if reference:
        eligible = [row for row in candles if row["time"] <= reference]
        if eligible:
            nearest = min(eligible, key=lambda row: abs((row["time"] - reference).total_seconds()))
            if abs((nearest["time"] - reference).total_seconds()) <= 300:
                baseline_candle = nearest
    spot_change = latest["close"] - baseline_candle["close"] if latest and baseline_candle else None
    pcr_change = current.get("pcr") - previous.get("pcr") if previous and current.get("pcr") is not None and previous.get("pcr") is not None else None
    context = {"live": live, "spotChange": spot_change, "supertrend": direction, "indicators": indicators}
    recent_candles = [row for row in candles if latest and row["time"] >= latest["time"] - timedelta(minutes=15)]
    spot = current.get("spotPrice")
    if spot is None or spot <= 0:
        raise FeedError(f"Groww returned no underlying price for {current['symbol']}.")
    regime = classify_regime(indicators)
    return {"supertrend": direction, "spotChange": spot_change, "pcr": current.get("pcr"), "pcrChange": pcr_change,
            "regime": regime, "indicators": indicators,
            "support": min((row["low"] for row in recent_candles), default=None),
            "resistance": max((row["high"] for row in recent_candles), default=None),
            "call": rank_candidates(current, previous, "call", context),
            "put": rank_candidates(current, previous, "put", context)}


def classify_regime(indicators):
    five, fifteen = indicators.get("fiveMinute", {}), indicators.get("fifteenMinute", {})
    adx = fifteen.get("adx14", {}).get("adx") if isinstance(fifteen.get("adx14"), dict) else None
    bull = (five.get("ema20") is not None and five.get("ema50") is not None and five["ema20"] > five["ema50"]
            and fifteen.get("ema20") is not None and fifteen.get("ema50") is not None and fifteen["ema20"] > fifteen["ema50"]
            and compare_values(fifteen.get("close"), fifteen.get("vwap"), True)
            and compare_values(five.get("close"), five.get("vwap"), True))
    bear = (five.get("ema20") is not None and five.get("ema50") is not None and five["ema20"] < five["ema50"]
            and fifteen.get("ema20") is not None and fifteen.get("ema50") is not None and fifteen["ema20"] < fifteen["ema50"]
            and compare_values(fifteen.get("close"), fifteen.get("vwap"), False)
            and compare_values(five.get("close"), five.get("vwap"), False))
    if bull and adx is not None and adx >= 20: return "bullish"
    if bear and adx is not None and adx >= 20: return "bearish"
    if adx is not None and adx < 20: return "sideways"
    return "uncertain"


def trading_summary():
    """Read Groww F&O order, fills, and positions; never place an order."""
    global _trading_cache
    today = datetime.now(IST).date().isoformat()
    with _cache_lock:
        if _trading_cache and _trading_cache[1].get("date") == today and time.monotonic()-_trading_cache[0] < 60:
            return _trading_cache[1]
    token = groww_token()
    orders, fills = [], []
    for page in range(20):
        response = groww_get("/order/list", {"segment":"FNO", "page":page, "page_size":100}, token)
        batch = response.get("order_list") if isinstance(response, dict) else None
        if not isinstance(batch, list): raise FeedError("Groww order response is missing order_list.")
        orders.extend(batch)
        if len(batch) < 100: break
    for order in orders:
        order_id = str(order.get("groww_order_id", ""))
        if not order_id or not order_id.replace("_", "").replace("-", "").isalnum(): continue
        for page in range(20):
            response = groww_get(f"/order/trades/{order_id}", {"segment":"FNO", "page":page, "page_size":50}, token)
            trades = response.get("trade_list") if isinstance(response, dict) else None
            if not isinstance(trades, list): raise FeedError("Groww trade response is missing trade_list.")
            for trade in trades:
                try:
                    stamp = datetime.fromisoformat(trade["trade_date_time"].replace("Z", "+00:00"))
                    if stamp.astimezone(IST).date().isoformat() != today: continue
                except (KeyError, ValueError, AttributeError): continue
                if trade.get("trade_status", "").upper() not in ("COMPLETED", "EXECUTED") or trade.get("segment", "").upper() != "FNO": continue
                fills.append({"id":trade.get("groww_trade_id"),"orderId":trade.get("groww_order_id") or order_id,
                    "symbol":trade.get("trading_symbol") or order.get("trading_symbol"),"side":trade.get("transaction_type"),
                    "quantity":number(trade.get("quantity")),"price":number(trade.get("price")),"time":trade.get("trade_date_time"),
                    "product":trade.get("product"),"exchange":trade.get("exchange") or order.get("exchange")})
            if len(trades) < 50: break
    positions_payload = groww_get("/positions/user", {"segment":"FNO"}, token)
    positions = positions_payload.get("positions") if isinstance(positions_payload, dict) else None
    if not isinstance(positions, list): raise FeedError("Groww positions response is missing positions.")
    clean_positions = [{"symbol":p.get("trading_symbol"),"exchange":p.get("exchange"),"product":p.get("product"),
                        "quantity":number(p.get("quantity")),"realizedPnl":number(p.get("realised_pnl"),signed=True)} for p in positions if isinstance(p,dict)]
    result = {"date":today,"updatedAt":datetime.now(timezone.utc).isoformat(),"source":"groww","orders":len(orders),
              "fills":fills,"fillCount":len(fills),"closedCycles":trade_cycles(fills),
              "realizedPnl":sum(p["realizedPnl"] or 0 for p in clean_positions),"positions":clean_positions}
    with _cache_lock: _trading_cache = (time.monotonic(), result)
    return result


MIME_TYPES = {".html":"text/html; charset=utf-8", ".css":"text/css; charset=utf-8", ".js":"text/javascript; charset=utf-8"}


class DashboardHandler(BaseHTTPRequestHandler):
    """Serve the static dashboard and its three read-only API routes."""
    server_version = "OptionTradeAnalyzerPython/1.0"

    def log_message(self, fmt, *args):
        print("[%s] %s" % (self.log_date_time_string(), fmt % args))

    def send_json(self, status, payload):
        data = json.dumps(payload, ensure_ascii=False, default=lambda value: value.isoformat() if isinstance(value, datetime) else str(value)).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)
        if parsed.path == "/api/oi":
            requested = {symbol: query[f"expiry_{symbol}"][0] for symbol in SYMBOLS if query.get(f"expiry_{symbol}")}
            try:
                self.send_json(200, synthetic_preview_feed(requested) if PREVIEW else live_feed(requested))
            except FeedError as exc:
                self.send_json(503, {"error": str(exc)})
            return
        if parsed.path == "/api/trading":
            try: self.send_json(200, trading_summary())
            except FeedError as exc: self.send_json(503, {"error": str(exc)})
            return
        if parsed.path == "/api/holidays":
            self.send_json(200, holidays())
            return
        name = "index.html" if parsed.path in ("/", "/index.html") else parsed.path.lstrip("/")
        if name not in ("index.html", "style.css", "app.js"):
            self.send_error(404)
            return
        data = (ROOT / name).read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", MIME_TYPES[Path(name).suffix])
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        self.send_response(405)
        self.send_header("Allow", "GET")
        self.end_headers()


def main():
    port = int(os.getenv("PORT", "8000"))
    server = ThreadingHTTPServer(("127.0.0.1", port), DashboardHandler)
    server.daemon_threads = True
    print(f"Option Trade Analyzer Python server running at http://127.0.0.1:{port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("Stopping dashboard server...", flush=True)
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
