# Option Trade Analyzer

A local dashboard for NIFTY and SENSEX. All market data shown—underlying price, expiry, option-chain OI, and the rolling 15-minute OI comparison—comes from Groww only. During weekdays the dashboard refreshes every five minutes from 09:15 through 15:30 India time, excluding dates loaded from NSE India's official holiday calendar when available.

## P&L and trade journal

The **P&L & Journal** tab reads Groww's documented F&O day-order list, per-order trade fills, and F&O positions endpoints. It displays Groww's reported realized P&L, completed same-session fill cycles, wins/losses, win rate, profit factor, average win/loss, expectancy, drawdown, fills, and open-position count. Only closed same-session fill cycles are used for win/loss statistics; this cycle estimate can be incomplete for contracts carried into the session. Future sessions are listed for planning, but future trades and P&L are not fabricated.

Groww's order, trade, and positions APIs do not return transaction-charge totals or unrealized mark-to-market P&L. Enter the actual total transaction charges from the next-day contract note in the **P&L & Journal** tab; net P&L is calculated from Groww-reported realized P&L less the entered charges. The charge total is saved in this browser's local storage for the selected session date and is not uploaded. Orders, trade fills, positions, realized P&L, cycle statistics, and open-position count continue to come from Groww. Unrealized MTM and contract-note charges are not available through the documented Groww Trading API.

Expand **Review trade** on a closed cycle to record setup type, entry trigger, entry/exit emotions, exit reason, execution/mistake tag, written-plan adherence, planned stop/target/max loss, and a lesson or next-session action. The summary tracks review completion, plan adherence, the most-tagged mistake and its associated closed-cycle P&L, and common entry emotion across journaled cycles. These notes and insights are stored only in this browser's local storage, not sent to the server. Older journal fields are retained when you add new review details. Clear the browser's site data to remove journal notes and saved charge entries. Closed cycles are same-session estimates; carried positions may not be represented accurately, and the review summary is only as complete as the trades you record.

## Holiday calendar

The dashboard loads NSE India's official live cash-market holiday calendar from `https://www.nseindia.com/api/holiday-master?type=trading`. It uses the returned NSE dates to skip holiday refreshes and lists upcoming sessions and holidays, with the source and update status visible in the P&L tab. The calendar is NSE's; BSE SENSEX closure dates can differ, so confirm BSE notices separately before trading SENSEX. If the official feed is unavailable, the dashboard warns and falls back to a weekday-only refresh schedule rather than pretending the holiday list is current.

The Market & OI view uses one combined card per index so the expiry/spot, option positioning, and CE/PE strike setups are visible together instead of repeating the same index in separate cards. Each side shows the full-chain highest-OI strike and OI, the largest strike-level 15-minute OI build, and net chain OI change alongside its candidate. Highest OI and 15-minute OI build are context only; they are not the candidate recommendation.

The card's expiry selector is populated from Groww's available upcoming expiries; the nearest expiry is selected by default. Changing an expiry fetches that index's chain for the selected date. Strike candidates are strictly limited to an inclusive ±500 index points from spot for NIFTY and ±1,000 points for SENSEX. The top candidate and up to two alternatives are ranked only from contracts within that index's selected-expiry range; the card displays the configured range. OI changes use the closest in-memory Groww snapshot to 15 minutes earlier. The bounded snapshot window is never written to disk and is cleared when the server restarts. A full comparison appears after enough snapshots have been collected, and net change compares strikes present in both snapshots.

Each side shows up to three read-only strike rankings within the range. For fast scanning, each side puts the top strike and its research score first, shows LTP/premium change/OI change/volume/delta/spread as compact metrics, and uses labeled bars for the seven score factors. Hover a factor bar for its detail; expand **Why WAIT** to see mandatory rejection gates and **Other ranked strikes** to compare the next two. The score is an uncalibrated 0–100 research score, not a probability of profit or a trade instruction.

The score combines option-premium momentum, underlying trend, volume/liquidity, OI positioning, volatility, Greeks suitability, and risk/reward. Missing inputs are shown as unavailable and do not increase the score. Candidate checks include completed 5- and 15-minute index candles, VWAP/EMA/RSI alignment, Supertrend, opening-range or recent swing breakout, 15-minute option premium/OI changes, and a configurable absolute-delta range (`OI_MIN_ABSOLUTE_DELTA` / `OI_MAX_ABSOLUTE_DELTA`). The default absolute-delta range is 0.45–0.70; the bid/ask spread rejection limit is configurable as `OI_MAX_BID_ASK_SPREAD_PERCENT` (default 2%). Score weights are individually configurable through the `OI_SCORE_WEIGHT_*` variables and must total 100. RSI and candidate score thresholds are configurable in `.env.example`. Each candidate includes its score breakdown and rejection gates.

The app fails closed to **WAIT / NO TRADE** because Groww option-premium historical candles, verified bid/ask quotes, verified contract lot sizes, and transaction-cost-aware stop/target calculations are not currently available in the implemented data flow. These are required before a candidate can be treated as eligible; no score overrides those gates. The score is not a probability of profit or a validated strategy, and the dashboard never places orders. OI is shared by buyers and sellers, so OI changes alone cannot identify buyer/seller intent. A **Find contract on Groww** link searches for the candidate; verify the contract and quote in Groww before taking any action.

## Run

The dashboard is configured to run only Monday through Friday, 09:00–16:00 India time. A macOS LaunchAgent starts it at 09:00; the server shuts itself down at 16:00, and direct starts outside that window exit immediately. If the Mac is asleep at 09:00, macOS starts the missed job when it wakes. The LaunchAgent runs only while your macOS user is logged in.

Requires the Ruby and WEBrick already included with this macOS setup. No extra tools or packages need to be installed. To start it manually during its operating window:

```sh
ruby server.rb
```

Open <http://127.0.0.1:8000>.

For a clearly labeled, synthetic UI-only preview (not market data or trading signals), run:

```sh
DASHBOARD_ALLOW_OUTSIDE_HOURS=1 DASHBOARD_TEST_PREVIEW=1 ruby server.rb
```

This mode affects only `/api/oi`; it does not contact Groww for option data. The banner labels all example values as synthetic and disables Groww contract links. Stop the preview server and start `ruby server.rb` normally to return to the real Groww feed.

Run the local strategy unit tests with:

```sh
ruby test/strategy_test.rb
```

## Connect Groww

Groww requires an active Trading API subscription for API access. Confirm eligibility and any subscription charges in the [Groww API portal](https://groww.in/trade-api/docs/python-sdk) before creating API credentials.

1. In the dashboard folder, copy `.env.example` to a new file named `.env`.
2. In `.env`, fill in `GROWW_API_KEY` and **one** of the following:
   - `GROWW_API_SECRET` for the API key/secret approval flow. Groww requires daily approval for this method.
   - `GROWW_TOTP_SECRET` for the TOTP flow. Use the TOTP token as `GROWW_API_KEY`.
3. Save `.env` and restart the server with `ruby server.rb`.

The server obtains and keeps the access token locally, then reads Groww's expiry list and option chain for each index. The dashboard reports the highest-OI strike separately from the multi-factor strike rankings. If Groww credentials are absent or Groww rejects a request, the dashboard reports an error instead of using another provider. The dashboard also reads account trade data for the P&L tab; it never places, modifies, or cancels orders.

`.env` is ignored by Git. Keep API keys, secrets, TOTP codes, and QR codes private; never put them in browser code or send them in chat.

See Groww's [official API guide](https://groww.in/trade-api/docs/python-sdk), [orders and trade-fill documentation](https://groww.in/trade-api/docs/curl/orders), [positions documentation](https://groww.in/trade-api/docs/curl/portfolio), [live-data and option-chain documentation](https://groww.in/trade-api/docs/python-sdk/live-data), and [feed documentation](https://groww.in/trade-api/docs/python-sdk/feed) for current eligibility and API terms.
