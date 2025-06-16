//+------------------------------------------------------------------+
//|                        BTCUSD Alligator Scalper                   |
//|         Original Williams Alligator Strategy (M1 Adapted)         |
//|               Copyright 2025 - free to use / modify               |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025"
#property version "1.00"
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

// Trade Timing and Thresholds
input double PRICE_THRESHOLD_POINTS = 100;   // Minimum price movement threshold (points) - 100 points = $1.00 for BTCUSD
input double LINE_SEPARATION_POINTS = 50;    // Minimum separation between Alligator lines (points) - 50 points = $0.50 for BTCUSD
input int SIGNAL_COOLDOWN_SECONDS = 180;     // Cooldown between signals (seconds) - prevents rapid fire & whipsaw
input int CONFIRMATION_WINDOW_SECONDS = 120; // Time window for lines to confirm after price crosses Jaw (seconds)

// ATR-Based Stop Loss Settings
input int ATR_STOP_LOSS_PERIOD = 14;         // ATR period for stop loss calculation
input double ATR_STOP_LOSS_MULTIPLIER = 1.0; // ATR multiplier for stop loss distance

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

// Trend tracking variables
datetime bullish_trend_start = 0; // When bullish alignment started
datetime bearish_trend_start = 0; // When bearish alignment started
datetime last_signal_time = 0;    // Last signal time for cooldown
bool previous_bullish_alignment = false;
bool previous_bearish_alignment = false;

// Sequential confirmation tracking variables
datetime price_crossed_jaw_up_time = 0;   // When price last crossed above Jaw
datetime price_crossed_jaw_down_time = 0; // When price last crossed below Jaw
bool waiting_for_lips_bullish = false;    // Step 1: Waiting for Lips to cross above Jaw
bool waiting_for_teeth_bullish = false;   // Step 2: Waiting for Teeth to cross above Jaw
bool waiting_for_lips_bearish = false;    // Step 1: Waiting for Lips to cross below Jaw
bool waiting_for_teeth_bearish = false;   // Step 2: Waiting for Teeth to cross below Jaw

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
   atr_handle = iATR(_Symbol, _Period, ATR_STOP_LOSS_PERIOD);

   if (atr_handle == INVALID_HANDLE)
   {
      if (DEBUG_LEVEL >= 1)
         Print("Failed to create ATR indicator handle. Error: ", GetLastError());
      return (INIT_FAILED);
   }

   // Reset daily trade counter if new day
   ResetDailyCounter();

   if (DEBUG_LEVEL >= 1)
   {
      Print("=== BTCUSD Alligator EA Initialized ===");
      Print("Timeframe: ", PeriodToString((ENUM_TIMEFRAMES)_Period));
      Print("Max trades per day: ", MAX_TRADES_PER_DAY);
      Print("Risk Management: ", RISK_PER_TRADE_PCT, "% of account per trade");
      Print("Risk:Reward Ratio = 1:", TAKE_PROFIT_MULT);
      Print("Stop Loss: ATR(", ATR_STOP_LOSS_PERIOD, ") × ", ATR_STOP_LOSS_MULTIPLIER, " (volatility-adaptive)");
      Print("==========================================");
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

   // Update trend duration tracking
   UpdateTrendDuration();

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
//| Update trend duration tracking                                   |
//+------------------------------------------------------------------+
void UpdateTrendDuration()
{
   // Check current line alignment
   bool bullish_alignment = (lips_current > teeth_current && teeth_current > jaw_current);
   bool bearish_alignment = (jaw_current > teeth_current && teeth_current > lips_current);

   // Track bullish trend duration
   if (bullish_alignment && !previous_bullish_alignment)
   {
      // Bullish trend just started
      bullish_trend_start = TimeCurrent();
      if (DEBUG_LEVEL >= 2)
         Print("BULLISH TREND STARTED at ", TimeToString(bullish_trend_start));
   }
   else if (!bullish_alignment && previous_bullish_alignment)
   {
      // Bullish trend ended
      if (DEBUG_LEVEL >= 2)
         Print("BULLISH TREND ENDED at ", TimeToString(TimeCurrent()));
      bullish_trend_start = 0;
   }

   // Track bearish trend duration
   if (bearish_alignment && !previous_bearish_alignment)
   {
      // Bearish trend just started
      bearish_trend_start = TimeCurrent();
      if (DEBUG_LEVEL >= 2)
         Print("BEARISH TREND STARTED at ", TimeToString(bearish_trend_start));
   }
   else if (!bearish_alignment && previous_bearish_alignment)
   {
      // Bearish trend ended
      if (DEBUG_LEVEL >= 2)
         Print("BEARISH TREND ENDED at ", TimeToString(TimeCurrent()));
      bearish_trend_start = 0;
   }

   // Update previous states
   previous_bullish_alignment = bullish_alignment;
   previous_bearish_alignment = bearish_alignment;
}

//+------------------------------------------------------------------+
//| Print Alligator status for debugging                             |
//+------------------------------------------------------------------+
void PrintAlligatorStatus()
{
   Print("=== ALLIGATOR STATUS ===");
   Print("Price: Current=", DoubleToString(price_current, _Digits),
         ", Previous=", DoubleToString(price_previous, _Digits));
   Print("Jaw (Blue): Current=", DoubleToString(jaw_current, _Digits),
         ", Previous=", DoubleToString(jaw_previous, _Digits));
   Print("Teeth (Red): Current=", DoubleToString(teeth_current, _Digits),
         ", Previous=", DoubleToString(teeth_previous, _Digits));
   Print("Lips (Green): Current=", DoubleToString(lips_current, _Digits),
         ", Previous=", DoubleToString(lips_previous, _Digits));

   // Check line alignment
   string alignment = "";
   if (lips_current > teeth_current && teeth_current > jaw_current)
      alignment = "BULLISH (Green>Red>Blue)";
   else if (jaw_current > teeth_current && teeth_current > lips_current)
      alignment = "BEARISH (Blue>Red>Green)";
   else
      alignment = "SIDEWAYS (Mixed)";
   Print("Line Alignment: ", alignment);

   // Show trend durations
   if (bullish_trend_start > 0)
   {
      int bullish_duration = (int)(TimeCurrent() - bullish_trend_start);
      Print("Bullish trend duration: ", bullish_duration, " seconds");
   }

   if (bearish_trend_start > 0)
   {
      int bearish_duration = (int)(TimeCurrent() - bearish_trend_start);
      Print("Bearish trend duration: ", bearish_duration, " seconds");
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
//| Check for entry signals based on Alligator strategy             |
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

   // Check individual conditions with thresholds
   bool price_crossed_above_jaw = (price_current > jaw_current && price_previous <= jaw_previous) &&
                                  (price_current - jaw_current >= PRICE_THRESHOLD_POINTS * _Point);

   bool price_crossed_below_jaw = (price_current < jaw_current && price_previous >= jaw_previous) &&
                                  (jaw_current - price_current >= PRICE_THRESHOLD_POINTS * _Point);

   bool lips_crossed_above_teeth = (lips_current > teeth_current && lips_previous <= teeth_previous) &&
                                   (lips_current - teeth_current >= LINE_SEPARATION_POINTS * _Point);

   bool lips_crossed_below_teeth = (lips_current < teeth_current && lips_previous >= teeth_previous) &&
                                   (teeth_current - lips_current >= LINE_SEPARATION_POINTS * _Point);

   // Add crossover detection for Lips vs Jaw
   bool lips_crossed_above_jaw = (lips_current > jaw_current && lips_previous <= jaw_previous) &&
                                 (lips_current - jaw_current >= LINE_SEPARATION_POINTS * _Point);

   bool lips_crossed_below_jaw = (lips_current < jaw_current && lips_previous >= jaw_previous) &&
                                 (jaw_current - lips_current >= LINE_SEPARATION_POINTS * _Point);

   // Add crossover detection for Teeth vs Jaw
   bool teeth_crossed_above_jaw = (teeth_current > jaw_current && teeth_previous <= jaw_previous) &&
                                  (teeth_current - jaw_current >= LINE_SEPARATION_POINTS * _Point);

   bool teeth_crossed_below_jaw = (teeth_current < jaw_current && teeth_previous >= jaw_previous) &&
                                  (jaw_current - teeth_current >= LINE_SEPARATION_POINTS * _Point);

   // Check line alignment for trend confirmation
   bool bullish_alignment = (lips_current > teeth_current && teeth_current > jaw_current);
   bool bearish_alignment = (jaw_current > teeth_current && teeth_current > lips_current);

   // Debug signal analysis (more frequent for troubleshooting)
   if (DEBUG_LEVEL >= 1)
   {
      static datetime last_signal_debug = 0;
      if (TimeCurrent() - last_signal_debug > 2) // Every 2 seconds for troubleshooting
      {
         Print("=== SIGNAL ANALYSIS ===");
         Print("Price vs Jaw: Above=", price_crossed_above_jaw ? "YES" : "No",
               ", Below=", price_crossed_below_jaw ? "YES" : "No");
         Print("Lips vs Teeth: Above=", lips_crossed_above_teeth ? "YES" : "No",
               ", Below=", lips_crossed_below_teeth ? "YES" : "No");
         Print("Alignment: Bullish=", bullish_alignment ? "YES" : "No",
               ", Bearish=", bearish_alignment ? "YES" : "No");

         // Detailed crossover analysis for debugging
         Print("=== DETAILED CROSSOVER DEBUG ===");
         Print("Price: Current=", DoubleToString(price_current, _Digits), ", Previous=", DoubleToString(price_previous, _Digits));
         Print("Jaw: Current=", DoubleToString(jaw_current, _Digits), ", Previous=", DoubleToString(jaw_previous, _Digits));
         Print("Teeth: Current=", DoubleToString(teeth_current, _Digits), ", Previous=", DoubleToString(teeth_previous, _Digits));
         Print("Lips: Current=", DoubleToString(lips_current, _Digits), ", Previous=", DoubleToString(lips_previous, _Digits));

         // Check raw crossover conditions (without thresholds)
         bool raw_price_cross_up = (price_current > jaw_current && price_previous <= jaw_previous);
         bool raw_price_cross_down = (price_current < jaw_current && price_previous >= jaw_previous);
         bool raw_lips_cross_up = (lips_current > teeth_current && lips_previous <= teeth_previous);
         bool raw_lips_cross_down = (lips_current < teeth_current && lips_previous >= teeth_previous);

         Print("Raw Crossovers (no thresholds): Price Up=", raw_price_cross_up ? "YES" : "No",
               ", Price Down=", raw_price_cross_down ? "YES" : "No",
               ", Lips Up=", raw_lips_cross_up ? "YES" : "No",
               ", Lips Down=", raw_lips_cross_down ? "YES" : "No");

         // Show actual threshold effectiveness for BTCUSD
         Print("=== THRESHOLD EFFECTIVENESS ANALYSIS ===");
         Print("_Point value: $", DoubleToString(_Point, 5));
         Print("Price threshold: ", PRICE_THRESHOLD_POINTS, " points = $", DoubleToString(PRICE_THRESHOLD_POINTS * _Point, 5));
         Print("Line threshold: ", LINE_SEPARATION_POINTS, " points = $", DoubleToString(LINE_SEPARATION_POINTS * _Point, 5));

         if (raw_price_cross_up)
         {
            double actual_price_gap = price_current - jaw_current;
            double required_gap = PRICE_THRESHOLD_POINTS * _Point;
            Print("BULLISH: Actual price gap = $", DoubleToString(actual_price_gap, 5),
                  " vs required $", DoubleToString(required_gap, 5),
                  " (", DoubleToString(actual_price_gap / _Point, 1), " points)");
            if (actual_price_gap < required_gap)
               Print("  → Price crossover REJECTED due to threshold");
            else
               Print("  → Price crossover ACCEPTED");
         }

         if (raw_price_cross_down)
         {
            double actual_price_gap = jaw_current - price_current;
            double required_gap = PRICE_THRESHOLD_POINTS * _Point;
            Print("BEARISH: Actual price gap = $", DoubleToString(actual_price_gap, 5),
                  " vs required $", DoubleToString(required_gap, 5),
                  " (", DoubleToString(actual_price_gap / _Point, 1), " points)");
            if (actual_price_gap < required_gap)
               Print("  → Price crossover REJECTED due to threshold");
            else
               Print("  → Price crossover ACCEPTED");
         }

         // Show current thresholds and mode being used
         Print("Thresholds: Price=", PRICE_THRESHOLD_POINTS, " points, Line=", LINE_SEPARATION_POINTS, " points");
         Print("Mode: WILLIAMS ALLIGATOR (Sequential crossover: Price→Lips→Teeth) on ", PeriodToString((ENUM_TIMEFRAMES)_Period));

         // Show current line positioning for Williams Alligator analysis
         bool lips_above_teeth = lips_current > teeth_current;
         bool teeth_vs_jaw = teeth_current > jaw_current;
         bool lips_vs_jaw = lips_current > jaw_current;
         Print("Line Positioning: Lips vs Teeth = ", lips_above_teeth ? "ABOVE" : "BELOW");
         Print("Line Stack Check: Teeth vs Jaw = ", teeth_vs_jaw ? "ABOVE" : "BELOW",
               ", Lips vs Jaw = ", lips_vs_jaw ? "ABOVE" : "BELOW");

         // Show confirmation status
         if (waiting_for_teeth_bullish)
         {
            int time_remaining = CONFIRMATION_WINDOW_SECONDS - (int)(TimeCurrent() - price_crossed_jaw_up_time);
            Print("CONFIRMATION STATUS: Waiting for TEETH to cross above JAW (", time_remaining, " seconds remaining)");
         }
         else if (waiting_for_lips_bullish)
         {
            int time_remaining = CONFIRMATION_WINDOW_SECONDS - (int)(TimeCurrent() - price_crossed_jaw_up_time);
            Print("CONFIRMATION STATUS: Waiting for LIPS above TEETH (", time_remaining, " seconds remaining)");
         }
         else if (waiting_for_teeth_bearish)
         {
            int time_remaining = CONFIRMATION_WINDOW_SECONDS - (int)(TimeCurrent() - price_crossed_jaw_down_time);
            Print("CONFIRMATION STATUS: Waiting for TEETH to cross below JAW (", time_remaining, " seconds remaining)");
         }
         else if (waiting_for_lips_bearish)
         {
            int time_remaining = CONFIRMATION_WINDOW_SECONDS - (int)(TimeCurrent() - price_crossed_jaw_down_time);
            Print("CONFIRMATION STATUS: Waiting for LIPS below TEETH (", time_remaining, " seconds remaining)");
         }
         else
         {
            Print("CONFIRMATION STATUS: Not waiting (no recent sequential confirmation started)");
         }

         last_signal_debug = TimeCurrent();
      }
   }

   // WILLIAMS ALLIGATOR BUY: Sequential Crossover Confirmation
   // Step 1: Price crosses above Jaw (trigger)
   // Step 2: Lips crosses above Jaw (first confirmation)
   // Step 3: Teeth crosses above Jaw (final confirmation & entry)

   bool buy_signal = false;
   string buy_reason = "";

   // Step 1: Check for new price cross above Jaw (trigger)
   if (price_crossed_above_jaw && !waiting_for_lips_bullish && !waiting_for_teeth_bullish)
   {
      price_crossed_jaw_up_time = TimeCurrent();
      waiting_for_lips_bullish = true;
      waiting_for_lips_bearish = false; // Cancel any bearish sequence
      waiting_for_teeth_bearish = false;
      if (DEBUG_LEVEL >= 1)
         Print("🔔 STEP 1: Price crossed above Jaw - waiting for Lips to cross above Jaw");
   }

   // Step 2: Check for Lips crossing above Jaw (first confirmation)
   // CRITICAL: Only accept lips crossovers that happen AFTER price crossed jaw
   // Ensure at least 1 second has passed since price crossed jaw to prevent same-tick acceptance
   bool lips_cross_after_price = waiting_for_lips_bullish &&
                                 (TimeCurrent() - price_crossed_jaw_up_time >= 1);

   if (lips_crossed_above_jaw && lips_cross_after_price)
   {
      waiting_for_lips_bullish = false;
      waiting_for_teeth_bullish = true;
      if (DEBUG_LEVEL >= 1)
         Print("✅ STEP 2: Lips crossed above Jaw AFTER price cross - waiting for Teeth to cross above Jaw");
   }

   // Step 3: Check for final confirmation and entry
   // Verify complete Williams Alligator alignment: Price > Lips > Teeth > Jaw
   bool price_above_lips = price_current > lips_current;
   bool lips_above_teeth = lips_current > teeth_current;
   bool within_bullish_window = waiting_for_teeth_bullish &&
                                (TimeCurrent() - price_crossed_jaw_up_time <= CONFIRMATION_WINDOW_SECONDS);

   buy_signal = within_bullish_window && teeth_crossed_above_jaw && price_above_lips && lips_above_teeth;

   if (buy_signal)
   {
      buy_reason = "WILLIAMS ALLIGATOR: Full bullish alignment (Price>Lips>Teeth>Jaw + Sequential crossovers)";
      waiting_for_teeth_bullish = false; // Reset confirmation flags
   }

   // Log potential signals that don't meet all criteria
   bool potential_buy_condition = waiting_for_teeth_bullish || waiting_for_lips_bullish;

   if (potential_buy_condition && DEBUG_LEVEL >= 1)
   {
      if (!buy_signal)
      {
         Print("POTENTIAL BUY SIGNAL - but failed WILLIAMS ALLIGATOR requirements:");
         if (!within_bullish_window)
            Print("  - Not within confirmation window (", CONFIRMATION_WINDOW_SECONDS, " sec after Jaw cross)");
         if (waiting_for_teeth_bullish)
         {
            int time_since_price_cross = (int)(TimeCurrent() - price_crossed_jaw_up_time);
            Print("  - Waiting for Teeth to cross above Jaw (", time_since_price_cross, " sec since price crossed)");
            if (teeth_crossed_above_jaw && time_since_price_cross < 1)
               Print("    → Teeth crossover detected but too soon (need 1+ sec after price cross)");
         }
         if (waiting_for_lips_bullish)
         {
            int time_remaining = CONFIRMATION_WINDOW_SECONDS - (int)(TimeCurrent() - price_crossed_jaw_up_time);
            Print("  - Waiting for Lips to cross above Jaw (", time_remaining, " seconds remaining)");
         }
         if (waiting_for_teeth_bullish)
         {
            int time_remaining = CONFIRMATION_WINDOW_SECONDS - (int)(TimeCurrent() - price_crossed_jaw_up_time);
            Print("  - Waiting for Teeth to cross above Jaw (", time_remaining, " seconds remaining)");
            if (!price_above_lips)
               Print("    → Price not above Lips (", DoubleToString(price_current, _Digits), " vs ", DoubleToString(lips_current, _Digits), ")");
            if (!lips_above_teeth)
               Print("    → Lips not above Teeth (", DoubleToString(lips_current, _Digits), " vs ", DoubleToString(teeth_current, _Digits), ")");
         }
         Print("  - Mode: WILLIAMS ALLIGATOR (Sequential crossover: Price→Lips→Teeth)");
      }
   }

   if (buy_signal)
   {
      if (DEBUG_LEVEL >= 1)
         Print("🔵 BUY SIGNAL DETECTED: ", buy_reason);

      ExecuteBuyOrder();
      last_signal_time = TimeCurrent();
      return;
   }

   // WILLIAMS ALLIGATOR SELL: Sequential Crossover Confirmation
   // Step 1: Price crosses below Jaw (trigger)
   // Step 2: Lips crosses below Jaw (first confirmation)
   // Step 3: Teeth crosses below Jaw (final confirmation & entry)

   bool sell_signal = false;
   string sell_reason = "";

   // Step 1: Check for new price cross below Jaw (trigger)
   if (price_crossed_below_jaw && !waiting_for_lips_bearish && !waiting_for_teeth_bearish)
   {
      price_crossed_jaw_down_time = TimeCurrent();
      waiting_for_lips_bearish = true;
      waiting_for_lips_bullish = false; // Cancel any bullish sequence
      waiting_for_teeth_bullish = false;
      if (DEBUG_LEVEL >= 1)
         Print("🔔 STEP 1: Price crossed below Jaw - waiting for Lips to cross below Jaw");
   }

   // Step 2: Check for Lips crossing below Jaw (first confirmation)
   // CRITICAL: Only accept lips crossovers that happen AFTER price crossed jaw
   // Ensure at least 1 second has passed since price crossed jaw to prevent same-tick acceptance
   bool lips_cross_after_price_bearish = waiting_for_lips_bearish &&
                                         (TimeCurrent() - price_crossed_jaw_down_time >= 1);

   if (lips_crossed_below_jaw && lips_cross_after_price_bearish)
   {
      waiting_for_lips_bearish = false;
      waiting_for_teeth_bearish = true;
      if (DEBUG_LEVEL >= 1)
         Print("✅ STEP 2: Lips crossed below Jaw AFTER price cross - waiting for Teeth to cross below Jaw");
   }

   // Step 3: Check for final confirmation and entry
   // Verify complete Williams Alligator alignment: Jaw > Teeth > Lips > Price
   bool price_below_lips = price_current < lips_current;
   bool lips_below_teeth = lips_current < teeth_current;
   bool within_bearish_window = waiting_for_teeth_bearish &&
                                (TimeCurrent() - price_crossed_jaw_down_time <= CONFIRMATION_WINDOW_SECONDS);

   sell_signal = within_bearish_window && teeth_crossed_below_jaw && price_below_lips && lips_below_teeth;

   if (sell_signal)
   {
      sell_reason = "WILLIAMS ALLIGATOR: Full bearish alignment (Jaw>Teeth>Lips>Price + Sequential crossovers)";
      waiting_for_teeth_bearish = false; // Reset confirmation flags
   }

   // Log potential signals that don't meet all criteria
   bool potential_sell_condition = waiting_for_teeth_bearish || waiting_for_lips_bearish;

   if (potential_sell_condition && DEBUG_LEVEL >= 1)
   {
      if (!sell_signal)
      {
         Print("POTENTIAL SELL SIGNAL - but failed WILLIAMS ALLIGATOR requirements:");
         if (!within_bearish_window)
            Print("  - Not within confirmation window (", CONFIRMATION_WINDOW_SECONDS, " sec after Jaw cross)");
         if (waiting_for_teeth_bearish)
         {
            int time_since_price_cross = (int)(TimeCurrent() - price_crossed_jaw_down_time);
            Print("  - Waiting for Teeth to cross below Jaw (", time_since_price_cross, " sec since price crossed)");
            if (teeth_crossed_below_jaw && time_since_price_cross < 1)
               Print("    → Teeth crossover detected but too soon (need 1+ sec after price cross)");
         }
         if (waiting_for_lips_bearish)
         {
            int time_remaining = CONFIRMATION_WINDOW_SECONDS - (int)(TimeCurrent() - price_crossed_jaw_down_time);
            Print("  - Waiting for Lips to cross below Jaw (", time_remaining, " seconds remaining)");
         }
         if (waiting_for_teeth_bearish)
         {
            int time_remaining = CONFIRMATION_WINDOW_SECONDS - (int)(TimeCurrent() - price_crossed_jaw_down_time);
            Print("  - Waiting for Teeth to cross below Jaw (", time_remaining, " seconds remaining)");
            if (!price_below_lips)
               Print("    → Price not below Lips (", DoubleToString(price_current, _Digits), " vs ", DoubleToString(lips_current, _Digits), ")");
            if (!lips_below_teeth)
               Print("    → Lips not below Teeth (", DoubleToString(lips_current, _Digits), " vs ", DoubleToString(teeth_current, _Digits), ")");
         }
         Print("  - Mode: WILLIAMS ALLIGATOR (Sequential crossover: Price→Lips→Teeth)");
      }
   }

   if (sell_signal)
   {
      if (DEBUG_LEVEL >= 1)
         Print("🔴 SELL SIGNAL DETECTED: ", sell_reason);

      ExecuteSellOrder();
      last_signal_time = TimeCurrent();
      return;
   }

   // Reset confirmation flags if windows expire
   if ((waiting_for_teeth_bullish || waiting_for_lips_bullish) && (TimeCurrent() - price_crossed_jaw_up_time > CONFIRMATION_WINDOW_SECONDS))
   {
      waiting_for_teeth_bullish = false;
      waiting_for_lips_bullish = false;
      if (DEBUG_LEVEL >= 1)
         Print("⏰ TIMEOUT: Bullish sequential confirmation window expired");
   }

   if ((waiting_for_teeth_bearish || waiting_for_lips_bearish) && (TimeCurrent() - price_crossed_jaw_down_time > CONFIRMATION_WINDOW_SECONDS))
   {
      waiting_for_teeth_bearish = false;
      waiting_for_lips_bearish = false;
      if (DEBUG_LEVEL >= 1)
         Print("⏰ TIMEOUT: Bearish sequential confirmation window expired");
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
      profit_target = risk_amount * TAKE_PROFIT_MULT;

      Print("⚠️ POSITION SIZE REDUCED FOR SAFETY:");
      Print("  Original position would be ", DoubleToString(position_as_percent_of_account, 1), "% of account");
      Print("  Reduced to 50% of account for safety");
      Print("  New risk amount: $", DoubleToString(risk_amount, 2));
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
   Print("ATR value: $", DoubleToString(atr_value, 2), " (", ATR_STOP_LOSS_PERIOD, "-period)");
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
      profit_target = risk_amount * TAKE_PROFIT_MULT;

      Print("⚠️ POSITION SIZE REDUCED FOR SAFETY:");
      Print("  Original position would be ", DoubleToString(position_as_percent_of_account, 1), "% of account");
      Print("  Reduced to 50% of account for safety");
      Print("  New risk amount: $", DoubleToString(risk_amount, 2));
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
   Print("ATR value: $", DoubleToString(atr_value, 2), " (", ATR_STOP_LOSS_PERIOD, "-period)");
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
               ", Lots=", DoubleToString(lot_size, 6));
   }
   else
   {
      Print("*** ALL SELL ORDER ATTEMPTS FAILED ***");
      Print("Final error: ", result.retcode, " - ", GetTradeErrorDescription(result.retcode));
      Print("Entry price: ", DoubleToString(entry_price, _Digits));
      Print("Stop loss: ", DoubleToString(stop_loss, _Digits));
      Print("Take profit: ", DoubleToString(take_profit, _Digits));
      Print("Lot size: ", DoubleToString(lot_size, 6));
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
      return;
   }

   // Check for early exit signals based on Alligator
   bool should_exit = false;
   string exit_reason = "";

   if (current_direction == LONG_TRADE)
   {
      // WILLIAMS ALLIGATOR EXIT: Price candle closes below Lips (Green line) - momentum weakening
      if (price_current < lips_current && price_previous >= lips_previous)
      {
         should_exit = true;
         exit_reason = "WILLIAMS ALLIGATOR EXIT: Price closed below Lips - bullish momentum weakening";
      }
   }
   else if (current_direction == SHORT_TRADE)
   {
      // WILLIAMS ALLIGATOR EXIT: Price candle closes above Lips (Green line) - momentum weakening
      if (price_current > lips_current && price_previous <= lips_previous)
      {
         should_exit = true;
         exit_reason = "WILLIAMS ALLIGATOR EXIT: Price closed above Lips - bearish momentum weakening";
      }
   }

   if (should_exit)
   {
      ClosePosition(exit_reason);
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
      }
   }
   else
   {
      status = "Looking for entry signals";
   }

   // Check line alignment for WILLIAMS ALLIGATOR trend indication
   string trend_status = "";
   bool bullish_stack = (lips_current > teeth_current && teeth_current > jaw_current);
   bool bearish_stack = (jaw_current > teeth_current && teeth_current > lips_current);

   if (bullish_stack)
      trend_status = "BULLISH TREND (Green>Red>Blue) - Alligator mouth open up";
   else if (bearish_stack)
      trend_status = "BEARISH TREND (Blue>Red>Green) - Alligator mouth open down";
   else if (lips_current > teeth_current)
      trend_status = "POTENTIAL BULLISH (Green>Red, waiting for full stack)";
   else if (lips_current < teeth_current)
      trend_status = "POTENTIAL BEARISH (Red>Green, waiting for full stack)";
   else
      trend_status = "SIDEWAYS/SLEEPING ALLIGATOR (Mixed lines)";

   string info = StringFormat(
       "BTCUSD Alligator Scalper | Trades Today: %d/%d\n" +
           "Status: %s\n" +
           "Trend: %s\n" +
           "Price: %s | Jaw: %s | Teeth: %s | Lips: %s\n" +
           "Risk per trade: %.1f%% | Max trades: %d",
       trades_today, MAX_TRADES_PER_DAY,
       status,
       trend_status,
       DoubleToString(price_current, _Digits),
       DoubleToString(jaw_current, _Digits),
       DoubleToString(teeth_current, _Digits),
       DoubleToString(lips_current, _Digits),
       RISK_PER_TRADE_PCT,
       MAX_TRADES_PER_DAY);

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
   // Get basic trading statistics
   double profit = TesterStatistics(STAT_PROFIT);
   double drawdown = TesterStatistics(STAT_BALANCE_DD);
   double max_drawdown_pct = TesterStatistics(STAT_BALANCE_DDREL_PERCENT); // Max drawdown as percentage
   double trades = TesterStatistics(STAT_TRADES);
   double profit_factor = TesterStatistics(STAT_PROFIT_FACTOR);
   double sharpe_ratio = TesterStatistics(STAT_SHARPE_RATIO);

   // If no trades or negative profit, return worst possible value
   if (trades == 0 || profit <= 0)
      return 0;

   // If drawdown is zero, adjust to small value to avoid division by zero
   if (drawdown == 0)
      drawdown = 0.01;

   // Heavily penalize high drawdowns (>50%)
   double drawdown_multiplier = 1.0;
   if (max_drawdown_pct > 40)
      drawdown_multiplier = 0.1; // Severe penalty but not complete rejection

   // Profit is the dominant factor - use a much higher power to emphasize it
   double profit_weight = 4.0; // Extremely high weight for profit

   // Drawdown is minor factor - use very small penalty
   double drawdown_penalty = 3; // Minimal impact from drawdown

   // Core formula: Massively prioritize profit, with minimal drawdown impact
   // Profit^4 makes profit extremely dominant
   double custom_criterion = MathPow(profit, profit_weight) / MathPow(drawdown, drawdown_penalty);

   // Profit factor enhances profit emphasis
   if (profit_factor > 1.0)
      custom_criterion *= profit_factor;

   // For scalping strategies, adjust minimum trades for statistical significance
   double min_trades_target = 50; // Higher minimum for scalping due to more frequent trades

   // Trade count multiplier - reaches 1.0 at min_trades_target
   double trade_multiplier = MathMin(1.0, trades / min_trades_target);

   // Final score - completely dominated by profit with minimal consideration for drawdown
   return custom_criterion * trade_multiplier * drawdown_multiplier;
}

//+------------------------------------------------------------------+