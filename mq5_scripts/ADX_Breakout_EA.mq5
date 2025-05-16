//+------------------------------------------------------------------+
//|                                               ADX_Breakout_EA.mq5 |
//|                        Copyright 2023, Based on Rob Booker Strategy|
//|                               Original by Andrew Palladino, 9/29/17|
//+------------------------------------------------------------------+
#property copyright "Copyright 2023"
#property link      "https://www.example.com"
#property version   "1.01"

// Strategy Overview:
// This EA implements Rob Booker's ADX Breakout Strategy, which identifies consolidation
// periods using ADX and trades breakouts from these periods. The strategy is designed
// to catch the beginning of new trends after periods of low volatility.
//
// Core Strategy Components:
// 1. ADX (Average Directional Index) - Used to identify consolidation periods
//    - Custom implementation using Wilder's smoothing method
//    - Consolidation identified when ADX is below threshold (default: 18)
// 2. Breakout Box - Price range formed during consolidation
//    - Upper level: Highest high over lookback period
//    - Lower level: Lowest low over lookback period
//    - Box width used for stop loss and take profit calculations
// 3. Entry Conditions:
//    - ADX must be below threshold (indicating consolidation)
//    - Price must break out of the box (above upper or below lower)
//    - No existing position
// 4. Exit Conditions:
//    - Fixed risk:reward ratio based on box width
//    - Stop loss: 1x box width
//    - Take profit: 2x box width (configurable)

// Strategy Parameters
input int                ADX_SMOOTH_PERIOD = 14;        // ADX Smoothing Period (Wilder's smoothing)
input int                ADX_PERIOD = 14;               // ADX Calculation Period
input double             ADX_CONSOLIDATION_THRESHOLD = 14; // ADX Threshold for Consolidation
input double             PROFIT_TARGET_MULTIPLE = 2.0;  // Take Profit as Multiple of Box Width
input double             STOP_LOSS_MULTIPLE = 1.0;      // Stop Loss as Multiple of Box Width
input int                BOX_LOOKBACK_PERIOD = 25;      // Period for Box Level Calculation
input int                TRADE_DIRECTION = 0;           // Trade Direction: Both(0), Long(1), Short(-1)
input double             TRADE_VOLUME = 1.0;            // Position Size in Lots
input int                MAGIC_NUMBER = 234000;         // Unique Identifier for EA Orders
input bool               ENABLE_LOGGING = true;         // Enable Detailed Logging
input bool               SHOW_BOX_LEVELS = true;        // Display Box Levels on Chart
input bool               SHOW_ADX_INFO = true;          // Show ADX Information on Chart

// Global State Variables
double                   box_upper_level;               // Upper Boundary of Breakout Box
double                   box_lower_level;               // Lower Boundary of Breakout Box
double                   box_width;                     // Width of Breakout Box
bool                     is_in_position;                // Current Position Status
bool                     is_adx_below_threshold;        // ADX Consolidation Status
datetime                 last_processed_bar_time;       // Last Bar Processing Time
double                   position_entry_price;          // Current Position Entry Price
int                      current_position_type;         // Current Position Type (0=Long, 1=Short, -1=None)
ulong                    current_position_ticket;       // Current Position Ticket

// Chart Object Names
string                   box_upper_line = "ADX_Box_Upper";
string                   box_lower_line = "ADX_Box_Lower";

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   // Print strategy configuration
   PrintConfig();
   
   // Clear any old objects
   ObjectDelete(0, box_upper_line);
   ObjectDelete(0, box_lower_line);
   
   // Calculate ADX statistics for initial insight
   if(ENABLE_LOGGING)
   {
      CalculateADXStatistics(100);
   }
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   // Remove objects
   ObjectDelete(0, box_upper_line);
   ObjectDelete(0, box_lower_line);
      
   Comment(""); // Clear chart comment
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // Check for new bar
   bool new_bar = IsNewBar();
   if(new_bar)
   {
      Print("===== New bar detected at ", TimeToString(TimeCurrent()), " =====");
   }
   else
   {
      return; // Skip if not a new bar
   }

   // Update position status
   UpdatePositionStatus();
   
   // Calculate indicators and box levels
   if(!CalculateIndicators())
   {
      Print("Failed to calculate indicators, skipping this bar");
      return;
   }
   
   // Process entry and exit signals
   ProcessTradeSignals();
}

//+------------------------------------------------------------------+
//| Custom ADX Calculation (Wilder's Smoothing Method)               |
//+------------------------------------------------------------------+
double CalculateADX(int period, int smooth_period, double &adx_values[], int required_bars)
{
   // Price data arrays
   double high[], low[], close[];
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   ArraySetAsSeries(close, true);
   
   // Fetch price data
   if(CopyHigh(_Symbol, _Period, 0, required_bars, high) <= 0 ||
      CopyLow(_Symbol, _Period, 0, required_bars, low) <= 0 ||
      CopyClose(_Symbol, _Period, 0, required_bars, close) <= 0)
   {
      Print("Error: Failed to fetch price data for ADX calculation");
      return 0;
   }
   
   // ADX calculation components
   double true_range[];           // True Range values
   double positive_dm[];          // Positive Directional Movement
   double negative_dm[];          // Negative Directional Movement
   double smoothed_tr[];          // Smoothed True Range
   double smoothed_plus_dm[];     // Smoothed Positive DM
   double smoothed_minus_dm[];    // Smoothed Negative DM
   double di_plus[];              // Positive Directional Indicator
   double di_minus[];             // Negative Directional Indicator
   double dx[];                   // Directional Index
   
   // Initialize arrays
   ArrayResize(true_range, required_bars);
   ArrayResize(positive_dm, required_bars);
   ArrayResize(negative_dm, required_bars);
   ArrayResize(smoothed_tr, required_bars);
   ArrayResize(smoothed_plus_dm, required_bars);
   ArrayResize(smoothed_minus_dm, required_bars);
   ArrayResize(di_plus, required_bars);
   ArrayResize(di_minus, required_bars);
   ArrayResize(dx, required_bars);
   ArrayResize(adx_values, required_bars);
   
   // Set arrays as series (newest first)
   ArraySetAsSeries(true_range, true);
   ArraySetAsSeries(positive_dm, true);
   ArraySetAsSeries(negative_dm, true);
   ArraySetAsSeries(smoothed_tr, true);
   ArraySetAsSeries(smoothed_plus_dm, true);
   ArraySetAsSeries(smoothed_minus_dm, true);
   ArraySetAsSeries(di_plus, true);
   ArraySetAsSeries(di_minus, true);
   ArraySetAsSeries(dx, true);
   ArraySetAsSeries(adx_values, true);
   
   // Calculate True Range and Directional Movement
   for(int i = required_bars - 2; i >= 0; i--)
   {
      // True Range = max(high-low, |high-prev_close|, |low-prev_close|)
      double high_low_range = high[i] - low[i];
      double high_prev_close = MathAbs(high[i] - close[i+1]);
      double low_prev_close = MathAbs(low[i] - close[i+1]);
      true_range[i] = MathMax(high_low_range, MathMax(high_prev_close, low_prev_close));
      
      // Calculate Directional Movement
      double up_move = high[i] - high[i+1];
      double down_move = low[i+1] - low[i];
      
      // Positive DM: up_move > down_move and up_move > 0
      if(up_move > down_move && up_move > 0)
         positive_dm[i] = up_move;
      else
         positive_dm[i] = 0;
         
      // Negative DM: down_move > up_move and down_move > 0
      if(down_move > up_move && down_move > 0)
         negative_dm[i] = down_move;
      else
         negative_dm[i] = 0;
   }
   
   // Apply Wilder's smoothing (EMA with alpha=1/period)
   // First value is simple average of first 'period' values
   double sum_tr = 0, sum_plus_dm = 0, sum_minus_dm = 0;
   for(int i = required_bars - 2; i >= required_bars - period - 1 && i >= 0; i--)
   {
      sum_tr += true_range[i];
      sum_plus_dm += positive_dm[i];
      sum_minus_dm += negative_dm[i];
   }
   
   int first_idx = required_bars - period - 1;
   if(first_idx < 0) first_idx = 0;
   
   // Initialize first smoothed values
   smoothed_tr[first_idx] = sum_tr / period;
   smoothed_plus_dm[first_idx] = sum_plus_dm / period;
   smoothed_minus_dm[first_idx] = sum_minus_dm / period;
   
   // Continue Wilder's smoothing: smoothed = prev_smoothed - (prev_smoothed/period) + current
   for(int i = first_idx - 1; i >= 0; i--)
   {
      smoothed_tr[i] = smoothed_tr[i+1] - (smoothed_tr[i+1] / period) + true_range[i];
      smoothed_plus_dm[i] = smoothed_plus_dm[i+1] - (smoothed_plus_dm[i+1] / period) + positive_dm[i];
      smoothed_minus_dm[i] = smoothed_minus_dm[i+1] - (smoothed_minus_dm[i+1] / period) + negative_dm[i];
      
      // Calculate Directional Indicators (DI+ and DI-)
      if(smoothed_tr[i] > 0)
      {
         di_plus[i] = 100 * smoothed_plus_dm[i] / smoothed_tr[i];
         di_minus[i] = 100 * smoothed_minus_dm[i] / smoothed_tr[i];
      }
      else
      {
         di_plus[i] = 0;
         di_minus[i] = 0;
      }
      
      // Calculate Directional Index (DX)
      if(di_plus[i] + di_minus[i] > 0)
         dx[i] = 100 * MathAbs(di_plus[i] - di_minus[i]) / (di_plus[i] + di_minus[i]);
      else
         dx[i] = 0;
   }
   
   // Apply Wilder's smoothing to DX to get ADX
   double sum_dx = 0;
   int adx_start = smooth_period;
   if(adx_start >= required_bars) adx_start = required_bars - 1;
   
   for(int i = adx_start; i > 0; i--)
   {
      sum_dx += dx[i];
   }
   
   // First ADX value is average of DX
   adx_values[adx_start] = sum_dx / smooth_period;
   
   // Calculate subsequent ADX values using Wilder's smoothing
   for(int i = adx_start - 1; i >= 0; i--)
   {
      adx_values[i] = ((adx_values[i+1] * (smooth_period - 1)) + dx[i]) / smooth_period;
   }
   
   // Return current ADX value
   double current_adx = adx_values[0];
   
   // Log detailed ADX calculation if enabled
   if(ENABLE_LOGGING)
   {
      Print("ADX Calculation Details:");
      Print("  Current Close: ", DoubleToString(close[0], _Digits));
      Print("  True Range: ", DoubleToString(true_range[0], 6));
      Print("  +DM: ", DoubleToString(positive_dm[0], 6));
      Print("  -DM: ", DoubleToString(negative_dm[0], 6));
      Print("  Smoothed TR: ", DoubleToString(smoothed_tr[0], 6));
      Print("  Smoothed +DM: ", DoubleToString(smoothed_plus_dm[0], 6));
      Print("  Smoothed -DM: ", DoubleToString(smoothed_minus_dm[0], 6));
      Print("  DI+: ", DoubleToString(di_plus[0], 6));
      Print("  DI-: ", DoubleToString(di_minus[0], 6));
      Print("  DX: ", DoubleToString(dx[0], 6));
      Print("  ADX: ", DoubleToString(current_adx, 6));
   }
   
   return current_adx;
}

//+------------------------------------------------------------------+
//| Check if we have a new bar                                       |
//+------------------------------------------------------------------+
bool IsNewBar()
{
   datetime current_bar_time = iTime(_Symbol, _Period, 0);
   
   if(current_bar_time == last_processed_bar_time)
      return false;
      
   last_processed_bar_time = current_bar_time;
   return true;
}

//+------------------------------------------------------------------+
//| Update position status - exactly matching strategy.position_size |
//+------------------------------------------------------------------+
void UpdatePositionStatus()
{
   bool previous_status = is_in_position;
   is_in_position = false;
   current_position_ticket = 0;
   current_position_type = -1;
   
   // Check for open positions with our magic number
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         // Select the position by ticket
         if(PositionSelectByTicket(ticket))
         {
            // Check if position belongs to this EA and symbol
            if(PositionGetInteger(POSITION_MAGIC) == MAGIC_NUMBER && 
               PositionGetString(POSITION_SYMBOL) == _Symbol)
            {
               // Found our position
               is_in_position = true;
               current_position_ticket = ticket;
               current_position_type = (int)PositionGetInteger(POSITION_TYPE); // 0 for buy, 1 for sell
               position_entry_price = PositionGetDouble(POSITION_PRICE_OPEN);
               break;
            }
         }
      }
   }
   
   // Log position status change if needed
   if(previous_status != is_in_position || ENABLE_LOGGING)
   {
      if(is_in_position)
      {
         string pos_type_str = (current_position_type == 0) ? "LONG" : "SHORT";
         Print("Position status: IN POSITION (", pos_type_str, ") - Ticket: ", current_position_ticket);
         Print("Entry price: ", DoubleToString(position_entry_price, _Digits));
      }
      else
      {
         Print("Position status: NO OPEN POSITIONS");
      }
   }
}

//+------------------------------------------------------------------+
//| Draw box levels on chart                                         |
//+------------------------------------------------------------------+
void DrawBoxLevels()
{
   if(!SHOW_BOX_LEVELS) return;
   
   // Set line properties for upper box level
   ObjectDelete(0, box_upper_line);
   ObjectCreate(0, box_upper_line, OBJ_HLINE, 0, 0, box_upper_level);
   ObjectSetInteger(0, box_upper_line, OBJPROP_COLOR, clrBlue);
   ObjectSetInteger(0, box_upper_line, OBJPROP_STYLE, STYLE_SOLID);
   ObjectSetInteger(0, box_upper_line, OBJPROP_WIDTH, 1);
   ObjectSetString(0, box_upper_line, OBJPROP_TEXT, "Box Upper: " + DoubleToString(box_upper_level, _Digits));
   
   // Set line properties for lower box level
   ObjectDelete(0, box_lower_line);
   ObjectCreate(0, box_lower_line, OBJ_HLINE, 0, 0, box_lower_level);
   ObjectSetInteger(0, box_lower_line, OBJPROP_COLOR, clrRed);
   ObjectSetInteger(0, box_lower_line, OBJPROP_STYLE, STYLE_SOLID);
   ObjectSetInteger(0, box_lower_line, OBJPROP_WIDTH, 1);
   ObjectSetString(0, box_lower_line, OBJPROP_TEXT, "Box Lower: " + DoubleToString(box_lower_level, _Digits));
}

//+------------------------------------------------------------------+
//| Display ADX information on chart                                 |
//+------------------------------------------------------------------+
void DisplayADXInformation(double adx_value)
{
   if(!SHOW_ADX_INFO) return;
   
   // Change background color to visually indicate when ADX is below threshold
   if(adx_value < ADX_CONSOLIDATION_THRESHOLD)
   {
      // Highlight the background when we're in a consolidation phase
      ChartSetInteger(0, CHART_COLOR_BACKGROUND, clrLavender);
   }
   else
   {
      // Reset background to default (white)
      ChartSetInteger(0, CHART_COLOR_BACKGROUND, clrWhite);
   }
}

//+------------------------------------------------------------------+
//| Calculate indicators and box levels - match PineScript exactly   |
//+------------------------------------------------------------------+
bool CalculateIndicators()
{
   // Define how many bars we need
   int required_bars = MathMax(100, ADX_PERIOD + ADX_SMOOTH_PERIOD + BOX_LOOKBACK_PERIOD + 20);
   
   // Make sure we have enough bars
   if(Bars(_Symbol, _Period) < required_bars)
   {
      Print("Not enough bars for calculation (", Bars(_Symbol, _Period), " < ", required_bars, ")");
      return false;
   }
   
   // Static variable to track when we last did an ADX analysis
   static datetime last_adx_analysis_time = 0;
   
   // Run ADX analysis every 24 hours (for daily tracking)
   if(ENABLE_LOGGING && TimeCurrent() - last_adx_analysis_time > PeriodSeconds(PERIOD_D1))
   {
      CalculateADXStatistics(100);
      last_adx_analysis_time = TimeCurrent();
   }
   
   // Calculate ADX manually to match Python exactly
   double adx_values[];
   double current_adx = CalculateADX(ADX_PERIOD, ADX_SMOOTH_PERIOD, adx_values, required_bars);
   
   // Display ADX information on chart
   DisplayADXInformation(current_adx);
   
   // Log the ADX values for comparison with Python
   if(ArraySize(adx_values) >= 5)
   {
      Print("✅ CUSTOM ADX VALUES - Current:", DoubleToString(adx_values[0], 2), 
            ", Previous:", DoubleToString(adx_values[1], 2),
            ", 2 bars ago:", DoubleToString(adx_values[2], 2),
            ", 3 bars ago:", DoubleToString(adx_values[3], 2),
            ", 4 bars ago:", DoubleToString(adx_values[4], 2));
   }
   
   // Check if ADX is below the lower level (consolidation)
   // Use previous bar's ADX value for signal generation (index 1)
   is_adx_below_threshold = adx_values[1] < ADX_CONSOLIDATION_THRESHOLD;
   Print("ADX Value (prev bar):", DoubleToString(adx_values[1], 2), " threshold:", DoubleToString(ADX_CONSOLIDATION_THRESHOLD, 2),
         " => ADX is ", is_adx_below_threshold ? "BELOW threshold (good for signal)" : "ABOVE threshold (no signal)");
   
   double old_upper = box_upper_level;
   double old_lower = box_lower_level;
   
   // ===== CRITICAL: Calculate box levels the SAME as PineScript =====
   // In PineScript: 
   // boxUpperLevel = strategy.position_size == 0 ? highest(high, boxLookBack)[1] : boxUpperLevel[1]
   // boxLowerLevel = strategy.position_size == 0 ? lowest(low, boxLookBack)[1] : boxLowerLevel[1]
   
   // Only update box levels when NOT in a position
   if(!is_in_position)
   {
      // Arrays for price data
      double high[];
      double low[];
      
      // Copy price data - CRITICAL: we must get exactly the same data as TradingView
      // In TradingView, highest(high, boxLookBack)[1] means:
      // - Get highest high over the last boxLookBack bars
      // - Then shift by 1 to exclude current bar
      
      // Set to get data in reverse order (newest first)
      ArraySetAsSeries(high, true);
      ArraySetAsSeries(low, true);
      
      // Get price data starting from bar index 1 (previous bar) for BOX_LOOKBACK_PERIOD bars
      // This exactly matches highest(high, boxLookBack)[1] and lowest(low, boxLookBack)[1]
      if(CopyHigh(_Symbol, _Period, 1, BOX_LOOKBACK_PERIOD, high) <= 0 ||
         CopyLow(_Symbol, _Period, 1, BOX_LOOKBACK_PERIOD, low) <= 0)
      {
         Print("Error copying price data: ", GetLastError());
         return false;
      }
      
      // Now calculate the actual box levels - highest high and lowest low
      // Since arrays are set as series, we need to find max/min across all elements
      // Start from index 1 to exclude current bar
      double highest_high = high[1];
      double lowest_low = low[1];
      int high_idx = 1;
      int low_idx = 1;
      
      for(int i = 1; i < BOX_LOOKBACK_PERIOD; i++)
      {
         if(high[i] > highest_high)
         {
            highest_high = high[i];
            high_idx = i;
         }
         if(low[i] < lowest_low)
         {
            lowest_low = low[i];
            low_idx = i;
         }
      }
      
      box_upper_level = highest_high;
      box_lower_level = lowest_low;
      box_width = box_upper_level - box_lower_level;
      
      // Log all bars used in the box calculation
      Print("Box calculation from bars 1 to ", BOX_LOOKBACK_PERIOD, " (0 is current bar, not included):");
      for(int i = 0; i < MathMin(BOX_LOOKBACK_PERIOD, ArraySize(high)); i++)
      {
         Print("  Bar[", i + 1, "] High:", DoubleToString(high[i], _Digits), 
               " Low:", DoubleToString(low[i], _Digits));
      }
      
      Print("Box calculation result:");
      Print("  Highest High at index ", high_idx, " value: ", DoubleToString(highest_high, _Digits));
      Print("  Lowest Low at index ", low_idx, " value: ", DoubleToString(lowest_low, _Digits));
      Print("  Box Width: ", DoubleToString(box_width, _Digits));
      
      // Check if box levels changed
      if(old_upper != box_upper_level || old_lower != box_lower_level)
      {
         Print("Box levels updated: Upper=", DoubleToString(box_upper_level, _Digits), 
               ", Lower=", DoubleToString(box_lower_level, _Digits),
               ", Width=", DoubleToString(box_width, _Digits));
      }
      
      // Draw the box levels on chart
      DrawBoxLevels();
   }
   
   // Get latest close prices for status display
   double close_prices[];
   ArraySetAsSeries(close_prices, true);
   
   if(CopyClose(_Symbol, _Period, 0, 2, close_prices) <= 0)
   {
      Print("Error copying close prices: ", GetLastError());
      return false;
   }
   
   double current_close = close_prices[0];
   double previous_close = close_prices[1];
   
   // Log box and ADX details
   string adx_status = is_adx_below_threshold ? "LOW ✓" : "HIGH ✗";
   string position_status = is_in_position ? (current_position_type == 0 ? "IN LONG" : "IN SHORT") : "NO POSITION";
   
   // Check for crosses - EXACTLY matching PineScript cross() function
   // In PineScript, cross(close, boxUpperLevel) only checks if current > upper
   bool cross_above_upper = (current_close > box_upper_level);
   
   // In PineScript, crossunder(close, boxLowerLevel) only checks if current < lower
   bool cross_below_lower = (current_close < box_lower_level);
   
   // Display current bar's price vs box levels with ADX info
   Print("Current close: ", DoubleToString(current_close, _Digits), 
         ", Previous close: ", DoubleToString(previous_close, _Digits),
         ", Box Upper: ", DoubleToString(box_upper_level, _Digits),
         ", Box Lower: ", DoubleToString(box_lower_level, _Digits),
         ", Cross Up: ", cross_above_upper ? "YES" : "No",
         ", Cross Down: ", cross_below_lower ? "YES" : "No");
   
   Comment("ADX Breakout EA\n",
           "ADX=", DoubleToString(current_adx, 2), "/", DoubleToString(ADX_CONSOLIDATION_THRESHOLD, 2),
           " (", adx_status, ") | ", position_status, "\n",
           "Upper=", DoubleToString(box_upper_level, _Digits), 
           ", Lower=", DoubleToString(box_lower_level, _Digits), "\n",
           "Close=", DoubleToString(current_close, _Digits), 
           " | Cross Up: ", cross_above_upper ? "YES" : "No",
           " | Cross Down: ", cross_below_lower ? "YES" : "No");
   
   return true;
}

//+------------------------------------------------------------------+
//| Process trade signals and execute trades                          |
//+------------------------------------------------------------------+
void ProcessTradeSignals()
{
   // Get current and previous bar close prices
   double close_prices[];
   ArraySetAsSeries(close_prices, true);
   
   if(CopyClose(_Symbol, _Period, 0, 2, close_prices) <= 0)
   {
      Print("Error: Failed to fetch close prices for signal processing");
      return;
   }
   
   double current_close = close_prices[0];
   double previous_close = close_prices[1];
       
   // Check for breakout signals
   bool breakout_above = (current_close > box_upper_level);
   bool breakout_below = (current_close < box_lower_level);
   
   // Log breakout check details
   if(ENABLE_LOGGING)
   {
      Print("Breakout Check:");
      Print("  Current Close: ", DoubleToString(current_close, _Digits));
      Print("  Previous Close: ", DoubleToString(previous_close, _Digits));
      Print("  Box Upper: ", DoubleToString(box_upper_level, _Digits));
      Print("  Box Lower: ", DoubleToString(box_lower_level, _Digits));
      Print("  ADX Below Threshold: ", is_adx_below_threshold ? "Yes" : "No");
   }
      
   if(breakout_above)
   {
      Print("⚠️ Breakout Above Box: ", DoubleToString(current_close, _Digits), " > ", 
            DoubleToString(box_upper_level, _Digits));
   }
   
   if(breakout_below)
   {
      Print("⚠️ Breakout Below Box: ", DoubleToString(current_close, _Digits), " < ", 
            DoubleToString(box_lower_level, _Digits));
   }
   
   // Check trade direction settings
   bool can_trade_long = (TRADE_DIRECTION == 0 || TRADE_DIRECTION == 1);
   bool can_trade_short = (TRADE_DIRECTION == 0 || TRADE_DIRECTION == -1);
   
   // Validate entry conditions
   bool long_entry_valid = !is_in_position && breakout_above && is_adx_below_threshold && can_trade_long;
   bool short_entry_valid = !is_in_position && breakout_below && is_adx_below_threshold && can_trade_short;
   
   // Analyze and log entry signals
   if(breakout_above)
   {
      string signal_status = long_entry_valid ? "✅ VALID!" : "❌ INVALID because:";
      string reason = "";
      
      if(!can_trade_long) reason += " Long trades not allowed.";
      if(is_in_position) reason += " Already in position.";
      if(!is_adx_below_threshold) reason += " ADX not below threshold.";
      
      Print("🔍 Long Entry Analysis: ", signal_status, reason);
      
      if(ENABLE_LOGGING)
      {
         Print("  - No existing position: ", !is_in_position ? "✓" : "✗");
         Print("  - Breakout above box: ", breakout_above ? "✓" : "✗");
         Print("  - ADX below threshold: ", is_adx_below_threshold ? "✓" : "✗");
         Print("  - Long trades allowed: ", can_trade_long ? "✓" : "✗");
      }
   }
   
   if(breakout_below)
   {
      string signal_status = short_entry_valid ? "✅ VALID!" : "❌ INVALID because:";
      string reason = "";
      
      if(!can_trade_short) reason += " Short trades not allowed.";
      if(is_in_position) reason += " Already in position.";
      if(!is_adx_below_threshold) reason += " ADX not below threshold.";
      
      Print("🔍 Short Entry Analysis: ", signal_status, reason);
      
      if(ENABLE_LOGGING)
      {
         Print("  - No existing position: ", !is_in_position ? "✓" : "✗");
         Print("  - Breakout below box: ", breakout_below ? "✓" : "✗");
         Print("  - ADX below threshold: ", is_adx_below_threshold ? "✓" : "✗");
         Print("  - Short trades allowed: ", can_trade_short ? "✓" : "✗");
      }
   }
   
   // Execute valid trades
   if(long_entry_valid)
   {
      Print("⬆️ Long Entry Signal: Price ", DoubleToString(current_close, _Digits), 
            " broke above box upper ", DoubleToString(box_upper_level, _Digits), 
            " with ADX below threshold");
      
      // Calculate trade levels
      double entry_price = current_close;
      double stop_loss = entry_price - STOP_LOSS_MULTIPLE * box_width;
      double take_profit = entry_price + PROFIT_TARGET_MULTIPLE * box_width;
      
      // Log trade details
      Print("Trade Levels:");
      Print("  Entry: ", DoubleToString(entry_price, _Digits));
      Print("  Stop Loss: ", DoubleToString(stop_loss, _Digits), 
            " (", DoubleToString(STOP_LOSS_MULTIPLE, 2), "x box width)");
      Print("  Take Profit: ", DoubleToString(take_profit, _Digits), 
            " (", DoubleToString(PROFIT_TARGET_MULTIPLE, 2), "x box width)");
            
      // Execute long trade
      ExecuteTrade(ORDER_TYPE_BUY, stop_loss, take_profit);
   }
   else if(short_entry_valid)
   {
      Print("⬇️ Short Entry Signal: Price ", DoubleToString(current_close, _Digits), 
            " broke below box lower ", DoubleToString(box_lower_level, _Digits), 
            " with ADX below threshold");
      
      // Calculate trade levels
      double entry_price = current_close;
      double stop_loss = entry_price + STOP_LOSS_MULTIPLE * box_width;
      double take_profit = entry_price - PROFIT_TARGET_MULTIPLE * box_width;
      
      // Log trade details
      Print("Trade Levels:");
      Print("  Entry: ", DoubleToString(entry_price, _Digits));
      Print("  Stop Loss: ", DoubleToString(stop_loss, _Digits), 
            " (", DoubleToString(STOP_LOSS_MULTIPLE, 2), "x box width)");
      Print("  Take Profit: ", DoubleToString(take_profit, _Digits), 
            " (", DoubleToString(PROFIT_TARGET_MULTIPLE, 2), "x box width)");
            
      // Execute short trade
      ExecuteTrade(ORDER_TYPE_SELL, stop_loss, take_profit);
   }
}

//+------------------------------------------------------------------+
//| Execute a trade with stop loss and take profit                   |
//+------------------------------------------------------------------+
void ExecuteTrade(ENUM_ORDER_TYPE order_type, double sl_price, double tp_price)
{
   // Round prices to symbol digits
   sl_price = NormalizeDouble(sl_price, _Digits);
   tp_price = NormalizeDouble(tp_price, _Digits);
   
   // Check if SL/TP needs adjustment due to minimum stop level
   double min_stop_level = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   
   // Get current market prices for execution
   double current_ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double current_bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double price = (order_type == ORDER_TYPE_BUY) ? current_ask : current_bid;
   
   // Adjust SL/TP if too close to current price
   if(order_type == ORDER_TYPE_BUY)
   {
      if(price - sl_price < min_stop_level)
      {
         sl_price = NormalizeDouble(price - min_stop_level, _Digits);
         Print("Warning: Stop loss adjusted to minimum allowed distance: ", DoubleToString(sl_price, _Digits));
      }
      
      if(tp_price - price < min_stop_level)
      {
         tp_price = NormalizeDouble(price + min_stop_level, _Digits);
         Print("Warning: Take profit adjusted to minimum allowed distance: ", DoubleToString(tp_price, _Digits));
      }
   }
   else
   {
      if(sl_price - price < min_stop_level)
      {
         sl_price = NormalizeDouble(price + min_stop_level, _Digits);
         Print("Warning: Stop loss adjusted to minimum allowed distance: ", DoubleToString(sl_price, _Digits));
      }
      
      if(price - tp_price < min_stop_level)
      {
         tp_price = NormalizeDouble(price - min_stop_level, _Digits);
         Print("Warning: Take profit adjusted to minimum allowed distance: ", DoubleToString(tp_price, _Digits));
      }
   }
   
   // Log the trade before execution
   string order_type_str = (order_type == ORDER_TYPE_BUY) ? "BUY" : "SELL";
   Print("📊 Sending ", order_type_str, " order: Price=", DoubleToString(price, _Digits), 
         ", SL=", DoubleToString(sl_price, _Digits), 
         ", TP=", DoubleToString(tp_price, _Digits));
   
   // Place the trade
   MqlTradeRequest request = {};
   MqlTradeResult result = {};
   
   request.action = TRADE_ACTION_DEAL;
   request.symbol = _Symbol;
   request.volume = TRADE_VOLUME;
   request.type = order_type;
   request.price = price;
   request.sl = sl_price; 
   request.tp = tp_price;
   request.deviation = 20; // 2 pips deviation
   request.magic = MAGIC_NUMBER;
   request.comment = "ADX Breakout";
   request.type_filling = ORDER_FILLING_IOC;
   request.type_time = ORDER_TIME_GTC;
   
   if(OrderSend(request, result))
   {
      Print("✅ Trade executed successfully. Ticket: ", result.order);
      // Update position tracking
      is_in_position = true;
      current_position_type = (order_type == ORDER_TYPE_BUY) ? 0 : 1;
      position_entry_price = price;
      current_position_ticket = result.order;
   }
   else
   {
      Print("❌ Trade execution failed with error: ", GetLastError());
   }
}

//+------------------------------------------------------------------+
//| Print strategy configuration                                     |
//+------------------------------------------------------------------+
void PrintConfig()
{
   Print("=== ROB BOOKER ADX BREAKOUT STRATEGY ===");
   Print("Symbol: ", _Symbol);
   Print("Timeframe: ", EnumToString(Period()));
   Print("ADX Smooth Period: ", ADX_SMOOTH_PERIOD);
   Print("ADX Period: ", ADX_PERIOD);
   Print("ADX Lower Level: ", ADX_CONSOLIDATION_THRESHOLD);
   Print("Box Lookback: ", BOX_LOOKBACK_PERIOD);
   Print("Profit Target Multiple: ", PROFIT_TARGET_MULTIPLE);
   Print("Stop Loss Multiple: ", STOP_LOSS_MULTIPLE);
   
   string direction = "Both";
   if(TRADE_DIRECTION == 1) direction = "Long Only";
   if(TRADE_DIRECTION == -1) direction = "Short Only";
   Print("Direction: ", direction);
   Print("===========================================");
}

//+------------------------------------------------------------------+
//| Calculate and display ADX statistics                             |
//+------------------------------------------------------------------+
void CalculateADXStatistics(int bars_to_analyze)
{
   if(Bars(_Symbol, _Period) < bars_to_analyze)
      bars_to_analyze = Bars(_Symbol, _Period);
      
   // Calculate custom ADX
   double adx_values[];
   CalculateADX(ADX_PERIOD, ADX_SMOOTH_PERIOD, adx_values, bars_to_analyze + 50);
   
   // Get built-in ADX for comparison
   double builtin_adx[];
   ArraySetAsSeries(builtin_adx, true);
   int adx_indicator_handle = iADX(_Symbol, _Period, ADX_PERIOD);
   CopyBuffer(adx_indicator_handle, 0, 0, bars_to_analyze, builtin_adx);
   
   // Count bars where ADX is below threshold
   int custom_below_count = 0;
   int builtin_below_count = 0;
   double max_diff = 0;
   double avg_diff = 0;
   
   for(int i = 0; i < bars_to_analyze && i < ArraySize(adx_values); i++)
   {
      if(adx_values[i] < ADX_CONSOLIDATION_THRESHOLD)
         custom_below_count++;
         
      if(i < ArraySize(builtin_adx) && builtin_adx[i] < ADX_CONSOLIDATION_THRESHOLD)
         builtin_below_count++;
         
      // Calculate differences between custom and built-in ADX
      if(i < ArraySize(builtin_adx))
      {
         double diff = MathAbs(adx_values[i] - builtin_adx[i]);
         avg_diff += diff;
         if(diff > max_diff)
            max_diff = diff;
      }
   }
   
   if(bars_to_analyze > 0)
      avg_diff /= bars_to_analyze;
   
   // Calculate percentages
   double custom_below_pct = (double)custom_below_count / bars_to_analyze * 100;
   double builtin_below_pct = (double)builtin_below_count / bars_to_analyze * 100;
   
   // Log statistics
   Print("=== ADX STATISTICS OVER LAST ", bars_to_analyze, " BARS ===");
   Print("Custom ADX < ", ADX_CONSOLIDATION_THRESHOLD, ": ", custom_below_count, " bars (", DoubleToString(custom_below_pct, 1), "%)");
   Print("Built-in ADX < ", ADX_CONSOLIDATION_THRESHOLD, ": ", builtin_below_count, " bars (", DoubleToString(builtin_below_pct, 1), "%)");
   Print("ADX Difference - Max: ", DoubleToString(max_diff, 2), ", Avg: ", DoubleToString(avg_diff, 2));
   Print("=== END ADX STATISTICS ===");
} 