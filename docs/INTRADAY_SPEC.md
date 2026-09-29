# Aegis Gold Intraday v2.0 — experiment specification

Standalone EA: [`MQL5/Experts/AegisGoldIntraday.mq5`](../MQL5/Experts/AegisGoldIntraday.mq5), magic number 26092820. It neither changes nor depends on v1.5 (`AegisGoldTrendPullback.mq5`), which stays the locked build on demo. Sessions, market-close handling, shield filters, the margin gate and order housekeeping are copied unchanged from v1.5.

## 1. Pass/fail rule (agreed before testing)

Test on Pepperstone UK real ticks with a £400 deposit, using the same leverage, commission and news-filter settings as the v1.5 runs.

| Period | Requirement |
|---|---|
| 28 Jun – 28 Sep 2026 | Net profit > 0 after all broker costs |
| 28 Mar – 28 Jun 2026 | Net profit > 0 after all broker costs |
| 9 Feb – 28 Mar 2026 (untouched) | Net profit > 0 after all broker costs |

In addition, combined net profit over the three periods must beat v1.5's combined net profit on the same periods. v1.5 still needs one run on 9 Feb – 28 Mar for this comparison. If any requirement fails, the intraday EA is shelved and v1.5 stays.

Runs:

1. Defaults, all three periods.
2. Variant `InpEnableTier1=false`, `InpTradeAsiaSession=false`, all three periods.
3. v1.5, 9 Feb – 28 Mar.

Either configuration can pass, but judge each against the rule above rather than picking whichever looks better in Jun–Sep.

## 2. Regime reader and setups

The regime is read on the last completed M15 bar:

- **Uptrend / downtrend:** EMA50 above (below) EMA200 and EMA50 rising (falling) over two bars; uses the trend engine.
- **Flat:** no trend and |EMA50 − EMA200| ≤ 1.0 × ATR14; uses the range engine.
- **Transition:** anything else; uses the M5 stack engine.

Setups use closed M5 bars: shift 2 is the exhaustion bar and shift 1 the confirmation bar. The exhaustion, confirmation and current bars must be consecutive, and the confirmation true range must be ≤ 1.5 × ATR20.

| Tag | Regime | Long rule (shorts mirror) |
|---|---|---|
| T2 | trend | Low ≤ EMA20 − 1.2 × ATR20, RSI(2) ≤ 15; confirmation bullish, closing in its upper half, above the exhaustion close, back above the band |
| T1 | trend | Low ≤ EMA20, RSI(2) ≤ 35; confirmation as T2, closing above EMA20 |
| T0 | trend | Low ≤ EMA9 but above EMA20, RSI(2) ≤ 40; confirmation bullish, upper half, above EMA9, with EMA9 > EMA20 |
| R | flat | Low ≤ EMA20 − 1.5 × ATR20, RSI(2) ≤ 10; confirmation as T2, back above the band |
| X | transition | M5 EMA9 > EMA20 > EMA50 with EMA20 rising; low ≤ EMA9, RSI(2) ≤ 40; confirmation bullish, upper half, above EMA9 |

Trend setups are checked in the order T2, T1, T0.

## 3. Entry, exits and risk

- **Entry:** buy stop at the confirmation high + $0.05 (sell stop at the low − $0.05). It is skipped if the broker's minimum stop distance would move it more than $0.20, and it expires after two M5 bars.
- **Bracket:** take profit $4.00 and stop loss $3.00 from the order price, attached to the order.
- **Breakeven:** once price is $1.50 in favour, the stop moves to entry + $0.10.
- **Time stop:** off by default (`InpTimeStopMinutes`).
- **Weekend close:** every EA position is closed 15 minutes before the weekly close.
- **Positions:** fixed 0.02 lot, one at a time. `InpMaxConcurrentPositions=2` allows a second position in the same direction, on hedging accounts only, when the margin gate passes.
- **Daily loss stop:** 6% of the day's starting balance (£24 at £400). A new order is placed only if today's net, minus the loss at every open stop, minus the new order's stop loss (with $0.05 slippage and commission), stays above −6%. There is no daily trade cap (`InpMaxEntriesPerDay=0`) and no cooldown.

## 4. Rocket-move shield (unchanged from v1.5)

- Spread above $0.60.
- Shock candle ≥ 3 × ATR20, or ATR20 ≥ 2 × its 100-bar median; clears after three normal bars.
- Runaway: close more than 2.5 × ATR20 from EMA20, or three same-direction bodies each ≥ 0.8 × ATR20.
- High-impact USD news, 15 minutes either side.
- No new entries in the last 15 minutes of a daily session or the last 60 minutes before the weekly close.

Switches: `InpEnableTrendEngine`, `InpEnableTier0`, `InpEnableTier1`, `InpEnableTier2`, `InpEnableRangeEngine`, `InpEnableTransitionEngine`, and `InpTradeAsiaSession` (false = no new entries 21:00–07:00 UTC).

## 5. Report

At the end of a test, the journal prints lines starting with `AegisIntraday`:

- setup funnel;
- position management;
- results: trades/day with min, median and max per weekday, profit factor, max drawdown, worst day;
- by setup and by session;
- exits: take profit, stop loss, breakeven scratch, closed by EA;
- holding time;
- costs: commission, spread at entry, entry slippage, and net before those costs.

Breakeven scratches count as non-wins, so the win rate will look low (about 30% in the replica); judge by net profit and profit factor. Order comments are `AegisIntraday-<setup>-<session>`, with `-P2` added for a second position.

## 6. Replica evidence

These defaults are the best of about 120 configurations in the offline replica (Binance XAUUSDT 1-minute data; spread $0.40 in Asian hours and $0.15 otherwise; $0.05 slippage).

| Period | Trades/day | Net | PF |
|---|---:|---:|---:|
| 28 Jun – 28 Sep | 11.2 | +£50 | 1.04 |
| 28 Mar – 28 Jun | 12.5 | +£74 | 1.06 |
| 9 Feb – 28 Mar (untouched) | 11.4 | −£46 | 0.93 |

Costs were about £0.58 per trade, or £6–7 per day. The result is within chance and very sensitive to spread and slippage, so expect roughly break-even. In the replica, Tier 2 and London were profitable in both tuned quarters; Tier 1 and the Asian session were weak or losing.
