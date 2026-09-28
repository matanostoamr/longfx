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

## Locked defaults (v1.1)

- M15 regime: EMA 50 versus EMA 200 plus two-completed-bar EMA50 slope.
- M5 Keltner Channel: EMA20 basis, ATR20, 1.2 ATR outer bands.
- Two-tier pullback (Tier 2 checked first):
  - Tier 2 (deep): exhaustion candle touches the outer band with RSI(2) ≤ 15 (≥ 85 for shorts); confirmation closes back inside the band.
  - Tier 1 (shallow): exhaustion candle touches the EMA20 basis with RSI(2) ≤ 30 (≥ 70 for shorts); confirmation closes back on the trend side of EMA20.
- Confirmation (both tiers): next closed M5 candle is in the trend direction, closes in the favourable half of its range, beyond the exhaustion close, with true range ≤ 1.5 ATR.
- Entry: stop order $0.05 beyond the confirmation candle; expires after two M5 bars. Order comment records the tier (`AegisGold-v1.1-T1` / `-T2`).
- Volume: fixed 0.02 lot.
- SL: recent local M5 swing plus 0.15 ATR buffer, minimum $4; maximum adapts to `clamp(1.5 × M15 ATR14, $5, $7)`; setup rejected if structure needs more.
- TP: `clamp(1.4 × SL distance, $6.00, $9.80)` — 1.4R across the $4.29–$7.00 stop range.
- Entry window: 07:00–18:00 UTC, Monday–Friday (set `InpUseUtcSessionWindow=false` for the v1.0 London/NY local windows).
- Daily stop: five entries, two **consecutive** losing positions, or -£14 net strategy P/L—whichever occurs first.
- Spread, news, volatility-shock, runaway-trend and margin filters unchanged from v1.0.
- One position or pending order on the symbol; no martingale, grid, averaging, trailing stop, or break-even mutation.
- Magic number changed to 26092811 so v1.1 statistics do not mix with v1.0.

See section 0 of the spec for the v1.0 → v1.1 change log and the input set that reproduces v1.0 exactly.

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
- results by London and New York window; and
- results with abnormal news days isolated.

Three to five trades per day is a target, not a guarantee. The EA accepts no more than five fills per day, and zero trades is correct when its conditions are absent. Report Tier 1 and Tier 2 results separately (split by order comment) so the looser Tier 1 trigger can be judged on its own.

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
- The chart dashboard shows spread, daily entries, daily losses, net P/L, halt state, and the latest decision.

## Known validation boundary

This workspace does not include MetaTrader/MetaEditor or Pepperstone tick history. The source therefore requires compilation in the user's MT5 installation, and the defaults remain hypotheses until tested. In particular, do not interpret the selected EMA, Keltner, RSI, SL, or TP values as proven optimal.
