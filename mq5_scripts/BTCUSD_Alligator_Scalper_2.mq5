//+------------------------------------------------------------------+
//|                   BTCUSD Alligator Early Entry Scalper            |
//|              Early Entry Strategy - Alligator Awakening           |
//|               Copyright 2025 - free to use / modify               |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025"
#property version "2.00"
#property strict

//---------------  USER INPUTS  ---------------------------//
// Risk Management - Percentage-Based System
input double RISK_PER_TRADE_PCT = 2.0; // % equity risk per trade (e.g., 2% of $10k = $200 risk)
input double TAKE_PROFIT_MULT = 2.0;   // Profit target multiplier (2.0 = 2:1 risk:reward ratio)
input int MAX_TRADES_PER_DAY = 100;    // Maximum trades per day

// Alligator Settings (Williams Alligator)
input int JAW_PERIOD = 13;                             // Jaw period (Blue line - slowest)
input int JAW_SHIFT = 8;                               // Jaw shift
input int TEETH_PERIOD = 8;                            // Teeth period (Red line - medium)
input int TEETH_SHIFT = 5;                             // Teeth shift
input int LIPS_PERIOD = 5;                             // Lips period (Green line - fastest)
input int LIPS_SHIFT = 3;                              // Lips shift
input ENUM_MA_METHOD MA_METHOD = MODE_SMMA;            // Moving average method
input ENUM_APPLIED_PRICE APPLIED_PRICE = PRICE_MEDIAN; // Applied price

// Early Entry Strategy Parameters
input int SLEEPING_WINDOW_SECONDS = 300;               // Time window required for alligator to be sleeping (5 minutes)
input double ALLIGATOR_CLOSED_LINES_ATR_PERCENTAGE = 10.0; // How close lines must be for "sleeping" (10% of ATR)
input double ATR_PRICE_THRESHOLD_PERCENT = 200.0;      // Price movement required to trigger entry (200% = 2.0 * ATR)
input int CONFIRMATION_WINDOW_SECONDS = 120;           // Time to achieve line separation or exit trade
input double LINE_SEPARATE_ATR_PERCENTAGE = 50.0;     // Required line separation % to stay in trade (50% of ATR)

// Risk Management
input int ATR_PERIOD = 14;                        // ATR period for all calculations
input double ATR_STOP_LOSS_MULTIPLIER = 1.0;      // ATR multiplier for stop loss distance
input int SIGNAL_COOLDOWN_SECONDS = 180;         // Cooldown between signals (seconds)

// Visual Settings
input bool SHOW_INFO = true; // Show information panel
input int DEBUG_LEVEL = 2;   // Debug level: 0=none, 1=basic, 2=detailed

//---------------  GLOBAL VARIABLES  ---------------------------//
// Indicator handles
int alligator_handle = INVALID_HANDLE;
int atr_handle = INVALID_HANDLE;

// Position tracking
ulong current_ticket = 0;
int trades_today = 0;
datetime last_trade_date = 0;

// Alligator values
double jaw_current, jaw_previous;     // Blue line (slowest)
double teeth_current, teeth_previous; // Red line (medium)
double lips_current, lips_previous;   // Green line (fastest)

// Price tracking for crossover detection
double price_current, price_previous;

// Early Entry Strategy Variables
datetime alligator_sleep_start = 0;    // When alligator started sleeping
datetime last_signal_time = 0;         // Last signal time for cooldown
bool alligator_is_sleeping = false;    // Current sleeping state
datetime entry_time = 0;               // When we entered a trade
bool monitoring_separation = false;    // Are we monitoring line separation after entry?

// Visual elements for backtesting
int visual_counter = 0;                // Counter for unique object names

// Trade state tracking
enum TradeDirection
{
   NO_TRADE = 0,
   LONG_TRADE = 1,
   SHORT_TRADE = 2
};

TradeDirection current_direction = NO_TRADE;

//+------------------------------------------------------------------+
//| Convert period to string                                         |
//+------------------------------------------------------------------+
string PeriodToString(ENUM_TIMEFRAMES period)
{
   switch (period)
   {
   case PERIOD_M1:
      return "M1";
   case PERIOD_M5:
      return "M5";
   case PERIOD_M15:
      return "M15";
   case PERIOD_M30:
      return "M30";
   case PERIOD_H1:
      return "H1";
   case PERIOD_H4:
      return "H4";
   case PERIOD_D1:
      return "D1";
   case PERIOD_W1:
      return "W1";
   case PERIOD_MN1:
      return "MN1";
   default:
      return "Unknown(" + IntegerToString(period) + ")";
   }
}

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   // Timeframe agnostic - works on any timeframe
   if (DEBUG_LEVEL >= 1)
      Print("Running on timeframe: ", PeriodToString((ENUM_TIMEFRAMES)_Period));

   // Verify symbol
   if (StringFind(_Symbol, "BTC") < 0)
   {
      if (DEBUG_LEVEL >= 1)
         Print("WARNING: This EA is designed for BTCUSD. Current symbol: ", _Symbol);
   }

   // Initialize Alligator indicator
   alligator_handle = iAlligator(_Symbol, _Period, JAW_PERIOD, JAW_SHIFT,
                                 TEETH_PERIOD, TEETH_SHIFT, LIPS_PERIOD, LIPS_SHIFT,
                                 MA_METHOD, APPLIED_PRICE);

   if (alligator_handle == INVALID_HANDLE)
   {
      if (DEBUG_LEVEL >= 1)
         Print("Failed to create Alligator indicator handle. Error: ", GetLastError());
      return (INIT_FAILED);
   }

   // Initialize ATR indicator
   atr_handle = iATR(_Symbol, _Period, ATR_PERIOD);

   if (atr_handle == INVALID_HANDLE)
   {
      if (DEBUG_LEVEL >= 1)
         Print("Failed to create ATR indicator handle. Error: ", GetLastError());
      return (INIT_FAILED);
   }

   // Reset all state variables for clean start
   current_ticket = 0;
   current_direction = NO_TRADE;
   trades_today = 0;
   
   // Reset previous values
   jaw_previous = 0;
   teeth_previous = 0;
   lips_previous = 0;
   price_previous = 0;
   
   // Reset early entry strategy state
   alligator_sleep_start = 0;
   alligator_is_sleeping = false;
   entry_time = 0;
   monitoring_separation = false;
   last_signal_time = 0;

   // Reset daily trade counter if new day
   ResetDailyCounter();

   if (DEBUG_LEVEL >= 1)
   {
      Print("=== BTCUSD Alligator Early Entry EA Initialized ===");
      Print("Timeframe: ", PeriodToString((ENUM_TIMEFRAMES)_Period));
      Print("Strategy: Early Entry - Alligator Awakening");
      Print("Sleeping window: ", SLEEPING_WINDOW_SECONDS, " seconds");
      Print("Lines close threshold: ", ALLIGATOR_CLOSED_LINES_ATR_PERCENTAGE, "% of ATR");
      Print("Price breakout threshold: ", ATR_PRICE_THRESHOLD_PERCENT, "% of ATR");
      Print("Separation confirmation: ", LINE_SEPARATE_ATR_PERCENTAGE, "% of ATR");
      Print("Max trades per day: ", MAX_TRADES_PER_DAY);
      Print("Risk Management: ", RISK_PER_TRADE_PCT, "% of account per trade");
      Print("Risk:Reward Ratio = 1:", TAKE_PROFIT_MULT);
      Print("Stop Loss: ATR(", ATR_PERIOD, ") × ", ATR_STOP_LOSS_MULTIPLIER, " (volatility-adaptive)");
      Print("=====================================================");
   }

   return (INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   // Release indicator handles
   if (alligator_handle != INVALID_HANDLE)
   {
      IndicatorRelease(alligator_handle);
      alligator_handle = INVALID_HANDLE;
   }

   if (atr_handle != INVALID_HANDLE)
   {
      IndicatorRelease(atr_handle);
      atr_handle = INVALID_HANDLE;
   }

   // Clean up visual objects
   CleanupVisualObjects();

   Comment("");
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // Reset daily counter if new day
   ResetDailyCounter();

   // Skip if max trades reached
   if (trades_today >= MAX_TRADES_PER_DAY)
   {
      if (DEBUG_LEVEL >= 1)
      {
         static datetime last_max_log = 0;
         if (TimeCurrent() - last_max_log > 300) // Log every 5 minutes
         {
            Print("Max trades reached today: ", trades_today, "/", MAX_TRADES_PER_DAY);
            last_max_log = TimeCurrent();
         }
      }
      if (SHOW_INFO)
         ShowInfo();
      return;
   }

   // Update Alligator values
   if (!UpdateAlligatorValues())
   {
      if (DEBUG_LEVEL >= 1)
      {
         static datetime last_error_log = 0;
         if (TimeCurrent() - last_error_log > 60) // Log every minute
         {
            Print("Failed to update Alligator values");
            last_error_log = TimeCurrent();
         }
      }
      return;
   }

   // Update price values
   UpdatePriceValues();

   // Monitor alligator sleeping state for early entry strategy
   MonitorAlligatorSleepState();

   // Debug current values (throttled)
   if (DEBUG_LEVEL >= 2)
   {
      static datetime last_debug_log = 0;
      if (TimeCurrent() - last_debug_log > 10) // Log every 10 seconds
      {
         PrintAlligatorStatus();
         last_debug_log = TimeCurrent();
      }
   }

   // Check if we have an open position
   if (current_ticket != 0)
   {
      // Manage existing position
      ManagePosition();
   }
   else
   {
      // Look for new entry signals
      CheckEntrySignals();
   }

   // Update info display (throttled)
   if (SHOW_INFO)
   {
      static datetime last_info_update = 0;
      if (TimeCurrent() - last_info_update > 1) // Update every second
      {
         ShowInfo();
         last_info_update = TimeCurrent();
      }
   }
}

//+------------------------------------------------------------------+
//| Monitor Alligator sleeping state for early entry strategy        |
//+------------------------------------------------------------------+
void MonitorAlligatorSleepState()
{
   // Get current ATR value for threshold calculations
   double atr_buffer[];
   if (CopyBuffer(atr_handle, 0, 0, 1, atr_buffer) <= 0)
   {
      if (DEBUG_LEVEL >= 1)
         Print("Failed to get ATR value for sleep monitoring");
      return;
   }
   double current_atr = atr_buffer[0];
   
   // Calculate line separation thresholds
   double sleep_threshold = current_atr * (ALLIGATOR_CLOSED_LINES_ATR_PERCENTAGE / 100.0);
   
   // Check if lines are close together (alligator sleeping)
   double lips_teeth_gap = MathAbs(lips_current - teeth_current);
   double teeth_jaw_gap = MathAbs(teeth_current - jaw_current);
   double lips_jaw_gap = MathAbs(lips_current - jaw_current);
   
   bool lines_are_close = (lips_teeth_gap <= sleep_threshold && 
                          teeth_jaw_gap <= sleep_threshold && 
                          lips_jaw_gap <= sleep_threshold);
   
   datetime current_time = TimeCurrent();
   
   // Update sleeping state
   if (lines_are_close && !alligator_is_sleeping)
   {
      // Alligator just started sleeping
      alligator_sleep_start = current_time;
      alligator_is_sleeping = true;
      
      if (DEBUG_LEVEL >= 2)
         Print("😴 ALLIGATOR SLEEPING: Lines close together (threshold: ", DoubleToString(sleep_threshold, _Digits), ")");
   }
   else if (!lines_are_close && alligator_is_sleeping)
   {
      // Alligator woke up
      alligator_is_sleeping = false;
      
      if (DEBUG_LEVEL >= 2)
         Print("👁️ ALLIGATOR AWAKENING: Lines separating");
      
      // Reset sleep timer since alligator woke up
      alligator_sleep_start = 0;
   }
   
   // Debug sleeping status (throttled)
   if (DEBUG_LEVEL >= 3)
   {
      static datetime last_sleep_debug = 0;
      if (current_time - last_sleep_debug > 30) // Every 30 seconds
      {
         Print("=== SLEEP STATUS DEBUG ===");
         Print("Lines Close: ", lines_are_close ? "YES" : "NO");
         Print("Sleeping: ", alligator_is_sleeping ? "YES" : "NO");
         Print("Sleep threshold: ", DoubleToString(sleep_threshold, _Digits));
         Print("Lips-Teeth gap: ", DoubleToString(lips_teeth_gap, _Digits));
         Print("Teeth-Jaw gap: ", DoubleToString(teeth_jaw_gap, _Digits));
         Print("Lips-Jaw gap: ", DoubleToString(lips_jaw_gap, _Digits));
         
         if (alligator_is_sleeping && alligator_sleep_start > 0)
         {
            int sleep_duration = (int)(current_time - alligator_sleep_start);
            Print("Sleep duration: ", sleep_duration, " seconds (need ", SLEEPING_WINDOW_SECONDS, ")");
         }
         
         last_sleep_debug = current_time;
      }
   }
}

//+------------------------------------------------------------------+
//| Print Alligator status for debugging                             |
//+------------------------------------------------------------------+
void PrintAlligatorStatus()
{
   Print("=== EARLY ENTRY ALLIGATOR STATUS ===");
   Print("Price: Current=", DoubleToString(price_current, _Digits),
         ", Previous=", DoubleToString(price_previous, _Digits));
   Print("Jaw (Blue): Current=", DoubleToString(jaw_current, _Digits),
         ", Previous=", DoubleToString(jaw_previous, _Digits));
   Print("Teeth (Red): Current=", DoubleToString(teeth_current, _Digits),
         ", Previous=", DoubleToString(teeth_previous, _Digits));
   Print("Lips (Green): Current=", DoubleToString(lips_current, _Digits),
         ", Previous=", DoubleToString(lips_previous, _Digits));

   // Show alligator state
   string state = "";
   if (alligator_is_sleeping)
   {
      int sleep_duration = (int)(TimeCurrent() - alligator_sleep_start);
      state = "SLEEPING (" + IntegerToString(sleep_duration) + " seconds)";
   }
   else
   {
      // Check line alignment for trend direction
      if (lips_current > teeth_current && teeth_current > jaw_current)
         state = "AWAKE - BULLISH (Green>Red>Blue)";
      else if (jaw_current > teeth_current && teeth_current > lips_current)
         state = "AWAKE - BEARISH (Blue>Red>Green)";
      else
         state = "AWAKE - MIXED SIGNALS";
   }
   Print("Alligator State: ", state);
   
   // Show position status if in trade
   if (current_ticket != 0 && monitoring_separation)
   {
      int time_in_trade = (int)(TimeCurrent() - entry_time);
      int time_remaining = CONFIRMATION_WINDOW_SECONDS - time_in_trade;
      Print("Position Status: Monitoring separation (", time_remaining, " seconds remaining)");
   }
}

//+------------------------------------------------------------------+
//| Update Alligator indicator values                                |
//+------------------------------------------------------------------+
bool UpdateAlligatorValues()
{
   double jaw_buffer[], teeth_buffer[], lips_buffer[];

   // Get current and previous values for each line
   if (CopyBuffer(alligator_handle, 0, 0, 3, jaw_buffer) <= 0) // Jaw (Blue)
      return false;
   if (CopyBuffer(alligator_handle, 1, 0, 3, teeth_buffer) <= 0) // Teeth (Red)
      return false;
   if (CopyBuffer(alligator_handle, 2, 0, 3, lips_buffer) <= 0) // Lips (Green)
      return false;

   // Store previous values
   jaw_previous = jaw_current;
   teeth_previous = teeth_current;
   lips_previous = lips_current;

   // Update current values (latest indicator values)
   jaw_current = jaw_buffer[0];     // Blue line (slowest)
   teeth_current = teeth_buffer[0]; // Red line (medium)
   lips_current = lips_buffer[0];   // Green line (fastest)

   return true;
}

//+------------------------------------------------------------------+
//| Update price values for crossover detection (CANDLE CLOSES ONLY) |
//+------------------------------------------------------------------+
void UpdatePriceValues()
{
   price_previous = price_current;

   // Use CANDLE CLOSE prices instead of live bid/ask to avoid false signals
   double close_prices[];
   if (CopyClose(_Symbol, _Period, 0, 2, close_prices) >= 2)
   {
      price_current = close_prices[0];     // Current (latest) candle close
      if (price_previous == 0)             // First run
         price_previous = close_prices[1]; // Previous candle close
   }
   else
   {
      // Fallback to live price if candle data unavailable
      price_current = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   }
}

//+------------------------------------------------------------------+
//| Check for early entry signals - Alligator Awakening Strategy    |
//+------------------------------------------------------------------+
void CheckEntrySignals()
{
   // Skip on first few ticks when we don't have previous values
   if (jaw_previous == 0 || teeth_previous == 0 || lips_previous == 0 || price_previous == 0)
   {
      return;
   }

   // Check signal cooldown
   if (TimeCurrent() - last_signal_time < SIGNAL_COOLDOWN_SECONDS)
   {
      if (DEBUG_LEVEL >= 3)
         Print("Signal in cooldown period");
      return;
   }

   // Get current ATR value for threshold calculations
   double atr_buffer[];
   if (CopyBuffer(atr_handle, 0, 0, 1, atr_buffer) <= 0)
   {
      if (DEBUG_LEVEL >= 1)
         Print("Failed to get ATR value for early entry signals");
      return;
   }
   double current_atr = atr_buffer[0];
   
   // Calculate dynamic thresholds based on ATR
   double price_breakout_threshold = current_atr * (ATR_PRICE_THRESHOLD_PERCENT / 100.0);
   
   datetime current_time = TimeCurrent();
   
   // EARLY ENTRY CONDITION 1: Alligator must have been sleeping long enough
   bool alligator_slept_enough = alligator_is_sleeping && 
                                alligator_sleep_start > 0 && 
                                (current_time - alligator_sleep_start >= SLEEPING_WINDOW_SECONDS);
   
   if (!alligator_slept_enough)
   {
      if (DEBUG_LEVEL >= 3)
      {
         static datetime last_sleep_log = 0;
         if (current_time - last_sleep_log > 30)
         {
            if (!alligator_is_sleeping)
               Print("EARLY ENTRY: Alligator not sleeping - waiting for consolidation");
            else if (alligator_sleep_start > 0)
            {
               int sleep_duration = (int)(current_time - alligator_sleep_start);
               Print("EARLY ENTRY: Alligator sleeping for ", sleep_duration, " seconds (need ", SLEEPING_WINDOW_SECONDS, ")");
            }
            last_sleep_log = current_time;
         }
      }
      return;
   }
   
   // Debug early entry analysis
   if (DEBUG_LEVEL >= 2)
   {
      static datetime last_entry_debug = 0;
      if (current_time - last_entry_debug > 5) // Every 5 seconds
      {
         Print("=== EARLY ENTRY ANALYSIS ===");
         Print("Alligator slept enough: YES (", (int)(current_time - alligator_sleep_start), " seconds)");
         Print("Price breakout threshold: ", DoubleToString(price_breakout_threshold, _Digits));
         Print("Current ATR: ", DoubleToString(current_atr, _Digits));
         
         // Show current line positions
         Print("Lines: Jaw=", DoubleToString(jaw_current, _Digits), 
               ", Teeth=", DoubleToString(teeth_current, _Digits),
               ", Lips=", DoubleToString(lips_current, _Digits));
         Print("Price: Current=", DoubleToString(price_current, _Digits),
               ", Previous=", DoubleToString(price_previous, _Digits));
         
         last_entry_debug = current_time;
      }
   }

   // EARLY ENTRY CONDITION 2: Check for bullish awakening breakout
   // Price must cross above ALL three lines with significant momentum
   bool price_above_all_lines = (price_current > jaw_current && 
                                price_current > teeth_current && 
                                price_current > lips_current);
   
   bool price_was_below_or_near_lines = (price_previous <= MathMax(MathMax(jaw_previous, teeth_previous), lips_previous));
   
   bool strong_bullish_breakout = price_above_all_lines && price_was_below_or_near_lines &&
                                 (price_current - MathMax(MathMax(jaw_current, teeth_current), lips_current) >= price_breakout_threshold);
   
   // Check if lines are starting to separate bullishly (Lips > Teeth > Jaw trending)
   bool lines_separating_bullish = (lips_current > teeth_current && teeth_current > jaw_current) &&
                                  (lips_current > lips_previous && teeth_current > teeth_previous);

   // EARLY ENTRY CONDITION 3: Check for bearish awakening breakout  
   // Price must cross below ALL three lines with significant momentum
   bool price_below_all_lines = (price_current < jaw_current && 
                                price_current < teeth_current && 
                                price_current < lips_current);
   
   bool price_was_above_or_near_lines = (price_previous >= MathMin(MathMin(jaw_previous, teeth_previous), lips_previous));
   
   bool strong_bearish_breakout = price_below_all_lines && price_was_above_or_near_lines &&
                                 (MathMin(MathMin(jaw_current, teeth_current), lips_current) - price_current >= price_breakout_threshold);
   
   // Check if lines are starting to separate bearishly (Jaw > Teeth > Lips trending)
   bool lines_separating_bearish = (jaw_current > teeth_current && teeth_current > lips_current) &&
                                  (jaw_current > jaw_previous && teeth_current > teeth_previous);

   // EXECUTE EARLY ENTRY TRADES
   
   bool buy_signal = strong_bullish_breakout && lines_separating_bullish;
   bool sell_signal = strong_bearish_breakout && lines_separating_bearish;
   
   if (buy_signal)
   {
      string buy_reason = "EARLY ENTRY BULLISH AWAKENING: Price breakout above all lines (" + 
                         DoubleToString(price_breakout_threshold, _Digits) + " threshold) + Lines separating bullishly after " +
                         IntegerToString((int)(current_time - alligator_sleep_start)) + " seconds of sleep";
      
      if (DEBUG_LEVEL >= 1)
         Print("🚀 EARLY BUY SIGNAL: ", buy_reason);
      
      // Draw visual indicators for backtesting
      DrawBreakoutBox(alligator_sleep_start, current_time, true);
      DrawBreakoutArrow(current_time, price_current, true);
      DrawThresholdLines(current_time, price_breakout_threshold, true);
      
      ExecuteBuyOrder();
      last_signal_time = current_time;
      entry_time = current_time;
      monitoring_separation = true;
      return;
   }
   
   if (sell_signal)
   {
      string sell_reason = "EARLY ENTRY BEARISH AWAKENING: Price breakout below all lines (" + 
                          DoubleToString(price_breakout_threshold, _Digits) + " threshold) + Lines separating bearishly after " +
                          IntegerToString((int)(current_time - alligator_sleep_start)) + " seconds of sleep";
      
      if (DEBUG_LEVEL >= 1)
         Print("🚀 EARLY SELL SIGNAL: ", sell_reason);
      
      // Draw visual indicators for backtesting
      DrawBreakoutBox(alligator_sleep_start, current_time, false);
      DrawBreakoutArrow(current_time, price_current, false);
      DrawThresholdLines(current_time, price_breakout_threshold, false);
      
      ExecuteSellOrder();
      last_signal_time = current_time;
      entry_time = current_time;
      monitoring_separation = true;
      return;
   }
   
   // Debug why signals didn't trigger (if conditions are close)
   if ((strong_bullish_breakout || strong_bearish_breakout) && DEBUG_LEVEL >= 1)
   {
      Print("=== EARLY ENTRY SIGNAL DEBUG ===");
      
      if (strong_bullish_breakout)
      {
         Print("Strong bullish breakout: YES");
         Print("Lines separating bullish: ", lines_separating_bullish ? "YES" : "NO");
         if (!lines_separating_bullish)
         {
            Print("  Lips>Teeth: ", (lips_current > teeth_current) ? "YES" : "NO");
            Print("  Teeth>Jaw: ", (teeth_current > jaw_current) ? "YES" : "NO");
            Print("  Lips rising: ", (lips_current > lips_previous) ? "YES" : "NO");
            Print("  Teeth rising: ", (teeth_current > teeth_previous) ? "YES" : "NO");
         }
      }
      
      if (strong_bearish_breakout)
      {
         Print("Strong bearish breakout: YES");
         Print("Lines separating bearish: ", lines_separating_bearish ? "YES" : "NO");
         if (!lines_separating_bearish)
         {
            Print("  Jaw>Teeth: ", (jaw_current > teeth_current) ? "YES" : "NO");
            Print("  Teeth>Lips: ", (teeth_current > lips_current) ? "YES" : "NO");
            Print("  Jaw rising: ", (jaw_current > jaw_previous) ? "YES" : "NO");
            Print("  Teeth falling: ", (teeth_current < teeth_previous) ? "YES" : "NO");
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Get ATR value for stop loss calculation                          |
//+------------------------------------------------------------------+
double GetATR()
{
   double atr_buffer[];

   // Get ATR value
   if (CopyBuffer(atr_handle, 0, 0, 1, atr_buffer) <= 0)
   {
      if (DEBUG_LEVEL >= 1)
         Print("Failed to get ATR value, using fallback");
      return 100.0; // Fallback ATR value ($100 for BTCUSD)
   }

   return atr_buffer[0];
}

//+------------------------------------------------------------------+
//| Execute buy order                                                |
//+------------------------------------------------------------------+
void ExecuteBuyOrder()
{
   double entry_price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   // Calculate percentage-based risk amount
   double risk_amount = CalculateRiskAmount();
   double profit_target = risk_amount * TAKE_PROFIT_MULT;

   // Calculate ATR-based stop loss distance
   double atr_value = GetATR();
   double stop_loss_distance = atr_value * ATR_STOP_LOSS_MULTIPLIER;

   // Calculate position size: Risk Amount ÷ Stop Loss Distance
   // Now position size varies based on ATR - tight ATR = bigger position, wide ATR = smaller position
   double point_value = 1.0; // For BTCUSD: 1 point = $1, 1 lot = 1 BTC
   double position_size_btc = risk_amount / (stop_loss_distance * point_value);

   // Check if this position size is safe for the account
   double account_balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double position_value = position_size_btc * entry_price;
   double position_as_percent_of_account = (position_value / account_balance) * 100;

   // Safety check: Don't allow position > 50% of account value
   if (position_as_percent_of_account > 50.0)
   {
      // Reduce position size to be safe
      double max_position_value = account_balance * 0.5; // 50% of account
      position_size_btc = max_position_value / entry_price;

      // Recalculate risk with reduced position
      risk_amount = position_size_btc * stop_loss_distance * point_value;
      // FIX: Take profit should always be based on stop loss distance, not risk amount
      profit_target = stop_loss_distance * TAKE_PROFIT_MULT;

      Print("⚠️ POSITION SIZE REDUCED FOR SAFETY:");
      Print("  Original position would be ", DoubleToString(position_as_percent_of_account, 1), "% of account");
      Print("  Reduced to 50% of account for safety");
      Print("  New risk amount: $", DoubleToString(risk_amount, 2));
      Print("  Take profit maintained at: $", DoubleToString(profit_target, 2), " (", TAKE_PROFIT_MULT, "x SL distance)");
   }

   // Calculate actual prices
   double stop_loss = entry_price - stop_loss_distance;
   double take_profit = entry_price + (profit_target); // Use profit_target directly

   // Validate and adjust stops for broker requirements
   ValidateAndAdjustStops(ORDER_TYPE_BUY, entry_price, stop_loss, take_profit);

   // Recalculate actual distances after broker adjustments
   double actual_sl_distance = entry_price - stop_loss;
   double actual_tp_distance = take_profit - entry_price;

   // Adjust position size if broker changed the stop loss distance
   if (MathAbs(actual_sl_distance - stop_loss_distance) > 1.0)
   {
      position_size_btc = risk_amount / (actual_sl_distance * point_value);
   }

   // Normalize lot size to broker requirements
   double lot_size = NormalizeLotSize(position_size_btc);

   // Calculate final risk and profit with normalized lot size
   double actual_risk = lot_size * actual_sl_distance * point_value;
   double actual_profit = lot_size * actual_tp_distance * point_value;
   position_value = lot_size * entry_price;

   // Debug the corrected calculation
   Print("=== ATR-BASED POSITION SIZING (BUY) ===");
   Print("Account balance: $", DoubleToString(account_balance, 2));
   Print("Risk percentage: ", RISK_PER_TRADE_PCT, "%");
   Print("Target risk amount: $", DoubleToString(CalculateRiskAmount(), 2));
   Print("Target profit amount: $", DoubleToString(CalculateRiskAmount() * TAKE_PROFIT_MULT, 2));
   Print("Entry price: $", DoubleToString(entry_price, 2));
   Print("ATR value: $", DoubleToString(atr_value, 2), " (", ATR_PERIOD, "-period)");
   Print("Stop loss distance: $", DoubleToString(stop_loss_distance, 2), " (= ATR × ", ATR_STOP_LOSS_MULTIPLIER, ")");
   Print("Take profit target: $", DoubleToString(profit_target, 2), " (= ", TAKE_PROFIT_MULT, "x risk)");
   Print("Calculated position size: ", DoubleToString(position_size_btc, 6), " BTC");
   Print("Final lot size: ", DoubleToString(lot_size, 6), " BTC");
   Print("Position value: $", DoubleToString(position_value, 2));
   Print("Position as % of account: ", DoubleToString((position_value / account_balance) * 100, 2), "%");
   Print("Stop loss: $", DoubleToString(stop_loss, 2), " (distance: $", DoubleToString(actual_sl_distance, 2), ")");
   Print("Take profit: $", DoubleToString(take_profit, 2), " (distance: $", DoubleToString(actual_tp_distance, 2), ")");
   Print("Actual dollar risk: $", DoubleToString(actual_risk, 2));
   Print("Actual dollar profit target: $", DoubleToString(actual_profit, 2));
   Print("Actual risk as % of account: ", DoubleToString((actual_risk / account_balance) * 100, 2), "%");
   Print("Reward:Risk ratio: ", DoubleToString(actual_profit / actual_risk, 2), ":1");
   Print("========================================");

   // Enhanced filling mode detection with extensive debugging
   int filling_mode = (int)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);

   // Always print filling mode info for troubleshooting
   Print("=== BUY ORDER FILLING MODE DEBUG ===");
   Print("Symbol: ", _Symbol);
   Print("Broker filling modes (raw): ", filling_mode);
   Print("SYMBOL_FILLING_FOK supported: ", ((filling_mode & SYMBOL_FILLING_FOK) != 0) ? "YES" : "NO");
   Print("SYMBOL_FILLING_IOC supported: ", ((filling_mode & SYMBOL_FILLING_IOC) != 0) ? "YES" : "NO");
   Print("Available filling modes: ", filling_mode);

   MqlTradeRequest request = {};
   MqlTradeResult result = {};

   request.action = TRADE_ACTION_DEAL;
   request.symbol = _Symbol;
   request.volume = lot_size;
   request.type = ORDER_TYPE_BUY;
   request.price = entry_price;
   request.sl = stop_loss;
   request.tp = take_profit;
   request.deviation = GetSymbolSlippage();
   request.magic = 123456;
   request.comment = "Alligator_Buy";

   // Try multiple filling modes - start with IOC which works for BTCUSD (from ADX_Breakout_EA)
   bool order_sent = false;

   // First try: IOC (Immediate or Cancel) - commonly supported for crypto
   Print("Attempting BUY with ORDER_FILLING_IOC (preferred for BTCUSD)");
   request.type_filling = ORDER_FILLING_IOC;

   if (OrderSend(request, result))
   {
      if (result.retcode == TRADE_RETCODE_DONE)
      {
         order_sent = true;
         Print("BUY order SUCCESS with ORDER_FILLING_IOC");
      }
      else
      {
         Print("BUY order FAILED with ORDER_FILLING_IOC: ", result.retcode, " - ", GetTradeErrorDescription(result.retcode));
      }
   }

   // Second try: FOK (Fill or Kill) if IOC failed
   if (!order_sent && (filling_mode & SYMBOL_FILLING_FOK) != 0)
   {
      request.type_filling = ORDER_FILLING_FOK;
      Print("Attempting BUY with ORDER_FILLING_FOK");

      if (OrderSend(request, result))
      {
         if (result.retcode == TRADE_RETCODE_DONE)
         {
            order_sent = true;
            Print("BUY order SUCCESS with ORDER_FILLING_FOK");
         }
         else
         {
            Print("BUY order FAILED with ORDER_FILLING_FOK: ", result.retcode, " - ", GetTradeErrorDescription(result.retcode));
         }
      }
   }

   // Skip third try - SYMBOL_FILLING_RETURN doesn't exist in MQL5

   // Last resort: If IOC and FOK both failed, there's likely a deeper issue
   if (!order_sent)
   {
      Print("*** BUY ORDER: Both IOC and FOK failed. Check broker compatibility or instrument specifications. ***");
   }

   // Process successful order
   if (order_sent && result.retcode == TRADE_RETCODE_DONE)
   {
      current_ticket = result.order;
      current_direction = LONG_TRADE;
      trades_today++;

      if (DEBUG_LEVEL >= 1)
         Print("BUY order executed successfully: Ticket=", current_ticket,
               ", Entry=", DoubleToString(entry_price, _Digits),
               ", SL=", DoubleToString(stop_loss, _Digits),
               ", TP=", DoubleToString(take_profit, _Digits),
               ", Lots=", DoubleToString(lot_size, 2));
   }
   else
   {
      Print("*** ALL BUY ORDER ATTEMPTS FAILED ***");
      Print("Final error: ", result.retcode, " - ", GetTradeErrorDescription(result.retcode));
      Print("Entry price: ", DoubleToString(entry_price, _Digits));
      Print("Stop loss: ", DoubleToString(stop_loss, _Digits));
      Print("Take profit: ", DoubleToString(take_profit, _Digits));
      Print("Lot size: ", DoubleToString(lot_size, 2));
      Print("Slippage: ", GetSymbolSlippage());
   }
}

//+------------------------------------------------------------------+
//| Execute sell order                                               |
//+------------------------------------------------------------------+
void ExecuteSellOrder()
{
   double entry_price = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // Calculate percentage-based risk amount
   double risk_amount = CalculateRiskAmount();
   double profit_target = risk_amount * TAKE_PROFIT_MULT;

   // Calculate ATR-based stop loss distance
   double atr_value = GetATR();
   double stop_loss_distance = atr_value * ATR_STOP_LOSS_MULTIPLIER;

   // Calculate position size: Risk Amount ÷ Stop Loss Distance
   // Now position size varies based on ATR - tight ATR = bigger position, wide ATR = smaller position
   double point_value = 1.0; // For BTCUSD: 1 point = $1, 1 lot = 1 BTC
   double position_size_btc = risk_amount / (stop_loss_distance * point_value);

   // Check if this position size is safe for the account
   double account_balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double position_value = position_size_btc * entry_price;
   double position_as_percent_of_account = (position_value / account_balance) * 100;

   // Safety check: Don't allow position > 50% of account value
   if (position_as_percent_of_account > 50.0)
   {
      // Reduce position size to be safe
      double max_position_value = account_balance * 0.5; // 50% of account
      position_size_btc = max_position_value / entry_price;

      // Recalculate risk with reduced position
      risk_amount = position_size_btc * stop_loss_distance * point_value;
      // FIX: Take profit should always be based on stop loss distance, not risk amount
      profit_target = stop_loss_distance * TAKE_PROFIT_MULT;

      Print("⚠️ POSITION SIZE REDUCED FOR SAFETY:");
      Print("  Original position would be ", DoubleToString(position_as_percent_of_account, 1), "% of account");
      Print("  Reduced to 50% of account for safety");
      Print("  New risk amount: $", DoubleToString(risk_amount, 2));
      Print("  Take profit maintained at: $", DoubleToString(profit_target, 2), " (", TAKE_PROFIT_MULT, "x SL distance)");
   }

   // Calculate actual prices for SELL order
   double stop_loss = entry_price + stop_loss_distance;
   double take_profit = entry_price - profit_target; // Use profit_target directly

   // Validate and adjust stops for broker requirements
   ValidateAndAdjustStops(ORDER_TYPE_SELL, entry_price, stop_loss, take_profit);

   // Recalculate actual distances after broker adjustments
   double actual_sl_distance = stop_loss - entry_price;
   double actual_tp_distance = entry_price - take_profit;

   // Adjust position size if broker changed the stop loss distance
   if (MathAbs(actual_sl_distance - stop_loss_distance) > 1.0)
   {
      position_size_btc = risk_amount / (actual_sl_distance * point_value);
   }

   // Normalize lot size to broker requirements
   double lot_size = NormalizeLotSize(position_size_btc);

   // Calculate final risk and profit with normalized lot size
   double actual_risk = lot_size * actual_sl_distance * point_value;
   double actual_profit = lot_size * actual_tp_distance * point_value;
   position_value = lot_size * entry_price;

   // Debug the corrected calculation
   Print("=== ATR-BASED POSITION SIZING (SELL) ===");
   Print("Account balance: $", DoubleToString(account_balance, 2));
   Print("Risk percentage: ", RISK_PER_TRADE_PCT, "%");
   Print("Target risk amount: $", DoubleToString(CalculateRiskAmount(), 2));
   Print("Target profit amount: $", DoubleToString(CalculateRiskAmount() * TAKE_PROFIT_MULT, 2));
   Print("Entry price: $", DoubleToString(entry_price, 2));
   Print("ATR value: $", DoubleToString(atr_value, 2), " (", ATR_PERIOD, "-period)");
   Print("Stop loss distance: $", DoubleToString(stop_loss_distance, 2), " (= ATR × ", ATR_STOP_LOSS_MULTIPLIER, ")");
   Print("Take profit target: $", DoubleToString(profit_target, 2), " (= ", TAKE_PROFIT_MULT, "x SL distance)");
   Print("Calculated position size: ", DoubleToString(position_size_btc, 6), " BTC");
   Print("Final lot size: ", DoubleToString(lot_size, 6), " BTC");
   Print("Position value: $", DoubleToString(position_value, 2));
   Print("Position as % of account: ", DoubleToString((position_value / account_balance) * 100, 2), "%");
   Print("Stop loss: $", DoubleToString(stop_loss, 2), " (distance: $", DoubleToString(actual_sl_distance, 2), ")");
   Print("Take profit: $", DoubleToString(take_profit, 2), " (distance: $", DoubleToString(actual_tp_distance, 2), ")");
   Print("Actual dollar risk: $", DoubleToString(actual_risk, 2));
   Print("Actual dollar profit target: $", DoubleToString(actual_profit, 2));
   Print("Actual risk as % of account: ", DoubleToString((actual_risk / account_balance) * 100, 2), "%");
   Print("Reward:Risk ratio: ", DoubleToString(actual_profit / actual_risk, 2), ":1");
   Print("========================================");

   // Enhanced filling mode detection with extensive debugging
   int filling_mode = (int)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);

   // Always print filling mode info for troubleshooting
   Print("=== SELL ORDER FILLING MODE DEBUG ===");
   Print("Symbol: ", _Symbol);
   Print("Broker filling modes (raw): ", filling_mode);
   Print("SYMBOL_FILLING_FOK supported: ", ((filling_mode & SYMBOL_FILLING_FOK) != 0) ? "YES" : "NO");
   Print("SYMBOL_FILLING_IOC supported: ", ((filling_mode & SYMBOL_FILLING_IOC) != 0) ? "YES" : "NO");
   Print("Available filling modes: ", filling_mode);

   MqlTradeRequest request = {};
   MqlTradeResult result = {};

   request.action = TRADE_ACTION_DEAL;
   request.symbol = _Symbol;
   request.volume = lot_size;
   request.type = ORDER_TYPE_SELL;
   request.price = entry_price;
   request.sl = stop_loss;
   request.tp = take_profit;
   request.deviation = GetSymbolSlippage();
   request.magic = 123456;
   request.comment = "Alligator_Sell";

   // Try multiple filling modes - start with IOC which works for BTCUSD (from ADX_Breakout_EA)
   bool order_sent = false;

   // First try: IOC (Immediate or Cancel) - commonly supported for crypto
   Print("Attempting SELL with ORDER_FILLING_IOC (preferred for BTCUSD)");
   request.type_filling = ORDER_FILLING_IOC;

   if (OrderSend(request, result))
   {
      if (result.retcode == TRADE_RETCODE_DONE)
      {
         order_sent = true;
         Print("SELL order SUCCESS with ORDER_FILLING_IOC");
      }
      else
      {
         Print("SELL order FAILED with ORDER_FILLING_IOC: ", result.retcode, " - ", GetTradeErrorDescription(result.retcode));
      }
   }

   // Second try: FOK (Fill or Kill) if IOC failed
   if (!order_sent && (filling_mode & SYMBOL_FILLING_FOK) != 0)
   {
      request.type_filling = ORDER_FILLING_FOK;
      Print("Attempting SELL with ORDER_FILLING_FOK");

      if (OrderSend(request, result))
      {
         if (result.retcode == TRADE_RETCODE_DONE)
         {
            order_sent = true;
            Print("SELL order SUCCESS with ORDER_FILLING_FOK");
         }
         else
         {
            Print("SELL order FAILED with ORDER_FILLING_FOK: ", result.retcode, " - ", GetTradeErrorDescription(result.retcode));
         }
      }
   }

   // Skip third try - SYMBOL_FILLING_RETURN doesn't exist in MQL5

   // Last resort: If IOC and FOK both failed, there's likely a deeper issue
   if (!order_sent)
   {
      Print("*** SELL ORDER: Both IOC and FOK failed. Check broker compatibility or instrument specifications. ***");
   }

   // Process successful order
   if (order_sent && result.retcode == TRADE_RETCODE_DONE)
   {
      current_ticket = result.order;
      current_direction = SHORT_TRADE;
      trades_today++;

      if (DEBUG_LEVEL >= 1)
         Print("SELL order executed successfully: Ticket=", current_ticket,
               ", Entry=", DoubleToString(entry_price, _Digits),
               ", SL=", DoubleToString(stop_loss, _Digits),
               ", TP=", DoubleToString(take_profit, _Digits),
               ", Lots=", DoubleToString(lot_size, 2));
   }
   else
   {
      Print("*** ALL SELL ORDER ATTEMPTS FAILED ***");
      Print("Final error: ", result.retcode, " - ", GetTradeErrorDescription(result.retcode));
      Print("Entry price: ", DoubleToString(entry_price, _Digits));
      Print("Stop loss: ", DoubleToString(stop_loss, _Digits));
      Print("Take profit: ", DoubleToString(take_profit, _Digits));
      Print("Lot size: ", DoubleToString(lot_size, 2));
      Print("Slippage: ", GetSymbolSlippage());
   }
}

//+------------------------------------------------------------------+
//| Validate and adjust SL/TP for broker requirements                |
//+------------------------------------------------------------------+
void ValidateAndAdjustStops(ENUM_ORDER_TYPE order_type, double entry_price, double &stop_loss, double &take_profit)
{
   // Get broker's minimum stop level requirements
   int broker_stop_level_points = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double min_stop_level = broker_stop_level_points * _Point;

   // Always show broker requirements for debugging
   Print("=== BROKER STOP LEVEL REQUIREMENTS ===");
   Print("Symbol: ", _Symbol);
   Print("Broker SYMBOL_TRADE_STOPS_LEVEL: ", broker_stop_level_points, " points");
   Print("Minimum stop distance: ", DoubleToString(min_stop_level, _Digits), " price units ($", DoubleToString(min_stop_level, 2), ")");
   Print("Your EA uses dollar-based stops, broker requirements will be automatically met");
   Print("=====================================");

   // Use broker's minimum OR a reasonable minimum for crypto (whichever is larger)
   double min_distance = MathMax(min_stop_level, 20 * _Point); // At least 20 points for crypto

   if (order_type == ORDER_TYPE_BUY)
   {
      // Buy order: SL below entry, TP above entry
      double sl_distance = entry_price - stop_loss;
      double tp_distance = take_profit - entry_price;

      Print("BUY Order Validation:");
      Print("  Original SL distance: ", DoubleToString(sl_distance, _Digits), " price units");
      Print("  Original TP distance: ", DoubleToString(tp_distance, _Digits), " price units");
      Print("  Required minimum: ", DoubleToString(min_distance, _Digits), " price units");

      // Only adjust SL if it violates broker requirements
      if (sl_distance < min_distance)
      {
         double original_sl = stop_loss;
         stop_loss = entry_price - min_distance;
         Print("⚠️ ADJUSTED BUY SL: ", DoubleToString(original_sl, _Digits),
               " → ", DoubleToString(stop_loss, _Digits), " (broker minimum required)");
      }
      else
      {
         Print("✅ BUY SL distance OK - no adjustment needed");
      }

      // Only adjust TP if it violates broker requirements
      if (tp_distance < min_distance)
      {
         double original_tp = take_profit;
         take_profit = entry_price + min_distance;
         Print("⚠️ ADJUSTED BUY TP: ", DoubleToString(original_tp, _Digits),
               " → ", DoubleToString(take_profit, _Digits), " (broker minimum required)");
      }
      else
      {
         Print("✅ BUY TP distance OK - no adjustment needed");
      }
   }
   else // SELL order
   {
      // Sell order: SL above entry, TP below entry
      double sl_distance = stop_loss - entry_price;
      double tp_distance = entry_price - take_profit;

      Print("SELL Order Validation:");
      Print("  Original SL distance: ", DoubleToString(sl_distance, _Digits), " price units");
      Print("  Original TP distance: ", DoubleToString(tp_distance, _Digits), " price units");
      Print("  Required minimum: ", DoubleToString(min_distance, _Digits), " price units");

      // Only adjust SL if it violates broker requirements
      if (sl_distance < min_distance)
      {
         double original_sl = stop_loss;
         stop_loss = entry_price + min_distance;
         Print("⚠️ ADJUSTED SELL SL: ", DoubleToString(original_sl, _Digits),
               " → ", DoubleToString(stop_loss, _Digits), " (broker minimum required)");
      }
      else
      {
         Print("✅ SELL SL distance OK - no adjustment needed");
      }

      // Only adjust TP if it violates broker requirements
      if (tp_distance < min_distance)
      {
         double original_tp = take_profit;
         take_profit = entry_price - min_distance;
         Print("⚠️ ADJUSTED SELL TP: ", DoubleToString(original_tp, _Digits),
               " → ", DoubleToString(take_profit, _Digits), " (broker minimum required)");
      }
      else
      {
         Print("✅ SELL TP distance OK - no adjustment needed");
      }
   }

   if (DEBUG_LEVEL >= 1)
   {
      Print("Final stops - Entry: ", DoubleToString(entry_price, _Digits),
            ", SL: ", DoubleToString(stop_loss, _Digits),
            ", TP: ", DoubleToString(take_profit, _Digits));
      Print("SL Distance: ", DoubleToString(MathAbs(entry_price - stop_loss), _Digits),
            ", TP Distance: ", DoubleToString(MathAbs(entry_price - take_profit), _Digits));
   }
}

//+------------------------------------------------------------------+
//| Calculate optimal slippage based on broker data (from ORB1)      |
//+------------------------------------------------------------------+
int GetSymbolSlippage()
{
   // Get broker-specific symbol information
   double spread = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   // Pure calculation based on broker data to get optimal slippage
   // For BTCUSD: typically 2 digits, needs higher slippage
   int calculated_slippage;

   if (digits == 2) // BTCUSD and other 2-digit crypto instruments
   {
      // For crypto: spread is typically 20-50 points
      // Formula: spread * 2 + 50 points base for crypto volatility
      calculated_slippage = (int)(spread * 2 + 50);

      if (DEBUG_LEVEL >= 2)
         Print("Auto-detected 2-digit crypto like BTCUSD: ", _Symbol);
   }
   else if (digits == 3) // JPY pairs
   {
      // JPY needs much higher slippage due to smaller increments
      calculated_slippage = (int)(spread * 8 + 50);

      if (DEBUG_LEVEL >= 2)
         Print("Auto-detected 3 digit pair like JPY: ", _Symbol);
   }
   else if (digits == 4 || digits == 5) // Major forex pairs
   {
      // Formula: spread * 3 + 15 points base
      calculated_slippage = (int)(spread * 3 + 15);

      if (DEBUG_LEVEL >= 2)
         Print("Auto-detected Major forex pair: ", _Symbol, " (digits=", digits, ")");
   }
   else // Unknown/exotic pairs
   {
      // Higher safety margin for unknowns
      calculated_slippage = (int)(spread * 5 + 30);

      if (DEBUG_LEVEL >= 2)
         Print("Auto-detected Exotic/Unknown pair: ", _Symbol, " (digits=", digits, ")");
   }

   // Apply reasonable bounds
   int min_slippage = 15;  // Never go below 15 points
   int max_slippage = 500; // Cap at 500 points for crypto

   calculated_slippage = MathMax(min_slippage, MathMin(max_slippage, calculated_slippage));

   // Safety check for invalid broker data
   if (spread <= 0)
   {
      calculated_slippage = 100; // Safe fallback for crypto
      if (DEBUG_LEVEL >= 1)
         Print("WARNING: Invalid spread data, using fallback slippage");
   }

   if (DEBUG_LEVEL >= 1)
   {
      Print("=== AUTO-SLIPPAGE CALCULATION ===");
      Print("Symbol: ", _Symbol);
      Print("Broker spread: ", DoubleToString(spread, 1), " points");
      Print("Digits: ", digits);
      Print("Calculated slippage: ", calculated_slippage, " points");
      Print("================================");
   }

   return calculated_slippage;
}

//+------------------------------------------------------------------+
//| Manage existing position                                         |
//+------------------------------------------------------------------+
void ManagePosition()
{
   // Check if position still exists
   if (!PositionSelectByTicket(current_ticket))
   {
      // Position closed (by TP/SL or manually)
      if (DEBUG_LEVEL >= 1)
         Print("Position closed: Ticket=", current_ticket);

      current_ticket = 0;
      current_direction = NO_TRADE;
      monitoring_separation = false;
      entry_time = 0;
      return;
   }

   datetime current_time = TimeCurrent();
   bool should_exit = false;
   string exit_reason = "";

   // EARLY ENTRY STRATEGY: Check line separation monitoring
   if (monitoring_separation && entry_time > 0)
   {
      int time_in_trade = (int)(current_time - entry_time);
      
      // Get current ATR for separation threshold
      double atr_buffer[];
      if (CopyBuffer(atr_handle, 0, 0, 1, atr_buffer) > 0)
      {
         double current_atr = atr_buffer[0];
         double required_separation = current_atr * (LINE_SEPARATE_ATR_PERCENTAGE / 100.0);
         
         if (current_direction == LONG_TRADE)
         {
            // For long trades, check if lines have achieved bullish separation AND correct order
            // Required order: Price > Lips > Teeth > Jaw
            bool correct_bullish_order = (price_current > lips_current && 
                                         lips_current > teeth_current && 
                                         teeth_current > jaw_current);
            
            double lips_teeth_gap = lips_current - teeth_current;
            double teeth_jaw_gap = teeth_current - jaw_current;
            double price_lips_gap = price_current - lips_current;
            
            bool sufficient_separation = (lips_teeth_gap >= required_separation && 
                                        teeth_jaw_gap >= required_separation && 
                                        price_lips_gap >= required_separation);
            
            bool good_separation = correct_bullish_order && sufficient_separation;
            
            if (good_separation)
            {
               // Good separation achieved - stop monitoring
               monitoring_separation = false;
               if (DEBUG_LEVEL >= 1)
                  Print("✅ SEPARATION CONFIRMED: Long position - correct bullish order (Price>Lips>Teeth>Jaw) with required separation (", 
                        DoubleToString(required_separation, _Digits), ")");
            }
            else if (time_in_trade >= CONFIRMATION_WINDOW_SECONDS)
            {
               // Timeout - lines didn't separate enough or lost correct order
               should_exit = true;
               string order_status = correct_bullish_order ? "YES" : "NO";
               string separation_status = sufficient_separation ? "YES" : "NO";
               exit_reason = "EARLY ENTRY TIMEOUT: Failed to achieve bullish alignment within " + 
                           IntegerToString(CONFIRMATION_WINDOW_SECONDS) + " seconds. " +
                           "Correct order (P>L>T>J): " + order_status + 
                           ", Sufficient separation: " + separation_status +
                           " (gaps: P-L=" + DoubleToString(price_lips_gap, _Digits) + 
                           ", L-T=" + DoubleToString(lips_teeth_gap, _Digits) + 
                           ", T-J=" + DoubleToString(teeth_jaw_gap, _Digits) + 
                           ", required=" + DoubleToString(required_separation, _Digits) + ")";
            }
            
            // Debug separation monitoring
            if (DEBUG_LEVEL >= 2 && time_in_trade % 10 == 0) // Every 10 seconds
            {
               int time_remaining = CONFIRMATION_WINDOW_SECONDS - time_in_trade;
               Print("LONG SEPARATION CHECK:");
               Print("  Order (P>L>T>J): ", correct_bullish_order ? "YES" : "NO", 
                     " | P=", DoubleToString(price_current, _Digits),
                     ", L=", DoubleToString(lips_current, _Digits),
                     ", T=", DoubleToString(teeth_current, _Digits),
                     ", J=", DoubleToString(jaw_current, _Digits));
               Print("  Gaps: P-L=", DoubleToString(price_lips_gap, _Digits),
                     ", L-T=", DoubleToString(lips_teeth_gap, _Digits),
                     ", T-J=", DoubleToString(teeth_jaw_gap, _Digits),
                     " | Required=", DoubleToString(required_separation, _Digits));
               Print("  Separation OK: ", sufficient_separation ? "YES" : "NO",
                     " | Time remaining: ", time_remaining, "s");
            }
         }
         else if (current_direction == SHORT_TRADE)
         {
            // For short trades, check if lines have achieved bearish separation AND correct order
            // Required order: Jaw > Teeth > Lips > Price
            bool correct_bearish_order = (jaw_current > teeth_current && 
                                         teeth_current > lips_current && 
                                         lips_current > price_current);
            
            double jaw_teeth_gap = jaw_current - teeth_current;
            double teeth_lips_gap = teeth_current - lips_current;
            double lips_price_gap = lips_current - price_current;
            
            bool sufficient_separation = (jaw_teeth_gap >= required_separation && 
                                        teeth_lips_gap >= required_separation && 
                                        lips_price_gap >= required_separation);
            
            bool good_separation = correct_bearish_order && sufficient_separation;
            
            if (good_separation)
            {
               // Good separation achieved - stop monitoring
               monitoring_separation = false;
               if (DEBUG_LEVEL >= 1)
                  Print("✅ SEPARATION CONFIRMED: Short position - correct bearish order (Jaw>Teeth>Lips>Price) with required separation (", 
                        DoubleToString(required_separation, _Digits), ")");
            }
            else if (time_in_trade >= CONFIRMATION_WINDOW_SECONDS)
            {
               // Timeout - lines didn't separate enough or lost correct order
               should_exit = true;
               string order_status = correct_bearish_order ? "YES" : "NO";
               string separation_status = sufficient_separation ? "YES" : "NO";
               exit_reason = "EARLY ENTRY TIMEOUT: Failed to achieve bearish alignment within " + 
                           IntegerToString(CONFIRMATION_WINDOW_SECONDS) + " seconds. " +
                           "Correct order (J>T>L>P): " + order_status + 
                           ", Sufficient separation: " + separation_status +
                           " (gaps: J-T=" + DoubleToString(jaw_teeth_gap, _Digits) + 
                           ", T-L=" + DoubleToString(teeth_lips_gap, _Digits) + 
                           ", L-P=" + DoubleToString(lips_price_gap, _Digits) + 
                           ", required=" + DoubleToString(required_separation, _Digits) + ")";
            }
            
            // Debug separation monitoring
            if (DEBUG_LEVEL >= 2 && time_in_trade % 10 == 0) // Every 10 seconds
            {
               int time_remaining = CONFIRMATION_WINDOW_SECONDS - time_in_trade;
               Print("SHORT SEPARATION CHECK:");
               Print("  Order (J>T>L>P): ", correct_bearish_order ? "YES" : "NO", 
                     " | J=", DoubleToString(jaw_current, _Digits),
                     ", T=", DoubleToString(teeth_current, _Digits),
                     ", L=", DoubleToString(lips_current, _Digits),
                     ", P=", DoubleToString(price_current, _Digits));
               Print("  Gaps: J-T=", DoubleToString(jaw_teeth_gap, _Digits),
                     ", T-L=", DoubleToString(teeth_lips_gap, _Digits),
                     ", L-P=", DoubleToString(lips_price_gap, _Digits),
                     " | Required=", DoubleToString(required_separation, _Digits));
               Print("  Separation OK: ", sufficient_separation ? "YES" : "NO",
                     " | Time remaining: ", time_remaining, "s");
            }
         }
      }
   }

   // MOMENTUM EXIT SIGNALS: Check for momentum weakening
   if (!should_exit)
   {
      if (current_direction == LONG_TRADE)
      {
         // Early exit if price closes below Lips (momentum weakening)
         if (price_current < lips_current && price_previous >= lips_previous)
         {
            should_exit = true;
            exit_reason = "MOMENTUM EXIT: Price closed below Lips - bullish momentum weakening";
         }
      }
      else if (current_direction == SHORT_TRADE)
      {
         // Early exit if price closes above Lips (momentum weakening)
         if (price_current > lips_current && price_previous <= lips_previous)
         {
            should_exit = true;
            exit_reason = "MOMENTUM EXIT: Price closed above Lips - bearish momentum weakening";
         }
      }
   }

   if (should_exit)
   {
      ClosePosition(exit_reason);
      monitoring_separation = false;
      entry_time = 0;
   }
}

//+------------------------------------------------------------------+
//| Close current position                                           |
//+------------------------------------------------------------------+
void ClosePosition(string reason)
{
   if (!PositionSelectByTicket(current_ticket))
      return;

   // Enhanced filling mode detection with extensive debugging
   int filling_mode = (int)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);

   // Always print filling mode info for troubleshooting
   Print("=== CLOSE POSITION FILLING MODE DEBUG ===");
   Print("Closing position: ", current_ticket, ", Reason: ", reason);
   Print("Symbol: ", _Symbol);
   Print("Broker filling modes (raw): ", filling_mode);
   Print("SYMBOL_FILLING_FOK supported: ", ((filling_mode & SYMBOL_FILLING_FOK) != 0) ? "YES" : "NO");
   Print("SYMBOL_FILLING_IOC supported: ", ((filling_mode & SYMBOL_FILLING_IOC) != 0) ? "YES" : "NO");
   Print("Available filling modes: ", filling_mode);

   MqlTradeRequest request = {};
   MqlTradeResult result = {};

   request.action = TRADE_ACTION_DEAL;
   request.position = current_ticket;
   request.symbol = _Symbol;
   request.volume = PositionGetDouble(POSITION_VOLUME);
   request.type = (current_direction == LONG_TRADE) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
   request.price = (request.type == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                                    : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   request.deviation = GetSymbolSlippage();
   request.magic = 123456;
   request.comment = "Alligator_Exit";

   // Try multiple filling modes - start with IOC which works for BTCUSD (from ADX_Breakout_EA)
   bool position_closed = false;

   // First try: IOC (Immediate or Cancel) - commonly supported for crypto
   Print("Attempting CLOSE with ORDER_FILLING_IOC (preferred for BTCUSD)");
   request.type_filling = ORDER_FILLING_IOC;

   if (OrderSend(request, result))
   {
      if (result.retcode == TRADE_RETCODE_DONE)
      {
         position_closed = true;
         Print("CLOSE order SUCCESS with ORDER_FILLING_IOC");
      }
      else
      {
         Print("CLOSE order FAILED with ORDER_FILLING_IOC: ", result.retcode, " - ", GetTradeErrorDescription(result.retcode));
      }
   }

   // Second try: FOK (Fill or Kill) if IOC failed
   if (!position_closed && (filling_mode & SYMBOL_FILLING_FOK) != 0)
   {
      request.type_filling = ORDER_FILLING_FOK;
      Print("Attempting CLOSE with ORDER_FILLING_FOK");

      if (OrderSend(request, result))
      {
         if (result.retcode == TRADE_RETCODE_DONE)
         {
            position_closed = true;
            Print("CLOSE order SUCCESS with ORDER_FILLING_FOK");
         }
         else
         {
            Print("CLOSE order FAILED with ORDER_FILLING_FOK: ", result.retcode, " - ", GetTradeErrorDescription(result.retcode));
         }
      }
   }

   // Skip third try - SYMBOL_FILLING_RETURN doesn't exist in MQL5

   // Last resort: If IOC and FOK both failed, there's likely a deeper issue
   if (!position_closed)
   {
      Print("*** CLOSE POSITION: Both IOC and FOK failed. Check broker compatibility or instrument specifications. ***");
   }

   // Process successful close
   if (position_closed && result.retcode == TRADE_RETCODE_DONE)
   {
      if (DEBUG_LEVEL >= 1)
         Print("Position closed successfully: Ticket=", current_ticket, ", Reason: ", reason);

      current_ticket = 0;
      current_direction = NO_TRADE;
   }
   else
   {
      Print("*** ALL CLOSE POSITION ATTEMPTS FAILED ***");
      Print("Final error: ", result.retcode, " - ", GetTradeErrorDescription(result.retcode));
      Print("Position ticket: ", current_ticket);
      Print("Close type: ", (request.type == ORDER_TYPE_BUY) ? "BUY" : "SELL");
      Print("Close price: ", DoubleToString(request.price, _Digits));
      Print("Volume: ", DoubleToString(request.volume, 2));
      Print("Slippage: ", GetSymbolSlippage());
   }
}

//+------------------------------------------------------------------+
//| Draw breakout box showing sleep period and awakening             |
//+------------------------------------------------------------------+
void DrawBreakoutBox(datetime sleep_start, datetime breakout_time, bool is_bullish)
{
   if (sleep_start == 0) return; // Safety check
   
   visual_counter++;
   string box_name = "BreakoutBox_" + IntegerToString(visual_counter);
   
   // Get price range during sleep period
   double high_prices[], low_prices[];
   int bars_count = (int)((breakout_time - sleep_start) / PeriodSeconds());
   bars_count = MathMax(1, MathMin(bars_count, 500)); // Limit for performance
   
   if (CopyHigh(_Symbol, _Period, iBarShift(_Symbol, _Period, sleep_start), bars_count, high_prices) > 0 &&
       CopyLow(_Symbol, _Period, iBarShift(_Symbol, _Period, sleep_start), bars_count, low_prices) > 0)
   {
      double highest = high_prices[ArrayMaximum(high_prices)];
      double lowest = low_prices[ArrayMinimum(low_prices)];
      
      // Add some padding to the box
      double padding = (highest - lowest) * 0.1;
      highest += padding;
      lowest -= padding;
      
      // Create rectangle showing the sleep period
      if (ObjectCreate(0, box_name, OBJ_RECTANGLE, 0, sleep_start, highest, breakout_time, lowest))
      {
         // Set box properties
         color box_color = is_bullish ? clrLightGreen : clrLightCoral;
         ObjectSetInteger(0, box_name, OBJPROP_COLOR, box_color);
         ObjectSetInteger(0, box_name, OBJPROP_STYLE, STYLE_SOLID);
         ObjectSetInteger(0, box_name, OBJPROP_WIDTH, 1);
         ObjectSetInteger(0, box_name, OBJPROP_BACK, true);
         ObjectSetInteger(0, box_name, OBJPROP_FILL, true);
         ObjectSetInteger(0, box_name, OBJPROP_SELECTED, false);
         ObjectSetInteger(0, box_name, OBJPROP_SELECTABLE, false);
         
         // Add text label
         string label_name = "BreakoutLabel_" + IntegerToString(visual_counter);
         if (ObjectCreate(0, label_name, OBJ_TEXT, 0, breakout_time, (highest + lowest) / 2))
         {
            string label_text = is_bullish ? "🚀 BULLISH AWAKENING" : "📉 BEARISH AWAKENING";
            ObjectSetString(0, label_name, OBJPROP_TEXT, label_text);
            ObjectSetString(0, label_name, OBJPROP_FONT, "Arial");
            ObjectSetInteger(0, label_name, OBJPROP_FONTSIZE, 8);
            ObjectSetInteger(0, label_name, OBJPROP_COLOR, is_bullish ? clrDarkGreen : clrDarkRed);
            ObjectSetInteger(0, label_name, OBJPROP_ANCHOR, ANCHOR_LEFT);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Draw breakout arrow at entry point                               |
//+------------------------------------------------------------------+
void DrawBreakoutArrow(datetime time, double price, bool is_bullish)
{
   visual_counter++;
   string arrow_name = "BreakoutArrow_" + IntegerToString(visual_counter);
   
   // Create arrow object
   ENUM_OBJECT arrow_type = is_bullish ? OBJ_ARROW_UP : OBJ_ARROW_DOWN;
   
   if (ObjectCreate(0, arrow_name, arrow_type, 0, time, price))
   {
      // Set arrow properties
      color arrow_color = is_bullish ? clrBlue : clrRed;
      ObjectSetInteger(0, arrow_name, OBJPROP_COLOR, arrow_color);
      ObjectSetInteger(0, arrow_name, OBJPROP_WIDTH, 3);
      ObjectSetInteger(0, arrow_name, OBJPROP_BACK, false);
      ObjectSetInteger(0, arrow_name, OBJPROP_SELECTED, false);
      ObjectSetInteger(0, arrow_name, OBJPROP_SELECTABLE, false);
      
      // Set arrow code for up/down arrows
      ObjectSetInteger(0, arrow_name, OBJPROP_ARROWCODE, is_bullish ? 233 : 234);
   }
}

//+------------------------------------------------------------------+
//| Draw threshold lines showing breakout levels                     |
//+------------------------------------------------------------------+
void DrawThresholdLines(datetime time, double threshold_distance, bool is_bullish)
{
   visual_counter++;
   string threshold_name = "Threshold_" + IntegerToString(visual_counter);
   
   // Calculate threshold level based on Alligator lines
   double max_line = MathMax(MathMax(jaw_current, teeth_current), lips_current);
   double min_line = MathMin(MathMin(jaw_current, teeth_current), lips_current);
   double threshold_level = is_bullish ? (max_line + threshold_distance) : (min_line - threshold_distance);
   
   // Create horizontal line
   datetime end_time = time + PeriodSeconds() * 20; // Show for 20 bars
   
   if (ObjectCreate(0, threshold_name, OBJ_TREND, 0, time, threshold_level, end_time, threshold_level))
   {
      color line_color = is_bullish ? clrDodgerBlue : clrOrangeRed;
      ObjectSetInteger(0, threshold_name, OBJPROP_COLOR, line_color);
      ObjectSetInteger(0, threshold_name, OBJPROP_STYLE, STYLE_DOT);
      ObjectSetInteger(0, threshold_name, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, threshold_name, OBJPROP_BACK, false);
      ObjectSetInteger(0, threshold_name, OBJPROP_RAY_RIGHT, false);
      ObjectSetInteger(0, threshold_name, OBJPROP_SELECTED, false);
      ObjectSetInteger(0, threshold_name, OBJPROP_SELECTABLE, false);
   }
}

//+------------------------------------------------------------------+
//| Clean up visual objects from chart                               |
//+------------------------------------------------------------------+
void CleanupVisualObjects()
{
   // Remove all objects created by this EA
   for (int i = ObjectsTotal(0) - 1; i >= 0; i--)
   {
      string obj_name = ObjectName(0, i);
      if (StringFind(obj_name, "BreakoutBox_") >= 0 || 
          StringFind(obj_name, "BreakoutLabel_") >= 0 ||
          StringFind(obj_name, "BreakoutArrow_") >= 0 ||
          StringFind(obj_name, "Threshold_") >= 0)
      {
         ObjectDelete(0, obj_name);
      }
   }
   
   visual_counter = 0; // Reset counter
}

//+------------------------------------------------------------------+
//| Calculate risk amount in dollars                                 |
//+------------------------------------------------------------------+
double CalculateRiskAmount()
{
   double account_balance = AccountInfoDouble(ACCOUNT_BALANCE);

   // Always use percentage-based risk calculation
   double risk_amount = account_balance * RISK_PER_TRADE_PCT / 100.0;
   Print("Using percentage-based risk: ", RISK_PER_TRADE_PCT, "% of $",
         DoubleToString(account_balance, 2), " = $", DoubleToString(risk_amount, 2));

   return risk_amount;
}

//+------------------------------------------------------------------+
//| Normalize lot size to broker requirements                        |
//+------------------------------------------------------------------+
double NormalizeLotSize(double lot_size)
{
   // Get broker requirements
   double min_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double max_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lot_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   // Apply limits
   lot_size = MathMax(min_lot, lot_size);
   lot_size = MathMin(max_lot, lot_size);

   // Round to valid step size
   lot_size = NormalizeDouble(lot_size / lot_step, 0) * lot_step;

   if (DEBUG_LEVEL >= 1)
   {
      Print("Lot size normalization:");
      Print("  Raw calculated: ", DoubleToString(lot_size, 4));
      Print("  Min lot: ", DoubleToString(min_lot, 4));
      Print("  Max lot: ", DoubleToString(max_lot, 4));
      Print("  Lot step: ", DoubleToString(lot_step, 4));
      Print("  Final lot size: ", DoubleToString(lot_size, 4));
   }

   return lot_size;
}

//+------------------------------------------------------------------+
//| Reset daily trade counter if new day                             |
//+------------------------------------------------------------------+
void ResetDailyCounter()
{
   datetime current_time = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(current_time, dt);
   dt.hour = 0;
   dt.min = 0;
   dt.sec = 0;
   datetime today = StructToTime(dt);

   if (last_trade_date != today)
   {
      trades_today = 0;
      last_trade_date = today;

      if (DEBUG_LEVEL >= 1)
         Print("New trading day started - trade counter reset");
   }
}

//+------------------------------------------------------------------+
//| Show information panel                                           |
//+------------------------------------------------------------------+
void ShowInfo()
{
   string status = "";

   if (current_ticket != 0)
   {
      if (PositionSelectByTicket(current_ticket))
      {
         double profit = PositionGetDouble(POSITION_PROFIT);
         status = "In " + ((current_direction == LONG_TRADE) ? "LONG" : "SHORT") +
                  " position | P&L: $" + DoubleToString(profit, 2);
         
         // Show separation monitoring status
         if (monitoring_separation && entry_time > 0)
         {
            int time_in_trade = (int)(TimeCurrent() - entry_time);
            int time_remaining = CONFIRMATION_WINDOW_SECONDS - time_in_trade;
            status += " | Monitoring separation (" + IntegerToString(time_remaining) + "s remaining)";
         }
      }
   }
   else
   {
      status = "Looking for early entry signals";
   }

   // Early Entry Strategy Status
   string strategy_status = "";
   if (alligator_is_sleeping)
   {
      if (alligator_sleep_start > 0)
      {
         int sleep_duration = (int)(TimeCurrent() - alligator_sleep_start);
         if (sleep_duration >= SLEEPING_WINDOW_SECONDS)
            strategy_status = "READY FOR BREAKOUT (Slept " + IntegerToString(sleep_duration) + "s)";
         else
         {
            int remaining = SLEEPING_WINDOW_SECONDS - sleep_duration;
            strategy_status = "SLEEPING - Need " + IntegerToString(remaining) + "s more";
         }
      }
      else
         strategy_status = "SLEEPING (just started)";
   }
   else
   {
      // Show line alignment for awake alligator
      bool bullish_stack = (lips_current > teeth_current && teeth_current > jaw_current);
      bool bearish_stack = (jaw_current > teeth_current && teeth_current > lips_current);

      if (bullish_stack)
         strategy_status = "AWAKE - BULLISH TREND (Green>Red>Blue)";
      else if (bearish_stack)
         strategy_status = "AWAKE - BEARISH TREND (Blue>Red>Green)";
      else if (lips_current > teeth_current)
         strategy_status = "AWAKE - POTENTIAL BULLISH (Green>Red)";
      else if (lips_current < teeth_current)
         strategy_status = "AWAKE - POTENTIAL BEARISH (Red>Green)";
      else
         strategy_status = "AWAKE - MIXED SIGNALS";
   }

   string info = StringFormat(
       "BTCUSD Alligator Early Entry | Trades Today: %d/%d\n" +
           "Status: %s\n" +
           "Strategy: %s\n" +
           "Price: %s | Jaw: %s | Teeth: %s | Lips: %s\n" +
           "Settings: Risk=%.1f%% | Sleep=%ds | Breakout=%.0f%% ATR | Separation=%.0f%% ATR",
       trades_today, MAX_TRADES_PER_DAY,
       status,
       strategy_status,
       DoubleToString(price_current, _Digits),
       DoubleToString(jaw_current, _Digits),
       DoubleToString(teeth_current, _Digits),
       DoubleToString(lips_current, _Digits),
       RISK_PER_TRADE_PCT,
       SLEEPING_WINDOW_SECONDS,
       ATR_PRICE_THRESHOLD_PERCENT,
       LINE_SEPARATE_ATR_PERCENTAGE);

   Comment(info);
}

//+------------------------------------------------------------------+
//| Get trade error description                                      |
//+------------------------------------------------------------------+
string GetTradeErrorDescription(int error_code)
{
   switch (error_code)
   {
   case TRADE_RETCODE_DONE:
      return "Done";
   case TRADE_RETCODE_REQUOTE:
      return "Requote";
   case TRADE_RETCODE_REJECT:
      return "Request rejected";
   case TRADE_RETCODE_CANCEL:
      return "Request canceled";
   case TRADE_RETCODE_PLACED:
      return "Order placed";
   case TRADE_RETCODE_DONE_PARTIAL:
      return "Done partially";
   case TRADE_RETCODE_ERROR:
      return "Common error";
   case TRADE_RETCODE_TIMEOUT:
      return "Timeout";
   case TRADE_RETCODE_INVALID:
      return "Invalid request";
   case TRADE_RETCODE_INVALID_VOLUME:
      return "Invalid volume";
   case TRADE_RETCODE_INVALID_PRICE:
      return "Invalid price";
   case TRADE_RETCODE_INVALID_STOPS:
      return "Invalid stops";
   case TRADE_RETCODE_TRADE_DISABLED:
      return "Trade disabled";
   case TRADE_RETCODE_MARKET_CLOSED:
      return "Market closed";
   case TRADE_RETCODE_NO_MONEY:
      return "No money";
   case TRADE_RETCODE_PRICE_CHANGED:
      return "Price changed";
   case TRADE_RETCODE_PRICE_OFF:
      return "Off quotes";
   case TRADE_RETCODE_INVALID_EXPIRATION:
      return "Invalid expiration";
   case TRADE_RETCODE_ORDER_CHANGED:
      return "Order changed";
   case TRADE_RETCODE_TOO_MANY_REQUESTS:
      return "Too many requests";
   case TRADE_RETCODE_NO_CHANGES:
      return "No changes";
   case TRADE_RETCODE_SERVER_DISABLES_AT:
      return "Autotrading disabled by server";
   case TRADE_RETCODE_CLIENT_DISABLES_AT:
      return "Autotrading disabled by client";
   case TRADE_RETCODE_LOCKED:
      return "Locked";
   case TRADE_RETCODE_FROZEN:
      return "Frozen";
   case TRADE_RETCODE_INVALID_FILL:
      return "Invalid fill";
   case TRADE_RETCODE_CONNECTION:
      return "No connection";
   case TRADE_RETCODE_ONLY_REAL:
      return "Only real accounts allowed";
   case TRADE_RETCODE_LIMIT_ORDERS:
      return "Limit orders only";
   case TRADE_RETCODE_LIMIT_VOLUME:
      return "Volume limit reached";
   default:
      return "Unknown error " + IntegerToString(error_code);
   }
}

//+------------------------------------------------------------------+
//| Tester function for optimization                                 |
//+------------------------------------------------------------------+
double OnTester()
{
   // Get backtest statistics
   double total_trades = TesterStatistics(STAT_TRADES);
   double gross_profit = TesterStatistics(STAT_GROSS_PROFIT);
   double gross_loss = TesterStatistics(STAT_GROSS_LOSS);
   double net_profit = TesterStatistics(STAT_PROFIT);
   double max_drawdown = TesterStatistics(STAT_BALANCE_DD);
   double initial_deposit = TesterStatistics(STAT_INITIAL_DEPOSIT);
   
   // Avoid division by zero and reject invalid data
   if (total_trades < 5 || initial_deposit <= 0)
      return 0.0;
   
   // Immediately reject zero or negative profit strategies
   if (net_profit <= 0.0)
   {
      if (DEBUG_LEVEL >= 1)
         Print("OPTIMIZATION REJECTED: Zero or negative profit (", DoubleToString(net_profit, 2), ")");
      return 0.0;
   }
   
   double roi_percent = (net_profit / initial_deposit) * 100.0;
   double drawdown_percent = (max_drawdown / initial_deposit) * 100.0;
   
   // SIMPLE FITNESS: High profit + Low drawdown + More trades
   
   // Base score: Profit adjusted for drawdown
   double profit_score;
   if (drawdown_percent > 0.1)  // Only adjust if meaningful drawdown (>0.1%)
      profit_score = net_profit / drawdown_percent;  // Dollar profit per % drawdown
   else
      profit_score = net_profit * 100.0;  // Zero/tiny drawdown = multiply profit by 100 (huge bonus)
   
   // Trade multiplier: More trades = better (with diminishing returns)
   double trade_multiplier = MathLog(total_trades + 1);  // Log scale to prevent explosion
   
   // Final fitness: Profit efficiency × Trade activity
   double fitness = profit_score * trade_multiplier;
   
   // Debug output for optimization
   if (DEBUG_LEVEL >= 1)
   {
      Print("=== SIMPLE OPTIMIZATION RESULTS ===");
      Print("Total Trades: ", (int)total_trades);
      Print("Net Profit: $", DoubleToString(net_profit, 2));
      Print("ROI: ", DoubleToString(roi_percent, 2), "%");
      Print("Max Drawdown: ", DoubleToString(drawdown_percent, 2), "%");
      Print("Profit Score: ", DoubleToString(profit_score, 2));
      Print("Trade Multiplier: ", DoubleToString(trade_multiplier, 2));
      Print("FINAL FITNESS: ", DoubleToString(fitness, 2));
      Print("===================================");
   }
   
   return fitness;
}

//+------------------------------------------------------------------+
//+------------------------------------------------------------------+