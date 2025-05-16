//+------------------------------------------------------------------+
//|           New-York ORB EA - auto-DST version (15-minute)         |
//|   Handles PU Prime server UTC+2/UTC+3 and NY EST/EDT shift       |
//|               Copyright 2025 - free to use / modify              |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025"
#property version   "1.10"
#property strict

//---------------  USER-TWEAKABLE INPUTS  ---------------------------//
// 1) Session - NYT 08:00 to 15:00 (SRV 15:00 to 22:00)
input int      SESSION_OR_MINUTES   = 15;    // Opening-range length (15 minutes)
input int      SESSION_TOTAL_HOURS  = 7;     // Session duration (default 7h = 15:00-22:00 SRV)

// 2) Breakout / risk
input double   BREAK_BUFFER_PIPS    = 2.0;   // Confirm break beyond box (1-5 pips)
input double   SL_ATR_MULT          = 0.5;   // 0 = opposite side of box, >0 = ATR×mult
input double   TP_RR_MULT           = 2.0;   // Take-profit multiple (SL×this)

// 3) Money-management
input double   RISK_PER_TRADE_PCT   = 1.0;   // % equity risk
input int      MAX_TRADES_PER_DAY   = 1;     // Safety cap (default = 1 trade/day)
input double   LOT_MIN              = 0.01;  // Minimum lot size
input double   LOT_STEP             = 0.01;  // Lot step size

// 4) Visuals
input color    BOX_COLOR            = 0x0000FF;  // Blue
input uchar    BOX_OPACITY          = 20;        // Box opacity (0-255)
input bool     LABEL_STATS          = true;      // Show info label

//---------------  INTERNAL STATE  ---------------------------//
enum TradeState { STATE_IDLE, STATE_BUILDING_RANGE, STATE_RANGE_LOCKED, STATE_IN_POSITION };
TradeState      trade_state    = STATE_IDLE;

datetime        session_start, session_end;
double          range_high     = -DBL_MAX;
double          range_low      =  DBL_MAX;
bool            box_drawn      = false;
string          box_name       = "ORB_BOX", hl_name="ORB_HI", ll_name="ORB_LO";

ulong           ticket         = 0;
int             trades_today   = 0;
int             stored_day     = -1;

//+------------------------------------------------------------------+
//| Helper: midnight of a date                                       |
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

//+------------------------------------------------------------------+
//| Helper: is this timestamp within US/NY DST?                      |
//+------------------------------------------------------------------+
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
//| Build today's NY session window (server time)                    |
//+------------------------------------------------------------------+
void ComputeSession()
{
   // PU Prime server is always 7 hours ahead of NY time, regardless of DST
   // NY 08:00 = Server 15:00
   // NY 15:00 = Server 22:00
   
   // Calculate session times using fixed 7-hour offset
   datetime today_mid = DateOfDay(TimeCurrent());        // Midnight today
   session_start = today_mid + 15 * 3600;                // 15:00 server time (8:00 NY)
   session_end   = today_mid + 22 * 3600;                // 22:00 server time (15:00 NY)
   
   datetime now = TimeCurrent();
   
   // Check if today's session is already past
   if(now > session_end)
   {
      // If it's already past today's session, set up for tomorrow
      Print("Current time ", TimeToString(now), " is past today's session end ", 
            TimeToString(session_end), ". Setting up for tomorrow's session.");
      session_start += 86400;  // Add one day
      session_end   += 86400;
   }
   // If current time is more than 1 hour before session start,
   // keep the session for today (this is fine even if it's early morning)
   else if(now < session_start - 3600)
   {
      Print("Current time ", TimeToString(now), " is more than 1 hour before session start ", 
            TimeToString(session_start), ". Using today's session window.");
   }
   else
   {
      Print("Current time ", TimeToString(now), " is within reasonable range of session window ", 
            TimeToString(session_start), " to ", TimeToString(session_end));
   }
   
   // For logging only - calculate the actual offsets
   int ny_offset = IsNYDST(TimeCurrent()) ? -4 : -5;   // EDT(-4) in summer, EST(-5) in winter
   int srv_offset = (int)((TimeCurrent() - TimeGMT()) / 3600);  // Current server offset
   
   Print("Session window calculated: ", TimeToString(session_start), " to ", 
         TimeToString(session_end), " (current server UTC offset: ", srv_offset, 
         ", NY offset: ", ny_offset, ", using fixed 7h gap)");
}

//+------------------------------------------------------------------+
//| Expert init                                                      |
//+------------------------------------------------------------------+
int OnInit()
{
   if(_Period != PERIOD_M15)
   {
      Print("Attach to a 15-minute chart.");
      return(INIT_FAILED);
   }
   
   // Reset for new trading day
   ResetDay();
   
   Print("ORB Strategy initialized. Looking for breakouts during NY session.");
   Print("Session time: 08:00-15:00 NYT (15:00-22:00 server time)");
   Print("Range formation: First ", SESSION_OR_MINUTES, " minutes after session open");
   Print("Only ", MAX_TRADES_PER_DAY, " trade(s) per day will be taken");
   
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
   datetime today_mid = DateOfDay(current_time);
   datetime today_session_start = today_mid + 15 * 3600;  // 15:00 server time
   
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
   
   // EXTREME DEBUG OUTPUT - Check if we're in between midnight and session start
   static datetime last_tick_debug = 0;
   if(current_time - last_tick_debug > 3600) // Log once an hour
   {
      Print("DEBUG Tick received at ", TimeToString(current_time), 
            " | Day: ", dt.day, 
            " | Session window: ", TimeToString(session_start), " to ", 
            TimeToString(session_end),
            " | State: ", GetStateString(trade_state));
      
      // Print next 24 hours of session windows for debugging
      datetime test_time = current_time;
      for (int i = 0; i < 3; i++)
      {
         test_time += 86400; // Add one day
         MqlDateTime test_dt;
         TimeToStruct(test_time, test_dt);
         datetime test_midnight = DateOfDay(test_time);
         datetime test_session_start = test_midnight + 15 * 3600;  
         datetime test_session_end = test_midnight + 22 * 3600;
         Print("Future session window ", i+1, ": ", TimeToString(test_session_start), 
               " to ", TimeToString(test_session_end));
      }
      last_tick_debug = current_time;
   }
   
   // Debug output at the start of each trading session
   static datetime last_session_day = 0;
   datetime today = DateOfDay(current_time);
   if(today != last_session_day && current_time >= session_start && current_time <= session_end)
   {
      Print("TRADING SESSION STARTED: ", TimeToString(current_time), 
            " is within session window (", TimeToString(session_start), 
            " to ", TimeToString(session_end), ")");
      last_session_day = today;
   }

   // Ignore ticks outside trading window (15:00-22:00 SRV time)
   if(current_time < session_start || current_time > session_end)
   {
      // No need to spam the logs with this message
      if(trade_state != STATE_IDLE && 
         (last_tick_debug == current_time || trade_state == STATE_BUILDING_RANGE || trade_state == STATE_RANGE_LOCKED))
      {
         Print("Outside of session window now. Going idle. Time: ", 
               TimeToString(current_time), ", Session: ", 
               TimeToString(session_start), " - ", TimeToString(session_end), 
               ", Current state: ", GetStateString(trade_state));
         trade_state = STATE_IDLE;
      }
      return;
   }
   else
   {
      // Log when we detect we're inside the session window
      static datetime last_in_session_log = 0;
      if(current_time - last_in_session_log > 3600) // Once per hour
      {
         Print("INSIDE SESSION WINDOW at ", TimeToString(current_time), 
               ", Session: ", TimeToString(session_start), " - ", 
               TimeToString(session_end),
               ", Current state: ", GetStateString(trade_state));
         last_in_session_log = current_time;
         
         // Debug print current prices
         double close[1];
         if(CopyClose(_Symbol, PERIOD_M15, 1, 1, close) > 0)
         {
            Print("Current close price: ", DoubleToString(close[0], _Digits));
         }
      }
   }
      
   // State machine for ORB strategy
   switch(trade_state)
   {
      case STATE_IDLE:
         // Check if within the opening range formation time (first 15 min)
         if(current_time >= session_start && current_time < session_start + SESSION_OR_MINUTES*60)
         {
            trade_state = STATE_BUILDING_RANGE;
            Print("BUILDING RANGE STARTED at ", TimeToString(current_time), 
                  ", Window: ", TimeToString(session_start), " to ", 
                  TimeToString(session_start + SESSION_OR_MINUTES*60));
            
            // Initial range reset
            range_high = -1000000;
            range_low = 1000000;
            
            // Process the first bar immediately
            UpdateRange();
         }
         break;

      case STATE_BUILDING_RANGE:
         // Track high/low during opening range period
         UpdateRange();
         
         // When opening range period ends, lock the range
         if(current_time >= session_start + SESSION_OR_MINUTES*60)
         {
            trade_state = STATE_RANGE_LOCKED;
            DrawBox();
            PrintFormat("Range locked at %s. High=%s, Low=%s, Width=%s points", 
                       TimeToString(current_time),
                       DoubleToString(range_high, _Digits), 
                       DoubleToString(range_low, _Digits),
                       DoubleToString((range_high-range_low)/_Point, 0));
                       
            // Check for breakout immediately after range is locked
            if(IsNewBar())
            {
               CheckBreakout();
            }
         }
         break;

      case STATE_RANGE_LOCKED:
         // Only check for breakouts after the bar closes
         // to avoid false signals from intra-bar wicks
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
            ", session window: ", TimeToString(session_start), " to ", TimeToString(session_end),
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
   
   box_drawn    = false;
   ObjectsDeleteAll(0, box_name);
   ObjectsDeleteAll(0, hl_name);
   ObjectsDeleteAll(0, ll_name);
   
   Print("New day reset: ", TimeToString(TimeCurrent()));
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
   
   long chart_id=0;
   datetime t0 = session_start;
   datetime t1 = session_start + SESSION_OR_MINUTES*60;
   
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
   ObjectCreate(chart_id, ll_name, OBJ_HLINE, 0, TimeCurrent(), range_low);
   ObjectSetInteger(chart_id, ll_name, OBJPROP_COLOR, 0xFF0000);  // Red

   // Add buffer zones to the chart to show entry thresholds
   string up_buffer_name = "ORB_UP_BUFFER";
   string dn_buffer_name = "ORB_DN_BUFFER";
   double buffer_points = BREAK_BUFFER_PIPS*_Point*10;
   
   ObjectCreate(chart_id, up_buffer_name, OBJ_HLINE, 0, TimeCurrent(), range_high + buffer_points);
   ObjectSetInteger(chart_id, up_buffer_name, OBJPROP_COLOR, 0x00AAFF);  // Light Blue
   ObjectSetInteger(chart_id, up_buffer_name, OBJPROP_STYLE, STYLE_DASH);
   
   ObjectCreate(chart_id, dn_buffer_name, OBJ_HLINE, 0, TimeCurrent(), range_low - buffer_points);
   ObjectSetInteger(chart_id, dn_buffer_name, OBJPROP_COLOR, 0xFFAA00);  // Light Red
   ObjectSetInteger(chart_id, dn_buffer_name, OBJPROP_STYLE, STYLE_DASH);
   
   box_drawn = true;
}

//+------------------------------------------------------------------+
//| Check for breakout & send order                                  |
//+------------------------------------------------------------------+
void CheckBreakout()
{
   // Only allow specified number of trades per day (default=1)
   if(trades_today >= MAX_TRADES_PER_DAY)
   {
      Print("Max trades per day reached: ", trades_today);
      return;
   }
   
   if(ticket != 0) return;  // already in a position
   
   // Get current price data
   double close[1];
   if(CopyClose(_Symbol, PERIOD_M15, 1, 1, close) <= 0)
   {
      Print("Error getting close price for breakout check");
      return;
   }
   
   // Current market prices
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   // Breakout threshold with buffer (configured in pips)
   double buffer_points = BREAK_BUFFER_PIPS*_Point*10;
   
   // Detailed breakout analysis
   Print("BREAKOUT CHECK at ", TimeToString(TimeCurrent()));
   Print("  Bar close: ", DoubleToString(close[0], _Digits));
   Print("  Range high: ", DoubleToString(range_high, _Digits), ", with buffer: ", DoubleToString(range_high + buffer_points, _Digits));
   Print("  Range low: ", DoubleToString(range_low, _Digits), ", with buffer: ", DoubleToString(range_low - buffer_points, _Digits));
   
   // Long entry: previous bar closed above the range high + buffer
   if(close[0] >= range_high + buffer_points)
   {
      Print("BREAKOUT UP: Close ", DoubleToString(close[0], _Digits), 
            " > Range high ", DoubleToString(range_high, _Digits), 
            " + Buffer ", DoubleToString(buffer_points, _Digits));
      SendOrder(ORDER_TYPE_BUY);
   }
   // Short entry: previous bar closed below the range low - buffer
   else if(close[0] <= range_low - buffer_points)
   {
      Print("BREAKOUT DOWN: Close ", DoubleToString(close[0], _Digits), 
            " < Range low ", DoubleToString(range_low, _Digits), 
            " - Buffer ", DoubleToString(buffer_points, _Digits));
      SendOrder(ORDER_TYPE_SELL);
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
   // Calculate ATR for dynamic SL option
   int atr_handle = iATR(_Symbol, PERIOD_M15, 14);
   double atr_buff[];
   if(CopyBuffer(atr_handle, 0, 1, 1, atr_buff) <= 0)
   { 
      Print("ATR error"); 
      return; 
   }
   double atr = atr_buff[0];
   
   // Entry price
   double entry = (type==ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                         : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   // Stop Loss calculation - either based on ATR or opposite side of box
   double sl = 0.0;
   double buffer_points = BREAK_BUFFER_PIPS*_Point*10;
   
   if(SL_ATR_MULT > 0.0)
   {
      // ATR-based stop loss
      sl = (type==ORDER_TYPE_BUY) ? entry - atr*SL_ATR_MULT
                                  : entry + atr*SL_ATR_MULT;
      Print("Using ATR-based SL: ", DoubleToString(sl, _Digits), 
            " (ATR=", DoubleToString(atr, _Digits), 
            ", mult=", DoubleToString(SL_ATR_MULT, 2), ")");
   }
   else
   {
      // Box-based stop loss (default ORB method)
      sl = (type==ORDER_TYPE_BUY) ? range_low - buffer_points
                                  : range_high + buffer_points;
      Print("Using box-based SL: ", DoubleToString(sl, _Digits));
   }

   // Calculate SL distance and Take Profit level
   double sl_dist = MathAbs(entry - sl);
   double tp = (TP_RR_MULT > 0.0) ? (type==ORDER_TYPE_BUY ? entry + sl_dist*TP_RR_MULT
                                                          : entry - sl_dist*TP_RR_MULT)
                                  : 0.0;

   // Lot sizing based on risk percentage
   double tick_val = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size= SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double risk_amt = AccountInfoDouble(ACCOUNT_EQUITY)*RISK_PER_TRADE_PCT/100.0;
   double lots = risk_amt / ((sl_dist/tick_size)*tick_val);
   lots = NormalizeDouble(lots/LOT_STEP, 0)*LOT_STEP;
   lots = MathMax(LOT_MIN, lots);

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
   req.deviation = 20;
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
      ticket=0; 
      return; 
   }

   // Force close at session end (15:00 NY / 22:00 SRV)
   if(TimeCurrent() >= session_end)
   {
      ClosePos();
      Print("Position closed at session end (15:00 NYT / 22:00 SRV)");
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
   req.deviation = 20;
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
   
   string txt = StringFormat(
      "NY ORB EA | Trades: %d/%d | State: %s\n"
      "NY Time: 08:00-15:00 | Server Time: 15:00-22:00\n"
      "Session: %s - %s | Range: %s - %s",
      trades_today, 
      MAX_TRADES_PER_DAY,
      status,
      TimeToString(session_start, TIME_MINUTES),
      TimeToString(session_end, TIME_MINUTES),
      DoubleToString(range_low, _Digits),
      DoubleToString(range_high, _Digits)
   );
   
   Comment(txt);
}
//+------------------------------------------------------------------+
