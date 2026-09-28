# Aegis Gold Trend-Pullback EA — Locked Strategy Specification v1.4

## 0. Change log

### v1.4 (from v1.3)

| Area | v1.3 | v1.4 default |
|---|---|---|
| Spread filter | Skip when spread > $0.30 | Skip when spread > $0.60 (still blocks rollover/news spikes) |
| Flat M15 regime | No setups | Range mode: when there is no M15 trend and \|EMA50 − EMA200\| ≤ 1.0 × M15 ATR14, fade the 1.5 ATR M5 band back toward EMA20 with RSI(2) ≤ 10 / ≥ 90 (`InpEnableRangeMode`) |
| Reporting | — | Current regime on the dashboard; range setups in the funnel; results by setup type (T1, T2, Range) and for entries made after a cooldown the same day (`-C` in the order comment) |
| Magic number | 26092813 | 26092814 |

v1.3 behaviour: `InpMaximumSpreadPrice=0.30`, `InpEnableRangeMode=false`.

#### v1.4 calibration evidence (approximate)

Same replica as below, now also run on 28 Mar – 28 Jun 2026 (the out-of-sample quarter). Spread modelled as $0.40 in Asian hours (21:00–07:00 UTC) and $0.13 otherwise, per the user's observation of Pepperstone Asian spreads.

With that spread model, v1.3's $0.30 filter blocked about 200 setups per quarter, more than any other rule, and removed every Asian trade. That brings the replica's v1.3 count to 2.3 trades/day, closer to the MT5 runs (1.66 and 1.38/day) than the earlier constant-spread replica (3.5/day).

| Replica run (trades/day, net GBP) | Jun–Sep | Mar–Jun |
|---|---:|---:|
| v1.3 ($0.30 filter) | 2.32, −167 | 2.31, +144 |
| + $0.60 filter | 3.25, −173 | 3.46, +93 |
| + $0.60 + range mode (v1.4 defaults) | 3.62, −55 | 3.66, +93 |
| + $0.60 + option B: M5 EMA20/50 fallback | 3.85, −215 | 3.74, −84 |
| + $0.60 + option C: no M15 slope requirement | 4.37, −220 | 4.22, +60 |

Range trades alone: 32 trades, 56% wins, +£77 (Jun–Sep); 18 trades, 50% wins, £0 (Mar–Jun). A looser flatness test (2.0 × ATR) or RSI 15/85 added trades and did slightly worse. The M5-alignment fallback's own trades lost £65 and £164; the relaxed-slope fallback's lost £76 and £41. Neither was built.

Six-month replica total for v1.4 defaults: +£38 over 473 trades. The replica ranked the two quarters the opposite way to the MT5 runs, so neither result is evidence of an edge. At this trade count, one quarter's result varies by about ±£100–£150 from chance alone.


### v1.3 (from v1.2)

| Area | v1.2 | v1.3 default |
|---|---|---|
| Concurrent positions | One | Up to two EA positions, same direction, hedging accounts only (`InpMaxConcurrentPositions`); still one pending order at a time |
| Additional-position risk | — | Skipped if today's net plus every open EA stop and the new stop would reach the −£14 limit (`InpWorstCaseDailyLossCheck`) |
| Consecutive-loss limit | Halt for the rest of the day | 2-hour cooldown, then resume; the streak restarts (`InpCooldownHoursAfterHalt`, 0 = v1.2) |
| Pending expiry | 2 M5 bars | 3 M5 bars |
| Stale trades | — | After 36 M5 bars (3 h): stop to breakeven + $0.10 if in profit, otherwise close at market (`InpStaleTradeBars`, 0 = off) |
| Weekend | No new entries in the last 60 min | Also closes every EA position 15 min before the weekly close (`InpCloseMinutesBeforeWeeklyClose`, 0 = off) |
| Reporting | Funnel, tier, session | Adds cooldown, margin and worst-case-loss funnel stages; position-management counts; additional-position, exit-type and holding-time results; margin capacity logged at start |
| Magic number | 26092812 | 26092813 |

v1.2 behaviour: `InpMaxConcurrentPositions=1`, `InpCooldownHoursAfterHalt=0`, `InpPendingExpiryBars=2`, `InpStaleTradeBars=0`, `InpCloseMinutesBeforeWeeklyClose=0`.

#### v1.3 calibration evidence (approximate)

Same offline replica and data as the v1.2 evidence below (Binance XAUUSDT 1-minute, 28 Jun – 28 Sep 2026). It does not model margin, so every second position it takes assumes enough equity for two. Relative comparisons only.

| Replica run | Trades/day | Net (GBP) | Max DD (GBP) | Worst day (GBP) |
|---|---:|---:|---:|---:|
| v1.2 | 2.74 | −77 | 172 | −52 |
| v1.2 + weekly close (W) | 2.78 | +6 | 88 | −19 |
| W + two positions with worst-case check | 2.94 | +41 | 98 | −19 |
| W + 2 h cooldown | 3.28 | −76 | 135 | −22 |
| W + expiry 3 bars | 2.77 | −33 | 100 | −19 |
| W + stale rule at 36 bars | 2.78 | +4 | 90 | −19 |
| v1.3 defaults (all of the above) | 3.51 | −125 | 179 | −23 |
| v1.3 defaults with one position | 3.29 | −126 | 163 | −22 |

- The −£52 day in v1.2 was a single short entered Friday 22:50 server time that gapped $35 through its $4 stop at Monday's open. Closing before the weekend removed it.
- In the cooldown run, the 32 trades taken after a day's first two-loss streak won 28% and lost £81 net; days ending at or below −£14 rose from 12 to 24.
- A longer expiry did not add trades: an order that waits longer blocks the next setup, and the late fills did worse.
- After weekend holds are removed, few trades last 3 hours (median holding time about 20 minutes), so the stale rule rarely acts.
- A 0.02-lot position needs about £300–£350 margin at 1:20 (gold $4,000–$4,650). Two positions need equity of about £740–£840 to pass the 120% margin-level gate, so a £400 account at 1:20 cannot hold the second position; the EA's margin gate blocks it.

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

This document locks the fifth implementation candidate for MT5. The values below are execution-aware defaults, not a claim of statistical optimization. No Pepperstone XAU/USD tick dataset is available in this workspace, so profitability, expected frequency, and win rate remain unverified until real-tick backtesting and demo forward testing are complete.

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
| Concurrent exposure | Up to two EA positions in the same direction (hedging accounts; one on netting accounts) plus at most one pending entry; any manual or other-EA position or order on the symbol blocks new entries |
| Entry timeframe | M5, evaluated once per newly opened M5 bar using closed candles only |
| Regime timeframe | M15, using closed candles only |
| Initial SL distance | $4.00 minimum; adaptive maximum `clamp(1.5 × M15 ATR14, $5.00, $7.00)` in XAU/USD price units |
| TP distance | `clamp(1.4 × actual SL distance, $6.00, $9.80)` |
| Daily entry cap | Ten filled entries per MT5 trade-server calendar day |
| Daily hard halt | Net strategy P/L at or below -£14, or ten entries; two consecutive losing positions start a 2-hour cooldown instead |
| Position sizing escalation | Prohibited |

A daily halt cancels the EA's unfilled pending entry and prevents new entries until the next trade-server day; a cooldown does the same until it ends. Neither force-closes a protected open position.

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

Place a buy-stop at the confirmation high plus $0.05. Both tiers use identical sizing, SL, and TP rules; the order comment records the setup type and UTC session (e.g. `AegisGold-v1.4-T1-ASIA`; sessions ASIA 21–07, LON 07–12, NY 12–17, LATE 17–21 UTC), plus `-P2` when the order is an additional position and `-C` when it was placed after a cooldown the same day, so results can be split per setup, session, position slot and cooldown.

### 4.1a Additional position

While one EA position is open, a new setup may add a second 0.02-lot position when all of the following hold:

- the account uses hedging mode (on a netting account the order would merge into the open position and replace its SL/TP, so the EA limits itself to one position);
- the setup is in the same direction as the open position;
- no pending order and no manual or other-EA exposure exists on the symbol;
- today's net P/L plus the loss at every open EA position's stop plus the new order's stop loss stays above -£14 (`InpWorstCaseDailyLossCheck`); and
- the margin gate in 7.5 passes.

The additional position has its own structural SL and TP, calculated exactly as for the first.

### 4.2 Short setup

Exact mirror: M15 short regime; bearish confirmation closing at or below its midpoint and below the exhaustion close; Tier 2 needs the exhaustion high at or above `EMA20 + 1.2 × ATR20` with RSI(2) ≥ 85 and a confirmation close back below that band; Tier 1 needs the exhaustion high at or above EMA20 with RSI(2) ≥ 65 and a confirmation close back below EMA20. Place a sell-stop at the confirmation low minus $0.05.

### 4.2a Range setup (flat M15 regime)

Range mode applies only when neither M15 trend regime (3.1) is valid and `|EMA50 − EMA200| ≤ 1.0 × ATR14` on the last completed M15 bar. In that state, Tier 1 and Tier 2 are not used, and the EA looks for band fades in either direction:

- Long: exhaustion low at or below `EMA20 − 1.5 × ATR20`; exhaustion RSI(2) ≤ 10; bullish confirmation that closes at or above its midpoint, above the exhaustion close, and back above its own 1.5 ATR lower band; confirmation true range ≤ 1.5 × ATR20.
- Short: exact mirror at the upper band with RSI(2) ≥ 90.

Entry, stop, target, expiry and every filter are the same as for trend setups. The order comment tag is `R` (e.g. `AegisGold-v1.4-R-ASIA`). When the M15 EMAs are neither trending nor within the flatness threshold (for example EMA50 above EMA200 but falling), no setup is taken; the dashboard shows this as "M15 mixed".

### 4.3 Pending-order handling

- The broker-side pending order includes SL and TP from creation.
- The requested entry must be adjusted when necessary to satisfy the broker's minimum stop distance.
- Reject the setup if that adjustment would worsen entry by more than $0.20 from the strategy trigger.
- Expire an unfilled pending order after three complete M5 bars.
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
- The EA's pending orders are cancelled inside these windows.
- Every EA position is closed at market 15 minutes before the weekly close (`InpCloseMinutesBeforeWeeklyClose`), so no position is held through the weekend gap. The no-entry window before the weekly close is never shorter than this.
- If the session table is empty, the EA assumes the session ends at server midnight and the week ends on Friday.
- The session table is the standard weekly schedule. Holiday early closes (for example 21:30 server time on some US holidays) are not in it, so on such a Friday the weekend close can happen before the EA closes its positions.

Legacy options: `SESSION_UTC_WINDOW` (v1.1: 07:00–18:00 UTC) and `SESSION_LONDON_NY` (v1.0: 08:00–12:00 Europe/London and 08:00–12:00 America/New_York local time, DST-aware).

In the Strategy Tester, UTC (used for legacy windows and session tags) is derived from the Pepperstone server offset. Existing positions remain protected and active outside entry windows.

## 7. Abnormal-condition filters

### 7.1 Spread

Skip when `ask - bid > $0.60` in XAU/USD price units (v1.3 and earlier: $0.30). Using a price-distance threshold avoids ambiguity between two-digit and three-digit broker quotes.

The spread is paid on every trade: at 0.02 lot, each $0.10 of spread costs about £0.15 per trade. A $0.45 Asian spread costs about £0.50 more per trade than a $0.12 London spread. The filter is kept, not removed, because rollover and news spreads can reach $1–$3, and a stop order placed into such a spike can fill far from the setup.

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

The 120% margin gate is a minimum operational guard, not a statement that this margin utilization is conservative. At UK retail leverage of 1:20, one 0.02-lot gold position needs about £300–£350 margin at $4,000–$4,650 gold, most of a £400 account. A second position needs about double; with the 120% gate that means roughly £740–£840 of equity. The EA logs the live margin per position and the equity needed for the configured number of positions on the first tick. The live MT5 margin figure is authoritative, and a Strategy Tester run must use the same leverage as the live account for its second-position results to be meaningful.

## 8. Daily accounting and hard halt

Daily statistics include only this EA's magic number and chart symbol.

- Entry count: filled entry deals.
- Position result: aggregate profit, commission, and swap for all deals sharing the completed position ID.
- Loss count: completed positions whose aggregate net result is negative.
- Daily net P/L: aggregate profit, commission, and swap for all strategy deals since trade-server midnight.

No new order is allowed for the rest of the server day when either condition is reached:

- ten entries; or
- net daily P/L at or below -£14.

Two consecutive losing positions start a cooldown (`InpCooldownHoursAfterHalt`, default 2 hours) measured from the exit of the second loss. During the cooldown, no new order is placed and the EA's pending order is cancelled; open positions keep their SL/TP. When it ends, the streak count restarts from zero, so another two consecutive losses start another cooldown. The loss order follows the exit time of each position, which matters when two positions are open together. Daily counters reset at server midnight, which also ends any running cooldown.

With `InpCooldownHoursAfterHalt=0`, two consecutive losses halt the EA for the rest of the day (v1.2). `InpDailyLossCountMode=LOSS_COUNT_TOTAL` restores the v1.0 rule of two losses in total, which always halts for the day.

A position closed early by the stale-trade rule or the weekend close counts like any other: a net loss extends the streak.

Worst-case day: the -£14 limit is checked before new entries, not during a trade. With one position, the day can end about one full loss beyond it (about -£24). The worst-case check keeps an additional position from being opened when both stops together would cross the limit.

There is no daily profit target and no recovery sizing.

## 9. Position management

Exits are broker-side SL/TP, plus two EA actions:

- **Weekend close:** every EA position is closed at market 15 minutes before the weekly close.
- **Stale-trade release:** a position still open 36 M5 bars (3 hours) after its fill has its stop moved to entry + $0.10 (breakeven after costs) when the price is far enough in profit for the broker to accept that stop; otherwise it is closed at market (`InpStaleTradeAction`; `STALE_CLOSE` always closes, `STALE_BREAKEVEN_ONLY` only moves the stop). The rule acts once per position.

Everything else is unchanged:

- No trailing stop.
- No widening or removal of SL.
- No averaging, grid, martingale, or recovery sizing; an additional position (4.1a) is a separate setup with its own stop and the same fixed 0.02 lot.
- No indicator-driven panic exit.
- A news window, a daily halt or a cooldown does not close an already protected position.

The end-of-run report splits exits into take profit, stop loss (including breakeven stops), EA-closed and other, so the effect of these two actions can be measured.

## 10. Validation gates before live use

1. Compile in the current MetaEditor with zero errors; investigate every warning.
2. Backtest with MT5 **Every tick based on real ticks**, using the Pepperstone XAU symbol and variable spread.
3. Include commission and inspect rejected-order logs.
4. Use separate in-sample and out-of-sample periods covering trend, range, high-volatility, and low-volatility regimes.
5. Perform walk-forward tests; do not select settings from a single best historical period.
6. Run on a Pepperstone demo account for at least several weeks.
7. Confirm actual average spread, slippage, fill rejection rate, trade frequency, net expectancy, loss streak, margin utilization, and maximum drawdown.
8. Treat four to five trades per day as a target, not a quota. Zero trades is correct when no valid setup occurs.
9. Read the end-of-run journal report. It lists the setup funnel (how many qualified setups each gate blocked), position-management counts, and closed-trade results by setup type (T1, T2, Range), UTC session, entries after a cooldown, additional position, exit type and holding time. Judge each of these separately.
10. Run the Strategy Tester at the live account's leverage (1:20 for UK retail gold). A higher tester leverage lets the second position through the margin gate, which the live account cannot do.

Live deployment is not approved by this specification. It requires explicit review of test evidence and acceptance of leveraged-CFD risk.
