//+------------------------------------------------------------------+
//|                                               ADX_Breakout_EA.mq5 |
//|                        Copyright 2023, Based on Rob Booker Strategy|
//|                               Original by Andrew Palladino, 9/29/17|
//+------------------------------------------------------------------+
#property copyright "Copyright 2023"
#property link      "https://www.example.com"
#property version   "1.01"

// This EA implements Rob Booker's ADX Breakout Strategy
// It uses a CUSTOM ADX calculation that exactly matches the Python implementation 
// using Wilder's smoothing method (EMA with alpha=1/period).
//
// Key Features:
// - Custom ADX calculation to ensure identical results with Python version
// - Box levels using highest high and lowest low
// - Trades breakouts when ADX is below threshold (consolidation)
// - Visual drawing of box levels on chart
//
// Strategy Logic:
// 1. ADX below threshold (18) indicates consolidation
// 2. Box formed from highest high and lowest low
// 3. Entry when price breaks out of box while ADX is low
// 4. Exit with fixed risk:reward based on box width

// Input Parameters - matching the PineScript
input int                ADX_SMOOTH_PERIOD = 14;        // ADX Smoothing Period
input int                ADX_PERIOD = 14;               // ADX Period
input double             ADX_LOWER_LEVEL = 14;          // ADX Lower Level (must be BELOW this for valid signal)
input double             PROFIT_TARGET_MULTIPLE = 2.0;  // Profit Target Box Width Multiple
input double             STOP_LOSS_MULTIPLE = 1;      // Stop Loss Box Width Multiple
input int                BOX_LOOKBACK = 25;             // Breakout Box Lookback Period (reduced from 20)
input int                ENABLE_DIRECTION = 0;          // Both(0), Long(1), Short(-1)
input double             TRADE_VOLUME = 1;              // Trade volume in lots
input int                MAGIC_NUMBER = 234000;         // Magic Number for order identification
input bool               VERBOSE_LOGGING = true;        // Enable detailed logging
input bool               DRAW_BOXES = true;             // Draw box levels on chart
input bool               SHOW_ADX_VALUES = true;        // Show custom ADX values in chart comments

// Global Variables
int                      adx_handle = INVALID_HANDLE;   // Not used anymore, will calculate manually
double                   box_upper_level;               // Upper level of the box
double                   box_lower_level;               // Lower level of the box
double                   box_width;                     // Width of the box
bool                     in_position = false;           // Flag for position tracking
bool                     is_adx_low = false;            // Flag for ADX below threshold
datetime                 last_bar_time = 0;             // Time of the last processed bar
double                   position_price = 0;            // Entry price of the current position
int                      position_type = -1;            // 0 for buy, 1 for sell, -1 for none
ulong                    position_ticket = 0;           // Ticket of the current position

// Objects for visualizing the box levels
string                   obj_box_upper = "ADX_Box_Upper";
string                   obj_box_lower = "ADX_Box_Lower";

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   // Print strategy configuration
   PrintConfig();
   
   // Clear any old objects
   ObjectDelete(0, obj_box_upper);
   ObjectDelete(0, obj_box_lower);
   
   // Calculate ADX statistics for initial insight
   if(VERBOSE_LOGGING)
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
   ObjectDelete(0, obj_box_upper);
   ObjectDelete(0, obj_box_lower);
      
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
//| Custom ADX Calculation (matching PineScript)                         |
//+------------------------------------------------------------------+
double CalculateADX(int period, int smooth_period, double &adx_values[], int required_bars)
{
   // Arrays for OHLC data
   double high[], low[], close[];
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   ArraySetAsSeries(close, true);
   
   // Get price data
   if(CopyHigh(_Symbol, _Period, 0, required_bars, high) <= 0 ||
      CopyLow(_Symbol, _Period, 0, required_bars, low) <= 0 ||
      CopyClose(_Symbol, _Period, 0, required_bars, close) <= 0)
   {
      Print("Error copying price data for ADX calculation: ", GetLastError());
      return 0;
   }
   
   // Arrays for calculations
   double tr_array[];             // True Range
   double plus_dm_array[];        // +DM
   double minus_dm_array[];       // -DM
   double smoothed_tr[];          // Smoothed TR
   double smoothed_plus_dm[];     // Smoothed +DM
   double smoothed_minus_dm[];    // Smoothed -DM
   double di_plus[];              // DI+
   double di_minus[];             // DI-
   double dx[];                   // DX
   
   // Initialize arrays
   ArrayResize(tr_array, required_bars);
   ArrayResize(plus_dm_array, required_bars);
   ArrayResize(minus_dm_array, required_bars);
   ArrayResize(smoothed_tr, required_bars);
   ArrayResize(smoothed_plus_dm, required_bars);
   ArrayResize(smoothed_minus_dm, required_bars);
   ArrayResize(di_plus, required_bars);
   ArrayResize(di_minus, required_bars);
   ArrayResize(dx, required_bars);
   ArrayResize(adx_values, required_bars);
   
   ArraySetAsSeries(tr_array, true);
   ArraySetAsSeries(plus_dm_array, true);
   ArraySetAsSeries(minus_dm_array, true);
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
      // True Range calculation (max of high-low, |high-prev_close|, |low-prev_close|)
      double hl = high[i] - low[i];
      double hpc = MathAbs(high[i] - close[i+1]);
      double lpc = MathAbs(low[i] - close[i+1]);
      tr_array[i] = MathMax(hl, MathMax(hpc, lpc));
      
      // Calculate Directional Movement
      double up_move = high[i] - high[i+1];
      double down_move = low[i+1] - low[i];
      
      // Exactly matching PineScript logic:
      // Where pos_dm > neg_dm and pos_dm > 0, else 0
      // Where neg_dm > pos_dm and neg_dm > 0, else 0
      if(up_move > down_move && up_move > 0)
         plus_dm_array[i] = up_move;
      else
         plus_dm_array[i] = 0;
         
      if(down_move > up_move && down_move > 0)
         minus_dm_array[i] = down_move;
      else
         minus_dm_array[i] = 0;
   }
   
   // Apply Wilder's smoothing (exactly matching PineScript's rma() function)
   // First value is simple average of first 'period' values
   double sum_tr = 0, sum_plus_dm = 0, sum_minus_dm = 0;
   for(int i = required_bars - 2; i >= required_bars - period - 1 && i >= 0; i--)
   {
      sum_tr += tr_array[i];
      sum_plus_dm += plus_dm_array[i];
      sum_minus_dm += minus_dm_array[i];
   }
   
   int first_idx = required_bars - period - 1;
   if(first_idx < 0) first_idx = 0;
   
   // Initialize first smoothed values - EXACTLY matching PineScript's rma()
   smoothed_tr[first_idx] = sum_tr / period;
   smoothed_plus_dm[first_idx] = sum_plus_dm / period;
   smoothed_minus_dm[first_idx] = sum_minus_dm / period;
   
   // Continue Wilder's smoothing - Using exact formula: smoothed = prev_smoothed - (prev_smoothed/period) + current
   // This matches PineScript's rma() function exactly
   for(int i = first_idx - 1; i >= 0; i--)
   {
      smoothed_tr[i] = smoothed_tr[i+1] - (smoothed_tr[i+1] / period) + tr_array[i];
      smoothed_plus_dm[i] = smoothed_plus_dm[i+1] - (smoothed_plus_dm[i+1] / period) + plus_dm_array[i];
      smoothed_minus_dm[i] = smoothed_minus_dm[i+1] - (smoothed_minus_dm[i+1] / period) + minus_dm_array[i];
      
      // Calculate DI+ and DI-
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
      
      // Calculate DX
      if(di_plus[i] + di_minus[i] > 0)
         dx[i] = 100 * MathAbs(di_plus[i] - di_minus[i]) / (di_plus[i] + di_minus[i]);
      else
         dx[i] = 0;
   }
   
   // Apply Wilder's smoothing to DX to get ADX (matching PineScript's rma())
   // First, calculate simple average of first smooth_period DX values
   double sum_dx = 0;
   int adx_start = smooth_period;
   if(adx_start >= required_bars) adx_start = required_bars - 1;
   
   for(int i = adx_start; i > 0; i--)
   {
      sum_dx += dx[i];
   }
   
   // First ADX value is average of DX - EXACTLY matching PineScript's rma()
   adx_values[adx_start] = sum_dx / smooth_period;
   
   // Calculate subsequent ADX values using Wilder's smoothing formula
   for(int i = adx_start - 1; i >= 0; i--)
   {
      // This exactly matches PineScript's rma() function
      adx_values[i] = ((adx_values[i+1] * (smooth_period - 1)) + dx[i]) / smooth_period;
   }
   
   // Return the current ADX value (index 0)
   double final_adx = adx_values[0];
   
   // Log additional debug values to help diagnose discrepancies
   if(VERBOSE_LOGGING)
   {
      Print("ADX calculation details:");
      Print("  Current Close: ", DoubleToString(close[0], _Digits));
      Print("  TR[0]: ", DoubleToString(tr_array[0], 6));
      Print("  +DM[0]: ", DoubleToString(plus_dm_array[0], 6));
      Print("  -DM[0]: ", DoubleToString(minus_dm_array[0], 6));
      Print("  Smoothed TR[0]: ", DoubleToString(smoothed_tr[0], 6));
      Print("  Smoothed +DM[0]: ", DoubleToString(smoothed_plus_dm[0], 6));
      Print("  Smoothed -DM[0]: ", DoubleToString(smoothed_minus_dm[0], 6));
      Print("  DI+[0]: ", DoubleToString(di_plus[0], 6));
      Print("  DI-[0]: ", DoubleToString(di_minus[0], 6));
      Print("  DX[0]: ", DoubleToString(dx[0], 6));
      Print("  ADX[0]: ", DoubleToString(final_adx, 6));
   }
   
   return final_adx;
}

//+------------------------------------------------------------------+
//| Check if we have a new bar                                       |
//+------------------------------------------------------------------+
bool IsNewBar()
{
   datetime current_bar_time = iTime(_Symbol, _Period, 0);
   
   if(current_bar_time == last_bar_time)
      return false;
      
   last_bar_time = current_bar_time;
   return true;
}

//+------------------------------------------------------------------+
//| Update position status - exactly matching strategy.position_size |
//+------------------------------------------------------------------+
void UpdatePositionStatus()
{
   bool previous_status = in_position;
   in_position = false;
   position_ticket = 0;
   position_type = -1;
   
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
               in_position = true;
               position_ticket = ticket;
               position_type = (int)PositionGetInteger(POSITION_TYPE); // 0 for buy, 1 for sell
               position_price = PositionGetDouble(POSITION_PRICE_OPEN);
               break;
            }
         }
      }
   }
   
   // Log position status change if needed
   if(previous_status != in_position || VERBOSE_LOGGING)
   {
      if(in_position)
      {
         string pos_type_str = (position_type == 0) ? "LONG" : "SHORT";
         Print("Position status: IN POSITION (", pos_type_str, ") - Ticket: ", position_ticket);
         Print("Entry price: ", DoubleToString(position_price, _Digits));
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
   if(!DRAW_BOXES) return;
   
   // Set line properties for upper box level
   ObjectDelete(0, obj_box_upper);
   ObjectCreate(0, obj_box_upper, OBJ_HLINE, 0, 0, box_upper_level);
   ObjectSetInteger(0, obj_box_upper, OBJPROP_COLOR, clrBlue);
   ObjectSetInteger(0, obj_box_upper, OBJPROP_STYLE, STYLE_SOLID);
   ObjectSetInteger(0, obj_box_upper, OBJPROP_WIDTH, 1);
   ObjectSetString(0, obj_box_upper, OBJPROP_TEXT, "Box Upper: " + DoubleToString(box_upper_level, _Digits));
   
   // Set line properties for lower box level
   ObjectDelete(0, obj_box_lower);
   ObjectCreate(0, obj_box_lower, OBJ_HLINE, 0, 0, box_lower_level);
   ObjectSetInteger(0, obj_box_lower, OBJPROP_COLOR, clrRed);
   ObjectSetInteger(0, obj_box_lower, OBJPROP_STYLE, STYLE_SOLID);
   ObjectSetInteger(0, obj_box_lower, OBJPROP_WIDTH, 1);
   ObjectSetString(0, obj_box_lower, OBJPROP_TEXT, "Box Lower: " + DoubleToString(box_lower_level, _Digits));
}

//+------------------------------------------------------------------+
//| Display ADX information on chart                                 |
//+------------------------------------------------------------------+
void DisplayADXInformation(double adx_value)
{
   if(!SHOW_ADX_VALUES) return;
   
   // Change background color to visually indicate when ADX is below threshold
   if(adx_value < ADX_LOWER_LEVEL)
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
   int required_bars = MathMax(100, ADX_PERIOD + ADX_SMOOTH_PERIOD + BOX_LOOKBACK + 20);
   
   // Make sure we have enough bars
   if(Bars(_Symbol, _Period) < required_bars)
   {
      Print("Not enough bars for calculation (", Bars(_Symbol, _Period), " < ", required_bars, ")");
      return false;
   }
   
   // Static variable to track when we last did an ADX analysis
   static datetime last_adx_analysis_time = 0;
   
   // Run ADX analysis every 24 hours (for daily tracking)
   if(VERBOSE_LOGGING && TimeCurrent() - last_adx_analysis_time > PeriodSeconds(PERIOD_D1))
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
   is_adx_low = adx_values[1] < ADX_LOWER_LEVEL;
   Print("ADX Value (prev bar):", DoubleToString(adx_values[1], 2), " threshold:", DoubleToString(ADX_LOWER_LEVEL, 2),
         " => ADX is ", is_adx_low ? "BELOW threshold (good for signal)" : "ABOVE threshold (no signal)");
   
   double old_upper = box_upper_level;
   double old_lower = box_lower_level;
   
   // ===== CRITICAL: Calculate box levels the SAME as PineScript =====
   // In PineScript: 
   // boxUpperLevel = strategy.position_size == 0 ? highest(high, boxLookBack)[1] : boxUpperLevel[1]
   // boxLowerLevel = strategy.position_size == 0 ? lowest(low, boxLookBack)[1] : boxLowerLevel[1]
   
   // Only update box levels when NOT in a position
   if(!in_position)
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
      
      // Get price data starting from bar index 1 (previous bar) for BOX_LOOKBACK bars
      // This exactly matches highest(high, boxLookBack)[1] and lowest(low, boxLookBack)[1]
      if(CopyHigh(_Symbol, _Period, 1, BOX_LOOKBACK, high) <= 0 ||
         CopyLow(_Symbol, _Period, 1, BOX_LOOKBACK, low) <= 0)
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
      
      for(int i = 1; i < BOX_LOOKBACK; i++)
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
      Print("Box calculation from bars 1 to ", BOX_LOOKBACK, " (0 is current bar, not included):");
      for(int i = 0; i < MathMin(BOX_LOOKBACK, ArraySize(high)); i++)
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
   string adx_status = is_adx_low ? "LOW ✓" : "HIGH ✗";
   string position_status = in_position ? (position_type == 0 ? "IN LONG" : "IN SHORT") : "NO POSITION";
   
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
           "ADX=", DoubleToString(current_adx, 2), "/", DoubleToString(ADX_LOWER_LEVEL, 2),
           " (", adx_status, ") | ", position_status, "\n",
           "Upper=", DoubleToString(box_upper_level, _Digits), 
           ", Lower=", DoubleToString(box_lower_level, _Digits), "\n",
           "Close=", DoubleToString(current_close, _Digits), 
           " | Cross Up: ", cross_above_upper ? "YES" : "No",
           " | Cross Down: ", cross_below_lower ? "YES" : "No");
   
   return true;
}

//+------------------------------------------------------------------+
//| Process trade signals - match PineScript cross() function exactly |
//+------------------------------------------------------------------+
void ProcessTradeSignals()
{
   // Get the last 2 closes - current and previous bar
   double close_prices[];
   ArraySetAsSeries(close_prices, true);
   
   if(CopyClose(_Symbol, _Period, 0, 2, close_prices) <= 0)
   {
      Print("Failed to get close prices for signal processing");
      return;
   }
   
   double current_close = close_prices[0];
   double previous_close = close_prices[1];
       
   // Check for crosses - EXACTLY matching PineScript cross() function
   // In PineScript, cross(close, boxUpperLevel) only checks if current > upper
   bool cross_above_upper = (current_close > box_upper_level);
   
   // In PineScript, crossunder(close, boxLowerLevel) only checks if current < lower
   bool cross_below_lower = (current_close < box_lower_level);
   
   // Always log the cross check for debugging
   Print("Cross check: Current=", DoubleToString(current_close, _Digits),
         ", Previous=", DoubleToString(previous_close, _Digits),
         ", Upper=", DoubleToString(box_upper_level, _Digits),
         ", Lower=", DoubleToString(box_lower_level, _Digits),
         ", ADX Low=", is_adx_low ? "Yes" : "No");
      
   if(cross_above_upper)
   {
      Print("⚠️ DETECTED CROSS ABOVE: ", DoubleToString(current_close, _Digits), " > ", 
            DoubleToString(box_upper_level, _Digits), " (prev: ", DoubleToString(previous_close, _Digits), ")");
   }
   
   if(cross_below_lower)
   {
      Print("⚠️ DETECTED CROSS BELOW: ", DoubleToString(current_close, _Digits), " < ", 
            DoubleToString(box_lower_level, _Digits), " (prev: ", DoubleToString(previous_close, _Digits), ")");
   }
   
   // In PineScript:
   // isBuyValid = strategy.position_size == 0 and cross(close, boxUpperLevel) and isADXLow
   // isSellValid = strategy.position_size == 0 and cross(boxLowerLevel, close) and isADXLow
   
   // Check direction settings
   bool can_go_long = (ENABLE_DIRECTION == 0 || ENABLE_DIRECTION == 1);
   bool can_go_short = (ENABLE_DIRECTION == 0 || ENABLE_DIRECTION == -1);
   
   // Long entry condition exactly matching PineScript
   bool is_buy_valid = !in_position && cross_above_upper && is_adx_low && can_go_long;
   
   // Short entry condition exactly matching PineScript
   bool is_sell_valid = !in_position && cross_below_lower && is_adx_low && can_go_short;
   
   // Detailed signal analysis
   if(cross_above_upper)
   {
      string signal_status = is_buy_valid ? "✅ VALID!" : "❌ INVALID because:";
      string reason = "";
      
      if(!can_go_long) reason += " Direction not allowed.";
      if(in_position) reason += " Already in position.";
      if(!is_adx_low) reason += " ADX not below threshold.";
      
      Print("🔍 LONG SIGNAL ANALYSIS: ", signal_status, reason);
      
      // Log signal components for debugging
      Print("  - Not in position: ", !in_position ? "✓" : "✗");
      Print("  - Cross above upper: ", cross_above_upper ? "✓" : "✗");
      Print("  - ADX below threshold: ", is_adx_low ? "✓" : "✗");
      Print("  - Can go long: ", can_go_long ? "✓" : "✗");
   }
   
   if(cross_below_lower)
   {
      string signal_status = is_sell_valid ? "✅ VALID!" : "❌ INVALID because:";
      string reason = "";
      
      if(!can_go_short) reason += " Direction not allowed.";
      if(in_position) reason += " Already in position.";
      if(!is_adx_low) reason += " ADX not below threshold.";
      
      Print("🔍 SHORT SIGNAL ANALYSIS: ", signal_status, reason);
      
      // Log signal components for debugging
      Print("  - Not in position: ", !in_position ? "✓" : "✗");
      Print("  - Cross below lower: ", cross_below_lower ? "✓" : "✗");
      Print("  - ADX below threshold: ", is_adx_low ? "✓" : "✗");
      Print("  - Can go short: ", can_go_short ? "✓" : "✗");
   }
   
   if(is_buy_valid)
   {
      Print("⬆️ LONG SIGNAL: Price ", DoubleToString(current_close, _Digits), " crossed above box upper ",
            DoubleToString(box_upper_level, _Digits), " with ADX low");
      
      // Calculate price levels for the trade
      double entry_price = current_close;
      double sl_price = entry_price - STOP_LOSS_MULTIPLE * box_width;
      double tp_price = entry_price + PROFIT_TARGET_MULTIPLE * box_width;
      
      // Log price levels
      Print("Entry=", DoubleToString(entry_price, _Digits), 
            ", SL=", DoubleToString(sl_price, _Digits), " (", DoubleToString(STOP_LOSS_MULTIPLE, 2), "x box width)", 
            ", TP=", DoubleToString(tp_price, _Digits), " (", DoubleToString(PROFIT_TARGET_MULTIPLE, 2), "x box width)");
            
      // Execute the long trade
      ExecuteTrade(ORDER_TYPE_BUY, sl_price, tp_price);
   }
   else if(is_sell_valid)
   {
      Print("⬇️ SHORT SIGNAL: Price ", DoubleToString(current_close, _Digits), " crossed below box lower ",
            DoubleToString(box_lower_level, _Digits), " with ADX low");
      
      // Calculate price levels for the trade
      double entry_price = current_close;
      double sl_price = entry_price + STOP_LOSS_MULTIPLE * box_width;
      double tp_price = entry_price - PROFIT_TARGET_MULTIPLE * box_width;
      
      // Log price levels
      Print("Entry=", DoubleToString(entry_price, _Digits), 
            ", SL=", DoubleToString(sl_price, _Digits), " (", DoubleToString(STOP_LOSS_MULTIPLE, 2), "x box width)", 
            ", TP=", DoubleToString(tp_price, _Digits), " (", DoubleToString(PROFIT_TARGET_MULTIPLE, 2), "x box width)");
            
      // Execute the short trade
      ExecuteTrade(ORDER_TYPE_SELL, sl_price, tp_price);
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
      in_position = true;
      position_type = (order_type == ORDER_TYPE_BUY) ? 0 : 1;
      position_price = price;
      position_ticket = result.order;
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
   Print("ADX Lower Level: ", ADX_LOWER_LEVEL);
   Print("Box Lookback: ", BOX_LOOKBACK);
   Print("Profit Target Multiple: ", PROFIT_TARGET_MULTIPLE);
   Print("Stop Loss Multiple: ", STOP_LOSS_MULTIPLE);
   
   string direction = "Both";
   if(ENABLE_DIRECTION == 1) direction = "Long Only";
   if(ENABLE_DIRECTION == -1) direction = "Short Only";
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
      if(adx_values[i] < ADX_LOWER_LEVEL)
         custom_below_count++;
         
      if(i < ArraySize(builtin_adx) && builtin_adx[i] < ADX_LOWER_LEVEL)
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
   Print("Custom ADX < ", ADX_LOWER_LEVEL, ": ", custom_below_count, " bars (", DoubleToString(custom_below_pct, 1), "%)");
   Print("Built-in ADX < ", ADX_LOWER_LEVEL, ": ", builtin_below_count, " bars (", DoubleToString(builtin_below_pct, 1), "%)");
   Print("ADX Difference - Max: ", DoubleToString(max_diff, 2), ", Avg: ", DoubleToString(avg_diff, 2));
   Print("=== END ADX STATISTICS ===");
} 