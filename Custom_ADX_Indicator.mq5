//+------------------------------------------------------------------+
//|                                          Custom_ADX_Indicator.mq5 |
//|                                       Based on Wilder's smoothing |
//|                                                                  |
//+------------------------------------------------------------------+
#property copyright "Copyright 2023"
#property link      "https://www.example.com"
#property version   "1.00"
#property indicator_separate_window
#property indicator_buffers 2
#property indicator_plots   2

// Plot properties for ADX line
#property indicator_label1  "Custom ADX"
#property indicator_type1   DRAW_LINE
#property indicator_color1  clrMagenta
#property indicator_style1  STYLE_SOLID
#property indicator_width1  2

// Plot properties for ADX threshold
#property indicator_label2  "ADX Threshold"
#property indicator_type2   DRAW_LINE
#property indicator_color2  clrGreen
#property indicator_style2  STYLE_DASH
#property indicator_width2  1

// Input parameters - matching the EA
input int                ADX_SMOOTH_PERIOD = 14;        // ADX Smoothing Period
input int                ADX_PERIOD = 14;               // ADX Period
input double             ADX_LOWER_LEVEL = 18;          // ADX Lower Level
input bool               FILL_BELOW_LEVEL = true;       // Fill area below threshold level
input color              FILL_COLOR = clrLavender;      // Fill color

// Indicator buffers
double ADXBuffer[];
double ThresholdBuffer[];

//+------------------------------------------------------------------+
//| Custom indicator initialization function                         |
//+------------------------------------------------------------------+
int OnInit()
{
   // Set indicator buffers
   SetIndexBuffer(0, ADXBuffer, INDICATOR_DATA);
   SetIndexBuffer(1, ThresholdBuffer, INDICATOR_DATA);
   
   // Set indicator labels
   PlotIndexSetString(0, PLOT_LABEL, "Custom ADX");
   PlotIndexSetString(1, PLOT_LABEL, "ADX Threshold");
   
   // Set indicator name
   IndicatorSetString(INDICATOR_SHORTNAME, "Custom ADX (Wilder's Method)");
   
   // Set indicator levels
   IndicatorSetInteger(INDICATOR_LEVELS, 1);
   IndicatorSetDouble(INDICATOR_LEVELVALUE, 0, ADX_LOWER_LEVEL);
   IndicatorSetString(INDICATOR_LEVELTEXT, 0, "ADX Threshold: " + DoubleToString(ADX_LOWER_LEVEL, 1));
   IndicatorSetInteger(INDICATOR_LEVELCOLOR, 0, clrGreen);
   IndicatorSetInteger(INDICATOR_LEVELSTYLE, 0, STYLE_DASH);
   
   // Set up area fill below threshold if enabled
   if(FILL_BELOW_LEVEL)
   {
      PlotIndexSetInteger(0, PLOT_DRAW_BEGIN, ADX_PERIOD + ADX_SMOOTH_PERIOD);
      PlotIndexSetInteger(0, PLOT_SHOW_DATA, true);
      PlotIndexSetInteger(0, PLOT_DRAW_TYPE, DRAW_FILLING);
      PlotIndexSetInteger(0, PLOT_COLOR, FILL_COLOR);
      PlotIndexSetInteger(0, PLOT_COLOR2, FILL_COLOR);
   }
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Custom indicator iteration function                              |
//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
{
   // Check if we have enough bars to calculate
   if(rates_total < ADX_PERIOD + ADX_SMOOTH_PERIOD)
   {
      Print("Not enough bars for calculation");
      return(0);
   }
   
   // Calculate starting position
   int start_pos;
   if(prev_calculated > rates_total || prev_calculated <= 0)
   {
      // Initial calculation
      ArrayInitialize(ThresholdBuffer, ADX_LOWER_LEVEL); // Set all threshold values
      start_pos = rates_total - 1 - (ADX_PERIOD + ADX_SMOOTH_PERIOD); // Leave room for calculation
      if(start_pos < 0) start_pos = 0;
   }
   else
   {
      // Subsequent calculations - only calculate new bars
      start_pos = prev_calculated - 1;
   }
   
   // Calculate ADX for each bar
   CalculateCustomADX(start_pos, rates_total, high, low, close, ADXBuffer);
   
   return(rates_total);
}

//+------------------------------------------------------------------+
//| Calculate ADX using Wilder's smoothing method                    |
//+------------------------------------------------------------------+
void CalculateCustomADX(const int start_pos, const int rates_total,
                        const double &high[], const double &low[], 
                        const double &close[], double &adx_buffer[])
{
   // Arrays for calculations
   double tr_array[];
   double plus_dm_array[];
   double minus_dm_array[];
   double smoothed_tr[];
   double smoothed_plus_dm[];
   double smoothed_minus_dm[];
   double di_plus[];
   double di_minus[];
   double dx[];
   
   // Allocate memory for the arrays
   ArrayResize(tr_array, rates_total);
   ArrayResize(plus_dm_array, rates_total);
   ArrayResize(minus_dm_array, rates_total);
   ArrayResize(smoothed_tr, rates_total);
   ArrayResize(smoothed_plus_dm, rates_total);
   ArrayResize(smoothed_minus_dm, rates_total);
   ArrayResize(di_plus, rates_total);
   ArrayResize(di_minus, rates_total);
   ArrayResize(dx, rates_total);
   
   // Calculate TR, +DM, -DM for all required bars
   for(int i = rates_total - 2; i >= start_pos; i--)
   {
      // True Range calculation
      double hl = high[i] - low[i];
      double hpc = MathAbs(high[i] - close[i+1]);
      double lpc = MathAbs(low[i] - close[i+1]);
      tr_array[i] = MathMax(hl, MathMax(hpc, lpc));
      
      // Directional Movement
      double up_move = high[i] - high[i+1];
      double down_move = low[i+1] - low[i];
      
      // Calculate +DM and -DM exactly as in EA
      if(up_move > down_move && up_move > 0)
         plus_dm_array[i] = up_move;
      else
         plus_dm_array[i] = 0;
         
      if(down_move > up_move && down_move > 0)
         minus_dm_array[i] = down_move;
      else
         minus_dm_array[i] = 0;
   }
   
   // Calculate Wilder's smoothing
   // First, calculate simple average for first period
   int first_idx = rates_total - ADX_PERIOD;
   if(first_idx < start_pos) first_idx = start_pos;
   
   double sum_tr = 0;
   double sum_plus_dm = 0;
   double sum_minus_dm = 0;
   
   for(int i = first_idx + ADX_PERIOD - 1; i >= first_idx; i--)
   {
      sum_tr += tr_array[i];
      sum_plus_dm += plus_dm_array[i];
      sum_minus_dm += minus_dm_array[i];
   }
   
   // Initialize first smoothed values
   smoothed_tr[first_idx] = sum_tr;
   smoothed_plus_dm[first_idx] = sum_plus_dm;
   smoothed_minus_dm[first_idx] = sum_minus_dm;
   
   // Continue with Wilder's smoothing
   for(int i = first_idx - 1; i >= start_pos; i--)
   {
      smoothed_tr[i] = smoothed_tr[i+1] - (smoothed_tr[i+1] / ADX_PERIOD) + tr_array[i];
      smoothed_plus_dm[i] = smoothed_plus_dm[i+1] - (smoothed_plus_dm[i+1] / ADX_PERIOD) + plus_dm_array[i];
      smoothed_minus_dm[i] = smoothed_minus_dm[i+1] - (smoothed_minus_dm[i+1] / ADX_PERIOD) + minus_dm_array[i];
      
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
   
   // Apply smoothing to DX to get ADX
   int adx_start = first_idx - ADX_SMOOTH_PERIOD;
   if(adx_start < start_pos) adx_start = start_pos;
   
   // Calculate first ADX as simple average of DX
   double sum_dx = 0;
   for(int i = adx_start + ADX_SMOOTH_PERIOD - 1; i >= adx_start; i--)
   {
      sum_dx += dx[i];
   }
   
   adx_buffer[adx_start] = sum_dx / ADX_SMOOTH_PERIOD;
   
   // Calculate remaining ADX values using Wilder's smoothing
   for(int i = adx_start - 1; i >= start_pos; i--)
   {
      adx_buffer[i] = ((adx_buffer[i+1] * (ADX_SMOOTH_PERIOD - 1)) + dx[i]) / ADX_SMOOTH_PERIOD;
   }
} 