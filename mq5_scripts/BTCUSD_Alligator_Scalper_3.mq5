//+------------------------------------------------------------------+
//|                     BTCUSD Alligator Trend Scalper                |
//|                 Simple Williams Alligator Strategy                |
//|               Copyright 2025 - free to use / modify               |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025"
#property version "3.00"
#property strict

//============================================================================
//                           USER SETTINGS
//============================================================================

// Risk Management
input double RISK_PERCENT = 2.0; // Risk per trade (% of account)
input double REWARD_RATIO = 2.0; // Reward:Risk ratio (2.0 = 2:1)
input int MAX_DAILY_TRADES = 50; // Maximum trades per day

// Alligator Indicator Settings
input int JAW_PERIOD = 13;  // Jaw period (Blue line - slowest)
input int JAW_SHIFT = 8;    // Jaw shift
input int TEETH_PERIOD = 8; // Teeth period (Red line - medium)
input int TEETH_SHIFT = 5;  // Teeth shift
input int LIPS_PERIOD = 5;  // Lips period (Green line - fastest)
input int LIPS_SHIFT = 3;   // Lips shift

// Strategy Parameters
input int ATR_PERIOD = 14;              // ATR period for volatility measurement
input double ATR_STOP_MULTIPLIER = 1.5; // Stop loss = ATR × this multiplier

// Alligator Mouth Dynamics
// These parameters control when the alligator "mouth" is considered open (lines diverging vs horizontal)
input double MIN_GATOR_DIVERGENCE_ANGLE = 1.0;     // Minimum angle difference between lines for mouth opening (degrees)
input double MIN_GATOR_SLOPE_FOR_DIVERGENCE = 0.5; // Minimum line slope required for divergence detection (degrees)
input int MIN_SLEEPING_BARS = 8;                   // Minimum bars alligator must sleep before breakout
input int MAX_BREAKOUT_BARS = 6;                   // Maximum bars to cross all three lines
input int MOUTH_OPENING_WINDOW = 10;               // Bars to wait for mouth to open after entry
input double MAX_LINE_SLOPE = 2.0;                 // Maximum line slope angle (degrees) for "horizontal" lines
input int SLOPE_CHECK_BARS = 3;                    // Bars to analyze for line slope calculation

// Breakout Slope Validation
input double MIN_BREAKOUT_SLOPE = 10.0;   // Minimum closing price slope angle (degrees) for valid breakout
input int REQUIRED_CANDLES_AFTER_JAW = 1; // Number of candles that must close beyond jaw in trend direction

// Trading Controls
input int SIGNAL_COOLDOWN_MINUTES = 3; // Minutes between signals
input bool SHOW_INFO_PANEL = true;     // Show information on chart
input int DEBUG_LEVEL = 1;             // 0=none, 1=basic, 2=detailed

//============================================================================
//                         GLOBAL VARIABLES
//============================================================================

// Indicator handles
int alligator_handle = INVALID_HANDLE;
int atr_handle = INVALID_HANDLE;

// Current market data
double price = 0;                    // Current price
double lips = 0, teeth = 0, jaw = 0; // Alligator lines
double atr_value = 0;                // Current ATR value

// Trading state enum (must be declared first)
enum TrendDirection
{
   NO_TREND = 0,
   BULLISH_TREND = 1,
   BEARISH_TREND = 2
};

// Alligator state tracking
bool is_sleeping = false;          // Are lines close together?
bool is_bullish_awake = false;     // Proper bullish alignment?
bool is_bearish_awake = false;     // Proper bearish alignment?
bool lines_are_horizontal = false; // Are lines relatively flat?
datetime sleep_start_time = 0;     // When did alligator start sleeping?
int sleep_bar_count = 0;           // How many bars has alligator been sleeping?

// Breakout tracking
bool monitoring_breakout = false;             // Are we monitoring a potential breakout?
datetime breakout_start_time = 0;             // When did price start crossing lines?
int lines_crossed = 0;                        // How many lines has price crossed?
TrendDirection breakout_direction = NO_TREND; // Direction of breakout
bool lips_crossed = false;                    // Has price crossed the lips line?
bool teeth_crossed = false;                   // Has price crossed the teeth line?
bool jaw_crossed = false;                     // Has price crossed the jaw line?
int candles_after_jaw = 0;                    // Count of candles closed beyond jaw in trend direction
double breakout_closes[];                     // Array to store closing prices during breakout

// Position and mouth opening tracking
ulong current_position_ticket = 0;
datetime entry_time = 0;             // When we entered the trade
bool waiting_for_mouth_open = false; // Are we waiting for mouth to open?
bool mouth_has_opened = false;       // Has mouth opened after entry?
int daily_trade_count = 0;
datetime last_trade_date = 0;
datetime last_signal_time = 0;

// Trading state variables
TrendDirection current_trend = NO_TREND;
TrendDirection position_direction = NO_TREND;

//============================================================================
//                         INITIALIZATION
//============================================================================

int OnInit()
{
   Print("=== BTCUSD Alligator Trend Scalper Starting ===");

   // Validate symbol
   if (StringFind(_Symbol, "BTC") < 0)
      Print("WARNING: Designed for BTCUSD, running on: ", _Symbol);

   // Initialize Alligator
   alligator_handle = iAlligator(_Symbol, _Period,
                                 JAW_PERIOD, JAW_SHIFT,
                                 TEETH_PERIOD, TEETH_SHIFT,
                                 LIPS_PERIOD, LIPS_SHIFT,
                                 MODE_SMMA, PRICE_MEDIAN);

   if (alligator_handle == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create Alligator indicator");
      return INIT_FAILED;
   }

   // Initialize ATR
   atr_handle = iATR(_Symbol, _Period, ATR_PERIOD);

   if (atr_handle == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create ATR indicator");
      return INIT_FAILED;
   }

   // Reset counters
   ResetDailyTrades();

   Print("=== ADVANCED ALLIGATOR SCALPER INITIALIZED ===");
   Print("Timeframe: ", TimeframeToString(_Period));
   Print("Risk per trade: ", RISK_PERCENT, "%");
   Print("Reward ratio: ", REWARD_RATIO, ":1");
   Print("Max daily trades: ", MAX_DAILY_TRADES);
   Print("--- Alligator Parameters ---");
   Print("Minimum sleeping bars: ", MIN_SLEEPING_BARS);
   Print("Maximum breakout bars: ", MAX_BREAKOUT_BARS);
   Print("Mouth opening window: ", MOUTH_OPENING_WINDOW, " bars");
   Print("--- Gator Mouth Divergence Detection ---");
   Print("Minimum divergence angle: ", MIN_GATOR_DIVERGENCE_ANGLE, "° (lines must differ by this much)");
   Print("Minimum slope for divergence: ", MIN_GATOR_SLOPE_FOR_DIVERGENCE, "° (at least one line must have this slope)");
   Print("Line horizontal threshold: ", MAX_LINE_SLOPE, "° (sleeping when all lines below this)");
   Print("Slope check period: ", SLOPE_CHECK_BARS, " bars");
   Print("--- Trading Logic ---");
   Print("Breakout entry: Price crosses all lines after sleep period (no divergence required)");
   Print("Mouth opening: Lines must be aligned AND diverging during MOUTH_OPENING_WINDOW");
   Print("--- Breakout Slope Validation ---");
   Print("Minimum breakout slope: ", MIN_BREAKOUT_SLOPE, "° angle");
   Print("Required candles after jaw: ", REQUIRED_CANDLES_AFTER_JAW);
   Print("==============================================");

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if (alligator_handle != INVALID_HANDLE)
      IndicatorRelease(alligator_handle);
   if (atr_handle != INVALID_HANDLE)
      IndicatorRelease(atr_handle);

   Comment("");
   Print("Alligator Scalper stopped");
}

//============================================================================
//                            MAIN LOGIC
//============================================================================

void OnTick()
{
   // Reset daily counter if new day
   ResetDailyTrades();

   // Check daily limit
   if (daily_trade_count >= MAX_DAILY_TRADES)
   {
      if (SHOW_INFO_PANEL)
         ShowInfoPanel();
      return;
   }

   // Update market data
   if (!UpdateMarketData())
   {
      if (DEBUG_LEVEL >= 1)
         Print("Failed to update market data");
      return;
   }

   // Analyze alligator state
   AnalyzeAlligatorState();

   // Handle existing position
   if (current_position_ticket != 0)
   {
      ManageOpenPosition();
   }
   else
   {
      // Look for new trading opportunities
      CheckForTradeSignals();
   }

   // Update display
   if (SHOW_INFO_PANEL)
      ShowInfoPanel();
}

//============================================================================
//                         MARKET DATA UPDATE
//============================================================================

bool UpdateMarketData()
{
   // Get current price (use close price to avoid noise)
   double close_prices[1];
   if (CopyClose(_Symbol, _Period, 0, 1, close_prices) <= 0)
   {
      price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   }
   else
   {
      price = close_prices[0];
   }

   // Get Alligator lines
   double jaw_buffer[1], teeth_buffer[1], lips_buffer[1];

   if (CopyBuffer(alligator_handle, 0, 0, 1, jaw_buffer) <= 0 ||
       CopyBuffer(alligator_handle, 1, 0, 1, teeth_buffer) <= 0 ||
       CopyBuffer(alligator_handle, 2, 0, 1, lips_buffer) <= 0)
   {
      return false;
   }

   jaw = jaw_buffer[0];
   teeth = teeth_buffer[0];
   lips = lips_buffer[0];

   // Get ATR value
   double atr_buffer[1];
   if (CopyBuffer(atr_handle, 0, 0, 1, atr_buffer) <= 0)
   {
      atr_value = 100.0; // Fallback for BTCUSD
   }
   else
   {
      atr_value = atr_buffer[0];
   }

   return true;
}

//============================================================================
//                      ALLIGATOR STATE ANALYSIS
//============================================================================

void AnalyzeAlligatorState()
{
   // Check if lines are horizontal (low slope) - this determines sleeping
   lines_are_horizontal = CheckLinesAreHorizontal(MAX_LINE_SLOPE);

   // Check if lines are sloping away from each other (diverging slopes) - this determines awaking
   bool lines_are_diverging = CheckLinesAreDiverging();

   // Update sleeping state and tracking
   static datetime last_sleep_bar = 0;

   if (lines_are_horizontal)
   {
      if (!is_sleeping)
      {
         // Just started sleeping
         is_sleeping = true;
         sleep_start_time = TimeCurrent();
         sleep_bar_count = 1;
         last_sleep_bar = iTime(_Symbol, _Period, 0);
         if (DEBUG_LEVEL >= 1)
            Print("😴 ALLIGATOR SLEEPING: Lines are horizontal");
      }
      else
      {
         // Continue sleeping - increment bar count only once per bar
         datetime current_bar = iTime(_Symbol, _Period, 0);
         if (current_bar != last_sleep_bar)
         {
            sleep_bar_count++;
            last_sleep_bar = current_bar;

            // Notify when ready for breakout monitoring
            if (sleep_bar_count == MIN_SLEEPING_BARS && DEBUG_LEVEL >= 1)
            {
               Print("✅ BREAKOUT MONITORING ACTIVE: Slept for ", MIN_SLEEPING_BARS, " bars - ready for breakouts");
            }
         }
      }
   }
   else
   {
      // Not sleeping anymore - reset everything
      if (is_sleeping && DEBUG_LEVEL >= 1)
         Print("👁️ ALLIGATOR AWAKENING: Lines no longer horizontal - breakout monitoring reset");

      is_sleeping = false;
      sleep_start_time = 0;
      sleep_bar_count = 0;

      // Don't reset active breakout monitoring - let MAX_BREAKOUT_BARS handle timeout
      // Once breakout monitoring starts, it should only be reset by:
      // 1. Successful trade execution, 2. MAX_BREAKOUT_BARS timeout,
      // 3. Failed slope validation, 4. Direction reversal
      if (monitoring_breakout && DEBUG_LEVEL >= 1)
      {
         Print("👁️ ALLIGATOR AWAKENING during active breakout - continuing monitoring within MAX_BREAKOUT_BARS window");
      }
   }

   // Check for proper alligator alignment (used for trend detection, NOT breakout entry)
   // Breakout entry is handled separately in MonitorBreakoutProgress()
   is_bullish_awake = (price > lips &&
                       lips > teeth &&
                       teeth > jaw); // Traditional bullish alligator alignment

   is_bearish_awake = (price < lips &&
                       lips < teeth &&
                       teeth < jaw); // Traditional bearish alligator alignment

   // Determine current trend
   if (is_bullish_awake)
      current_trend = BULLISH_TREND;
   else if (is_bearish_awake)
      current_trend = BEARISH_TREND;
   else
      current_trend = NO_TREND;

   // Monitor breakout progress if applicable
   // Start new monitoring only when sleeping requirements met
   // Continue existing monitoring regardless of sleep state
   if ((sleep_bar_count >= MIN_SLEEPING_BARS && !monitoring_breakout) || monitoring_breakout)
   {
      MonitorBreakoutProgress();
   }

   // Simple status at DEBUG_LEVEL 1
   if (DEBUG_LEVEL >= 1)
   {
      static datetime last_simple_debug = 0;
      static string last_status = "";
      if (TimeCurrent() - last_simple_debug > 60) // Every 60 seconds
      {
         string current_status = "";

         if (monitoring_breakout)
         {
            int breakout_bars = (int)((TimeCurrent() - breakout_start_time) / PeriodSeconds());
            string direction = (breakout_direction == BULLISH_TREND) ? "BULLISH" : "BEARISH";
            current_status = "🚀 ACTIVE BREAKOUT: " + direction + " " + IntegerToString(lines_crossed) + "/3 lines (" +
                             IntegerToString(breakout_bars) + "/" + IntegerToString(MAX_BREAKOUT_BARS) + " bars)";
         }
         else if (is_sleeping && sleep_bar_count >= MIN_SLEEPING_BARS)
         {
            current_status = "😴 READY: Sleeping " + IntegerToString(sleep_bar_count) + " bars - monitoring for breakout";
         }
         else if (is_sleeping)
         {
            current_status = "😴 SLEEPING: " + IntegerToString(sleep_bar_count) + "/" + IntegerToString(MIN_SLEEPING_BARS) +
                             " bars - need " + IntegerToString(MIN_SLEEPING_BARS - sleep_bar_count) + " more";
         }
         else
         {
            if (monitoring_breakout)
               current_status = "👁️ AWAKE: Lines moving during active breakout";
            else
               current_status = "👁️ AWAKE: Lines not horizontal - no new breakout monitoring";
         }

         // Only print if status changed
         if (current_status != last_status)
         {
            Print("📊 ALLIGATOR STATUS: ", current_status);
            last_status = current_status;
         }
         last_simple_debug = TimeCurrent();
      }
   }

   // Debug output
   if (DEBUG_LEVEL >= 2)
   {
      static datetime last_debug = 0;
      if (TimeCurrent() - last_debug > 30) // Every 30 seconds
      {
         Print("=== ALLIGATOR STRATEGY STATUS ===");
         Print("💰 Price: ", DoubleToString(price, _Digits));
         Print("📊 Lines: Lips=", DoubleToString(lips, _Digits),
               " | Teeth=", DoubleToString(teeth, _Digits),
               " | Jaw=", DoubleToString(jaw, _Digits));

         // Main status explanation
         if (is_sleeping)
         {
            if (sleep_bar_count >= MIN_SLEEPING_BARS)
               Print("😴 SLEEPING: ", sleep_bar_count, " bars ✅ READY for breakout");
            else
               Print("😴 SLEEPING: ", sleep_bar_count, "/", MIN_SLEEPING_BARS, " bars ⏳ Need more sleep");
         }
         else
         {
            if (monitoring_breakout)
               Print("👁️ AWAKE: Lines moving during active breakout");
            else
               Print("👁️ AWAKE: Lines not horizontal - no new breakout monitoring");
         }

         // Breakout monitoring status
         if (monitoring_breakout)
         {
            int breakout_bars = (int)((TimeCurrent() - breakout_start_time) / PeriodSeconds());
            string direction = (breakout_direction == BULLISH_TREND) ? "BULLISH" : "BEARISH";
            Print("🚀 BREAKOUT: ", direction, " ", lines_crossed, "/3 lines (", breakout_bars, "/", MAX_BREAKOUT_BARS, " bars)");
         }
         else if (sleep_bar_count >= MIN_SLEEPING_BARS)
         {
            Print("⏳ MONITORING: Ready for breakout detection");
         }
         else
         {
            Print("🛑 NOT MONITORING: Need ", MIN_SLEEPING_BARS - sleep_bar_count, " more sleep bars");
         }

         // Additional info
         if (lines_are_diverging)
            Print("📈 Lines diverging: YES (ready for mouth opening confirmation)");

         last_debug = TimeCurrent();
      }
   }
}

//============================================================================
//                         ADVANCED ALLIGATOR ANALYSIS
//============================================================================

bool CheckLinesAreHorizontal(double max_slope)
{
   // Get historical alligator values to check slope
   double jaw_buffer[], teeth_buffer[], lips_buffer[];

   if (CopyBuffer(alligator_handle, 0, 0, SLOPE_CHECK_BARS, jaw_buffer) <= 0 ||
       CopyBuffer(alligator_handle, 1, 0, SLOPE_CHECK_BARS, teeth_buffer) <= 0 ||
       CopyBuffer(alligator_handle, 2, 0, SLOPE_CHECK_BARS, lips_buffer) <= 0)
   {
      return true; // Default to horizontal if can't get data
   }

   // Calculate actual slope angles (timeframe-independent)
   double jaw_angle = CalculateSlopeAngle(jaw_buffer[SLOPE_CHECK_BARS - 1], jaw_buffer[0], SLOPE_CHECK_BARS);
   double teeth_angle = CalculateSlopeAngle(teeth_buffer[SLOPE_CHECK_BARS - 1], teeth_buffer[0], SLOPE_CHECK_BARS);
   double lips_angle = CalculateSlopeAngle(lips_buffer[SLOPE_CHECK_BARS - 1], lips_buffer[0], SLOPE_CHECK_BARS);

   // All lines must be relatively horizontal (below max angle threshold)
   return (jaw_angle <= max_slope && teeth_angle <= max_slope && lips_angle <= max_slope);
}

bool CheckLinesAreDiverging()
{
   // Get historical alligator values to check slope
   double jaw_buffer[], teeth_buffer[], lips_buffer[];

   if (CopyBuffer(alligator_handle, 0, 0, SLOPE_CHECK_BARS, jaw_buffer) <= 0 ||
       CopyBuffer(alligator_handle, 1, 0, SLOPE_CHECK_BARS, teeth_buffer) <= 0 ||
       CopyBuffer(alligator_handle, 2, 0, SLOPE_CHECK_BARS, lips_buffer) <= 0)
   {
      return false; // Default to not diverging if can't get data
   }

   // Calculate actual slope angles (timeframe-independent)
   double jaw_angle = CalculateSlopeAngle(jaw_buffer[SLOPE_CHECK_BARS - 1], jaw_buffer[0], SLOPE_CHECK_BARS);
   double teeth_angle = CalculateSlopeAngle(teeth_buffer[SLOPE_CHECK_BARS - 1], teeth_buffer[0], SLOPE_CHECK_BARS);
   double lips_angle = CalculateSlopeAngle(lips_buffer[SLOPE_CHECK_BARS - 1], lips_buffer[0], SLOPE_CHECK_BARS);

   // Calculate slope differences to detect divergence
   double jaw_teeth_diff = MathAbs(jaw_angle - teeth_angle);
   double teeth_lips_diff = MathAbs(teeth_angle - lips_angle);
   double jaw_lips_diff = MathAbs(jaw_angle - lips_angle);

   // Lines are diverging if slopes are significantly different from each other
   // AND at least one line has significant slope (not all flat)
   bool slopes_are_different = (jaw_teeth_diff >= MIN_GATOR_DIVERGENCE_ANGLE ||
                                teeth_lips_diff >= MIN_GATOR_DIVERGENCE_ANGLE ||
                                jaw_lips_diff >= MIN_GATOR_DIVERGENCE_ANGLE);

   bool has_meaningful_slope = (MathAbs(jaw_angle) >= MIN_GATOR_SLOPE_FOR_DIVERGENCE ||
                                MathAbs(teeth_angle) >= MIN_GATOR_SLOPE_FOR_DIVERGENCE ||
                                MathAbs(lips_angle) >= MIN_GATOR_SLOPE_FOR_DIVERGENCE);

   // Debug output for divergence detection
   if (DEBUG_LEVEL >= 2 && (slopes_are_different || has_meaningful_slope))
   {
      static datetime last_divergence_debug = 0;
      if (TimeCurrent() - last_divergence_debug > 60) // Every 60 seconds
      {
         Print("=== GATOR MOUTH DIVERGENCE ANALYSIS ===");
         Print("Line angles: Jaw=", DoubleToString(jaw_angle, 2), "° | Teeth=", DoubleToString(teeth_angle, 2), "° | Lips=", DoubleToString(lips_angle, 2), "°");
         Print("Angle differences: Jaw↔Teeth=", DoubleToString(jaw_teeth_diff, 2), "° | Teeth↔Lips=", DoubleToString(teeth_lips_diff, 2), "° | Jaw↔Lips=", DoubleToString(jaw_lips_diff, 2), "°");
         Print("Slopes different: ", slopes_are_different ? "YES" : "NO", " (need ≥ ", MIN_GATOR_DIVERGENCE_ANGLE, "°)");
         Print("Has meaningful slope: ", has_meaningful_slope ? "YES" : "NO", " (need ≥ ", MIN_GATOR_SLOPE_FOR_DIVERGENCE, "°)");
         Print("Lines diverging: ", (slopes_are_different && has_meaningful_slope) ? "YES" : "NO");
         Print("=====================================");
         last_divergence_debug = TimeCurrent();
      }
   }

   return (slopes_are_different && has_meaningful_slope);
}

void MonitorBreakoutProgress()
{
   // Sleep requirement only applies to STARTING new monitoring
   // Continue existing monitoring regardless of sleep state
   if (sleep_bar_count < MIN_SLEEPING_BARS && !monitoring_breakout)
   {
      if (DEBUG_LEVEL >= 2)
         Print("⚠️ MonitorBreakoutProgress called but sleep requirement not met for NEW monitoring (", sleep_bar_count, "/", MIN_SLEEPING_BARS, ")");
      return;
   }

   // Rate limiting - only process once per bar to avoid spam
   static datetime last_breakout_check = 0;
   datetime current_bar = iTime(_Symbol, _Period, 0);
   if (current_bar == last_breakout_check)
   {
      if (DEBUG_LEVEL >= 3)
         Print("⏸️ Breakout check skipped - already processed this bar");
      return; // Already processed this bar
   }
   last_breakout_check = current_bar;

   // PROGRESSIVE LINE CROSSING DETECTION
   // Check for new line crossings during monitoring period

   // Detect bullish line crossings (price moving above lines)
   bool new_bullish_lips = (!lips_crossed && price > lips);
   bool new_bullish_teeth = (!teeth_crossed && price > teeth);
   bool new_bullish_jaw = (!jaw_crossed && price > jaw);

   // Detect bearish line crossings (price moving below lines)
   bool new_bearish_lips = (!lips_crossed && price < lips);
   bool new_bearish_teeth = (!teeth_crossed && price < teeth);
   bool new_bearish_jaw = (!jaw_crossed && price < jaw);

   // Start monitoring on ANY line crossing if not already monitoring
   if (!monitoring_breakout)
   {
      bool should_start_monitoring = false;
      TrendDirection initial_direction = NO_TREND;

      if (new_bullish_lips || new_bullish_teeth || new_bullish_jaw)
      {
         should_start_monitoring = true;
         initial_direction = BULLISH_TREND;
      }
      else if (new_bearish_lips || new_bearish_teeth || new_bearish_jaw)
      {
         should_start_monitoring = true;
         initial_direction = BEARISH_TREND;
      }

      if (should_start_monitoring)
      {
         monitoring_breakout = true;
         breakout_start_time = TimeCurrent();
         breakout_direction = initial_direction;
         candles_after_jaw = 0;
         lines_crossed = 0;

         // Mark which lines were crossed in this detection
         if (initial_direction == BULLISH_TREND)
         {
            if (new_bullish_lips)
            {
               lips_crossed = true;
               lines_crossed++;
            }
            if (new_bullish_teeth)
            {
               teeth_crossed = true;
               lines_crossed++;
            }
            if (new_bullish_jaw)
            {
               jaw_crossed = true;
               lines_crossed++;
            }
         }
         else
         {
            if (new_bearish_lips)
            {
               lips_crossed = true;
               lines_crossed++;
            }
            if (new_bearish_teeth)
            {
               teeth_crossed = true;
               lines_crossed++;
            }
            if (new_bearish_jaw)
            {
               jaw_crossed = true;
               lines_crossed++;
            }
         }

         // Initialize closing price tracking - start with initial breakout price
         ArrayResize(breakout_closes, 0);
         ArrayResize(breakout_closes, 1);
         breakout_closes[0] = price;

         if (DEBUG_LEVEL >= 1)
         {
            string crossed_lines = "";
            if (lips_crossed)
               crossed_lines += "Lips ";
            if (teeth_crossed)
               crossed_lines += "Teeth ";
            if (jaw_crossed)
               crossed_lines += "Jaw ";

            Print("🚀 BREAKOUT STARTED: Price crossed ", crossed_lines, "direction: ",
                  initial_direction == BULLISH_TREND ? "BULLISH" : "BEARISH");
            Print("  💰 Initial price: ", DoubleToString(price, _Digits));
            Print("  📊 Lines: Jaw=", DoubleToString(jaw, _Digits), " | Teeth=", DoubleToString(teeth, _Digits), " | Lips=", DoubleToString(lips, _Digits));
            Print("  📈 Progress: ", lines_crossed, "/3 lines crossed | Starting price data collection...");
         }
         return; // Exit early to avoid double-processing on detection bar
      }
   }

   // Update progress if already monitoring
   if (monitoring_breakout)
   {
      // Add current price to tracking array once per bar only (skip the detection bar)
      int current_data_points = ArraySize(breakout_closes);
      int breakout_bars = (int)((TimeCurrent() - breakout_start_time) / PeriodSeconds());

      // Only add price data if this is a new bar (not the detection bar)
      if (breakout_bars > 0 && current_data_points <= breakout_bars)
      {
         ArrayResize(breakout_closes, current_data_points + 1);
         breakout_closes[current_data_points] = price;

         if (DEBUG_LEVEL >= 2)
         {
            double price_change = price - breakout_closes[0];
            Print("📈 BAR ", breakout_bars, " DATA: Price=", DoubleToString(price, _Digits),
                  " | Change=", DoubleToString(price_change, 2), " pts from start");
         }
      }

      // Check for NEW line crossings during monitoring (progressive crossing)
      bool new_line_crossed = false;
      string newly_crossed = "";

      if (breakout_direction == BULLISH_TREND)
      {
         if (new_bullish_lips)
         {
            lips_crossed = true;
            lines_crossed++;
            new_line_crossed = true;
            newly_crossed += "Lips ";
         }
         if (new_bullish_teeth)
         {
            teeth_crossed = true;
            lines_crossed++;
            new_line_crossed = true;
            newly_crossed += "Teeth ";
         }
         if (new_bullish_jaw)
         {
            jaw_crossed = true;
            lines_crossed++;
            new_line_crossed = true;
            newly_crossed += "Jaw ";
         }
      }
      else if (breakout_direction == BEARISH_TREND)
      {
         if (new_bearish_lips)
         {
            lips_crossed = true;
            lines_crossed++;
            new_line_crossed = true;
            newly_crossed += "Lips ";
         }
         if (new_bearish_teeth)
         {
            teeth_crossed = true;
            lines_crossed++;
            new_line_crossed = true;
            newly_crossed += "Teeth ";
         }
         if (new_bearish_jaw)
         {
            jaw_crossed = true;
            lines_crossed++;
            new_line_crossed = true;
            newly_crossed += "Jaw ";
         }
      }

      // Check for direction violations (price moving against breakout direction)
      bool direction_violated = false;
      if (breakout_direction == BULLISH_TREND)
      {
         // Allow retracement to previously crossed lines, but not below all of them
         if (lips_crossed && teeth_crossed && jaw_crossed && price < jaw)
            direction_violated = true;
      }
      else if (breakout_direction == BEARISH_TREND)
      {
         // Allow retracement to previously crossed lines, but not above all of them
         if (lips_crossed && teeth_crossed && jaw_crossed && price > jaw)
            direction_violated = true;
      }

      if (direction_violated)
      {
         if (DEBUG_LEVEL >= 1)
            Print("❌ BREAKOUT INVALIDATED: Price moved against all crossed lines");
         ResetBreakoutMonitoring();
         return;
      }

      // Log newly crossed lines
      if (new_line_crossed && DEBUG_LEVEL >= 1)
      {
         Print("📈 BREAKOUT PROGRESS: ", newly_crossed, "crossed | Total: ", lines_crossed, "/3 lines");
      }

      // Handle jaw crossing detection
      bool jaw_just_crossed = false;
      if (!jaw_crossed && (new_bearish_jaw || new_bullish_jaw))
      {
         jaw_crossed = true;
         jaw_just_crossed = true;
         candles_after_jaw = 0;

         if (DEBUG_LEVEL >= 1)
            Print("🎯 JAW CROSSED: Starting countdown for ", REQUIRED_CANDLES_AFTER_JAW, " confirmation candles");
      }

      // Count candles that closed beyond jaw in trend direction
      // But don't count the same bar that just crossed the jaw
      if (jaw_crossed && !jaw_just_crossed)
      {
         bool candle_in_trend = false;
         if (breakout_direction == BULLISH_TREND && price > jaw)
            candle_in_trend = true;
         else if (breakout_direction == BEARISH_TREND && price < jaw)
            candle_in_trend = true;

         if (candle_in_trend)
         {
            candles_after_jaw++;
            if (DEBUG_LEVEL >= 2)
               Print("✅ CONFIRMATION CANDLE ", candles_after_jaw, "/", REQUIRED_CANDLES_AFTER_JAW,
                     " closed beyond jaw in trend direction");
         }
         else
         {
            // Candle closed against trend - invalidate breakout
            if (DEBUG_LEVEL >= 1)
               Print("❌ BREAKOUT INVALIDATED: Candle closed against trend direction");
            ResetBreakoutMonitoring();
            return;
         }
      }
      else if (jaw_crossed && jaw_just_crossed)
      {
         // This is the bar that just crossed jaw - validate it closed in trend direction
         bool jaw_crossing_valid = false;
         if (breakout_direction == BULLISH_TREND && price > jaw)
            jaw_crossing_valid = true;
         else if (breakout_direction == BEARISH_TREND && price < jaw)
            jaw_crossing_valid = true;

         if (!jaw_crossing_valid)
         {
            if (DEBUG_LEVEL >= 1)
               Print("❌ BREAKOUT INVALIDATED: Jaw crossing bar closed against trend direction");
            ResetBreakoutMonitoring();
            return;
         }
         else
         {
            if (DEBUG_LEVEL >= 2)
               Print("✅ JAW CROSSING VALID: Bar closed beyond jaw in trend direction");
         }
      }

      // Check if we've progressively crossed all 3 lines with sufficient momentum
      if (lines_crossed == 3 && lips_crossed && teeth_crossed && jaw_crossed &&
          candles_after_jaw >= REQUIRED_CANDLES_AFTER_JAW)
      {
         int breakout_bars = (int)((TimeCurrent() - breakout_start_time) / PeriodSeconds());
         int price_data_points = ArraySize(breakout_closes);

         if (breakout_bars <= MAX_BREAKOUT_BARS)
         {
            // Only validate slope if we have sufficient price movement data
            if (price_data_points >= 2) // Initial price + at least 1 more bar
            {
               // Validate breakout slope and trend consistency
               if (ValidateBreakoutSlope())
               {
                  if (DEBUG_LEVEL >= 1)
                  {
                     Print("✅ VALID BREAKOUT: All conditions met");
                     Print("  Lines crossed: 3/3 in ", breakout_bars, " bars");
                     Print("  Confirmation candles: ", candles_after_jaw, "/", REQUIRED_CANDLES_AFTER_JAW);
                     Print("  Price data points: ", price_data_points, " bars");
                     Print("  Slope and trend validated ✓");

                     // Special case notification for single-bar crossing
                     if (breakout_bars == 1)
                        Print("  🚀 POWER BREAKOUT: Single bar crossed all three lines with momentum!");
                  }

                  // Signal for trade entry
                  ExecuteBreakoutTrade(breakout_direction);
                  return;
               }
               else
               {
                  if (DEBUG_LEVEL >= 1)
                     Print("❌ WEAK BREAKOUT: Slope insufficient or trend inconsistent - resetting monitoring");

                  // Reset immediately when slope validation fails
                  ResetBreakoutMonitoring();
                  return;
               }
            }
            else
            {
               // Still need more price data for slope validation
               if (DEBUG_LEVEL >= 2)
                  Print("⏳ COLLECTING PRICE DATA: ", price_data_points, "/2 minimum points for slope validation");
            }
         }
         else
         {
            if (DEBUG_LEVEL >= 1)
               Print("⏰ BREAKOUT TOO SLOW: ", breakout_bars, " bars (max: ", MAX_BREAKOUT_BARS, ") - resetting monitoring");

            // Reset immediately when timeout occurs
            ResetBreakoutMonitoring();
            return;
         }
      }
      // Add debug for why trade isn't executing yet
      else if (DEBUG_LEVEL >= 1 && lines_crossed > 0)
      {
         static datetime last_waiting_debug = 0;
         if (TimeCurrent() - last_waiting_debug > 30) // Every 30 seconds
         {
            int price_data_points = ArraySize(breakout_closes);
            int breakout_bars = (int)((TimeCurrent() - breakout_start_time) / PeriodSeconds());

            string crossed_status = "";
            if (lips_crossed)
               crossed_status += "Lips ";
            if (teeth_crossed)
               crossed_status += "Teeth ";
            if (jaw_crossed)
               crossed_status += "Jaw ";

            Print("⏳ BREAKOUT IN PROGRESS - Waiting for conditions:");
            Print("  📊 Lines crossed: ", lines_crossed, "/3 (", crossed_status, ")");
            Print("  🎯 Direction: ", breakout_direction == BULLISH_TREND ? "BULLISH" : "BEARISH");
            Print("  ⏱️ Confirmation candles: ", candles_after_jaw, "/", REQUIRED_CANDLES_AFTER_JAW, " required");
            Print("  📈 Price data collected: ", price_data_points, "/2 minimum for slope validation");
            Print("  ⏰ Breakout duration: ", breakout_bars, "/", MAX_BREAKOUT_BARS, " bars allowed");

            if (price_data_points >= 2)
            {
               double price_change = breakout_closes[price_data_points - 1] - breakout_closes[0];
               Print("  💰 Current price movement: ", DoubleToString(price_change, 2), " points from start");
            }

            last_waiting_debug = TimeCurrent();
         }
      }
      // Special debug for complete breakouts waiting for confirmation
      else if (lines_crossed == 3 && candles_after_jaw < REQUIRED_CANDLES_AFTER_JAW && DEBUG_LEVEL >= 1)
      {
         int breakout_bars = (int)((TimeCurrent() - breakout_start_time) / PeriodSeconds());
         if (breakout_bars == 1)
         {
            Print("🚀 POWER BREAKOUT DETECTED: Single bar crossed all lines, waiting for ",
                  (REQUIRED_CANDLES_AFTER_JAW - candles_after_jaw), " confirmation candles");
         }
      }
      else
      {
         // Check if breakout is taking too long
         int breakout_bars = (int)((TimeCurrent() - breakout_start_time) / PeriodSeconds());
         if (breakout_bars > MAX_BREAKOUT_BARS)
         {
            if (DEBUG_LEVEL >= 1)
               Print("⏰ BREAKOUT TIMEOUT: Resetting after ", breakout_bars, " bars");
            ResetBreakoutMonitoring();
         }
      }
   }
}

bool ValidateBreakoutSlope()
{
   int closes_count = ArraySize(breakout_closes);
   if (closes_count < 2)
   {
      if (DEBUG_LEVEL >= 2)
         Print("❌ INSUFFICIENT PRICE DATA: Need at least 2 data points for slope validation, have: ", closes_count);
      return false;
   }

   // Calculate slope angle and price change for validation
   double slope_angle = CalculateSlopeAngle(breakout_closes[0], breakout_closes[closes_count - 1], closes_count - 1);
   double price_change = breakout_closes[closes_count - 1] - breakout_closes[0];

   // Validate slope meets minimum requirement
   if (slope_angle < MIN_BREAKOUT_SLOPE)
   {
      if (DEBUG_LEVEL >= 1)
      {
         Print("❌ BREAKOUT SLOPE TOO SHALLOW: ", DoubleToString(slope_angle, 2),
               "° (min: ", DoubleToString(MIN_BREAKOUT_SLOPE, 2), "°)");
         Print("  📈 Price movement: ", DoubleToString(breakout_closes[0], 2), " → ",
               DoubleToString(breakout_closes[closes_count - 1], 2), " (", DoubleToString(price_change, 2), " points)");
         Print("  📊 Slope calculation: ", DoubleToString(price_change, 2), " points over ", closes_count - 1, " bars");
      }
      return false;
   }

   // Validate trend consistency - all candles should be moving in trend direction
   bool trend_consistent = true;
   int trend_violations = 0;

   for (int i = 1; i < closes_count; i++)
   {
      double prev_close = breakout_closes[i - 1];
      double curr_close = breakout_closes[i];

      // Check if current candle moved in trend direction
      bool candle_in_trend = false;
      if (breakout_direction == BULLISH_TREND && curr_close > prev_close)
         candle_in_trend = true;
      else if (breakout_direction == BEARISH_TREND && curr_close < prev_close)
         candle_in_trend = true;

      if (!candle_in_trend)
      {
         trend_violations++;
         if (DEBUG_LEVEL >= 2)
            Print("Trend violation at candle ", i, ": ", DoubleToString(prev_close, 2),
                  " → ", DoubleToString(curr_close, 2));
      }
   }

   // Allow maximum 1 violation (small pullback acceptable)
   if (trend_violations > 1)
   {
      if (DEBUG_LEVEL >= 1)
      {
         Print("❌ TOO MANY TREND VIOLATIONS: ", trend_violations, " candles moved against trend (max 1 allowed)");
         Print("  📊 Expected direction: ", breakout_direction == BULLISH_TREND ? "BULLISH (prices rising)" : "BEARISH (prices falling)");
         Print("  📈 Total candles analyzed: ", closes_count - 1);
      }
      trend_consistent = false;
   }

   // Validate that price change is in correct direction
   bool direction_correct = false;
   if (breakout_direction == BULLISH_TREND && price_change > 0)
      direction_correct = true;
   else if (breakout_direction == BEARISH_TREND && price_change < 0)
      direction_correct = true;

   if (!direction_correct)
   {
      if (DEBUG_LEVEL >= 1)
         Print("❌ BREAKOUT DIRECTION MISMATCH: Expected ",
               breakout_direction == BULLISH_TREND ? "bullish" : "bearish",
               " but price moved ", price_change > 0 ? "up" : "down");
      return false;
   }

   if (DEBUG_LEVEL >= 1)
   {
      Print("✅ BREAKOUT SLOPE VALIDATION:");
      Print("  Slope angle: ", DoubleToString(slope_angle, 2), "° (min: ", DoubleToString(MIN_BREAKOUT_SLOPE, 2), "°)");
      Print("  Price change: ", DoubleToString(price_change, 2), " points over ", closes_count - 1, " bars");
      Print("  Trend violations: ", trend_violations, "/", closes_count - 1, " candles");
      Print("  Direction: ", breakout_direction == BULLISH_TREND ? "BULLISH" : "BEARISH", " ✓");
   }

   return trend_consistent;
}

void ResetBreakoutMonitoring()
{
   monitoring_breakout = false;
   breakout_start_time = 0;
   lines_crossed = 0;
   breakout_direction = NO_TREND;
   lips_crossed = false;
   teeth_crossed = false;
   jaw_crossed = false;
   candles_after_jaw = 0;
   ArrayResize(breakout_closes, 0);
}

//============================================================================
//                         TRADE SIGNAL DETECTION
//============================================================================

void CheckForTradeSignals()
{
   // The new system uses breakout detection instead of simple signals
   // Trading signals are now generated by ExecuteBreakoutTrade()
   // which is called from MonitorBreakoutProgress()

   // This function is kept for compatibility but does nothing
   // All trading decisions are now made in the advanced alligator analysis
}

void ExecuteBreakoutTrade(TrendDirection direction)
{
   // Check cooldown period
   if (TimeCurrent() - last_signal_time < SIGNAL_COOLDOWN_MINUTES * 60)
   {
      if (DEBUG_LEVEL >= 1)
         Print("⏰ BREAKOUT SIGNAL IGNORED: Still in cooldown period");
      return;
   }

   // Execute the appropriate trade
   if (direction == BULLISH_TREND)
   {
      if (DEBUG_LEVEL >= 1)
         Print("🟢 EXECUTING BULLISH BREAKOUT TRADE");

      ExecuteBuyTrade();

      // Set up mouth opening monitoring
      entry_time = TimeCurrent();
      waiting_for_mouth_open = true;
      mouth_has_opened = false;
   }
   else if (direction == BEARISH_TREND)
   {
      if (DEBUG_LEVEL >= 1)
         Print("🔴 EXECUTING BEARISH BREAKOUT TRADE");

      ExecuteSellTrade();

      // Set up mouth opening monitoring
      entry_time = TimeCurrent();
      waiting_for_mouth_open = true;
      mouth_has_opened = false;
   }

   last_signal_time = TimeCurrent();

   // CRITICAL: Stop breakout monitoring after trade execution
   // Switch to position management phase
   ResetBreakoutMonitoring();

   if (DEBUG_LEVEL >= 1)
      Print("🔄 PHASE SWITCH: Breakout monitoring stopped → Position management active");
}

//============================================================================
//                          TRADE EXECUTION
//============================================================================

void ExecuteBuyTrade()
{
   double entry_price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   // Calculate position size based on risk
   double risk_amount = AccountInfoDouble(ACCOUNT_BALANCE) * RISK_PERCENT / 100.0;
   double stop_distance = atr_value * ATR_STOP_MULTIPLIER;
   double position_size = risk_amount / stop_distance;

   // Calculate stop loss and take profit
   double stop_loss = entry_price - stop_distance;
   double take_profit = entry_price + (stop_distance * REWARD_RATIO);

   // Validate and normalize position size
   position_size = NormalizePositionSize(position_size);

   // Validate stop levels
   ValidateStopLevels(ORDER_TYPE_BUY, entry_price, stop_loss, take_profit);

   // Create trade request
   MqlTradeRequest request = {};
   MqlTradeResult result = {};

   request.action = TRADE_ACTION_DEAL;
   request.symbol = _Symbol;
   request.volume = position_size;
   request.type = ORDER_TYPE_BUY;
   request.price = entry_price;
   request.sl = stop_loss;
   request.tp = take_profit;
   request.deviation = GetOptimalSlippage();
   request.magic = 12345;
   request.comment = "Alligator_Buy";
   request.type_filling = ORDER_FILLING_IOC;

   // Execute trade
   if (OrderSend(request, result) && result.retcode == TRADE_RETCODE_DONE)
   {
      current_position_ticket = result.order;
      position_direction = BULLISH_TREND;
      daily_trade_count++;

      if (DEBUG_LEVEL >= 1)
      {
         Print("✅ BUY ORDER EXECUTED");
         Print("Entry: $", DoubleToString(entry_price, 2));
         Print("Stop: $", DoubleToString(stop_loss, 2));
         Print("Target: $", DoubleToString(take_profit, 2));
         Print("Size: ", DoubleToString(position_size, 6), " BTC");
         Print("Risk: $", DoubleToString(risk_amount, 2));
      }
   }
   else
   {
      Print("❌ BUY ORDER FAILED: ", result.retcode, " - ", GetErrorDescription(result.retcode));
   }
}

void ExecuteSellTrade()
{
   double entry_price = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // Calculate position size based on risk
   double risk_amount = AccountInfoDouble(ACCOUNT_BALANCE) * RISK_PERCENT / 100.0;
   double stop_distance = atr_value * ATR_STOP_MULTIPLIER;
   double position_size = risk_amount / stop_distance;

   // Calculate stop loss and take profit
   double stop_loss = entry_price + stop_distance;
   double take_profit = entry_price - (stop_distance * REWARD_RATIO);

   // Validate and normalize position size
   position_size = NormalizePositionSize(position_size);

   // Validate stop levels
   ValidateStopLevels(ORDER_TYPE_SELL, entry_price, stop_loss, take_profit);

   // Create trade request
   MqlTradeRequest request = {};
   MqlTradeResult result = {};

   request.action = TRADE_ACTION_DEAL;
   request.symbol = _Symbol;
   request.volume = position_size;
   request.type = ORDER_TYPE_SELL;
   request.price = entry_price;
   request.sl = stop_loss;
   request.tp = take_profit;
   request.deviation = GetOptimalSlippage();
   request.magic = 12345;
   request.comment = "Alligator_Sell";
   request.type_filling = ORDER_FILLING_IOC;

   // Execute trade
   if (OrderSend(request, result) && result.retcode == TRADE_RETCODE_DONE)
   {
      current_position_ticket = result.order;
      position_direction = BEARISH_TREND;
      daily_trade_count++;

      if (DEBUG_LEVEL >= 1)
      {
         Print("✅ SELL ORDER EXECUTED");
         Print("Entry: $", DoubleToString(entry_price, 2));
         Print("Stop: $", DoubleToString(stop_loss, 2));
         Print("Target: $", DoubleToString(take_profit, 2));
         Print("Size: ", DoubleToString(position_size, 6), " BTC");
         Print("Risk: $", DoubleToString(risk_amount, 2));
      }
   }
   else
   {
      Print("❌ SELL ORDER FAILED: ", result.retcode, " - ", GetErrorDescription(result.retcode));
   }
}

//============================================================================
//                        POSITION MANAGEMENT
//============================================================================

void ManageOpenPosition()
{
   // Check if position still exists
   if (!PositionSelectByTicket(current_position_ticket))
   {
      // Position was closed (by SL/TP or manually)
      if (DEBUG_LEVEL >= 1)
         Print("Position closed: ", current_position_ticket);

      ResetPositionTracking();
      return;
   }

   bool should_exit = false;
   string exit_reason = "";
   datetime current_time = TimeCurrent();

   // PHASE 1: Waiting for mouth to open after breakout entry
   if (waiting_for_mouth_open && !mouth_has_opened)
   {
      int bars_since_entry = (int)((current_time - entry_time) / PeriodSeconds());
      bool lines_are_diverging = CheckLinesAreDiverging();

      // Check if mouth has opened (alligator is properly awake AND lines are diverging)
      bool mouth_opened = false;
      if (position_direction == BULLISH_TREND && is_bullish_awake && lines_are_diverging)
      {
         mouth_opened = true;
      }
      else if (position_direction == BEARISH_TREND && is_bearish_awake && lines_are_diverging)
      {
         mouth_opened = true;
      }

      if (mouth_opened)
      {
         mouth_has_opened = true;
         waiting_for_mouth_open = false;

         if (DEBUG_LEVEL >= 1)
         {
            Print("✅ MOUTH OPENED: Alligator confirmed awake AND diverging after ", bars_since_entry, " bars");
            Print("  📊 Line alignment: ", (position_direction == BULLISH_TREND) ? "Bullish" : "Bearish", " ✓");
            Print("  📈 Lines diverging: YES ✓");
         }
      }
      else if (bars_since_entry >= MOUTH_OPENING_WINDOW)
      {
         // Mouth didn't open in time - exit trade
         should_exit = true;
         string alignment_status = "";
         if (position_direction == BULLISH_TREND)
            alignment_status = is_bullish_awake ? "Aligned ✓" : "Not aligned ❌";
         else
            alignment_status = is_bearish_awake ? "Aligned ✓" : "Not aligned ❌";

         exit_reason = "Mouth failed to open within " + IntegerToString(MOUTH_OPENING_WINDOW) + " bars (" +
                       alignment_status + ", Diverging: " + (lines_are_diverging ? "YES ✓" : "NO ❌") + ")";
      }
      else if (is_sleeping)
      {
         // Alligator went back to sleep before mouth opened - exit immediately
         should_exit = true;
         exit_reason = "Alligator went back to sleep before mouth opened";
      }
      else
      {
         // Debug waiting progress
         if (DEBUG_LEVEL >= 1)
         {
            static datetime last_waiting_debug = 0;
            if (current_time - last_waiting_debug > 60) // Every 60 seconds
            {
               string alignment_status = "";
               if (position_direction == BULLISH_TREND)
                  alignment_status = is_bullish_awake ? "Aligned ✓" : "Not aligned ❌";
               else
                  alignment_status = is_bearish_awake ? "Aligned ✓" : "Not aligned ❌";

               Print("⏳ WAITING FOR MOUTH OPENING: Bar ", bars_since_entry, "/", MOUTH_OPENING_WINDOW);
               Print("  📊 Line alignment: ", alignment_status);
               Print("  📈 Lines diverging: ", lines_are_diverging ? "YES ✓" : "NO ❌");
               last_waiting_debug = current_time;
            }
         }
      }
   }

   // PHASE 2: Mouth has opened - monitor for closure or price reversal
   else if (mouth_has_opened)
   {
      // Check if mouth closed again (alligator going back to sleep)
      if (is_sleeping)
      {
         should_exit = true;
         exit_reason = "Alligator mouth closed - trend ending";
      }
      // Check if price crossed back through lips (momentum reversal)
      else if (position_direction == BULLISH_TREND && price < lips)
      {
         should_exit = true;
         exit_reason = "Price closed below lips - bullish momentum lost";
      }
      else if (position_direction == BEARISH_TREND && price > lips)
      {
         should_exit = true;
         exit_reason = "Price closed above lips - bearish momentum lost";
      }
   }

   // Execute exit if needed
   if (should_exit)
   {
      ClosePosition(exit_reason);
   }

   // Debug position status
   if (DEBUG_LEVEL >= 2)
   {
      static datetime last_position_debug = 0;
      if (current_time - last_position_debug > 30) // Every 30 seconds
      {
         string direction = (position_direction == BULLISH_TREND) ? "LONG" : "SHORT";
         double profit = PositionGetDouble(POSITION_PROFIT);
         int bars_in_trade = (int)((current_time - entry_time) / PeriodSeconds());

         Print("=== POSITION STATUS ===");
         Print("Direction: ", direction, " | P&L: $", DoubleToString(profit, 2));
         Print("Bars in trade: ", bars_in_trade);
         Print("Waiting for mouth: ", waiting_for_mouth_open ? "YES" : "NO");
         Print("Mouth opened: ", mouth_has_opened ? "YES" : "NO");

         if (waiting_for_mouth_open)
         {
            bool lines_diverging = CheckLinesAreDiverging();
            Print("Mouth opening requirements:");
            Print("  Line alignment: Bullish=", is_bullish_awake ? "✓" : "❌", " | Bearish=", is_bearish_awake ? "✓" : "❌");
            Print("  Lines diverging: ", lines_diverging ? "✓" : "❌");
         }
         else
         {
            Print("Current mouth state: Bullish=", is_bullish_awake ? "OPEN" : "CLOSED",
                  " | Bearish=", is_bearish_awake ? "OPEN" : "CLOSED");
         }

         last_position_debug = current_time;
      }
   }
}

void ResetPositionTracking()
{
   current_position_ticket = 0;
   position_direction = NO_TREND;
   entry_time = 0;
   waiting_for_mouth_open = false;
   mouth_has_opened = false;
}

void ClosePosition(string reason)
{
   MqlTradeRequest request = {};
   MqlTradeResult result = {};

   request.action = TRADE_ACTION_DEAL;
   request.position = current_position_ticket;
   request.symbol = _Symbol;
   request.volume = PositionGetDouble(POSITION_VOLUME);
   request.type = (position_direction == BULLISH_TREND) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
   request.price = (request.type == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   request.deviation = GetOptimalSlippage();
   request.magic = 12345;
   request.comment = "Alligator_Exit";
   request.type_filling = ORDER_FILLING_IOC;

   if (OrderSend(request, result) && result.retcode == TRADE_RETCODE_DONE)
   {
      if (DEBUG_LEVEL >= 1)
      {
         double profit = PositionGetDouble(POSITION_PROFIT);
         Print("✅ POSITION CLOSED: ", reason);
         Print("P&L: $", DoubleToString(profit, 2));
      }

      ResetPositionTracking();
   }
   else
   {
      Print("❌ FAILED TO CLOSE POSITION: ", result.retcode);
   }
}

//============================================================================
//                           UTILITY FUNCTIONS
//============================================================================

double CalculateSlopeAngle(double price_start, double price_end, int bars)
{
   // Calculate percentage change to make it scale-independent
   double percentage_change = MathAbs(price_end - price_start) / price_start * 100.0;

   // Get actual time duration to make it timeframe-independent
   double time_duration_hours = bars * PeriodSeconds() / 3600.0;

   // Calculate slope as percentage change per hour
   double slope = percentage_change / time_duration_hours;

   // Convert to angle in degrees
   // Using atan to get the angle whose tangent is the slope
   double angle_radians = MathArctan(slope);
   double angle_degrees = angle_radians * 180.0 / M_PI;

   return angle_degrees;
}

double NormalizePositionSize(double size)
{
   double min_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double max_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lot_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   size = MathMax(min_lot, MathMin(max_lot, size));
   size = NormalizeDouble(size / lot_step, 0) * lot_step;

   return size;
}

void ValidateStopLevels(ENUM_ORDER_TYPE order_type, double entry, double &stop_loss, double &take_profit)
{
   int stop_level = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double min_distance = stop_level * _Point;

   if (order_type == ORDER_TYPE_BUY)
   {
      if (entry - stop_loss < min_distance)
         stop_loss = entry - min_distance;
      if (take_profit - entry < min_distance)
         take_profit = entry + min_distance;
   }
   else
   {
      if (stop_loss - entry < min_distance)
         stop_loss = entry + min_distance;
      if (entry - take_profit < min_distance)
         take_profit = entry - min_distance;
   }
}

int GetOptimalSlippage()
{
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   int slippage = (int)(spread * 2 + 50); // For crypto
   return MathMax(15, MathMin(200, slippage));
}

void ResetDailyTrades()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0;
   dt.min = 0;
   dt.sec = 0;
   datetime today = StructToTime(dt);

   if (last_trade_date != today)
   {
      daily_trade_count = 0;
      last_trade_date = today;
      if (DEBUG_LEVEL >= 1)
         Print("New trading day - reset counter");
   }
}

string TimeframeToString(ENUM_TIMEFRAMES tf)
{
   switch (tf)
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
   default:
      return "Unknown";
   }
}

string GetErrorDescription(int error_code)
{
   switch (error_code)
   {
   case TRADE_RETCODE_DONE:
      return "Success";
   case TRADE_RETCODE_REQUOTE:
      return "Requote";
   case TRADE_RETCODE_REJECT:
      return "Rejected";
   case TRADE_RETCODE_INVALID_PRICE:
      return "Invalid price";
   case TRADE_RETCODE_INVALID_STOPS:
      return "Invalid stops";
   case TRADE_RETCODE_NO_MONEY:
      return "No money";
   default:
      return "Error " + IntegerToString(error_code);
   }
}

void ShowInfoPanel()
{
   // Alligator status
   string gator_status = "";
   if (is_sleeping)
   {
      string sleep_info = "";
      if (sleep_bar_count >= MIN_SLEEPING_BARS)
         sleep_info = " (READY " + IntegerToString(sleep_bar_count) + "/" + IntegerToString(MIN_SLEEPING_BARS) + ")";
      else
         sleep_info = " (" + IntegerToString(sleep_bar_count) + "/" + IntegerToString(MIN_SLEEPING_BARS) + ")";

      gator_status = "😴 SLEEPING" + sleep_info;
   }
   else if (is_bullish_awake)
      gator_status = "🟢 BULLISH AWAKE";
   else if (is_bearish_awake)
      gator_status = "🔴 BEARISH AWAKE";
   else
      gator_status = "😐 LINES SEPARATING";

   // Breakout monitoring status
   string breakout_status = "";
   if (monitoring_breakout)
   {
      int breakout_bars = (int)((TimeCurrent() - breakout_start_time) / PeriodSeconds());
      string direction = (breakout_direction == BULLISH_TREND) ? "BULL" : "BEAR";

      // Calculate current slope angle if we have enough data
      string slope_info = "";
      int closes_count = ArraySize(breakout_closes);
      if (closes_count >= 2)
      {
         double current_slope_angle = CalculateSlopeAngle(breakout_closes[0], breakout_closes[closes_count - 1], closes_count - 1);
         slope_info = " | Angle: " + DoubleToString(current_slope_angle, 1) + "°/" + DoubleToString(MIN_BREAKOUT_SLOPE, 1) + "°";
      }

      breakout_status = "🚀 BREAKOUT: " + direction + " " + IntegerToString(lines_crossed) + "/3 lines (" +
                        IntegerToString(breakout_bars) + "/" + IntegerToString(MAX_BREAKOUT_BARS) + " bars)" +
                        slope_info;

      if (jaw_crossed)
         breakout_status += " | After jaw: " + IntegerToString(candles_after_jaw) + "/" + IntegerToString(REQUIRED_CANDLES_AFTER_JAW);
   }
   else
   {
      breakout_status = "⏳ Monitoring for breakout";
   }

   // Position status
   string position_status = "No Position";
   if (current_position_ticket != 0)
   {
      double profit = PositionGetDouble(POSITION_PROFIT);
      string direction = (position_direction == BULLISH_TREND) ? "LONG" : "SHORT";
      position_status = direction + " | P&L: $" + DoubleToString(profit, 2);

      if (waiting_for_mouth_open)
      {
         int bars_waiting = (int)((TimeCurrent() - entry_time) / PeriodSeconds());
         position_status += " | Waiting for mouth (" + IntegerToString(bars_waiting) + "/" +
                            IntegerToString(MOUTH_OPENING_WINDOW) + ")";
      }
      else if (mouth_has_opened)
      {
         position_status += " | Mouth OPEN";
      }
   }

   string info = StringFormat(
       "🐊 ADVANCED ALLIGATOR SCALPER | Trades: %d/%d\n" +
           "Gator: %s\n" +
           "Breakout: %s\n" +
           "Position: %s\n" +
           "Price: $%s | Lips: $%s | Teeth: $%s | Jaw: $%s\n" +
           "ATR: $%s | Risk: %.1f%% | Reward: %.1f:1",
       daily_trade_count, MAX_DAILY_TRADES,
       gator_status,
       breakout_status,
       position_status,
       DoubleToString(price, 2),
       DoubleToString(lips, 2),
       DoubleToString(teeth, 2),
       DoubleToString(jaw, 2),
       DoubleToString(atr_value, 2),
       RISK_PERCENT,
       REWARD_RATIO);

   Comment(info);
}

//============================================================================
//                        OPTIMIZATION FUNCTION
//============================================================================

double OnTester()
{
   double trades = TesterStatistics(STAT_TRADES);
   double profit = TesterStatistics(STAT_PROFIT);
   double drawdown = TesterStatistics(STAT_BALANCE_DD);
   double initial = TesterStatistics(STAT_INITIAL_DEPOSIT);

   if (trades < 5 || profit <= 0 || initial <= 0)
      return 0.0;

   double roi = (profit / initial) * 100.0;
   double dd_percent = (drawdown / initial) * 100.0;

   // Fitness = Profit factor adjusted for drawdown and trade frequency
   double fitness = (roi / MathMax(dd_percent, 1.0)) * MathLog(trades + 1);

   return fitness;
}