//+------------------------------------------------------------------+
//|       NY Cash Session ORB EA (1-minute + trend detection)        |
//|     Handles PU Prime server UTC+2/UTC+3 and NY EST/EDT shift      |
//|               Copyright 2025 - free to use / modify               |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025"
#property version "2.00"
#property strict

//---------------  USER-TWEAKABLE INPUTS  ---------------------------//
// 1) Session times
enum SessionType
{
   CLASSIC_NYSE = 0, // Classic NYSE (09:30 - 10:00 NY)
   EARLY_US = 1      // Early US (08:00 - 08:30 NY)
};
input SessionType SESSION_TYPE = CLASSIC_NYSE; // Session window to use
input int SESSION_OR_MINUTES = 30;             // Opening-range length (minutes)
input int NY_SESSION_CLOSE_HOUR = 16;          // NY Close hour (default 16:00 NY)

// 2) Breakout / risk
input double RANGE_BUFFER_MULT = 0.2; // Buffer as range fraction (replaces ATR buffer)
input int TREND_CANDLES = 15;         // Number of candles for trend detection
input double TREND_THRESHOLD = 0.6;   // Trend confirmation threshold (0.6 = 60% of candles must be in trend direction)

// Stop loss placement strategy
enum SLPlacement
{
   SL_OUTER = 0,  // Opposite boundary (safest, largest SL)
   SL_MIDDLE = 1, // Middle of the range (moderate)
   SL_CLOSE = 2   // Close to breakout point (tight, aggressive)
};
input SLPlacement STOP_LOSS_STRATEGY = SL_OUTER; // Stop loss placement strategy

// 3) Money-management
input double RISK_PER_TRADE_PCT = 1.0; // % equity risk
input int MAX_TRADES_PER_DAY = 2;      // Max trades per day

// Add back the global variables for broker lot constraints
// Broker lot size constraints
double lot_min = 0;  // Will be set from broker
double lot_step = 0; // Will be set from broker

// 4) Volatility filter
input bool USE_VOLATILITY_FILTER = true; // Enable volatility filter
input double ATR_THRESHOLD_PCT = 80.0;   // ATR Threshold Percentage - Keep 80% for balanced trading; lower to 70% for more signals; raise to 90% for stronger breakouts only
input int ATR_PERIOD = 14;               // ATR Period - Keep 14 for standard volatility; lower to 7 for faster response; raise to 21 for smoother readings
input int ATR_MEDIAN_DAYS = 120;         // ATR Median Days - Keep 120 days (6 months) for stable markets; lower to 60-90 days for adapting to changing regimes

// 5) Range Multiple Target
// This multiplies the opening range size (high-low) to determine TP distance from entry:
// For buy orders: TP = entry + (range_size × RANGE_MULT)
// For sell orders: TP = entry - (range_size × RANGE_MULT)
//
input double RANGE_MULT = 1.0;                     // Keep 1.0 for balanced risk:reward; lower to 0.5-0.8 for faster but smaller profits; raise to 1.5-2.0 for larger but slower profits
input double MIN_BREAKOUT_ANGLE = 75.0;            // Minimum angle from breakout point to current price (degrees, 0=disabled)
input bool ALLOW_TP_AFTER_HOURS = false;           // Allow positions to reach TP after session close (will close before next session)
input int CLOSE_MINUTES_BEFORE_NEXT_SESSION = 120; // Minutes before next session to close after-hours positions (only applies if ALLOW_TP_AFTER_HOURS is true)

// 6) Visuals
input color BOX_COLOR = 0x0000FF; // Box color (Blue)
input uchar BOX_OPACITY = 20;     // Box opacity (0-255)
input bool LABEL_STATS = true;    // Show info label
input int DEBUG_LEVEL = 0;        // Debug level: 0=none, 1=basic, 2=detailed

//---------------  INTERNAL STATE  ---------------------------//
enum TradeState
{
   STATE_IDLE,
   STATE_BUILDING_RANGE,
   STATE_RANGE_LOCKED,
   STATE_IN_POSITION,
   STATE_AFTER_HOURS_POSITION // Special state for positions held after session hours
};
TradeState trade_state = STATE_IDLE;

//---------------  TIME VARIABLES  ---------------------------//
// Fixed time offset between server and NY (always 7 hours)
const int NY_TIME_OFFSET = 7; // Server is 7 hours ahead of NY

// Constants for range initialization
const double RANGE_HIGH_INIT = -1000000; // Initial high value (will be replaced with actual prices)
const double RANGE_LOW_INIT = 1000000;   // Initial low value (will be replaced with actual prices)

// Session timing variables
datetime current_session_start; // Start of current trading session (server time)
datetime current_session_end;   // End of current trading session (server time)
datetime current_range_end;     // End of opening range period (server time)
datetime next_session_start;    // Start of next trading session (server time)
double range_high = RANGE_HIGH_INIT;
double range_low = RANGE_LOW_INIT;
double range_size = 0;
double atr_value = 0;       // Current ATR value
double atr_median = 0;      // 6-month ATR median
bool volatility_ok = false; // Volatility filter passed
bool box_drawn = false;
string box_name = "ORB_BOX", hl_name = "ORB_HI", ll_name = "ORB_LO";

// Position tracking
ulong ticket = 0;
int trades_today = 0;
datetime active_trading_session = 0; // Timestamp of the trading session we're currently operating in

// Breakout confirmation tracking
// REMOVED: breakout counters - using simple buffer crossing instead

// Angle-based breakout tracking
double breakout_start_price = 0;  // Price when breakout started
datetime breakout_start_time = 0; // Time when breakout started

// ATR history for median calculation
double atr_history[];

// ATR handle for efficient indicator access
int atr_handle = INVALID_HANDLE;

// Current live price for trend detection (set in CheckBreakout)
double price = 0;

// Time variables are now defined in the TIME VARIABLES section

//+------------------------------------------------------------------+
//| Time utility functions                                           |
//+------------------------------------------------------------------+
datetime DateOfDay(datetime t)
{
   MqlDateTime dt;
   TimeToStruct(t, dt);
   dt.hour = 0;
   dt.min = 0;
   dt.sec = 0;
   return StructToTime(dt);
}

bool IsNYDST(datetime ts)
{
   MqlDateTime dt;
   TimeToStruct(ts, dt);
   int year = dt.year;

   // DST start = 2nd Sunday in March at 2 AM
   datetime march1 = StringToTime(StringFormat("%d.03.01 02:00", year));

   // Get day of week (0-Sunday, 1-Monday, etc.)
   MqlDateTime march_dt;
   TimeToStruct(march1, march_dt);
   int w_m1 = march_dt.day_of_week;

   datetime dstStart = march1 + ((7 - w_m1) % 7 + 7) * 86400;

   // DST end = 1st Sunday in November at 2 AM
   datetime nov1 = StringToTime(StringFormat("%d.11.01 02:00", year));

   // Get day of week
   MqlDateTime nov_dt;
   TimeToStruct(nov1, nov_dt);
   int w_n1 = nov_dt.day_of_week;

   datetime dstEnd = nov1 + ((7 - w_n1) % 7) * 86400;

   return (ts >= dstStart && ts < dstEnd);
}

//+------------------------------------------------------------------+
//| Check if within session hours                                    |
//+------------------------------------------------------------------+
bool IsWithinSessionHours(datetime time_to_check)
{
   return (time_to_check >= current_session_start && time_to_check <= current_session_end);
}

//+------------------------------------------------------------------+
//| Check if within range formation period                           |
//+------------------------------------------------------------------+
bool IsWithinRangeFormationPeriod(datetime time_to_check)
{
   return (time_to_check >= current_session_start && time_to_check < current_range_end);
}

//+------------------------------------------------------------------+
//| Build today's NY session window (server time)                    |
//+------------------------------------------------------------------+
void ComputeSession()
{
   datetime current_time = TimeCurrent();

   // Define NY session hours based on session type
   int ny_start_hour = (SESSION_TYPE == CLASSIC_NYSE) ? 9 : 8;
   int ny_start_minute = (SESSION_TYPE == CLASSIC_NYSE) ? 30 : 0;

   // Convert NY time to server time
   int server_ny_start_hour = ny_start_hour + NY_TIME_OFFSET;
   int server_ny_start_minute = ny_start_minute;
   int server_ny_close_hour = NY_SESSION_CLOSE_HOUR + NY_TIME_OFFSET;

   // Calculate the most recent session start (could be today or yesterday in server time)
   // We need to find the session that either:
   // 1. Started today and hasn't ended yet, OR
   // 2. Started yesterday and we're in the after-hours period

   MqlDateTime dt;
   TimeToStruct(current_time, dt);
   dt.hour = 0;
   dt.min = 0;
   dt.sec = 0;
   datetime today_midnight = StructToTime(dt);
   datetime yesterday_midnight = today_midnight - 86400;
   datetime tomorrow_midnight = today_midnight + 86400;

   // Calculate session times for yesterday, today, and tomorrow (server time)
   datetime yesterday_session_start = yesterday_midnight + server_ny_start_hour * 3600 + server_ny_start_minute * 60;
   datetime yesterday_session_end = yesterday_midnight + server_ny_close_hour * 3600;

   datetime today_session_start = today_midnight + server_ny_start_hour * 3600 + server_ny_start_minute * 60;
   datetime today_session_end = today_midnight + server_ny_close_hour * 3600;

   datetime tomorrow_session_start = tomorrow_midnight + server_ny_start_hour * 3600 + server_ny_start_minute * 60;

   // Determine which session we're currently in or closest to
   if (current_time >= today_session_start)
   {
      // We're at or after today's session start
      current_session_start = today_session_start;
      current_session_end = today_session_end;
      current_range_end = current_session_start + SESSION_OR_MINUTES * 60;
      next_session_start = tomorrow_session_start;
   }
   else if (current_time >= yesterday_session_end)
   {
      // We're between yesterday's session end and today's session start
      // This is the "after hours" period for yesterday's session
      current_session_start = yesterday_session_start;
      current_session_end = yesterday_session_end;
      current_range_end = current_session_start + SESSION_OR_MINUTES * 60;
      next_session_start = today_session_start;
   }
   else
   {
      // We're before yesterday's session end (shouldn't happen in normal trading)
      // Default to today's session
      current_session_start = today_session_start;
      current_session_end = today_session_end;
      current_range_end = current_session_start + SESSION_OR_MINUTES * 60;
      next_session_start = tomorrow_session_start;
   }

   // Skip weekends for next_session_start (holidays are handled elsewhere)
   MqlDateTime next_dt;
   TimeToStruct(next_session_start, next_dt);
   int safety_counter = 0;

   while ((next_dt.day_of_week == 0 || next_dt.day_of_week == 6) && safety_counter < 10)
   {
      next_session_start += 86400; // Add one day
      TimeToStruct(next_session_start, next_dt);
      safety_counter++;

      // Recalculate the session start time for the new day
      datetime new_day_midnight = DateOfDay(next_session_start);
      next_session_start = new_day_midnight + server_ny_start_hour * 3600 + server_ny_start_minute * 60;
      TimeToStruct(next_session_start, next_dt);
   }

   // Extremely limited logging
   static datetime last_session_log = 0;
   static int session_log_count = 0;
   if (DEBUG_LEVEL >= 2 && current_time - last_session_log > 3600)
   {
      if (session_log_count < 2)
      {
         if (DEBUG_LEVEL >= 2)
            Print("Session computed: Current=", TimeToString(current_session_start),
                  " to ", TimeToString(current_session_end),
                  ", Next=", TimeToString(next_session_start));
         session_log_count++;
      }
      last_session_log = current_time;
   }
}

//+------------------------------------------------------------------+
//| Expert init                                                      |
//+------------------------------------------------------------------+
int OnInit()
{
   // Get broker's lot size constraints
   lot_min = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   lot_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if (DEBUG_LEVEL >= 1)
   {
      Print("Broker lot size constraints for ", _Symbol, ":");
      Print("  Minimum lot size: ", DoubleToString(lot_min, 2));
      Print("  Lot step size: ", DoubleToString(lot_step, 2));
   }

   // STARTUP SAFETY: Close any positions that might have carried over
   if (ticket != 0)
   {
      if (PositionSelectByTicket(ticket))
      {
         if (DEBUG_LEVEL >= 1)
            Print("WARNING: Detected lingering position at startup. Closing position #", ticket);
         bool closed = ClosePos();

         if (!closed && ticket != 0)
         {
            if (DEBUG_LEVEL >= 1)
               Print("WARNING: Unable to close lingering position. Will try again later.");
         }
      }
      else
      {
         // Position doesn't exist but ticket is non-zero
         if (DEBUG_LEVEL >= 1)
            Print("WARNING: Invalid ticket found at startup. Resetting ticket value.");
         ticket = 0;
      }
   }

   // Verify timeframe
   if (_Period != PERIOD_M1)
   {
      if (DEBUG_LEVEL >= 1)
         Print("Attach to a 1-minute chart for optimal performance.");
      // We'll continue but warn the user
   }

   // Calculate session times first, then reset for new trading session
   ComputeSession();
   ResetSession(); // This will set active_trading_session to current_session_start

   // Display strategy information
   string session_type_str = (SESSION_TYPE == CLASSIC_NYSE) ? "NYSE Open (9:30 NY)" : "Early US (8:00 NY)";
   if (DEBUG_LEVEL >= 1)
   {
      Print("=== NY ORB Strategy Initialized ===");
      Print("Session: ", session_type_str);
      Print("Opening Range: ", SESSION_OR_MINUTES, " minutes");
      Print("Max Trades: ", MAX_TRADES_PER_DAY, " per day");
      Print("Buffer: Range × ", DoubleToString(RANGE_BUFFER_MULT, 1));
      Print("Trend Detection: ", TREND_CANDLES, " candles (live price + historical), ", DoubleToString(TREND_THRESHOLD * 100, 1), "% threshold");
      Print("Trend Requirement: Current price MUST be beyond previous close");
      if (MIN_BREAKOUT_ANGLE > 0)
         Print("Minimum Breakout Angle: ", DoubleToString(MIN_BREAKOUT_ANGLE, 1), "°");
      else
         Print("Minimum Breakout Angle: DISABLED (set to 0)");
      Print("Take Profit Type: Range Multiple");
   }

   // Show stop loss strategy
   string sl_strategy = "";
   switch (STOP_LOSS_STRATEGY)
   {
   case SL_OUTER:
      sl_strategy = "Outer (Conservative)";
      break;
   case SL_MIDDLE:
      sl_strategy = "Middle (Moderate)";
      break;
   case SL_CLOSE:
      sl_strategy = "Close (Aggressive)";
      break;
   default:
      sl_strategy = "Unknown";
   }
   if (DEBUG_LEVEL >= 1)
   {
      Print("Stop Loss Strategy: ", sl_strategy);

      Print("Volatility Filter: ", USE_VOLATILITY_FILTER ? "Enabled" : "Disabled");
      Print("=================================");
   }

   // Calculate ATR
   // Initialize ATR handle for efficient indicator access
   atr_handle = iATR(_Symbol, _Period, ATR_PERIOD);
   if (atr_handle == INVALID_HANDLE)
   {
      if (DEBUG_LEVEL >= 1)
         Print("Failed to create ATR indicator handle. Error: ", GetLastError());
      return (INIT_FAILED);
   }

   UpdateATR();

   // Add volume indicator to chart
   int volume_indicator = iVolumes(_Symbol, PERIOD_CURRENT, VOLUME_TICK);
   if (volume_indicator != INVALID_HANDLE)
   {
      // Add to separate window below main chart
      if (!ChartIndicatorAdd(0, 1, volume_indicator))
      {
         if (DEBUG_LEVEL >= 1)
            Print("Failed to add volume indicator to chart. Error: ", GetLastError());
      }
      else
      {
         if (DEBUG_LEVEL >= 2)
            Print("Volume indicator added to chart successfully");
      }
   }

   // Verify test data is available during session hours
   ValidateTestData();

   return (INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Validate that test data exists for the session period            |
//+------------------------------------------------------------------+
void ValidateTestData()
{
   // Use current time and our already calculated session times
   datetime current_time = TimeCurrent();

   // Ensure session times are calculated
   ComputeSession();

   // Check if we're before the current session start
   if (current_time < current_session_start)
   {
      if (DEBUG_LEVEL >= 2)
         Print("Validation: Current time is before today's session start. Will check this session.");
   }

   // Try to read some bars around the session start
   if (DEBUG_LEVEL >= 2)
      Print("VALIDATING DATA around session start: ", TimeToString(current_session_start));

   // Check bars before, at, and after session start
   for (int offset = -2; offset <= 2; offset++)
   {
      datetime check_time = current_session_start + offset * 60; // 1-minute bars
      int bar_index = iBarShift(_Symbol, PERIOD_M1, check_time, false);

      if (bar_index >= 0)
      {
         double close = iClose(_Symbol, PERIOD_M1, bar_index);
         double open = iOpen(_Symbol, PERIOD_M1, bar_index);
         double high = iHigh(_Symbol, PERIOD_M1, bar_index);
         double low = iLow(_Symbol, PERIOD_M1, bar_index);

         if (DEBUG_LEVEL >= 3)
            Print("Bar found at ", TimeToString(check_time),
                  " (index ", bar_index,
                  "): Open=", DoubleToString(open, _Digits),
                  ", High=", DoubleToString(high, _Digits),
                  ", Low=", DoubleToString(low, _Digits),
                  ", Close=", DoubleToString(close, _Digits));
      }
      else
      {
         if (DEBUG_LEVEL >= 1)
            Print("WARNING: No bar found at ", TimeToString(check_time),
                  ". This might indicate missing data during the session window!");
      }
   }

   // Specifically check the first 1-minute bar of the session
   datetime first_bar_time = current_session_start;
   int first_bar_index = iBarShift(_Symbol, PERIOD_M1, first_bar_time, false);

   if (first_bar_index >= 0)
   {
      if (DEBUG_LEVEL >= 2)
         Print("First session bar found at ", TimeToString(first_bar_time));
   }
   else
   {
      if (DEBUG_LEVEL >= 1)
         Print("WARNING: First bar of session at ", TimeToString(first_bar_time),
               " not found! Session detection may not work properly.");
   }
}

//+------------------------------------------------------------------+
//| Expert deinit                                                    |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   // Clean up all chart objects
   ObjectsDeleteAll(0, box_name);
   ObjectsDeleteAll(0, hl_name);
   ObjectsDeleteAll(0, ll_name);

   // Release ATR indicator handle
   if (atr_handle != INVALID_HANDLE)
   {
      IndicatorRelease(atr_handle);
      atr_handle = INVALID_HANDLE;
   }

   Comment("");
}

//+------------------------------------------------------------------+
//| Each tick                                                        |
//+------------------------------------------------------------------+
void OnTick()
{
   // 1. INITIALIZATION AND TIME CHECKS
   // Get current time - use once for efficiency
   datetime current_time = TimeCurrent();

   // Note: We now use tick-based breakout detection for faster response

   // Recalculate session times - critical for accurate after-hours position management
   // Must run on every tick for reliability
   ComputeSession();

   // 2. SESSION MANAGEMENT
   // Detect new trading sessions
   if (active_trading_session != current_session_start)
   {
      if (DEBUG_LEVEL >= 1)
         Print("NEW SESSION DETECTED at ", TimeToString(current_time),
               " | Previous: ", TimeToString(active_trading_session),
               " | Current: ", TimeToString(current_session_start));

      // Special handling for after-hours positions
      if (trade_state == STATE_AFTER_HOURS_POSITION && ticket != 0)
      {
         if (DEBUG_LEVEL >= 1)
            Print("After-hours position detected during session transition - preserving position");

         // Only update the active session marker without full reset
         active_trading_session = current_session_start;
      }
      else
      {
         // Normal reset for all other states
         ResetSession();
      }
   }

   // Skip trading on NYSE holidays
   if (IsNYSEHoliday(current_time))
   {
      // Handle open positions with throttling to avoid log spam during market closed
      static datetime last_holiday_check = 0;

      if (ticket != 0)
      {
         // Only try to close position once every 5 minutes to avoid log spam
         if (current_time - last_holiday_check > 300)
         {
            last_holiday_check = current_time;
            if (DEBUG_LEVEL >= 1)
               Print("NYSE holiday detected - closing open position #", ticket);

            // Try to close, but handle errors gracefully
            bool closed = ClosePos();

            // If closing failed, log it but wait for next attempt
            if (!closed && ticket != 0)
            {
               if (DEBUG_LEVEL >= 1)
                  Print("Unable to close position during holiday - will retry later");
            }
         }
      }
      else
      {
         // Then transition to idle state if needed
         if (trade_state != STATE_IDLE)
         {
            if (DEBUG_LEVEL >= 1)
               Print("NYSE holiday detected - skipping trading today");
            trade_state = STATE_IDLE;
            if (LABEL_STATS)
               ShowLabel(); // Update display immediately
         }
      }
      return;
   }

   // 3. MARKET ANALYSIS
   // Update ATR for breakout levels and position sizing
   UpdateATR();

   // Debug ATR values periodically
   static datetime last_atr_log = 0;
   if (DEBUG_LEVEL >= 2 && current_time - last_atr_log > 1800) // Log every 30 minutes
   {
      last_atr_log = current_time;
      Print("ATR STATUS: Current=", DoubleToString(atr_value, _Digits),
            ", Median=", DoubleToString(atr_median, _Digits),
            ", Filter=", (USE_VOLATILITY_FILTER ? "ON" : "OFF"),
            ", Passed=", (volatility_ok ? "YES" : "NO"));
   }

   // 4. STATE TRANSITIONS
   // Handle critical state transitions based on time
   // (especially after-hours position management)
   UpdateSessionState(current_time);

   // 5. STATE-SPECIFIC ACTIONS
   // Process current trading state
   switch (trade_state)
   {
   case STATE_BUILDING_RANGE:
      UpdateRange(); // Track high/low during opening range
      break;

   case STATE_RANGE_LOCKED:
      CheckBreakout(); // Check on every tick for faster detection
      break;

   case STATE_IN_POSITION:
      ManagePos(); // Handles transition to AFTER_HOURS_POSITION
      break;

   case STATE_AFTER_HOURS_POSITION:
      ManageAfterHoursPos(); // Monitor after-hours positions
      break;
   }

   // Now check if we're outside trading window - this is a failsafe only
   // ManagePos() should have already handled the transition to AFTER_HOURS_POSITION
   bool outside_session = !IsWithinSessionHours(current_time);

   // Handle different states depending on session hours - acts as a failsafe only
   if (outside_session)
   {
      // If we have a position and after-hours TP is enabled, transition to after-hours state
      if (trade_state == STATE_IN_POSITION && ALLOW_TP_AFTER_HOURS && ticket != 0)
      {
         if (DEBUG_LEVEL >= 1)
            Print("FAILSAFE: Transitioning to AFTER_HOURS_POSITION state at ", TimeToString(current_time));
         trade_state = STATE_AFTER_HOURS_POSITION;
         if (LABEL_STATS)
            ShowLabel(); // Update display immediately
      }
      // Otherwise go idle if we're not already in after-hours position state or idle
      else if (trade_state != STATE_AFTER_HOURS_POSITION && trade_state != STATE_IDLE)
      {
         // Use static variable for logging to prevent compilation errors
         static datetime last_log_time = 0;

         // Only log once per hour to avoid spamming
         if (current_time - last_log_time > 3600)
         {
            if (DEBUG_LEVEL >= 1)
               Print("Outside session - going IDLE. Time: ", TimeToString(current_time),
                     ", Session: ", TimeToString(current_session_start),
                     " - ", TimeToString(current_session_end));
            last_log_time = current_time;
         }

         trade_state = STATE_IDLE;
         if (LABEL_STATS)
            ShowLabel(); // Update display immediately
      }
   }

   if (LABEL_STATS)
      ShowLabel();
}

//+------------------------------------------------------------------+
//| Check and handle state transitions                               |
//+------------------------------------------------------------------+
void UpdateSessionState(datetime current_time)
{
   // First priority: Close any after-hours positions if approaching next session
   if (trade_state == STATE_AFTER_HOURS_POSITION && ticket != 0)
   {
      // Periodic safety check - reduced frequency to avoid log spam
      static datetime last_safety_check = 0;
      if (current_time - last_safety_check > 900) // Check every 15 minutes
      {
         last_safety_check = current_time;
         if (DEBUG_LEVEL >= 2)
            Print("PERIODIC SAFETY CHECK: Verifying after-hours position status at ", TimeToString(current_time));
      }

      // Close position if:
      // 1. We're approaching next session start (within configurable minutes), OR
      // 2. We're already within a new session's range formation period
      bool should_close = false;

      if (current_time >= next_session_start - CLOSE_MINUTES_BEFORE_NEXT_SESSION * 60)
      {
         should_close = true;
         if (DEBUG_LEVEL >= 1)
            Print("FAILSAFE: Closing after-hours position as we're approaching next session (",
                  TimeToString(next_session_start), ")");
      }
      else if (IsWithinRangeFormationPeriod(current_time))
      {
         should_close = true;
         if (DEBUG_LEVEL >= 1)
            Print("FAILSAFE: Closing after-hours position as new session has started");
      }

      // Force close position if needed
      if (should_close)
      {
         if (DEBUG_LEVEL >= 1)
            Print("Closing after-hours position before new session at ", TimeToString(current_time));
         bool closed = ClosePos();

         // Only proceed with state changes if position was successfully closed
         if (!closed && ticket != 0)
         {
            if (DEBUG_LEVEL >= 1)
               Print("WARNING: Failed to close position before new session. Will retry.");
            return;
         }
      }
   }

   // Check if within opening range formation time
   if (IsWithinRangeFormationPeriod(current_time))
   {
      // Only transition to BUILDING_RANGE if we're IDLE
      // Note: STATE_AFTER_HOURS_POSITION with ticket==0 should never happen
      // as we should immediately transition to IDLE when closing a position
      if (trade_state == STATE_IDLE)
      {
         trade_state = STATE_BUILDING_RANGE;
         if (DEBUG_LEVEL >= 1)
            Print("BUILDING RANGE STARTED at ", TimeToString(current_time),
                  ", Window: ", TimeToString(current_session_start), " to ",
                  TimeToString(current_range_end));
         if (LABEL_STATS)
            ShowLabel(); // Update display immediately

         // Initialize range values
         InitializeRangeValues();

         // Process the first bar immediately
         UpdateRange();
      }
   }
   // Check if range formation period has ended
   else if (current_time >= current_range_end && trade_state == STATE_BUILDING_RANGE)
   {
      trade_state = STATE_RANGE_LOCKED;

      // Calculate range size for TP calculations
      range_size = range_high - range_low;

      // Check volatility filter
      CheckVolatilityFilter();

      if (LABEL_STATS)
         ShowLabel(); // Update display immediately

      // Draw range visualization
      DrawBox();

      PrintFormat("Range locked at %s. High=%s, Low=%s, Width=%s points",
                  TimeToString(current_time),
                  DoubleToString(range_high, _Digits),
                  DoubleToString(range_low, _Digits),
                  DoubleToString(range_size / _Point, 0));

      // Check for breakout immediately after range is locked
      CheckBreakout();
   }
}

//+------------------------------------------------------------------+
//| Initialize range values for a new session                        |
//+------------------------------------------------------------------+
void InitializeRangeValues()
{
   // Reset range boundaries to their initial values
   range_high = RANGE_HIGH_INIT;
   range_low = RANGE_LOW_INIT;

   // Reset range size
   range_size = 0;

   // Reset breakout tracking (counters removed - using simple buffer crossing)
   ResetBreakoutTracking();

   // Reset box drawing flag
   box_drawn = false;

   if (DEBUG_LEVEL >= 2)
      Print("Range values initialized for new session");
}

//+------------------------------------------------------------------+
//| Check if current volatility passes filter                        |
//+------------------------------------------------------------------+
void CheckVolatilityFilter()
{
   volatility_ok = true;
   if (USE_VOLATILITY_FILTER)
   {
      volatility_ok = (atr_value >= atr_median * ATR_THRESHOLD_PCT / 100.0);

      if (!volatility_ok)
      {
         if (DEBUG_LEVEL >= 1)
            Print("⚠️ VOLATILITY FILTER: ATR(", ATR_PERIOD, ")=", DoubleToString(atr_value, _Digits),
                  " is below threshold (", DoubleToString(atr_median * ATR_THRESHOLD_PCT / 100.0, _Digits),
                  "). No trades will be taken.");
      }
      else
      {
         if (DEBUG_LEVEL >= 2)
            Print("✅ VOLATILITY FILTER: ATR(", ATR_PERIOD, ")=", DoubleToString(atr_value, _Digits),
                  " passed threshold (", DoubleToString(atr_median * ATR_THRESHOLD_PCT / 100.0, _Digits),
                  ")");
      }
   }
}

//+------------------------------------------------------------------+
//| Helper to convert trade state to string                          |
//+------------------------------------------------------------------+
string GetStateString(TradeState state)
{
   switch (state)
   {
   case STATE_IDLE:
      return "IDLE";
   case STATE_BUILDING_RANGE:
      return "BUILDING_RANGE";
   case STATE_RANGE_LOCKED:
      return "RANGE_LOCKED";
   case STATE_IN_POSITION:
      return "IN_POSITION";
   case STATE_AFTER_HOURS_POSITION:
      return "AFTER_HOURS_POSITION";
   default:
      return "UNKNOWN";
   }
}

//+------------------------------------------------------------------+
//| Reset counters for a new trading session                          |
//+------------------------------------------------------------------+
void ResetSession()
{
   // Set active_trading_session to the current session start
   active_trading_session = current_session_start;

   trades_today = 0;
   ticket = 0;
   trade_state = STATE_IDLE;
   if (LABEL_STATS)
      ShowLabel(); // Update display immediately

   // Initialize range values to ensure they will be updated properly
   range_high = RANGE_HIGH_INIT;
   range_low = RANGE_LOW_INIT;

   // Reset breakout tracking (counters removed - using simple buffer crossing)

   box_drawn = false;
   ObjectsDeleteAll(0, box_name);
   ObjectsDeleteAll(0, hl_name);
   ObjectsDeleteAll(0, ll_name);

   if (DEBUG_LEVEL >= 1)
      Print("New session reset: ", TimeToString(current_session_start));
}

//+------------------------------------------------------------------+
//| Track highs/lows during OR                                       |
//+------------------------------------------------------------------+
void UpdateRange()
{
   double high[], low[];

   // Get the high/low of the most recent completed M1 bar
   if (CopyHigh(_Symbol, PERIOD_M1, 1, 1, high) > 0 && CopyLow(_Symbol, PERIOD_M1, 1, 1, low) > 0)
   {
      double h = high[0];
      double l = low[0];

      // Update range values if needed
      if (h > range_high)
      {
         range_high = h;
         if (DEBUG_LEVEL >= 2)
            Print("New range high: ", DoubleToString(range_high, _Digits), " at ", TimeToString(TimeCurrent()));
      }

      if (l < range_low)
      {
         range_low = l;
         if (DEBUG_LEVEL >= 2)
            Print("New range low: ", DoubleToString(range_low, _Digits), " at ", TimeToString(TimeCurrent()));
      }
   }
}

//+------------------------------------------------------------------+
//| Calculate Range-based buffer points                              |
//+------------------------------------------------------------------+
double CalculateRangeBuffer()
{
   return range_size * RANGE_BUFFER_MULT;
}

//+------------------------------------------------------------------+
//| Draw OR rectangle and reference lines                            |
//+------------------------------------------------------------------+
void DrawBox()
{
   if (box_drawn)
      return;

   long chart_id = 0;
   datetime t0 = current_session_start;
   datetime t1 = current_range_end;

   // Draw the rectangle for the opening range
   ObjectCreate(chart_id, box_name, OBJ_RECTANGLE, 0, t0, range_high, t1, range_low);

   // Set box color with opacity
   color box_color_with_opacity = BOX_COLOR;
   if (BOX_OPACITY < 255)
   {
      // Simple way to apply opacity
      box_color_with_opacity = (color)((BOX_COLOR & 0xFFFFFF) | (BOX_OPACITY << 24));
   }

   ObjectSetInteger(chart_id, box_name, OBJPROP_COLOR, box_color_with_opacity);
   ObjectSetInteger(chart_id, box_name, OBJPROP_FILL, true);

   // Draw horizontal lines for range high and low
   ObjectCreate(chart_id, hl_name, OBJ_HLINE, 0, TimeCurrent(), range_high);
   ObjectSetInteger(chart_id, hl_name, OBJPROP_COLOR, 0x00FF00); // Green
   ObjectSetInteger(chart_id, hl_name, OBJPROP_WIDTH, 2);
   ObjectSetString(chart_id, hl_name, OBJPROP_TEXT, "OR High: " + DoubleToString(range_high, _Digits));

   ObjectCreate(chart_id, ll_name, OBJ_HLINE, 0, TimeCurrent(), range_low);
   ObjectSetInteger(chart_id, ll_name, OBJPROP_COLOR, 0xFF0000); // Red
   ObjectSetInteger(chart_id, ll_name, OBJPROP_WIDTH, 2);
   ObjectSetString(chart_id, ll_name, OBJPROP_TEXT, "OR Low: " + DoubleToString(range_low, _Digits));

   // Add buffer zones to the chart to show entry thresholds
   string up_buffer_name = "ORB_UP_BUFFER";
   string dn_buffer_name = "ORB_DN_BUFFER";

   // Calculate buffer using Range multiplier
   double buffer_points = CalculateRangeBuffer();

   ObjectCreate(chart_id, up_buffer_name, OBJ_HLINE, 0, TimeCurrent(), range_high + buffer_points);
   ObjectSetInteger(chart_id, up_buffer_name, OBJPROP_COLOR, 0x00AAFF); // Light Blue
   ObjectSetInteger(chart_id, up_buffer_name, OBJPROP_STYLE, STYLE_DASH);
   ObjectSetString(chart_id, up_buffer_name, OBJPROP_TEXT, "Buy Entry: " + DoubleToString(range_high + buffer_points, _Digits));

   ObjectCreate(chart_id, dn_buffer_name, OBJ_HLINE, 0, TimeCurrent(), range_low - buffer_points);
   ObjectSetInteger(chart_id, dn_buffer_name, OBJPROP_COLOR, 0xFFAA00); // Light Red
   ObjectSetInteger(chart_id, dn_buffer_name, OBJPROP_STYLE, STYLE_DASH);
   ObjectSetString(chart_id, dn_buffer_name, OBJPROP_TEXT, "Sell Entry: " + DoubleToString(range_low - buffer_points, _Digits));

   // Add vertical lines to mark OR start/end
   string start_vline = "ORB_START";
   string end_vline = "ORB_END";

   ObjectCreate(chart_id, start_vline, OBJ_VLINE, 0, current_session_start, 0);
   ObjectSetInteger(chart_id, start_vline, OBJPROP_COLOR, 0x0000FF); // Blue
   ObjectSetInteger(chart_id, start_vline, OBJPROP_STYLE, STYLE_DOT);
   ObjectSetString(chart_id, start_vline, OBJPROP_TEXT, "ORB Start");

   ObjectCreate(chart_id, end_vline, OBJ_VLINE, 0, current_range_end, 0);
   ObjectSetInteger(chart_id, end_vline, OBJPROP_COLOR, 0x0000FF); // Blue
   ObjectSetInteger(chart_id, end_vline, OBJPROP_STYLE, STYLE_DOT);
   ObjectSetString(chart_id, end_vline, OBJPROP_TEXT, "ORB End");

   box_drawn = true;
}

//+------------------------------------------------------------------+
//| Calculate bullish breakout level                                  |
//+------------------------------------------------------------------+
double CalculateBullBreakoutLevel()
{
   return range_high + CalculateRangeBuffer();
}

//+------------------------------------------------------------------+
//| Calculate bearish breakout level                                 |
//+------------------------------------------------------------------+
double CalculateBearBreakoutLevel()
{
   return range_low - CalculateRangeBuffer();
}

//+------------------------------------------------------------------+
//| Check for breakout & send order                                  |
//+------------------------------------------------------------------+
void CheckBreakout()
{
   // Only allow specified number of trades per day
   if (trades_today >= MAX_TRADES_PER_DAY)
   {
      if (DEBUG_LEVEL >= 1)
         Print("Max trades per day reached: ", trades_today);
      return;
   }

   if (ticket != 0)
      return; // already in a position

   // Skip if volatility filter is enabled and not passed
   if (USE_VOLATILITY_FILTER && !volatility_ok)
   {
      if (DEBUG_LEVEL >= 1)
      {
         Print("Skipping breakout check - volatility filter not passed");
      }
      return;
   }

   // Get current live price (for trend detection) and completed bar close (for breakout detection)
   price = (SymbolInfoDouble(_Symbol, SYMBOL_BID) + SymbolInfoDouble(_Symbol, SYMBOL_ASK)) / 2.0; // Live mid price
   double close = GetPreviousClose(); // Most recent completed bar close

   // Calculate breakout levels using utility functions
   double bull_breakout_level = CalculateBullBreakoutLevel();
   double bear_breakout_level = CalculateBearBreakoutLevel();
   double buffer_points = CalculateRangeBuffer();

   LogBreakoutLevels(close, buffer_points, bull_breakout_level, bear_breakout_level);

   // Check for bullish breakout
   if (price >= bull_breakout_level && price >= close)
   {
      if (ValidateBreakout(true)) // true = bullish
      {
         ProcessBreakout(true, close, buffer_points);
      }
   }
   // Check for bearish breakout
   else if (price <= bear_breakout_level && price <= close)
   {
      if (ValidateBreakout(false)) // false = bearish
      {
         ProcessBreakout(false, close, buffer_points);
      }
   }
}

//+------------------------------------------------------------------+
//| Validate breakout conditions (unified for both directions)       |
//+------------------------------------------------------------------+
bool ValidateBreakout(bool is_bullish)
{
   // STEP 1: Critical trend requirement - current price must be beyond previous close
   double prev_close = GetPreviousClose();
   if (is_bullish && price <= prev_close)
   {
      if (DEBUG_LEVEL >= 3)
         Print("BULLISH BREAKOUT: Current price ", DoubleToString(price, _Digits),
               " <= previous close ", DoubleToString(prev_close, _Digits), " - trend requirement not met");
      return false;
   }
   else if (!is_bullish && price >= prev_close)
   {
      if (DEBUG_LEVEL >= 3)
         Print("BEARISH BREAKOUT: Current price ", DoubleToString(price, _Digits),
               " >= previous close ", DoubleToString(prev_close, _Digits), " - trend requirement not met");
      return false;
   }

   // STEP 2: Check trend alignment FIRST - don't waste time on non-trending breakouts
   bool trend_aligned = is_bullish ? IsTrendAlignmentBullish() : IsTrendAlignmentBearish();
   if (!trend_aligned)
   {
      string direction = is_bullish ? "BULLISH" : "BEARISH";
      if (DEBUG_LEVEL >= 2)
         Print(direction, " BREAKOUT DETECTED but trend alignment insufficient (",
               DoubleToString(TREND_THRESHOLD * 100, 1), "% threshold) - ignoring breakout");

      // Check if trend is strongly in opposite direction (reset counters)
      bool opposite_trend = is_bullish ? IsTrendAlignmentBearish() : IsTrendAlignmentBullish();
      if (opposite_trend)
      {
         if (DEBUG_LEVEL >= 2)
            Print("STRONG OPPOSITE TREND DETECTED - resetting ", direction, " counters");
         
         // Counter reset removed - using simple buffer crossing
         ResetBreakoutTracking();
      }
      return false;
   }

   // Trend is good - proceed with breakout processing
   if (DEBUG_LEVEL >= 2)
   {
      string direction = is_bullish ? "BULLISH" : "BEARISH";
      Print(direction, " BREAKOUT with valid trend alignment - processing");
   }
   
   return true;
}

//+------------------------------------------------------------------+
//| Process breakout (unified for both directions)                   |
//+------------------------------------------------------------------+
void ProcessBreakout(bool is_bullish, double close, double buffer_points)
{
   // Initialize breakout tracking on first detection
   if (breakout_start_time == 0)
   {
      if (is_bullish)
         breakout_start_price = range_high + buffer_points;
      else
         breakout_start_price = range_low - buffer_points;
      
      breakout_start_time = TimeCurrent();
   }


   // STEP 2: Angle validation (if enabled)
   if (MIN_BREAKOUT_ANGLE > 0)
   {
      double breakout_angle = CalculateBreakoutAngle(breakout_start_price, breakout_start_time, close);
      if (breakout_angle < MIN_BREAKOUT_ANGLE)
      {
         string direction = is_bullish ? "BULLISH" : "BEARISH";
         if (DEBUG_LEVEL >= 2)
            Print(direction, " BREAKOUT REJECTED: Angle ", DoubleToString(breakout_angle, 1),
                  "° < required ", DoubleToString(MIN_BREAKOUT_ANGLE, 1), "°");
         return;
      }
   }

   // All validations passed - execute trade
   ExecuteBreakoutTrade(is_bullish, close);
}

//+------------------------------------------------------------------+
//| Execute breakout trade (simplified - no confirmation counting)   |
//+------------------------------------------------------------------+
void ExecuteBreakoutTrade(bool is_bullish, double close)
{
   string direction = is_bullish ? "BULLISH" : "BEARISH";
   
   if (DEBUG_LEVEL >= 1)
   {
      string angle_info = "";
      if (MIN_BREAKOUT_ANGLE > 0)
      {
         double breakout_angle = CalculateBreakoutAngle(breakout_start_price, breakout_start_time, close);
         angle_info = " | Angle: " + DoubleToString(breakout_angle, 1) + "°";
      }
      else
      {
         angle_info = " | Angle: DISABLED";
      }

      Print("CONFIRMED ", direction, " BREAKOUT + TREND + BUFFER CROSSING - EXECUTING ", 
            (is_bullish ? "BUY" : "SELL"), angle_info);
   }

   // Execute the trade
   ENUM_ORDER_TYPE order_type = is_bullish ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   SendOrder(order_type);
   
   // Reset breakout tracking after trade
         ResetBreakoutTracking();
}

//+------------------------------------------------------------------+
//| Log breakout levels and current price                            |
//+------------------------------------------------------------------+
void LogBreakoutLevels(double close, double buffer_points, double bull_level, double bear_level)
{
   if (DEBUG_LEVEL >= 2)
   {
      Print("Using Range buffer: ", DoubleToString(buffer_points, _Digits),
            " (Range=", DoubleToString(range_size, _Digits),
            " x ", DoubleToString(RANGE_BUFFER_MULT, 2), ")");

      Print("BREAKOUT CHECK at ", TimeToString(TimeCurrent()));
      Print("  Bar close: ", DoubleToString(close, _Digits));
      Print("  Range high: ", DoubleToString(range_high, _Digits),
            ", with buffer: ", DoubleToString(bull_level, _Digits));
      Print("  Range low: ", DoubleToString(range_low, _Digits),
            ", with buffer: ", DoubleToString(bear_level, _Digits));
   }
}

//+------------------------------------------------------------------+
//| Calculate ATR and median ATR                                     |
//+------------------------------------------------------------------+
void UpdateATR()
{
   // Calculate current ATR value using the global handle
   double atr_buff[];

   if (CopyBuffer(atr_handle, 0, 0, 2, atr_buff) <= 0)
   {
      if (DEBUG_LEVEL >= 1)
         Print("ATR error: ", GetLastError());
      return;
   }

   // Get current ATR value (from previous completed bar)
   atr_value = atr_buff[1];

   // Calculate or recalculate median ATR if needed
   static datetime last_median_calculation = 0;
   const int MEDIAN_RECALC_HOURS = 168; // Recalculate weekly (7 days × 24 hours)
   
   bool should_calculate_median = false;
   
   if (USE_VOLATILITY_FILTER)
   {
      // Initial calculation if never done
      if (atr_median <= 0)
      {
         should_calculate_median = true;
         if (DEBUG_LEVEL >= 1)
            Print("Initial ATR median calculation triggered");
      }
      // Periodic recalculation (weekly)
      else if (TimeCurrent() - last_median_calculation > MEDIAN_RECALC_HOURS * 3600)
      {
         should_calculate_median = true;
         if (DEBUG_LEVEL >= 1)
            Print("Periodic ATR median recalculation triggered (", MEDIAN_RECALC_HOURS, " hours elapsed)");
      }
   }
   
   if (should_calculate_median)
   {
      // For median calculation we need a longer ATR history
      // NY trading session: 9:30 AM - 4:00 PM = 6.5 hours = 390 one-minute bars per day
      int bars_per_trading_day = 390;
      int bars_needed = ATR_MEDIAN_DAYS * bars_per_trading_day;

      // Make sure we don't request more bars than available
      int available_bars = Bars(_Symbol, _Period);
      if (bars_needed > available_bars)
         bars_needed = available_bars;

      // Only proceed if we have enough data
      if (bars_needed < 10)
      {
         if (DEBUG_LEVEL >= 1)
            Print("Insufficient data for ATR median calculation. Need at least 10 bars, have ", bars_needed);
         return;
      }

      // Get ATR values for the period
      ArrayResize(atr_history, bars_needed);

      if (CopyBuffer(atr_handle, 0, 0, bars_needed, atr_history) <= 0)
      {
         if (DEBUG_LEVEL >= 1)
            Print("Error getting ATR history: ", GetLastError());
         return;
      }

      // Sort the array to find median
      ArraySort(atr_history);

      // Median is the middle value (or average of the two middle values)
      int middle = bars_needed / 2;
      double new_median;
      if (bars_needed % 2 == 0) // Even number of elements
         new_median = (atr_history[middle - 1] + atr_history[middle]) / 2.0;
      else // Odd number of elements
         new_median = atr_history[middle];

      // Log the change if this is an update
      if (atr_median > 0 && DEBUG_LEVEL >= 1)
      {
         double change_pct = ((new_median - atr_median) / atr_median) * 100.0;
         Print("ATR median updated: ", DoubleToString(atr_median, _Digits), 
               " → ", DoubleToString(new_median, _Digits),
               " (", (change_pct >= 0 ? "+" : ""), DoubleToString(change_pct, 1), "%)");
      }
      else if (DEBUG_LEVEL >= 1)
      {
         Print("ATR median calculated: ", DoubleToString(new_median, _Digits),
               " from ", bars_needed, " bars (", ATR_MEDIAN_DAYS, " trading days)");
      }
      
      atr_median = new_median;
      last_median_calculation = TimeCurrent();
   }
}

//+------------------------------------------------------------------+
//| Check if today is a NYSE holiday or early close                  |
//+------------------------------------------------------------------+
bool IsNYSEHoliday(datetime t)
{
   // Convert server time to NY time by applying the fixed offset
   // NY_TIME_OFFSET is the difference between server and NY time (always 7 hours)
   datetime ny_time = t - NY_TIME_OFFSET * 3600;

   // Now get the date in NY time
   MqlDateTime dt;
   TimeToStruct(ny_time, dt);
   int y = dt.year, m = dt.mon, d = dt.day;
   int wd = dt.day_of_week; // 0=Sunday, 1=Monday, ...

   // Always skip weekends in NY time
   if (wd == 0 || wd == 6)
      return true;

   // 2025 NYSE Full Closures - checked using NY date
   if (y == 2025)
   {
      if ((m == 1 && d == 1)      // New Year's Day (Wed)
          || (m == 1 && d == 20)  // MLK Jr. Day (Mon)
          || (m == 2 && d == 17)  // Presidents' Day (Mon)
          || (m == 4 && d == 18)  // Good Friday (Fri)
          || (m == 5 && d == 26)  // Memorial Day (Mon)
          || (m == 6 && d == 19)  // Juneteenth (Thu)
          || (m == 7 && d == 4)   // Independence Day (Fri)
          || (m == 9 && d == 1)   // Labor Day (Mon)
          || (m == 11 && d == 27) // Thanksgiving (Thu)
          || (m == 12 && d == 25) // Christmas (Thu)
      )
         return true;

      // Early Closures (1:00 p.m. ET)
      if ((m == 7 && d == 3)      // Day before Independence Day (Thu)
          || (m == 11 && d == 28) // Day after Thanksgiving (Fri)
          || (m == 12 && d == 24) // Christmas Eve (Wed)
      )
      {
         // You may want to skip trading or close positions early on these days
         // For now, treat as full holiday (no trading)
         return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Manage position held after hours                                 |
//+------------------------------------------------------------------+
void ManageAfterHoursPos()
{
   // Check if position still exists
   if (!PositionSelectByTicket(ticket))
   {
      // If we're in AFTER_HOURS_POSITION state but the position doesn't exist,
      // we must transition to IDLE immediately and clear the ticket
      if (trade_state == STATE_AFTER_HOURS_POSITION)
      {
         Print("Position no longer exists - transitioning from AFTER_HOURS_POSITION to IDLE");
         trade_state = STATE_IDLE;
         if (LABEL_STATS)
            ShowLabel(); // Update display immediately
      }
      ticket = 0;
      return;
   }

   // Special check to detect time gaps (like weekends)
   static datetime last_check_time = 0;
   datetime current_time = TimeCurrent();

   if (last_check_time > 0 && current_time - last_check_time > 7200) // Gap greater than 2 hours
   {
      Print("WARNING: Time gap detected in after-hours position management - possible weekend/holiday skip");
      Print("Last check: ", TimeToString(last_check_time), ", Current: ", TimeToString(current_time),
            ", Gap: ", (current_time - last_check_time) / 3600, " hours");
   }

   last_check_time = current_time;

   // Log position details once per hour
   static datetime last_after_hours_log = 0;
   if (current_time - last_after_hours_log > 3600)
   {
      ENUM_POSITION_TYPE position_type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double sl = PositionGetDouble(POSITION_SL);
      double tp = PositionGetDouble(POSITION_TP);

      if (DEBUG_LEVEL >= 2)
         Print("AFTER-HOURS POSITION STATUS: Type=",
               (position_type == POSITION_TYPE_BUY ? "BUY" : "SELL"),
               ", SL=", DoubleToString(sl, _Digits),
               ", TP=", DoubleToString(tp, _Digits),
               ", Current time: ", TimeToString(current_time),
               ", Next session: ", TimeToString(next_session_start),
               ", Time until next session: ",
               (int)((next_session_start - current_time) / 60), " minutes");

      last_after_hours_log = current_time;
   }

   // Check if we need to close position before next session
   if (current_time >= next_session_start - CLOSE_MINUTES_BEFORE_NEXT_SESSION * 60)
   {
      if (DEBUG_LEVEL >= 1)
         Print("ManageAfterHoursPos: Closing position as we're approaching next session (",
               CLOSE_MINUTES_BEFORE_NEXT_SESSION, " minutes before ", TimeToString(next_session_start), ")");

      bool closed = ClosePos();

      if (!closed && ticket != 0)
      {
         if (DEBUG_LEVEL >= 1)
            Print("ManageAfterHoursPos: Failed to close position before next session. Will retry.");
      }
   }
}

//+------------------------------------------------------------------+
//| Calculate optimal slippage based on broker data                  |
//+------------------------------------------------------------------+
int GetSymbolSlippage()
{
   // Get broker-specific symbol information
   double spread = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   // Pure calculation based on broker data to get optimal slippage
   // Goal: Gold should automatically get 30-40 points

   int calculated_slippage;

   if (digits == 2) // Gold and other 2-digit instruments (like XAUUSD)
   {
      // For gold: spread is typically 10-30 points
      // Formula: spread * 1.5 + 20 points base
      // Examples: spread=20 → 20*1.5+20 = 50 points
      //          spread=15 → 15*1.5+20 = 42.5 = 43 points
      //          spread=10 → 10*1.5+20 = 35 points
      calculated_slippage = (int)(spread * 1.5 + 20);

      if (DEBUG_LEVEL >= 1)
         Print("Auto-detected 2-digit instrument like Gold: ", _Symbol);
   }
   else if (digits == 3) // JPY pairs
   {
      // JPY needs much higher slippage due to smaller increments
      // Formula: spread * 8 + 50 points base
      calculated_slippage = (int)(spread * 8 + 50);

      if (DEBUG_LEVEL >= 1)
         Print("Auto-detected 3 digit pair like JPY: ", _Symbol);
   }
   else if (digits == 4 || digits == 5) // Major forex pairs
   {
      // Formula: spread * 3 + 15 points base
      calculated_slippage = (int)(spread * 3 + 15);

      if (DEBUG_LEVEL >= 1)
         Print("Auto-detected Major forex pair: ", _Symbol, " (digits=", digits, ")");
   }
   else // Unknown/exotic pairs
   {
      // Higher safety margin for unknowns
      // Formula: spread * 5 + 30 points base
      calculated_slippage = (int)(spread * 5 + 30);

      if (DEBUG_LEVEL >= 1)
         Print("Auto-detected Exotic/Unknown pair: ", _Symbol, " (digits=", digits, ")");
   }

   // Apply reasonable bounds
   int min_slippage = 15;   // Never go below 15 points
   int max_slippage = 2000; // Cap at 2000 points for safety

   calculated_slippage = MathMax(min_slippage, MathMin(max_slippage, calculated_slippage));

   // Safety check for invalid broker data
   if (spread <= 0)
   {
      calculated_slippage = 40; // Safe fallback
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
//| Efficient helper functions for optimized breakout validation     |
//+------------------------------------------------------------------+
double GetPreviousClose()
{
   double closes[1];
   if (CopyClose(_Symbol, PERIOD_M1, 1, 1, closes) <= 0)
   {
      if (DEBUG_LEVEL >= 1)
         Print("Error getting previous close price");
      return 0.0; // Return 0 if error - will cause trend checks to fail safely
   }
   return closes[0];
}

bool IsTrendAlignmentBullish()
{
   // Get historical closes (excluding current price - we already checked that)
   double closes[];
   if (CopyClose(_Symbol, PERIOD_M1, 1, TREND_CANDLES - 1, closes) != TREND_CANDLES - 1)
   {
      if (DEBUG_LEVEL >= 1)
         Print("Error getting close prices for bullish trend alignment");
      return false;
   }

   // Append current price to the array (resize and add at front)
   ArrayResize(closes, TREND_CANDLES);
   for (int i = TREND_CANDLES - 1; i > 0; i--)
   {
      closes[i] = closes[i - 1]; // Shift existing closes to the right
   }
   closes[0] = price; // Add current price at front

   int bullish_candles = 0;
   int bearish_candles = 0;

   // Analyze all moves including current price
   for (int i = 0; i < TREND_CANDLES - 1; i++)
   {
      if (closes[i] > closes[i + 1]) // Compare current with previous
         bullish_candles++;
      else if (closes[i] < closes[i + 1])
         bearish_candles++;
      // Equal closes are ignored (neutral)
   }

   int total_directional_candles = bullish_candles + bearish_candles;
   if (total_directional_candles == 0)
      return false;

   double bullish_percentage = (double)bullish_candles / total_directional_candles;

   if (DEBUG_LEVEL >= 2)
   {
      Print("BULLISH TREND ALIGNMENT: ", bullish_candles, " bullish, ", bearish_candles, " bearish out of ",
            total_directional_candles, " directional moves (",
            DoubleToString(bullish_percentage * 100, 1), "% bullish)");
   }

   return bullish_percentage >= TREND_THRESHOLD;
}

bool IsTrendAlignmentBearish()
{
   // Get historical closes (excluding current price - we already checked that)
   double closes[];
   if (CopyClose(_Symbol, PERIOD_M1, 1, TREND_CANDLES - 1, closes) != TREND_CANDLES - 1)
   {
      if (DEBUG_LEVEL >= 1)
         Print("Error getting close prices for bearish trend alignment");
      return false;
   }

   // Append current price to the array (resize and add at front)
   ArrayResize(closes, TREND_CANDLES);
   for (int i = TREND_CANDLES - 1; i > 0; i--)
   {
      closes[i] = closes[i - 1]; // Shift existing closes to the right
   }
   closes[0] = price; // Add current price at front

   int bullish_candles = 0;
   int bearish_candles = 0;

   // Analyze all moves including current price
   for (int i = 0; i < TREND_CANDLES - 1; i++)
   {
      if (closes[i] > closes[i + 1]) // Compare current with previous
         bullish_candles++;
      else if (closes[i] < closes[i + 1])
         bearish_candles++;
      // Equal closes are ignored (neutral)
   }

   int total_directional_candles = bullish_candles + bearish_candles;
   if (total_directional_candles == 0)
      return false;

   double bearish_percentage = (double)bearish_candles / total_directional_candles;

   if (DEBUG_LEVEL >= 2)
   {
      Print("BEARISH TREND ALIGNMENT: ", bearish_candles, " bearish, ", bullish_candles, " bullish out of ",
            total_directional_candles, " directional moves (",
            DoubleToString(bearish_percentage * 100, 1), "% bearish)");
   }

   return bearish_percentage >= TREND_THRESHOLD;
}


//+------------------------------------------------------------------+
//| Calculate angle between two price points over time               |
//+------------------------------------------------------------------+
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

//+------------------------------------------------------------------+
//| Calculate angle from breakout point to current price             |
//+------------------------------------------------------------------+
double CalculateBreakoutAngle(double start_price, datetime start_time, double current_price)
{
   if (start_time == 0 || start_price == 0)
      return 0.0;

   double elapsed_seconds = (double)(TimeCurrent() - start_time);
   return CalculateSlopeAngleFromSeconds(start_price, current_price, elapsed_seconds);
}


//+------------------------------------------------------------------+
//| Reset breakout tracking variables                                |
//+------------------------------------------------------------------+
void ResetBreakoutTracking()
{
   breakout_start_price = 0;
   breakout_start_time = 0;
}

//+------------------------------------------------------------------+
//| Calculate SL/TP + risk-based lot and execute                     |
//+------------------------------------------------------------------+
void SendOrder(ENUM_ORDER_TYPE type)
{
   // Entry price
   double entry = (type == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                           : SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // Stop Loss calculation based on selected strategy
   double sl = CalculateStopLoss(type);

   // Range multiple - Use range size * multiplier
   double tp = CalculateTakeProfit(type, entry);

   // Lot sizing based on risk percentage
   double lots = CalculateLotSize(entry, sl);

   // Get the available filling modes for this symbol
   int filling_mode = (int)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   Print("Symbol filling modes: ", filling_mode);

   // Trade request
   MqlTradeRequest req = {};
   MqlTradeResult res = {};
   req.action = TRADE_ACTION_DEAL;
   req.symbol = _Symbol;
   req.type = type;
   req.volume = lots;
   req.price = entry;
   req.sl = sl;
   req.tp = tp;
   req.deviation = GetSymbolSlippage();
   req.magic = 777777;
   req.comment = "NY_ORB";

   // Set a filling mode that should work with most brokers
   if ((filling_mode & SYMBOL_FILLING_FOK) != 0)
      req.type_filling = ORDER_FILLING_FOK;
   else if ((filling_mode & SYMBOL_FILLING_IOC) != 0)
      req.type_filling = ORDER_FILLING_IOC;
   else
      req.type_filling = ORDER_FILLING_RETURN; // Try this as a fallback

   Print("Using filling mode: ", req.type_filling);

   bool result = OrderSend(req, res);
   if (!result || res.retcode != 10009) // 10009 is TRADE_RETCODE_DONE constant
   {
      string direction = (type == ORDER_TYPE_BUY) ? "buy" : "sell";
      Print("Failed market ", direction, " ", DoubleToString(lots, 2), " ", _Symbol,
            " sl: ", DoubleToString(sl, _Digits),
            " tp: ", DoubleToString(tp, _Digits),
            " [", GetErrorDescription(res.retcode), "]");
      Print("Order failed: ", res.retcode);
      return;
   }

   ticket = res.order;
   trades_today++;
   trade_state = STATE_IN_POSITION;
   if (LABEL_STATS)
      ShowLabel(); // Update display immediately

   string direction = (type == ORDER_TYPE_BUY) ? "LONG" : "SHORT";
   Print("ORB ", direction, " trade opened at ", TimeToString(TimeCurrent()),
         ": ticket=", ticket,
         ", entry=", DoubleToString(entry, _Digits),
         ", lots=", DoubleToString(lots, 2),
         ", SL=", DoubleToString(sl, _Digits),
         ", TP=", DoubleToString(tp, _Digits));
}

//+------------------------------------------------------------------+
//| Calculate stop loss based on strategy                            |
//+------------------------------------------------------------------+
double CalculateStopLoss(ENUM_ORDER_TYPE type)
{
   double sl = 0;

   switch (STOP_LOSS_STRATEGY)
   {
   case SL_OUTER: // Opposite side of the range
      sl = (type == ORDER_TYPE_BUY) ? range_low : range_high;
      Print("Using OUTER stop loss strategy - SL at opposite boundary");
      break;

   case SL_MIDDLE: // Middle of the range
      sl = (type == ORDER_TYPE_BUY) ? range_low + (range_size * 0.5)
                                    : range_high - (range_size * 0.5);
      Print("Using MIDDLE stop loss strategy - SL at mid-range");
      break;

   case SL_CLOSE: // Close to breakout point
      sl = (type == ORDER_TYPE_BUY) ? range_high : range_low;
      Print("Using CLOSE stop loss strategy - SL near breakout point");
      break;

   default: // Fallback to outer (safest)
      sl = (type == ORDER_TYPE_BUY) ? range_low : range_high;
      Print("Using default (OUTER) stop loss strategy");
   }

   return sl;
}

//+------------------------------------------------------------------+
//| Calculate take profit based on range size                        |
//+------------------------------------------------------------------+
double CalculateTakeProfit(ENUM_ORDER_TYPE type, double entry_price)
{
   // Range multiple - Use range size * multiplier
   double tp = (type == ORDER_TYPE_BUY) ? entry_price + range_size * RANGE_MULT
                                        : entry_price - range_size * RANGE_MULT;

   Print("Using range multiple take profit: ", DoubleToString(tp, _Digits),
         " (", DoubleToString(RANGE_MULT, 1), "x range size)");

   return tp;
}

//+------------------------------------------------------------------+
//| Calculate position size based on risk                            |
//+------------------------------------------------------------------+
double CalculateLotSize(double entry_price, double stop_loss)
{
   // Get account equity and calculate risk amount
   double account_equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double risk_amt = account_equity * RISK_PER_TRADE_PCT / 100.0;
   
   // Calculate stop loss distance in points
   double sl_dist_pts = MathAbs(entry_price - stop_loss) / _Point;
   string symbol = _Symbol;
   
   // Calculate lots based on instrument type
   double lots = 0;
   
   // Convert symbol to uppercase for case-insensitive comparison
   string symbol_upper = symbol;
   StringToUpper(symbol_upper);
   
   if (StringFind(symbol_upper, "XAUUSD") >= 0 || StringFind(symbol_upper, "GOLD") >= 0)
   {
      // Gold: Each point = $1 for CFD
      double point_value = 1.0;
      lots = risk_amt / (sl_dist_pts * point_value);
   }
   else if (StringFind(symbol_upper, "NAS100") >= 0 || StringFind(symbol_upper, "NAS") >= 0 ||
            StringFind(symbol_upper, "SP500") >= 0 || StringFind(symbol_upper, "SPX") >= 0 || 
            StringFind(symbol_upper, "DJ30") >= 0 || StringFind(symbol_upper, "DOW") >= 0)
   {
      // Index CFDs: Each point = $1 for CFD at PU Prime
      double point_value = 1.0;
      lots = risk_amt / (sl_dist_pts * point_value);
   }
   else if (StringFind(symbol_upper, "EURUSD") >= 0 || StringFind(symbol_upper, "GBPUSD") >= 0 || 
            StringFind(symbol_upper, "AUDUSD") >= 0 || StringFind(symbol_upper, "NZDUSD") >= 0)
   {
      // USD pairs: Each pip = $10 per standard lot
      double sl_dist_pips = sl_dist_pts / 10.0;
      double pip_value = 10.0;
      lots = risk_amt / (sl_dist_pips * pip_value);
   }
   else if (StringFind(symbol_upper, "USDJPY") >= 0)
   {
      // JPY pairs: Each pip = ¥1000 per standard lot
      double sl_dist_pips = sl_dist_pts / 100.0;
      double pip_value = (1000.0 / entry_price);
      lots = risk_amt / (sl_dist_pips * pip_value);
   }
   
   // Normalize lot size to broker requirements
   // First round to lot_step precision
   int lot_step_decimals = 0;
   double temp_step = lot_step;
   while (temp_step < 1.0 && temp_step > 0)
   {
      lot_step_decimals++;
      temp_step *= 10;
   }
   
   lots = NormalizeDouble(lots / lot_step, lot_step_decimals) * lot_step;
   lots = NormalizeDouble(lots, lot_step_decimals); // Ensure final value is properly rounded
   
   // Ensure minimum lot size
   lots = MathMax(lots, lot_min);
   
   // Debug logging
   if (DEBUG_LEVEL >= 1) // Changed to level 1 to see more info about lot calculations
   {
      Print("=== LOT SIZE CALCULATION ===");
      Print("Account equity: $", DoubleToString(account_equity, 2));
      Print("Risk amount: $", DoubleToString(risk_amt, 2));
      Print("Stop loss distance in points: ", DoubleToString(sl_dist_pts, 1));
      Print("Lot step decimals: ", lot_step_decimals);
      Print("Raw lot size: ", DoubleToString(lots, lot_step_decimals));
      Print("Normalized lot size: ", DoubleToString(lots, lot_step_decimals));
      Print("Minimum lot: ", DoubleToString(lot_min, lot_step_decimals));
      Print("Lot step: ", DoubleToString(lot_step, lot_step_decimals));
      Print("Actual risk: $", DoubleToString(CalculateActualRisk(lots, entry_price, stop_loss), 2));
      Print("========================");
   }
   
   return lots;
}

// Calculate actual risk amount for verification
double CalculateActualRisk(double lots, double entry_price, double stop_loss)
{
   string symbol = _Symbol;
   string symbol_upper = symbol;
   StringToUpper(symbol_upper);
   double sl_dist_pts = MathAbs(entry_price - stop_loss) / _Point;
   double actual_risk = 0;
   
   if (StringFind(symbol_upper, "XAUUSD") >= 0 || StringFind(symbol_upper, "GOLD") >= 0)
   {
      actual_risk = lots * sl_dist_pts * 1.0; // $1 per point
   }
   else if (StringFind(symbol_upper, "NAS100") >= 0 || StringFind(symbol_upper, "NAS") >= 0 ||
            StringFind(symbol_upper, "SP500") >= 0 || StringFind(symbol_upper, "SPX") >= 0 || 
            StringFind(symbol_upper, "DJ30") >= 0 || StringFind(symbol_upper, "DOW") >= 0)
   {
      actual_risk = lots * sl_dist_pts * 1.0; // $1 per point
   }
   else if (StringFind(symbol_upper, "EURUSD") >= 0 || StringFind(symbol_upper, "GBPUSD") >= 0 || 
            StringFind(symbol_upper, "AUDUSD") >= 0 || StringFind(symbol_upper, "NZDUSD") >= 0)
   {
      actual_risk = lots * (sl_dist_pts / 10.0) * 10.0; // $10 per pip
   }
   else if (StringFind(symbol_upper, "USDJPY") >= 0)
   {
      actual_risk = lots * (sl_dist_pts / 100.0) * (1000.0 / entry_price);
   }
   
   return actual_risk;
}

//+------------------------------------------------------------------+
//| Get error description                                            |
//+------------------------------------------------------------------+
string GetErrorDescription(int error_code)
{
   string error_string;

   switch (error_code)
   {
   case 10004:
      error_string = "Requote";
      break;
   case 10006:
      error_string = "Request rejected";
      break;
   case 10007:
      error_string = "Request canceled by trader";
      break;
   case 10008:
      error_string = "Order placed";
      break;
   case 10009:
      error_string = "Request executed";
      break;
   case 10010:
      error_string = "Request executed partially";
      break;
   case 10011:
      error_string = "Request error";
      break;
   case 10013:
      error_string = "Error trade disabled";
      break;
   case 10014:
      error_string = "No changes in request";
      break;
   case 10015:
      error_string = "AutoTrading disabled";
      break;
   case 10016:
      error_string = "Broker busy";
      break;
   case 10017:
      error_string = "Invalid price";
      break;
   case 10018:
      error_string = "Invalid stops";
      break;
   case 10019:
      error_string = "Trade not allowed";
      break;
   case 10020:
      error_string = "Trade timeout";
      break;
   case 10021:
      error_string = "Invalid volume";
      break;
   case 10022:
      error_string = "Market closed";
      break;
   case 10026:
      error_string = "Order change denied";
      break;
   case 10027:
      error_string = "Trading timeout";
      break;
   case 10028:
      error_string = "Transaction canceled";
      break;
   case 10029:
      error_string = "No connect to trade server";
      break;
   case 10030:
      error_string = "Unsupported filling mode";
      break;
   case 10031:
      error_string = "No connection/Invalid account";
      break;
   case 10032:
      error_string = "Too many requests";
      break;
   case 10033:
      error_string = "Trade is disabled for symbol";
      break;
   case 10034:
      error_string = "Invalid order ticket";
      break;
   default:
      error_string = "Unknown error " + IntegerToString(error_code);
   }

   return error_string;
}

//+------------------------------------------------------------------+
//| Manage open position  (time exit at session end)                 |
//+------------------------------------------------------------------+
void ManagePos()
{
   // Check if position still exists
   if (!PositionSelectByTicket(ticket))
   {
      trade_state = STATE_IDLE;
      ticket = 0;
      return;
   }

   // Get position properties
   ENUM_POSITION_TYPE position_type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double sl = PositionGetDouble(POSITION_SL);
   double tp = PositionGetDouble(POSITION_TP);
   double open_price = PositionGetDouble(POSITION_PRICE_OPEN);

   // Get current time
   datetime current_time = TimeCurrent();

   // Check if we're after session end
   if (current_time >= current_session_end)
   {
      if (!ALLOW_TP_AFTER_HOURS)
      {
         // Standard behavior - close at session end
         bool closed = ClosePos();

         if (closed)
         {
            Print("Position closed at session end - after-hours TP not enabled (", TimeToString(current_time), ")");
         }
         else if (ticket != 0)
         {
            Print("Failed to close position at session end. Will retry.");
         }
      }
      else
      {
         // Transition to the after-hours state for clearer management
         trade_state = STATE_AFTER_HOURS_POSITION;
         Print("POSITION CONTINUED AFTER HOURS - Transitioning to AFTER_HOURS_POSITION state at ", TimeToString(current_time));
         if (LABEL_STATS)
            ShowLabel(); // Update display immediately

         // Call after-hours management immediately
         ManageAfterHoursPos();
      }
   }
}

//+------------------------------------------------------------------+
//| Close position                                                   |
//+------------------------------------------------------------------+
bool ClosePos()
{
   if (!PositionSelectByTicket(ticket))
      return true; // Position doesn't exist, consider it "closed"
   ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

   MqlTradeRequest req = {};
   MqlTradeResult res = {};
   req.action = TRADE_ACTION_DEAL;
   req.position = ticket;
   req.symbol = _Symbol;
   req.volume = PositionGetDouble(POSITION_VOLUME);
   req.type = (ptype == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
   req.price = (req.type == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                            : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   req.deviation = GetSymbolSlippage();
   req.magic = 777777;

   // Get the available filling modes for this symbol
   int filling_mode = (int)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);

   // Set a filling mode that should work with most brokers
   if ((filling_mode & SYMBOL_FILLING_FOK) != 0)
      req.type_filling = ORDER_FILLING_FOK;
   else if ((filling_mode & SYMBOL_FILLING_IOC) != 0)
      req.type_filling = ORDER_FILLING_IOC;
   else
      req.type_filling = ORDER_FILLING_RETURN; // Try this as a fallback

   bool result = OrderSend(req, res);
   if (!result || res.retcode != 10009) // 10009 is TRADE_RETCODE_DONE constant
   {
      // Some errors (like market closed) should be handled gracefully with minimal logging
      // Market closed (10022) and Invalid stops (10018) are common during weekends/holidays
      static datetime last_close_error_log = 0;
      datetime cur_time = TimeCurrent();
      if (cur_time - last_close_error_log > 300) // Log errors max once per 5 minutes
      {
         last_close_error_log = cur_time;
         string direction = (req.type == ORDER_TYPE_BUY) ? "buy" : "sell";
         Print("Close position failed: ", res.retcode, " [", GetErrorDescription(res.retcode), "]");
      }
      return false; // Failed to close
   }

   ticket = 0;
   trade_state = STATE_IDLE; // Always go to IDLE after closing a position
   if (LABEL_STATS)
      ShowLabel(); // Update display immediately
   Print("Position closed at ", TimeToString(TimeCurrent()));
   return true; // Successfully closed
}

//+------------------------------------------------------------------+
//| Chart label                                                      |
//+------------------------------------------------------------------+
void ShowLabel()
{
   string status;

   switch (trade_state)
   {
   case STATE_IDLE:
      status = "Waiting for session start";
      break;
   case STATE_BUILDING_RANGE:
      status = "Building opening range";
      break;
   case STATE_RANGE_LOCKED:
      status = "Watching for breakout";
      break;
   case STATE_IN_POSITION:
   {
      ENUM_POSITION_TYPE ptype;
      if (PositionSelectByTicket(ticket))
      {
         ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         status = "In " + (ptype == POSITION_TYPE_BUY ? "LONG" : "SHORT") + " position";
      }
      else
      {
         status = "Position status unknown";
      }
      break;
   }
   case STATE_AFTER_HOURS_POSITION:
   {
      ENUM_POSITION_TYPE ptype;
      if (PositionSelectByTicket(ticket))
      {
         ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         double sl = PositionGetDouble(POSITION_SL);
         double tp = PositionGetDouble(POSITION_TP);

         // Calculate time to next session with proper handling
         datetime current_time = TimeCurrent();
         int mins_to_next = (int)((next_session_start - current_time) / 60);

         string time_info;
         if (mins_to_next > 0)
         {
            if (mins_to_next > 1440) // More than 24 hours
            {
               int days = mins_to_next / 1440;
               int hours = (mins_to_next % 1440) / 60;
               time_info = IntegerToString(days) + "d " + IntegerToString(hours) + "h to next session";
            }
            else if (mins_to_next > 60) // More than 1 hour
            {
               int hours = mins_to_next / 60;
               int minutes = mins_to_next % 60;
               time_info = IntegerToString(hours) + "h " + IntegerToString(minutes) + "m to next session";
            }
            else // Less than 1 hour
            {
               time_info = IntegerToString(mins_to_next) + "m to next session";
            }
         }
         else
         {
            time_info = "Next session starting soon";
         }

         status = "In " + (ptype == POSITION_TYPE_BUY ? "LONG" : "SHORT") +
                  " AFTER HOURS position (" + time_info + ")";
      }
      else
      {
         status = "After-hours position status unknown";
      }
      break;
   }
   default:
      status = "Unknown state";
   }

   // Get session details based on session type
   string session_type_str = (SESSION_TYPE == CLASSIC_NYSE) ? "NYSE Open (9:30 NY)" : "Early US (8:00 NY)";

   // Format buffer info
   string buffer_info = "Range " + DoubleToString(RANGE_BUFFER_MULT, 1) + "×Size";

   // Format take profit info
   string tp_info = "Range " + DoubleToString(RANGE_MULT, 1) + "×Size";

   // Format session time info
   string session_time_info = TimeToString(current_session_start, TIME_MINUTES) +
                              " - " + TimeToString(current_session_end, TIME_MINUTES);

   // Format volatility filter info
   string vol_filter = USE_VOLATILITY_FILTER ? (volatility_ok ? "Passed ✓" : "Failed ✗") : "Disabled";

   string txt = StringFormat(
       "NY ORB EA | Session: %s | Trades: %d/%d\n"
       "Status: %s | Session Time: %s\n"
       "Range: %s - %s (width: %s pips)\n"
       "Buffer: %s | Target: %s | Volatility: %s",
       session_type_str,
       trades_today,
       MAX_TRADES_PER_DAY,
       status,
       session_time_info,
       DoubleToString(range_low, _Digits),
       DoubleToString(range_high, _Digits),
       DoubleToString(range_size / _Point / 10, 1),
       buffer_info,
       tp_info,
       vol_filter);

   Comment(txt);
}

//+------------------------------------------------------------------+
//| Optimization function for backtesting                           |
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
   if (total_trades < 100 || initial_deposit <= 0)
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

   // PROFIT-FOCUSED FITNESS: Heavily weight profit, consider drawdown secondarily
   
   // Start with raw profit as base score
   double profit_score = net_profit;
   
   // Square the profit to give even more weight to profitable strategies
   double weighted_profit = profit_score * profit_score;
   
   // Apply a softer drawdown penalty (square root to reduce impact)
   double drawdown_factor = 1.0;
   if (drawdown_percent > 0.1) // Only apply penalty for meaningful drawdown
   {
      // Convert to a factor that reduces as drawdown increases, but less aggressively
      drawdown_factor = 1.0 / MathSqrt(1.0 + drawdown_percent);
   }
   
   // Apply very minimal trade count consideration
   // Just enough to prefer strategies with more trades when profit/drawdown are similar
   double trade_factor = 1.0 + MathLog(total_trades / 50.0) * 0.1; // Max ~20% impact
   
   // Final fitness: Heavily weighted profit × mild drawdown penalty × minimal trade factor
   double fitness = weighted_profit * drawdown_factor * trade_factor;

   // Debug output for optimization
   if (DEBUG_LEVEL >= 1)
   {
      Print("=== PROFIT-FOCUSED OPTIMIZATION RESULTS ===");
      Print("Total Trades: ", (int)total_trades);
      Print("Net Profit: $", DoubleToString(net_profit, 2));
      Print("ROI: ", DoubleToString(roi_percent, 2), "%");
      Print("Max Drawdown: ", DoubleToString(drawdown_percent, 2), "%");
      Print("Base Profit: ", DoubleToString(profit_score, 2));
      Print("Weighted Profit: ", DoubleToString(weighted_profit, 2));
      Print("Drawdown Factor: ", DoubleToString(drawdown_factor, 4));
      Print("Trade Factor: ", DoubleToString(trade_factor, 4));
      Print("FINAL FITNESS: ", DoubleToString(fitness, 2));
      Print("============================================");
   }

   return fitness;
}

//+------------------------------------------------------------------+
//+------------------------------------------------------------------+