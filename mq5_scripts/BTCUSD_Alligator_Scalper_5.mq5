//+------------------------------------------------------------------+
//|                     BTCUSD Alligator Trend Scalper                |
//|                 Simple Williams Alligator Strategy                |
//|               Copyright 2025 - free to use / modify               |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025"
#property version "3.00"
#property strict

//+------------------------------------------------------------------+
//|                         TODO LIST                                |
//+------------------------------------------------------------------+
// ✅ COMPLETED: Changed bar-based sleep/mouth tracking to time-based (minutes)
// ⏳ REMAINING: Convert GATOR_HORIZONTAL_CHECK_BARS and BREAKOUT_TREND_CONSISTENCY_BARS to time-based

//============================================================================
//                           USER SETTINGS
//============================================================================

// Risk Management
input double RISK_PERCENT = 1.0; // RISK_PERCENT: Risk per trade (% of account)
input double REWARD_RATIO = 2.0; // REWARD_RATIO: Reward:Risk ratio (2.0 = 2:1)
input int MAX_DAILY_TRADES = 50; // MAX_DAILY_TRADES: Maximum trades per day

// Alligator Indicator Settings
input int JAW_PERIOD = 13;  // JAW_PERIOD: Jaw period (Blue line - slowest)
input int JAW_SHIFT = 8;    // JAW_SHIFT: Jaw shift
input int TEETH_PERIOD = 8; // TEETH_PERIOD: Teeth period (Red line - medium)
input int TEETH_SHIFT = 5;  // TEETH_SHIFT: Teeth shift
input int LIPS_PERIOD = 5;  // LIPS_PERIOD: Lips period (Green line - fastest)
input int LIPS_SHIFT = 3;   // LIPS_SHIFT: Lips shift

// Strategy Parameters
input int ATR_PERIOD = 14;              // ATR_PERIOD: ATR period for volatility measurement
input double ATR_STOP_MULTIPLIER = 1.5; // ATR_STOP_MULTIPLIER: Stop loss = ATR × this multiplier

// Alligator Mouth Dynamics
// These parameters control when the alligator "mouth" is considered open (lines diverging vs horizontal)
input double MIN_GATOR_DIVERGENCE_ANGLE = 1.0;     // MIN_GATOR_DIVERGENCE_ANGLE: Minimum angle difference between lines for mouth opening (degrees)
input double MIN_GATOR_SLOPE_FOR_DIVERGENCE = 0.5; // MIN_GATOR_SLOPE_FOR_DIVERGENCE: Minimum line slope required for divergence detection (degrees)
input double MIN_SLEEPING_MINUTES = 3.0;            // MIN_SLEEPING_MINUTES: Minimum minutes alligator must sleep before breakout
input double MAX_MOUTH_OPENING_MINUTES = 10.0;     // MAX_MOUTH_OPENING_MINUTES: Maximum minutes to wait for mouth to open after entry (timeout)
input double MAX_LINE_SLOPE = 10;                  // MAX_LINE_SLOPE: Maximum line slope angle (degrees) for "horizontal" lines
input int GATOR_HORIZONTAL_CHECK_BARS = 3;          // GATOR_HORIZONTAL_CHECK_BARS: Bars to analyze alligator line slopes for horizontal/sleeping detection
input double MAX_LINE_SPREAD_DOLLARS = 50.0;       // MAX_LINE_SPREAD_DOLLARS: Maximum dollar distance between any line pair to consider "closed/sleeping"

// Breakout Validation
input double MIN_BREAKOUT_SLOPE = 60;   // MIN_BREAKOUT_SLOPE: Minimum slope angle from jaw (degrees) for valid breakout
input int BREAKOUT_TREND_CONSISTENCY_BARS = 3; // BREAKOUT_TREND_CONSISTENCY_BARS: Number of recent bars analyzed to validate price movement direction matches breakout
input double MIN_ATR_BREAKOUT_DISTANCE_MULTIPLIER = 1.5; // MIN_ATR_BREAKOUT_DISTANCE_MULTIPLIER: ATR multiplier for minimum dollar distance price must move from jaw
// Trading Controls
input double MIN_SIGNAL_COOLDOWN_MINUTES = 3.0; // MIN_SIGNAL_COOLDOWN_MINUTES: Minimum minutes between signals (allows fractions)
input bool SHOW_INFO_PANEL = true;     // SHOW_INFO_PANEL: Show information panel on chart
input int DEBUG_LEVEL = 1;             // DEBUG_LEVEL: Debug verbosity level (0=none, 1=basic, 2=detailed)

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
// sleep_bar_count removed - now using time-based tracking

// Breakout tracking
bool monitoring_breakout = false;             // Are we monitoring for breakout signals?
double price_history[];                       // Array to track price history for breakout detection

// Actual breakout tracking (when price moves beyond jaw)
bool price_beyond_jaw = false;                // Has price moved beyond jaw?
datetime breakout_start_time = 0;             // When price first went beyond jaw
double breakout_start_price = 0;              // Price when it first crossed jaw
TrendDirection breakout_direction = NO_TREND; // Direction of the breakout

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
   Print("Minimum sleeping time: ", MIN_SLEEPING_MINUTES, " minutes");
   Print("Mouth opening window: ", MAX_MOUTH_OPENING_MINUTES, " minutes");
   Print("--- Gator Mouth Divergence Detection ---");
   Print("Minimum divergence angle: ", MIN_GATOR_DIVERGENCE_ANGLE, "° (lines must differ by this much)");
   Print("Minimum slope for divergence: ", MIN_GATOR_SLOPE_FOR_DIVERGENCE, "° (at least one line must have this slope)");
   Print("Line horizontal threshold: ", MAX_LINE_SLOPE, "° (sleeping when all lines below this)");
   Print("Gator horizontal check period: ", GATOR_HORIZONTAL_CHECK_BARS, " bars");
   Print("Line distance threshold: $", MAX_LINE_SPREAD_DOLLARS, " (max dollar distance between any line pair for sleeping)");
   Print("--- Trading Logic ---");
   Print("Cycle: Sleep → Monitor → Breakout → Trade → Position Mgmt → Exit → Wait for Sleep");
   Print("Breakout entry: Price angle from jaw during monitoring phase");
   Print("Mouth opening: Lines must be aligned AND diverging during MAX_MOUTH_OPENING_MINUTES");
   Print("--- Price Breakout Validation ---");
   Print("Minimum breakout slope: ", MIN_BREAKOUT_SLOPE, "° angle from actual jaw crossing point");
   Print("Trend consistency window: ", BREAKOUT_TREND_CONSISTENCY_BARS, " bars (for recent trend validation)");
   Print("ATR distance multiplier: ", MIN_ATR_BREAKOUT_DISTANCE_MULTIPLIER);
   Print("Logic: Track from jaw crossing → Validate slope from actual start point");
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
   // Check if lines are horizontal (low slope) AND close together - this determines sleeping
   bool lines_horizontal_by_angle = CheckLinesAreHorizontal(MAX_LINE_SLOPE);
   bool lines_close_by_spread = CheckLinesAreCloseBySpread();
   lines_are_horizontal = lines_horizontal_by_angle && lines_close_by_spread;

   // Check if lines are sloping away from each other (diverging slopes) - this determines awaking
   bool lines_are_diverging = CheckLinesAreDiverging();

   // Update sleeping state and tracking (TIME-BASED)
   static bool ready_notification_sent = false;

   if (lines_are_horizontal)
   {
      if (!is_sleeping)
      {
         // Just started sleeping
         is_sleeping = true;
         sleep_start_time = TimeCurrent();
         ready_notification_sent = false;
         if (DEBUG_LEVEL >= 1)
            Print("😴 ALLIGATOR SLEEPING: Lines are horizontal");
      }
      else
      {
         // Continue sleeping - check if we've reached minimum duration
         double sleep_duration_minutes = (TimeCurrent() - sleep_start_time) / 60.0;
         
         // Notify when ready for breakout monitoring (only once)
         if (sleep_duration_minutes >= MIN_SLEEPING_MINUTES && !ready_notification_sent && DEBUG_LEVEL >= 1)
         {
            Print("✅ BREAKOUT MONITORING ACTIVE: Slept for ", DoubleToString(sleep_duration_minutes, 2), " minutes - ready for breakouts");
            ready_notification_sent = true;
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
      ready_notification_sent = false;
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

   // Start breakout monitoring when alligator ready (TIME-BASED)
   double sleep_duration_minutes = is_sleeping && sleep_start_time > 0 ? (TimeCurrent() - sleep_start_time) / 60.0 : 0.0;
   bool sleep_duration_met = (sleep_duration_minutes >= MIN_SLEEPING_MINUTES);
   
   if (sleep_duration_met && current_position_ticket == 0)
   {
      if (!monitoring_breakout)
      {
         monitoring_breakout = true;
         if (DEBUG_LEVEL >= 1)
            Print("🎯 BREAKOUT MONITORING STARTED: Ready for price angle detection");
      }
      
      CheckPriceBreakoutFromJaw();
   }
   else if (monitoring_breakout && (!sleep_duration_met || current_position_ticket != 0))
   {
      // Stop monitoring if alligator wakes up or we have a position
      monitoring_breakout = false;
      ResetBreakoutTracking(); // Reset tracking when monitoring stops
      if (DEBUG_LEVEL >= 1)
         Print("🛑 BREAKOUT MONITORING STOPPED: Conditions no longer met");
   }

   // Simple status at DEBUG_LEVEL 1 (TIME-BASED)
   if (DEBUG_LEVEL >= 1)
   {
      static datetime last_simple_debug = 0;
      static string last_status = "";
      if (TimeCurrent() - last_simple_debug > 60) // Every 60 seconds
      {
         string current_status = "";
         double current_sleep_minutes = is_sleeping && sleep_start_time > 0 ? (TimeCurrent() - sleep_start_time) / 60.0 : 0.0;

         if (is_sleeping && current_sleep_minutes >= MIN_SLEEPING_MINUTES)
         {
            if (monitoring_breakout)
               current_status = "🎯 MONITORING: Sleeping " + DoubleToString(current_sleep_minutes, 1) + " mins - watching for breakout";
            else
               current_status = "😴 READY: Sleeping " + DoubleToString(current_sleep_minutes, 1) + " mins - will monitor when no position";
         }
         else if (is_sleeping)
         {
            double remaining_minutes = MIN_SLEEPING_MINUTES - current_sleep_minutes;
            current_status = "😴 SLEEPING: " + DoubleToString(current_sleep_minutes, 1) + "/" + DoubleToString(MIN_SLEEPING_MINUTES, 1) +
                             " mins - need " + DoubleToString(remaining_minutes, 1) + " more";
         }
         else
         {
            current_status = "👁️ AWAKE: Lines not sleeping - monitoring paused";
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
         
         // Show individual line distances
         double lips_teeth_distance = MathAbs(lips - teeth);
         double teeth_jaw_distance = MathAbs(teeth - jaw);
         double lips_jaw_distance = MathAbs(lips - jaw);
         Print("📏 Line distances: Lips↔Teeth=$", DoubleToString(lips_teeth_distance, 2), 
               " | Teeth↔Jaw=$", DoubleToString(teeth_jaw_distance, 2), 
               " | Lips↔Jaw=$", DoubleToString(lips_jaw_distance, 2), " (max: $", MAX_LINE_SPREAD_DOLLARS, ")");

         // Main status explanation (TIME-BASED)
         if (is_sleeping)
         {
            double current_sleep_minutes = (TimeCurrent() - sleep_start_time) / 60.0;
            if (current_sleep_minutes >= MIN_SLEEPING_MINUTES)
               Print("😴 SLEEPING: ", DoubleToString(current_sleep_minutes, 1), " minutes ✅ READY for breakout");
            else
               Print("😴 SLEEPING: ", DoubleToString(current_sleep_minutes, 1), "/", DoubleToString(MIN_SLEEPING_MINUTES, 1), " minutes ⏳ Need more sleep");
         }
         else
         {
            string awake_reason = "";
            if (!lines_horizontal_by_angle && !lines_close_by_spread)
               awake_reason = "Lines not horizontal AND distances too wide";
            else if (!lines_horizontal_by_angle)
               awake_reason = "Lines not horizontal";
            else if (!lines_close_by_spread)
            {
               // Show which specific distances are too wide
               double lips_teeth_dist = MathAbs(lips - teeth);
               double teeth_jaw_dist = MathAbs(teeth - jaw);
               double lips_jaw_dist = MathAbs(lips - jaw);
               
               string wide_pairs = "";
               if (lips_teeth_dist > MAX_LINE_SPREAD_DOLLARS) wide_pairs += "Lips↔Teeth ";
               if (teeth_jaw_dist > MAX_LINE_SPREAD_DOLLARS) wide_pairs += "Teeth↔Jaw ";
               if (lips_jaw_dist > MAX_LINE_SPREAD_DOLLARS) wide_pairs += "Lips↔Jaw ";
               
               awake_reason = "Line distances too wide (" + wide_pairs + ")";
            }
            
            Print("👁️ AWAKE: ", awake_reason, " - monitoring paused");
         }

         // Breakout monitoring status (TIME-BASED)
         if (monitoring_breakout)
         {
            Print("🎯 ACTIVE MONITORING: Watching for price breakout signals");
         }
         else
         {
            double current_sleep_minutes = is_sleeping && sleep_start_time > 0 ? (TimeCurrent() - sleep_start_time) / 60.0 : 0.0;
            bool sleep_duration_met = (current_sleep_minutes >= MIN_SLEEPING_MINUTES);
            
            if (sleep_duration_met && current_position_ticket != 0)
            {
               Print("💼 POSITION ACTIVE: Monitoring paused during trade management");
            }
            else if (sleep_duration_met)
            {
               Print("😴 READY: Will start monitoring when conditions met");
            }
            else
            {
               double remaining_minutes = MIN_SLEEPING_MINUTES - current_sleep_minutes;
               Print("🛑 NOT MONITORING: Need ", DoubleToString(remaining_minutes, 1), " more sleep minutes");
            }
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

   if (CopyBuffer(alligator_handle, 0, 0, GATOR_HORIZONTAL_CHECK_BARS, jaw_buffer) <= 0 ||
       CopyBuffer(alligator_handle, 1, 0, GATOR_HORIZONTAL_CHECK_BARS, teeth_buffer) <= 0 ||
       CopyBuffer(alligator_handle, 2, 0, GATOR_HORIZONTAL_CHECK_BARS, lips_buffer) <= 0)
   {
      return true; // Default to horizontal if can't get data
   }

   // Calculate actual slope angles (timeframe-independent)
   double jaw_angle = CalculateSlopeAngle(jaw_buffer[GATOR_HORIZONTAL_CHECK_BARS - 1], jaw_buffer[0], GATOR_HORIZONTAL_CHECK_BARS);
   double teeth_angle = CalculateSlopeAngle(teeth_buffer[GATOR_HORIZONTAL_CHECK_BARS - 1], teeth_buffer[0], GATOR_HORIZONTAL_CHECK_BARS);
   double lips_angle = CalculateSlopeAngle(lips_buffer[GATOR_HORIZONTAL_CHECK_BARS - 1], lips_buffer[0], GATOR_HORIZONTAL_CHECK_BARS);

   // All lines must be relatively horizontal (below max angle threshold)
   return (jaw_angle <= max_slope && teeth_angle <= max_slope && lips_angle <= max_slope);
}

bool CheckLinesAreCloseBySpread()
{
   // Calculate the distance between each pair of lines
   double lips_teeth_distance = MathAbs(lips - teeth);
   double teeth_jaw_distance = MathAbs(teeth - jaw);
   double lips_jaw_distance = MathAbs(lips - jaw);
   
   // All line pairs must be within the dollar threshold
   return (lips_teeth_distance <= MAX_LINE_SPREAD_DOLLARS &&
           teeth_jaw_distance <= MAX_LINE_SPREAD_DOLLARS &&
           lips_jaw_distance <= MAX_LINE_SPREAD_DOLLARS);
}

bool CheckLinesAreDiverging()
{
   // Get historical alligator values to check slope
   double jaw_buffer[], teeth_buffer[], lips_buffer[];

   if (CopyBuffer(alligator_handle, 0, 0, GATOR_HORIZONTAL_CHECK_BARS, jaw_buffer) <= 0 ||
       CopyBuffer(alligator_handle, 1, 0, GATOR_HORIZONTAL_CHECK_BARS, teeth_buffer) <= 0 ||
       CopyBuffer(alligator_handle, 2, 0, GATOR_HORIZONTAL_CHECK_BARS, lips_buffer) <= 0)
   {
      return false; // Default to not diverging if can't get data
   }

   // Calculate actual slope angles (timeframe-independent)
   double jaw_angle = CalculateSlopeAngle(jaw_buffer[GATOR_HORIZONTAL_CHECK_BARS - 1], jaw_buffer[0], GATOR_HORIZONTAL_CHECK_BARS);
   double teeth_angle = CalculateSlopeAngle(teeth_buffer[GATOR_HORIZONTAL_CHECK_BARS - 1], teeth_buffer[0], GATOR_HORIZONTAL_CHECK_BARS);
   double lips_angle = CalculateSlopeAngle(lips_buffer[GATOR_HORIZONTAL_CHECK_BARS - 1], lips_buffer[0], GATOR_HORIZONTAL_CHECK_BARS);

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

void CheckPriceBreakoutFromJaw()
{
   // Only check when actively monitoring
   if (!monitoring_breakout)
      return;

   // Update price history array with current LIVE price + recent bar closes
   // This enables trend consistency validation that includes real-time market action
   UpdatePriceHistory();

   // Check if we have enough price data for trend consistency
   if (ArraySize(price_history) < BREAKOUT_TREND_CONSISTENCY_BARS)
      return;

   // Step 1: Check if price has moved beyond jaw (start tracking if not already)
   TrendDirection current_direction = NO_TREND;
   if (price > jaw)
      current_direction = BULLISH_TREND;
   else if (price < jaw)
      current_direction = BEARISH_TREND;

   // Detect when price first moves beyond jaw
   if (!price_beyond_jaw && current_direction != NO_TREND)
   {
      // Price just crossed jaw - start tracking
      price_beyond_jaw = true;
      breakout_start_time = TimeCurrent();
      breakout_start_price = price;
      breakout_direction = current_direction;

      if (DEBUG_LEVEL >= 2)
         Print("🎯 PRICE BEYOND JAW: Starting breakout tracking at $", DoubleToString(price, 2), 
               " (", current_direction == BULLISH_TREND ? "BULLISH" : "BEARISH", ")");
   }

   // Step 2: If price has moved beyond jaw, check all breakout conditions
   if (price_beyond_jaw && current_direction == breakout_direction)
   {
             // Calculate elapsed time from breakout start
       double elapsed_seconds = (double)(TimeCurrent() - breakout_start_time);
       
       if (elapsed_seconds >= PeriodSeconds()) // Need at least 1 bar worth of time
      {
         double actual_slope_angle = CalculateSlopeAngleFromSeconds(breakout_start_price, price, elapsed_seconds);
         
         // Calculate price distance from jaw
         double price_distance_from_jaw = MathAbs(price - jaw);
         double required_distance = MIN_ATR_BREAKOUT_DISTANCE_MULTIPLIER * atr_value;

         // Check trend consistency using recent price history (includes current LIVE price)
         bool trend_consistent = ValidatePriceTrendConsistency(breakout_direction);

         // Check all breakout conditions
         bool slope_valid = (actual_slope_angle >= MIN_BREAKOUT_SLOPE);
         bool distance_valid = (price_distance_from_jaw >= required_distance);
         bool direction_valid = (current_direction == breakout_direction);

         if (slope_valid && distance_valid && direction_valid && trend_consistent)
         {
            if (DEBUG_LEVEL >= 1)
            {
               Print("✅ BREAKOUT VALIDATED:");
               Print("  Direction: ", breakout_direction == BULLISH_TREND ? "BULLISH" : "BEARISH");
               Print("  Actual slope angle: ", DoubleToString(actual_slope_angle, 2), "° (min: ", DoubleToString(MIN_BREAKOUT_SLOPE, 2), "°)");
                               Print("  Elapsed time: ", DoubleToString(elapsed_seconds, 1), " seconds from jaw crossing");
               Print("  Distance from jaw: ", DoubleToString(price_distance_from_jaw, 2), " (min: ", DoubleToString(required_distance, 2), ")");
               Print("  Trend consistency: ✓ (recent ", BREAKOUT_TREND_CONSISTENCY_BARS, "-bar history confirms direction)");
            }
            
            ExecuteBreakoutTrade(breakout_direction);
         }
         else if (DEBUG_LEVEL >= 2)
         {
            // Debug why breakout failed
                         Print("⏳ BREAKOUT PENDING: Elapsed ", DoubleToString(elapsed_seconds, 1), " seconds");
            if (!slope_valid) Print("  Slope: ", DoubleToString(actual_slope_angle, 2), "° < ", MIN_BREAKOUT_SLOPE, "° ❌");
            if (!distance_valid) Print("  Distance: ", DoubleToString(price_distance_from_jaw, 2), " < ", DoubleToString(required_distance, 2), " ❌");
            if (!trend_consistent) Print("  Trend consistency: ❌");
         }
      }
   }
   else if (price_beyond_jaw && current_direction != breakout_direction)
   {
      // Price changed direction - reset tracking
      if (DEBUG_LEVEL >= 2)
         Print("🔄 BREAKOUT DIRECTION CHANGED: Resetting tracking");
      ResetBreakoutTracking();
   }
   else if (price_beyond_jaw && current_direction == NO_TREND)
   {
      // Price moved back to jaw area - reset tracking
      if (DEBUG_LEVEL >= 2)
         Print("↩️ PRICE RETURNED TO JAW: Resetting tracking");
      ResetBreakoutTracking();
   }
}

void UpdatePriceHistory()
{
   // Resize array if needed
   if (ArraySize(price_history) != BREAKOUT_TREND_CONSISTENCY_BARS)
      ArrayResize(price_history, BREAKOUT_TREND_CONSISTENCY_BARS);

   // IMPORTANT: Store current LIVE price at index 0 for trend consistency validation
   // This ensures ValidatePriceTrendConsistency() includes current market action
   price_history[0] = price;  // ← Current live price (real-time)

   // Fill historical positions with actual closing prices of previous bars
   // Array structure: [0]=Live, [1]=1-bar-ago, [2]=2-bars-ago, etc.
   double close_prices[];
   int bars_needed = BREAKOUT_TREND_CONSISTENCY_BARS - 1; // Don't include current bar
   
   if (CopyClose(_Symbol, _Period, 1, bars_needed, close_prices) > 0)
   {
      for (int i = 0; i < bars_needed && i < ArraySize(close_prices); i++)
      {
         price_history[i + 1] = close_prices[i]; // close_prices[0] is 1 bar ago, etc.
      }
   }
}

void ResetBreakoutTracking()
{
   price_beyond_jaw = false;
   breakout_start_time = 0;
   breakout_start_price = 0;
   breakout_direction = NO_TREND;
}

bool ValidatePriceTrendConsistency(TrendDirection direction)
{
   // Validates that recent price movements (including LIVE price) support the breakout direction
   // Uses current live price + historical bar closes to ensure trend consistency
   // Use only the fixed window for trend consistency check
   int bars_to_check = BREAKOUT_TREND_CONSISTENCY_BARS;
   if (ArraySize(price_history) < bars_to_check)
      return false;

   int positive_moves = 0;
   int negative_moves = 0;
   
   // Count price movements in the recent window INCLUDING current live price
   // Example with BREAKOUT_TREND_CONSISTENCY_BARS=3: Analyzes 2 movements:
   //   i=0: Live price vs 1-bar-ago  ← INCLUDES current market action
   //   i=1: 1-bar-ago vs 2-bars-ago  ← Recent historical movement
   for (int i = 0; i < bars_to_check - 1; i++)
   {
      double current_price = price_history[i];     // More recent (i=0 is LIVE price)
      double previous_price = price_history[i + 1]; // Older
      
      if (current_price > previous_price)
         positive_moves++;
      else if (current_price < previous_price)
         negative_moves++;
   }
   
   // For bullish breakout: majority of recent moves should be positive
   // For bearish breakout: majority of recent moves should be negative
   if (direction == BULLISH_TREND)
   {
      return (positive_moves > negative_moves);
   }
   else if (direction == BEARISH_TREND)
   {
      return (negative_moves > positive_moves);
   }
   
   return false;
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
   if (TimeCurrent() - last_signal_time < MIN_SIGNAL_COOLDOWN_MINUTES * 60)
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

   // Stop breakout monitoring after trade execution
   monitoring_breakout = false;
   ResetBreakoutTracking(); // Reset tracking after trade execution

   // Switch to position management phase
   if (DEBUG_LEVEL >= 1)
      Print("🔄 PHASE SWITCH: Trade executed → Position management active (monitoring stopped)");
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

   // PHASE 1: Waiting for mouth to open after breakout entry (TIME-BASED)
   if (waiting_for_mouth_open && !mouth_has_opened)
   {
      double minutes_since_entry = (current_time - entry_time) / 60.0;
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
            Print("✅ MOUTH OPENED: Alligator confirmed awake AND diverging after ", DoubleToString(minutes_since_entry, 1), " minutes");
            Print("  📊 Line alignment: ", (position_direction == BULLISH_TREND) ? "Bullish" : "Bearish", " ✓");
            Print("  📈 Lines diverging: YES ✓");
         }
      }
      else if (minutes_since_entry >= MAX_MOUTH_OPENING_MINUTES)
      {
         // Mouth didn't open in time - exit trade
         should_exit = true;
         string alignment_status = "";
         if (position_direction == BULLISH_TREND)
            alignment_status = is_bullish_awake ? "Aligned ✓" : "Not aligned ❌";
         else
            alignment_status = is_bearish_awake ? "Aligned ✓" : "Not aligned ❌";

         exit_reason = "Mouth failed to open within " + DoubleToString(MAX_MOUTH_OPENING_MINUTES, 1) + " minutes (" +
                       alignment_status + ", Diverging: " + (lines_are_diverging ? "YES ✓" : "NO ❌") + ")";
      }
      // Don't exit just because alligator is sleeping - wait for full window
      else
      {
         // Debug waiting progress (TIME-BASED)
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

               Print("⏳ WAITING FOR MOUTH OPENING: ", DoubleToString(minutes_since_entry, 1), "/", DoubleToString(MAX_MOUTH_OPENING_MINUTES, 1), " minutes");
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
      // Check if mouth closed again (lines no longer diverging)
      bool lines_are_diverging = CheckLinesAreDiverging();
      if (!lines_are_diverging)
      {
         should_exit = true;
         exit_reason = "Alligator mouth closed - lines no longer diverging";
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
         double minutes_in_trade = (current_time - entry_time) / 60.0;

         Print("=== POSITION STATUS ===");
         Print("Direction: ", direction, " | P&L: $", DoubleToString(profit, 2));
         Print("Minutes in trade: ", DoubleToString(minutes_in_trade, 1));
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

double CalculateSlopeAngleFromSeconds(double price_start, double price_end, double elapsed_seconds)
{
   // Calculate percentage change to make it scale-independent
   double percentage_change = MathAbs(price_end - price_start) / price_start * 100.0;

   // Convert seconds directly to hours
   double time_duration_hours = elapsed_seconds / 3600.0;

   // Avoid division by zero
   if (time_duration_hours <= 0.0)
      return 0.0;

   // Calculate slope as percentage change per hour
   double slope = percentage_change / time_duration_hours;

   // Convert to angle in degrees
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
   // Alligator status (TIME-BASED)
   string gator_status = "";
   if (is_sleeping)
   {
      double current_sleep_minutes = sleep_start_time > 0 ? (TimeCurrent() - sleep_start_time) / 60.0 : 0.0;
      string sleep_info = "";
      if (current_sleep_minutes >= MIN_SLEEPING_MINUTES)
         sleep_info = " (READY " + DoubleToString(current_sleep_minutes, 1) + "/" + DoubleToString(MIN_SLEEPING_MINUTES, 1) + ")";
      else
         sleep_info = " (" + DoubleToString(current_sleep_minutes, 1) + "/" + DoubleToString(MIN_SLEEPING_MINUTES, 1) + ")";

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
      // Show breakout tracking info if price is beyond jaw
      string slope_info = "";
      double required_distance = MIN_ATR_BREAKOUT_DISTANCE_MULTIPLIER * atr_value;
      double current_distance = MathAbs(price - jaw);
      
      if (price_beyond_jaw && breakout_start_time > 0)
      {
         double elapsed_seconds = (double)(TimeCurrent() - breakout_start_time);
         if (elapsed_seconds > 0)
         {
            double current_slope = CalculateSlopeAngleFromSeconds(breakout_start_price, price, elapsed_seconds);
            slope_info = " | Tracking: " + DoubleToString(current_slope, 1) + "°/" + DoubleToString(MIN_BREAKOUT_SLOPE, 1) + "°";
         }
      }
      
      slope_info += " | Dist: " + DoubleToString(current_distance, 1) + "/" + DoubleToString(required_distance, 1);
      
      breakout_status = "🎯 ACTIVE MONITORING" + slope_info;
   }
   else if (current_position_ticket != 0)
   {
      breakout_status = "💼 POSITION ACTIVE: Monitoring paused";
   }
   else
   {
      double current_sleep_minutes = is_sleeping && sleep_start_time > 0 ? (TimeCurrent() - sleep_start_time) / 60.0 : 0.0;
      if (current_sleep_minutes >= MIN_SLEEPING_MINUTES)
      {
         breakout_status = "😴 READY: Will monitor when no position";
      }
      else
      {
         double remaining_minutes = MIN_SLEEPING_MINUTES - current_sleep_minutes;
         breakout_status = "⏳ Need " + DoubleToString(remaining_minutes, 1) + " more sleep minutes";
      }
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
         double minutes_waiting = (TimeCurrent() - entry_time) / 60.0;
         position_status += " | Waiting for mouth (" + DoubleToString(minutes_waiting, 1) + "/" +
                            DoubleToString(MAX_MOUTH_OPENING_MINUTES, 1) + ")";
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