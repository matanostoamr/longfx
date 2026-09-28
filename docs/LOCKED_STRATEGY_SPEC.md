# Aegis Gold Trend-Pullback EA — Locked Strategy Specification v1.2

## 0. Change log

### v1.2 (from v1.1)

| Area | v1.1 | v1.2 default |
|---|---|---|
| Entry window | 07:00–18:00 UTC | 24/5: every M5 bar Monday–Friday (server time) while the broker market is open (`InpSessionMode`) |
| Market-close protection | — | No new entries, and pending orders cancelled, in the last 15 min of each daily session and the last 60 min before the weekly close (set either to 0 to disable) |
| Tier 1 RSI(2) | ≤ 30 / ≥ 70 | ≤ 35 / ≥ 65 |
| Daily entry cap | 5 | 10 |
| Stop anchor | Most recent swing from shift 2 | Also beyond both signal candles (`InpStopBeyondSignalCandles`) |
| Signal bars | — | Exhaustion, confirmation and current bar must be consecutive M5 bars (no setup across a market break) |
| Reporting | — | End-of-run setup funnel and results by tier and UTC session in the journal; session tag in the order comment |
| Magic number | 26092811 | 26092812 |

v1.1 behaviour: `InpSessionMode=SESSION_UTC_WINDOW`, `InpTier1RsiLongThreshold=30`, `InpTier1RsiShortThreshold=70`, `InpMaximumDailyEntries=5`, `InpStopBeyondSignalCandles=false`, `InpNoEntryMinutesBeforeDailyClose=0`, `InpNoEntryMinutesBeforeWeeklyClose=0`.

v1.0 behaviour: the v1.1 set above plus `InpSessionMode=SESSION_LONDON_NY`, `InpEnableTier1=false`, `InpKeltnerAtrMultiplier=1.5`, `InpTier2RsiLongThreshold=10`, `InpTier2RsiShortThreshold=90`, `InpUseAdaptiveMaxStop=false`, `InpMaximumTargetPrice=6.5`, `InpDailyLossCountMode=LOSS_COUNT_TOTAL`.

The consecutive-bar rule has no switch; inside the v1.1/v1.0 windows it never triggers because those windows do not span the daily break.

#### v1.2 calibration evidence (approximate)

The Tier 1 threshold and entry cap were chosen with an offline Python replica of the EA, run on Binance XAUUSDT 1-minute data (offset-corrected to spot) for 28 Jun – 28 Sep 2026, with a $0.13 spread and £0.09 commission per trade. This is not Pepperstone tick data: the replica produced about twice the user-reported v1.1 trade count (100 against 45) and did not reproduce the user-reported profitability. Treat these figures as relative comparisons only.

| Replica run | Trades/day | Win rate | Net (GBP) | PF |
|---|---:|---:|---:|---:|
| v1.1 | 1.54 | 34.0% | -128 | 0.73 |
| v1.2 defaults | 2.74 | 39.9% | -77 | 0.91 |
| v1.2 with Tier 1 RSI 40/60 | 2.75 | 39.1% | -116 | 0.87 |
| v1.2 without loss breaker or cap | 3.86 | 37.8% | -201 | 0.83 |

In the v1.2 replica, the daily loss breaker blocked the most setups (151), followed by stops too wide for the adaptive maximum (84) and an already-open position or order (46). The average does not reach 4–5 trades per day while the two-consecutive-loss breaker is on; 19 of 65 weekdays had four or more trades. Raising the cap from 8 to 10 changed nothing because no day exceeded 8 trades.

## 1. Status and calibration boundary

This document locks the third implementation candidate for MT5. The values below are execution-aware defaults, not a claim of statistical optimization. No Pepperstone XAU/USD tick dataset is available in this workspace, so profitability, expected frequency, and win rate remain unverified until real-tick backtesting and demo forward testing are complete.

Pepperstone UK currently advertises Razor XAU/USD spreads from 0.08, GBP commission of £4.50 per lot round-trip, and retail gold leverage of 1:20. At 0.02 lot, the advertised commission implies £0.09 round-trip before spread and slippage. The EA reads the actual MT5 symbol properties at runtime and does not assume a particular number of digits, tick size, contract size, minimum stop level, or margin requirement.

Sources:

- [Pepperstone UK costs and fees](https://pepperstone.com/en-gb/trading/costs-and-fees)
- [MQL5 `SymbolInfoDouble`](https://www.mql5.com/en/docs/marketinformation/symbolinfodouble)
- [MQL5 `SymbolInfoInteger`](https://www.mql5.com/en/docs/marketinformation/symbolinfointeger)
- [MQL5 `CalendarValueHistory`](https://www.mql5.com/en/docs/calendar/calendarvaluehistory)
- [MQL5 `CTrade::BuyStop`](https://www.mql5.com/en/docs/standardlibrary/tradeclasses/ctrade/ctradebuystop)

Content sourced from external documentation has been rephrased for licensing compliance.

## 2. Mandate

| Setting | Locked value |
|---|---|
| Platform | MetaTrader 5 |
| Instrument | The Pepperstone chart symbol containing `XAU` (supports broker suffixes) |
| Account currency | GBP by default; initialization fails when strict GBP validation is enabled and the account differs |
| Volume | Fixed 0.02 lot |
| Concurrent exposure | One position or pending entry on the symbol |
| Entry timeframe | M5, evaluated once per newly opened M5 bar using closed candles only |
| Regime timeframe | M15, using closed candles only |
| Initial SL distance | $4.00 minimum; adaptive maximum `clamp(1.5 × M15 ATR14, $5.00, $7.00)` in XAU/USD price units |
| TP distance | `clamp(1.4 × actual SL distance, $6.00, $9.80)` |
| Daily entry cap | Ten filled entries per MT5 trade-server calendar day |
| Daily hard halt | Two consecutive losing completed positions or net strategy P/L at or below -£14 |
| Position sizing escalation | Prohibited |

A daily halt cancels the EA's unfilled pending entry and prevents new entries until the next trade-server day. It does not force-close a protected open position.

## 3. Indicator definitions

### 3.1 M15 directional regime

Indicators use closing prices:

- Fast EMA: 50
- Slow EMA: 200
- Slope lookback: two completed M15 bars

Long regime:

1. EMA 50 at M15 shift 1 is above EMA 200 at shift 1.
2. EMA 50 at shift 1 is above EMA 50 at shift 3.

Short regime is the exact inverse.

A flat or conflicting regime produces no entry.

### 3.2 M5 Keltner Channel

- Basis: EMA 20 of close
- Volatility: ATR 20
- Band multiplier: 1.2
- Upper band: `EMA20 + 1.2 × ATR20`
- Lower band: `EMA20 - 1.2 × ATR20`
- Middle line (basis): `EMA20`

The Keltner Channel is calculated inside the EA from native MT5 EMA and ATR buffers.

### 3.3 RSI exhaustion

- RSI period: 2
- Applied price: close
- Tier 2 (deep) thresholds: RSI ≤ 15 for longs, ≥ 85 for shorts
- Tier 1 (shallow) thresholds: RSI ≤ 35 for longs, ≥ 65 for shorts

RSI is a timing condition, not a standalone entry.

## 4. Closed-candle entry setup

At the first tick of a new M5 candle:

- `shift 2` is the exhaustion/pullback candle.
- `shift 1` is the confirmation candle.
- Shift 2, shift 1 and the new candle must be consecutive M5 bars; a setup that spans the daily break or weekend is ignored.

### 4.1 Long setup

Common conditions (both tiers):

1. M15 long regime is valid.
2. Confirmation candle is bullish (`close > open`).
3. Confirmation candle closes at or above the midpoint of its range.
4. Confirmation close is above the exhaustion close.
5. Confirmation true range is no greater than 1.5 × its ATR20.
6. A valid structural stop and all execution/risk filters are available.

Tier 2 (deep pullback) — evaluated first:

- Exhaustion low touches or penetrates its lower band (`EMA20 − 1.2 × ATR20`).
- Exhaustion RSI(2) ≤ 15.
- Confirmation closes back above its lower band.

Tier 1 (shallow pullback) — evaluated only when Tier 2 does not qualify:

- Exhaustion low touches or penetrates its EMA20 basis.
- Exhaustion RSI(2) ≤ 35.
- Confirmation closes back above its EMA20 basis (`InpTier1RequireBasisReclaim`).

Place a buy-stop at the confirmation high plus $0.05. Both tiers use identical sizing, SL, and TP rules; the order comment records the tier and UTC session (e.g. `AegisGold-v1.2-T1-ASIA`; sessions ASIA 21–07, LON 07–12, NY 12–17, LATE 17–21 UTC) so results can be split per tier and session.

### 4.2 Short setup

Exact mirror: M15 short regime; bearish confirmation closing at or below its midpoint and below the exhaustion close; Tier 2 needs the exhaustion high at or above `EMA20 + 1.2 × ATR20` with RSI(2) ≥ 85 and a confirmation close back below that band; Tier 1 needs the exhaustion high at or above EMA20 with RSI(2) ≥ 65 and a confirmation close back below EMA20. Place a sell-stop at the confirmation low minus $0.05.

### 4.3 Pending-order handling

- The broker-side pending order includes SL and TP from creation.
- The requested entry must be adjusted when necessary to satisfy the broker's minimum stop distance.
- Reject the setup if that adjustment would worsen entry by more than $0.20 from the strategy trigger.
- Expire an unfilled pending order after two complete M5 bars.
- Never chase an expired or missed signal.

## 5. Structural stop and target

### 5.1 Swing detection

Search the most recent 12 completed M5 bars, starting at shift 2:

- Swing low: its low is below both adjacent candle lows.
- Swing high: its high is above both adjacent candle highs.

With `InpStopBeyondSignalCandles=true` (default), the anchor is the lower of that swing low and both signal candles' lows (for shorts, the higher of the swing high and both signal candles' highs). If no swing is found, the signal candles' extreme is used. This keeps the stop outside the setup's own range. In the v1.1 search, when the confirmation candle undercut the exhaustion candle, the search moved to older bars and could place the stop inside the setup or on the wrong side of the entry.

For a long, the structural candidate is the anchor minus `0.15 × ATR20`.
For a short, it is the anchor plus `0.15 × ATR20`.

### 5.2 SL normalization

Let structural distance be the absolute entry-to-structural-candidate distance:

Maximum stop for the setup:

```text
max SL = clamp(1.5 × ATR14(M15, last completed bar), $5.00, $7.00)
```

- If structural distance exceeds max SL, reject the setup.
- If structural distance is below $4.00, extend the SL distance to $4.00.
- Otherwise, use the structural distance.

The resulting SL remains beyond the detected structure and within $4.00–$7.00. Set `InpUseAdaptiveMaxStop=false` to restore the fixed $5.00 ceiling.

### 5.3 TP normalization

Calculate:

```text
TP distance = clamp(1.4 × SL distance, $6.00, $9.80)
```

This produces:

| SL | TP | R multiple |
|---:|---:|---:|
| $4.00 | $6.00 | 1.50R |
| $4.50 | $6.30 | 1.40R |
| $5.00 | $7.00 | 1.40R |
| $6.00 | $8.40 | 1.40R |
| $7.00 | $9.80 | 1.40R |

At 0.02 lot on a 100 oz contract, a $7.00 stop is about $14 (≈ £10–£11 at current GBP/USD) before costs—above the v1.0 £7 per-trade loss range. Check the logged contract size. Because the halt is checked before each new entry, not during a trade, the worst day is roughly the -£14 threshold plus one more full loss (about -£24), not -£14.

SL and TP are broker-side price levels. GBP results vary with the XAU/USD contract specification, GBP/USD conversion, spread, commission, and fill price. The EA does not close based on an exact GBP floating-profit value.

## 6. Trading windows

Default (`InpSessionMode=SESSION_24X5`): the EA scans every new M5 bar, Monday–Friday in broker server time, whenever the broker market is open. Pepperstone lists gold at 01:01–23:59 server time Monday–Thursday and 01:01–23:55 on Friday (server GMT+3 during US DST, GMT+2 otherwise).

Market-close protection uses the symbol's MT5 trade-session table, which is logged at start-up:

- No new entry in the last 15 minutes of a daily session (`InpNoEntryMinutesBeforeDailyClose`), which covers the rollover spread spike.
- No new entry in the last 60 minutes before the weekly close (`InpNoEntryMinutesBeforeWeeklyClose`), which reduces the chance of holding a new position through the weekend gap. A stop loss does not protect against a gap; the fill happens at the reopening price.
- The EA's pending orders are cancelled inside these windows. Open positions keep their SL/TP and are not closed.
- If the session table is empty, the EA assumes the session ends at server midnight and the week ends on Friday.

Legacy options: `SESSION_UTC_WINDOW` (v1.1: 07:00–18:00 UTC) and `SESSION_LONDON_NY` (v1.0: 08:00–12:00 Europe/London and 08:00–12:00 America/New_York local time, DST-aware).

In the Strategy Tester, UTC (used for legacy windows and session tags) is derived from the Pepperstone server offset. Existing positions remain protected and active outside entry windows.

## 7. Abnormal-condition filters

### 7.1 Spread

Skip when `ask - bid > $0.30` in XAU/USD price units. Using a price-distance threshold avoids ambiguity between two-digit and three-digit broker quotes. The threshold is configurable for later tick-data calibration.

### 7.2 High-impact USD news

With the live news filter enabled, skip from 15 minutes before through 15 minutes after MT5 economic-calendar events that:

- are associated with USD; and
- have `CALENDAR_IMPORTANCE_HIGH`.

The MT5 calendar operates in trade-server time. If the calendar request fails and fail-closed mode is enabled, the EA does not open a new position. The news filter can be disabled explicitly for Strategy Tester runs where calendar data are unavailable; those test results must be labelled as not news-filtered.

### 7.3 Volatility shock

Block a setup when either is true:

- A completed M5 candle true range is at least 3.0 × its ATR20; or
- ATR20 is at least 2.0 × the median ATR20 of the previous 100 completed bars.

Three consecutive normal completed M5 bars are required before entries resume.

### 7.4 Runaway trend

Block a setup when either is true:

- The latest completed M5 close is more than 2.5 × ATR20 from EMA20; or
- The latest three completed M5 candles have the same direction and each body is at least 0.8 × its ATR20.

### 7.5 Margin and symbol checks

Before order submission:

- Volume must align with the symbol minimum, maximum, and step.
- The broker must permit trading and pending stop orders.
- Projected account margin level after the new order must be at least 120% by default.
- Entry, SL, and TP must satisfy tick-size and broker stop-level constraints.
- The EA must be attached to an XAU symbol and, in strict mode, a GBP account.

The 120% margin gate is a minimum operational guard, not a statement that this margin utilization is conservative. At UK retail leverage of 1:20, 0.02 lot can consume a material part of a £400 account's free margin; the actual MT5 margin preview is authoritative.

## 8. Daily accounting and hard halt

Daily statistics include only this EA's magic number and chart symbol.

- Entry count: filled entry deals.
- Position result: aggregate profit, commission, and swap for all deals sharing the completed position ID.
- Loss count: completed positions whose aggregate net result is negative.
- Daily net P/L: aggregate profit, commission, and swap for all strategy deals since trade-server midnight.

No new order is allowed when any condition is reached:

- ten entries;
- two consecutive losing positions (default; `InpDailyLossCountMode=LOSS_COUNT_TOTAL` restores two losses in total); or
- net daily P/L at or below -£14.

The consecutive-loss halt is sticky: once the streak is reached, the day stays halted even though no further trade can break it.

There is no daily profit target and no recovery sizing.

## 9. Position management

Version 1 uses deterministic broker-side SL/TP exits only:

- No trailing stop.
- No automatic break-even move.
- No widening or removal of SL.
- No averaging, grid, martingale, or concurrent position.
- No indicator-driven panic exit.
- Session closure, a news window, or a daily halt does not close an already protected position.

This keeps the first backtest attributable to the defined entry, SL, and TP rather than discretionary exit logic.

## 10. Validation gates before live use

1. Compile in the current MetaEditor with zero errors; investigate every warning.
2. Backtest with MT5 **Every tick based on real ticks**, using the Pepperstone XAU symbol and variable spread.
3. Include commission and inspect rejected-order logs.
4. Use separate in-sample and out-of-sample periods covering trend, range, high-volatility, and low-volatility regimes.
5. Perform walk-forward tests; do not select settings from a single best historical period.
6. Run on a Pepperstone demo account for at least several weeks.
7. Confirm actual average spread, slippage, fill rejection rate, trade frequency, net expectancy, loss streak, margin utilization, and maximum drawdown.
8. Treat four to five trades per day as a target, not a quota. Zero trades is correct when no valid setup occurs.
9. Read the end-of-run journal report. It lists the setup funnel (how many qualified setups each gate blocked) and closed-trade results by tier and by UTC session. Judge Tier 1, Tier 2 and each session separately; the Asian hours are new in v1.2.

Live deployment is not approved by this specification. It requires explicit review of test evidence and acceptance of leveraged-CFD risk.
