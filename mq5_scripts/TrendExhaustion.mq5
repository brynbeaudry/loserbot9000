//+------------------------------------------------------------------+
//|                        %R Trend Exhaustion Strategy             |
//|                   Williams %R Dual Period Strategy              |
//|               Copyright 2025 - free to use / modify             |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025"
#property version "1.00"
#property strict

//+------------------------------------------------------------------+
//|                         STRATEGY DESCRIPTION                     |
//+------------------------------------------------------------------+
// Based on "upslidedown" Pine Script %R Trend Exhaustion strategy
// Uses dual Williams %R periods (Fast: 21, Slow: 112) to detect trend exhaustion
// 
// SIGNAL LOGIC:
// - Overbought Zone: When both %R values >= -20 (near 0)
// - Oversold Zone: When both %R values <= -80 (near -100)
// - BEARISH Signal (▼): When price EXITS overbought zone (was OB, now not OB)
// - BULLISH Signal (▲): When price EXITS oversold zone (was OS, now not OS)
//
// The strategy trades reversals when trends are exhausted:
// - Long trades: Enter when oversold trend exhausts (bullish reversal)
// - Short trades: Enter when overbought trend exhausts (bearish reversal)
//
// Williams %R ranges from -100 (oversold) to 0 (overbought)
// This is opposite to RSI which uses 0-100 scale

//============================================================================
//                           USER SETTINGS
//============================================================================

// Risk Management
input double RISK_PERCENT = 1.0; // RISK_PERCENT: Risk per trade (% of account)
input double STOP_LOSS_PERCENT = 1.0; // STOP_LOSS_PERCENT: Stop loss distance (% from entry price)
input double REWARD_RATIO = 2.0; // REWARD_RATIO: Reward:Risk ratio (2.0 = 2:1)
input int MAX_DAILY_TRADES = 50; // MAX_DAILY_TRADES: Maximum trades per day

// %R Indicator Settings
input int FAST_PERIOD = 21;     // FAST_PERIOD: Fast Williams %R period
input int SLOW_PERIOD = 112;    // SLOW_PERIOD: Slow Williams %R period
input int THRESHOLD = 20;       // THRESHOLD: Exhaustion threshold (overbought/oversold zone size)
input int FAST_SMOOTHING = 7;   // FAST_SMOOTHING: Fast %R smoothing period
input int SLOW_SMOOTHING = 3;   // SLOW_SMOOTHING: Slow %R smoothing period

// Strategy Controls
input bool USE_AVERAGE_FORMULA = false; // USE_AVERAGE_FORMULA: Use average of both %R instead of dual condition
input double MIN_SIGNAL_COOLDOWN_MINUTES = 3.0; // MIN_SIGNAL_COOLDOWN_MINUTES: Minimum minutes between signals
input bool SHOW_INFO_PANEL = true;     // SHOW_INFO_PANEL: Show information panel on chart
input int DEBUG_LEVEL = 1;             // DEBUG_LEVEL: Debug verbosity level (0=none, 1=basic, 2=detailed)

//============================================================================
//                         GLOBAL VARIABLES
//============================================================================

// Indicator handles
int atr_handle = INVALID_HANDLE;

// Current market data
double price = 0;                    // Current price
double fast_r = 0, slow_r = 0;       // Williams %R values
double avg_r = 0;                    // Average %R (when using average formula)
double atr_value = 0;                // Current ATR value for arrow placement

// Strategy state
bool is_overbought = false;          // Current overbought state
bool is_oversold = false;            // Current oversold state
bool was_overbought = false;         // Previous overbought state
bool was_oversold = false;           // Previous oversold state

// Position tracking
ulong current_position_ticket = 0;
int daily_trade_count = 0;
datetime last_trade_date = 0;
datetime last_signal_time = 0;

// Visual elements tracking
datetime last_ob_zone_start = 0;     // Track overbought zone start
datetime last_os_zone_start = 0;     // Track oversold zone start
int signal_counter = 0;              // Counter for unique object names

// Trading direction enum
enum TrendDirection
{
   NO_TREND = 0,
   BULLISH_TREND = 1,
   BEARISH_TREND = 2
};

TrendDirection position_direction = NO_TREND;

//============================================================================
//                         INITIALIZATION
//============================================================================

int OnInit()
{
   Print("=== %R Trend Exhaustion Strategy Starting ===");

   // Validate symbol
   if (StringFind(_Symbol, "BTC") < 0)
      Print("WARNING: Designed for BTCUSD, running on: ", _Symbol);

   // Initialize ATR for visual arrow placement
   atr_handle = iATR(_Symbol, _Period, 14);
   if (atr_handle == INVALID_HANDLE)
   {
      Print("WARNING: Failed to create ATR indicator - arrow placement may be suboptimal");
   }

   // Reset counters
   ResetDailyTrades();

   // Initialize market data and set initial states
   if (UpdateMarketData())
   {
      AnalyzeRConditions();
      // Set initial states to prevent false signals on startup
      was_overbought = is_overbought;
      was_oversold = is_oversold;
      Print("Initial %R states - Overbought: ", is_overbought, ", Oversold: ", is_oversold);
   }

   // Clean up any existing visual objects from previous runs
   CleanupVisualObjects();

   Print("=== %R Trend Exhaustion Strategy INITIALIZED ===");
   Print("Timeframe: ", TimeframeToString(_Period));
   Print("Risk per trade: ", RISK_PERCENT, "%");
   Print("Stop loss: ", STOP_LOSS_PERCENT, "%");
   Print("Reward ratio: ", REWARD_RATIO, ":1");
   Print("Max daily trades: ", MAX_DAILY_TRADES);
   Print("--- %R Parameters ---");
   Print("Fast period: ", FAST_PERIOD);
   Print("Slow period: ", SLOW_PERIOD);
   Print("Threshold: ", THRESHOLD);
   Print("Fast smoothing: ", FAST_SMOOTHING);
   Print("Slow smoothing: ", SLOW_SMOOTHING);
   Print("--- Strategy Controls ---");
   Print("Use average formula: ", USE_AVERAGE_FORMULA ? "YES" : "NO");
   Print("Minimum signal cooldown: ", MIN_SIGNAL_COOLDOWN_MINUTES, " minutes");
   Print("--- Visual Elements ---");
   Print("Overbought zones: Red rectangles");
   Print("Oversold zones: Blue rectangles");
   Print("Sell signals: Red down arrows");
   Print("Buy signals: Blue up arrows");
   Print("==============================================");

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   // Clean up visual objects
   CleanupVisualObjects();
   
   // Release indicator handles
   if (atr_handle != INVALID_HANDLE)
      IndicatorRelease(atr_handle);
   
   Comment("");
   Print("%R Trend Exhaustion Strategy stopped");
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

   // Update market data and %R values
   if (!UpdateMarketData())
   {
      if (DEBUG_LEVEL >= 1)
         Print("Failed to update market data");
      return;
   }

   // Check if position still exists (could have been closed by SL/TP)
   if (current_position_ticket != 0)
   {
      if (!PositionSelectByTicket(current_position_ticket))
      {
         // Position was closed
         current_position_ticket = 0;
         position_direction = NO_TREND;
         if (DEBUG_LEVEL >= 1)
            Print("Position closed by SL/TP");
      }
   }

   // Store previous states
   was_overbought = is_overbought;
   was_oversold = is_oversold;

   // Analyze current %R conditions
   AnalyzeRConditions();

   // Check for trend exhaustion signals
   CheckTrendExhaustionSignals();

   // Update visual elements (zones and arrows)
   UpdateVisualElements();

   // Update display
   if (SHOW_INFO_PANEL)
      ShowInfoPanel();
}

//============================================================================
//                         MARKET DATA UPDATE AND %R CALCULATION
//============================================================================

bool UpdateMarketData()
{
   // Get current price
   price = (SymbolInfoDouble(_Symbol, SYMBOL_BID) + SymbolInfoDouble(_Symbol, SYMBOL_ASK)) / 2.0;

   // Get ATR value for arrow placement
   if (atr_handle != INVALID_HANDLE)
   {
      double atr_buffer[1];
      if (CopyBuffer(atr_handle, 0, 0, 1, atr_buffer) > 0)
         atr_value = atr_buffer[0];
      else
         atr_value = 0; // Fallback if ATR not available
   }

   // Calculate Williams %R values
   if (!CalculateWilliamsR())
      return false;

   return true;
}

bool CalculateWilliamsR()
{
   // Get fast %R
   double fast_highest = 0, fast_lowest = 0;
   if (!GetHighestLowest(FAST_PERIOD, fast_highest, fast_lowest))
      return false;
   
   // Williams %R Formula: 100 * (Close - Highest) / (Highest - Lowest)
   // This gives values from -100 (oversold) to 0 (overbought)
   if (fast_highest - fast_lowest > 0)
      fast_r = 100.0 * (price - fast_highest) / (fast_highest - fast_lowest);
   else
      fast_r = 0; // Default to neutral if no range
   
   // Get slow %R
   double slow_highest = 0, slow_lowest = 0;
   if (!GetHighestLowest(SLOW_PERIOD, slow_highest, slow_lowest))
      return false;
   
   if (slow_highest - slow_lowest > 0)
      slow_r = 100.0 * (price - slow_highest) / (slow_highest - slow_lowest);
   else
      slow_r = 0; // Default to neutral if no range

   // Apply smoothing if needed
   if (FAST_SMOOTHING > 1)
      fast_r = GetSmoothedValue(fast_r, FAST_SMOOTHING, "fast_r");
   
   if (SLOW_SMOOTHING > 1)
      slow_r = GetSmoothedValue(slow_r, SLOW_SMOOTHING, "slow_r");

   // Calculate average %R if using average formula
   if (USE_AVERAGE_FORMULA)
      avg_r = (fast_r + slow_r) / 2.0;

   return true;
}

bool GetHighestLowest(int period, double &highest, double &lowest)
{
   double high_array[], low_array[];
   
   if (CopyHigh(_Symbol, _Period, 0, period, high_array) <= 0 ||
       CopyLow(_Symbol, _Period, 0, period, low_array) <= 0)
      return false;
   
   highest = high_array[ArrayMaximum(high_array)];
   lowest = low_array[ArrayMinimum(low_array)];
   
   // Include current price in the range for real-time calculation
   if (price > highest) highest = price;
   if (price < lowest) lowest = price;
   
   return true;
}

double GetSmoothedValue(double current_value, int period, string identifier)
{
   // Simple EMA smoothing - in a real implementation you'd want proper EMA calculation
   static double prev_fast_r = 0;
   static double prev_slow_r = 0;
   
   double alpha = 2.0 / (period + 1.0);
   
   if (identifier == "fast_r")
   {
      if (prev_fast_r == 0) prev_fast_r = current_value;
      prev_fast_r = alpha * current_value + (1.0 - alpha) * prev_fast_r;
      return prev_fast_r;
   }
   else if (identifier == "slow_r")
   {
      if (prev_slow_r == 0) prev_slow_r = current_value;
      prev_slow_r = alpha * current_value + (1.0 - alpha) * prev_slow_r;
      return prev_slow_r;
   }
   
   return current_value;
}

//============================================================================
//                      %R CONDITIONS ANALYSIS
//============================================================================

void AnalyzeRConditions()
{
   if (USE_AVERAGE_FORMULA)
   {
      // Use average formula
      is_overbought = (avg_r >= -THRESHOLD);
      is_oversold = (avg_r <= (-100 + THRESHOLD));
   }
   else
   {
      // Standard dual %R logic (both must be in zone)
      is_overbought = (fast_r >= -THRESHOLD && slow_r >= -THRESHOLD);
      is_oversold = (fast_r <= (-100 + THRESHOLD) && slow_r <= (-100 + THRESHOLD));
   }
   
   // Debug output for %R analysis
   if (DEBUG_LEVEL >= 2)
   {
      static datetime last_debug_time = 0;
      if (TimeCurrent() - last_debug_time >= 60) // Print every 60 seconds
      {
         Print("=== %R ANALYSIS ===");
         Print("Fast %R: ", DoubleToString(fast_r, 2), " | Slow %R: ", DoubleToString(slow_r, 2));
         if (USE_AVERAGE_FORMULA)
            Print("Average %R: ", DoubleToString(avg_r, 2));
         Print("Threshold: ", THRESHOLD, " (OB >= -", THRESHOLD, ", OS <= -", (100-THRESHOLD), ")");
         Print("Is Overbought: ", is_overbought ? "YES" : "NO");
         Print("Is Oversold: ", is_oversold ? "YES" : "NO");
         Print("==================");
         last_debug_time = TimeCurrent();
      }
   }
}

//============================================================================
//                    TREND EXHAUSTION SIGNAL DETECTION
//============================================================================

void CheckTrendExhaustionSignals()
{
   // Detect trend exhaustion signals (reversal from OB/OS zones)
   bool ob_reversal = (!is_overbought && was_overbought); // Exit from overbought = bearish signal
   bool os_reversal = (!is_oversold && was_oversold);     // Exit from oversold = bullish signal

   // Debug signal detection
   if (DEBUG_LEVEL >= 2)
   {
      if (was_overbought && !is_overbought)
         Print("📊 OVERBOUGHT EXIT DETECTED: was_overbought=true, is_overbought=false");
      if (was_oversold && !is_oversold)
         Print("📊 OVERSOLD EXIT DETECTED: was_oversold=true, is_oversold=false");
   }

   // Execute trades based on signals
   if (ob_reversal)
   {
      if (DEBUG_LEVEL >= 1)
         Print("🔴 BEARISH SIGNAL: Overbought trend exhausted (exit from OB zone)");
      
      // Draw sell signal arrow above the current bar
      double arrow_price = price + (atr_value > 0 ? atr_value * 0.5 : price * 0.001);
      DrawSignalArrow(TimeCurrent(), arrow_price, false);
      
      ExecuteTrendExhaustionTrade(BEARISH_TREND, "Overbought Trend Exhausted ▼");
   }
   else if (os_reversal)
   {
      if (DEBUG_LEVEL >= 1)
         Print("🟢 BULLISH SIGNAL: Oversold trend exhausted (exit from OS zone)");
      
      // Draw buy signal arrow below the current bar
      double arrow_price = price - (atr_value > 0 ? atr_value * 0.5 : price * 0.001);
      DrawSignalArrow(TimeCurrent(), arrow_price, true);
      
      ExecuteTrendExhaustionTrade(BULLISH_TREND, "Oversold Trend Exhausted ▲");
   }
}

void ExecuteTrendExhaustionTrade(TrendDirection direction, string signal_description)
{
   // Check cooldown period
   if (TimeCurrent() - last_signal_time < MIN_SIGNAL_COOLDOWN_MINUTES * 60)
   {
      if (DEBUG_LEVEL >= 1)
         Print("⏰ SIGNAL IGNORED: ", signal_description, " - Still in cooldown period");
      return;
   }

   // Check if we already have a position
   if (current_position_ticket != 0)
   {
      if (DEBUG_LEVEL >= 1)
         Print("⏰ SIGNAL IGNORED: ", signal_description, " - Position already open");
      return;
   }

   if (DEBUG_LEVEL >= 1)
      Print("🎯 TREND EXHAUSTION SIGNAL: ", signal_description);

   // Execute the appropriate trade
   if (direction == BULLISH_TREND)
      ExecuteBuyTrade();
   else if (direction == BEARISH_TREND)
      ExecuteSellTrade();

   last_signal_time = TimeCurrent();
}

//============================================================================
//                          TRADE EXECUTION
//============================================================================

void ExecuteBuyTrade()
{
   double entry_price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   // Calculate position size based on risk
   double risk_amount = AccountInfoDouble(ACCOUNT_BALANCE) * RISK_PERCENT / 100.0;
   double stop_distance = entry_price * STOP_LOSS_PERCENT / 100.0;
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
   request.comment = "R_Exhaustion_Buy";
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
         Print("Size: ", DoubleToString(position_size, 6));
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
   double stop_distance = entry_price * STOP_LOSS_PERCENT / 100.0;
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
   request.comment = "R_Exhaustion_Sell";
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
         Print("Size: ", DoubleToString(position_size, 6));
         Print("Risk: $", DoubleToString(risk_amount, 2));
      }
   }
   else
   {
      Print("❌ SELL ORDER FAILED: ", result.retcode, " - ", GetErrorDescription(result.retcode));
   }
}

//============================================================================
//                           VISUAL FUNCTIONS
//============================================================================

void DrawSignalArrow(datetime time, double price, bool is_buy_signal)
{
   signal_counter++;
   string obj_name = "R_Signal_" + IntegerToString(signal_counter);
   
   // Create arrow object
   if (ObjectCreate(0, obj_name, OBJ_ARROW, 0, time, price))
   {
      if (is_buy_signal)
      {
         // Blue up arrow for buy signal
         ObjectSetInteger(0, obj_name, OBJPROP_ARROWCODE, 233); // Up arrow
         ObjectSetInteger(0, obj_name, OBJPROP_COLOR, clrDodgerBlue);
         ObjectSetInteger(0, obj_name, OBJPROP_WIDTH, 3);
      }
      else
      {
         // Red down arrow for sell signal
         ObjectSetInteger(0, obj_name, OBJPROP_ARROWCODE, 234); // Down arrow
         ObjectSetInteger(0, obj_name, OBJPROP_COLOR, clrCrimson);
         ObjectSetInteger(0, obj_name, OBJPROP_WIDTH, 3);
      }
      
      ObjectSetInteger(0, obj_name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, obj_name, OBJPROP_SELECTED, false);
   }
}

void DrawZoneRectangle(datetime start_time, datetime end_time, bool is_overbought_zone)
{
   signal_counter++;
   string obj_name = "R_Zone_" + IntegerToString(signal_counter);
   
   // Get high and low prices for the rectangle
   double high_array[], low_array[];
   int bars_count = iBarShift(_Symbol, _Period, start_time) - iBarShift(_Symbol, _Period, end_time) + 1;
   
   if (bars_count > 0)
   {
      int start_shift = iBarShift(_Symbol, _Period, end_time);
      
      if (CopyHigh(_Symbol, _Period, start_shift, bars_count, high_array) > 0 &&
          CopyLow(_Symbol, _Period, start_shift, bars_count, low_array) > 0)
      {
         double zone_high = high_array[ArrayMaximum(high_array)];
         double zone_low = low_array[ArrayMinimum(low_array)];
         
         // Create rectangle
         if (ObjectCreate(0, obj_name, OBJ_RECTANGLE, 0, start_time, zone_high, end_time, zone_low))
         {
            if (is_overbought_zone)
            {
               // Red zone for overbought
               ObjectSetInteger(0, obj_name, OBJPROP_COLOR, clrCrimson);
               ObjectSetInteger(0, obj_name, OBJPROP_FILL, true);
               ObjectSetInteger(0, obj_name, OBJPROP_BACK, true);
               ObjectSetInteger(0, obj_name, OBJPROP_WIDTH, 0);
               ObjectSetInteger(0, obj_name, OBJPROP_STYLE, STYLE_SOLID);
               // Set transparency (0-255, where 255 is fully transparent)
               ObjectSetInteger(0, obj_name, OBJPROP_COLOR, ColorToARGB(clrCrimson, 230)); // ~90% transparent
            }
            else
            {
               // Blue zone for oversold
               ObjectSetInteger(0, obj_name, OBJPROP_COLOR, clrDodgerBlue);
               ObjectSetInteger(0, obj_name, OBJPROP_FILL, true);
               ObjectSetInteger(0, obj_name, OBJPROP_BACK, true);
               ObjectSetInteger(0, obj_name, OBJPROP_WIDTH, 0);
               ObjectSetInteger(0, obj_name, OBJPROP_STYLE, STYLE_SOLID);
               // Set transparency
               ObjectSetInteger(0, obj_name, OBJPROP_COLOR, ColorToARGB(clrDodgerBlue, 230)); // ~90% transparent
            }
            
            ObjectSetInteger(0, obj_name, OBJPROP_SELECTABLE, false);
            ObjectSetInteger(0, obj_name, OBJPROP_SELECTED, false);
         }
      }
   }
}

// Helper function to convert color with transparency
color ColorToARGB(color clr, uchar alpha)
{
   return (color)((alpha << 24) | (clr & 0xFFFFFF));
}

void UpdateVisualElements()
{
   datetime current_time = TimeCurrent();
   
   // Handle overbought zone visualization
   if (is_overbought && !was_overbought)
   {
      // Started overbought zone
      last_ob_zone_start = current_time;
   }
   else if (!is_overbought && was_overbought && last_ob_zone_start > 0)
   {
      // Ended overbought zone - draw the zone rectangle
      DrawZoneRectangle(last_ob_zone_start, current_time, true);
      last_ob_zone_start = 0;
   }
   
   // Handle oversold zone visualization
   if (is_oversold && !was_oversold)
   {
      // Started oversold zone
      last_os_zone_start = current_time;
   }
   else if (!is_oversold && was_oversold && last_os_zone_start > 0)
   {
      // Ended oversold zone - draw the zone rectangle
      DrawZoneRectangle(last_os_zone_start, current_time, false);
      last_os_zone_start = 0;
   }
   
   // Draw current active zones (temporary visualization)
   DrawCurrentActiveZones();
}

void DrawCurrentActiveZones()
{
   // Remove previous temporary zone objects
   ObjectDelete(0, "R_ActiveZone_OB");
   ObjectDelete(0, "R_ActiveZone_OS");
   
   datetime current_time = TimeCurrent();
   
   // Draw current overbought zone if active
   if (is_overbought && last_ob_zone_start > 0)
   {
      double high = iHigh(_Symbol, _Period, 0);
      double low = iLow(_Symbol, _Period, 0);
      
      if (ObjectCreate(0, "R_ActiveZone_OB", OBJ_RECTANGLE, 0, last_ob_zone_start, high * 1.001, current_time, low * 0.999))
      {
         ObjectSetInteger(0, "R_ActiveZone_OB", OBJPROP_COLOR, ColorToARGB(clrCrimson, 240));
         ObjectSetInteger(0, "R_ActiveZone_OB", OBJPROP_FILL, true);
         ObjectSetInteger(0, "R_ActiveZone_OB", OBJPROP_BACK, true);
         ObjectSetInteger(0, "R_ActiveZone_OB", OBJPROP_WIDTH, 0);
         ObjectSetInteger(0, "R_ActiveZone_OB", OBJPROP_STYLE, STYLE_SOLID);
         ObjectSetInteger(0, "R_ActiveZone_OB", OBJPROP_SELECTABLE, false);
         ObjectSetInteger(0, "R_ActiveZone_OB", OBJPROP_SELECTED, false);
      }
   }
   
   // Draw current oversold zone if active
   if (is_oversold && last_os_zone_start > 0)
   {
      double high = iHigh(_Symbol, _Period, 0);
      double low = iLow(_Symbol, _Period, 0);
      
      if (ObjectCreate(0, "R_ActiveZone_OS", OBJ_RECTANGLE, 0, last_os_zone_start, high * 1.001, current_time, low * 0.999))
      {
         ObjectSetInteger(0, "R_ActiveZone_OS", OBJPROP_COLOR, ColorToARGB(clrDodgerBlue, 240));
         ObjectSetInteger(0, "R_ActiveZone_OS", OBJPROP_FILL, true);
         ObjectSetInteger(0, "R_ActiveZone_OS", OBJPROP_BACK, true);
         ObjectSetInteger(0, "R_ActiveZone_OS", OBJPROP_WIDTH, 0);
         ObjectSetInteger(0, "R_ActiveZone_OS", OBJPROP_STYLE, STYLE_SOLID);
         ObjectSetInteger(0, "R_ActiveZone_OS", OBJPROP_SELECTABLE, false);
         ObjectSetInteger(0, "R_ActiveZone_OS", OBJPROP_SELECTED, false);
      }
   }
}

void CleanupVisualObjects()
{
   // Remove all visual objects created by this EA
   for (int i = ObjectsTotal(0) - 1; i >= 0; i--)
   {
      string obj_name = ObjectName(0, i);
      if (StringFind(obj_name, "R_Signal_") >= 0 || 
          StringFind(obj_name, "R_Zone_") >= 0 ||
          StringFind(obj_name, "R_ActiveZone_") >= 0)
      {
         ObjectDelete(0, obj_name);
      }
   }
   
   // Explicitly remove active zone objects
   ObjectDelete(0, "R_ActiveZone_OB");
   ObjectDelete(0, "R_ActiveZone_OS");
}

//============================================================================
//                           UTILITY FUNCTIONS
//============================================================================

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
   int slippage = (int)(spread * 2 + 50);
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
   case PERIOD_M1: return "M1";
   case PERIOD_M5: return "M5";
   case PERIOD_M15: return "M15";
   case PERIOD_M30: return "M30";
   case PERIOD_H1: return "H1";
   default: return "Unknown";
   }
}

string GetErrorDescription(int error_code)
{
   switch (error_code)
   {
   case TRADE_RETCODE_DONE: return "Success";
   case TRADE_RETCODE_REQUOTE: return "Requote";
   case TRADE_RETCODE_REJECT: return "Rejected";
   case TRADE_RETCODE_INVALID_PRICE: return "Invalid price";
   case TRADE_RETCODE_INVALID_STOPS: return "Invalid stops";
   case TRADE_RETCODE_NO_MONEY: return "No money";
   default: return "Error " + IntegerToString(error_code);
   }
}

void ShowInfoPanel()
{
   // Position status
   string position_status = "No Position";
   if (current_position_ticket != 0)
   {
      if (PositionSelectByTicket(current_position_ticket))
      {
         double profit = PositionGetDouble(POSITION_PROFIT);
         string direction = (position_direction == BULLISH_TREND) ? "LONG" : "SHORT";
         position_status = direction + " | P&L: $" + DoubleToString(profit, 2);
      }
      else
      {
         // Position was closed
         current_position_ticket = 0;
         position_direction = NO_TREND;
         position_status = "No Position";
      }
   }

   // %R status with zone duration
   string r_status = "";
   string zone_info = "";
   
   if (is_overbought)
   {
      r_status = "🔴 OVERBOUGHT (Bearish Zone)";
      if (last_ob_zone_start > 0)
      {
         int zone_bars = iBarShift(_Symbol, _Period, last_ob_zone_start);
         double zone_minutes = (TimeCurrent() - last_ob_zone_start) / 60.0;
         zone_info = "Zone Duration: " + IntegerToString(zone_bars) + " bars (" + 
                     DoubleToString(zone_minutes, 1) + " min)";
      }
   }
   else if (is_oversold)
   {
      r_status = "🟢 OVERSOLD (Bullish Zone)";
      if (last_os_zone_start > 0)
      {
         int zone_bars = iBarShift(_Symbol, _Period, last_os_zone_start);
         double zone_minutes = (TimeCurrent() - last_os_zone_start) / 60.0;
         zone_info = "Zone Duration: " + IntegerToString(zone_bars) + " bars (" + 
                     DoubleToString(zone_minutes, 1) + " min)";
      }
   }
   else
      r_status = "😐 NEUTRAL";

   // Visual elements count
   int signal_count = 0;
   int zone_count = 0;
   for (int i = ObjectsTotal(0) - 1; i >= 0; i--)
   {
      string obj_name = ObjectName(0, i);
      if (StringFind(obj_name, "R_Signal_") >= 0) signal_count++;
      else if (StringFind(obj_name, "R_Zone_") >= 0) zone_count++;
   }

   string info = StringFormat(
       "📊 %R TREND EXHAUSTION | Trades: %d/%d\n" +
           "Fast %R: %.1f | Slow %R: %.1f | Avg: %.1f\n" +
           "Status: %s\n" +
           "%s\n" +
           "Position: %s\n" +
           "Price: $%s | Threshold: %d\n" +
           "Visual: %d signals, %d zones",
       daily_trade_count, MAX_DAILY_TRADES,
       fast_r, slow_r, avg_r,
       r_status,
       zone_info,
       position_status,
       DoubleToString(price, 2),
       THRESHOLD,
       signal_count, zone_count);

   Comment(info);
}

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
   if (total_trades < 5 || initial_deposit <= 0)
      return 0.0;
   
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
   
   // Trade volume multiplier
   double trade_multiplier = MathLog(total_trades + 1);
   
   // Final fitness: Profit efficiency × Win rate × Profit factor × Trade volume
   double fitness = profit_score * win_rate_multiplier * pf_multiplier * trade_multiplier;
   
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
      Print("Trade Multiplier: ", DoubleToString(trade_multiplier, 2));
      Print("FINAL FITNESS: ", DoubleToString(fitness, 2));
      Print("=====================================");
   }
   
   return fitness;
}

//+------------------------------------------------------------------+
//+------------------------------------------------------------------+