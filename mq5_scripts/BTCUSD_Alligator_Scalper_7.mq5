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
// ✅ COMPLETED: Reorganized state management with formal state machine
// ⏳ REMAINING: Convert GATOR_HORIZONTAL_CHECK_BARS and BREAKOUT_TREND_CONSISTENCY_BARS to time-based

//============================================================================
//                           USER SETTINGS
//============================================================================

// Risk Management
input double RISK_PERCENT = 1.0; // RISK_PERCENT: Risk per trade (% of account)
input double REWARD_RATIO = 2.0; // REWARD_RATIO: Reward:Risk ratio (2.0 = 2:1)
input int MAX_DAILY_TRADES = 50; // MAX_DAILY_TRADES: Maximum trades per day

// Alligator Indicator Settings
input int JAW_PERIOD = 21;  // JAW_PERIOD: Jaw period (Blue line - slowest)
input int JAW_SHIFT = 8;    // JAW_SHIFT: Jaw shift
input int TEETH_PERIOD = 13; // TEETH_PERIOD: Teeth period (Red line - medium)
input int TEETH_SHIFT = 5;  // TEETH_SHIFT: Teeth shift
input int LIPS_PERIOD = 8;  // LIPS_PERIOD: Lips period (Green line - fastest)
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
input double MIN_BREAKOUT_SLOPE = 45;   // MIN_BREAKOUT_SLOPE: Minimum slope angle from jaw (degrees) for valid breakout
input int BREAKOUT_TREND_CONSISTENCY_BARS = 3; // BREAKOUT_TREND_CONSISTENCY_BARS: Number of recent bars analyzed to validate price movement direction matches breakout (0 = disable trend consistency, use distance-only)
input double MIN_ATR_BREAKOUT_DISTANCE_MULTIPLIER = 1.5; // MIN_ATR_BREAKOUT_DISTANCE_MULTIPLIER: ATR multiplier for minimum dollar distance price must move from jaw
// Trading Controls
input double MIN_SIGNAL_COOLDOWN_MINUTES = 3.0; // MIN_SIGNAL_COOLDOWN_MINUTES: Minimum minutes between signals (allows fractions)
input bool STRICT_BREAKOUT_TIMING = false;  // STRICT_BREAKOUT_TIMING: Only trade breakouts while alligator is still sleeping (reduces late entries)
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

// Trading state enums
enum TrendDirection
{
   NO_TREND = 0,
   BULLISH_TREND = 1,
   BEARISH_TREND = 2
};

enum AlligatorState
{
   STATE_SLEEPING = 0,           // Alligator is sleeping (lines horizontal & close)
   STATE_READY_TO_MONITOR = 1,   // Slept long enough, ready to monitor breakouts
   STATE_MONITORING_BREAKOUT = 2, // Actively monitoring for breakout signals
   STATE_TRADE_EXECUTED = 3,     // Trade placed, waiting for mouth to open
   STATE_POSITION_ACTIVE = 4,    // Position active with mouth open
   STATE_WAITING_FOR_SLEEP = 5   // Position closed, waiting for alligator to sleep
};

// Centralized state management
AlligatorState current_state = STATE_SLEEPING;
datetime state_start_time = 0;       // When current state began
TrendDirection position_direction = NO_TREND;

// Alligator analysis results
bool lines_are_horizontal = false;
bool lines_are_diverging = false;
bool is_bullish_awake = false;
bool is_bearish_awake = false;

// Breakout tracking
bool price_beyond_jaw = false;
datetime breakout_start_time = 0;
double breakout_start_price = 0;
double breakout_start_atr = 0;          // ATR value when breakout tracking started
TrendDirection breakout_direction = NO_TREND;
double price_history[];

// Position tracking
ulong current_position_ticket = 0;
int daily_trade_count = 0;
datetime last_trade_date = 0;
datetime last_signal_time = 0;

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

   // Wait a moment for indicators to initialize
   Sleep(100);

   // Determine proper starting state based on actual conditions
   if (UpdateMarketData())
   {
      AnalyzeAlligatorConditions();
      
      // Set appropriate initial state based on real conditions
      if (lines_are_horizontal)
      {
         current_state = STATE_SLEEPING;
         state_start_time = TimeCurrent();
         Print("🎯 STARTING STATE: SLEEPING (alligator is actually sleeping)");
      }
      else if (is_bullish_awake || is_bearish_awake)
      {
         current_state = STATE_WAITING_FOR_SLEEP;
         state_start_time = TimeCurrent();
         Print("🎯 STARTING STATE: WAITING_FOR_SLEEP (alligator is awake - entering cooldown)");
      }
      else
      {
         // Lines are moving but not awake yet
         current_state = STATE_WAITING_FOR_SLEEP;
         state_start_time = TimeCurrent();
         Print("🎯 STARTING STATE: WAITING_FOR_SLEEP (lines are separating - entering cooldown)");
      }
   }
   else
   {
      // Fallback if market data unavailable
      current_state = STATE_SLEEPING;
      state_start_time = TimeCurrent();
      Print("⚠️ STARTING STATE: SLEEPING (fallback - couldn't get market data)");
   }

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
   Print("State Machine: Sleep → Ready → Monitor → Trade → Position → Wait → Sleep");
   Print("Breakout entry: Price angle from jaw during monitoring phase");
   Print("Mouth opening: Lines must be aligned AND diverging during MAX_MOUTH_OPENING_MINUTES");
   Print("Strict breakout timing: ", STRICT_BREAKOUT_TIMING ? "ON (miss boat if mouth opens before trade)" : "OFF (continue monitoring after mouth opens)");
   Print("--- Price Breakout Validation ---");
   Print("Minimum breakout slope: ", MIN_BREAKOUT_SLOPE, "° angle from actual jaw crossing point");
   if (BREAKOUT_TREND_CONSISTENCY_BARS > 0)
      Print("Trend consistency window: ", BREAKOUT_TREND_CONSISTENCY_BARS, " bars (for recent trend validation)");
   else
      Print("Trend consistency: DISABLED (0 bars) - using distance-only validation");
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

   // Analyze alligator conditions (independent of state)
   AnalyzeAlligatorConditions();

   // Process state machine
   ProcessStateMachine();

   // Update display
   if (SHOW_INFO_PANEL)
      ShowInfoPanel();
}

//============================================================================
//                         MARKET DATA UPDATE
//============================================================================

bool UpdateMarketData()
{
   // Get current price (live price = average of bid/ask)
   price = (SymbolInfoDouble(_Symbol, SYMBOL_BID) + SymbolInfoDouble(_Symbol, SYMBOL_ASK)) / 2.0;

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
//                      ALLIGATOR CONDITIONS ANALYSIS
//============================================================================

void AnalyzeAlligatorConditions()
{
   // Analyze line positioning and slopes (independent of state)
   bool lines_are_close_by_spread = CheckLinesAreCloseBySpread();
   lines_are_horizontal = CheckLinesAreHorizontal(MAX_LINE_SLOPE) && lines_are_close_by_spread;
   lines_are_diverging = CheckLinesAreDiverging();
   
   // Determine awake states (requires alignment AND divergence, NOT sleeping)
   bool has_bullish_alignment = (price > lips && lips > teeth && teeth > jaw);
   bool has_bearish_alignment = (price < lips && lips < teeth && teeth < jaw);
   
   is_bullish_awake = has_bullish_alignment && lines_are_diverging && !lines_are_close_by_spread;
   is_bearish_awake = has_bearish_alignment && lines_are_diverging && !lines_are_close_by_spread;
}

//============================================================================
//                         STATE MACHINE PROCESSING
//============================================================================

void ProcessStateMachine()
{
   double state_duration_minutes = (TimeCurrent() - state_start_time) / 60.0;
   
   switch (current_state)
   {
      case STATE_SLEEPING:
         ProcessSleepingState(state_duration_minutes);
         break;
         
      case STATE_READY_TO_MONITOR:
         ProcessReadyToMonitorState();
         break;
         
      case STATE_MONITORING_BREAKOUT:
         ProcessMonitoringBreakoutState();
         break;
         
      case STATE_TRADE_EXECUTED:
         ProcessTradeExecutedState(state_duration_minutes);
         break;
         
      case STATE_POSITION_ACTIVE:
         ProcessPositionActiveState();
         break;
         
      case STATE_WAITING_FOR_SLEEP:
         ProcessWaitingForSleepState();
         break;
   }
}

void ProcessSleepingState(double state_duration_minutes)
{
   if (!lines_are_horizontal)
   {
      // Lines no longer sleeping - reset to beginning
      TransitionToState(STATE_SLEEPING, "Lines awakened - restarting sleep cycle");
      return;
   }
   
   if (state_duration_minutes >= MIN_SLEEPING_MINUTES)
   {
      TransitionToState(STATE_READY_TO_MONITOR, "Slept long enough - ready to monitor");
   }
}

void ProcessReadyToMonitorState()
{
   if (lines_are_horizontal)
   {
      // Still sleeping, start monitoring
      TransitionToState(STATE_MONITORING_BREAKOUT, "Starting breakout monitoring");
   }
   else
   {
      // No longer sleeping - go back to sleep
      TransitionToState(STATE_SLEEPING, "No longer sleeping - restarting sleep cycle");
   }
}

void ProcessMonitoringBreakoutState()
{
   // First check: Are basic sleep conditions still met?
   if (!lines_are_horizontal)
   {
      // Lines no longer sleeping - exit monitoring
      TransitionToState(STATE_WAITING_FOR_SLEEP, "Lines no longer horizontal - exiting monitoring");
      ResetBreakoutTracking();
      return;
   }
   
   // Second check: Has alligator woken up (mouth opened) while we were monitoring?
   if (STRICT_BREAKOUT_TIMING && (is_bullish_awake || is_bearish_awake))
   {
      // Alligator woke up before we could execute trade - missed the boat
      TransitionToState(STATE_WAITING_FOR_SLEEP, "Alligator woke up during monitoring - missed the boat (strict timing)");
      ResetBreakoutTracking();
      return;
   }
   
   // Continue monitoring for breakout
   // In non-strict mode, we continue even if alligator wakes up
   CheckPriceBreakoutFromJaw();
}

void ProcessTradeExecutedState(double state_duration_minutes)
{
   // Check if position still exists
   if (!PositionSelectByTicket(current_position_ticket))
   {
      // Position closed before mouth opened
      TransitionToState(STATE_WAITING_FOR_SLEEP, "Position closed before mouth opened");
      ResetPositionTracking();
      return;
   }
   
   // Check if mouth opened (alligator awake in our direction)
   bool mouth_opened = false;
   if (position_direction == BULLISH_TREND && is_bullish_awake)
      mouth_opened = true;
   else if (position_direction == BEARISH_TREND && is_bearish_awake)
      mouth_opened = true;
   
   if (mouth_opened)
   {
      TransitionToState(STATE_POSITION_ACTIVE, "Mouth opened - position now active");
   }
   else if (state_duration_minutes >= MAX_MOUTH_OPENING_MINUTES)
   {
      // Timeout - close position
      ClosePosition("Mouth failed to open within timeout");
      TransitionToState(STATE_WAITING_FOR_SLEEP, "Mouth opening timeout");
   }
}

void ProcessPositionActiveState()
{
   // Check if position still exists
   if (!PositionSelectByTicket(current_position_ticket))
   {
      // Position closed (SL/TP hit)
      TransitionToState(STATE_WAITING_FOR_SLEEP, "Position closed by SL/TP");
      ResetPositionTracking();
      return;
   }
   
   // Check exit conditions
   bool should_exit = false;
   string exit_reason = "";
   
   // Check if alligator went back to sleep or lost proper awake state
   bool still_awake = false;
   if (position_direction == BULLISH_TREND && is_bullish_awake)
      still_awake = true;
   else if (position_direction == BEARISH_TREND && is_bearish_awake)
      still_awake = true;
      
   if (!still_awake)
   {
      should_exit = true;
      if (lines_are_horizontal)
         exit_reason = "Alligator went back to sleep";
      else
         exit_reason = "Alligator mouth closed - lost alignment or divergence";
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
   
   if (should_exit)
   {
      ClosePosition(exit_reason);
      TransitionToState(STATE_WAITING_FOR_SLEEP, "Position manually closed");
   }
}

void ProcessWaitingForSleepState()
{
   if (lines_are_horizontal)
   {
      TransitionToState(STATE_SLEEPING, "Alligator returned to sleep");
   }
}

void TransitionToState(AlligatorState new_state, string reason)
{
   if (new_state != current_state)
   {
      if (DEBUG_LEVEL >= 1)
      {
         string old_state_name = GetStateName(current_state);
         string new_state_name = GetStateName(new_state);
         Print("🔄 STATE TRANSITION: ", old_state_name, " → ", new_state_name, " (", reason, ")");
      }
      
      current_state = new_state;
      state_start_time = TimeCurrent();
   }
}

string GetStateName(AlligatorState state)
{
   switch (state)
   {
      case STATE_SLEEPING: return "SLEEPING";
      case STATE_READY_TO_MONITOR: return "READY_TO_MONITOR";
      case STATE_MONITORING_BREAKOUT: return "MONITORING_BREAKOUT";
      case STATE_TRADE_EXECUTED: return "TRADE_EXECUTED";
      case STATE_POSITION_ACTIVE: return "POSITION_ACTIVE";
      case STATE_WAITING_FOR_SLEEP: return "WAITING_FOR_SLEEP";
      default: return "UNKNOWN";
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
   if (current_state != STATE_MONITORING_BREAKOUT)
      return;

   // Update price history array with current LIVE price + recent bar closes
   // This enables trend consistency validation that includes real-time market action
   // Only update if trend consistency is enabled (BREAKOUT_TREND_CONSISTENCY_BARS > 0)
   if (BREAKOUT_TREND_CONSISTENCY_BARS > 0)
   {
      UpdatePriceHistory();
      
      // Check if we have enough price data for trend consistency
      if (ArraySize(price_history) < BREAKOUT_TREND_CONSISTENCY_BARS)
         return;
   }

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
      breakout_start_atr = atr_value;
      breakout_direction = current_direction;

      if (DEBUG_LEVEL >= 2)
      {
         Print("🎯 PRICE BEYOND JAW: Starting breakout tracking at $", DoubleToString(price, 2), 
               " (", current_direction == BULLISH_TREND ? "BULLISH" : "BEARISH", ")");
         Print("  Captured ATR for validation: $", DoubleToString(breakout_start_atr, 2));
      }
   }

   // Step 2: If price has moved beyond jaw, check all breakout conditions
   if (price_beyond_jaw && current_direction == breakout_direction)
   {
             // Calculate elapsed time from breakout start
       double elapsed_seconds = (double)(TimeCurrent() - breakout_start_time);
       
       if (elapsed_seconds >= PeriodSeconds()) // Need at least 1 bar worth of time
      {
         double actual_slope_angle = CalculateSlopeAngleFromSeconds(breakout_start_price, price, elapsed_seconds);
         
         // Calculate price distance from jaw (use ATR from when breakout started)
         double price_distance_from_jaw = MathAbs(price - jaw);
         double atr_for_validation = (breakout_start_atr > 0) ? breakout_start_atr : atr_value;
         double required_distance = MIN_ATR_BREAKOUT_DISTANCE_MULTIPLIER * atr_for_validation;

         // Check trend consistency using recent price history (includes current LIVE price)
         // Skip trend consistency check if BREAKOUT_TREND_CONSISTENCY_BARS is 0
         bool trend_consistent = true; // Default to true when trend consistency is disabled
         if (BREAKOUT_TREND_CONSISTENCY_BARS > 0)
         {
            trend_consistent = ValidatePriceTrendConsistency(breakout_direction);
         }

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
               Print("  ATR for validation: $", DoubleToString(atr_for_validation, 2), 
                     (breakout_start_atr > 0) ? " (captured at breakout start)" : " (using current ATR as fallback)");
               if (BREAKOUT_TREND_CONSISTENCY_BARS > 0)
                  Print("  Trend consistency: ✓ (recent ", BREAKOUT_TREND_CONSISTENCY_BARS, "-bar history confirms direction)");
               else
                  Print("  Trend consistency: DISABLED (BREAKOUT_TREND_CONSISTENCY_BARS=0 - using distance-only validation)");
            }
            
            ExecuteBreakoutTrade(breakout_direction);
         }
         else if (DEBUG_LEVEL >= 2)
         {
            // Debug why breakout failed
            Print("⏳ BREAKOUT PENDING: Elapsed ", DoubleToString(elapsed_seconds, 1), " seconds");
            if (!slope_valid) Print("  Slope: ", DoubleToString(actual_slope_angle, 2), "° < ", MIN_BREAKOUT_SLOPE, "° ❌");
            if (!distance_valid) 
            {
               Print("  Distance: ", DoubleToString(price_distance_from_jaw, 2), " < ", DoubleToString(required_distance, 2), " ❌");
               Print("  ATR for validation: $", DoubleToString(atr_for_validation, 2), 
                     (breakout_start_atr > 0) ? " (from breakout start)" : " (current ATR fallback)");
            }
            if (!trend_consistent && BREAKOUT_TREND_CONSISTENCY_BARS > 0) 
               Print("  Trend consistency: ❌");
            else if (BREAKOUT_TREND_CONSISTENCY_BARS == 0)
               Print("  Trend consistency: DISABLED");
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
   breakout_start_atr = 0;
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

// Trade signals are now handled by the state machine in ProcessStateMachine()
// Breakout detection happens in CheckPriceBreakoutFromJaw() when in STATE_MONITORING_BREAKOUT

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
   }
   else if (direction == BEARISH_TREND)
   {
      if (DEBUG_LEVEL >= 1)
         Print("🔴 EXECUTING BEARISH BREAKOUT TRADE");

      ExecuteSellTrade();
   }

   last_signal_time = TimeCurrent();
   ResetBreakoutTracking(); // Reset tracking after trade execution

   // Transition to trade executed state for mouth opening monitoring
   if (current_position_ticket != 0)
   {
      TransitionToState(STATE_TRADE_EXECUTED, "Trade executed - waiting for mouth to open");
   }
}

//============================================================================
//                          TRADE EXECUTION
//============================================================================

void ExecuteBuyTrade()
{
   double entry_price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   // Calculate position size based on risk (use current ATR for position sizing)
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

   // Calculate position size based on risk (use current ATR for position sizing)
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

// Position management is now handled by the state machine in ProcessStateMachine()
// Individual states handle their own position logic:
// - STATE_TRADE_EXECUTED: Waits for mouth to open
// - STATE_POSITION_ACTIVE: Monitors for exit conditions

void ResetPositionTracking()
{
   current_position_ticket = 0;
   position_direction = NO_TREND;
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
   if (elapsed_seconds <= 0.0)
      return 0.0;
      
   // True geometric calculation: angle = atan(rise/run)
   double price_change = MathAbs(price_end - price_start);  // Rise (dollars)
   double time_change = elapsed_seconds;                    // Run (seconds)
   
   // Geometric slope: dollars per second
   double slope = price_change / time_change;
   
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
   // Alligator status based on conditions
   string gator_status = "";
   if (lines_are_horizontal)
   {
      double current_sleep_minutes = (TimeCurrent() - state_start_time) / 60.0;
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

   // State status with explicit conditions
   string state_status = "";
   double state_duration_minutes = (TimeCurrent() - state_start_time) / 60.0;
   
   switch (current_state)
   {
      case STATE_SLEEPING:
         state_status = "SLEEPING (lines_horizontal=" + (lines_are_horizontal ? "✓" : "✗") + 
                       ", time=" + DoubleToString(state_duration_minutes, 1) + "/" + DoubleToString(MIN_SLEEPING_MINUTES, 1) + "min)";
         break;
         
      case STATE_READY_TO_MONITOR:
         state_status = "READY (lines_horizontal=" + (lines_are_horizontal ? "✓" : "✗") + 
                       ", slept=" + DoubleToString(state_duration_minutes, 1) + "min)";
         break;
         
      case STATE_MONITORING_BREAKOUT:
         state_status = "MONITORING (lines_horizontal=" + (lines_are_horizontal ? "✓" : "✗") + 
                       ", price_beyond_jaw=" + (price_beyond_jaw ? "✓" : "✗") + ")";
         break;
         
      case STATE_TRADE_EXECUTED:
         state_status = "TRADE_EXECUTED (position=" + (current_position_ticket != 0 ? "✓" : "✗") + 
                       ", mouth_open=" + ((is_bullish_awake && position_direction == BULLISH_TREND) || 
                                         (is_bearish_awake && position_direction == BEARISH_TREND) ? "✓" : "✗") + 
                       ", wait=" + DoubleToString(state_duration_minutes, 1) + "/" + DoubleToString(MAX_MOUTH_OPENING_MINUTES, 1) + "min)";
         break;
         
      case STATE_POSITION_ACTIVE:
         state_status = "POSITION_ACTIVE (position=" + (current_position_ticket != 0 ? "✓" : "✗") + 
                       ", mouth_open=" + ((is_bullish_awake && position_direction == BULLISH_TREND) || 
                                         (is_bearish_awake && position_direction == BEARISH_TREND) ? "✓" : "✗") + ")";
         break;
         
      case STATE_WAITING_FOR_SLEEP:
         state_status = "WAITING_FOR_SLEEP (lines_horizontal=" + (lines_are_horizontal ? "✓" : "✗") + 
                       ", cooldown=" + DoubleToString(state_duration_minutes, 1) + "min)";
         break;
         
      default:
         state_status = "UNKNOWN";
         break;
   }

   // Position status based on current state
   string position_status = "No Position";
   if (current_position_ticket != 0)
   {
      double profit = PositionGetDouble(POSITION_PROFIT);
      string direction = (position_direction == BULLISH_TREND) ? "LONG" : "SHORT";
      position_status = direction + " | P&L: $" + DoubleToString(profit, 2);

      if (current_state == STATE_TRADE_EXECUTED)
      {
         double minutes_waiting = (TimeCurrent() - state_start_time) / 60.0;
         position_status += " | Waiting for mouth (" + DoubleToString(minutes_waiting, 1) + "/" +
                            DoubleToString(MAX_MOUTH_OPENING_MINUTES, 1) + ")";
      }
      else if (current_state == STATE_POSITION_ACTIVE)
      {
         position_status += " | Mouth OPEN";
      }
   }

   string info = StringFormat(
       "🐊 ADVANCED ALLIGATOR SCALPER | Trades: %d/%d\n" +
           "State: %s\n" +
           "Gator: %s\n" +
           "Position: %s\n" +
           "Price: $%s | Lips: $%s | Teeth: $%s | Jaw: $%s\n" +
           "ATR: $%s | Risk: %.1f%% | Reward: %.1f:1 | Strict: %s",
       daily_trade_count, MAX_DAILY_TRADES,
       state_status,
       gator_status,
       position_status,
       DoubleToString(price, 2),
       DoubleToString(lips, 2),
       DoubleToString(teeth, 2),
       DoubleToString(jaw, 2),
       DoubleToString(atr_value, 2),
       RISK_PERCENT,
       REWARD_RATIO,
       STRICT_BREAKOUT_TIMING ? "YES" : "NO");

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
   double profit_trades = TesterStatistics(STAT_PROFIT_TRADES);
   double loss_trades = TesterStatistics(STAT_LOSS_TRADES);
   double gross_profit = TesterStatistics(STAT_GROSS_PROFIT);
   double gross_loss = TesterStatistics(STAT_GROSS_LOSS);
   double net_profit = TesterStatistics(STAT_PROFIT);
   double max_drawdown = TesterStatistics(STAT_BALANCE_DD);
   double initial_deposit = TesterStatistics(STAT_INITIAL_DEPOSIT);
   double profit_factor = TesterStatistics(STAT_PROFIT_FACTOR);
   
   // Avoid division by zero and reject invalid data
   if (total_trades < 1 || initial_deposit <= 0)
      return 0.0;
   
   // Target number of trades for optimization
   double target_trades = 70.0;
   
   // Calculate trade volume penalty/bonus
   double trade_penalty_multiplier = 1.0;
   
   if (total_trades < target_trades)
   {
      // Progressive penalty: the further below target, the worse the penalty
      // Penalty ranges from 0.1x (far below) to 1.0x (at target)
      double trade_ratio = total_trades / target_trades;
      trade_penalty_multiplier = 0.1 + (0.9 * trade_ratio); // Scales from 0.1 to 1.0
      
      if (DEBUG_LEVEL >= 1)
         Print("TRADE VOLUME PENALTY: ", (int)total_trades, " trades < ", (int)target_trades, 
               " target. Penalty multiplier: ", DoubleToString(trade_penalty_multiplier, 2), "x");
   }
   else if (total_trades > target_trades)
   {
      // Small bonus for exceeding target (up to 1.2x multiplier)
      double excess_ratio = (total_trades - target_trades) / target_trades;
      trade_penalty_multiplier = 1.0 + MathMin(0.2, excess_ratio * 0.1); // Max 1.2x bonus
      
      if (DEBUG_LEVEL >= 1)
         Print("TRADE VOLUME BONUS: ", (int)total_trades, " trades > ", (int)target_trades, 
               " target. Bonus multiplier: ", DoubleToString(trade_penalty_multiplier, 2), "x");
   }
   
   // Immediately reject zero or negative profit strategies
   if (net_profit <= 0.0)
   {
      if (DEBUG_LEVEL >= 1)
         Print("OPTIMIZATION REJECTED: Zero or negative profit (", DoubleToString(net_profit, 2), ")");
      return 0.0;
   }
   
   // Calculate additional metrics
   double win_rate = (profit_trades / total_trades) * 100.0;
   double roi_percent = (net_profit / initial_deposit) * 100.0;
   double drawdown_percent = (max_drawdown / initial_deposit) * 100.0;
   
   // Reject strategies with poor win rates (less than 30%)
   if (win_rate < 30.0)
   {
      if (DEBUG_LEVEL >= 1)
         Print("OPTIMIZATION REJECTED: Win rate too low (", DoubleToString(win_rate, 1), "%)");
      return 0.0;
   }
   
   // ENHANCED FITNESS: Profit + Win Rate + Low Drawdown + Trade Volume
   
   // Base score: Profit adjusted for drawdown
   double profit_score;
   if (drawdown_percent > 0.1)
      profit_score = net_profit / drawdown_percent;
   else
      profit_score = net_profit * 100.0;
   
   // Win rate bonus: Higher win rates get multiplier boost
   double win_rate_multiplier = 1.0 + (win_rate - 50.0) / 100.0;  // 50% = 1.0x, 60% = 1.1x, 70% = 1.2x
   if (win_rate_multiplier < 0.5) win_rate_multiplier = 0.5;  // Minimum 0.5x
   
   // Profit factor bonus: PF > 1.5 gets bonus
   double pf_multiplier = 1.0;
   if (profit_factor > 1.5)
      pf_multiplier = 1.0 + (profit_factor - 1.5) * 0.2;  // Each 0.1 above 1.5 adds 2% bonus
   
   // Trade volume multiplier (logarithmic scaling for additional trades)
   double trade_multiplier = MathLog(total_trades + 1);
   
   // Final fitness: Profit efficiency × Win rate × Profit factor × Trade volume × Trade target penalty/bonus
   double fitness = profit_score * win_rate_multiplier * pf_multiplier * trade_multiplier * trade_penalty_multiplier;
   
   // Debug output for optimization
   if (DEBUG_LEVEL >= 1)
   {
      Print("=== ENHANCED OPTIMIZATION RESULTS ===");
      Print("Total Trades: ", (int)total_trades, " | Wins: ", (int)profit_trades, " | Losses: ", (int)loss_trades);
      Print("Win Rate: ", DoubleToString(win_rate, 1), "% | Profit Factor: ", DoubleToString(profit_factor, 2));
      Print("Net Profit: $", DoubleToString(net_profit, 2), " | ROI: ", DoubleToString(roi_percent, 2), "%");
      Print("Max Drawdown: ", DoubleToString(drawdown_percent, 2), "%");
      Print("--- Fitness Components ---");
      Print("Profit Score: ", DoubleToString(profit_score, 2));
      Print("Win Rate Multiplier: ", DoubleToString(win_rate_multiplier, 2), "x");
      Print("Profit Factor Multiplier: ", DoubleToString(pf_multiplier, 2), "x");
      Print("Trade Volume Multiplier: ", DoubleToString(trade_multiplier, 2));
      Print("Trade Target Penalty/Bonus: ", DoubleToString(trade_penalty_multiplier, 2), "x");
      Print("FINAL FITNESS: ", DoubleToString(fitness, 2));
      Print("=====================================");
   }
   
   return fitness;
}

//+------------------------------------------------------------------+
//+------------------------------------------------------------------+