#property strict
#property version   "2.01"
#property description "Aegis Gold Intraday v2.0 (experiment): all-day XAU/USD M5 engine, regime reader, $4/$3 bracket, breakeven"

#include <Trade/Trade.mqh>

CTrade Trade;

enum SignalDirection
{
   SIGNAL_SHORT = -1,
   SIGNAL_NONE  = 0,
   SIGNAL_LONG  = 1
};

// Regimes read from completed M15 bars
#define REGIME_TREND_UP       1
#define REGIME_TREND_DOWN     2
#define REGIME_RANGE          3
#define REGIME_TRANSITION     4

// Setup types, recorded in the order comment as T0, T1, T2, R or X
#define SETUP_T0              1
#define SETUP_T1              2
#define SETUP_T2              3
#define SETUP_RANGE           4
#define SETUP_TRANSITION      5
#define SETUP_COUNT           5

// Setup funnel: indices 0-4 count qualified setups by type (setup - 1); the rest record
// where each setup ended: the first gate that blocked it, or placed.
#define FUNNEL_HALT           5
#define FUNNEL_EXPOSURE       6
#define FUNNEL_SESSION        7
#define FUNNEL_MARKET_CLOSE   8
#define FUNNEL_SPREAD         9
#define FUNNEL_SHOCK          10
#define FUNNEL_RUNAWAY        11
#define FUNNEL_NEWS           12
#define FUNNEL_CHASE          13
#define FUNNEL_RISK_BUDGET    14
#define FUNNEL_MARGIN         15
#define FUNNEL_OTHER          16
#define FUNNEL_PLACED         17
#define FUNNEL_SIZE           18

input group "Identity and account safety"
input ulong  InpMagicNumber                  = 26092820;
input bool   InpRequireGBPAccount             = true;
input double InpFixedLots                     = 0.02;
input double InpMinimumProjectedMarginLevel   = 120.0;
// EA positions at once; 2 only on hedging accounts and only when the margin gate allows it
input int    InpMaxConcurrentPositions        = 1;

input group "Regime reader (completed M15 bars)"
input int    InpM15FastEmaPeriod              = 50;
input int    InpM15SlowEmaPeriod              = 200;
input int    InpM15SlopeLookbackBars          = 2;
input int    InpM15AtrPeriod                  = 14;
// Range when there is no trend and |EMA50 - EMA200| <= this multiple of M15 ATR; otherwise transition
input double InpRangeMaxEmaGapAtr             = 1.00;

input group "M5 indicators"
input int    InpM5FastEmaPeriod               = 9;
input int    InpM5BasisEmaPeriod              = 20;
input int    InpM5SlowEmaPeriod               = 50;
input int    InpM5AtrPeriod                   = 20;
input int    InpRsiPeriod                     = 2;
input double InpMaxConfirmationRangeAtr       = 1.50;

input group "Trend engine (M15 uptrend or downtrend)"
input bool   InpEnableTrendEngine             = true;
// T0: exhaustion bar taps EMA9 but holds beyond EMA20
input bool   InpEnableTier0                   = true;
input double InpTier0RsiLongThreshold         = 40.0;
input double InpTier0RsiShortThreshold        = 60.0;
// T1: exhaustion bar reaches EMA20
input bool   InpEnableTier1                   = true;
input double InpTier1RsiLongThreshold         = 35.0;
input double InpTier1RsiShortThreshold        = 65.0;
// T2: exhaustion bar reaches the outer band (EMA20 +/- multiple x ATR20)
input bool   InpEnableTier2                   = true;
input double InpTier2BandAtr                  = 1.20;
input double InpTier2RsiLongThreshold         = 15.0;
input double InpTier2RsiShortThreshold        = 85.0;

input group "Range engine (flat M15)"
input bool   InpEnableRangeEngine             = true;
input double InpRangeBandAtr                  = 1.50;
input double InpRangeRsiLongThreshold         = 10.0;
input double InpRangeRsiShortThreshold        = 90.0;

input group "Transition engine (M5 EMA9/20/50 stack)"
input bool   InpEnableTransitionEngine        = true;
input double InpTransitionRsiLongThreshold    = 40.0;
input double InpTransitionRsiShortThreshold   = 60.0;

input group "Entry and exits (XAU/USD price units)"
input double InpEntryBufferPrice              = 0.05;
input double InpMaxEntryAdjustmentPrice       = 0.20;
input int    InpPendingExpiryBars             = 2;
input double InpTakeProfitPrice               = 4.00;
input double InpStopLossPrice                 = 3.00;
// Move the stop to entry + offset once price is this far in profit; 0 = off
input double InpBreakevenTriggerPrice         = 1.50;
input double InpBreakevenOffsetPrice          = 0.10;
// Close a position at market after this many minutes; 0 = off
input int    InpTimeStopMinutes               = 0;
input int    InpMaximumDeviationPoints        = 20;

input group "Sessions and market close"
// false: no new entries 21:00-07:00 UTC
input bool   InpTradeAsiaSession              = true;
// false: no new entries 17:00-21:00 UTC (US afternoon into the daily rollover)
input bool   InpTradeLateSession              = true;
input bool   InpTesterUsesPepperstoneServer   = true;
input int    InpFallbackServerUtcOffsetHours  = 2;
input int    InpNoEntryMinutesBeforeDailyClose  = 15;
input int    InpNoEntryMinutesBeforeWeeklyClose = 60;
// Close all EA positions this many minutes before the weekly close; 0 = off
input int    InpCloseMinutesBeforeWeeklyClose   = 15;

input group "Rocket-move shield"
input double InpMaximumSpreadPrice            = 0.60;
input double InpShockCandleAtrMultiple        = 3.00;
input double InpShockAtrMedianMultiple        = 2.00;
input int    InpAtrMedianLookbackBars         = 100;
input int    InpNormalBarsAfterShock          = 3;
input double InpRunawayDistanceAtr            = 2.50;
input double InpRunawayBodyAtr                = 0.80;
input bool   InpUseNewsFilter                 = true;
input bool   InpNewsFailClosed                = true;
input int    InpNewsMinutesBefore             = 15;
input int    InpNewsMinutesAfter              = 15;

input group "Daily loss stop (the only daily limit)"
// Percent of the day's starting balance; each new entry must keep today's worst case inside it
input double InpDailyLossPercent              = 6.0;
// Round-trip commission per lot in account currency; used only for the worst-case estimate
input double InpCommissionPerLot              = 4.50;
input double InpRiskSlippageAllowancePrice    = 0.05;
// Optional safety cap on entries per server day; 0 = no cap
input int    InpMaxEntriesPerDay              = 0;

int      g_m5FastHandle      = INVALID_HANDLE;
int      g_m5BasisHandle     = INVALID_HANDLE;
int      g_m5SlowHandle      = INVALID_HANDLE;
int      g_m5AtrHandle       = INVALID_HANDLE;
int      g_m5RsiHandle       = INVALID_HANDLE;
int      g_m15FastHandle     = INVALID_HANDLE;
int      g_m15SlowHandle     = INVALID_HANDLE;
int      g_m15AtrHandle      = INVALID_HANDLE;
datetime g_lastM5BarTime     = 0;
datetime g_dailyStart        = 0;
int      g_dailyEntries      = 0;
double   g_dailyNet          = 0.0;
bool     g_dailyHalted       = false;
string   g_status            = "Initializing";
string   g_regimeText        = "M15 regime not evaluated yet";
int      g_lastSetup         = 0;
int      g_funnel[FUNNEL_SIZE];       // setup funnel for the end-of-run report
datetime g_runStart          = 0;
int      g_maxPositions      = 1;     // effective limit (1 on netting accounts)
datetime g_lastManageTime    = 0;
datetime g_nextCloseAttempt  = 0;
datetime g_nextModifyAttempt = 0;
bool     g_marginLogged      = false;
int      g_eventBreakevens   = 0;
int      g_eventTimeStops    = 0;
int      g_eventWeeklyCloses = 0;
ulong    g_breakevenIds[];            // position IDs whose stop was moved to breakeven
int      g_fillCount         = 0;
double   g_fillSpreadSum     = 0.0;
double   g_spreadCost        = 0.0;

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

   g_m5FastHandle  = iMA(_Symbol, PERIOD_M5, InpM5FastEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_m5BasisHandle = iMA(_Symbol, PERIOD_M5, InpM5BasisEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_m5SlowHandle  = iMA(_Symbol, PERIOD_M5, InpM5SlowEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_m5AtrHandle   = iATR(_Symbol, PERIOD_M5, InpM5AtrPeriod);
   g_m5RsiHandle   = iRSI(_Symbol, PERIOD_M5, InpRsiPeriod, PRICE_CLOSE);
   g_m15FastHandle = iMA(_Symbol, PERIOD_M15, InpM15FastEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_m15SlowHandle = iMA(_Symbol, PERIOD_M15, InpM15SlowEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_m15AtrHandle  = iATR(_Symbol, PERIOD_M15, InpM15AtrPeriod);

   if(g_m5FastHandle == INVALID_HANDLE || g_m5BasisHandle == INVALID_HANDLE || g_m5SlowHandle == INVALID_HANDLE ||
      g_m5AtrHandle == INVALID_HANDLE || g_m5RsiHandle == INVALID_HANDLE || g_m15FastHandle == INVALID_HANDLE ||
      g_m15SlowHandle == INVALID_HANDLE || g_m15AtrHandle == INVALID_HANDLE)
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
   ArrayResize(g_breakevenIds, 0);
   g_eventBreakevens = g_eventTimeStops = g_eventWeeklyCloses = 0;
   g_fillCount = 0;
   g_fillSpreadSum = g_spreadCost = 0.0;
   g_lastManageTime = g_nextCloseAttempt = g_nextModifyAttempt = 0;
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
//| Expert deinitialization: print the run report                    |
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
      CancelOwnPendingOrders("daily loss stop");
   else if(OrdersTotal() > 0 && IsNearMarketClose(close_reason))
      CancelOwnPendingOrders("market-close protection");
   else
      CancelExpiredOwnPendingOrders();

   if(IsNewM5Bar())
      EvaluateNewM5Bar();

   UpdateDashboard();
}

//+------------------------------------------------------------------+
//| Record entry costs and refresh the daily state after each deal   |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
      RecordEntryCosts(trans.deal);
   RefreshDailyStats();
}

//+------------------------------------------------------------------+
//| Validate inputs                                                  |
//+------------------------------------------------------------------+
bool InputsAreValid()
{
   bool valid = true;

   if(InpFixedLots <= 0.0 || InpMinimumProjectedMarginLevel <= 0.0 ||
      InpMaxConcurrentPositions < 1 || InpMaxConcurrentPositions > 2)
      valid = false;
   if(InpM15FastEmaPeriod <= 1 || InpM15SlowEmaPeriod <= InpM15FastEmaPeriod || InpM15SlopeLookbackBars < 1 ||
      InpM15AtrPeriod <= 1 || InpRangeMaxEmaGapAtr <= 0.0)
      valid = false;
   if(InpM5FastEmaPeriod < 2 || InpM5BasisEmaPeriod <= InpM5FastEmaPeriod ||
      InpM5SlowEmaPeriod <= InpM5BasisEmaPeriod || InpM5AtrPeriod <= 1 || InpRsiPeriod <= 0 ||
      InpMaxConfirmationRangeAtr <= 0.0 || InpTier2BandAtr <= 0.0 || InpRangeBandAtr <= 0.0)
      valid = false;
   if(!RsiPairIsValid(InpTier0RsiLongThreshold, InpTier0RsiShortThreshold) ||
      !RsiPairIsValid(InpTier1RsiLongThreshold, InpTier1RsiShortThreshold) ||
      !RsiPairIsValid(InpTier2RsiLongThreshold, InpTier2RsiShortThreshold) ||
      !RsiPairIsValid(InpRangeRsiLongThreshold, InpRangeRsiShortThreshold) ||
      !RsiPairIsValid(InpTransitionRsiLongThreshold, InpTransitionRsiShortThreshold))
      valid = false;
   bool trend_on = (InpEnableTrendEngine && (InpEnableTier0 || InpEnableTier1 || InpEnableTier2));
   if(!trend_on && !InpEnableRangeEngine && !InpEnableTransitionEngine)
      valid = false;
   if(InpEntryBufferPrice < 0.0 || InpMaxEntryAdjustmentPrice < 0.0 || InpPendingExpiryBars < 1 ||
      InpTakeProfitPrice <= 0.0 || InpStopLossPrice <= 0.0 || InpBreakevenTriggerPrice < 0.0 ||
      InpBreakevenOffsetPrice < 0.0 || InpTimeStopMinutes < 0 || InpMaximumDeviationPoints < 0)
      valid = false;
   if(InpBreakevenTriggerPrice > 0.0 &&
      (InpBreakevenOffsetPrice >= InpBreakevenTriggerPrice || InpBreakevenTriggerPrice >= InpTakeProfitPrice))
      valid = false;
   if(InpNoEntryMinutesBeforeDailyClose < 0 || InpNoEntryMinutesBeforeWeeklyClose < 0 ||
      InpCloseMinutesBeforeWeeklyClose < 0 || InpFallbackServerUtcOffsetHours < -12 ||
      InpFallbackServerUtcOffsetHours > 14)
      valid = false;
   if(InpMaximumSpreadPrice <= 0.0 || InpShockCandleAtrMultiple <= 0.0 || InpShockAtrMedianMultiple <= 0.0 ||
      InpAtrMedianLookbackBars < 10 || InpNormalBarsAfterShock < 1 || InpRunawayDistanceAtr <= 0.0 ||
      InpRunawayBodyAtr <= 0.0 || InpNewsMinutesBefore < 0 || InpNewsMinutesAfter < 0)
      valid = false;
   if(InpDailyLossPercent <= 0.0 || InpDailyLossPercent > 50.0 || InpCommissionPerLot < 0.0 ||
      InpRiskSlippageAllowancePrice < 0.0 || InpMaxEntriesPerDay < 0)
      valid = false;

   if(!valid)
      Print("Initialization failed: one or more EA inputs are invalid.");
   return valid;
}

bool RsiPairIsValid(const double long_threshold, const double short_threshold)
{
   return (long_threshold > 0.0 && long_threshold < 50.0 && short_threshold > 50.0 && short_threshold < 100.0);
}

//+------------------------------------------------------------------+
//| Evaluate once per new M5 bar. Every qualified setup is counted   |
//| and attributed to the first gate that blocks it, or to placed.   |
//+------------------------------------------------------------------+
void EvaluateNewM5Bar()
{
   RefreshDailyStats();
   CancelExpiredOwnPendingOrders();

   int  own_positions    = 0;
   int  own_direction    = 0;
   bool foreign_exposure = false;
   ScanSymbolExposure(own_positions, own_direction, foreign_exposure);

   double loss_limit  = DailyLossLimit();
   double open_risk   = 0.0;
   bool   risk_known  = OpenRisk(open_risk);
   bool   cap_reached = (InpMaxEntriesPerDay > 0 && g_dailyEntries >= InpMaxEntriesPerDay);
   g_dailyHalted = (!risk_known || cap_reached || g_dailyNet - open_risk <= -loss_limit);
   if(g_dailyHalted)
      CancelOwnPendingOrders("daily loss stop");

   // Setup-independent gates first, so the dashboard shows why the EA is idle.
   int    gate_stage   = -1;
   string gate_status  = "";
   string close_reason = "";
   if(g_dailyHalted)
   {
      gate_stage  = FUNNEL_HALT;
      gate_status = DailyHaltDescription(loss_limit, open_risk, risk_known, cap_reached);
   }
   else if(foreign_exposure)
   {
      gate_stage  = FUNNEL_EXPOSURE;
      gate_status = "Manual or other-EA position/order on this symbol; EA entries paused";
   }
   else if(HasAnyPendingOrderForSymbol())
   {
      gate_stage  = FUNNEL_EXPOSURE;
      gate_status = "Pending entry order waiting to trigger or expire";
   }
   else if(own_positions >= g_maxPositions)
   {
      gate_stage  = FUNNEL_EXPOSURE;
      gate_status = StringFormat("%d of %d EA positions open", own_positions, g_maxPositions);
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
   double   ema_fast[];
   double   ema_basis[];
   double   ema_slow[];
   double   atr[];
   double   rsi[];
   double   m15_fast[];
   double   m15_slow[];
   double   m15_atr[];
   if(!LoadStrategyData(rates, ema_fast, ema_basis, ema_slow, atr, rsi, m15_fast, m15_slow, m15_atr))
   {
      SetStatus(gate_stage >= 0 ? gate_status : "Waiting for sufficient indicator history");
      return;
   }

   int setup = 0;
   SignalDirection signal = BuildSignal(rates, ema_fast, ema_basis, ema_slow, atr, rsi,
                                        m15_fast, m15_slow, m15_atr, setup);
   if(signal == SIGNAL_NONE)
   {
      SetStatus(gate_stage >= 0 ? gate_status : "No qualified setup");
      return;
   }

   g_funnel[setup - 1]++;
   string setup_text = StringFormat("%s %s setup", SetupTag(setup), signal == SIGNAL_LONG ? "long" : "short");
   if(gate_stage >= 0)
   {
      BlockSetup(gate_stage, gate_status + "; " + setup_text + " skipped");
      return;
   }

   // An additional position must be in the same direction as the open one (no hedging).
   if(own_positions > 0 && (int)signal != own_direction)
   {
      BlockSetup(FUNNEL_EXPOSURE, "Opposite-direction " + setup_text + " while an EA position is open");
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
      BlockSetup(FUNNEL_SPREAD, StringFormat("Spread %.3f above %.2f; %s skipped",
                                             spread_price, InpMaximumSpreadPrice, setup_text));
      return;
   }

   if(IsVolatilityShock(rates, atr))
   {
      BlockSetup(FUNNEL_SHOCK, "Rocket-move shield: volatility shock; " + setup_text + " skipped");
      return;
   }

   if(IsRunawayMarket(rates, ema_basis, atr))
   {
      BlockSetup(FUNNEL_RUNAWAY, "Rocket-move shield: runaway move; " + setup_text + " skipped");
      return;
   }

   if(IsHighImpactUsdNewsWindow())
   {
      BlockSetup(FUNNEL_NEWS, "High-impact USD news window or unavailable calendar; " + setup_text + " skipped");
      return;
   }

   g_lastSetup = setup;
   int stage = PlaceStopEntry(signal, setup, own_positions > 0, rates, tick, loss_limit, open_risk);
   g_funnel[stage]++;
}

void BlockSetup(const int stage, const string status)
{
   g_funnel[stage]++;
   SetStatus(status);
}

//+------------------------------------------------------------------+
//| Load closed/current M5 and M15 values (index 0 = forming bar)     |
//+------------------------------------------------------------------+
bool LoadStrategyData(MqlRates &rates[], double &ema_fast[], double &ema_basis[], double &ema_slow[],
                      double &atr[], double &rsi[], double &m15_fast[], double &m15_slow[], double &m15_atr[])
{
   int needed_m5 = InpAtrMedianLookbackBars + InpNormalBarsAfterShock + 10;
   if(needed_m5 < 20)
      needed_m5 = 20;
   int needed_m15 = InpM15SlopeLookbackBars + 3;
   if(needed_m15 < 5)
      needed_m15 = 5;

   ArraySetAsSeries(rates, true);
   ArraySetAsSeries(ema_fast, true);
   ArraySetAsSeries(ema_basis, true);
   ArraySetAsSeries(ema_slow, true);
   ArraySetAsSeries(atr, true);
   ArraySetAsSeries(rsi, true);
   ArraySetAsSeries(m15_fast, true);
   ArraySetAsSeries(m15_slow, true);
   ArraySetAsSeries(m15_atr, true);

   if(BarsCalculated(g_m5FastHandle) < needed_m5 || BarsCalculated(g_m5BasisHandle) < needed_m5 ||
      BarsCalculated(g_m5SlowHandle) < needed_m5 || BarsCalculated(g_m5AtrHandle) < needed_m5 ||
      BarsCalculated(g_m5RsiHandle) < needed_m5 || BarsCalculated(g_m15FastHandle) < needed_m15 ||
      BarsCalculated(g_m15SlowHandle) < needed_m15 || BarsCalculated(g_m15AtrHandle) < needed_m15)
      return false;

   if(CopyRates(_Symbol, PERIOD_M5, 0, needed_m5, rates) != needed_m5 ||
      CopyBuffer(g_m5FastHandle, 0, 0, needed_m5, ema_fast) != needed_m5 ||
      CopyBuffer(g_m5BasisHandle, 0, 0, needed_m5, ema_basis) != needed_m5 ||
      CopyBuffer(g_m5SlowHandle, 0, 0, needed_m5, ema_slow) != needed_m5 ||
      CopyBuffer(g_m5AtrHandle, 0, 0, needed_m5, atr) != needed_m5 ||
      CopyBuffer(g_m5RsiHandle, 0, 0, needed_m5, rsi) != needed_m5 ||
      CopyBuffer(g_m15FastHandle, 0, 0, needed_m15, m15_fast) != needed_m15 ||
      CopyBuffer(g_m15SlowHandle, 0, 0, needed_m15, m15_slow) != needed_m15 ||
      CopyBuffer(g_m15AtrHandle, 0, 0, needed_m15, m15_atr) != needed_m15)
      return false;

   return (atr[1] > 0.0 && atr[2] > 0.0 && m15_atr[1] > 0.0);
}

//+------------------------------------------------------------------+
//| Regime reader (completed M15 bar 1; slope vs bar 1 + lookback)   |
//+------------------------------------------------------------------+
int ReadRegime(const double &m15_fast[], const double &m15_slow[], const double &m15_atr[])
{
   int slope_shift = 1 + InpM15SlopeLookbackBars;
   if(m15_fast[1] > m15_slow[1] && m15_fast[1] > m15_fast[slope_shift])
      return REGIME_TREND_UP;
   if(m15_fast[1] < m15_slow[1] && m15_fast[1] < m15_fast[slope_shift])
      return REGIME_TREND_DOWN;
   if(MathAbs(m15_fast[1] - m15_slow[1]) <= InpRangeMaxEmaGapAtr * m15_atr[1])
      return REGIME_RANGE;
   return REGIME_TRANSITION;
}

string RegimeText(const int regime)
{
   if(regime == REGIME_TREND_UP)
      return "M15 uptrend: trend engine";
   if(regime == REGIME_TREND_DOWN)
      return "M15 downtrend: trend engine";
   if(regime == REGIME_RANGE)
      return "M15 flat: range engine";
   return "M15 transition: M5 stack engine";
}

//+------------------------------------------------------------------+
//| Setups on closed bars: shift 2 = exhaustion, shift 1 =           |
//| confirmation. Returns the direction and sets the setup type.     |
//+------------------------------------------------------------------+
SignalDirection BuildSignal(const MqlRates &rates[], const double &ema_fast[], const double &ema_basis[],
                            const double &ema_slow[], const double &atr[], const double &rsi[],
                            const double &m15_fast[], const double &m15_slow[], const double &m15_atr[],
                            int &setup)
{
   setup = 0;
   int regime = ReadRegime(m15_fast, m15_slow, m15_atr);
   g_regimeText = RegimeText(regime);

   // The exhaustion bar, confirmation bar and current bar must be consecutive (no market break).
   long bar_seconds = (long)PeriodSeconds(PERIOD_M5);
   if((long)rates[0].time - (long)rates[1].time != bar_seconds ||
      (long)rates[1].time - (long)rates[2].time != bar_seconds)
      return SIGNAL_NONE;
   if(TrueRange(rates, 1) > InpMaxConfirmationRangeAtr * atr[1])
      return SIGNAL_NONE;

   double midpoint   = (rates[1].high + rates[1].low) * 0.5;
   bool   bull       = (rates[1].close > rates[1].open && rates[1].close >= midpoint);
   bool   bear       = (rates[1].close < rates[1].open && rates[1].close <= midpoint);
   bool   long_conf  = (bull && rates[1].close > rates[2].close);
   bool   short_conf = (bear && rates[1].close < rates[2].close);
   double rsi2       = rsi[2];

   if(regime == REGIME_TREND_UP)
   {
      if(!InpEnableTrendEngine)
         return SIGNAL_NONE;
      if(InpEnableTier2 && long_conf && rates[2].low <= ema_basis[2] - InpTier2BandAtr * atr[2] &&
         rsi2 <= InpTier2RsiLongThreshold && rates[1].close > ema_basis[1] - InpTier2BandAtr * atr[1])
      {
         setup = SETUP_T2;
         return SIGNAL_LONG;
      }
      if(InpEnableTier1 && long_conf && rates[2].low <= ema_basis[2] &&
         rsi2 <= InpTier1RsiLongThreshold && rates[1].close > ema_basis[1])
      {
         setup = SETUP_T1;
         return SIGNAL_LONG;
      }
      if(InpEnableTier0 && bull && rates[2].low <= ema_fast[2] && rates[2].low > ema_basis[2] &&
         rsi2 <= InpTier0RsiLongThreshold && rates[1].close > ema_fast[1] && ema_fast[1] > ema_basis[1])
      {
         setup = SETUP_T0;
         return SIGNAL_LONG;
      }
      return SIGNAL_NONE;
   }

   if(regime == REGIME_TREND_DOWN)
   {
      if(!InpEnableTrendEngine)
         return SIGNAL_NONE;
      if(InpEnableTier2 && short_conf && rates[2].high >= ema_basis[2] + InpTier2BandAtr * atr[2] &&
         rsi2 >= InpTier2RsiShortThreshold && rates[1].close < ema_basis[1] + InpTier2BandAtr * atr[1])
      {
         setup = SETUP_T2;
         return SIGNAL_SHORT;
      }
      if(InpEnableTier1 && short_conf && rates[2].high >= ema_basis[2] &&
         rsi2 >= InpTier1RsiShortThreshold && rates[1].close < ema_basis[1])
      {
         setup = SETUP_T1;
         return SIGNAL_SHORT;
      }
      if(InpEnableTier0 && bear && rates[2].high >= ema_fast[2] && rates[2].high < ema_basis[2] &&
         rsi2 >= InpTier0RsiShortThreshold && rates[1].close < ema_fast[1] && ema_fast[1] < ema_basis[1])
      {
         setup = SETUP_T0;
         return SIGNAL_SHORT;
      }
      return SIGNAL_NONE;
   }

   if(regime == REGIME_RANGE)
   {
      if(!InpEnableRangeEngine)
         return SIGNAL_NONE;
      if(long_conf && rates[2].low <= ema_basis[2] - InpRangeBandAtr * atr[2] &&
         rsi2 <= InpRangeRsiLongThreshold && rates[1].close > ema_basis[1] - InpRangeBandAtr * atr[1])
      {
         setup = SETUP_RANGE;
         return SIGNAL_LONG;
      }
      if(short_conf && rates[2].high >= ema_basis[2] + InpRangeBandAtr * atr[2] &&
         rsi2 >= InpRangeRsiShortThreshold && rates[1].close < ema_basis[1] + InpRangeBandAtr * atr[1])
      {
         setup = SETUP_RANGE;
         return SIGNAL_SHORT;
      }
      return SIGNAL_NONE;
   }

   // Transition: M5 EMA stack (fast beyond basis beyond slow, basis sloping) and a tap of the fast EMA.
   if(!InpEnableTransitionEngine)
      return SIGNAL_NONE;
   bool basis_rising  = (ema_basis[1] > ema_basis[3]);
   bool basis_falling = (ema_basis[1] < ema_basis[3]);
   if(ema_fast[1] > ema_basis[1] && ema_basis[1] > ema_slow[1] && basis_rising && bull &&
      rates[2].low <= ema_fast[2] && rsi2 <= InpTransitionRsiLongThreshold && rates[1].close > ema_fast[1])
   {
      setup = SETUP_TRANSITION;
      return SIGNAL_LONG;
   }
   if(ema_fast[1] < ema_basis[1] && ema_basis[1] < ema_slow[1] && basis_falling && bear &&
      rates[2].high >= ema_fast[2] && rsi2 >= InpTransitionRsiShortThreshold && rates[1].close < ema_fast[1])
   {
      setup = SETUP_TRANSITION;
      return SIGNAL_SHORT;
   }
   return SIGNAL_NONE;
}

string SetupTag(const int setup)
{
   if(setup == SETUP_T0)
      return "T0";
   if(setup == SETUP_T1)
      return "T1";
   if(setup == SETUP_T2)
      return "T2";
   if(setup == SETUP_RANGE)
      return "R";
   if(setup == SETUP_TRANSITION)
      return "X";
   return "?";
}

//+------------------------------------------------------------------+
//| Broker-side stop entry with a fixed bracket attached. Long: buy  |
//| stop at the confirmation high + buffer, SL/TP a fixed distance   |
//| from the order price. Short is the mirror.                       |
//+------------------------------------------------------------------+
int PlaceStopEntry(const SignalDirection signal, const int setup, const bool additional_position,
                   const MqlRates &rates[], const MqlTick &tick, const double loss_limit, const double open_risk)
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

   double minimum_gap   = MathMax((double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * point, tick_size);
   double desired_entry = 0.0;
   double entry         = 0.0;
   double stop_loss     = 0.0;
   double take_profit   = 0.0;

   if(signal == SIGNAL_LONG)
   {
      desired_entry = RoundUpToTick(rates[1].high + InpEntryBufferPrice);
      entry = RoundUpToTick(MathMax(desired_entry, tick.ask + minimum_gap));
      if(entry - desired_entry > InpMaxEntryAdjustmentPrice + tick_size * 0.5)
      {
         SetStatus("Buy trigger already missed beyond chase allowance");
         return FUNNEL_CHASE;
      }
      stop_loss   = RoundDownToTick(entry - InpStopLossPrice);
      take_profit = RoundUpToTick(entry + InpTakeProfitPrice);
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
      stop_loss   = RoundUpToTick(entry + InpStopLossPrice);
      take_profit = RoundDownToTick(entry - InpTakeProfitPrice);
   }

   if(MathAbs(entry - stop_loss) < minimum_gap || MathAbs(take_profit - entry) < minimum_gap)
   {
      SetStatus("Broker minimum stop distance rejected SL/TP geometry");
      return FUNNEL_OTHER;
   }

   // Daily loss stop: today's net, minus every open stop, minus this order's stop must stay inside the limit.
   double new_risk = NewOrderRisk(signal, entry, stop_loss);
   if(new_risk < 0.0)
   {
      SetStatus("Could not price the new order's risk; setup skipped");
      return FUNNEL_RISK_BUDGET;
   }
   if(g_dailyNet - open_risk - new_risk < -loss_limit)
   {
      SetStatus(StringFormat("Daily loss stop: a stop-out would take today to %.2f (limit -%.2f); setup skipped",
                             g_dailyNet - open_risk - new_risk, loss_limit));
      return FUNNEL_RISK_BUDGET;
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

   // e.g. AegisIntraday-T1-LON, AegisIntraday-X-ASIA-P2 (P2 = additional position)
   string comment = StringFormat("AegisIntraday-%s-%s%s", SetupTag(setup), SessionTag(),
                                 additional_position ? "-P2" : "");
   bool request_ok = false;
   if(signal == SIGNAL_LONG)
      request_ok = Trade.BuyStop(InpFixedLots, entry, _Symbol, stop_loss, take_profit,
                                 order_time, expiration, comment);
   else
      request_ok = Trade.SellStop(InpFixedLots, entry, _Symbol, stop_loss, take_profit,
                                  order_time, expiration, comment);

   uint retcode = Trade.ResultRetcode();
   if(!request_ok || (retcode != TRADE_RETCODE_DONE && retcode != TRADE_RETCODE_PLACED))
   {
      SetStatus(StringFormat("Order rejected: %u %s", retcode, Trade.ResultRetcodeDescription()));
      PrintFormat("Order request failed. retcode=%u description=%s entry=%.3f sl=%.3f tp=%.3f",
                  retcode, Trade.ResultRetcodeDescription(), entry, stop_loss, take_profit);
      return FUNNEL_OTHER;
   }

   SetStatus(StringFormat("%s %s stop placed: entry %.3f SL %.3f TP %.3f", SetupTag(setup),
                          signal == SIGNAL_LONG ? "buy" : "sell", entry, stop_loss, take_profit));
   PrintFormat("Protected %s %s stop accepted. order=%I64u volume=%.2f entry=%.3f sl=%.3f tp=%.3f",
               SetupTag(setup), signal == SIGNAL_LONG ? "buy" : "sell", Trade.ResultOrder(), InpFixedLots,
               entry, stop_loss, take_profit);
   return FUNNEL_PLACED;
}

//+------------------------------------------------------------------+
//| Daily loss stop: InpDailyLossPercent of the balance at the start |
//| of the server day (current balance minus today's EA result).     |
//+------------------------------------------------------------------+
double DailyLossLimit()
{
   double day_start_balance = AccountInfoDouble(ACCOUNT_BALANCE) - g_dailyNet;
   return MathMax(0.0, day_start_balance * InpDailyLossPercent / 100.0);
}

// Loss if every open EA position hit its current stop (plus exit commission); false if a stop is missing.
bool OpenRisk(double &risk)
{
   risk = 0.0;
   for(int index = PositionsTotal() - 1; index >= 0; index--)
   {
      ulong ticket = PositionGetTicket(index);
      if(ticket == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol ||
         (ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      double stop_loss = PositionGetDouble(POSITION_SL);
      if(stop_loss <= 0.0)
         return false;

      ENUM_ORDER_TYPE type = ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
                             ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      double volume = PositionGetDouble(POSITION_VOLUME);
      double result = 0.0;
      if(!OrderCalcProfit(type, _Symbol, volume, PositionGetDouble(POSITION_PRICE_OPEN), stop_loss, result))
         return false;
      result += PositionGetDouble(POSITION_SWAP) - 0.5 * InpCommissionPerLot * volume;
      risk += MathMax(0.0, -result);
   }
   return true;
}

// Loss if a new order is stopped out, with a slippage allowance and round-trip commission; -1 if unpriceable.
double NewOrderRisk(const SignalDirection signal, const double entry, const double stop_loss)
{
   ENUM_ORDER_TYPE type = (signal == SIGNAL_LONG) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double exit_price = (signal == SIGNAL_LONG) ? stop_loss - InpRiskSlippageAllowancePrice
                                               : stop_loss + InpRiskSlippageAllowancePrice;
   double result = 0.0;
   if(!OrderCalcProfit(type, _Symbol, InpFixedLots, entry, exit_price, result))
      return -1.0;
   return MathMax(0.0, -result) + InpCommissionPerLot * InpFixedLots;
}

//+------------------------------------------------------------------+
//| Daily accounting: entries and net result of this EA since server |
//| midnight. History failure fails closed.                          |
//+------------------------------------------------------------------+
void RefreshDailyStats()
{
   datetime now = ServerNow();
   datetime day_start = StartOfDay(now);
   g_dailyStart   = day_start;
   g_dailyEntries = 0;
   g_dailyNet     = 0.0;

   if(!HistorySelect(day_start, now + 60))
   {
      g_dailyHalted = true;
      SetStatus("History unavailable; daily loss stop fails closed");
      return;
   }

   int deals_total = HistoryDealsTotal();
   for(int index = 0; index < deals_total; index++)
   {
      ulong deal_ticket = HistoryDealGetTicket(index);
      if(deal_ticket == 0 || (ulong)HistoryDealGetInteger(deal_ticket, DEAL_MAGIC) != InpMagicNumber ||
         HistoryDealGetString(deal_ticket, DEAL_SYMBOL) != _Symbol)
         continue;
      ENUM_DEAL_ENTRY entry_type = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal_ticket, DEAL_ENTRY);
      if(entry_type == DEAL_ENTRY_IN || entry_type == DEAL_ENTRY_INOUT)
         g_dailyEntries++;
      g_dailyNet += DealNetResult(deal_ticket);
   }

   g_dailyHalted = (g_dailyNet <= -DailyLossLimit() ||
                    (InpMaxEntriesPerDay > 0 && g_dailyEntries >= InpMaxEntriesPerDay));
}

// 24/5 in server time; optionally skip the Asian (21:00-07:00 UTC) and late (17:00-21:00 UTC) sessions.
bool IsEntrySession()
{
   MqlDateTime server_parts;
   TimeToStruct(ServerNow(), server_parts);
   if(server_parts.day_of_week == 0 || server_parts.day_of_week == 6)
      return false;
   string session_tag = SessionTag();
   if(!InpTradeAsiaSession && session_tag == "ASIA")
      return false;
   if(!InpTradeLateSession && session_tag == "LATE")
      return false;
   return true;
}

string SessionBlockDescription()
{
   MqlDateTime server_parts;
   TimeToStruct(ServerNow(), server_parts);
   if(server_parts.day_of_week == 0 || server_parts.day_of_week == 6)
      return "Weekend (server time)";
   if(SessionTag() == "LATE")
      return "Late session switched off (17:00-21:00 UTC)";
   return "Asian session switched off (21:00-07:00 UTC)";
}

string DailyHaltDescription(const double loss_limit, const double open_risk, const bool risk_known,
                            const bool cap_reached)
{
   if(!risk_known)
      return "Open EA position without a stop or unpriceable risk; new entries paused";
   if(cap_reached)
      return StringFormat("Daily entry cap reached: %d entries", g_dailyEntries);
   return StringFormat("Daily loss stop: today %.2f, open risk %.2f, limit -%.2f %s",
                       g_dailyNet, open_risk, loss_limit, AccountInfoString(ACCOUNT_CURRENCY));
}

//+------------------------------------------------------------------+
//| Position management                                              |
//| Breakeven on every tick; time stop and weekend close at most     |
//| once per second (a failed close retries after 60 s).             |
//+------------------------------------------------------------------+
void ManageOpenPositions()
{
   if(PositionsTotal() == 0)
      return;

   datetime now = TimeCurrent();
   bool once_per_second = (now != g_lastManageTime);
   g_lastManageTime = now;
   bool can_close = (once_per_second && now >= g_nextCloseAttempt);
   bool flatten   = (can_close && WeeklyFlattenDue());

   MqlTick tick;
   bool have_tick = (SymbolInfoTick(_Symbol, tick) && tick.bid > 0.0 && tick.ask > 0.0);

   for(int index = PositionsTotal() - 1; index >= 0; index--)
   {
      ulong ticket = PositionGetTicket(index);
      if(ticket == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol ||
         (ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      if(flatten)
      {
         if(ClosePositionWithReason(ticket, "weekend-close protection"))
            g_eventWeeklyCloses++;
         continue;
      }

      if(InpTimeStopMinutes > 0 && can_close &&
         (long)now - (long)PositionGetInteger(POSITION_TIME) >= (long)InpTimeStopMinutes * 60)
      {
         if(ClosePositionWithReason(ticket, StringFormat("time stop after %d min", InpTimeStopMinutes)))
            g_eventTimeStops++;
         continue;
      }

      if(have_tick && InpBreakevenTriggerPrice > 0.0)
         ApplyBreakeven(ticket, tick, now);
   }
}

// Move the stop to entry + offset once price has moved InpBreakevenTriggerPrice in favour (once per position).
void ApplyBreakeven(const ulong ticket, const MqlTick &tick, const datetime now)
{
   if(now < g_nextModifyAttempt || !PositionSelectByTicket(ticket))
      return;

   bool   is_long     = ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
   double open_price  = PositionGetDouble(POSITION_PRICE_OPEN);
   double stop_loss   = PositionGetDouble(POSITION_SL);
   double take_profit = PositionGetDouble(POSITION_TP);
   ulong  position_id = (ulong)PositionGetInteger(POSITION_IDENTIFIER);
   double tick_size   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double breakeven   = is_long ? RoundUpToTick(open_price + InpBreakevenOffsetPrice)
                                : RoundDownToTick(open_price - InpBreakevenOffsetPrice);

   if(stop_loss > 0.0 && (is_long ? stop_loss >= breakeven - tick_size * 0.5
                                  : stop_loss <= breakeven + tick_size * 0.5))
      return;
   bool triggered = is_long ? (tick.bid >= open_price + InpBreakevenTriggerPrice)
                            : (tick.ask <= open_price - InpBreakevenTriggerPrice);
   if(!triggered)
      return;

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double level_points = MathMax((double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL),
                                 (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL));
   double minimum_gap = MathMax(level_points * point, tick_size);
   if(is_long ? (tick.bid - breakeven < minimum_gap) : (breakeven - tick.ask < minimum_gap))
      return;

   if(Trade.PositionModify(ticket, breakeven, take_profit))
   {
      g_eventBreakevens++;
      int size = ArraySize(g_breakevenIds);
      ArrayResize(g_breakevenIds, size + 1);
      g_breakevenIds[size] = position_id;
      PrintFormat("Position %I64u: stop moved to breakeven %.3f.", ticket, breakeven);
   }
   else
   {
      PrintFormat("Breakeven move failed for %I64u: %u %s; retrying in 5 s.",
                  ticket, Trade.ResultRetcode(), Trade.ResultRetcodeDescription());
      g_nextModifyAttempt = now + 5;
   }
}

//+------------------------------------------------------------------+
//| Spread at the moment each entry fills (for the run report).      |
//| Entry slippage is measured in the report, where the filled order |
//| is guaranteed to be in history.                                  |
//+------------------------------------------------------------------+
void RecordEntryCosts(const ulong deal_ticket)
{
   if(deal_ticket == 0 || !HistoryDealSelect(deal_ticket))
      return;
   if((ulong)HistoryDealGetInteger(deal_ticket, DEAL_MAGIC) != InpMagicNumber ||
      HistoryDealGetString(deal_ticket, DEAL_SYMBOL) != _Symbol ||
      (ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal_ticket, DEAL_ENTRY) != DEAL_ENTRY_IN)
      return;

   double volume     = HistoryDealGetDouble(deal_ticket, DEAL_VOLUME);
   double tick_size  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   MqlTick tick;
   if(tick_size <= 0.0 || volume <= 0.0 || !SymbolInfoTick(_Symbol, tick) || tick.ask <= tick.bid)
      return;
   g_fillCount++;
   g_fillSpreadSum += tick.ask - tick.bid;
   g_spreadCost    += (tick.ask - tick.bid) * tick_value / tick_size * volume;
}

void ReleaseIndicators()
{
   if(g_m5FastHandle != INVALID_HANDLE)
      IndicatorRelease(g_m5FastHandle);
   if(g_m5BasisHandle != INVALID_HANDLE)
      IndicatorRelease(g_m5BasisHandle);
   if(g_m5SlowHandle != INVALID_HANDLE)
      IndicatorRelease(g_m5SlowHandle);
   if(g_m5AtrHandle != INVALID_HANDLE)
      IndicatorRelease(g_m5AtrHandle);
   if(g_m5RsiHandle != INVALID_HANDLE)
      IndicatorRelease(g_m5RsiHandle);
   if(g_m15FastHandle != INVALID_HANDLE)
      IndicatorRelease(g_m15FastHandle);
   if(g_m15SlowHandle != INVALID_HANDLE)
      IndicatorRelease(g_m15SlowHandle);
   if(g_m15AtrHandle != INVALID_HANDLE)
      IndicatorRelease(g_m15AtrHandle);
   g_m5FastHandle = g_m5BasisHandle = g_m5SlowHandle = g_m5AtrHandle = g_m5RsiHandle = INVALID_HANDLE;
   g_m15FastHandle = g_m15SlowHandle = g_m15AtrHandle = INVALID_HANDLE;
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

   string dashboard = StringFormat(
      "Aegis Gold Intraday v2.01 (experiment)\n"
      "Symbol: %s | Lots: %.2f | Spread: %.3f (max %.2f) | EA positions: %d/%d\n"
      "Today: entries %d | net %.2f %s | daily loss stop -%.2f (%s)\n"
      "Regime: %s | Last setup: %s | Sessions: Asia %s, Late %s\n"
      "Status: %s",
      _Symbol, InpFixedLots, spread, InpMaximumSpreadPrice, own_positions, g_maxPositions,
      g_dailyEntries, g_dailyNet, AccountInfoString(ACCOUNT_CURRENCY), DailyLossLimit(),
      g_dailyHalted ? "reached" : "not reached",
      g_regimeText, g_lastSetup > 0 ? SetupTag(g_lastSetup) : "none", InpTradeAsiaSession ? "on" : "off",
      InpTradeLateSession ? "on" : "off",
      g_status);
   Comment(dashboard);
}

//+------------------------------------------------------------------+
//| End-of-run report (Strategy Tester journal / Experts log):       |
//| setup funnel, position management, and this run's closed trades  |
//| by setup, session and exit type, with holding time and costs.    |
//+------------------------------------------------------------------+
void PrintRunSummary()
{
   if(g_runStart <= 0)
      return;

   int setups = 0;
   for(int index = 0; index < SETUP_COUNT; index++)
      setups += g_funnel[index];
   PrintFormat("AegisIntraday setup funnel: %d qualified setups (T0 %d, T1 %d, T2 %d, R %d, X %d), orders placed %d. "
               "Blocked by: daily loss stop %d, open position/order %d, session %d, market close %d, spread %d, "
               "shock %d, runaway %d, news %d, chase %d, worst-case loss %d, margin %d, other %d",
               setups, g_funnel[SETUP_T0 - 1], g_funnel[SETUP_T1 - 1], g_funnel[SETUP_T2 - 1],
               g_funnel[SETUP_RANGE - 1], g_funnel[SETUP_TRANSITION - 1], g_funnel[FUNNEL_PLACED],
               g_funnel[FUNNEL_HALT], g_funnel[FUNNEL_EXPOSURE], g_funnel[FUNNEL_SESSION],
               g_funnel[FUNNEL_MARKET_CLOSE], g_funnel[FUNNEL_SPREAD], g_funnel[FUNNEL_SHOCK],
               g_funnel[FUNNEL_RUNAWAY], g_funnel[FUNNEL_NEWS], g_funnel[FUNNEL_CHASE],
               g_funnel[FUNNEL_RISK_BUDGET], g_funnel[FUNNEL_MARGIN], g_funnel[FUNNEL_OTHER]);
   PrintFormat("AegisIntraday position management: %d breakeven moves, %d time-stop closes, %d weekend closes",
               g_eventBreakevens, g_eventTimeStops, g_eventWeeklyCloses);

   datetime now = TimeCurrent();
   if(!HistorySelect(g_runStart, now + 60))
      return;

   // Aggregate this EA's deals by position; the running sum of deal results gives the realized drawdown.
   ulong    ids[];
   double   nets[];
   double   commissions[];
   ulong    entry_orders[];
   double   entry_prices[];
   datetime entry_times[];
   datetime exit_times[];
   int      exit_kinds[];     // 0 open, 1 stop loss, 2 take profit, 3 closed by the EA, 4 other
   double   equity       = 0.0;
   double   peak         = 0.0;
   double   max_drawdown = 0.0;
   int      deals_total  = HistoryDealsTotal();
   for(int index = 0; index < deals_total; index++)
   {
      ulong deal = HistoryDealGetTicket(index);
      if(deal == 0 || (ulong)HistoryDealGetInteger(deal, DEAL_MAGIC) != InpMagicNumber ||
         HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol)
         continue;

      ulong position_id = (ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID);
      int slot = -1;
      for(int search = ArraySize(ids) - 1; search >= 0; search--)
      {
         if(ids[search] == position_id)
         {
            slot = search;
            break;
         }
      }
      if(slot < 0)
      {
         slot = ArraySize(ids);
         ArrayResize(ids, slot + 1);
         ArrayResize(nets, slot + 1);
         ArrayResize(commissions, slot + 1);
         ArrayResize(entry_orders, slot + 1);
         ArrayResize(entry_prices, slot + 1);
         ArrayResize(entry_times, slot + 1);
         ArrayResize(exit_times, slot + 1);
         ArrayResize(exit_kinds, slot + 1);
         ids[slot]          = position_id;
         nets[slot]         = 0.0;
         commissions[slot]  = 0.0;
         entry_orders[slot] = 0;
         entry_prices[slot] = 0.0;
         entry_times[slot]  = 0;
         exit_times[slot]   = 0;
         exit_kinds[slot]   = 0;
      }
      double deal_net = DealNetResult(deal);
      nets[slot]        += deal_net;
      commissions[slot] += HistoryDealGetDouble(deal, DEAL_COMMISSION) + HistoryDealGetDouble(deal, DEAL_FEE);
      equity            += deal_net;
      peak               = MathMax(peak, equity);
      max_drawdown       = MathMax(max_drawdown, peak - equity);

      datetime deal_time = (datetime)HistoryDealGetInteger(deal, DEAL_TIME);
      ENUM_DEAL_ENTRY entry_type = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal, DEAL_ENTRY);
      if(entry_type == DEAL_ENTRY_IN && entry_orders[slot] == 0)
      {
         entry_orders[slot] = (ulong)HistoryDealGetInteger(deal, DEAL_ORDER);
         entry_prices[slot] = HistoryDealGetDouble(deal, DEAL_PRICE);
         entry_times[slot]  = deal_time;
      }
      else if(entry_type == DEAL_ENTRY_OUT || entry_type == DEAL_ENTRY_OUT_BY || entry_type == DEAL_ENTRY_INOUT)
      {
         ENUM_DEAL_REASON exit_reason = (ENUM_DEAL_REASON)HistoryDealGetInteger(deal, DEAL_REASON);
         exit_times[slot] = deal_time;
         if(exit_reason == DEAL_REASON_SL)
            exit_kinds[slot] = 1;
         else if(exit_reason == DEAL_REASON_TP)
            exit_kinds[slot] = 2;
         else if(exit_reason == DEAL_REASON_EXPERT)
            exit_kinds[slot] = 3;
         else
            exit_kinds[slot] = 4;
      }
   }
   // Index 0 = untagged; setups 1-5 (T0, T1, T2, R, X); sessions 1-4 (ASIA, LON, NY, LATE).
   string setup_names[6]    = {"untagged", "T0", "T1", "T2", "R", "X"};
   string session_names[5]  = {"untagged", "ASIA", "LON", "NY", "LATE"};
   int    setup_trades[6]   = {0, 0, 0, 0, 0, 0};
   int    setup_wins[6]     = {0, 0, 0, 0, 0, 0};
   double setup_net[6]      = {0.0, 0.0, 0.0, 0.0, 0.0, 0.0};
   int    session_trades[5] = {0, 0, 0, 0, 0};
   int    session_wins[5]   = {0, 0, 0, 0, 0};
   double session_net[5]    = {0.0, 0.0, 0.0, 0.0, 0.0};
   int    exit_counts[5]    = {0, 0, 0, 0, 0};
   double exit_net[5]       = {0.0, 0.0, 0.0, 0.0, 0.0};
   int    scratch_count     = 0;
   double scratch_net       = 0.0;
   int    slippage_count    = 0;
   double slippage_sum      = 0.0;
   double hold_minutes[];
   int    in_window         = 0;
   int    trades            = 0;
   int    wins              = 0;
   double net_total         = 0.0;
   double gross_profit      = 0.0;
   double gross_loss        = 0.0;
   double commission_total  = 0.0;

   datetime day0      = StartOfDay(g_runStart);
   int      day_count = (int)((StartOfDay(now) - day0) / 86400) + 1;
   if(day_count < 1)
      day_count = 1;
   int    day_entries[];
   double day_net[];
   ArrayResize(day_entries, day_count);
   ArrayResize(day_net, day_count);
   ArrayInitialize(day_entries, 0);
   ArrayInitialize(day_net, 0.0);
   for(int slot = 0; slot < ArraySize(ids); slot++)
   {
      if(exit_kinds[slot] == 0)
         continue;

      string comment = (entry_orders[slot] > 0) ? HistoryOrderGetString(entry_orders[slot], ORDER_COMMENT) : "";
      int setup_index = 0;
      for(int setup = 1; setup <= SETUP_COUNT; setup++)
      {
         if(StringFind(comment, "-" + SetupTag(setup) + "-") >= 0)
         {
            setup_index = setup;
            break;
         }
      }
      int session_index = 0;
      for(int session = 1; session <= 4; session++)
      {
         if(StringFind(comment, "-" + session_names[session]) >= 0)
         {
            session_index = session;
            break;
         }
      }

      double net     = nets[slot];
      bool   win     = (net > 0.0);
      bool   scratch = (exit_kinds[slot] == 1 && ContainsUlong(g_breakevenIds, ids[slot]));
      trades++;
      net_total        += net;
      commission_total += commissions[slot];
      setup_trades[setup_index]++;
      setup_net[setup_index] += net;
      session_trades[session_index]++;
      session_net[session_index] += net;
      if(win)
      {
         wins++;
         gross_profit += net;
         setup_wins[setup_index]++;
         session_wins[session_index]++;
      }
      else
         gross_loss -= net;

      // Entry slippage: fill price versus the stop-order price (positive = worse than requested).
      if(entry_prices[slot] > 0.0)
      {
         double requested = HistoryOrderGetDouble(entry_orders[slot], ORDER_PRICE_OPEN);
         if(requested > 0.0)
         {
            bool is_buy = ((ENUM_ORDER_TYPE)HistoryOrderGetInteger(entry_orders[slot], ORDER_TYPE) ==
                           ORDER_TYPE_BUY_STOP);
            slippage_count++;
            slippage_sum += is_buy ? entry_prices[slot] - requested : requested - entry_prices[slot];
         }
      }

      if(scratch)
      {
         scratch_count++;
         scratch_net += net;
      }
      else
      {
         exit_counts[exit_kinds[slot]]++;
         exit_net[exit_kinds[slot]] += net;
      }

      if(entry_times[slot] > 0 && exit_times[slot] >= entry_times[slot])
      {
         double minutes = (double)((long)exit_times[slot] - (long)entry_times[slot]) / 60.0;
         int size = ArraySize(hold_minutes);
         ArrayResize(hold_minutes, size + 1);
         hold_minutes[size] = minutes;
         if(minutes >= 10.0 && minutes <= 25.0)
            in_window++;
      }
      int entry_day = (int)((StartOfDay(entry_times[slot]) - day0) / 86400);
      if(entry_day >= 0 && entry_day < day_count)
         day_entries[entry_day]++;
      int exit_day = (int)((StartOfDay(exit_times[slot]) - day0) / 86400);
      if(exit_day >= 0 && exit_day < day_count)
         day_net[exit_day] += net;
   }

   int    weekday_counts[];
   int    weekdays  = 0;
   double worst_day = 0.0;
   for(int day = 0; day < day_count; day++)
   {
      if(day_net[day] < worst_day)
         worst_day = day_net[day];
      datetime day_time = day0 + day * 86400;
      MqlDateTime day_parts;
      TimeToStruct(day_time, day_parts);
      if(day_parts.day_of_week == 0 || day_parts.day_of_week == 6)
         continue;
      ArrayResize(weekday_counts, weekdays + 1);
      weekday_counts[weekdays] = day_entries[day];
      weekdays++;
   }
   int day_min    = 0;
   int day_median = 0;
   int day_max    = 0;
   if(weekdays > 0)
   {
      ArraySort(weekday_counts);
      day_min    = weekday_counts[0];
      day_median = weekday_counts[weekdays / 2];
      day_max    = weekday_counts[weekdays - 1];
   }
   int    held        = ArraySize(hold_minutes);
   double hold_median = 0.0;
   double hold_mean   = 0.0;
   double hold_max    = 0.0;
   if(held > 0)
   {
      ArraySort(hold_minutes);
      hold_median = hold_minutes[held / 2];
      hold_max    = hold_minutes[held - 1];
      for(int k = 0; k < held; k++)
         hold_mean += hold_minutes[k] / held;
   }

   string currency = AccountInfoString(ACCOUNT_CURRENCY);
   PrintFormat("AegisIntraday results this run (magic %I64u): %d closed trades, %d wins (%.1f%%), net %.2f %s, "
               "profit factor %.2f, max drawdown %.2f, worst day %.2f | %d weekdays = %.2f trades/day "
               "(min %d, median %d, max %d per day)",
               InpMagicNumber, trades, wins, trades > 0 ? 100.0 * wins / trades : 0.0, net_total, currency,
               gross_loss > 0.0 ? gross_profit / gross_loss : 0.0, max_drawdown, worst_day,
               weekdays, weekdays > 0 ? (double)trades / weekdays : 0.0, day_min, day_median, day_max);
   for(int setup = 1; setup <= SETUP_COUNT; setup++)
      PrintFormat("AegisIntraday   Setup %s: %d trades, %d wins (%.1f%%), net %.2f", setup_names[setup],
                  setup_trades[setup], setup_wins[setup],
                  setup_trades[setup] > 0 ? 100.0 * setup_wins[setup] / setup_trades[setup] : 0.0, setup_net[setup]);
   for(int session = 1; session <= 4; session++)
      PrintFormat("AegisIntraday   Session %s: %d trades, %d wins (%.1f%%), net %.2f", session_names[session],
                  session_trades[session], session_wins[session],
                  session_trades[session] > 0 ? 100.0 * session_wins[session] / session_trades[session] : 0.0,
                  session_net[session]);
   if(setup_trades[0] > 0 || session_trades[0] > 0)
      PrintFormat("AegisIntraday   Untagged trades: %d by setup, %d by session", setup_trades[0], session_trades[0]);
   PrintFormat("AegisIntraday   Exits: take profit %d (net %.2f), stop loss %d (net %.2f), breakeven scratch %d "
               "(net %.2f), closed by EA %d (net %.2f), other %d (net %.2f)",
               exit_counts[2], exit_net[2], exit_counts[1], exit_net[1], scratch_count, scratch_net,
               exit_counts[3], exit_net[3], exit_counts[4], exit_net[4]);
   PrintFormat("AegisIntraday   Holding time: median %.1f min, average %.1f min, longest %.0f min; "
               "%d of %d trades (%.0f%%) closed in 10-25 min",
               hold_median, hold_mean, hold_max, in_window, held, held > 0 ? 100.0 * in_window / held : 0.0);

   double tick_size     = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tick_value    = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double slippage_cost = (tick_size > 0.0) ? slippage_sum * tick_value / tick_size * InpFixedLots : 0.0;
   double spread_avg    = (g_fillCount > 0) ? g_fillSpreadSum / g_fillCount : 0.0;
   double slippage_avg  = (slippage_count > 0) ? slippage_sum / slippage_count : 0.0;
   double costs         = -commission_total + g_spreadCost + slippage_cost;
   PrintFormat("AegisIntraday   Costs: commission %.2f + spread at entry %.2f (average $%.3f) + entry slippage %.2f "
               "(average $%.3f) = %.2f %s, %.2f per trade; net before these costs %.2f",
               -commission_total, g_spreadCost, spread_avg, slippage_cost, slippage_avg, costs, currency,
               trades > 0 ? costs / trades : 0.0, net_total + costs);
}

//+------------------------------------------------------------------+
//| Shared infrastructure copied unchanged from v1.5                 |
//| (AegisGoldTrendPullback, 0 errors / 0 warnings); only the log    |
//| prefix is renamed: sessions, market close, shield, margin, orders|
//+------------------------------------------------------------------+
bool ContainsUlong(const ulong &values[], const ulong value)
{
   for(int index = 0; index < ArraySize(values); index++)
      if(values[index] == value)
         return true;
   return false;
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
   PrintFormat("AegisIntraday trade sessions (server time): %s", text);
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

int NthSunday(const int year, const int month, const int occurrence)
{
   MqlDateTime parts;
   TimeToStruct(MakeDateTime(year, month, 1, 12, 0), parts);
   int first_sunday = 1 + ((7 - parts.day_of_week) % 7);
   return first_sunday + (occurrence - 1) * 7;
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

double DealNetResult(const ulong deal_ticket)
{
   return HistoryDealGetDouble(deal_ticket, DEAL_PROFIT) +
          HistoryDealGetDouble(deal_ticket, DEAL_COMMISSION) +
          HistoryDealGetDouble(deal_ticket, DEAL_SWAP) +
          HistoryDealGetDouble(deal_ticket, DEAL_FEE);
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

void SetStatus(const string status)
{
   if(status != g_status)
   {
      g_status = status;
      Print("AegisIntraday: ", status);
   }
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
   PrintFormat("AegisIntraday margin: %.2f lot at %.2f needs %.2f %s. At the %.0f%% margin-level gate, one position "
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

   PrintFormat("AegisIntraday initialized on %s: account=%s contract=%.2f tickSize=%.5f tickValue=%.5f digits=%d stopsLevel=%d volumeMin=%.3f volumeStep=%.3f",
               _Symbol, AccountInfoString(ACCOUNT_CURRENCY), contract_size, tick_size,
               tick_value, (int)digits, (int)stops_level, volume_min, volume_step);
}
