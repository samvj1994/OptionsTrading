"""Python-only Streamlit interface for the Option Trade Analyzer."""

from __future__ import annotations

import json
import os
import sqlite3
import urllib.error
import urllib.parse
import urllib.request
from datetime import date, datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

import streamlit as st


ROOT = Path(__file__).resolve().parent
API_URL = os.getenv("DASHBOARD_API_URL", "http://127.0.0.1:8765")
PREVIEW = os.getenv("DASHBOARD_TEST_PREVIEW") == "1"
DB_PATH = ROOT / ".dashboard_data" / "journal.sqlite3"
INDIA_TZ = ZoneInfo("Asia/Kolkata")
st.set_page_config(page_title="Option Trade Analyzer", page_icon="📈", layout="wide")


def api(path: str, params: dict | None = None) -> dict:
    query = urllib.parse.urlencode(params or {})
    request = urllib.request.Request(f"{API_URL}{path}?{query}", headers={"Cache-Control": "no-cache"})
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        try:
            detail = json.loads(exc.read().decode("utf-8")).get("error", str(exc))
        except (ValueError, AttributeError):
            detail = str(exc)
        raise RuntimeError(detail) from exc
    except (urllib.error.URLError, TimeoutError) as exc:
        raise RuntimeError(f"Python data service is unavailable at {API_URL}. Restart the dashboard.") from exc
    if not isinstance(payload, dict):
        raise RuntimeError("The data service returned an invalid response.")
    return payload


def fmt(value, decimals=2):
    if value is None:
        return "—"
    try:
        return f"{float(value):,.{decimals}f}"
    except (TypeError, ValueError):
        return str(value)


def journal_connection():
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    connection = sqlite3.connect(DB_PATH)
    connection.execute("""CREATE TABLE IF NOT EXISTS reviews (
        cycle_key TEXT PRIMARY KEY, setup TEXT, trigger TEXT, entry_emotion TEXT,
        exit_emotion TEXT, exit_reason TEXT, mistake TEXT, followed_plan INTEGER,
        stop REAL, target REAL, max_loss REAL, lesson TEXT, updated_at TEXT)""")
    connection.execute("CREATE TABLE IF NOT EXISTS charges (session_date TEXT PRIMARY KEY, amount REAL NOT NULL)")
    return connection


def get_review(key):
    with journal_connection() as connection:
        row = connection.execute("SELECT * FROM reviews WHERE cycle_key=?", (key,)).fetchone()
    if not row:
        return {}
    names = ["cycle_key", "setup", "trigger", "entry_emotion", "exit_emotion", "exit_reason",
             "mistake", "followed_plan", "stop", "target", "max_loss", "lesson", "updated_at"]
    return dict(zip(names, row))


def save_review(key, values):
    with journal_connection() as connection:
        connection.execute("""INSERT INTO reviews VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(cycle_key) DO UPDATE SET setup=excluded.setup, trigger=excluded.trigger,
            entry_emotion=excluded.entry_emotion, exit_emotion=excluded.exit_emotion,
            exit_reason=excluded.exit_reason, mistake=excluded.mistake,
            followed_plan=excluded.followed_plan, stop=excluded.stop, target=excluded.target,
            max_loss=excluded.max_loss, lesson=excluded.lesson, updated_at=excluded.updated_at""",
            (key, values["setup"], values["trigger"], values["entry_emotion"], values["exit_emotion"],
             values["exit_reason"], values["mistake"], values["followed_plan"], values["stop"],
             values["target"], values["max_loss"], values["lesson"], datetime.now().isoformat()))


def saved_charges(session_date):
    with journal_connection() as connection:
        row = connection.execute("SELECT amount FROM charges WHERE session_date=?", (session_date,)).fetchone()
    return float(row[0]) if row else 0.0


def store_charges(session_date, amount):
    with journal_connection() as connection:
        if amount:
            connection.execute("INSERT INTO charges VALUES (?, ?) ON CONFLICT(session_date) DO UPDATE SET amount=excluded.amount",
                               (session_date, amount))
        else:
            connection.execute("DELETE FROM charges WHERE session_date=?", (session_date,))


def market_context(analysis):
    indicators = analysis.get("indicators", {})
    def alignment(name):
        data = indicators.get(name, {})
        fast, slow = data.get("ema20"), data.get("ema50")
        if fast is None or slow is None:
            return "—"
        return "Bullish" if fast > slow else "Bearish" if fast < slow else "Flat"
    five, fifteen = indicators.get("fiveMinute", {}), indicators.get("fifteenMinute", {})
    supertrend = analysis.get("supertrend", {})
    return {
        "Regime": analysis.get("regime", "uncertain"),
        "EMA 5m / 15m": f"{alignment('fiveMinute')} / {alignment('fifteenMinute')}",
        "RSI 5m / 15m": f"{fmt(five.get('rsi14'))} / {fmt(fifteen.get('rsi14'))}",
        "Supertrend": supertrend.get("direction", "—"),
        "PCR": fmt(analysis.get("pcr")),
        "15m index change": f"{fmt(analysis.get('spotChange'))} pts",
    }


def render_candidate(candidate, option_side, preview, strike_range, symbol, expiry):
    candidate = candidate or {}
    status = candidate.get("status", "WAIT")
    strike = candidate.get("strike")
    st.markdown(f"#### {option_side} · {status}")
    if strike:
        st.write(f"**{fmt(strike, 0)} {option_side}** · {candidate.get('moneyness', '—')} · score **{fmt(candidate.get('score'))}/100**")
    else:
        st.write(candidate.get("reason", f"No {option_side} contract in ±{fmt(strike_range, 0)} points."))
    score = candidate.get("score")
    if score is not None:
        st.progress(max(0.0, min(1.0, float(score) / 100)), text="Research score · not a probability")
    metrics = st.columns(6)
    for column, (label, value) in zip(metrics, [
        ("LTP", f"₹{fmt(candidate.get('ltp'))}" if candidate.get("ltp") is not None else "—"),
        ("Premium Δ", f"{fmt(candidate.get('premiumChangePercent'))}%" if candidate.get("premiumChangePercent") is not None else "—"),
        ("OI Δ", fmt(candidate.get("oiChange"))), ("Volume", fmt(candidate.get("volume"), 0)),
        ("Delta", fmt(candidate.get("delta"))),
        ("Spread", f"{fmt(candidate.get('bidAskSpreadPercent'))}%" if candidate.get("bidAskSpreadPercent") is not None else "—"),
    ]):
        column.metric(label, value)
    components = candidate.get("scoreComponents") or {}
    if components:
        with st.expander("Score factors"):
            for key, component in components.items():
                label = key.replace("premiumMomentum", "Premium momentum").replace("underlyingTrend", "Underlying trend").replace("volumeLiquidity", "Volume / liquidity").replace("oiPositioning", "OI positioning").replace("volatility", "Volatility").replace("greeksSuitability", "Greeks suitability").replace("riskReward", "Risk / reward")
                st.write(f"**{label}** · {fmt(component.get('score'))}/{fmt(component.get('weight'))} — {component.get('detail', '')}")
    reasons = candidate.get("rejections") or []
    with st.expander(f"Why WAIT · {len(reasons)} checks" if reasons else "Eligibility checks"):
        if reasons:
            for reason in reasons:
                st.write(f"- {reason}")
        else:
            st.write("No blocking checks reported. This score alone is not a trade instruction.")
    alternatives = [item for item in candidate.get("rankings", []) if item.get("rank") != 1]
    if alternatives:
        with st.expander("Other ranked strikes"):
            for item in alternatives:
                st.write(f"#{item.get('rank')} · {fmt(item.get('strike'), 0)} {option_side} · {fmt(item.get('score'))}/100 · {item.get('status')}")
    if strike and not preview:
        query = urllib.parse.quote(f"{symbol} {expiry} {strike} {option_side}")
        st.link_button("Find contract on Groww", f"https://groww.in/search?q={query}")


@st.fragment(run_every="5m")
def market_panel():
    holidays = st.session_state.get("holidays", {})
    with st.spinner("Loading market data…"):
        try:
            payload = api("/api/oi", {f"expiry_{symbol}": st.session_state.get(f"expiry_{symbol}", "")
                                       for symbol in ("NIFTY", "SENSEX") if st.session_state.get(f"expiry_{symbol}")})
        except RuntimeError as exc:
            st.error(str(exc))
            if PREVIEW:
                st.warning("Synthetic preview mode is enabled. Restart with `--preview` to view example values.")
            return
    preview = payload.get("testPreview") is True and payload.get("source") == "test-preview"
    if payload.get("source") != "groww" and not preview:
        st.error("Unexpected feed source. Only Groww data or explicit synthetic preview is accepted.")
        return
    if preview:
        st.warning("TEST PREVIEW ONLY — all displayed values, OI changes, indicators, scores, and candidates are synthetic placeholders. They are not Groww data or trading signals.")
    else:
        st.caption(f"Groww live market data · updated {payload.get('lastUpdated', '—')} · refreshes every five minutes during market hours.")
    change_data = payload.get("oiChange") or {}
    if preview:
        st.info("Synthetic preview only · no live market data.")
    elif change_data.get("referenceTime"):
        st.info(f"OI change vs {change_data['referenceTime']} · {change_data.get('windowMinutes', 15)}-minute window. Snapshots stay in memory and clear when restarted.")
    else:
        st.info(f"Collecting in-memory OI snapshots. Comparison available after {change_data.get('availableAt') or 'more data is collected'}.")
    symbol_items = {item.get("symbol"): item for item in payload.get("symbols", [])}
    comparisons = {item.get("symbol"): item for item in change_data.get("symbols", [])}
    for symbol in ("NIFTY", "SENSEX"):
        market = symbol_items.get(symbol, {})
        comparison = comparisons.get(symbol, {})
        analysis = comparison.get("tradeAnalysis", {})
        expiry_options = market.get("availableExpiries", [])
        selected = payload.get("selectedExpiries", {}).get(symbol) or market.get("expiryDate") or market.get("expiry")
        if expiry_options:
            try:
                default_index = expiry_options.index(selected)
            except ValueError:
                default_index = 0
            new_expiry = st.selectbox(f"{symbol} expiry", expiry_options, index=default_index, key=f"expiry_{symbol}")
            selected = new_expiry
        with st.container(border=True):
            left, right = st.columns([1, 2])
            with left:
                st.subheader(symbol)
                st.metric("Spot", f"₹{fmt(market.get('spotPrice'))}")
                st.caption(f"Expiry {selected or '—'} · strike range ±{fmt(market.get('strikeRangePoints'), 0)} points")
                st.write("**Market context**")
                for label, value in market_context(analysis).items():
                    st.write(f"{label}: {value}")
                call, put = comparison.get("call", {}), comparison.get("put", {})
                st.write(f"**Highest OI** · CE {fmt((market.get('call') or {}).get('strike'), 0)} ({fmt((market.get('call') or {}).get('oi'), 0)}) · PE {fmt((market.get('put') or {}).get('strike'), 0)} ({fmt((market.get('put') or {}).get('oi'), 0)})")
                st.write(f"**15m OI** · CE largest build {fmt((call.get('largestIncrease') or {}).get('strike'), 0)} ({fmt((call.get('largestIncrease') or {}).get('change'), 0)}) · net {fmt(call.get('change'), 0)}")
                st.write(f"**15m OI** · PE largest build {fmt((put.get('largestIncrease') or {}).get('strike'), 0)} ({fmt((put.get('largestIncrease') or {}).get('change'), 0)}) · net {fmt(put.get('change'), 0)}")
            with right:
                call_col, put_col = st.columns(2)
                with call_col:
                    render_candidate(analysis.get("call"), "CE", preview, market.get("strikeRangePoints"), symbol, selected)
                with put_col:
                    render_candidate(analysis.get("put"), "PE", preview, market.get("strikeRangePoints"), symbol, selected)


def upcoming_sessions(holidays, count=5):
    excluded = set(holidays.get("dates", []))
    current = datetime.now(INDIA_TZ).date()
    result = []
    for offset in range(1, 370):
        day = current + timedelta(days=offset)
        if day.weekday() < 5 and day.isoformat() not in excluded:
            result.append(day)
        if len(result) >= count:
            break
    return result


def journal_key(cycle):
    return "|".join(str(cycle.get(name, "")) for name in ("symbol", "entryTime", "exitTime", "quantity", "realizedPnl"))


def trading_panel(holidays):
    today = datetime.now(INDIA_TZ).date()
    sessions = [today] + upcoming_sessions(holidays)
    selected = st.selectbox("Session", sessions, format_func=lambda item: f"{item.isoformat()}" + (" · Today" if item == today else " · upcoming session"))
    try:
        data = api("/api/trading")
    except RuntimeError as exc:
        st.error(str(exc))
        st.caption("Add valid Groww API credentials to the private `.env` file for account data.")
        return
    if selected != today:
        st.info("Future session selected. Trades and P&L are not fabricated; Groww returns current-session trade data only.")
        return
    if data.get("source") != "groww":
        st.error("Trading data source is not Groww.")
        return
    cycles = data.get("closedCycles", [])
    pnl = float(data.get("realizedPnl") or 0)
    charge_key = f"contract_charges_{selected.isoformat()}"
    if charge_key not in st.session_state:
        st.session_state[charge_key] = saved_charges(selected.isoformat())
    charges = st.number_input("Actual transaction charges from contract note (₹)", min_value=0.0, step=1.0, key=charge_key)
    store_charges(selected.isoformat(), charges)
    wins = [float(c.get("realizedPnl") or 0) for c in cycles if float(c.get("realizedPnl") or 0) > 0]
    losses = [float(c.get("realizedPnl") or 0) for c in cycles if float(c.get("realizedPnl") or 0) < 0]
    gross_losses = abs(sum(losses))
    reviewed = [get_review(journal_key(c)) for c in cycles]
    completed_reviews = sum(bool(item) for item in reviewed)
    review_pairs = [(review, cycle) for review, cycle in zip(reviewed, cycles) if review]
    plan_reviews = [review for review, _cycle in review_pairs]
    followed = sum(item.get("followed_plan") == 1 for item in plan_reviews)
    metrics = st.columns(6)
    for col, label, value in zip(metrics, ["Groww realized P&L", "Net after charges", "Completed cycles", "Wins / losses", "Win rate", "Profit factor"],
                                [f"₹{pnl:,.2f}", f"₹{pnl-charges:,.2f}", str(len(cycles)), f"{len(wins)} / {len(losses)}", f"{len(wins)/len(cycles)*100:.1f}%" if cycles else "—", f"{sum(wins)/gross_losses:.2f}" if gross_losses else "—"]):
        col.metric(label, value)
    cumulative = 0.0
    peak = 0.0
    drawdown = 0.0
    for cycle in cycles:
        cumulative += float(cycle.get("realizedPnl") or 0)
        peak = max(peak, cumulative)
        drawdown = max(drawdown, peak - cumulative)
    avg_win = sum(wins) / len(wins) if wins else 0
    avg_loss = sum(losses) / len(losses) if losses else 0
    insights = st.columns(6)
    for col, label, value in zip(insights, ["Average win / loss", "Expectancy", "Max drawdown", "Plan adherence", "Executed fills", "Open positions"],
                                 [f"₹{avg_win:,.2f} / ₹{avg_loss:,.2f}", f"₹{sum(float(c.get('realizedPnl') or 0) for c in cycles)/len(cycles):,.2f}" if cycles else "—", f"₹{drawdown:,.2f}", f"{followed/len(plan_reviews)*100:.0f}%" if plan_reviews else "—", str(data.get("fillCount", 0)), str(sum(bool(p.get("quantity")) for p in data.get("positions", [])))]):
        col.metric(label, value)
    st.caption("Groww realized P&L is before charges. Only completed same-session fill cycles are included in cycle metrics; estimates may omit carried contracts. Unrealized MTM is not available through this API.")
    st.caption(f"Journal reviews completed: {completed_reviews}/{len(cycles)} · notes and charges are stored only on this computer.")
    mistake_totals, emotion_totals = {}, {}
    for review, cycle in review_pairs:
        mistake = str(review.get("mistake") or "").strip()
        emotion = str(review.get("entry_emotion") or "").strip()
        if mistake:
            summary = mistake_totals.setdefault(mistake, [0, 0.0])
            summary[0] += 1
            summary[1] += float(cycle.get("realizedPnl") or 0)
        if emotion:
            emotion_totals[emotion] = emotion_totals.get(emotion, 0) + 1
    if mistake_totals or emotion_totals:
        common_mistake = max(mistake_totals.items(), key=lambda pair: pair[1][0]) if mistake_totals else None
        common_emotion = max(emotion_totals.items(), key=lambda pair: pair[1]) if emotion_totals else None
        insight_text = []
        if common_mistake:
            insight_text.append(f"Most tagged mistake: {common_mistake[0]} · {common_mistake[1][0]} trades · associated closed-cycle P&L ₹{common_mistake[1][1]:,.2f}")
        if common_emotion:
            insight_text.append(f"Most common entry emotion: {common_emotion[0]} · {common_emotion[1]} trades")
        st.info("\n\n".join(insight_text))
    if not cycles:
        st.info("No completed same-session fill cycles returned by Groww.")
    for index, cycle in enumerate(cycles, 1):
        key = journal_key(cycle)
        saved = get_review(key)
        with st.expander(f"Review trade {index} · {cycle.get('symbol', 'contract')} · P&L ₹{float(cycle.get('realizedPnl') or 0):,.2f}"):
            st.caption(f"{cycle.get('side', '—')} · {fmt(cycle.get('quantity'), 0)} quantity · Entry ₹{fmt(cycle.get('entryPrice'))} at {cycle.get('entryTime', '—')} · Exit ₹{fmt(cycle.get('exitPrice'))} at {cycle.get('exitTime', '—')}")
            with st.form(f"review_{index}"):
                cols = st.columns(3)
                setup = cols[0].text_input("Setup type", value=saved.get("setup", ""))
                trigger = cols[1].text_input("Entry trigger", value=saved.get("trigger", ""))
                exit_reason = cols[2].text_input("Exit reason", value=saved.get("exit_reason", ""))
                cols = st.columns(3)
                entry_emotion = cols[0].text_input("Entry emotion", value=saved.get("entry_emotion", ""))
                exit_emotion = cols[1].text_input("Exit emotion", value=saved.get("exit_emotion", ""))
                mistake = cols[2].text_input("Execution / mistake tag", value=saved.get("mistake", ""))
                followed_plan = st.checkbox("Followed written plan", value=saved.get("followed_plan") == 1)
                cols = st.columns(3)
                stop = cols[0].number_input("Planned stop (₹)", value=float(saved.get("stop") or 0), min_value=0.0)
                target = cols[1].number_input("Planned target (₹)", value=float(saved.get("target") or 0), min_value=0.0)
                max_loss = cols[2].number_input("Planned max loss (₹)", value=float(saved.get("max_loss") or 0), min_value=0.0)
                lesson = st.text_area("Lesson / next-session action", value=saved.get("lesson", ""))
                if st.form_submit_button("Save review"):
                    save_review(key, {"setup": setup, "trigger": trigger, "entry_emotion": entry_emotion,
                                      "exit_emotion": exit_emotion, "exit_reason": exit_reason, "mistake": mistake,
                                      "followed_plan": int(followed_plan), "stop": stop or None,
                                      "target": target or None, "max_loss": max_loss or None, "lesson": lesson})
                    st.success("Review saved locally.")


st.title("Option Trade Analyzer")
st.caption("India derivatives · NIFTY 50 · SENSEX")
try:
    holiday_data = api("/api/holidays")
except RuntimeError as exc:
    holiday_data = {"status": "unavailable", "warning": str(exc), "dates": [], "entries": []}
st.session_state["holidays"] = holiday_data
if holiday_data.get("status") == "live":
    st.caption(f"Holiday calendar: {holiday_data.get('sourceName')} · {holiday_data.get('scope', '')}")
else:
    st.warning(f"Holiday calendar unavailable: {holiday_data.get('warning', 'Weekday-only schedule will be used.')}")
if PREVIEW:
    st.warning("SYNTHETIC PREVIEW · placeholder data only, not market data or trading advice.")
market_tab, trading_tab = st.tabs(["Market & OI", "P&L & Journal"])
with market_tab:
    st.subheader("Index strike setups")
    st.caption("Candidates are limited to NIFTY ±500 and SENSEX ±1,000 points from spot. OI is shared by buyers and sellers and is not a directional signal.")
    st.button("Refresh market data", key="refresh_market")
    market_panel()
with trading_tab:
    st.subheader("Session P&L & trade journal")
    st.caption("Groww executions · review your setup, risk, execution, and lesson after closed trades.")
    st.link_button("NSE official holiday calendar", holiday_data.get("source", "https://www.nseindia.com/resources/exchange-communication-holidays"))
    sessions = upcoming_sessions(holiday_data)
    if sessions:
        st.write("Upcoming sessions: " + " · ".join(item.isoformat() for item in sessions))
    india_today = datetime.now(INDIA_TZ).date().isoformat()
    future_holidays = [item for item in holiday_data.get("entries", []) if item.get("date", "") >= india_today][:6]
    if future_holidays:
        st.write("Upcoming NSE holidays: " + " · ".join(f"{item['date']} · {item.get('description', 'Holiday')}" for item in future_holidays))
    trading_panel(holiday_data)
