//+------------------------------------------------------------------+
//|               NY Cash Session ORB EA (30-minute)                  |
//|     Handles PU Prime server UTC+2/UTC+3 and NY EST/EDT shift      |
//|               Copyright 2025 - free to use / modify               |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025"
#property version   "2.00"
#property strict

//---------------  USER-TWEAKABLE INPUTS  ---------------------------//
// 1) Session times
enum SessionType { 
   CLASSIC_NYSE = 0,     // Classic NYSE (09:30 - 10:00 NY)
   EARLY_US = 1          // Early US (08:00 - 08:30 NY)
};
input SessionType  SESSION_TYPE        = CLASSIC_NYSE;  // Session window to use
input int          SESSION_OR_MINUTES  = 30;            // Opening-range length (minutes)
input int          NY_SESSION_CLOSE_HOUR = 16;          // NY Close hour (default 16:00 NY)

// 2) Breakout / risk
input double       ATR_BUFFER_MULT     = 0.2;           // Buffer as ATR multiple

// Stop loss placement strategy
enum SLPlacement {
   SL_OUTER = 0,      // Opposite boundary (safest, largest SL)
   SL_MIDDLE = 1,     // Middle of the range (moderate)
   SL_CLOSE = 2       // Close to breakout point (tight, aggressive)
};
input SLPlacement   STOP_LOSS_STRATEGY = SL_OUTER;     // Stop loss placement strategy

// 3) Money-management
input double       RISK_PER_TRADE_PCT  = 1.0;           // % equity risk
input int          MAX_TRADES_PER_DAY  = 2;             // Max trades per day
input int          MAX_DEVIATION_POINTS = 20;           // Maximum allowed slippage in points

// Add back the global variables for broker lot constraints
// Broker lot size constraints
double          lot_min        = 0;  // Will be set from broker
double          lot_step       = 0;  // Will be set from broker

// 4) Volatility filter
input bool         USE_VOLATILITY_FILTER = true;        // Enable volatility filter
input double       ATR_THRESHOLD_PCT   = 80.0;          // ATR Threshold Percentage - Keep 80% for balanced trading; lower to 70% for more signals; raise to 90% for stronger breakouts only
input int          ATR_PERIOD          = 14;            // ATR Period - Keep 14 for standard volatility; lower to 7 for faster response; raise to 21 for smoother readings
input int          ATR_MEDIAN_DAYS     = 120;           // ATR Median Days - Keep 120 days (6 months) for stable markets; lower to 60-90 days for adapting to changing regimes

// 5) Range Multiple Target
// This multiplies the opening range size (high-low) to determine TP distance from entry:
// For buy orders: TP = entry + (range_size × RANGE_MULT) 
// For sell orders: TP = entry - (range_size × RANGE_MULT)
// 
input double       RANGE_MULT          = 1.0;           // Keep 1.0 for balanced risk:reward; lower to 0.5-0.8 for faster but smaller profits; raise to 1.5-2.0 for larger but slower profits
input int          CONFIRMATION_CANDLES = 1;            // Candles required to confirm breakout (1=immediate, 2+=more conservative)
input bool         ALLOW_TP_AFTER_HOURS = false;        // Allow positions to reach TP after session close (will close before next session)

// 6) Visuals
input color        BOX_COLOR           = 0x0000FF;      // Box color (Blue)
input uchar        BOX_OPACITY         = 20;            // Box opacity (0-255)
input bool         LABEL_STATS         = true;          // Show info label

//---------------  INTERNAL STATE  ---------------------------//
enum TradeState { STATE_IDLE, STATE_BUILDING_RANGE, STATE_RANGE_LOCKED, STATE_IN_POSITION };
TradeState      trade_state    = STATE_IDLE;

//---------------  TIME VARIABLES  ---------------------------//
// Fixed time offset between server and NY (always 7 hours)
const int       NY_TIME_OFFSET = 7;       // Server is 7 hours ahead of NY

// Session timing variables
datetime        current_session_start;    // Start of current trading session (server time)
datetime        current_session_end;      // End of current trading session (server time)
datetime        current_range_end;        // End of opening range period (server time)
datetime        next_session_start;       // Start of next trading session (server time)
double          range_high     = -DBL_MAX;
double          range_low      =  DBL_MAX;
double          range_size     = 0;
double          atr_value      = 0;  // Current ATR value
double          atr_median     = 0;  // 6-month ATR median
bool            volatility_ok  = false; // Volatility filter passed
bool            box_drawn      = false;
string          box_name       = "ORB_BOX", hl_name="ORB_HI", ll_name="ORB_LO";

// Position tracking
ulong           ticket         = 0;
int             trades_today   = 0;
int             stored_day     = -1;

// Breakout confirmation tracking
int             bull_breakout_count = 0;  // Count of consecutive bullish breakout candles
int             bear_breakout_count = 0;  // Count of consecutive bearish breakout candles

// ATR history for median calculation
double          atr_history[];

// For debugging/logging
int             debug_level    = 2;  // 0=none, 1=basic, 2=detailed

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
//| Calculate session time boundaries                                |
//+------------------------------------------------------------------+
void CalculateSessionTimes(datetime reference_time, bool is_tomorrow = false)
{
   // Get midnight of reference day
   datetime midnight = DateOfDay(reference_time);
   
   // If calculating for tomorrow, add a day
   if(is_tomorrow)
      midnight += 86400;
      
   // Define NY session hours based on session type
   int ny_start_hour, ny_start_minute;
   
   if(SESSION_TYPE == CLASSIC_NYSE)
   {
      ny_start_hour = 9;
      ny_start_minute = 30;
   }
   else // EARLY_US
   {
      ny_start_hour = 8;
      ny_start_minute = 0;
   }
   
   // Convert NY time to server time using fixed offset
   int server_start_hour = ny_start_hour + NY_TIME_OFFSET;
   int server_start_minute = ny_start_minute;
   int server_close_hour = NY_SESSION_CLOSE_HOUR + NY_TIME_OFFSET;
   
   // Calculate session timestamps
   datetime session_start = midnight + server_start_hour * 3600 + server_start_minute * 60;
   datetime session_end = midnight + server_close_hour * 3600;
   datetime range_end = session_start + SESSION_OR_MINUTES * 60;
   
   // Update global session variables
   if (!is_tomorrow) {
      current_session_start = session_start;
      current_session_end = session_end;
      current_range_end = range_end;
   } else {
      next_session_start = session_start;
   }
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
   
   // Calculate today's session times
   CalculateSessionTimes(current_time, false);
   
   // Calculate tomorrow's session start
   CalculateSessionTimes(current_time + 86400, true);
   
   // Check if today's session is over, use tomorrow's times instead
   if(current_time > current_session_end) {
      // Copy tomorrow's start to today's session variables
      current_session_start = next_session_start;
      current_range_end = current_session_start + SESSION_OR_MINUTES * 60;
      
      // Calculate day after tomorrow for next_session_start
      CalculateSessionTimes(current_time + 2*86400, true);
      
      // Recalculate session end time
      datetime tomorrow_midnight = DateOfDay(current_time) + 86400;
      current_session_end = tomorrow_midnight + (NY_SESSION_CLOSE_HOUR + NY_TIME_OFFSET) * 3600;
      
      Print("Current time ", TimeToString(current_time), " is past today's session end. Setting up for tomorrow's session.");
   }
   
   // Log session details
   LogSessionDetails();
}

//+------------------------------------------------------------------+
//| Log session details                                              |
//+------------------------------------------------------------------+
void LogSessionDetails()
{
   // Calculate offsets for logging only
   int ny_time_offset = IsNYDST(TimeCurrent()) ? -4 : -5;  // EDT(-4) in summer, EST(-5) in winter
   int srv_offset = (int)((TimeCurrent() - TimeGMT()) / 3600);  // Current server offset
   
   string session_type_str = (SESSION_TYPE == CLASSIC_NYSE) ? "NYSE Open (9:30 NY)" : "Early US (8:00 NY)";
   
   Print("Session window calculated: ", session_type_str);
   Print("  Opening Range: ", TimeToString(current_session_start), " to ", 
         TimeToString(current_range_end), " (", SESSION_OR_MINUTES, " minutes)");
   Print("  Trading Hours: ", TimeToString(current_session_start), " to ", 
         TimeToString(current_session_end), " (server time)");
   Print("  Next session starts: ", TimeToString(next_session_start));
   Print("  Current server UTC offset: ", srv_offset, 
         ", NY offset: ", ny_time_offset, ", using fixed ", NY_TIME_OFFSET, "h gap");
}

//+------------------------------------------------------------------+
//| Expert init                                                      |
//+------------------------------------------------------------------+
int OnInit()
{
   // Get broker's lot size constraints
   lot_min = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   lot_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   
   Print("Broker lot size constraints for ", _Symbol, ":");
   Print("  Minimum lot size: ", DoubleToString(lot_min, 2));
   Print("  Lot step size: ", DoubleToString(lot_step, 2));
   
   // Verify timeframe
   if(_Period != PERIOD_M15)
   {
      Print("Attach to a 15-minute chart for optimal performance.");
      // We'll continue but warn the user
   }
   
   // Reset for new trading day
   ResetDay();
   
   // Display strategy information
   string session_type_str = (SESSION_TYPE == CLASSIC_NYSE) ? "NYSE Open (9:30 NY)" : "Early US (8:00 NY)";
   Print("=== NY ORB Strategy Initialized ===");
   Print("Session: ", session_type_str);
   Print("Opening Range: ", SESSION_OR_MINUTES, " minutes");
   Print("Max Trades: ", MAX_TRADES_PER_DAY, " per day");
   Print("Buffer: ATR × ", DoubleToString(ATR_BUFFER_MULT, 1));
   Print("Take Profit Type: Range Multiple");
   
   // Show stop loss strategy
   string sl_strategy = "";
   switch(STOP_LOSS_STRATEGY) {
      case SL_OUTER: sl_strategy = "Outer (Conservative)"; break;
      case SL_MIDDLE: sl_strategy = "Middle (Moderate)"; break;
      case SL_CLOSE: sl_strategy = "Close (Aggressive)"; break;
      default: sl_strategy = "Unknown";
   }
   Print("Stop Loss Strategy: ", sl_strategy);
   
   Print("Volatility Filter: ", USE_VOLATILITY_FILTER ? "Enabled" : "Disabled");
   Print("=================================");
   
   // Calculate ATR
   UpdateATR();
   
   // Add volume indicator to chart
   int volume_indicator = iVolumes(_Symbol, PERIOD_CURRENT, VOLUME_TICK);
   if(volume_indicator != INVALID_HANDLE)
   {
      // Add to separate window below main chart
      if(!ChartIndicatorAdd(0, 1, volume_indicator))
      {
         Print("Failed to add volume indicator to chart. Error: ", GetLastError());
      }
      else
      {
         Print("Volume indicator added to chart successfully");
      }
   }
   
   // Verify test data is available during session hours
   ValidateTestData();
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Validate that test data exists for the session period            |
//+------------------------------------------------------------------+
void ValidateTestData()
{
   // Get current time and calculate today's session window
   datetime current_time = TimeCurrent();
   datetime today_midnight = DateOfDay(current_time);
   datetime today_session_start = today_midnight + 15 * 3600;  // 15:00 server time
   
   // Check if we're past the session start time
   if(current_time < today_session_start)
   {
      Print("Validation: Current time is before today's session start. Will check next session.");
      today_session_start += 86400; // Check tomorrow's session
   }
   
   // Try to read some bars around the session start
   Print("VALIDATING DATA around session start: ", TimeToString(today_session_start));
   
   // Check bars before, at, and after session start
   for(int offset = -2; offset <= 2; offset++)
   {
      datetime check_time = today_session_start + offset * 900; // 15-minute bars
      int bar_index = iBarShift(_Symbol, PERIOD_M15, check_time, false);
      
      if(bar_index >= 0)
      {
         double close = iClose(_Symbol, PERIOD_M15, bar_index);
         double open = iOpen(_Symbol, PERIOD_M15, bar_index);
         double high = iHigh(_Symbol, PERIOD_M15, bar_index);
         double low = iLow(_Symbol, PERIOD_M15, bar_index);
         
         Print("Bar found at ", TimeToString(check_time), 
               " (index ", bar_index, 
               "): Open=", DoubleToString(open, _Digits),
               ", High=", DoubleToString(high, _Digits),
               ", Low=", DoubleToString(low, _Digits),
               ", Close=", DoubleToString(close, _Digits));
      }
      else
      {
         Print("WARNING: No bar found at ", TimeToString(check_time), 
               ". This might indicate missing data during the session window!");
      }
   }
   
   // Specifically check the first 15-minute bar of the session
   datetime first_bar_time = today_session_start;
   int first_bar_index = iBarShift(_Symbol, PERIOD_M15, first_bar_time, false);
   
   if(first_bar_index >= 0)
   {
      Print("First session bar found at ", TimeToString(first_bar_time));
   }
   else
   {
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
   Comment("");
}

//+------------------------------------------------------------------+
//| Each tick                                                        |
//+------------------------------------------------------------------+
void OnTick()
{
   // Check for new day - reset counters if needed
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.day != stored_day)
      ResetDay();

   // Current time for session checks
   datetime current_time = TimeCurrent();
   
   // Skip trading on NYSE holidays
   if (IsNYSEHoliday(TimeCurrent()))
   {
      if (trade_state != STATE_IDLE)
      {
         Print("NYSE holiday or early close detected, skipping trading for today.");
         trade_state = STATE_IDLE;
      }
      return;
   }
   
   // Debug output for session tracking - log once an hour
   static datetime last_tick_debug = 0;
   if(current_time - last_tick_debug > 3600)
   {
      Print("DEBUG [", TimeToString(current_time), "] Day: ", dt.day, 
            " | Session window: ", TimeToString(current_session_start), " to ", 
            TimeToString(current_session_end),
            " | Range window: ", TimeToString(current_session_start), " to ",
            TimeToString(current_range_end),
            " | State: ", GetStateString(trade_state));
      last_tick_debug = current_time;
   }
   
   // Debug output at the start of each trading session
   static datetime last_session_day = 0;
   datetime today = DateOfDay(current_time);
   if(today != last_session_day && IsWithinSessionHours(current_time))
   {
      Print("TRADING SESSION STARTED: ", TimeToString(current_time), 
            " is within session window (", TimeToString(current_session_start), 
            " to ", TimeToString(current_session_end), ")");
      last_session_day = today;
   }

   // Update ATR on each tick
   UpdateATR();

   // Ignore ticks outside trading window
   if(!IsWithinSessionHours(current_time))
   {
      // Only log state changes to avoid spamming the log
      if(trade_state != STATE_IDLE && current_time - last_tick_debug <= 3600)
      {
         Print("Outside of session window now. Going idle. Time: ", 
               TimeToString(current_time), ", Session: ", 
               TimeToString(current_session_start), " - ", TimeToString(current_session_end), 
               ", Current state: ", GetStateString(trade_state));
         trade_state = STATE_IDLE;
      }
      return;
   }

   // State machine for ORB strategy
   UpdateSessionState(current_time);
   
   // Handle each state's logic based on current state
   switch(trade_state)
   {
      case STATE_BUILDING_RANGE:
         // Track high/low during opening range period
         UpdateRange();
         break;
         
      case STATE_RANGE_LOCKED:
         // Only check for breakouts after the bar closes
         if(IsNewBar())
         {
            CheckBreakout();
         }
         break;
         
      case STATE_IN_POSITION:
         ManagePos();
         break;
   }

   if(LABEL_STATS) ShowLabel();
}

//+------------------------------------------------------------------+
//| Check and handle state transitions                               |
//+------------------------------------------------------------------+
void UpdateSessionState(datetime current_time)
{
   // Check if within opening range formation time
   if(IsWithinRangeFormationPeriod(current_time) && trade_state == STATE_IDLE)
   {
      trade_state = STATE_BUILDING_RANGE;
      Print("BUILDING RANGE STARTED at ", TimeToString(current_time), 
            ", Window: ", TimeToString(current_session_start), " to ", 
            TimeToString(current_range_end));
      
      // Initialize range values
      InitializeRangeValues();
      
      // Process the first bar immediately
      UpdateRange();
   }
   // Check if range formation period has ended
   else if(current_time >= current_range_end && trade_state == STATE_BUILDING_RANGE)
   {
      trade_state = STATE_RANGE_LOCKED;
      
      // Calculate range size for TP calculations
      range_size = range_high - range_low;
      
      // Check volatility filter
      CheckVolatilityFilter();
      
      // Draw range visualization
      DrawBox();
      
      PrintFormat("Range locked at %s. High=%s, Low=%s, Width=%s points", 
                 TimeToString(current_time),
                 DoubleToString(range_high, _Digits), 
                 DoubleToString(range_low, _Digits),
                 DoubleToString(range_size/_Point, 0));
                 
      // Check for breakout immediately after range is locked
      if(IsNewBar())
      {
         CheckBreakout();
      }
   }
}

//+------------------------------------------------------------------+
//| Initialize range values for a new session                        |
//+------------------------------------------------------------------+
void InitializeRangeValues()
{
   range_high = -1000000;
   range_low = 1000000;
   bull_breakout_count = 0;
   bear_breakout_count = 0;
}

//+------------------------------------------------------------------+
//| Check if current volatility passes filter                        |
//+------------------------------------------------------------------+
void CheckVolatilityFilter()
{
   volatility_ok = true;
   if(USE_VOLATILITY_FILTER)
   {
      volatility_ok = (atr_value >= atr_median * ATR_THRESHOLD_PCT / 100.0);
      
      if(!volatility_ok)
      {
         Print("⚠️ VOLATILITY FILTER: ATR(", ATR_PERIOD, ")=", DoubleToString(atr_value, _Digits),
               " is below threshold (", DoubleToString(atr_median * ATR_THRESHOLD_PCT / 100.0, _Digits),
               "). No trades will be taken.");
      }
      else
      {
         Print("✅ VOLATILITY FILTER: ATR(", ATR_PERIOD, ")=", DoubleToString(atr_value, _Digits),
               " passed threshold (", DoubleToString(atr_median * ATR_THRESHOLD_PCT / 100.0, _Digits),
               ")");
      }
   }
}

//+------------------------------------------------------------------+
//| Check if we have a new bar                                       |
//+------------------------------------------------------------------+
bool IsNewBar()
{
   static datetime last_bar_time = 0;
   datetime current_bar_time = iTime(_Symbol, PERIOD_M15, 0);
   
   if(current_bar_time != last_bar_time)
   {
      last_bar_time = current_bar_time;
      Print("NEW BAR DETECTED at ", TimeToString(current_bar_time), 
            ", session window: ", TimeToString(current_session_start), " to ", TimeToString(current_session_end),
            ", state: ", GetStateString(trade_state));
      return true;
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Helper to convert trade state to string                          |
//+------------------------------------------------------------------+
string GetStateString(TradeState state)
{
   switch(state)
   {
      case STATE_IDLE: return "IDLE";
      case STATE_BUILDING_RANGE: return "BUILDING_RANGE";
      case STATE_RANGE_LOCKED: return "RANGE_LOCKED";
      case STATE_IN_POSITION: return "IN_POSITION";
      default: return "UNKNOWN";
   }
}

//+------------------------------------------------------------------+
//| Reset counters at new server day                                 |
//+------------------------------------------------------------------+
void ResetDay()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   stored_day   = dt.day;
   trades_today = 0;
   ticket       = 0;
   trade_state  = STATE_IDLE;
   
   // Initialize range values to ensure they will be updated properly
   // Using very large but finite values to avoid potential issues with DBL_MAX
   range_high   = -1000000;
   range_low    = 1000000;
   
   // Reset breakout confirmation counters
   bull_breakout_count = 0;
   bear_breakout_count = 0;
   
   box_drawn    = false;
   ObjectsDeleteAll(0, box_name);
   ObjectsDeleteAll(0, hl_name);
   ObjectsDeleteAll(0, ll_name);
   
   Print("New day reset: ", TimeToString(TimeCurrent()));
   
   // Recalculate session timing values including next_session_start
   ComputeSession();
}

//+------------------------------------------------------------------+
//| Track highs/lows during OR                                       |
//+------------------------------------------------------------------+
void UpdateRange()
{
   double high[], low[];
   
   // Get the high/low of the most recent completed M15 bar
   if(CopyHigh(_Symbol, PERIOD_M15, 1, 1, high) > 0 && CopyLow(_Symbol, PERIOD_M15, 1, 1, low) > 0)
   {
      double h = high[0];
      double l = low[0];
      
      // Update range values if needed
      if(h > range_high) 
      {
         range_high = h;
         Print("New range high: ", DoubleToString(range_high, _Digits), " at ", TimeToString(TimeCurrent()));
      }
      
      if(l < range_low) 
      {
         range_low = l;
         Print("New range low: ", DoubleToString(range_low, _Digits), " at ", TimeToString(TimeCurrent()));
      }
   }
}

//+------------------------------------------------------------------+
//| Draw OR rectangle and reference lines                            |
//+------------------------------------------------------------------+
void DrawBox()
{
   if(box_drawn) return;
   
   long chart_id = 0;
   datetime t0 = current_session_start;
   datetime t1 = current_range_end;
   
   // Draw the rectangle for the opening range
   ObjectCreate(chart_id, box_name, OBJ_RECTANGLE, 0, t0, range_high, t1, range_low);
   
   // Set box color with opacity
   color box_color_with_opacity = BOX_COLOR;
   if(BOX_OPACITY < 255) 
   {
      // Simple way to apply opacity
      box_color_with_opacity = (color)((BOX_COLOR & 0xFFFFFF) | (BOX_OPACITY << 24));
   }
   
   ObjectSetInteger(chart_id, box_name, OBJPROP_COLOR, box_color_with_opacity);
   ObjectSetInteger(chart_id, box_name, OBJPROP_FILL, true);

   // Draw horizontal lines for range high and low
   ObjectCreate(chart_id, hl_name, OBJ_HLINE, 0, TimeCurrent(), range_high);
   ObjectSetInteger(chart_id, hl_name, OBJPROP_COLOR, 0x00FF00);  // Green
   ObjectSetInteger(chart_id, hl_name, OBJPROP_WIDTH, 2);
   ObjectSetString(chart_id, hl_name, OBJPROP_TEXT, "OR High: " + DoubleToString(range_high, _Digits));
   
   ObjectCreate(chart_id, ll_name, OBJ_HLINE, 0, TimeCurrent(), range_low);
   ObjectSetInteger(chart_id, ll_name, OBJPROP_COLOR, 0xFF0000);  // Red
   ObjectSetInteger(chart_id, ll_name, OBJPROP_WIDTH, 2);
   ObjectSetString(chart_id, ll_name, OBJPROP_TEXT, "OR Low: " + DoubleToString(range_low, _Digits));

   // Add buffer zones to the chart to show entry thresholds
   string up_buffer_name = "ORB_UP_BUFFER";
   string dn_buffer_name = "ORB_DN_BUFFER";
   
   // Calculate buffer using ATR
   double buffer_points = atr_value * ATR_BUFFER_MULT;
   
   ObjectCreate(chart_id, up_buffer_name, OBJ_HLINE, 0, TimeCurrent(), range_high + buffer_points);
   ObjectSetInteger(chart_id, up_buffer_name, OBJPROP_COLOR, 0x00AAFF);  // Light Blue
   ObjectSetInteger(chart_id, up_buffer_name, OBJPROP_STYLE, STYLE_DASH);
   ObjectSetString(chart_id, up_buffer_name, OBJPROP_TEXT, "Buy Entry: " + DoubleToString(range_high + buffer_points, _Digits));
   
   ObjectCreate(chart_id, dn_buffer_name, OBJ_HLINE, 0, TimeCurrent(), range_low - buffer_points);
   ObjectSetInteger(chart_id, dn_buffer_name, OBJPROP_COLOR, 0xFFAA00);  // Light Red
   ObjectSetInteger(chart_id, dn_buffer_name, OBJPROP_STYLE, STYLE_DASH);
   ObjectSetString(chart_id, dn_buffer_name, OBJPROP_TEXT, "Sell Entry: " + DoubleToString(range_low - buffer_points, _Digits));
   
   // Add vertical lines to mark OR start/end
   string start_vline = "ORB_START";
   string end_vline = "ORB_END";
   
   ObjectCreate(chart_id, start_vline, OBJ_VLINE, 0, current_session_start, 0);
   ObjectSetInteger(chart_id, start_vline, OBJPROP_COLOR, 0x0000FF);  // Blue
   ObjectSetInteger(chart_id, start_vline, OBJPROP_STYLE, STYLE_DOT);
   ObjectSetString(chart_id, start_vline, OBJPROP_TEXT, "ORB Start");
   
   ObjectCreate(chart_id, end_vline, OBJ_VLINE, 0, current_range_end, 0);
   ObjectSetInteger(chart_id, end_vline, OBJPROP_COLOR, 0x0000FF);  // Blue
   ObjectSetInteger(chart_id, end_vline, OBJPROP_STYLE, STYLE_DOT);
   ObjectSetString(chart_id, end_vline, OBJPROP_TEXT, "ORB End");

   box_drawn = true;
}

//+------------------------------------------------------------------+
//| Check for breakout & send order                                  |
//+------------------------------------------------------------------+
void CheckBreakout()
{
   // Only allow specified number of trades per day 
   if(trades_today >= MAX_TRADES_PER_DAY)
   {
      Print("Max trades per day reached: ", trades_today);
      return;
   }
   
   if(ticket != 0) return;  // already in a position
   
   // Skip if volatility filter is enabled and not passed
   if(USE_VOLATILITY_FILTER && !volatility_ok)
   {
      if(debug_level >= 1)
      {
         Print("Skipping breakout check - volatility filter not passed");
      }
      return;
   }
   
   // Get current price data
   double close = GetLastBarClose();
   if(close == 0) return; // Error getting price data
   
   // Calculate breakout levels
   double buffer_points = atr_value * ATR_BUFFER_MULT;
   double bull_breakout_level = range_high + buffer_points;
   double bear_breakout_level = range_low - buffer_points;
   
   LogBreakoutLevels(close, buffer_points, bull_breakout_level, bear_breakout_level);
   
   // Check for bullish breakout
   if(close >= bull_breakout_level)
   {
      ProcessBullishBreakout(close, buffer_points);
   }
   // Check for bearish breakout
   else if(close <= bear_breakout_level)
   {
      ProcessBearishBreakout(close, buffer_points);
   }
   else
   {
      ResetBreakoutCounters();
   }
}

//+------------------------------------------------------------------+
//| Get the close price of the last completed bar                    |
//+------------------------------------------------------------------+
double GetLastBarClose()
{
   double close[1];
   if(CopyClose(_Symbol, PERIOD_M15, 1, 1, close) <= 0)
   {
      Print("Error getting close price for breakout check");
      return 0;
   }
   return close[0];
}

//+------------------------------------------------------------------+
//| Log breakout levels and current price                            |
//+------------------------------------------------------------------+
void LogBreakoutLevels(double close, double buffer_points, double bull_level, double bear_level)
{
   Print("Using ATR buffer: ", DoubleToString(buffer_points, _Digits),
         " (ATR=", DoubleToString(atr_value, _Digits), 
         " x ", DoubleToString(ATR_BUFFER_MULT, 2), ")");
   
   Print("BREAKOUT CHECK at ", TimeToString(TimeCurrent()));
   Print("  Bar close: ", DoubleToString(close, _Digits));
   Print("  Range high: ", DoubleToString(range_high, _Digits), 
         ", with buffer: ", DoubleToString(bull_level, _Digits));
   Print("  Range low: ", DoubleToString(range_low, _Digits), 
         ", with buffer: ", DoubleToString(bear_level, _Digits));
}

//+------------------------------------------------------------------+
//| Process bullish breakout                                         |
//+------------------------------------------------------------------+
void ProcessBullishBreakout(double close, double buffer_points)
{
   bull_breakout_count++;
   bear_breakout_count = 0; // Reset bear count on bullish candle
   
   Print("BULLISH BREAKOUT CANDLE: ", bull_breakout_count, "/", CONFIRMATION_CANDLES, 
         " | Close ", DoubleToString(close, _Digits), 
         " > Range high ", DoubleToString(range_high, _Digits), 
         " + Buffer ", DoubleToString(buffer_points, _Digits));
   
   // Only execute trade after enough confirmation candles
   if(bull_breakout_count >= CONFIRMATION_CANDLES)
   {
      Print("CONFIRMED BULL BREAKOUT AFTER ", bull_breakout_count, " CANDLES - EXECUTING BUY");
      SendOrder(ORDER_TYPE_BUY);
      bull_breakout_count = 0; // Reset counter after trade
   }
}

//+------------------------------------------------------------------+
//| Process bearish breakout                                         |
//+------------------------------------------------------------------+
void ProcessBearishBreakout(double close, double buffer_points)
{
   bear_breakout_count++;
   bull_breakout_count = 0; // Reset bull count on bearish candle
   
   Print("BEARISH BREAKOUT CANDLE: ", bear_breakout_count, "/", CONFIRMATION_CANDLES,
         " | Close ", DoubleToString(close, _Digits), 
         " < Range low ", DoubleToString(range_low, _Digits), 
         " - Buffer ", DoubleToString(buffer_points, _Digits));
   
   // Only execute trade after enough confirmation candles
   if(bear_breakout_count >= CONFIRMATION_CANDLES)
   {
      Print("CONFIRMED BEAR BREAKOUT AFTER ", bear_breakout_count, " CANDLES - EXECUTING SELL");
      SendOrder(ORDER_TYPE_SELL);
      bear_breakout_count = 0; // Reset counter after trade
   }
}

//+------------------------------------------------------------------+
//| Reset breakout counters when no breakout is detected             |
//+------------------------------------------------------------------+
void ResetBreakoutCounters()
{
   // No breakout - reset both counters
   if(bull_breakout_count > 0 || bear_breakout_count > 0)
   {
      Print("No breakout continuation - resetting confirmation counters");
      bull_breakout_count = 0;
      bear_breakout_count = 0;
   }
   else
   {
      Print("No breakout detected - price within range");
   }
}

//+------------------------------------------------------------------+
//| Calculate SL/TP + risk-based lot and execute                     |
//+------------------------------------------------------------------+
void SendOrder(ENUM_ORDER_TYPE type)
{
   // Entry price
   double entry = (type==ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                         : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   // Calculate buffer using ATR
   double buffer_points = atr_value * ATR_BUFFER_MULT;
   
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
   req.deviation = MAX_DEVIATION_POINTS;
   req.magic = 777777;
   req.comment = "NY_ORB";
   
   // Set a filling mode that should work with most brokers
   if((filling_mode & SYMBOL_FILLING_FOK) != 0)
      req.type_filling = ORDER_FILLING_FOK;
   else if((filling_mode & SYMBOL_FILLING_IOC) != 0)
      req.type_filling = ORDER_FILLING_IOC;
   else
      req.type_filling = ORDER_FILLING_RETURN; // Try this as a fallback
   
   Print("Using filling mode: ", req.type_filling);

   bool result = OrderSend(req, res);
   if(!result || res.retcode != 10009)  // 10009 is TRADE_RETCODE_DONE constant
   { 
      string direction = (type==ORDER_TYPE_BUY) ? "buy" : "sell";
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
   
   string direction = (type==ORDER_TYPE_BUY) ? "LONG" : "SHORT";
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
   
   switch(STOP_LOSS_STRATEGY)
   {
      case SL_OUTER: // Opposite side of the range
         sl = (type==ORDER_TYPE_BUY) ? range_low : range_high;
         Print("Using OUTER stop loss strategy - SL at opposite boundary");
         break;
         
      case SL_MIDDLE: // Middle of the range
         sl = (type==ORDER_TYPE_BUY) ? range_low + (range_size * 0.5)
                                     : range_high - (range_size * 0.5);
         Print("Using MIDDLE stop loss strategy - SL at mid-range");
         break;
         
      case SL_CLOSE: // Close to breakout point
         sl = (type==ORDER_TYPE_BUY) ? range_high : range_low;
         Print("Using CLOSE stop loss strategy - SL near breakout point");
         break;
         
      default: // Fallback to outer (safest)
         sl = (type==ORDER_TYPE_BUY) ? range_low : range_high;
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
   double tp = (type==ORDER_TYPE_BUY) ? entry_price + range_size * RANGE_MULT
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
   // Lot sizing based on risk percentage
   double tick_val = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double risk_amt = AccountInfoDouble(ACCOUNT_EQUITY) * RISK_PER_TRADE_PCT / 100.0;
   double sl_dist_pts = MathAbs(entry_price - stop_loss) / _Point;
   double lots = risk_amt / ((sl_dist_pts * _Point / tick_size) * tick_val);
   
   // Normalize to broker's lot step
   lots = NormalizeDouble(lots/lot_step, 0) * lot_step;
   // Ensure minimum lot size
   lots = MathMax(lot_min, lots);
   
   Print("Lot size calculation:");
   Print("  Account equity: ", DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2));
   Print("  Risk amount: ", DoubleToString(risk_amt, 2));
   Print("  Stop loss distance: ", DoubleToString(sl_dist_pts, 1), " points");
   Print("  Calculated lots: ", DoubleToString(lots, 2));
   
   return lots;
}

//+------------------------------------------------------------------+
//| Get error description                                            |
//+------------------------------------------------------------------+
string GetErrorDescription(int error_code)
{
   string error_string;

   switch(error_code)
   {
      case 10004: error_string = "Requote"; break;
      case 10006: error_string = "Request rejected"; break;
      case 10007: error_string = "Request canceled by trader"; break;
      case 10008: error_string = "Order placed"; break;
      case 10009: error_string = "Request executed"; break;
      case 10010: error_string = "Request executed partially"; break;
      case 10011: error_string = "Request error"; break;
      case 10013: error_string = "Error trade disabled"; break;
      case 10014: error_string = "No changes in request"; break;
      case 10015: error_string = "AutoTrading disabled"; break;
      case 10016: error_string = "Broker busy"; break;
      case 10017: error_string = "Invalid price"; break;
      case 10018: error_string = "Invalid stops"; break;
      case 10019: error_string = "Trade not allowed"; break;
      case 10020: error_string = "Trade timeout"; break;
      case 10021: error_string = "Invalid volume"; break;
      case 10022: error_string = "Market closed"; break;
      case 10026: error_string = "Order change denied"; break;
      case 10027: error_string = "Trading timeout"; break;
      case 10028: error_string = "Transaction canceled"; break;
      case 10029: error_string = "No connect to trade server"; break;
      case 10030: error_string = "Unsupported filling mode"; break;
      case 10031: error_string = "No connection/Invalid account"; break;
      case 10032: error_string = "Too many requests"; break;
      case 10033: error_string = "Trade is disabled for symbol"; break;
      case 10034: error_string = "Invalid order ticket"; break;
      default: error_string = "Unknown error " + IntegerToString(error_code);
   }
   
   return error_string;
}

//+------------------------------------------------------------------+
//| Manage open position  (time exit at session end)                 |
//+------------------------------------------------------------------+
void ManagePos()
{
   // Check if position still exists
   if(!PositionSelectByTicket(ticket))
   { 
      trade_state = STATE_RANGE_LOCKED; 
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
   
   // Only force close position if:
   // 1. We're after session end AND
   // 2. Either ALLOW_TP_AFTER_HOURS is false OR we're approaching next session start
   
   bool force_close = false;
   
   if(current_time >= current_session_end)
   {
      if(!ALLOW_TP_AFTER_HOURS)
      {
         // Standard behavior - close at session end
         force_close = true;
         Print("Position being closed at session end - after-hours TP not enabled");
      }
      else
      {
         // After-hours TP is enabled - check if we're approaching next session
         // Simple and clear check using the explicit next_session_start variable
         if(current_time >= next_session_start - 1800) // Within 30 minutes of next session
         {
            force_close = true;
            Print("Position will be closed now as we're within 15 minutes of next session (",
                  TimeToString(next_session_start), "), remaining time: ", 
                  (int)((next_session_start - current_time) / 60), " minutes");
         }
         else
         {
            // Still allowed to run to TP
            int hours_until_next = (int)((next_session_start - current_time) / 3600);
            int mins_until_next = (int)(((next_session_start - current_time) % 3600) / 60);
            Print("Position allowed to continue after hours (until TP or next session in ", 
                  hours_until_next, "h ", mins_until_next, "m)");
         }
      }
   }
   
   // Force close if needed
   if(force_close)
   {
      ClosePos();
      string close_reason = ALLOW_TP_AFTER_HOURS ? "before next session start" : "at session end";
      Print("Position closed ", close_reason, " (", TimeToString(current_time), ")");
   }
}

//+------------------------------------------------------------------+
//| Close position                                                   |
//+------------------------------------------------------------------+
void ClosePos()
{
   if(!PositionSelectByTicket(ticket)) return;
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
   req.deviation = MAX_DEVIATION_POINTS;
   req.magic = 777777;
   
   // Get the available filling modes for this symbol
   int filling_mode = (int)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   
   // Set a filling mode that should work with most brokers
   if((filling_mode & SYMBOL_FILLING_FOK) != 0)
      req.type_filling = ORDER_FILLING_FOK;
   else if((filling_mode & SYMBOL_FILLING_IOC) != 0)
      req.type_filling = ORDER_FILLING_IOC;
   else
      req.type_filling = ORDER_FILLING_RETURN; // Try this as a fallback

   bool result = OrderSend(req, res);
   if(!result || res.retcode != 10009)  // 10009 is TRADE_RETCODE_DONE constant
   {
      string direction = (req.type == ORDER_TYPE_BUY) ? "buy" : "sell";
      Print("Close position failed: ", res.retcode, " [", GetErrorDescription(res.retcode), "]");
      return;
   }
   
   ticket = 0;
   trade_state = STATE_RANGE_LOCKED;
   Print("Position closed at ", TimeToString(TimeCurrent()));
}

//+------------------------------------------------------------------+
//| Chart label                                                      |
//+------------------------------------------------------------------+
void ShowLabel()
{
   string status;
   
   switch(trade_state)
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
            if(PositionSelectByTicket(ticket))
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
      default:
         status = "Unknown state";
   }
   
   // Get session details based on session type
   string session_type_str = (SESSION_TYPE == CLASSIC_NYSE) ? "NYSE Open (9:30 NY)" : "Early US (8:00 NY)";
   
   // Format buffer info
   string buffer_info = "ATR(" + IntegerToString(ATR_PERIOD) + ") × " + DoubleToString(ATR_BUFFER_MULT, 1);
   
   // Format take profit info
   string tp_info = "Range " + DoubleToString(RANGE_MULT, 1) + "×Size";
   
   // Format session time info
   string session_time_info = TimeToString(current_session_start, TIME_MINUTES) + 
                             " - " + TimeToString(current_session_end, TIME_MINUTES);
   
   // Format volatility filter info
   string vol_filter = USE_VOLATILITY_FILTER ? 
                     (volatility_ok ? "Passed ✓" : "Failed ✗") : 
                     "Disabled";
   
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
      vol_filter
   );
   
   Comment(txt);
}

//+------------------------------------------------------------------+
//| Calculate ATR and median ATR                                     |
//+------------------------------------------------------------------+
void UpdateATR()
{
   // Calculate current ATR value
   int atr_handle = iATR(_Symbol, _Period, ATR_PERIOD);
   double atr_buff[];
   
   if(CopyBuffer(atr_handle, 0, 0, 2, atr_buff) <= 0)
   { 
      Print("ATR error: ", GetLastError()); 
      return; 
   }
   
   // Get current ATR value (from previous completed bar)
   atr_value = atr_buff[1];
   
   // Calculate median ATR if we don't have it yet
   if(atr_median <= 0 && USE_VOLATILITY_FILTER)
   {
      // For median calculation we need a longer ATR history
      int bars_needed = ATR_MEDIAN_DAYS * 24;  // Approximately ATR_MEDIAN_DAYS days of data
      
      // Make sure we don't request more bars than available
      int available_bars = Bars(_Symbol, _Period);
      if(bars_needed > available_bars)
         bars_needed = available_bars;
         
      // Get ATR values for the period
      ArrayResize(atr_history, bars_needed);
      
      if(CopyBuffer(atr_handle, 0, 0, bars_needed, atr_history) <= 0)
      { 
         Print("Error getting ATR history: ", GetLastError()); 
         return; 
      }
      
      // Sort the array to find median
      ArraySort(atr_history);
      
      // Median is the middle value (or average of the two middle values)
      int middle = bars_needed / 2;
      if(bars_needed % 2 == 0) // Even number of elements
         atr_median = (atr_history[middle-1] + atr_history[middle]) / 2.0;
      else // Odd number of elements
         atr_median = atr_history[middle];
      
      Print("ATR Median calculated from ", bars_needed, " bars: ", 
            DoubleToString(atr_median, _Digits));
      Print("ATR Threshold (", ATR_THRESHOLD_PCT, "%): ", 
            DoubleToString(atr_median * ATR_THRESHOLD_PCT / 100.0, _Digits));
   }
   
   if(debug_level >= 2 && MathMod(TimeCurrent(), 60) < 10) // Log every minute
   {
      Print("ATR(", ATR_PERIOD, "): ", DoubleToString(atr_value, _Digits),
            ", Median: ", DoubleToString(atr_median, _Digits),
            ", Threshold: ", DoubleToString(atr_median * ATR_THRESHOLD_PCT / 100.0, _Digits),
            ", Filter passed: ", volatility_ok ? "Yes" : "No");
   }
}

//+------------------------------------------------------------------+
//| Check if today is a NYSE holiday or early close                  |
//+------------------------------------------------------------------+
bool IsNYSEHoliday(datetime t)
{
   MqlDateTime dt;
   TimeToStruct(t, dt);
   int y = dt.year, m = dt.mon, d = dt.day;
   int wd = dt.day_of_week; // 0=Sunday, 1=Monday, ...

   // Always skip weekends
   if (wd == 0 || wd == 6) return true;

   // 2025 NYSE Full Closures
   if (y == 2025)
   {
      if ((m==1 && d==1)   // New Year's Day (Wed)
       || (m==1 && d==20)  // MLK Jr. Day (Mon)
       || (m==2 && d==17)  // Presidents' Day (Mon)
       || (m==4 && d==18)  // Good Friday (Fri)
       || (m==5 && d==26)  // Memorial Day (Mon)
       || (m==6 && d==19)  // Juneteenth (Thu)
       || (m==7 && d==4)   // Independence Day (Fri)
       || (m==9 && d==1)   // Labor Day (Mon)
       || (m==11 && d==27) // Thanksgiving (Thu)
       || (m==12 && d==25) // Christmas (Thu)
      ) return true;

      // Early Closures (1:00 p.m. ET)
      if ((m==7 && d==3)   // Day before Independence Day (Thu)
       || (m==11 && d==28) // Day after Thanksgiving (Fri)
       || (m==12 && d==24) // Christmas Eve (Wed)
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
