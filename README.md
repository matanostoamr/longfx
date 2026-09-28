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

## Locked defaults (v1.2)

- Trading hours: 24/5. The EA scans every M5 bar, Monday–Friday (server time), while the broker market is open (`InpSessionMode=SESSION_24X5`).
- Market-close protection: no new entries in the last 15 min of each daily session or the last 60 min before the weekly close; the EA's pending orders are cancelled in those windows. Set `InpNoEntryMinutesBeforeDailyClose` / `InpNoEntryMinutesBeforeWeeklyClose` to 0 to disable.
- M15 regime: EMA 50 versus EMA 200 plus two-completed-bar EMA50 slope.
- M5 Keltner Channel: EMA20 basis, ATR20, 1.2 ATR outer bands.
- Two-tier pullback (Tier 2 checked first):
  - Tier 2 (deep): exhaustion candle touches the outer band with RSI(2) ≤ 15 (≥ 85 for shorts); confirmation closes back inside the band.
  - Tier 1 (shallow): exhaustion candle touches the EMA20 basis with RSI(2) ≤ 35 (≥ 65 for shorts); confirmation closes back on the trend side of EMA20.
- Confirmation (both tiers): the next closed M5 candle is in the trend direction, closes in the favourable half of its range and beyond the exhaustion close, with true range ≤ 1.5 ATR. The exhaustion, confirmation and current bars must be consecutive (no setup across a market break).
- Entry: stop order $0.05 beyond the confirmation candle; expires after two M5 bars. The order comment records tier and UTC session, e.g. `AegisGold-v1.2-T1-ASIA`.
- Volume: fixed 0.02 lot.
- SL: beyond the recent M5 swing and both signal candles, plus a 0.15 ATR buffer; minimum $4; maximum `clamp(1.5 × M15 ATR14, $5, $7)`; setup rejected if structure needs more.
- TP: `clamp(1.4 × SL distance, $6.00, $9.80)`, i.e. 1.4R across the $4.29–$7.00 stop range.
- Daily stop: ten entries, two **consecutive** losing positions, or -£14 net strategy P/L, whichever comes first.
- Spread, news, volatility-shock, runaway-trend and margin filters are unchanged.
- One position or pending order on the symbol; no martingale, grid, averaging, trailing stop, or break-even mutation.
- Magic number 26092812 keeps v1.2 statistics separate from earlier versions.

Section 0 of the spec has the change log, the input sets that reproduce v1.1 and v1.0, and the calibration evidence behind these defaults.

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

The EA also calls `OrderCalcMargin` before every request. It rejects a setup when free margin is insufficient or projected margin level would be below 120%. Pepperstone UK advertises 1:20 retail leverage for gold, so 0.02 lot may consume a material fraction of a £400 account's available margin even though the price stop limits intended trade loss.

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
4. A deposit of £400 and the intended leverage/account type.
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
- results by tier and by session; and
- results with abnormal news days isolated.

Four to five trades per day is a target, not a guarantee. The EA accepts no more than ten fills per day, and zero trades is correct when its conditions are absent.

### End-of-run report

When a test finishes (or the EA is removed from a chart), the journal prints:

```text
AegisGold setup funnel: N qualified setups (T1 a, T2 b), orders placed c. Blocked by: daily halt ..., open position/order ..., session ..., market close ..., spread ..., shock ..., runaway ..., news ..., chase ..., no swing ..., stop too wide ..., other ...
AegisGold results this run (magic 26092812): trades, wins, net, trades/day
AegisGold   Tier 1: ... / Tier 2: ...
AegisGold   ASIA / LON / NY / LATE: ...
```

The funnel shows which rule is limiting trade frequency. Judge each tier and session separately, especially the Asian hours that are new in v1.2.

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
- A pending signal expires after two M5 bars, using broker expiration when supported and manual cleanup otherwise.
- The EA refuses to chase the trigger by more than $0.20 when satisfying broker stop-distance rules.
- Manual positions or orders on the same symbol block new EA exposure.
- A daily halt cancels the EA's pending order but does not force-close a protected open position.
- Daily statistics use the EA magic number and chart symbol, and reset at MT5 trade-server midnight.
- Pending orders are cancelled, and no new entries are placed, near the daily and weekly market close (market-close protection).
- The chart dashboard shows spread, daily entries, daily losses, net P/L, halt state, last signal tier, and the latest decision.

## Known validation boundary

This workspace does not include MetaTrader/MetaEditor or Pepperstone tick history. The source therefore requires compilation in the user's MT5 installation, and the defaults remain hypotheses until tested. In particular, do not interpret the selected EMA, Keltner, RSI, SL, or TP values as proven optimal.
