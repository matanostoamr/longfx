#property strict
#property version   "1.00"
#property description "Aegis XAU/USD M15 regime and M5 Keltner-RSI pullback EA"

#include <Trade/Trade.mqh>

CTrade Trade;

enum SignalDirection
{
   SIGNAL_SHORT = -1,
   SIGNAL_NONE  = 0,
   SIGNAL_LONG  = 1
};

input group "Identity and account safety"
input ulong  InpMagicNumber                  = 26092801;
input bool   InpRequireGBPAccount             = true;
input double InpFixedLots                     = 0.02;
input double InpMinimumProjectedMarginLevel   = 120.0;

input group "Trend and pullback"
input int    InpM15FastEmaPeriod              = 50;
input int    InpM15SlowEmaPeriod              = 200;
input int    InpM15SlopeLookbackBars          = 2;
input int    InpM5KeltnerEmaPeriod            = 20;
input int    InpM5AtrPeriod                   = 20;
input double InpKeltnerAtrMultiplier          = 1.50;
input int    InpRsiPeriod                     = 2;
input double InpRsiLongThreshold              = 10.0;
input double InpRsiShortThreshold             = 90.0;
input double InpMaxConfirmationRangeAtr       = 1.50;

input group "Entry, stop and target"
input double InpEntryBufferPrice              = 0.05;
input double InpMaxEntryAdjustmentPrice       = 0.20;
input int    InpPendingExpiryBars             = 2;
input int    InpSwingLookbackBars             = 12;
input double InpSwingAtrBuffer                = 0.15;
input double InpMinimumStopPrice              = 4.00;
input double InpMaximumStopPrice              = 5.00;
input double InpRewardMultiple                = 1.40;
input double InpMinimumTargetPrice            = 6.00;
input double InpMaximumTargetPrice            = 6.50;
input int    InpMaximumDeviationPoints        = 20;

input group "Sessions"
input int    InpLondonStartHour               = 8;
input int    InpLondonEndHour                 = 12;
input int    InpNewYorkStartHour              = 8;
input int    InpNewYorkEndHour                = 12;
input bool   InpTesterUsesPepperstoneServer   = true;
input int    InpFallbackServerUtcOffsetHours  = 2;

input group "Abnormal-condition filters"
input double InpMaximumSpreadPrice            = 0.30;
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
input int    InpMaximumDailyEntries           = 5;
input int    InpMaximumDailyLosses            = 2;
input double InpMaximumDailyDrawdown          = 14.0;

int      g_m5EmaHandle       = INVALID_HANDLE;
int      g_m5AtrHandle       = INVALID_HANDLE;
int      g_m5RsiHandle       = INVALID_HANDLE;
int      g_m15FastEmaHandle  = INVALID_HANDLE;
int      g_m15SlowEmaHandle  = INVALID_HANDLE;
datetime g_lastM5BarTime     = 0;
datetime g_dailyStart        = 0;
int      g_dailyEntries      = 0;
int      g_dailyLosses       = 0;
double   g_dailyNet          = 0.0;
bool     g_dailyHalted       = false;
string   g_status            = "Initializing";

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

   if(g_m5EmaHandle == INVALID_HANDLE || g_m5AtrHandle == INVALID_HANDLE ||
      g_m5RsiHandle == INVALID_HANDLE || g_m15FastEmaHandle == INVALID_HANDLE ||
      g_m15SlowEmaHandle == INVALID_HANDLE)
   {
      PrintFormat("Initialization failed: unable to create indicator handles. Error %d.", GetLastError());
      ReleaseIndicators();
      return INIT_FAILED;
   }

   Trade.SetExpertMagicNumber(InpMagicNumber);
   Trade.SetDeviationInPoints(InpMaximumDeviationPoints);
   Trade.SetTypeFillingBySymbol(_Symbol);
   Trade.SetAsyncMode(false);

   g_lastM5BarTime = iTime(_Symbol, PERIOD_M5, 0);
   RefreshDailyStats();
   LogSymbolConfiguration();

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
   ReleaseIndicators();
   Comment("");
}

//+------------------------------------------------------------------+
//| Tick handler                                                     |
//+------------------------------------------------------------------+
void OnTick()
{
   RefreshDailyStatsIfNeeded();

   if(g_dailyHalted)
      CancelOwnPendingOrders("daily halt");
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
      InpKeltnerAtrMultiplier <= 0.0)
      valid = false;
   if(InpRsiLongThreshold <= 0.0 || InpRsiLongThreshold >= 50.0 ||
      InpRsiShortThreshold <= 50.0 || InpRsiShortThreshold >= 100.0)
      valid = false;
   if(InpMinimumStopPrice <= 0.0 || InpMaximumStopPrice < InpMinimumStopPrice ||
      InpMinimumTargetPrice <= 0.0 || InpMaximumTargetPrice < InpMinimumTargetPrice ||
      InpRewardMultiple <= 0.0)
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
//+------------------------------------------------------------------+
void EvaluateNewM5Bar()
{
   RefreshDailyStats();
   CancelExpiredOwnPendingOrders();

   if(g_dailyHalted)
   {
      SetStatus(DailyHaltDescription());
      CancelOwnPendingOrders("daily halt");
      return;
   }

   if(HasAnyPositionForSymbol())
   {
      SetStatus("Existing symbol position; no overlapping exposure");
      return;
   }

   if(HasAnyPendingOrderForSymbol())
   {
      SetStatus("Existing symbol pending order; waiting for resolution");
      return;
   }

   if(!IsEntrySession())
   {
      SetStatus("Outside London/New York entry windows");
      return;
   }

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick) || tick.ask <= 0.0 || tick.bid <= 0.0)
   {
      SetStatus("No valid symbol tick");
      return;
   }

   double spread_price = tick.ask - tick.bid;
   if(spread_price > InpMaximumSpreadPrice)
   {
      SetStatus(StringFormat("Spread blocked: %.3f > %.3f", spread_price, InpMaximumSpreadPrice));
      return;
   }

   MqlRates rates[];
   double ema[];
   double atr[];
   double rsi[];
   double m15_fast[];
   double m15_slow[];
   if(!LoadStrategyData(rates, ema, atr, rsi, m15_fast, m15_slow))
   {
      SetStatus("Waiting for sufficient indicator history");
      return;
   }

   if(IsVolatilityShock(rates, atr))
   {
      SetStatus("Volatility-shock cooldown active");
      return;
   }

   if(IsRunawayMarket(rates, ema, atr))
   {
      SetStatus("Runaway-trend filter active");
      return;
   }

   SignalDirection signal = BuildSignal(rates, ema, atr, rsi, m15_fast, m15_slow);
   if(signal == SIGNAL_NONE)
   {
      SetStatus("No qualified closed-candle setup");
      return;
   }

   if(IsHighImpactUsdNewsWindow())
   {
      SetStatus("High-impact USD news window or unavailable calendar");
      return;
   }

   PlaceProtectedPendingOrder(signal, rates, atr, tick);
}

//+------------------------------------------------------------------+
//| Load closed/current M5 and M15 values                             |
//+------------------------------------------------------------------+
bool LoadStrategyData(MqlRates &rates[], double &ema[], double &atr[], double &rsi[],
                      double &m15_fast[], double &m15_slow[])
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

   if(BarsCalculated(g_m5EmaHandle) < needed_m5 || BarsCalculated(g_m5AtrHandle) < needed_m5 ||
      BarsCalculated(g_m5RsiHandle) < needed_m5 || BarsCalculated(g_m15FastEmaHandle) < needed_m15 ||
      BarsCalculated(g_m15SlowEmaHandle) < needed_m15)
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

   return (atr[1] > 0.0 && atr[2] > 0.0);
}

//+------------------------------------------------------------------+
//| Build a direction from the locked closed-candle rules            |
//+------------------------------------------------------------------+
SignalDirection BuildSignal(const MqlRates &rates[], const double &ema[], const double &atr[],
                            const double &rsi[], const double &m15_fast[], const double &m15_slow[])
{
   int slope_shift = 1 + InpM15SlopeLookbackBars;
   bool long_regime  = (m15_fast[1] > m15_slow[1] && m15_fast[1] > m15_fast[slope_shift]);
   bool short_regime = (m15_fast[1] < m15_slow[1] && m15_fast[1] < m15_fast[slope_shift]);

   double lower_exhaustion = ema[2] - InpKeltnerAtrMultiplier * atr[2];
   double upper_exhaustion = ema[2] + InpKeltnerAtrMultiplier * atr[2];
   double lower_confirm    = ema[1] - InpKeltnerAtrMultiplier * atr[1];
   double upper_confirm    = ema[1] + InpKeltnerAtrMultiplier * atr[1];
   double confirmation_range = TrueRange(rates, 1);

   double confirmation_midpoint = (rates[1].high + rates[1].low) * 0.5;

   bool normal_confirmation = (confirmation_range <= InpMaxConfirmationRangeAtr * atr[1]);

   bool long_setup = long_regime && normal_confirmation &&
                     rates[2].low <= lower_exhaustion && rsi[2] <= InpRsiLongThreshold &&
                     rates[1].close > lower_confirm && rates[1].close > rates[1].open &&
                     rates[1].close >= confirmation_midpoint && rates[1].close > rates[2].close;

   bool short_setup = short_regime && normal_confirmation &&
                      rates[2].high >= upper_exhaustion && rsi[2] >= InpRsiShortThreshold &&
                      rates[1].close < upper_confirm && rates[1].close < rates[1].open &&
                      rates[1].close <= confirmation_midpoint && rates[1].close < rates[2].close;

   if(long_setup && !short_setup)
      return SIGNAL_LONG;
   if(short_setup && !long_setup)
      return SIGNAL_SHORT;
   return SIGNAL_NONE;
}

//+------------------------------------------------------------------+
//| Place a broker-side protected stop entry                         |
//+------------------------------------------------------------------+
void PlaceProtectedPendingOrder(const SignalDirection signal, const MqlRates &rates[],
                                const double &atr[], const MqlTick &tick)
{
   ENUM_SYMBOL_TRADE_MODE trade_mode = (ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
   if((signal == SIGNAL_LONG && trade_mode == SYMBOL_TRADE_MODE_SHORTONLY) ||
      (signal == SIGNAL_SHORT && trade_mode == SYMBOL_TRADE_MODE_LONGONLY))
   {
      SetStatus("Broker symbol direction restriction blocked setup");
      return;
   }

   double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double point     = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(tick_size <= 0.0 || point <= 0.0)
   {
      SetStatus("Invalid symbol tick-size metadata");
      return;
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
         return;
      }
   }
   else
   {
      desired_entry = RoundDownToTick(rates[1].low - InpEntryBufferPrice);
      entry = RoundDownToTick(MathMin(desired_entry, tick.bid - minimum_gap));
      if(desired_entry - entry > InpMaxEntryAdjustmentPrice + tick_size * 0.5)
      {
         SetStatus("Sell trigger already missed beyond chase allowance");
         return;
      }
   }

   double swing_price = 0.0;
   bool swing_found = (signal == SIGNAL_LONG)
                      ? FindMostRecentSwingLow(rates, swing_price)
                      : FindMostRecentSwingHigh(rates, swing_price);
   if(!swing_found)
   {
      SetStatus("No confirmed structural swing in lookback");
      return;
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
      return;
   }

   if(structural_distance > InpMaximumStopPrice + tick_size * 0.5)
   {
      SetStatus(StringFormat("Structure needs %.2f stop; maximum is %.2f",
                             structural_distance, InpMaximumStopPrice));
      return;
   }

   double stop_distance = MathMax(structural_distance, InpMinimumStopPrice);
   double stop_loss = 0.0;
   if(signal == SIGNAL_LONG)
      stop_loss = RoundDownToTick(entry - stop_distance);
   else
      stop_loss = RoundUpToTick(entry + stop_distance);

   stop_distance = MathAbs(entry - stop_loss);
   if(stop_distance > InpMaximumStopPrice + tick_size)
   {
      SetStatus("Tick normalization pushed stop beyond maximum");
      return;
   }

   double target_distance = Clamp(stop_distance * InpRewardMultiple,
                                  InpMinimumTargetPrice, InpMaximumTargetPrice);
   double take_profit = (signal == SIGNAL_LONG)
                        ? RoundUpToTick(entry + target_distance)
                        : RoundDownToTick(entry - target_distance);

   if(MathAbs(entry - stop_loss) < minimum_gap || MathAbs(take_profit - entry) < minimum_gap)
   {
      SetStatus("Broker minimum stop distance rejected SL/TP geometry");
      return;
   }

   if(!HasSufficientMargin(signal, entry))
      return;

   ENUM_ORDER_TYPE_TIME order_time = ORDER_TIME_GTC;
   datetime expiration = 0;
   long expiration_modes = SymbolInfoInteger(_Symbol, SYMBOL_EXPIRATION_MODE);
   if((expiration_modes & SYMBOL_EXPIRATION_SPECIFIED) == SYMBOL_EXPIRATION_SPECIFIED)
   {
      order_time = ORDER_TIME_SPECIFIED;
      expiration = iTime(_Symbol, PERIOD_M5, 0) + InpPendingExpiryBars * PeriodSeconds(PERIOD_M5);
   }

   string comment = "AegisGold-v1";
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
      return;
   }

   SetStatus(StringFormat("%s stop placed: entry %.3f SL %.3f TP %.3f",
                          signal == SIGNAL_LONG ? "Buy" : "Sell", entry, stop_loss, take_profit));
   PrintFormat("Protected %s stop accepted. order=%I64u volume=%.2f entry=%.3f sl=%.3f tp=%.3f SLdist=%.3f TPdist=%.3f",
               signal == SIGNAL_LONG ? "buy" : "sell", Trade.ResultOrder(), InpFixedLots,
               entry, stop_loss, take_profit, MathAbs(entry - stop_loss), MathAbs(take_profit - entry));
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
//| Session filter with UK and US daylight-saving rules              |
//+------------------------------------------------------------------+
bool IsEntrySession()
{
   datetime utc = CurrentUtcTime();
   MqlDateTime utc_parts;
   TimeToStruct(utc, utc_parts);
   if(utc_parts.day_of_week == 0 || utc_parts.day_of_week == 6)
      return false;

   int london_offset = IsUkDaylightSaving(utc) ? 1 : 0;
   int new_york_offset = IsUsDaylightSaving(utc) ? -4 : -5;

   datetime london_local = utc + london_offset * 3600;
   datetime new_york_local = utc + new_york_offset * 3600;
   return IsHourWindow(london_local, InpLondonStartHour, InpLondonEndHour) ||
          IsHourWindow(new_york_local, InpNewYorkStartHour, InpNewYorkEndHour);
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

   for(int position_index = 0; position_index < ArraySize(closed_position_ids); position_index++)
   {
      double position_net = 0.0;
      bool has_exit = false;
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
            has_exit = true;
      }
      if(has_exit && position_net < 0.0)
         g_dailyLosses++;
   }

   g_dailyHalted = (g_dailyEntries >= InpMaximumDailyEntries ||
                    g_dailyLosses >= InpMaximumDailyLosses ||
                    g_dailyNet <= -InpMaximumDailyDrawdown);
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
   if(g_dailyLosses >= InpMaximumDailyLosses)
      return StringFormat("Daily halt: %d losses", g_dailyLosses);
   if(g_dailyNet <= -InpMaximumDailyDrawdown)
      return StringFormat("Daily halt: net P/L %.2f", g_dailyNet);
   if(g_dailyEntries >= InpMaximumDailyEntries)
      return StringFormat("Daily halt: %d entries", g_dailyEntries);
   return "Daily risk halt";
}

//+------------------------------------------------------------------+
//| Exposure and pending-order helpers                               |
//+------------------------------------------------------------------+
bool HasAnyPositionForSymbol()
{
   for(int index = 0; index < PositionsTotal(); index++)
   {
      ulong ticket = PositionGetTicket(index);
      if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol)
         return true;
   }
   return false;
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

   g_m5EmaHandle = g_m5AtrHandle = g_m5RsiHandle = INVALID_HANDLE;
   g_m15FastEmaHandle = g_m15SlowEmaHandle = INVALID_HANDLE;
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

   string dashboard = StringFormat(
      "Aegis Gold Trend-Pullback v1.00\n"
      "Symbol: %s | Lots: %.2f | Spread: %.3f\n"
      "Today: entries %d/%d | losses %d/%d | net %.2f %s\n"
      "Halted: %s | Status: %s",
      _Symbol, InpFixedLots, spread,
      g_dailyEntries, InpMaximumDailyEntries,
      g_dailyLosses, InpMaximumDailyLosses,
      g_dailyNet, AccountInfoString(ACCOUNT_CURRENCY),
      g_dailyHalted ? "YES" : "NO", g_status);
   Comment(dashboard);
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
