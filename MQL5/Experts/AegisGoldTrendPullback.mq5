#property strict
#property version   "1.40"
#property description "Aegis XAU/USD M15 regime and M5 Keltner-RSI pullback EA with flat-market range mode (v1.4, 24/5)"

#include <Trade/Trade.mqh>

CTrade Trade;

enum SignalDirection
{
   SIGNAL_SHORT = -1,
   SIGNAL_NONE  = 0,
   SIGNAL_LONG  = 1
};

enum DailyLossCountMode
{
   LOSS_COUNT_CONSECUTIVE = 0, // Halt after N consecutive losing positions
   LOSS_COUNT_TOTAL       = 1  // Halt after N losing positions in total (v1.0 behaviour)
};

enum EntrySessionMode
{
   SESSION_24X5       = 0, // 24/5: scan every M5 bar while the market is open (v1.2)
   SESSION_UTC_WINDOW = 1, // Single UTC window (v1.1: 07:00-18:00 UTC)
   SESSION_LONDON_NY  = 2  // London + New York local windows (v1.0)
};

enum StaleTradeAction
{
   STALE_BREAKEVEN_ELSE_CLOSE = 0, // Move SL to breakeven if in profit, otherwise close at market
   STALE_CLOSE                = 1, // Close at market
   STALE_BREAKEVEN_ONLY       = 2  // Move SL to breakeven once in profit, otherwise leave it
};

// Setup-funnel counters: every qualified setup is counted once, then either
// attributed to the first gate that blocked it or counted as placed.
#define FUNNEL_SIGNAL_T1      0
#define FUNNEL_SIGNAL_T2      1
#define FUNNEL_SIGNAL_RANGE   2
#define FUNNEL_HALT           3
#define FUNNEL_COOLDOWN       4
#define FUNNEL_EXPOSURE       5
#define FUNNEL_SESSION        6
#define FUNNEL_MARKET_CLOSE   7
#define FUNNEL_SPREAD         8
#define FUNNEL_SHOCK          9
#define FUNNEL_RUNAWAY        10
#define FUNNEL_NEWS           11
#define FUNNEL_CHASE          12
#define FUNNEL_NO_SWING       13
#define FUNNEL_STOP_TOO_WIDE  14
#define FUNNEL_RISK_BUDGET    15
#define FUNNEL_MARGIN         16
#define FUNNEL_OTHER          17
#define FUNNEL_PLACED         18
#define FUNNEL_SIZE           19

// Setup types (recorded in the order comment as T1, T2 or R)
#define SETUP_TIER1           1
#define SETUP_TIER2           2
#define SETUP_RANGE           3

input group "Identity and account safety"
input ulong  InpMagicNumber                  = 26092814;
input bool   InpRequireGBPAccount             = true;
input double InpFixedLots                     = 0.02;
input double InpMinimumProjectedMarginLevel   = 120.0;

input group "Trend regime (M15)"
input int    InpM15FastEmaPeriod              = 50;
input int    InpM15SlowEmaPeriod              = 200;
input int    InpM15SlopeLookbackBars          = 2;

input group "Keltner / RSI (M5)"
input int    InpM5KeltnerEmaPeriod            = 20;
input int    InpM5AtrPeriod                   = 20;
input int    InpRsiPeriod                     = 2;
input double InpMaxConfirmationRangeAtr       = 1.50;

input group "Tier 1: shallow pullback to Keltner middle (EMA20)"
input bool   InpEnableTier1                   = true;
input double InpTier1RsiLongThreshold         = 35.0;
input double InpTier1RsiShortThreshold        = 65.0;
input bool   InpTier1RequireBasisReclaim      = true;

input group "Tier 2: deep pullback to outer Keltner band"
input bool   InpEnableTier2                   = true;
input double InpKeltnerAtrMultiplier          = 1.20;
input double InpTier2RsiLongThreshold         = 15.0;
input double InpTier2RsiShortThreshold        = 85.0;

input group "Range mode: flat M15 regime"
// When the M15 trend filter is off and the EMAs have converged, fade the outer M5 band back toward EMA20
input bool   InpEnableRangeMode               = true;
// Flat = no M15 trend and |EMA50 - EMA200| <= this multiple of M15 ATR14
input double InpRangeMaxEmaGapAtr             = 1.00;
input double InpRangeBandAtr                  = 1.50;
input double InpRangeRsiLongThreshold         = 10.0;
input double InpRangeRsiShortThreshold        = 90.0;

input group "Entry, stop and target"
input double InpEntryBufferPrice              = 0.05;
input double InpMaxEntryAdjustmentPrice       = 0.20;
input int    InpPendingExpiryBars             = 3;
input int    InpSwingLookbackBars             = 12;
input double InpSwingAtrBuffer                = 0.15;
// Stop always beyond both signal candles (false = v1.1 swing search)
input bool   InpStopBeyondSignalCandles       = true;
input double InpMinimumStopPrice              = 4.00;
input bool   InpUseAdaptiveMaxStop            = true;
input int    InpM15AtrPeriod                  = 14;
input double InpAdaptiveStopM15AtrMultiple    = 1.50;
// Fixed max stop, and floor of the adaptive max
input double InpMaximumStopPrice              = 5.00;
// Hard ceiling of the adaptive max
input double InpAbsoluteMaximumStopPrice      = 7.00;
input double InpRewardMultiple                = 1.40;
input double InpMinimumTargetPrice            = 6.00;
// 1.4 x $7.00 keeps 1.4R at the widest stop
input double InpMaximumTargetPrice            = 9.80;
input int    InpMaximumDeviationPoints        = 20;

input group "Position capacity"
// EA positions allowed at once on this symbol (hedging accounts only; netting accounts use 1)
input int    InpMaxConcurrentPositions        = 2;
// Skip an additional position if every open EA position plus the new one stopping out would breach the daily loss limit
input bool   InpWorstCaseDailyLossCheck       = true;

input group "Stale-trade release"
// M5 bars after the fill before the rule acts (36 = 3 hours); 0 = off
input int    InpStaleTradeBars                = 36;
input StaleTradeAction InpStaleTradeAction    = STALE_BREAKEVEN_ELSE_CLOSE;
// Breakeven stop is placed this far beyond the entry price (covers commission and spread)
input double InpBreakevenOffsetPrice          = 0.10;

input group "Sessions"
input EntrySessionMode InpSessionMode         = SESSION_24X5;
// Used only by SESSION_UTC_WINDOW
input int    InpUtcSessionStartHour           = 7;
input int    InpUtcSessionEndHour             = 18;
input int    InpLondonStartHour               = 8;
input int    InpLondonEndHour                 = 12;
input int    InpNewYorkStartHour              = 8;
input int    InpNewYorkEndHour                = 12;
input bool   InpTesterUsesPepperstoneServer   = true;
input int    InpFallbackServerUtcOffsetHours  = 2;

input group "Market-close protection (broker session table)"
// 0 = off. No new entries, pending orders cancelled
input int    InpNoEntryMinutesBeforeDailyClose  = 15;
// 0 = off. Same, before the last session of the week
input int    InpNoEntryMinutesBeforeWeeklyClose = 60;
// Close all EA positions this many minutes before the weekly close (weekend-gap protection); 0 = off
input int    InpCloseMinutesBeforeWeeklyClose   = 15;

input group "Abnormal-condition filters"
input double InpMaximumSpreadPrice            = 0.60;
input bool   InpUseNewsFilter                 = true;
input bool   InpNewsFailClosed                = true;
input int    InpNewsMinutesBefore             = 15;
input int    InpNewsMinutesAfter              = 15;
input double InpShockCandleAtrMultiple        = 3.00;
input double InpShockAtrMedianMultiple        = 2.00;
input int    InpAtrMedianLookbackBars         = 100;
input int    InpNormalBarsAfterShock          = 3;
input double InpRunawayDistanceAtr            = 2.50;
input double InpRunawayBodyAtr                = 0.80;

input group "Daily controls (account currency)"
input int    InpMaximumDailyEntries           = 10;
input int    InpMaximumDailyLosses            = 2;
input DailyLossCountMode InpDailyLossCountMode = LOSS_COUNT_CONSECUTIVE;
// Pause new entries for this many hours after the consecutive-loss limit; 0 = halt for the rest of the day (v1.2)
input int    InpCooldownHoursAfterHalt        = 2;
input double InpMaximumDailyDrawdown          = 14.0;

int      g_m5EmaHandle       = INVALID_HANDLE;
int      g_m5AtrHandle       = INVALID_HANDLE;
int      g_m5RsiHandle       = INVALID_HANDLE;
int      g_m15FastEmaHandle  = INVALID_HANDLE;
int      g_m15SlowEmaHandle  = INVALID_HANDLE;
int      g_m15AtrHandle      = INVALID_HANDLE;
datetime g_lastM5BarTime     = 0;
datetime g_dailyStart        = 0;
int      g_dailyEntries      = 0;
int      g_dailyLosses       = 0;     // total losing positions today
int      g_dailyConsecLosses = 0;     // current consecutive losing streak today (resets after a cooldown)
int      g_lastSetup         = 0;
string   g_regimeText        = "M15 regime not evaluated yet";
double   g_dailyNet          = 0.0;
bool     g_dailyHalted       = false;
string   g_status            = "Initializing";
int      g_funnel[FUNNEL_SIZE];       // setup funnel for the end-of-run report
datetime g_runStart          = 0;
int      g_maxPositions      = 1;     // effective concurrent-position limit (1 on netting accounts)
bool     g_lossHalt          = false; // loss-count halt for the rest of the server day
datetime g_cooldownUntil     = 0;     // end of the current loss-streak cooldown (server time)
int      g_dailyCooldowns    = 0;     // cooldowns started today
datetime g_lastManageTime    = 0;
datetime g_nextCloseAttempt  = 0;
bool     g_marginLogged      = false;
int      g_placedAdditional  = 0;     // orders placed while another EA position was open
int      g_eventCooldowns    = 0;
int      g_eventWeeklyCloses = 0;
int      g_eventStaleCloses  = 0;
int      g_eventBreakevens   = 0;

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   string symbol_name = _Symbol;
   StringToUpper(symbol_name);
   if(StringFind(symbol_name, "XAU") < 0)
   {
      Print("Initialization failed: attach the EA to Pepperstone's XAU/USD symbol chart.");
      return INIT_FAILED;
   }

   string profit_currency = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_PROFIT);
   if(profit_currency != "USD")
   {
      PrintFormat("Initialization failed: %s profit currency is %s, not USD; dollar price-distance rules are unsafe.",
                  _Symbol, profit_currency);
      return INIT_FAILED;
   }

   string account_currency = AccountInfoString(ACCOUNT_CURRENCY);
   if(InpRequireGBPAccount && account_currency != "GBP")
   {
      PrintFormat("Initialization failed: strict GBP mode is enabled but account currency is %s.", account_currency);
      return INIT_FAILED;
   }

   if(!InputsAreValid() || !VolumeIsValid(InpFixedLots))
      return INIT_PARAMETERS_INCORRECT;

   ENUM_SYMBOL_TRADE_MODE trade_mode = (ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
   if(trade_mode == SYMBOL_TRADE_MODE_DISABLED || trade_mode == SYMBOL_TRADE_MODE_CLOSEONLY)
   {
      Print("Initialization failed: the symbol does not currently permit new trades.");
      return INIT_FAILED;
   }

   g_m5EmaHandle      = iMA(_Symbol, PERIOD_M5, InpM5KeltnerEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_m5AtrHandle      = iATR(_Symbol, PERIOD_M5, InpM5AtrPeriod);
   g_m5RsiHandle      = iRSI(_Symbol, PERIOD_M5, InpRsiPeriod, PRICE_CLOSE);
   g_m15FastEmaHandle = iMA(_Symbol, PERIOD_M15, InpM15FastEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_m15SlowEmaHandle = iMA(_Symbol, PERIOD_M15, InpM15SlowEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_m15AtrHandle     = iATR(_Symbol, PERIOD_M15, InpM15AtrPeriod);

   if(g_m5EmaHandle == INVALID_HANDLE || g_m5AtrHandle == INVALID_HANDLE ||
      g_m5RsiHandle == INVALID_HANDLE || g_m15FastEmaHandle == INVALID_HANDLE ||
      g_m15SlowEmaHandle == INVALID_HANDLE || g_m15AtrHandle == INVALID_HANDLE)
   {
      PrintFormat("Initialization failed: unable to create indicator handles. Error %d.", GetLastError());
      ReleaseIndicators();
      return INIT_FAILED;
   }

   Trade.SetExpertMagicNumber(InpMagicNumber);
   Trade.SetDeviationInPoints(InpMaximumDeviationPoints);
   Trade.SetTypeFillingBySymbol(_Symbol);
   Trade.SetAsyncMode(false);

   g_maxPositions = InpMaxConcurrentPositions;
   if(g_maxPositions > 1 &&
      (ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
   {
      PrintFormat("Netting account: a second order would merge into the open position and replace its SL/TP. "
                  "Concurrent positions limited to 1 (input was %d).", InpMaxConcurrentPositions);
      g_maxPositions = 1;
   }

   ArrayInitialize(g_funnel, 0);
   g_placedAdditional = g_eventCooldowns = g_eventWeeklyCloses = g_eventStaleCloses = g_eventBreakevens = 0;
   g_cooldownUntil = g_lastManageTime = g_nextCloseAttempt = 0;
   g_marginLogged = false;
   g_runStart = TimeCurrent();
   g_lastM5BarTime = iTime(_Symbol, PERIOD_M5, 0);
   RefreshDailyStats();
   LogSymbolConfiguration();
   LogTradeSessions();

   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED))
      Print("Warning: automated trading is currently disabled; enable Algo Trading before demo operation.");

   SetStatus("Ready; waiting for a new M5 bar");
   UpdateDashboard();
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   PrintRunSummary();
   ReleaseIndicators();
   Comment("");
}

//+------------------------------------------------------------------+
//| Tick handler                                                     |
//+------------------------------------------------------------------+
void OnTick()
{
   RefreshDailyStatsIfNeeded();
   if(!g_marginLogged)
      LogMarginCapacity();

   ManageOpenPositions();

   string close_reason = "";
   if(g_dailyHalted)
      CancelOwnPendingOrders("daily halt");
   else if(IsInCooldown())
      CancelOwnPendingOrders("loss-streak cooldown");
   else if(OrdersTotal() > 0 && IsNearMarketClose(close_reason))
      CancelOwnPendingOrders("market-close protection");
   else
      CancelExpiredOwnPendingOrders();

   if(IsNewM5Bar())
      EvaluateNewM5Bar();

   UpdateDashboard();
}

//+------------------------------------------------------------------+
//| Refresh risk state immediately after account transactions        |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   RefreshDailyStats();
}

//+------------------------------------------------------------------+
//| Validate all strategy inputs                                     |
//+------------------------------------------------------------------+
bool InputsAreValid()
{
   bool valid = true;

   if(InpFixedLots <= 0.0 || InpMinimumProjectedMarginLevel <= 0.0)
      valid = false;
   if(InpM15FastEmaPeriod <= 1 || InpM15SlowEmaPeriod <= InpM15FastEmaPeriod ||
      InpM15SlopeLookbackBars < 1)
      valid = false;
   if(InpM5KeltnerEmaPeriod <= 1 || InpM5AtrPeriod <= 1 || InpRsiPeriod <= 0 ||
      InpKeltnerAtrMultiplier <= 0.0 || InpM15AtrPeriod <= 1)
      valid = false;
   if(!InpEnableTier1 && !InpEnableTier2)
      valid = false;
   if(InpRangeMaxEmaGapAtr <= 0.0 || InpRangeBandAtr <= 0.0 ||
      InpRangeRsiLongThreshold <= 0.0 || InpRangeRsiLongThreshold >= 50.0 ||
      InpRangeRsiShortThreshold <= 50.0 || InpRangeRsiShortThreshold >= 100.0)
      valid = false;
   if(InpTier1RsiLongThreshold <= 0.0 || InpTier1RsiLongThreshold >= 50.0 ||
      InpTier1RsiShortThreshold <= 50.0 || InpTier1RsiShortThreshold >= 100.0 ||
      InpTier2RsiLongThreshold <= 0.0 || InpTier2RsiLongThreshold >= 50.0 ||
      InpTier2RsiShortThreshold <= 50.0 || InpTier2RsiShortThreshold >= 100.0)
      valid = false;
   if(InpMinimumStopPrice <= 0.0 || InpMaximumStopPrice < InpMinimumStopPrice ||
      InpAbsoluteMaximumStopPrice < InpMaximumStopPrice || InpAdaptiveStopM15AtrMultiple <= 0.0 ||
      InpMinimumTargetPrice <= 0.0 || InpMaximumTargetPrice < InpMinimumTargetPrice ||
      InpRewardMultiple <= 0.0)
      valid = false;
   if(InpUtcSessionStartHour < 0 || InpUtcSessionStartHour > 23 || InpUtcSessionEndHour < 1 ||
      InpUtcSessionEndHour > 24 || InpUtcSessionStartHour >= InpUtcSessionEndHour)
      valid = false;
   if(InpNoEntryMinutesBeforeDailyClose < 0 || InpNoEntryMinutesBeforeWeeklyClose < 0 ||
      InpCloseMinutesBeforeWeeklyClose < 0)
      valid = false;
   if(InpMaxConcurrentPositions < 1 || InpMaxConcurrentPositions > 3 || InpCooldownHoursAfterHalt < 0 ||
      InpCooldownHoursAfterHalt > 24 || InpStaleTradeBars < 0 || InpBreakevenOffsetPrice < 0.0)
      valid = false;
   if(InpPendingExpiryBars < 1 || InpSwingLookbackBars < 3 || InpAtrMedianLookbackBars < 10 ||
      InpNormalBarsAfterShock < 1)
      valid = false;
   if(InpMaximumSpreadPrice <= 0.0 || InpMaximumDailyEntries < 1 ||
      InpMaximumDailyLosses < 1 || InpMaximumDailyDrawdown <= 0.0)
      valid = false;
   if(InpLondonStartHour < 0 || InpLondonStartHour > 23 || InpLondonEndHour < 1 ||
      InpLondonEndHour > 24 || InpLondonStartHour >= InpLondonEndHour ||
      InpNewYorkStartHour < 0 || InpNewYorkStartHour > 23 || InpNewYorkEndHour < 1 ||
      InpNewYorkEndHour > 24 || InpNewYorkStartHour >= InpNewYorkEndHour)
      valid = false;

   if(!valid)
      Print("Initialization failed: one or more EA inputs are invalid.");
   return valid;
}

//+------------------------------------------------------------------+
//| Validate fixed volume against broker symbol properties           |
//+------------------------------------------------------------------+
bool VolumeIsValid(const double volume)
{
   double minimum = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maximum = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(step <= 0.0 || volume < minimum - 1e-9 || volume > maximum + 1e-9)
   {
      PrintFormat("Invalid volume %.4f; broker range is %.4f to %.4f with %.4f step.",
                  volume, minimum, maximum, step);
      return false;
   }

   double steps = (volume - minimum) / step;
   if(MathAbs(steps - MathRound(steps)) > 1e-7)
   {
      PrintFormat("Invalid volume %.4f; it does not align with broker step %.4f.", volume, step);
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| Evaluate the strategy exactly once per new M5 bar                |
//| Every qualified setup is counted, then attributed to the first   |
//| gate that blocks it (or to "placed"), so the end-of-run funnel   |
//| shows exactly what each rule costs in trade frequency.           |
//+------------------------------------------------------------------+
void EvaluateNewM5Bar()
{
   RefreshDailyStats();
   CancelExpiredOwnPendingOrders();

   bool cooling_down = IsInCooldown();
   if(g_dailyHalted || cooling_down)
      CancelOwnPendingOrders(g_dailyHalted ? "daily halt" : "loss-streak cooldown");

   int  own_positions    = 0;
   int  own_direction    = 0;
   bool foreign_exposure = false;
   ScanSymbolExposure(own_positions, own_direction, foreign_exposure);

   // Setup-independent gates, evaluated first so the dashboard keeps showing why the EA is idle.
   int    gate_stage   = -1;
   string gate_status  = "";
   string close_reason = "";
   if(g_dailyHalted)
   {
      gate_stage  = FUNNEL_HALT;
      gate_status = DailyHaltDescription();
   }
   else if(cooling_down)
   {
      gate_stage  = FUNNEL_COOLDOWN;
      gate_status = CooldownDescription();
   }
   else if(foreign_exposure)
   {
      gate_stage  = FUNNEL_EXPOSURE;
      gate_status = "Manual or other-EA position/order on this symbol; EA entries paused";
   }
   else if(HasAnyPendingOrderForSymbol())
   {
      gate_stage  = FUNNEL_EXPOSURE;
      gate_status = "Existing symbol pending order; waiting for resolution";
   }
   else if(own_positions >= g_maxPositions)
   {
      gate_stage  = FUNNEL_EXPOSURE;
      gate_status = StringFormat("%d of %d EA positions open; no further exposure", own_positions, g_maxPositions);
   }
   else if(!IsEntrySession())
   {
      gate_stage  = FUNNEL_SESSION;
      gate_status = SessionBlockDescription();
   }
   else if(IsNearMarketClose(close_reason))
   {
      gate_stage  = FUNNEL_MARKET_CLOSE;
      gate_status = close_reason;
   }

   MqlRates rates[];
   double ema[];
   double atr[];
   double rsi[];
   double m15_fast[];
   double m15_slow[];
   double m15_atr[];
   if(!LoadStrategyData(rates, ema, atr, rsi, m15_fast, m15_slow, m15_atr))
   {
      SetStatus(gate_stage >= 0 ? gate_status : "Waiting for sufficient indicator history");
      return;
   }

   int setup = 0;
   SignalDirection signal = BuildSignal(rates, ema, atr, rsi, m15_fast, m15_slow, m15_atr, setup);
   if(signal == SIGNAL_NONE)
   {
      SetStatus(gate_stage >= 0 ? gate_status : "No qualified closed-candle setup");
      return;
   }

   g_funnel[setup == SETUP_TIER1 ? FUNNEL_SIGNAL_T1 : (setup == SETUP_TIER2 ? FUNNEL_SIGNAL_T2 : FUNNEL_SIGNAL_RANGE)]++;
   if(gate_stage >= 0)
   {
      BlockSetup(gate_stage, StringFormat("%s; %s %s setup skipped", gate_status, SetupTag(setup),
                                          signal == SIGNAL_LONG ? "long" : "short"));
      return;
   }

   // An additional position must be in the same direction as the EA's open position(s).
   if(own_positions > 0 && (int)signal != own_direction)
   {
      BlockSetup(FUNNEL_EXPOSURE, "Opposite-direction setup while an EA position is open");
      return;
   }

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick) || tick.ask <= 0.0 || tick.bid <= 0.0)
   {
      BlockSetup(FUNNEL_OTHER, "No valid symbol tick");
      return;
   }

   double spread_price = tick.ask - tick.bid;
   if(spread_price > InpMaximumSpreadPrice)
   {
      BlockSetup(FUNNEL_SPREAD, StringFormat("Spread blocked: %.3f > %.3f", spread_price, InpMaximumSpreadPrice));
      return;
   }

   if(IsVolatilityShock(rates, atr))
   {
      BlockSetup(FUNNEL_SHOCK, "Volatility-shock cooldown active");
      return;
   }

   if(IsRunawayMarket(rates, ema, atr))
   {
      BlockSetup(FUNNEL_RUNAWAY, "Runaway-trend filter active");
      return;
   }

   if(IsHighImpactUsdNewsWindow())
   {
      BlockSetup(FUNNEL_NEWS, "High-impact USD news window or unavailable calendar");
      return;
   }

   g_lastSetup = setup;
   bool additional = (own_positions > 0);
   int stage = PlaceProtectedPendingOrder(signal, setup, additional, rates, atr,
                                          CurrentMaximumStopPrice(m15_atr), tick);
   g_funnel[stage]++;
   if(stage == FUNNEL_PLACED && additional)
      g_placedAdditional++;
}

void BlockSetup(const int stage, const string status)
{
   g_funnel[stage]++;
   SetStatus(status);
}

//+------------------------------------------------------------------+
//| Maximum structural stop: fixed, or adaptive to completed M15 ATR |
//+------------------------------------------------------------------+
double CurrentMaximumStopPrice(const double &m15_atr[])
{
   if(!InpUseAdaptiveMaxStop)
      return InpMaximumStopPrice;
   return Clamp(InpAdaptiveStopM15AtrMultiple * m15_atr[1],
                InpMaximumStopPrice, InpAbsoluteMaximumStopPrice);
}

//+------------------------------------------------------------------+
//| Load closed/current M5 and M15 values                             |
//+------------------------------------------------------------------+
bool LoadStrategyData(MqlRates &rates[], double &ema[], double &atr[], double &rsi[],
                      double &m15_fast[], double &m15_slow[], double &m15_atr[])
{
   int needed_m5 = InpAtrMedianLookbackBars + InpNormalBarsAfterShock + 10;
   if(needed_m5 < InpSwingLookbackBars + 5)
      needed_m5 = InpSwingLookbackBars + 5;

   int needed_m15 = InpM15SlopeLookbackBars + 3;
   if(needed_m15 < 5)
      needed_m15 = 5;

   ArraySetAsSeries(rates, true);
   ArraySetAsSeries(ema, true);
   ArraySetAsSeries(atr, true);
   ArraySetAsSeries(rsi, true);
   ArraySetAsSeries(m15_fast, true);
   ArraySetAsSeries(m15_slow, true);
   ArraySetAsSeries(m15_atr, true);

   if(BarsCalculated(g_m5EmaHandle) < needed_m5 || BarsCalculated(g_m5AtrHandle) < needed_m5 ||
      BarsCalculated(g_m5RsiHandle) < needed_m5 || BarsCalculated(g_m15FastEmaHandle) < needed_m15 ||
      BarsCalculated(g_m15SlowEmaHandle) < needed_m15 || BarsCalculated(g_m15AtrHandle) < needed_m15)
      return false;

   if(CopyRates(_Symbol, PERIOD_M5, 0, needed_m5, rates) != needed_m5)
      return false;
   if(CopyBuffer(g_m5EmaHandle, 0, 0, needed_m5, ema) != needed_m5)
      return false;
   if(CopyBuffer(g_m5AtrHandle, 0, 0, needed_m5, atr) != needed_m5)
      return false;
   if(CopyBuffer(g_m5RsiHandle, 0, 0, needed_m5, rsi) != needed_m5)
      return false;
   if(CopyBuffer(g_m15FastEmaHandle, 0, 0, needed_m15, m15_fast) != needed_m15)
      return false;
   if(CopyBuffer(g_m15SlowEmaHandle, 0, 0, needed_m15, m15_slow) != needed_m15)
      return false;
   if(CopyBuffer(g_m15AtrHandle, 0, 0, needed_m15, m15_atr) != needed_m15)
      return false;

   return (atr[1] > 0.0 && atr[2] > 0.0 && m15_atr[1] > 0.0);
}

//+------------------------------------------------------------------+
//| Build a direction and setup type from closed-candle rules        |
//| M15 trend (EMA50 vs EMA200 plus EMA50 slope), with the trend:    |
//|   Tier 2 (deep): exhaustion bar reaches the outer band (1.2 ATR) |
//|                  with RSI(2) <= 15 / >= 85.                      |
//|   Tier 1 (shallow): exhaustion bar reaches the EMA20 basis with  |
//|                  RSI(2) <= 35 / >= 65, and confirmation reclaims |
//|                  the basis. Tier 2 is checked first.             |
//| M15 flat (no trend and |EMA50 - EMA200| <= 1.0 x M15 ATR14),     |
//| either direction:                                                |
//|   Range: exhaustion bar reaches the 1.5 ATR band with RSI(2)     |
//|          <= 10 / >= 90 and confirmation closes back inside it.   |
//| The exhaustion bar, confirmation bar and current bar must be     |
//| consecutive M5 bars, so no setup spans a market break.           |
//+------------------------------------------------------------------+
SignalDirection BuildSignal(const MqlRates &rates[], const double &ema[], const double &atr[],
                            const double &rsi[], const double &m15_fast[], const double &m15_slow[],
                            const double &m15_atr[], int &setup)
{
   setup = 0;
   int slope_shift = 1 + InpM15SlopeLookbackBars;
   bool long_regime  = (m15_fast[1] > m15_slow[1] && m15_fast[1] > m15_fast[slope_shift]);
   bool short_regime = (m15_fast[1] < m15_slow[1] && m15_fast[1] < m15_fast[slope_shift]);
   bool flat_regime  = (!long_regime && !short_regime && InpEnableRangeMode &&
                        MathAbs(m15_fast[1] - m15_slow[1]) <= InpRangeMaxEmaGapAtr * m15_atr[1]);
   if(long_regime)
      g_regimeText = "M15 uptrend";
   else if(short_regime)
      g_regimeText = "M15 downtrend";
   else if(flat_regime)
      g_regimeText = "M15 flat: range mode";
   else
      g_regimeText = "M15 mixed: no setups";

   long bar_seconds = (long)PeriodSeconds(PERIOD_M5);
   if((long)rates[0].time - (long)rates[1].time != bar_seconds ||
      (long)rates[1].time - (long)rates[2].time != bar_seconds)
      return SIGNAL_NONE;

   if(!long_regime && !short_regime && !flat_regime)
      return SIGNAL_NONE;

   double confirmation_range    = TrueRange(rates, 1);
   double confirmation_midpoint = (rates[1].high + rates[1].low) * 0.5;
   if(confirmation_range > InpMaxConfirmationRangeAtr * atr[1])
      return SIGNAL_NONE;

   // Common confirmation-candle quality (direction, close location, momentum shift)
   bool long_confirm  = rates[1].close > rates[1].open &&
                        rates[1].close >= confirmation_midpoint && rates[1].close > rates[2].close;
   bool short_confirm = rates[1].close < rates[1].open &&
                        rates[1].close <= confirmation_midpoint && rates[1].close < rates[2].close;

   if(flat_regime)
   {
      if(long_confirm && rates[2].low <= ema[2] - InpRangeBandAtr * atr[2] &&
         rsi[2] <= InpRangeRsiLongThreshold && rates[1].close > ema[1] - InpRangeBandAtr * atr[1])
      {
         setup = SETUP_RANGE;
         return SIGNAL_LONG;
      }
      if(short_confirm && rates[2].high >= ema[2] + InpRangeBandAtr * atr[2] &&
         rsi[2] >= InpRangeRsiShortThreshold && rates[1].close < ema[1] + InpRangeBandAtr * atr[1])
      {
         setup = SETUP_RANGE;
         return SIGNAL_SHORT;
      }
      return SIGNAL_NONE;
   }

   if(long_regime && long_confirm)
   {
      if(InpEnableTier2)
      {
         double lower_exhaustion = ema[2] - InpKeltnerAtrMultiplier * atr[2];
         double lower_confirm    = ema[1] - InpKeltnerAtrMultiplier * atr[1];
         if(rates[2].low <= lower_exhaustion && rsi[2] <= InpTier2RsiLongThreshold &&
            rates[1].close > lower_confirm)
         {
            setup = SETUP_TIER2;
            return SIGNAL_LONG;
         }
      }
      if(InpEnableTier1)
      {
         bool reclaim = !InpTier1RequireBasisReclaim || rates[1].close > ema[1];
         if(rates[2].low <= ema[2] && rsi[2] <= InpTier1RsiLongThreshold && reclaim)
         {
            setup = SETUP_TIER1;
            return SIGNAL_LONG;
         }
      }
   }

   if(short_regime && short_confirm)
   {
      if(InpEnableTier2)
      {
         double upper_exhaustion = ema[2] + InpKeltnerAtrMultiplier * atr[2];
         double upper_confirm    = ema[1] + InpKeltnerAtrMultiplier * atr[1];
         if(rates[2].high >= upper_exhaustion && rsi[2] >= InpTier2RsiShortThreshold &&
            rates[1].close < upper_confirm)
         {
            setup = SETUP_TIER2;
            return SIGNAL_SHORT;
         }
      }
      if(InpEnableTier1)
      {
         bool reclaim = !InpTier1RequireBasisReclaim || rates[1].close < ema[1];
         if(rates[2].high >= ema[2] && rsi[2] >= InpTier1RsiShortThreshold && reclaim)
         {
            setup = SETUP_TIER1;
            return SIGNAL_SHORT;
         }
      }
   }

   return SIGNAL_NONE;
}

string SetupTag(const int setup)
{
   if(setup == SETUP_TIER1)
      return "T1";
   if(setup == SETUP_TIER2)
      return "T2";
   if(setup == SETUP_RANGE)
      return "R";
   return "?";
}

//+------------------------------------------------------------------+
//| Place a broker-side protected stop entry                         |
//+------------------------------------------------------------------+
int PlaceProtectedPendingOrder(const SignalDirection signal, const int setup, const bool additional_position,
                               const MqlRates &rates[], const double &atr[], const double maximum_stop,
                               const MqlTick &tick)
{
   ENUM_SYMBOL_TRADE_MODE trade_mode = (ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
   if((signal == SIGNAL_LONG && trade_mode == SYMBOL_TRADE_MODE_SHORTONLY) ||
      (signal == SIGNAL_SHORT && trade_mode == SYMBOL_TRADE_MODE_LONGONLY))
   {
      SetStatus("Broker symbol direction restriction blocked setup");
      return FUNNEL_OTHER;
   }

   double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double point     = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(tick_size <= 0.0 || point <= 0.0)
   {
      SetStatus("Invalid symbol tick-size metadata");
      return FUNNEL_OTHER;
   }

   double broker_stop_gap = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * point;
   double minimum_gap = MathMax(broker_stop_gap, tick_size);
   double desired_entry = 0.0;
   double entry = 0.0;

   if(signal == SIGNAL_LONG)
   {
      desired_entry = RoundUpToTick(rates[1].high + InpEntryBufferPrice);
      entry = RoundUpToTick(MathMax(desired_entry, tick.ask + minimum_gap));
      if(entry - desired_entry > InpMaxEntryAdjustmentPrice + tick_size * 0.5)
      {
         SetStatus("Buy trigger already missed beyond chase allowance");
         return FUNNEL_CHASE;
      }
   }
   else
   {
      desired_entry = RoundDownToTick(rates[1].low - InpEntryBufferPrice);
      entry = RoundDownToTick(MathMin(desired_entry, tick.bid - minimum_gap));
      if(desired_entry - entry > InpMaxEntryAdjustmentPrice + tick_size * 0.5)
      {
         SetStatus("Sell trigger already missed beyond chase allowance");
         return FUNNEL_CHASE;
      }
   }

   double swing_price = 0.0;
   bool swing_found = (signal == SIGNAL_LONG)
                      ? FindMostRecentSwingLow(rates, swing_price)
                      : FindMostRecentSwingHigh(rates, swing_price);
   if(InpStopBeyondSignalCandles)
   {
      // The stop must also clear both signal candles. Without this, a confirmation candle that
      // undercuts (or overshoots) the exhaustion candle pushes the swing search to older bars and
      // can leave the stop inside the setup's own range, or on the wrong side of the entry.
      double pattern_extreme = (signal == SIGNAL_LONG)
                               ? MathMin(rates[1].low, rates[2].low)
                               : MathMax(rates[1].high, rates[2].high);
      if(!swing_found)
         swing_price = pattern_extreme;
      else if(signal == SIGNAL_LONG)
         swing_price = MathMin(swing_price, pattern_extreme);
      else
         swing_price = MathMax(swing_price, pattern_extreme);
      swing_found = true;
   }
   if(!swing_found)
   {
      SetStatus("No confirmed structural swing in lookback");
      return FUNNEL_NO_SWING;
   }

   double structural_stop = (signal == SIGNAL_LONG)
                            ? swing_price - InpSwingAtrBuffer * atr[1]
                            : swing_price + InpSwingAtrBuffer * atr[1];
   double structural_distance = (signal == SIGNAL_LONG)
                                ? entry - structural_stop
                                : structural_stop - entry;

   if(structural_distance <= 0.0)
   {
      SetStatus("Structural stop lies on invalid side of entry");
      return FUNNEL_OTHER;
   }

   if(structural_distance > maximum_stop + tick_size * 0.5)
   {
      SetStatus(StringFormat("Structure needs %.2f stop; current maximum is %.2f",
                             structural_distance, maximum_stop));
      return FUNNEL_STOP_TOO_WIDE;
   }

   double stop_distance = MathMax(structural_distance, InpMinimumStopPrice);
   double stop_loss = 0.0;
   if(signal == SIGNAL_LONG)
      stop_loss = RoundDownToTick(entry - stop_distance);
   else
      stop_loss = RoundUpToTick(entry + stop_distance);

   stop_distance = MathAbs(entry - stop_loss);
   if(stop_distance > maximum_stop + tick_size)
   {
      SetStatus("Tick normalization pushed stop beyond maximum");
      return FUNNEL_STOP_TOO_WIDE;
   }

   double target_distance = Clamp(stop_distance * InpRewardMultiple,
                                  InpMinimumTargetPrice, InpMaximumTargetPrice);
   double take_profit = (signal == SIGNAL_LONG)
                        ? RoundUpToTick(entry + target_distance)
                        : RoundDownToTick(entry - target_distance);

   if(MathAbs(entry - stop_loss) < minimum_gap || MathAbs(take_profit - entry) < minimum_gap)
   {
      SetStatus("Broker minimum stop distance rejected SL/TP geometry");
      return FUNNEL_OTHER;
   }

   if(additional_position && InpWorstCaseDailyLossCheck)
   {
      double worst_case = 0.0;
      if(!WorstCaseDailyNet(signal, entry, stop_loss, worst_case))
      {
         SetStatus("Worst-case daily loss unavailable; additional position skipped");
         return FUNNEL_RISK_BUDGET;
      }
      if(worst_case <= -InpMaximumDailyDrawdown)
      {
         SetStatus(StringFormat("Additional position skipped: if every stop is hit, today's net would be %.2f (limit -%.2f)",
                                worst_case, InpMaximumDailyDrawdown));
         return FUNNEL_RISK_BUDGET;
      }
   }

   if(!HasSufficientMargin(signal, entry))
      return FUNNEL_MARGIN;

   ENUM_ORDER_TYPE_TIME order_time = ORDER_TIME_GTC;
   datetime expiration = 0;
   long expiration_modes = SymbolInfoInteger(_Symbol, SYMBOL_EXPIRATION_MODE);
   if((expiration_modes & SYMBOL_EXPIRATION_SPECIFIED) == SYMBOL_EXPIRATION_SPECIFIED)
   {
      order_time = ORDER_TIME_SPECIFIED;
      expiration = iTime(_Symbol, PERIOD_M5, 0) + InpPendingExpiryBars * PeriodSeconds(PERIOD_M5);
   }

   // e.g. AegisGold-v1.4-T1-ASIA, AegisGold-v1.4-R-LON-P2-C (P2 = additional position, C = after a cooldown today)
   string comment = StringFormat("AegisGold-v1.4-%s-%s%s%s", SetupTag(setup), SessionTag(),
                                 additional_position ? "-P2" : "", g_dailyCooldowns > 0 ? "-C" : "");
   bool request_ok = false;
   if(signal == SIGNAL_LONG)
      request_ok = Trade.BuyStop(InpFixedLots, entry, _Symbol, stop_loss, take_profit,
                                 order_time, expiration, comment);
   else
      request_ok = Trade.SellStop(InpFixedLots, entry, _Symbol, stop_loss, take_profit,
                                  order_time, expiration, comment);

   uint retcode = Trade.ResultRetcode();
   bool accepted = request_ok && (retcode == TRADE_RETCODE_DONE || retcode == TRADE_RETCODE_PLACED);
   if(!accepted)
   {
      SetStatus(StringFormat("Order rejected: %u %s", retcode, Trade.ResultRetcodeDescription()));
      PrintFormat("Order request failed. retcode=%u description=%s entry=%.3f sl=%.3f tp=%.3f",
                  retcode, Trade.ResultRetcodeDescription(), entry, stop_loss, take_profit);
      return FUNNEL_OTHER;
   }

   SetStatus(StringFormat("%s %s stop placed: entry %.3f SL %.3f TP %.3f",
                          SetupTag(setup), signal == SIGNAL_LONG ? "buy" : "sell", entry, stop_loss, take_profit));
   PrintFormat("Protected %s %s stop accepted. order=%I64u volume=%.2f entry=%.3f sl=%.3f tp=%.3f SLdist=%.3f TPdist=%.3f maxSL=%.3f",
               SetupTag(setup), signal == SIGNAL_LONG ? "buy" : "sell", Trade.ResultOrder(), InpFixedLots,
               entry, stop_loss, take_profit, MathAbs(entry - stop_loss), MathAbs(take_profit - entry),
               maximum_stop);
   return FUNNEL_PLACED;
}

//+------------------------------------------------------------------+
//| Margin gate using MT5's live symbol calculation                  |
//+------------------------------------------------------------------+
bool HasSufficientMargin(const SignalDirection signal, const double entry)
{
   ENUM_ORDER_TYPE order_type = (signal == SIGNAL_LONG) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double required_margin = 0.0;
   ResetLastError();
   if(!OrderCalcMargin(order_type, _Symbol, InpFixedLots, entry, required_margin))
   {
      SetStatus(StringFormat("Margin calculation failed: %d", GetLastError()));
      return false;
   }

   double free_margin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(required_margin > free_margin)
   {
      SetStatus(StringFormat("Insufficient free margin: need %.2f, have %.2f",
                             required_margin, free_margin));
      return false;
   }

   double projected_margin = AccountInfoDouble(ACCOUNT_MARGIN) + required_margin;
   double projected_level = (projected_margin > 0.0)
                            ? AccountInfoDouble(ACCOUNT_EQUITY) / projected_margin * 100.0
                            : 999999.0;
   if(projected_level < InpMinimumProjectedMarginLevel)
   {
      SetStatus(StringFormat("Projected margin level %.1f%% below %.1f%% gate",
                             projected_level, InpMinimumProjectedMarginLevel));
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| Find most recent local structural swing                          |
//+------------------------------------------------------------------+
bool FindMostRecentSwingLow(const MqlRates &rates[], double &price)
{
   int maximum_shift = MathMin(InpSwingLookbackBars, ArraySize(rates) - 2);
   for(int shift = 2; shift <= maximum_shift; shift++)
   {
      if(rates[shift].low < rates[shift - 1].low && rates[shift].low <= rates[shift + 1].low)
      {
         price = rates[shift].low;
         return true;
      }
   }
   return false;
}

bool FindMostRecentSwingHigh(const MqlRates &rates[], double &price)
{
   int maximum_shift = MathMin(InpSwingLookbackBars, ArraySize(rates) - 2);
   for(int shift = 2; shift <= maximum_shift; shift++)
   {
      if(rates[shift].high > rates[shift - 1].high && rates[shift].high >= rates[shift + 1].high)
      {
         price = rates[shift].high;
         return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Abnormal volatility requires three normal bars to clear          |
//+------------------------------------------------------------------+
bool IsVolatilityShock(const MqlRates &rates[], const double &atr[])
{
   int bars_to_check = MathMin(InpNormalBarsAfterShock, ArraySize(atr) - InpAtrMedianLookbackBars - 2);
   if(bars_to_check < InpNormalBarsAfterShock)
      return true;

   for(int shift = 1; shift <= bars_to_check; shift++)
   {
      double median_atr = MedianSlice(atr, shift + 1, InpAtrMedianLookbackBars);
      if(median_atr <= 0.0)
         return true;

      bool shock_candle = TrueRange(rates, shift) >= InpShockCandleAtrMultiple * atr[shift];
      bool shock_regime = atr[shift] >= InpShockAtrMedianMultiple * median_atr;
      if(shock_candle || shock_regime)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Reject extended or one-way M5 price action                       |
//+------------------------------------------------------------------+
bool IsRunawayMarket(const MqlRates &rates[], const double &ema[], const double &atr[])
{
   if(MathAbs(rates[1].close - ema[1]) > InpRunawayDistanceAtr * atr[1])
      return true;

   bool all_bullish = true;
   bool all_bearish = true;
   bool all_large   = true;
   for(int shift = 1; shift <= 3; shift++)
   {
      all_bullish = all_bullish && (rates[shift].close > rates[shift].open);
      all_bearish = all_bearish && (rates[shift].close < rates[shift].open);
      all_large   = all_large && (MathAbs(rates[shift].close - rates[shift].open) >=
                                  InpRunawayBodyAtr * atr[shift]);
   }
   return all_large && (all_bullish || all_bearish);
}

//+------------------------------------------------------------------+
//| High-impact USD economic-calendar guard                          |
//+------------------------------------------------------------------+
bool IsHighImpactUsdNewsWindow()
{
   if(!InpUseNewsFilter)
      return false;

   datetime now = TimeTradeServer();
   if(now <= 0)
      now = TimeCurrent();

   MqlCalendarValue values[];
   ResetLastError();
   int count = CalendarValueHistory(values,
                                    now - InpNewsMinutesAfter * 60,
                                    now + InpNewsMinutesBefore * 60,
                                    NULL,
                                    "USD");
   if(count < 0)
   {
      int error_code = GetLastError();
      PrintFormat("Economic calendar query failed with error %d; fail-closed=%s.",
                  error_code, InpNewsFailClosed ? "true" : "false");
      return InpNewsFailClosed;
   }

   for(int index = 0; index < count; index++)
   {
      MqlCalendarEvent event;
      ResetLastError();
      if(!CalendarEventById(values[index].event_id, event))
      {
         if(InpNewsFailClosed)
         {
            PrintFormat("Calendar event lookup failed with error %d; blocking entry.", GetLastError());
            return true;
         }
         continue;
      }

      if(event.importance == CALENDAR_IMPORTANCE_HIGH)
      {
         long seconds_to_event = (long)values[index].time - (long)now;
         if(seconds_to_event >= -(long)InpNewsMinutesAfter * 60 &&
            seconds_to_event <=  (long)InpNewsMinutesBefore * 60)
         {
            PrintFormat("Entry blocked around high-impact USD event: %s at %s server time.",
                        event.name, TimeToString(values[index].time, TIME_DATE | TIME_MINUTES));
            return true;
         }
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Session filter                                                   |
//| 24/5: any bar Monday-Friday in broker server time (the broker's  |
//| own session table decides when the market is actually open).     |
//| UTC window / London+NY: legacy v1.1 / v1.0 behaviour.            |
//+------------------------------------------------------------------+
bool IsEntrySession()
{
   if(InpSessionMode == SESSION_24X5)
   {
      MqlDateTime server_parts;
      TimeToStruct(ServerNow(), server_parts);
      return (server_parts.day_of_week != 0 && server_parts.day_of_week != 6);
   }

   datetime utc = CurrentUtcTime();
   MqlDateTime utc_parts;
   TimeToStruct(utc, utc_parts);
   if(utc_parts.day_of_week == 0 || utc_parts.day_of_week == 6)
      return false;

   if(InpSessionMode == SESSION_UTC_WINDOW)
      return IsHourWindow(utc, InpUtcSessionStartHour, InpUtcSessionEndHour);

   int london_offset = IsUkDaylightSaving(utc) ? 1 : 0;
   int new_york_offset = IsUsDaylightSaving(utc) ? -4 : -5;

   datetime london_local = utc + london_offset * 3600;
   datetime new_york_local = utc + new_york_offset * 3600;
   return IsHourWindow(london_local, InpLondonStartHour, InpLondonEndHour) ||
          IsHourWindow(new_york_local, InpNewYorkStartHour, InpNewYorkEndHour);
}

string SessionBlockDescription()
{
   if(InpSessionMode == SESSION_UTC_WINDOW)
      return StringFormat("Outside %02d:00-%02d:00 UTC entry window",
                          InpUtcSessionStartHour, InpUtcSessionEndHour);
   if(InpSessionMode == SESSION_LONDON_NY)
      return "Outside London/New York entry windows";
   return "Weekend (server time)";
}

//+------------------------------------------------------------------+
//| UTC session tag used in order comments and the run report        |
//+------------------------------------------------------------------+
string SessionTag()
{
   MqlDateTime utc_parts;
   TimeToStruct(CurrentUtcTime(), utc_parts);
   if(utc_parts.hour >= 7 && utc_parts.hour < 12)
      return "LON";
   if(utc_parts.hour >= 12 && utc_parts.hour < 17)
      return "NY";
   if(utc_parts.hour >= 17 && utc_parts.hour < 21)
      return "LATE";
   return "ASIA";
}

datetime ServerNow()
{
   datetime now = TimeTradeServer();
   if(now <= 0)
      now = TimeCurrent();
   return now;
}

//+------------------------------------------------------------------+
//| Market-close protection                                          |
//| No new entry (and no live pending order) in the last N minutes   |
//| of a broker trade session: avoids rollover spread spikes and     |
//| opening a position just before the weekend gap. Uses the symbol  |
//| session table; if it is empty, server midnight is assumed.       |
//+------------------------------------------------------------------+
bool IsNearMarketClose(string &reason)
{
   // No new entries while (or just before) positions are being closed for the weekend.
   int weekly_limit = MathMax(InpNoEntryMinutesBeforeWeeklyClose, InpCloseMinutesBeforeWeeklyClose);
   if(InpNoEntryMinutesBeforeDailyClose <= 0 && weekly_limit <= 0)
      return false;

   bool weekly_close = false;
   long seconds_left = SecondsToSessionClose(ServerNow(), weekly_close);
   if(seconds_left < 0)
      return false;

   int limit_minutes = weekly_close ? weekly_limit : InpNoEntryMinutesBeforeDailyClose;
   if(limit_minutes <= 0 || seconds_left > (long)limit_minutes * 60)
      return false;

   reason = StringFormat("%s market close in %d min; no new entries in the last %d min",
                         weekly_close ? "Weekly" : "Daily", (int)(seconds_left / 60), limit_minutes);
   return true;
}

long SecondsToSessionClose(const datetime server_time, bool &weekly_close)
{
   weekly_close = false;
   MqlDateTime parts;
   TimeToStruct(server_time, parts);
   long now_seconds = (long)parts.hour * 3600 + (long)parts.min * 60 + (long)parts.sec;
   int day = parts.day_of_week;

   long session_end = 0;
   if(!FindSessionEnd(day, now_seconds, session_end))
   {
      weekly_close = (parts.day_of_week == 5);
      return 86400 - now_seconds;
   }

   long seconds_left = session_end - now_seconds;
   // Follow sessions that run through midnight into the next day without a break.
   for(int hops = 0; hops < 7 && session_end >= 86400; hops++)
   {
      int next_day = (day + 1) % 7;
      long next_end = 0;
      if(!FindSessionEnd(next_day, 0, next_end))
         break;
      day = next_day;
      seconds_left += next_end;
      session_end = next_end;
   }

   weekly_close = !DayHasTradeSession((day + 1) % 7);
   return seconds_left;
}

bool FindSessionEnd(const int day_of_week, const long second_of_day, long &session_end)
{
   datetime from_time = 0;
   datetime to_time = 0;
   for(int index = 0; index < 16; index++)
   {
      if(!SymbolInfoSessionTrade(_Symbol, (ENUM_DAY_OF_WEEK)day_of_week, (uint)index, from_time, to_time))
         return false;
      long from_seconds = (long)from_time % 86400;
      long to_seconds = (long)to_time % 86400;
      if(to_seconds <= from_seconds)
         to_seconds = 86400;
      if(second_of_day >= from_seconds && second_of_day < to_seconds)
      {
         session_end = to_seconds;
         return true;
      }
   }
   return false;
}

bool DayHasTradeSession(const int day_of_week)
{
   datetime from_time = 0;
   datetime to_time = 0;
   return SymbolInfoSessionTrade(_Symbol, (ENUM_DAY_OF_WEEK)day_of_week, 0, from_time, to_time);
}

void LogTradeSessions()
{
   string names[7] = {"Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"};
   string text = "";
   for(int day = 0; day < 7; day++)
   {
      datetime from_time = 0;
      datetime to_time = 0;
      string day_text = "";
      for(int index = 0; index < 16; index++)
      {
         if(!SymbolInfoSessionTrade(_Symbol, (ENUM_DAY_OF_WEEK)day, (uint)index, from_time, to_time))
            break;
         long from_seconds = (long)from_time % 86400;
         long to_seconds = (long)to_time % 86400;
         if(to_seconds <= from_seconds)
            to_seconds = 86400;
         day_text += StringFormat("%s%02d:%02d-%02d:%02d", day_text == "" ? "" : ",",
                                  (int)(from_seconds / 3600), (int)((from_seconds % 3600) / 60),
                                  (int)(to_seconds / 3600), (int)((to_seconds % 3600) / 60));
      }
      text += StringFormat("%s %s; ", names[day], day_text == "" ? "closed" : day_text);
   }
   PrintFormat("AegisGold trade sessions (server time): %s", text);
}

bool IsHourWindow(const datetime local_time, const int start_hour, const int end_hour)
{
   MqlDateTime parts;
   TimeToStruct(local_time, parts);
   int minute_of_day = parts.hour * 60 + parts.min;
   return minute_of_day >= start_hour * 60 && minute_of_day < end_hour * 60;
}

datetime CurrentUtcTime()
{
   if(MQLInfoInteger(MQL_TESTER))
   {
      datetime server_time = TimeCurrent();
      if(InpTesterUsesPepperstoneServer)
      {
         datetime approximate_utc = server_time - 2 * 3600;
         int server_offset = IsUsDaylightSaving(approximate_utc) ? 3 : 2;
         return server_time - server_offset * 3600;
      }
      return server_time - InpFallbackServerUtcOffsetHours * 3600;
   }

   datetime utc = TimeGMT();
   if(utc > 0)
      return utc;
   return TimeCurrent() - InpFallbackServerUtcOffsetHours * 3600;
}

bool IsUkDaylightSaving(const datetime utc)
{
   MqlDateTime parts;
   TimeToStruct(utc, parts);
   int start_day = LastSunday(parts.year, 3);
   int end_day   = LastSunday(parts.year, 10);
   datetime start_time = MakeDateTime(parts.year, 3, start_day, 1, 0);
   datetime end_time   = MakeDateTime(parts.year, 10, end_day, 1, 0);
   return utc >= start_time && utc < end_time;
}

bool IsUsDaylightSaving(const datetime utc)
{
   MqlDateTime parts;
   TimeToStruct(utc, parts);
   int start_day = NthSunday(parts.year, 3, 2);
   int end_day   = NthSunday(parts.year, 11, 1);
   datetime start_time = MakeDateTime(parts.year, 3, start_day, 7, 0);
   datetime end_time   = MakeDateTime(parts.year, 11, end_day, 6, 0);
   return utc >= start_time && utc < end_time;
}

int LastSunday(const int year, const int month)
{
   int last_day = DaysInMonth(year, month);
   MqlDateTime parts;
   TimeToStruct(MakeDateTime(year, month, last_day, 12, 0), parts);
   return last_day - parts.day_of_week;
}

int NthSunday(const int year, const int month, const int occurrence)
{
   MqlDateTime parts;
   TimeToStruct(MakeDateTime(year, month, 1, 12, 0), parts);
   int first_sunday = 1 + ((7 - parts.day_of_week) % 7);
   return first_sunday + (occurrence - 1) * 7;
}

int DaysInMonth(const int year, const int month)
{
   if(month == 2)
   {
      bool leap = ((year % 4 == 0 && year % 100 != 0) || year % 400 == 0);
      return leap ? 29 : 28;
   }
   if(month == 4 || month == 6 || month == 9 || month == 11)
      return 30;
   return 31;
}

datetime MakeDateTime(const int year, const int month, const int day,
                      const int hour, const int minute)
{
   MqlDateTime parts = {0};
   parts.year = year;
   parts.mon  = month;
   parts.day  = day;
   parts.hour = hour;
   parts.min  = minute;
   return StructToTime(parts);
}

//+------------------------------------------------------------------+
//| Daily history accounting                                         |
//+------------------------------------------------------------------+
void RefreshDailyStatsIfNeeded()
{
   datetime now = TimeTradeServer();
   if(now <= 0)
      now = TimeCurrent();
   datetime today = StartOfDay(now);
   if(today != g_dailyStart)
      RefreshDailyStats();
}

void RefreshDailyStats()
{
   datetime now = TimeTradeServer();
   if(now <= 0)
      now = TimeCurrent();
   datetime day_start = StartOfDay(now);

   g_dailyStart   = day_start;
   g_dailyEntries = 0;
   g_dailyLosses  = 0;
   g_dailyConsecLosses = 0;
   g_dailyNet     = 0.0;

   if(!HistorySelect(day_start, now))
   {
      g_dailyHalted = true;
      SetStatus("History unavailable; daily risk state fails closed");
      return;
   }

   ulong closed_position_ids[];
   int deals_total = HistoryDealsTotal();
   for(int index = 0; index < deals_total; index++)
   {
      ulong deal_ticket = HistoryDealGetTicket(index);
      if(deal_ticket == 0)
         continue;
      if((ulong)HistoryDealGetInteger(deal_ticket, DEAL_MAGIC) != InpMagicNumber)
         continue;
      if(HistoryDealGetString(deal_ticket, DEAL_SYMBOL) != _Symbol)
         continue;

      ENUM_DEAL_ENTRY entry_type = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal_ticket, DEAL_ENTRY);
      if(entry_type == DEAL_ENTRY_IN || entry_type == DEAL_ENTRY_INOUT)
         g_dailyEntries++;

      g_dailyNet += DealNetResult(deal_ticket);

      if(entry_type == DEAL_ENTRY_OUT || entry_type == DEAL_ENTRY_OUT_BY || entry_type == DEAL_ENTRY_INOUT)
      {
         ulong position_id = (ulong)HistoryDealGetInteger(deal_ticket, DEAL_POSITION_ID);
         if(!ContainsUlong(closed_position_ids, position_id))
         {
            int size = ArraySize(closed_position_ids);
            ArrayResize(closed_position_ids, size + 1);
            closed_position_ids[size] = position_id;
         }
      }
   }

   int      current_streak = 0;
   bool     loss_halt      = false;
   datetime cooldown_until = 0;
   int      cooldowns      = 0;
   for(int position_index = 0; position_index < ArraySize(closed_position_ids); position_index++)
   {
      double   position_net = 0.0;
      bool     has_exit     = false;
      datetime exit_time    = 0;
      for(int deal_index = 0; deal_index < deals_total; deal_index++)
      {
         ulong deal_ticket = HistoryDealGetTicket(deal_index);
         if(deal_ticket == 0 ||
            (ulong)HistoryDealGetInteger(deal_ticket, DEAL_MAGIC) != InpMagicNumber ||
            HistoryDealGetString(deal_ticket, DEAL_SYMBOL) != _Symbol ||
            (ulong)HistoryDealGetInteger(deal_ticket, DEAL_POSITION_ID) != closed_position_ids[position_index])
            continue;

         position_net += DealNetResult(deal_ticket);
         ENUM_DEAL_ENTRY entry_type = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal_ticket, DEAL_ENTRY);
         if(entry_type == DEAL_ENTRY_OUT || entry_type == DEAL_ENTRY_OUT_BY || entry_type == DEAL_ENTRY_INOUT)
         {
            has_exit = true;
            datetime deal_time = (datetime)HistoryDealGetInteger(deal_ticket, DEAL_TIME);
            if(deal_time > exit_time)
               exit_time = deal_time;
         }
      }
      // closed_position_ids follows the order of each position's exit deal (history deals are
      // time-ordered), so the running streak follows the order in which positions closed.
      if(!has_exit)
         continue;
      if(position_net >= 0.0)
      {
         current_streak = 0;
         continue;
      }

      g_dailyLosses++;
      current_streak++;
      if(InpDailyLossCountMode == LOSS_COUNT_CONSECUTIVE && current_streak >= InpMaximumDailyLosses)
      {
         if(InpCooldownHoursAfterHalt > 0)
         {
            // Pause instead of halting; the streak restarts after each cooldown.
            cooldown_until = exit_time + InpCooldownHoursAfterHalt * 3600;
            cooldowns++;
            current_streak = 0;
         }
         else
            loss_halt = true;   // v1.2 behaviour: halted until the next server day
      }
   }

   if(InpDailyLossCountMode == LOSS_COUNT_TOTAL && g_dailyLosses >= InpMaximumDailyLosses)
      loss_halt = true;

   // Counters reset at server midnight, so a cooldown never runs past the day rollover.
   if(cooldown_until > g_cooldownUntil)
      g_eventCooldowns++;
   g_cooldownUntil     = cooldown_until;
   g_dailyCooldowns    = cooldowns;
   g_dailyConsecLosses = current_streak;
   g_lossHalt          = loss_halt;

   g_dailyHalted = (g_dailyEntries >= InpMaximumDailyEntries ||
                    g_lossHalt ||
                    g_dailyNet <= -InpMaximumDailyDrawdown);
}

bool IsInCooldown()
{
   return (g_cooldownUntil > 0 && ServerNow() < g_cooldownUntil);
}

string CooldownDescription()
{
   return StringFormat("Cooldown after %d consecutive losses until %s server time",
                       InpMaximumDailyLosses, TimeToString(g_cooldownUntil, TIME_MINUTES));
}

double DealNetResult(const ulong deal_ticket)
{
   return HistoryDealGetDouble(deal_ticket, DEAL_PROFIT) +
          HistoryDealGetDouble(deal_ticket, DEAL_COMMISSION) +
          HistoryDealGetDouble(deal_ticket, DEAL_SWAP) +
          HistoryDealGetDouble(deal_ticket, DEAL_FEE);
}

bool ContainsUlong(const ulong &values[], const ulong value)
{
   for(int index = 0; index < ArraySize(values); index++)
      if(values[index] == value)
         return true;
   return false;
}

datetime StartOfDay(const datetime value)
{
   MqlDateTime parts;
   TimeToStruct(value, parts);
   parts.hour = 0;
   parts.min  = 0;
   parts.sec  = 0;
   return StructToTime(parts);
}

string DailyHaltDescription()
{
   if(g_lossHalt)
      return (InpDailyLossCountMode == LOSS_COUNT_CONSECUTIVE)
             ? StringFormat("Daily halt: %d consecutive losses", InpMaximumDailyLosses)
             : StringFormat("Daily halt: %d losses in total", g_dailyLosses);
   if(g_dailyNet <= -InpMaximumDailyDrawdown)
      return StringFormat("Daily halt: net P/L %.2f", g_dailyNet);
   if(g_dailyEntries >= InpMaximumDailyEntries)
      return StringFormat("Daily halt: %d entries", g_dailyEntries);
   return "Daily risk halt";
}

//+------------------------------------------------------------------+
//| Exposure and pending-order helpers                               |
//+------------------------------------------------------------------+
//| Count this EA's positions on the symbol and their direction      |
//| (+1 long, -1 short, 0 none or mixed). Manual or other-EA          |
//| positions and orders on the symbol are reported as foreign.       |
void ScanSymbolExposure(int &own_positions, int &own_direction, bool &foreign_exposure)
{
   own_positions    = 0;
   own_direction    = 0;
   foreign_exposure = false;
   bool has_long  = false;
   bool has_short = false;

   for(int index = PositionsTotal() - 1; index >= 0; index--)
   {
      ulong ticket = PositionGetTicket(index);
      if(ticket == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
      {
         foreign_exposure = true;
         continue;
      }
      own_positions++;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
         has_long = true;
      else
         has_short = true;
   }

   for(int index = OrdersTotal() - 1; index >= 0; index--)
   {
      ulong ticket = OrderGetTicket(index);
      if(ticket > 0 && OrderGetString(ORDER_SYMBOL) == _Symbol &&
         (ulong)OrderGetInteger(ORDER_MAGIC) != InpMagicNumber)
         foreign_exposure = true;
   }

   if(has_long && !has_short)
      own_direction = 1;
   else if(has_short && !has_long)
      own_direction = -1;
}

//+------------------------------------------------------------------+
//| Today's net if the new order and every open EA position hit      |
//| their stops (account currency). Fails if a stop is missing.      |
//+------------------------------------------------------------------+
bool WorstCaseDailyNet(const SignalDirection signal, const double entry, const double stop_loss,
                       double &worst_case)
{
   worst_case = g_dailyNet;

   double new_loss = 0.0;
   ENUM_ORDER_TYPE new_type = (signal == SIGNAL_LONG) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   if(!OrderCalcProfit(new_type, _Symbol, InpFixedLots, entry, stop_loss, new_loss))
      return false;
   worst_case += MathMin(0.0, new_loss);

   for(int index = PositionsTotal() - 1; index >= 0; index--)
   {
      ulong ticket = PositionGetTicket(index);
      if(ticket == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol ||
         (ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      double position_stop = PositionGetDouble(POSITION_SL);
      if(position_stop <= 0.0)
         return false;

      ENUM_ORDER_TYPE position_type =
         ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      double position_loss = 0.0;
      if(!OrderCalcProfit(position_type, _Symbol, PositionGetDouble(POSITION_VOLUME),
                          PositionGetDouble(POSITION_PRICE_OPEN), position_stop, position_loss))
         return false;
      worst_case += MathMin(0.0, position_loss) + MathMin(0.0, PositionGetDouble(POSITION_SWAP));
   }
   return true;
}

//+------------------------------------------------------------------+
//| Position management, at most once per second:                    |
//| 1. close every EA position shortly before the weekly close;      |
//| 2. stale-trade release after InpStaleTradeBars M5 bars.          |
//+------------------------------------------------------------------+
void ManageOpenPositions()
{
   if(PositionsTotal() == 0 || (InpCloseMinutesBeforeWeeklyClose <= 0 && InpStaleTradeBars <= 0))
      return;

   datetime now = TimeCurrent();
   if(now == g_lastManageTime || now < g_nextCloseAttempt)
      return;
   g_lastManageTime = now;

   bool flatten = WeeklyFlattenDue();
   for(int index = PositionsTotal() - 1; index >= 0; index--)
   {
      ulong ticket = PositionGetTicket(index);
      if(ticket == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol ||
         (ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      if(flatten)
      {
         if(ClosePositionWithReason(ticket, "weekly-close protection"))
            g_eventWeeklyCloses++;
         continue;
      }
      ApplyStaleTradeRule(ticket, now);
   }
}

bool WeeklyFlattenDue()
{
   if(InpCloseMinutesBeforeWeeklyClose <= 0)
      return false;

   datetime server_time = ServerNow();
   bool weekly_close = false;
   long seconds_left = SecondsToSessionClose(server_time, weekly_close);
   if(!weekly_close || seconds_left < 0 || seconds_left > (long)InpCloseMinutesBeforeWeeklyClose * 60)
      return false;

   // With a published session table, act only while the market is open (orders fail otherwise).
   MqlDateTime parts;
   TimeToStruct(server_time, parts);
   long now_seconds = (long)parts.hour * 3600 + (long)parts.min * 60 + (long)parts.sec;
   long session_end = 0;
   if(DayHasTradeSession(parts.day_of_week) && !FindSessionEnd(parts.day_of_week, now_seconds, session_end))
      return false;
   return true;
}

void ApplyStaleTradeRule(const ulong ticket, const datetime now)
{
   if(InpStaleTradeBars <= 0 || !PositionSelectByTicket(ticket))
      return;

   long held_seconds = (long)now - (long)PositionGetInteger(POSITION_TIME);
   if(held_seconds < (long)InpStaleTradeBars * PeriodSeconds(PERIOD_M5))
      return;

   bool   is_long     = ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
   double open_price  = PositionGetDouble(POSITION_PRICE_OPEN);
   double stop_loss   = PositionGetDouble(POSITION_SL);
   double take_profit = PositionGetDouble(POSITION_TP);
   double tick_size   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double breakeven   = is_long ? RoundUpToTick(open_price + InpBreakevenOffsetPrice)
                                : RoundDownToTick(open_price - InpBreakevenOffsetPrice);

   // Stop already at breakeven or better: nothing left to do for this position.
   if(stop_loss > 0.0 && (is_long ? stop_loss >= breakeven - tick_size * 0.5
                                  : stop_loss <= breakeven + tick_size * 0.5))
      return;

   if(InpStaleTradeAction != STALE_CLOSE)
   {
      MqlTick tick;
      if(!SymbolInfoTick(_Symbol, tick))
         return;
      double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      double level_points = MathMax((double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL),
                                    (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL));
      double minimum_gap = MathMax(level_points * point, tick_size);
      bool room = is_long ? (tick.bid - breakeven >= minimum_gap) : (breakeven - tick.ask >= minimum_gap);
      if(room)
      {
         if(Trade.PositionModify(ticket, breakeven, take_profit))
         {
            g_eventBreakevens++;
            PrintFormat("Stale trade %I64u after %d M5 bars: stop moved to breakeven %.3f.",
                        ticket, InpStaleTradeBars, breakeven);
         }
         else
         {
            PrintFormat("Breakeven move failed for %I64u: %u %s; retrying in 60 s.",
                        ticket, Trade.ResultRetcode(), Trade.ResultRetcodeDescription());
            g_nextCloseAttempt = now + 60;
         }
         return;
      }
      if(InpStaleTradeAction == STALE_BREAKEVEN_ONLY)
         return;
   }

   if(ClosePositionWithReason(ticket, StringFormat("stale after %d M5 bars", InpStaleTradeBars)))
      g_eventStaleCloses++;
}

bool ClosePositionWithReason(const ulong ticket, const string reason)
{
   bool request_ok = Trade.PositionClose(ticket, (ulong)InpMaximumDeviationPoints);
   uint retcode = Trade.ResultRetcode();
   if(!request_ok || (retcode != TRADE_RETCODE_DONE && retcode != TRADE_RETCODE_DONE_PARTIAL &&
                      retcode != TRADE_RETCODE_PLACED))
   {
      PrintFormat("Failed to close position %I64u (%s): %u %s; retrying in 60 s.",
                  ticket, reason, retcode, Trade.ResultRetcodeDescription());
      g_nextCloseAttempt = TimeCurrent() + 60;
      return false;
   }
   PrintFormat("Position %I64u closed at market: %s.", ticket, reason);
   return true;
}

bool HasAnyPendingOrderForSymbol()
{
   for(int index = 0; index < OrdersTotal(); index++)
   {
      ulong ticket = OrderGetTicket(index);
      if(ticket > 0 && OrderGetString(ORDER_SYMBOL) == _Symbol)
         return true;
   }
   return false;
}

void CancelExpiredOwnPendingOrders()
{
   datetime now = TimeTradeServer();
   if(now <= 0)
      now = TimeCurrent();
   long maximum_age = (long)InpPendingExpiryBars * PeriodSeconds(PERIOD_M5);

   for(int index = OrdersTotal() - 1; index >= 0; index--)
   {
      ulong ticket = OrderGetTicket(index);

      if(ticket == 0 || OrderGetString(ORDER_SYMBOL) != _Symbol ||
         (ulong)OrderGetInteger(ORDER_MAGIC) != InpMagicNumber)
         continue;

      ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(type != ORDER_TYPE_BUY_STOP && type != ORDER_TYPE_SELL_STOP)
         continue;

      datetime setup_time = (datetime)OrderGetInteger(ORDER_TIME_SETUP);
      if(now - setup_time >= maximum_age)
      {
         if(Trade.OrderDelete(ticket))
            PrintFormat("Expired pending order %I64u deleted after %d M5 bars.",
                        ticket, InpPendingExpiryBars);
         else
            PrintFormat("Failed to delete expired order %I64u: %u %s",
                        ticket, Trade.ResultRetcode(), Trade.ResultRetcodeDescription());
      }
   }
}

void CancelOwnPendingOrders(const string reason)
{
   for(int index = OrdersTotal() - 1; index >= 0; index--)
   {
      ulong ticket = OrderGetTicket(index);
      if(ticket == 0 || OrderGetString(ORDER_SYMBOL) != _Symbol ||
         (ulong)OrderGetInteger(ORDER_MAGIC) != InpMagicNumber)
         continue;

      ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(type != ORDER_TYPE_BUY_STOP && type != ORDER_TYPE_SELL_STOP)
         continue;

      if(Trade.OrderDelete(ticket))
         PrintFormat("Pending order %I64u deleted because of %s.", ticket, reason);
   }
}

//+------------------------------------------------------------------+
//| Generic math and price helpers                                   |
//+------------------------------------------------------------------+
double TrueRange(const MqlRates &rates[], const int shift)
{
   double high_low = rates[shift].high - rates[shift].low;
   double high_previous = MathAbs(rates[shift].high - rates[shift + 1].close);
   double low_previous  = MathAbs(rates[shift].low - rates[shift + 1].close);
   return MathMax(high_low, MathMax(high_previous, low_previous));
}

double MedianSlice(const double &values[], const int start, const int count)
{
   if(start < 0 || count <= 0 || start + count > ArraySize(values))
      return 0.0;

   double sample[];
   ArrayResize(sample, count);
   for(int index = 0; index < count; index++)
      sample[index] = values[start + index];
   ArraySort(sample);

   if((count % 2) == 1)
      return sample[count / 2];
   return (sample[count / 2 - 1] + sample[count / 2]) * 0.5;
}

double Clamp(const double value, const double minimum, const double maximum)
{
   return MathMax(minimum, MathMin(maximum, value));
}

double RoundUpToTick(const double price)
{
   double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   if(tick_size <= 0.0)
      return NormalizeDouble(price, digits);
   return NormalizeDouble(MathCeil(price / tick_size - 1e-10) * tick_size, digits);
}

double RoundDownToTick(const double price)
{
   double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   if(tick_size <= 0.0)
      return NormalizeDouble(price, digits);
   return NormalizeDouble(MathFloor(price / tick_size + 1e-10) * tick_size, digits);
}

//+------------------------------------------------------------------+
//| Lifecycle, status and diagnostics                                |
//+------------------------------------------------------------------+
bool IsNewM5Bar()
{
   datetime current_bar = iTime(_Symbol, PERIOD_M5, 0);
   if(current_bar <= 0 || current_bar == g_lastM5BarTime)
      return false;
   g_lastM5BarTime = current_bar;
   return true;
}

void ReleaseIndicators()
{
   if(g_m5EmaHandle != INVALID_HANDLE)
      IndicatorRelease(g_m5EmaHandle);
   if(g_m5AtrHandle != INVALID_HANDLE)
      IndicatorRelease(g_m5AtrHandle);
   if(g_m5RsiHandle != INVALID_HANDLE)
      IndicatorRelease(g_m5RsiHandle);
   if(g_m15FastEmaHandle != INVALID_HANDLE)
      IndicatorRelease(g_m15FastEmaHandle);
   if(g_m15SlowEmaHandle != INVALID_HANDLE)
      IndicatorRelease(g_m15SlowEmaHandle);
   if(g_m15AtrHandle != INVALID_HANDLE)
      IndicatorRelease(g_m15AtrHandle);

   g_m5EmaHandle = g_m5AtrHandle = g_m5RsiHandle = INVALID_HANDLE;
   g_m15FastEmaHandle = g_m15SlowEmaHandle = g_m15AtrHandle = INVALID_HANDLE;
}

void SetStatus(const string status)
{
   if(status != g_status)
   {
      g_status = status;
      Print("AegisGold: ", status);
   }
}

void UpdateDashboard()
{
   MqlTick tick;
   double spread = 0.0;
   if(SymbolInfoTick(_Symbol, tick))
      spread = tick.ask - tick.bid;

   int  own_positions    = 0;
   int  own_direction    = 0;
   bool foreign_exposure = false;
   ScanSymbolExposure(own_positions, own_direction, foreign_exposure);

   string state = "active";
   if(g_dailyHalted)
      state = "HALTED for the day";
   else if(IsInCooldown())
      state = "COOLDOWN until " + TimeToString(g_cooldownUntil, TIME_MINUTES);

   string dashboard = StringFormat(
      "Aegis Gold Trend-Pullback v1.40 (two-tier + range mode, 24/5)\n"
      "Symbol: %s | Lots: %.2f | Spread: %.3f (max %.2f) | EA positions: %d/%d\n"
      "Today: entries %d/%d | losses %d, streak %d/%d, cooldowns %d | net %.2f %s\n"
      "Regime: %s | Last setup: %s | State: %s\n"
      "Status: %s",
      _Symbol, InpFixedLots, spread, InpMaximumSpreadPrice, own_positions, g_maxPositions,
      g_dailyEntries, InpMaximumDailyEntries,
      g_dailyLosses, g_dailyConsecLosses, InpMaximumDailyLosses, g_dailyCooldowns,
      g_dailyNet, AccountInfoString(ACCOUNT_CURRENCY),
      g_regimeText, g_lastSetup > 0 ? SetupTag(g_lastSetup) : "none", state, g_status);
   Comment(dashboard);
}

//+------------------------------------------------------------------+
//| End-of-run report (Strategy Tester journal / Experts log):       |
//| setup funnel and position-management events for this run, then   |
//| this run's closed trades split by setup type, session,           |
//| after-cooldown entries, additional position, exit type and       |
//| holding time.                                                    |
//+------------------------------------------------------------------+
void PrintRunSummary()
{
   if(g_runStart <= 0)
      return;

   int setups = g_funnel[FUNNEL_SIGNAL_T1] + g_funnel[FUNNEL_SIGNAL_T2] + g_funnel[FUNNEL_SIGNAL_RANGE];
   PrintFormat("AegisGold setup funnel: %d qualified setups (T1 %d, T2 %d, range %d), orders placed %d (%d as an additional position). "
               "Blocked by: daily halt %d, cooldown %d, open position/order %d, session %d, market close %d, "
               "spread %d, shock %d, runaway %d, news %d, chase %d, no swing %d, stop too wide %d, "
               "worst-case daily loss %d, margin %d, other %d",
               setups, g_funnel[FUNNEL_SIGNAL_T1], g_funnel[FUNNEL_SIGNAL_T2], g_funnel[FUNNEL_SIGNAL_RANGE],
               g_funnel[FUNNEL_PLACED],
               g_placedAdditional, g_funnel[FUNNEL_HALT], g_funnel[FUNNEL_COOLDOWN], g_funnel[FUNNEL_EXPOSURE],
               g_funnel[FUNNEL_SESSION], g_funnel[FUNNEL_MARKET_CLOSE], g_funnel[FUNNEL_SPREAD],
               g_funnel[FUNNEL_SHOCK], g_funnel[FUNNEL_RUNAWAY], g_funnel[FUNNEL_NEWS], g_funnel[FUNNEL_CHASE],
               g_funnel[FUNNEL_NO_SWING], g_funnel[FUNNEL_STOP_TOO_WIDE], g_funnel[FUNNEL_RISK_BUDGET],
               g_funnel[FUNNEL_MARGIN], g_funnel[FUNNEL_OTHER]);
   PrintFormat("AegisGold position management: %d cooldowns, %d weekly-close exits, %d stale-trade closes, "
               "%d breakeven moves",
               g_eventCooldowns, g_eventWeeklyCloses, g_eventStaleCloses, g_eventBreakevens);

   datetime now = TimeCurrent();
   if(!HistorySelect(g_runStart, now + 60))
      return;

   // Aggregate every deal of this EA by position ID.
   ulong    position_ids[];
   double   position_net[];
   ulong    entry_orders[];
   bool     position_closed[];
   datetime entry_times[];
   datetime exit_times[];
   int      exit_types[];   // 0 other, 1 stop loss, 2 take profit, 3 closed by the EA
   int deals_total = HistoryDealsTotal();
   for(int index = 0; index < deals_total; index++)
   {
      ulong deal_ticket = HistoryDealGetTicket(index);
      if(deal_ticket == 0 ||
         (ulong)HistoryDealGetInteger(deal_ticket, DEAL_MAGIC) != InpMagicNumber ||
         HistoryDealGetString(deal_ticket, DEAL_SYMBOL) != _Symbol)
         continue;

      ulong position_id = (ulong)HistoryDealGetInteger(deal_ticket, DEAL_POSITION_ID);
      int slot = -1;
      for(int search = 0; search < ArraySize(position_ids); search++)
      {
         if(position_ids[search] == position_id)
         {
            slot = search;
            break;
         }
      }
      if(slot < 0)
      {
         slot = ArraySize(position_ids);
         ArrayResize(position_ids, slot + 1);
         ArrayResize(position_net, slot + 1);
         ArrayResize(entry_orders, slot + 1);
         ArrayResize(position_closed, slot + 1);
         ArrayResize(entry_times, slot + 1);
         ArrayResize(exit_times, slot + 1);
         ArrayResize(exit_types, slot + 1);
         position_ids[slot]    = position_id;
         position_net[slot]    = 0.0;
         entry_orders[slot]    = 0;
         position_closed[slot] = false;
         entry_times[slot]     = 0;
         exit_times[slot]      = 0;
         exit_types[slot]      = 0;
      }

      position_net[slot] += DealNetResult(deal_ticket);
      datetime deal_time = (datetime)HistoryDealGetInteger(deal_ticket, DEAL_TIME);
      ENUM_DEAL_ENTRY entry_type = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal_ticket, DEAL_ENTRY);
      if(entry_type == DEAL_ENTRY_IN && entry_orders[slot] == 0)
      {
         entry_orders[slot] = (ulong)HistoryDealGetInteger(deal_ticket, DEAL_ORDER);
         entry_times[slot]  = deal_time;
      }
      if(entry_type == DEAL_ENTRY_OUT || entry_type == DEAL_ENTRY_OUT_BY || entry_type == DEAL_ENTRY_INOUT)
      {
         position_closed[slot] = true;
         exit_times[slot] = deal_time;
         ENUM_DEAL_REASON reason = (ENUM_DEAL_REASON)HistoryDealGetInteger(deal_ticket, DEAL_REASON);
         exit_types[slot] = (reason == DEAL_REASON_SL) ? 1 :
                            ((reason == DEAL_REASON_TP) ? 2 : ((reason == DEAL_REASON_EXPERT) ? 3 : 0));
      }
   }

   // Index 0 = untagged/unknown; setups T1, T2, range; sessions ASIA, LON, NY, LATE.
   string setup_names[4]   = {"untagged", "Tier 1", "Tier 2", "Range"};
   string session_names[5] = {"untagged", "ASIA", "LON", "NY", "LATE"};
   int    tier_trades[4]    = {0, 0, 0, 0};
   int    tier_wins[4]      = {0, 0, 0, 0};
   double tier_net[4]       = {0.0, 0.0, 0.0, 0.0};
   int    cooldown_trades   = 0;
   int    cooldown_wins     = 0;
   double cooldown_net      = 0.0;
   int    session_trades[5] = {0, 0, 0, 0, 0};
   int    session_wins[5]   = {0, 0, 0, 0, 0};
   double session_net[5]    = {0.0, 0.0, 0.0, 0.0, 0.0};
   int    exit_counts[4]    = {0, 0, 0, 0};
   double exit_net[4]       = {0.0, 0.0, 0.0, 0.0};
   int    additional_trades = 0;
   int    additional_wins   = 0;
   double additional_net    = 0.0;
   int    timed_trades      = 0;
   double total_minutes     = 0.0;
   double longest_minutes   = 0.0;
   int    trades = 0;
   int    wins = 0;
   double net_total = 0.0;

   for(int slot = 0; slot < ArraySize(position_ids); slot++)
   {
      if(!position_closed[slot])
         continue;

      string comment = (entry_orders[slot] > 0) ? HistoryOrderGetString(entry_orders[slot], ORDER_COMMENT) : "";
      int tier_index = 0;
      if(StringFind(comment, "-T1") >= 0)
         tier_index = 1;
      else if(StringFind(comment, "-T2") >= 0)
         tier_index = 2;
      else if(StringFind(comment, "-R-") >= 0)
         tier_index = 3;

      int session_index = 0;
      if(StringFind(comment, "-ASIA") >= 0)
         session_index = 1;
      else if(StringFind(comment, "-LON") >= 0)
         session_index = 2;
      else if(StringFind(comment, "-NY") >= 0)
         session_index = 3;
      else if(StringFind(comment, "-LATE") >= 0)
         session_index = 4;

      bool win = (position_net[slot] > 0.0);
      trades++;
      net_total += position_net[slot];
      tier_trades[tier_index]++;
      tier_net[tier_index] += position_net[slot];
      session_trades[session_index]++;
      session_net[session_index] += position_net[slot];
      exit_counts[exit_types[slot]]++;
      exit_net[exit_types[slot]] += position_net[slot];
      if(StringFind(comment, "-C") >= 0)
      {
         cooldown_trades++;
         cooldown_net += position_net[slot];
         if(win)
            cooldown_wins++;
      }
      if(StringFind(comment, "-P2") >= 0)
      {
         additional_trades++;
         additional_net += position_net[slot];
         if(win)
            additional_wins++;
      }
      if(entry_times[slot] > 0 && exit_times[slot] >= entry_times[slot])
      {
         double minutes = (double)((long)exit_times[slot] - (long)entry_times[slot]) / 60.0;
         timed_trades++;
         total_minutes += minutes;
         if(minutes > longest_minutes)
            longest_minutes = minutes;
      }
      if(win)
      {
         wins++;
         tier_wins[tier_index]++;
         session_wins[session_index]++;
      }
   }

   int weekdays = 0;
   if(now > g_runStart)
   {
      for(datetime day = StartOfDay(g_runStart); day <= now; day += 86400)
      {
         MqlDateTime day_parts;
         TimeToStruct(day, day_parts);
         if(day_parts.day_of_week != 0 && day_parts.day_of_week != 6)
            weekdays++;
      }
   }

   PrintFormat("AegisGold results this run (magic %I64u): %d closed trades, %d wins (%.1f%%), net %.2f %s | "
               "%d weekdays = %.2f trades/day",
               InpMagicNumber, trades, wins, trades > 0 ? 100.0 * wins / trades : 0.0, net_total,
               AccountInfoString(ACCOUNT_CURRENCY), weekdays, weekdays > 0 ? (double)trades / weekdays : 0.0);
   for(int tier_index = 1; tier_index <= 3; tier_index++)
      PrintFormat("AegisGold   %s: %d trades, %d wins (%.1f%%), net %.2f", setup_names[tier_index],
                  tier_trades[tier_index], tier_wins[tier_index],
                  tier_trades[tier_index] > 0 ? 100.0 * tier_wins[tier_index] / tier_trades[tier_index] : 0.0,
                  tier_net[tier_index]);
   for(int session_index = 0; session_index < 5; session_index++)
   {
      if(session_trades[session_index] == 0)
         continue;
      PrintFormat("AegisGold   %s: %d trades, %d wins (%.1f%%), net %.2f", session_names[session_index],
                  session_trades[session_index], session_wins[session_index],
                  100.0 * session_wins[session_index] / session_trades[session_index],
                  session_net[session_index]);
   }
   PrintFormat("AegisGold   Entered after a cooldown the same day: %d trades, %d wins (%.1f%%), net %.2f",
               cooldown_trades, cooldown_wins,
               cooldown_trades > 0 ? 100.0 * cooldown_wins / cooldown_trades : 0.0, cooldown_net);
   PrintFormat("AegisGold   Additional positions: %d trades, %d wins (%.1f%%), net %.2f",
               additional_trades, additional_wins,
               additional_trades > 0 ? 100.0 * additional_wins / additional_trades : 0.0, additional_net);
   PrintFormat("AegisGold   Exits: take profit %d (net %.2f), stop loss incl. breakeven %d (net %.2f), "
               "closed by EA %d (net %.2f), other %d (net %.2f)",
               exit_counts[2], exit_net[2], exit_counts[1], exit_net[1], exit_counts[3], exit_net[3],
               exit_counts[0], exit_net[0]);
   PrintFormat("AegisGold   Holding time: average %.0f min, longest %.0f min",
               timed_trades > 0 ? total_minutes / timed_trades : 0.0, longest_minutes);
}

//+------------------------------------------------------------------+
//| Margin capacity, logged once a live price is available           |
//+------------------------------------------------------------------+
void LogMarginCapacity()
{
   MqlTick tick;
   double margin = 0.0;
   if(!SymbolInfoTick(_Symbol, tick) || tick.ask <= 0.0 ||
      !OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, InpFixedLots, tick.ask, margin) || margin <= 0.0)
      return;

   g_marginLogged = true;
   double gate = InpMinimumProjectedMarginLevel / 100.0;
   PrintFormat("AegisGold margin: %.2f lot at %.2f needs %.2f %s. At the %.0f%% margin-level gate, one position "
               "needs equity >= %.2f and %d positions need >= %.2f; equity now %.2f.",
               InpFixedLots, tick.ask, margin, AccountInfoString(ACCOUNT_CURRENCY), InpMinimumProjectedMarginLevel,
               margin * gate, g_maxPositions, margin * g_maxPositions * gate, AccountInfoDouble(ACCOUNT_EQUITY));
}

void LogSymbolConfiguration()
{
   double contract_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   double tick_size     = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tick_value    = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double volume_min    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double volume_step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   long digits          = SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   long stops_level     = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);

   PrintFormat("AegisGold initialized on %s: account=%s contract=%.2f tickSize=%.5f tickValue=%.5f digits=%d stopsLevel=%d volumeMin=%.3f volumeStep=%.3f",
               _Symbol, AccountInfoString(ACCOUNT_CURRENCY), contract_size, tick_size,
               tick_value, (int)digits, (int)stops_level, volume_min, volume_step);
}
