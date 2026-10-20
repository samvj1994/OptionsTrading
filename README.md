# Option Trade Analyzer

A local dashboard for NIFTY and SENSEX. All market data shown—underlying price, expiry, option-chain OI, and the rolling 15-minute OI comparison—comes from Groww only. While the dashboard is open, its market view refreshes every five minutes. The NSE holiday calendar is shown for session planning; verify BSE notices separately for SENSEX.

## P&L and trade journal

The **P&L & Journal** tab reads Groww's documented F&O day-order list, per-order trade fills, and F&O positions endpoints. It displays Groww's reported realized P&L, completed same-session fill cycles, wins/losses, win rate, profit factor, average win/loss, expectancy, drawdown, fills, and open-position count. Only closed same-session fill cycles are used for win/loss statistics; this cycle estimate can be incomplete for contracts carried into the session. Future sessions are listed for planning, but future trades and P&L are not fabricated.

Groww's order, trade, and positions APIs do not return transaction-charge totals or unrealized mark-to-market P&L. Enter the actual total transaction charges from the next-day contract note in the **P&L & Journal** tab; net P&L is calculated from Groww-reported realized P&L less the entered charges. Charges and trade review notes are saved in a local SQLite file under `.dashboard_data/` and are not uploaded. Orders, trade fills, positions, realized P&L, cycle statistics, and open-position count continue to come from Groww. Unrealized MTM and contract-note charges are not available through the documented Groww Trading API.

Expand **Review trade** on a closed cycle to record setup type, entry trigger, entry/exit emotions, exit reason, execution/mistake tag, written-plan adherence, planned stop/target/max loss, and a lesson or next-session action. The summary shows review completion and plan adherence. Notes and charge entries stay on this computer in `.dashboard_data/journal.sqlite3`. Delete that local data folder to remove them. Closed cycles are same-session estimates; carried positions may not be represented accurately, and the review summary is only as complete as the trades you record.

## Holiday calendar

The dashboard loads NSE India's official live cash-market holiday calendar from `https://www.nseindia.com/api/holiday-master?type=trading`. It lists upcoming sessions and holidays for planning, with the source and update status visible in the P&L tab. The calendar is NSE's; BSE SENSEX closure dates can differ, so confirm BSE notices separately before trading SENSEX. If the official feed is unavailable, the dashboard warns rather than pretending the holiday list is current.

The Market & OI view uses one combined card per index so the expiry/spot, option positioning, and CE/PE strike setups are visible together instead of repeating the same index in separate cards. Each side shows the full-chain highest-OI strike and OI, the largest strike-level 15-minute OI build, and net chain OI change alongside its candidate. Highest OI and 15-minute OI build are context only; they are not the candidate recommendation.

The card's expiry selector is populated from Groww's available upcoming expiries; the nearest expiry is selected by default. Changing an expiry fetches that index's chain for the selected date. Strike candidates are strictly limited to an inclusive ±500 index points from spot for NIFTY and ±1,000 points for SENSEX. The top candidate and up to two alternatives are ranked only from contracts within that index's selected-expiry range; the card displays the configured range. OI changes use the closest in-memory Groww snapshot to 15 minutes earlier. The bounded snapshot window is never written to disk and is cleared when the server restarts. A full comparison appears after enough snapshots have been collected, and net change compares strikes present in both snapshots.

Each side shows up to three read-only strike rankings within the range. For fast scanning, each side puts the top strike and its research score first, shows LTP/premium change/OI change/volume/delta/spread as compact metrics, and uses labeled bars for the seven score factors. Hover a factor bar for its detail; expand **Why WAIT** to see mandatory rejection gates and **Other ranked strikes** to compare the next two. The score is an uncalibrated 0–100 research score, not a probability of profit or a trade instruction.

The score combines option-premium momentum, underlying trend, volume/liquidity, OI positioning, volatility, Greeks suitability, and risk/reward. Missing inputs are shown as unavailable and do not increase the score. Candidate checks include completed 5- and 15-minute index candles, VWAP/EMA/RSI alignment, Supertrend, opening-range or recent swing breakout, 15-minute option premium/OI changes, and a configurable absolute-delta range (`OI_MIN_ABSOLUTE_DELTA` / `OI_MAX_ABSOLUTE_DELTA`). The default absolute-delta range is 0.45–0.70; the bid/ask spread rejection limit is configurable as `OI_MAX_BID_ASK_SPREAD_PERCENT` (default 2%). Score weights are individually configurable through the `OI_SCORE_WEIGHT_*` variables and must total 100. RSI and candidate score thresholds are configurable in `.env.example`. Each candidate includes its score breakdown and rejection gates.

The app fails closed to **WAIT / NO TRADE** because Groww option-premium historical candles, verified bid/ask quotes, verified contract lot sizes, and transaction-cost-aware stop/target calculations are not currently available in the implemented data flow. These are required before a candidate can be treated as eligible; no score overrides those gates. The score is not a probability of profit or a validated strategy, and the dashboard never places orders. OI is shared by buyers and sellers, so OI changes alone cannot identify buyer/seller intent. A **Find contract on Groww** link searches for the candidate; verify the contract and quote in Groww before taking any action.

## Run

### Before you start

- Install Git if you plan to clone the repository; downloading the ZIP works too.
- Install Python 3.11 or newer. Check with `python3 --version` (Windows: `py --version`). On first start, the Python launcher creates a private `.venv` environment and installs Streamlit, the Python interface framework. You do not need to install it by hand.
- Have an internet connection on first start to install Streamlit, and for live market data from Groww and the NSE holiday calendar. Synthetic preview mode works without API credentials after setup.
- Use a modern web browser. The dashboard is served only on your computer at `http://127.0.0.1:8000`; choose another free port with `PORT` if 8000 is already in use.
- Groww API access is optional for opening the dashboard, but required for live market and account data. Set up an eligible Groww Trading API subscription and credentials first; the [Connect Groww](#connect-groww) section explains the local `.env` setup. Without credentials, run the synthetic preview to explore the interface.

### Quick start

After the prerequisites are ready, clone the repository and start it directly with Python.

```console
git clone https://github.com/samvj1994/OptionsTrading.git
cd OptionsTrading
python3 run_dashboard.py
```

On Windows, run `py -3 run_dashboard.py`.

Open <http://127.0.0.1:8000>. To stop it manually, run `python3 run_dashboard.py --stop` (Windows: `py -3 run_dashboard.py --stop`). If port 8000 is already in use, set `PORT` to another port before starting (for example, `PORT=8001 python3 run_dashboard.py` on macOS/Linux).

For your 9 AM to 4 PM schedule, set the scheduled start action to `python3 /path/to/OptionsTrading/run_dashboard.py` and the scheduled stop action to `python3 /path/to/OptionsTrading/run_dashboard.py --stop`. Replace the path with the folder where you cloned the repo. On Windows, use `py -3 C:\\path\\to\\OptionsTrading\\run_dashboard.py` and append `--stop` to the 4 PM action.

The local dashboard starts without Groww credentials, but live market and account data require Groww API credentials. Follow [Connect Groww](#connect-groww) to configure them. The dashboard stays available outside market hours and refreshes its market view every five minutes while open.

To see the interface without credentials or outside market hours, start the clearly labeled synthetic preview (not market data or trading signals):

```sh
python3 run_dashboard.py --preview
```

On Windows, run `py -3 run_dashboard.py --preview`. Preview mode affects only `/api/oi`; it does not contact Groww for option data. The banner labels all example values as synthetic and disables Groww contract links. Stop the preview server and start normally to return to the real Groww feed.

The dashboard interface, market-data processing, and local journal are written in Python. Streamlit is the only application dependency; its renderer displays the Python interface in your browser.

## Connect Groww

Groww requires an active Trading API subscription for API access. Confirm eligibility and any subscription charges in the [Groww API portal](https://groww.in/trade-api/docs/python-sdk) before creating API credentials.

1. In the dashboard folder, copy `.env.example` to a new file named `.env`.
2. In `.env`, fill in `GROWW_API_KEY` and **one** of the following:
   - `GROWW_API_SECRET` for the API key/secret approval flow. Groww requires daily approval for this method.
   - `GROWW_TOTP_SECRET` for the TOTP flow. Use the TOTP token as `GROWW_API_KEY`.
3. Save `.env`, stop the server with `python3 run_dashboard.py --stop` (or `py -3 run_dashboard.py --stop` on Windows), then start it again with `python3 run_dashboard.py` (or `py -3 run_dashboard.py` on Windows).

The server obtains and keeps the access token locally, then reads Groww's expiry list and option chain for each index. The dashboard reports the highest-OI strike separately from the multi-factor strike rankings. If Groww credentials are absent or Groww rejects a request, the dashboard reports an error instead of using another provider. The dashboard also reads account trade data for the P&L tab; it never places, modifies, or cancels orders.

`.env` is ignored by Git. Keep API keys, secrets, TOTP codes, and QR codes private; never put them in browser code or send them in chat.

See Groww's [official API guide](https://groww.in/trade-api/docs/python-sdk), [orders and trade-fill documentation](https://groww.in/trade-api/docs/curl/orders), [positions documentation](https://groww.in/trade-api/docs/curl/portfolio), [live-data and option-chain documentation](https://groww.in/trade-api/docs/python-sdk/live-data), and [feed documentation](https://groww.in/trade-api/docs/python-sdk/feed) for current eligibility and API terms.
