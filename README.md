# Aegis Gold MT5 EA

A MetaTrader 5 Expert Advisor implementing a selective XAU/USD trend-pullback strategy with fixed 0.02-lot exposure, broker-side structural protection, session/news/spread/volatility filters, and daily hard risk limits.

> This is an unvalidated strategy implementation, not a profitability claim or personalized financial recommendation. Do not attach it to a live account until it has compiled cleanly and passed real-tick backtesting plus Pepperstone demo forward testing.

## Project files

```text
aegis-gold-mt5/
├── README.md
├── docs/
│   └── LOCKED_STRATEGY_SPEC.md
└── MQL5/
    └── Experts/
        └── AegisGoldTrendPullback.mq5
```

- [`docs/LOCKED_STRATEGY_SPEC.md`](docs/LOCKED_STRATEGY_SPEC.md) is the authoritative rulebook.
- [`MQL5/Experts/AegisGoldTrendPullback.mq5`](MQL5/Experts/AegisGoldTrendPullback.mq5) is the complete EA source.

## Locked defaults (v1.4)

- Trading hours: 24/5. The EA scans every M5 bar, Monday–Friday (server time), while the broker market is open (`InpSessionMode=SESSION_24X5`).
- Market-close protection: no new entries in the last 15 min of each daily session or the last 60 min before the weekly close; the EA's pending orders are cancelled in those windows. Set `InpNoEntryMinutesBeforeDailyClose` / `InpNoEntryMinutesBeforeWeeklyClose` to 0 to disable.
- Weekend close: every EA position is closed 15 min before the weekly close, because a stop loss does not protect against the weekend gap (`InpCloseMinutesBeforeWeeklyClose`, 0 = off).
- M15 regime: EMA 50 versus EMA 200 plus two-completed-bar EMA50 slope.
- M5 Keltner Channel: EMA20 basis, ATR20, 1.2 ATR outer bands.
- Two-tier pullback (Tier 2 checked first):
  - Tier 2 (deep): exhaustion candle touches the outer band with RSI(2) ≤ 15 (≥ 85 for shorts); confirmation closes back inside the band.
  - Tier 1 (shallow): exhaustion candle touches the EMA20 basis with RSI(2) ≤ 35 (≥ 65 for shorts); confirmation closes back on the trend side of EMA20.
- Range mode (flat M15): when there is no M15 trend and |EMA50 − EMA200| ≤ 1.0 × M15 ATR14, the EA fades a touch of the 1.5 ATR M5 band back toward EMA20, in either direction, with RSI(2) ≤ 10 (≥ 90 for shorts) and the same confirmation, stop, target and filters (`InpEnableRangeMode`).
- Confirmation (both tiers): the next closed M5 candle is in the trend direction, closes in the favourable half of its range and beyond the exhaustion close, with true range ≤ 1.5 ATR. The exhaustion, confirmation and current bars must be consecutive (no setup across a market break).
- Entry: stop order $0.05 beyond the confirmation candle; expires after three M5 bars. The order comment records setup type and UTC session, e.g. `AegisGold-v1.4-T1-ASIA` or `AegisGold-v1.4-R-LON`, plus `-P2` for an additional position and `-C` for an entry made after a cooldown the same day.
- Volume: fixed 0.02 lot.
- SL: beyond the recent M5 swing and both signal candles, plus a 0.15 ATR buffer; minimum $4; maximum `clamp(1.5 × M15 ATR14, $5, $7)`; setup rejected if structure needs more.
- TP: `clamp(1.4 × SL distance, $6.00, $9.80)`, i.e. 1.4R across the $4.29–$7.00 stop range.
- Daily stop: ten entries or -£14 net strategy P/L halts the EA for the rest of the day. Two **consecutive** losing positions start a 2-hour cooldown instead, after which the streak restarts (`InpCooldownHoursAfterHalt`, 0 = halt for the day).
- Up to two EA positions at once (`InpMaxConcurrentPositions`), in the same direction, on hedging accounts only. An additional position is skipped if its stop plus every open EA stop would take today's net to -£14, or if the margin gate fails. At UK retail 1:20, a £400 account cannot hold two 0.02-lot gold positions; the second slot opens up at roughly £750–£850 equity. One pending order at a time.
- Stale trades: 36 M5 bars (3 h) after the fill, the stop moves to entry + $0.10 if the price is far enough in profit, otherwise the position is closed at market (`InpStaleTradeBars`, 0 = off; `InpStaleTradeAction`).
- Spread filter: skip when the spread is above $0.60 (v1.3: $0.30). Each $0.10 of spread costs about £0.15 per 0.02-lot trade.
- News, volatility-shock, runaway-trend and margin filters are unchanged.
- No martingale, grid, averaging, recovery sizing or trailing stop.
- Magic number 26092814 keeps v1.4 statistics separate from earlier versions.

Section 0 of the spec has the change log, the input sets that reproduce earlier versions, and the replica evidence for each v1.3 change.

## Installation in MetaTrader 5

1. In MT5, choose **File → Open Data Folder**.
2. Open `MQL5/Experts`.
3. Copy `AegisGoldTrendPullback.mq5` from this project's `MQL5/Experts` directory into that MT5 directory.
4. Open MetaEditor, open the copied file, and compile it with **F7**.
5. Do not proceed until compilation reports zero errors; inspect every warning.
6. In MT5, refresh the Navigator or restart the terminal.
7. Attach the EA to Pepperstone's XAU/USD chart (the EA accepts broker suffixes as long as the symbol contains `XAU`).
8. Keep strict GBP-account validation enabled for the intended account.
9. Enable Algo Trading only on a demo account initially.

The EA can be attached to any chart timeframe, but an M5 XAU/USD chart is recommended for visibility. It explicitly reads M5 and M15 data internally.

## Critical first-run checks

Read the Experts journal immediately after initialization. The EA logs MT5's live values for:

- contract size;
- tick size and tick value;
- quote digits;
- broker minimum stop level;
- minimum volume and volume step; and
- account currency.

These values are authoritative. The code intentionally does not hard-code the common assumption that one XAU/USD lot equals 100 ounces.

The EA also calls `OrderCalcMargin` before every request. It rejects a setup when free margin is insufficient or projected margin level would be below 120%. Pepperstone UK advertises 1:20 retail leverage for gold, so one 0.02-lot position needs about £300–£350 margin at $4,000–$4,650 gold. On the first tick the journal prints a line like:

```text
AegisGold margin: 0.02 lot at 4262.00 needs 320.00 GBP. At the 120% margin-level gate, one position needs equity >= 384.00 and 2 positions need >= 768.00; equity now 400.00.
```

If the account is in netting mode, the EA also logs that it limits itself to one position.

## News-filter behavior

Live default:

```text
InpUseNewsFilter  = true
InpNewsFailClosed = true
```

The EA queries MT5's native calendar for high-impact USD events and blocks entries from 15 minutes before through 15 minutes after. Existing protected positions are not closed.

The Strategy Tester may not supply usable economic-calendar data. For a tester run, set `InpUseNewsFilter=false` if calendar calls prevent entries. Label that result **not news-filtered** and perform a separate event-aware validation before live use. Do not disable fail-closed behavior casually on a live terminal.

## Strategy Tester workflow

Use MT5 Strategy Tester with:

1. The exact Pepperstone XAU/USD symbol intended for deployment.
2. **Every tick based on real ticks**.
3. Variable spread rather than a permanently minimal spread.
4. A deposit of £400 and the live account's leverage (1:20 for UK retail gold) and hedging mode. A higher tester leverage lets second positions through the margin gate that the live account would reject.
5. Commission enabled through the broker's symbol/account history.
6. Multiple non-overlapping market regimes—not one favorable month.
7. Separate development and untouched out-of-sample periods.
8. Forward optimization or walk-forward windows if parameters are explored.

Record at minimum:

- number of filled entries and rejected setups;
- net profit after commission and spread;
- profit factor and expectancy per trade;
- win rate and average win/loss;
- maximum consecutive losses;
- maximum balance and equity drawdown;
- average and worst slippage;
- projected/live margin level;
- results by tier, session, additional position and exit type; and
- results with abnormal news days isolated.

Four to five trades per day is a target, not a guarantee. The EA accepts no more than ten fills per day, and zero trades is correct when its conditions are absent.

### End-of-run report

When a test finishes (or the EA is removed from a chart), the journal prints:

```text
AegisGold setup funnel: N qualified setups (T1 a, T2 b, range r), orders placed c (d as an additional position). Blocked by: daily halt ..., cooldown ..., open position/order ..., session ..., market close ..., spread ..., shock ..., runaway ..., news ..., chase ..., no swing ..., stop too wide ..., worst-case daily loss ..., margin ..., other ...
AegisGold position management: cooldowns, weekly-close exits, stale-trade closes, breakeven moves
AegisGold results this run (magic 26092814): trades, wins, net, trades/day
AegisGold   Tier 1: ... / Tier 2: ... / Range: ...
AegisGold   ASIA / LON / NY / LATE: ...
AegisGold   Entered after a cooldown the same day: ...
AegisGold   Additional positions: ...
AegisGold   Exits: take profit ..., stop loss incl. breakeven ..., closed by EA ..., other ...
AegisGold   Holding time: average ... min, longest ... min
```

The funnel shows which rule is limiting trade frequency. A large "margin" count means second positions are being refused for lack of equity. Judge each setup type, session, the after-cooldown entries and the additional positions separately.

## Pepperstone cost context

Pepperstone UK's published Razor pricing currently states:

- XAU/USD spread from 0.08;
- GBP commission of £4.50 per lot round-trip; and
- gold leverage of 1:20 for retail clients.

At 0.02 lot, the advertised commission scales to approximately £0.09 round-trip, before spread and slippage. Actual terminal/account conditions override website examples.

Source: [Pepperstone UK costs and fees](https://pepperstone.com/en-gb/trading/costs-and-fees). MT5 API behavior is based on the official [`SymbolInfoDouble`](https://www.mql5.com/en/docs/marketinformation/symbolinfodouble), [`CalendarValueHistory`](https://www.mql5.com/en/docs/calendar/calendarvaluehistory), and [`CTrade::BuyStop`](https://www.mql5.com/en/docs/standardlibrary/tradeclasses/ctrade/ctradebuystop) documentation.

Content sourced from external documentation has been rephrased for licensing compliance.

## Operational behavior

- SL and TP are attached to the original pending request.
- A pending signal expires after three M5 bars, using broker expiration when supported and manual cleanup otherwise.
- The EA refuses to chase the trigger by more than $0.20 when satisfying broker stop-distance rules.
- Manual positions or orders on the same symbol block new EA exposure.
- A daily halt or cooldown cancels the EA's pending order but does not force-close a protected open position.
- The EA closes positions itself only for the weekend close and the stale-trade rule.
- Daily statistics use the EA magic number and chart symbol, and reset at MT5 trade-server midnight.
- Pending orders are cancelled, and no new entries are placed, near the daily and weekly market close (market-close protection).
- The chart dashboard shows spread and its limit, open EA positions, daily entries, losses, loss streak, cooldowns, net P/L, the current M15 regime (uptrend, downtrend, flat/range mode, or mixed), halt or cooldown state, last setup type, and the latest decision.

## Known validation boundary

This workspace does not include MetaTrader/MetaEditor or Pepperstone tick history. The source therefore requires compilation in the user's MT5 installation, and the defaults remain hypotheses until tested. In particular, do not interpret the selected EMA, Keltner, RSI, SL, or TP values as proven optimal.
