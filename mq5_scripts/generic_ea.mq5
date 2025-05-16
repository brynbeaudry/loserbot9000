//+------------------------------------------------------------------+
//|                                                      generic_ea.mq5 |
//|                        Copyright 2024, MetaQuotes Software Corp. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024"
#property link      "https://www.mql5.com"
#property version   "1.00"

// Strategy Overview:
// This is a generic template for creating Expert Advisors in MQL5.
// It provides a well-structured foundation with common functionality
// that can be extended for specific trading strategies.
//
// Template Features:
// 1. Standard EA lifecycle management (OnInit, OnDeinit, OnTick)
// 2. Position management and tracking
// 3. Trade execution with proper error handling
// 4. Risk management utilities
// 5. Logging and debugging support
// 6. Chart visualization capabilities

// Strategy Parameters
input group "Strategy Parameters"
input int                STRATEGY_PERIOD = 14;          // Strategy Calculation Period
input double             ENTRY_THRESHOLD = 0.0;         // Entry Signal Threshold
input double             EXIT_THRESHOLD = 0.0;          // Exit Signal Threshold

input group "Risk Management"
input double             RISK_PERCENT = 1.0;            // Risk Per Trade (%)
input double             REWARD_RATIO = 2.0;            // Risk:Reward Ratio
input double             MAX_DAILY_LOSS = 5.0;          // Maximum Daily Loss (%)
input double             MAX_DAILY_TRADES = 5;          // Maximum Daily Trades

input group "Trade Settings"
input int                TRADE_DIRECTION = 0;           // Trade Direction: Both(0), Long(1), Short(-1)
input double             TRADE_VOLUME = 0.1;            // Position Size in Lots
input int                MAGIC_NUMBER = 123456;         // Unique Identifier for EA Orders

input group "Visualization"
input bool               ENABLE_LOGGING = true;         // Enable Detailed Logging
input bool               SHOW_INDICATORS = true;         // Display Indicators on Chart
input bool               SHOW_TRADE_INFO = true;        // Show Trade Information on Chart

// Global State Variables
bool                     is_in_position;                // Current Position Status
int                      current_position_type;         // Current Position Type (0=Long, 1=Short, -1=None)
double                   position_entry_price;          // Current Position Entry Price
ulong                    current_position_ticket;       // Current Position Ticket
datetime                 last_processed_bar_time;       // Last Bar Processing Time
int                      daily_trade_count;             // Number of Trades Today
double                   daily_pnl;                     // Daily Profit/Loss

// Chart Object Names
string                   indicator_line = "Indicator_Line";
string                   signal_line = "Signal_Line";

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   // Initialize state variables
   is_in_position = false;
   current_position_type = -1;
   position_entry_price = 0.0;
   current_position_ticket = 0;
   last_processed_bar_time = 0;
   daily_trade_count = 0;
   daily_pnl = 0.0;
   
   // Print strategy configuration
   PrintConfig();
   
   // Clear any existing chart objects
   ClearChartObjects();
   
   // Initialize indicators if needed
   if(!InitializeIndicators())
   {
      Print("Error: Failed to initialize indicators");
      return INIT_FAILED;
   }
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   // Clean up chart objects
   ClearChartObjects();
   
   // Clear chart comment
   Comment("");
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // Check for new bar
   if(!IsNewBar())
      return;
      
   // Update position status
   UpdatePositionStatus();
   
   // Update daily statistics
   UpdateDailyStats();
   
   // Calculate strategy signals
   if(!CalculateSignals())
   {
      Print("Error: Failed to calculate signals");
      return;
   }
   
   // Process trade signals
   ProcessTradeSignals();
   
   // Update chart visualization
   UpdateChartVisualization();
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
//| Update position status                                           |
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
         if(PositionSelectByTicket(ticket))
         {
            if(PositionGetInteger(POSITION_MAGIC) == MAGIC_NUMBER && 
               PositionGetString(POSITION_SYMBOL) == _Symbol)
            {
               is_in_position = true;
               current_position_ticket = ticket;
               current_position_type = (int)PositionGetInteger(POSITION_TYPE);
               position_entry_price = PositionGetDouble(POSITION_PRICE_OPEN);
               break;
            }
         }
      }
   }
   
   // Log position status change
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
//| Update daily trading statistics                                  |
//+------------------------------------------------------------------+
void UpdateDailyStats()
{
   static datetime last_day = 0;
   datetime current_day = TimeCurrent();
   
   // Reset daily stats at the start of a new day
   if(TimeDay(current_day) != TimeDay(last_day))
   {
      daily_trade_count = 0;
      daily_pnl = 0.0;
      last_day = current_day;
   }
}

//+------------------------------------------------------------------+
//| Calculate strategy signals                                       |
//+------------------------------------------------------------------+
bool CalculateSignals()
{
   // TODO: Implement your strategy's signal calculation logic here
   // This is where you would:
   // 1. Calculate technical indicators
   // 2. Generate entry/exit signals
   // 3. Update any strategy-specific variables
   
   return true;
}

//+------------------------------------------------------------------+
//| Process trade signals                                            |
//+------------------------------------------------------------------+
void ProcessTradeSignals()
{
   // TODO: Implement your strategy's trade signal processing logic here
   // This is where you would:
   // 1. Check entry conditions
   // 2. Validate trade setup
   // 3. Calculate position size
   // 4. Execute trades
   
   // Example structure:
   if(!is_in_position)
   {
      // Check entry conditions
      bool can_trade_long = (TRADE_DIRECTION == 0 || TRADE_DIRECTION == 1);
      bool can_trade_short = (TRADE_DIRECTION == 0 || TRADE_DIRECTION == -1);
      
      // TODO: Add your entry conditions here
      bool long_entry_valid = false;  // Replace with your conditions
      bool short_entry_valid = false; // Replace with your conditions
      
      if(long_entry_valid && can_trade_long)
      {
         // Calculate trade levels
         double entry_price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double stop_loss = CalculateStopLoss(ORDER_TYPE_BUY, entry_price);
         double take_profit = CalculateTakeProfit(ORDER_TYPE_BUY, entry_price, stop_loss);
         
         // Execute long trade
         ExecuteTrade(ORDER_TYPE_BUY, stop_loss, take_profit);
      }
      else if(short_entry_valid && can_trade_short)
      {
         // Calculate trade levels
         double entry_price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double stop_loss = CalculateStopLoss(ORDER_TYPE_SELL, entry_price);
         double take_profit = CalculateTakeProfit(ORDER_TYPE_SELL, entry_price, stop_loss);
         
         // Execute short trade
         ExecuteTrade(ORDER_TYPE_SELL, stop_loss, take_profit);
      }
   }
}

//+------------------------------------------------------------------+
//| Calculate stop loss level                                        |
//+------------------------------------------------------------------+
double CalculateStopLoss(ENUM_ORDER_TYPE order_type, double entry_price)
{
   // TODO: Implement your stop loss calculation logic here
   // This is where you would:
   // 1. Calculate stop loss based on your strategy
   // 2. Apply risk management rules
   // 3. Ensure stop loss is valid for the symbol
   
   return 0.0; // Replace with your calculation
}

//+------------------------------------------------------------------+
//| Calculate take profit level                                      |
//+------------------------------------------------------------------+
double CalculateTakeProfit(ENUM_ORDER_TYPE order_type, double entry_price, double stop_loss)
{
   // TODO: Implement your take profit calculation logic here
   // This is where you would:
   // 1. Calculate take profit based on your strategy
   // 2. Apply risk:reward ratio
   // 3. Ensure take profit is valid for the symbol
   
   return 0.0; // Replace with your calculation
}

//+------------------------------------------------------------------+
//| Execute a trade with stop loss and take profit                   |
//+------------------------------------------------------------------+
void ExecuteTrade(ENUM_ORDER_TYPE order_type, double stop_loss, double take_profit)
{
   // Validate trade limits
   if(daily_trade_count >= MAX_DAILY_TRADES)
   {
      Print("Warning: Maximum daily trades reached");
      return;
   }
   
   // Calculate position size based on risk
   double position_size = CalculatePositionSize(order_type, stop_loss);
   
   // Prepare trade request
   MqlTradeRequest request = {};
   MqlTradeResult result = {};
   
   request.action = TRADE_ACTION_DEAL;
   request.symbol = _Symbol;
   request.volume = position_size;
   request.type = order_type;
   request.price = (order_type == ORDER_TYPE_BUY) ? 
                  SymbolInfoDouble(_Symbol, SYMBOL_ASK) : 
                  SymbolInfoDouble(_Symbol, SYMBOL_BID);
   request.sl = stop_loss;
   request.tp = take_profit;
   request.deviation = 10;
   request.magic = MAGIC_NUMBER;
   request.comment = "Generic EA";
   request.type_filling = ORDER_FILLING_FOK;
   
   // Execute the trade
   if(!OrderSend(request, result))
   {
      Print("Error: OrderSend failed. Error code: ", GetLastError());
      return;
   }
   
   // Check the result
   if(result.retcode == TRADE_RETCODE_DONE)
   {
      Print("✅ Trade executed successfully. Ticket: ", result.order);
      daily_trade_count++;
      
      // Update position tracking
      is_in_position = true;
      current_position_type = (order_type == ORDER_TYPE_BUY) ? 0 : 1;
      position_entry_price = request.price;
      current_position_ticket = result.order;
   }
   else
   {
      Print("❌ Trade execution failed. Error code: ", result.retcode);
   }
}

//+------------------------------------------------------------------+
//| Calculate position size based on risk                            |
//+------------------------------------------------------------------+
double CalculatePositionSize(ENUM_ORDER_TYPE order_type, double stop_loss)
{
   double account_balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double risk_amount = account_balance * RISK_PERCENT / 100.0;
   
   double entry_price = (order_type == ORDER_TYPE_BUY) ? 
                       SymbolInfoDouble(_Symbol, SYMBOL_ASK) : 
                       SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   double stop_distance = MathAbs(entry_price - stop_loss);
   double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   
   double position_size = risk_amount / (stop_distance / tick_size * tick_value);
   
   // Normalize position size to symbol lot step
   double lot_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   position_size = MathFloor(position_size / lot_step) * lot_step;
   
   // Ensure position size is within allowed limits
   double min_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double max_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   
   position_size = MathMax(min_lot, MathMin(max_lot, position_size));
   
   return position_size;
}

//+------------------------------------------------------------------+
//| Initialize technical indicators                                  |
//+------------------------------------------------------------------+
bool InitializeIndicators()
{
   // TODO: Initialize your strategy's indicators here
   // This is where you would:
   // 1. Create indicator handles
   // 2. Validate indicator initialization
   // 3. Set up any indicator-specific parameters
   
   return true;
}

//+------------------------------------------------------------------+
//| Update chart visualization                                       |
//+------------------------------------------------------------------+
void UpdateChartVisualization()
{
   if(!SHOW_INDICATORS && !SHOW_TRADE_INFO)
      return;
      
   // TODO: Implement your chart visualization logic here
   // This is where you would:
   // 1. Draw indicator lines
   // 2. Show trade information
   // 3. Update chart objects
}

//+------------------------------------------------------------------+
//| Clear all chart objects                                          |
//+------------------------------------------------------------------+
void ClearChartObjects()
{
   ObjectsDeleteAll(0, "Indicator_");
   ObjectsDeleteAll(0, "Signal_");
}

//+------------------------------------------------------------------+
//| Print strategy configuration                                     |
//+------------------------------------------------------------------+
void PrintConfig()
{
   Print("=== Strategy Configuration ===");
   Print("Strategy Period: ", STRATEGY_PERIOD);
   Print("Entry Threshold: ", ENTRY_THRESHOLD);
   Print("Exit Threshold: ", EXIT_THRESHOLD);
   Print("Risk Per Trade: ", RISK_PERCENT, "%");
   Print("Reward Ratio: ", REWARD_RATIO);
   Print("Max Daily Loss: ", MAX_DAILY_LOSS, "%");
   Print("Max Daily Trades: ", MAX_DAILY_TRADES);
   
   string direction = "Both";
   if(TRADE_DIRECTION == 1) direction = "Long Only";
   if(TRADE_DIRECTION == -1) direction = "Short Only";
   Print("Trade Direction: ", direction);
   
   Print("Trade Volume: ", TRADE_VOLUME, " lots");
   Print("Magic Number: ", MAGIC_NUMBER);
   Print("============================");
}
