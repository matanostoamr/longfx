# Aegis Gold Trend-Pullback EA — Locked Strategy Specification v1.1

## 0. v1.1 change log (from v1.0)

| Area | v1.0 | v1.1 default |
|---|---|---|
| Entry window | 08:00–12:00 London local + 08:00–12:00 New York local | 07:00–18:00 UTC (v1.0 windows still selectable) |
| Pullback trigger | Single tier: 1.5 ATR band touch + RSI(2) ≤ 10 / ≥ 90 | Tier 2: 1.2 ATR band + RSI(2) ≤ 15 / ≥ 85; Tier 1: EMA20 basis + RSI(2) ≤ 30 / ≥ 70 |
| Max SL | Fixed $5.00 | `clamp(1.5 × M15 ATR14, $5.00, $7.00)` |
| TP cap | $6.50 | $9.80 (keeps 1.4R up to a $7.00 stop) |
| Loss halt | Two losing positions in total | Two **consecutive** losing positions (total mode selectable) |
| Magic number | 26092801 | 26092811 (keeps v1.0 and v1.1 statistics separate) |

v1.0 behaviour is reproducible with: `InpUseUtcSessionWindow=false`, `InpEnableTier1=false`, `InpKeltnerAtrMultiplier=1.5`, `InpTier2RsiLongThreshold=10`, `InpTier2RsiShortThreshold=90`, `InpUseAdaptiveMaxStop=false`, `InpMaximumTargetPrice=6.5`, `InpDailyLossCountMode=LOSS_COUNT_TOTAL`.

The v1.0 3-month result (9 trades, PF 2.69) does not validate the v1.1 triggers: Tier 1 and the wider stop add trades that v1.0 never took. v1.1 must be re-tested from scratch.

## 1. Status and calibration boundary

This document locks the second implementation candidate for MT5. The values below are execution-aware defaults, not a claim of statistical optimization. No Pepperstone XAU/USD tick dataset is available in this workspace, so profitability, expected frequency, and win rate remain unverified until real-tick backtesting and demo forward testing are complete.

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
| Daily entry cap | Five filled entries per MT5 trade-server calendar day |
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
- Tier 1 (shallow) thresholds: RSI ≤ 30 for longs, ≥ 70 for shorts

RSI is a timing condition, not a standalone entry.

## 4. Closed-candle entry setup

At the first tick of a new M5 candle:

- `shift 2` is the exhaustion/pullback candle.
- `shift 1` is the confirmation candle.

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
- Exhaustion RSI(2) ≤ 30.
- Confirmation closes back above its EMA20 basis (`InpTier1RequireBasisReclaim`).

Place a buy-stop at the confirmation high plus $0.05. Both tiers use identical sizing, SL, and TP rules; the order comment records the tier (`AegisGold-v1.1-T1` / `-T2`) so results can be split per tier.

### 4.2 Short setup

Exact mirror: M15 short regime; bearish confirmation closing at or below its midpoint and below the exhaustion close; Tier 2 needs the exhaustion high at or above `EMA20 + 1.2 × ATR20` with RSI(2) ≥ 85 and a confirmation close back below that band; Tier 1 needs the exhaustion high at or above EMA20 with RSI(2) ≥ 70 and a confirmation close back below EMA20. Place a sell-stop at the confirmation low minus $0.05.

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

For a long, the structural candidate is the most recent swing low minus `0.15 × ATR20`.
For a short, it is the most recent swing high plus `0.15 × ATR20`.

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

Default (`InpUseUtcSessionWindow=true`): new entries are allowed from 07:00 to 18:00 UTC, Monday–Friday.

Legacy option (`InpUseUtcSessionWindow=false`): the v1.0 windows of 08:00–12:00 Europe/London and 08:00–12:00 America/New_York local time, with UK and US daylight-saving conversion.

In the Strategy Tester, UTC is derived from the Pepperstone server offset (GMT+2 / GMT+3 following US DST). Existing positions remain protected and active outside entry windows.

No entry is permitted on Saturday or Sunday.

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

- five entries;
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
8. Treat three to five trades as a ceiling/expected opportunity range—not a quota. Zero trades is correct when no valid setup occurs.

Live deployment is not approved by this specification. It requires explicit review of test evidence and acceptance of leveraged-CFD risk.
