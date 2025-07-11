//+------------------------------------------------------------------+
//|                                               GoLongBTC.mq5      |
//|                                                                  |
//|                                                                  |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025"
#property link      ""
#property version   "1.00"

#include <Trade\Trade.mqh>

//============================================================================
//                           USER SETTINGS
//============================================================================

// Trade Configuration
input int MAGIC_NUMBER = 20250128;                                    // MAGIC_NUMBER: Magic number for this EA
input double RISK_PERCENT = 100.0;                                    // RISK_PERCENT: Risk percentage (100% = risk to zero)

// Trading Schedule
input int ENTRY_HOUR = 1;                                             // ENTRY_HOUR: Entry hour (0-23, broker time GMT+2)
input int ENTRY_MINUTE = 5;                                           // ENTRY_MINUTE: Entry minute (0-59)
input int EXIT_HOUR = 23;                                             // EXIT_HOUR: Exit hour (0-23, broker time GMT+2)
input int EXIT_MINUTE = 50;                                           // EXIT_MINUTE: Exit minute (0-59)

// Logging and Alerts
input bool ENABLE_LOGGING = false;                                    // ENABLE_LOGGING: Enable detailed logging
input bool USE_SOUND = false;                                         // USE_SOUND: Use sound alerts
input string SOUND_FILE = "alert.wav";                               // SOUND_FILE: Sound file for alerts

// Volatility Filter
input bool ENABLE_VOLATILITY_FILTER = false;                         // ENABLE_VOLATILITY_FILTER: Enable volatility filter (trade only on high vol days)
input int VOL_CALC_HOUR = 0;                                          // VOL_CALC_HOUR: Hour to calculate volatility (0-23, GMT+2)
input int VOL_CALC_MINUTE = 0;                                        // VOL_CALC_MINUTE: Minute to calculate volatility (0-59)

// Trading Rules
input bool SKIP_FRIDAY_TO_SATURDAY_TRADES = false;                   // SKIP_FRIDAY_TO_SATURDAY_TRADES: Skip trades that would close on Saturday
input bool USE_CUSTOM_SPREAD = false;                                // USE_CUSTOM_SPREAD: Use custom spread instead of broker spread
input double CUSTOM_SPREAD_POINTS = 1600.0;                          // CUSTOM_SPREAD_POINTS: Custom spread in points (1600 = $16 for BTC)

// Global variables
datetime lastTradeDate;                    // Date of the last trade (actual trade execution)
datetime currentTradingDate;               // Current trading date being processed
bool     tradeTakenToday;                  // Flag to ensure only one trade per day
ulong    positionTicket;                   // Current position ticket
datetime entryTime;                        // Time when position was opened
CTrade   trade;                            // Trade object
datetime lastMarketClosedAlert;            // Last time we alerted about market being closed
bool     waitingForMarketOpen;             // Flag to indicate we're waiting for market to reopen
double   actualEntryPrice;                 // Actual entry price for spread calculation

// Volatility filter tracking
int      tradesSkippedByVolFilter;         // Count of trades skipped by volatility filter
int      tradesAllowedByVolFilter;         // Count of trades allowed by volatility filter
datetime lastVolFilterCheck;               // Last time we checked volatility filter

// Symbol information cache
struct SymbolCache {
   double point;
   double tickValue;
   double tickSize;
   double minLot;
   double maxLot;
   double lotStep;
   int digits;
   bool isValid;
};
SymbolCache symbolCache;

// Volatility filter variables
#define MAX_DAILY_CLOSES 366        // Store 366 daily closes (1 year + 1 for calculations)
#define VOLATILITY_LOOKBACK 30      // 30-day lookback for HV calculation
#define MEDIAN_LOOKBACK 365         // 365-day lookback for median calculation

double dailyCloses[];               // Array to store daily close prices
double dailyLogReturns[];           // Array to store daily log returns
double rollingHVValues[];           // Array to store 365 rolling 30-day HV values
datetime lastVolCalcDate;           // Last date volatility was calculated
double current30DayHV;              // Current 30-day historical volatility
double median365DayHV;              // Median of 365-day rolling HV values
bool volatilityFilterPassed;        // Whether current day passes volatility filter
int dailyClosesCount;               // Number of daily closes stored
int hvValuesCount;                  // Number of HV values stored

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   // Validate input parameters
   if(ENTRY_HOUR < 0 || ENTRY_HOUR > 23)
   {
      Print("ERROR: ENTRY_HOUR must be between 0-23. Current value: ", ENTRY_HOUR);
      Print("Use 0 for midnight, not 24");
      return(INIT_PARAMETERS_INCORRECT);
   }

   if(EXIT_HOUR < 0 || EXIT_HOUR > 23)
   {
      Print("ERROR: EXIT_HOUR must be between 0-23. Current value: ", EXIT_HOUR);
      Print("Use 0 for midnight, not 24");
      return(INIT_PARAMETERS_INCORRECT);
   }

   if(ENTRY_MINUTE < 0 || ENTRY_MINUTE > 59)
   {
      Print("ERROR: ENTRY_MINUTE must be between 0-59. Current value: ", ENTRY_MINUTE);
      return(INIT_PARAMETERS_INCORRECT);
   }

   if(EXIT_MINUTE < 0 || EXIT_MINUTE > 59)
   {
      Print("ERROR: EXIT_MINUTE must be between 0-59. Current value: ", EXIT_MINUTE);
      return(INIT_PARAMETERS_INCORRECT);
   }

   if(ENABLE_VOLATILITY_FILTER)
   {
      if(VOL_CALC_HOUR < 0 || VOL_CALC_HOUR > 23)
      {
         Print("ERROR: VOL_CALC_HOUR must be between 0-23. Current value: ", VOL_CALC_HOUR);
         return(INIT_PARAMETERS_INCORRECT);
      }

      if(VOL_CALC_MINUTE < 0 || VOL_CALC_MINUTE > 59)
      {
         Print("ERROR: VOL_CALC_MINUTE must be between 0-59. Current value: ", VOL_CALC_MINUTE);
         return(INIT_PARAMETERS_INCORRECT);
      }
   }

   // Set trade parameters
   trade.SetExpertMagicNumber(MAGIC_NUMBER);
   trade.SetDeviationInPoints(10);

   // Initialize variables
   lastTradeDate = 0;
   currentTradingDate = 0;
   tradeTakenToday = false;
   positionTicket = 0;
   entryTime = 0;
   lastMarketClosedAlert = 0;
   waitingForMarketOpen = false;
   actualEntryPrice = 0;

   // Initialize volatility filter variables
   dailyClosesCount = 0;
   hvValuesCount = 0;
   lastVolCalcDate = 0;
   current30DayHV = 0;
   median365DayHV = 0;
   volatilityFilterPassed = true;  // Default to allowing trades until we have data
   tradesSkippedByVolFilter = 0;
   tradesAllowedByVolFilter = 0;
   lastVolFilterCheck = 0;

   // Initialize arrays
   ArrayResize(dailyCloses, 0);
   ArrayResize(dailyLogReturns, 0);
   ArrayResize(rollingHVValues, 0);

   // Update symbol cache
   UpdateSymbolCache();

   // Validate symbol
   if(_Symbol != "BTCUSD" && StringFind(_Symbol, "BTC") == -1)
   {
      Print("WARNING: This EA is designed for Bitcoin (BTCUSD). Current symbol: ", _Symbol);
   }

   Print("GoLongBTC EA initialized successfully");
   Print("Symbol: ", _Symbol);
   Print("Using current account balance for calculations: $", DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2));
   Print("Risk percentage: ", DoubleToString(RISK_PERCENT, 1), "%");
   Print("Entry time: ", StringFormat("%02d:%02d GMT+2 (broker server time)", ENTRY_HOUR, ENTRY_MINUTE));
   Print("Exit time: ", StringFormat("%02d:%02d GMT+2 (broker server time)", EXIT_HOUR, EXIT_MINUTE));

   // Print symbol trading session info
   datetime sessionFrom, sessionTo;
   for(int day = SUNDAY; day <= SATURDAY; day++)
   {
      if(SymbolInfoSessionTrade(_Symbol, (ENUM_DAY_OF_WEEK)day, 0, sessionFrom, sessionTo))
      {
         string dayName = "";
         switch(day)
         {
            case SUNDAY: dayName = "Sunday"; break;
            case MONDAY: dayName = "Monday"; break;
            case TUESDAY: dayName = "Tuesday"; break;
            case WEDNESDAY: dayName = "Wednesday"; break;
            case THURSDAY: dayName = "Thursday"; break;
            case FRIDAY: dayName = "Friday"; break;
            case SATURDAY: dayName = "Saturday"; break;
         }
         Print(dayName, " trading session: ", TimeToString(sessionFrom, TIME_MINUTES),
               " - ", TimeToString(sessionTo, TIME_MINUTES));
      }
   }

   // Check if exit time is next day
   if(EXIT_HOUR < ENTRY_HOUR || (EXIT_HOUR == ENTRY_HOUR && EXIT_MINUTE <= ENTRY_MINUTE))
   {
      Print("Exit time is on the NEXT DAY after entry");
   }

   // Display volatility filter settings
   if(ENABLE_VOLATILITY_FILTER)
   {
      Print("Volatility filter: ENABLED");
      Print("Volatility calculation time: ", StringFormat("%02d:%02d GMT+2", VOL_CALC_HOUR, VOL_CALC_MINUTE));
      Print("Filter logic: Trade only when 30-day HV > 365-day median HV");
   }
   else
   {
      Print("Volatility filter: DISABLED");
   }

   // Display spread settings
   if(USE_CUSTOM_SPREAD)
   {
      double spreadInPrice = CUSTOM_SPREAD_POINTS * _Point;
      Print("Custom spread: ENABLED");
      Print("Spread: ", CUSTOM_SPREAD_POINTS, " points ($", DoubleToString(spreadInPrice, 2), ")");
   }
   else
   {
      Print("Custom spread: DISABLED (using broker spread)");
   }

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   // Print volatility filter statistics on exit
   if(ENABLE_VOLATILITY_FILTER && hvValuesCount > 0)
   {
      Print("=== VOLATILITY FILTER FINAL STATISTICS ===");
      Print("Total days processed: ", hvValuesCount);

      if(hvValuesCount >= MEDIAN_LOOKBACK)
      {
         // Count how many days passed the filter
         int daysPassedFilter = 0;
         for(int i = 0; i < MEDIAN_LOOKBACK; i++)
         {
            if(rollingHVValues[i] > median365DayHV)
               daysPassedFilter++;
         }

         double passRate = (double)daysPassedFilter / MEDIAN_LOOKBACK * 100;
         Print("Days that passed filter: ", daysPassedFilter, " out of ", MEDIAN_LOOKBACK);
         Print("Filter pass rate: ", DoubleToString(passRate, 1), "%");
         Print("Final 30-day HV: ", DoubleToString(current30DayHV * 100, 2), "%");
         Print("Final Median HV: ", DoubleToString(median365DayHV * 100, 2), "%");

         // Find min and max HV values
         double minHV = rollingHVValues[0];
         double maxHV = rollingHVValues[0];
         for(int i = 1; i < MEDIAN_LOOKBACK; i++)
         {
            if(rollingHVValues[i] < minHV) minHV = rollingHVValues[i];
            if(rollingHVValues[i] > maxHV) maxHV = rollingHVValues[i];
         }
         Print("Min HV in period: ", DoubleToString(minHV * 100, 2), "%");
         Print("Max HV in period: ", DoubleToString(maxHV * 100, 2), "%");
      }

      Print("\n=== VOLATILITY FILTER TRADING RESULTS ===");
      Print("Trades allowed by filter: ", tradesAllowedByVolFilter);
      Print("Trades skipped by filter: ", tradesSkippedByVolFilter);
      int totalFilterChecks = tradesAllowedByVolFilter + tradesSkippedByVolFilter;
      if(totalFilterChecks > 0)
      {
         double filterEfficiency = (double)tradesAllowedByVolFilter / totalFilterChecks * 100;
         Print("Filter allowed ", DoubleToString(filterEfficiency, 1), "% of potential trades");
      }
   }
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // Get current server time (GMT+2)
   datetime currentTime = TimeCurrent();
   MqlDateTime timeStruct;
   TimeToStruct(currentTime, timeStruct);


   // Debug logging for first tick of each minute
   static int lastLoggedMinute = -1;
   if(timeStruct.min != lastLoggedMinute && ENABLE_LOGGING)
   {
      lastLoggedMinute = timeStruct.min;
      Print("Current time: ", StringFormat("%02d:%02d", timeStruct.hour, timeStruct.min),
            " | Entry time: ", StringFormat("%02d:%02d", ENTRY_HOUR, ENTRY_MINUTE),
            " | TradeTaken: ", tradeTakenToday ? "Yes" : "No",
            " | Position: ", positionTicket > 0 ? "Open" : "None");
   }

   // Check if it's a new trading day
   CheckNewTradingDay();

   // Check if it's time to calculate volatility
   if(ENABLE_VOLATILITY_FILTER)
   {
      bool shouldCalcVolatility = false;

      // Check if we're at the volatility calculation time
      if(timeStruct.hour == VOL_CALC_HOUR && timeStruct.min >= VOL_CALC_MINUTE && timeStruct.min < VOL_CALC_MINUTE + 5)
      {
         // Check if we haven't calculated today
         MqlDateTime lastCalcStruct;
         TimeToStruct(lastVolCalcDate, lastCalcStruct);

         if(lastVolCalcDate == 0 ||
            lastCalcStruct.year != timeStruct.year ||
            lastCalcStruct.mon != timeStruct.mon ||
            lastCalcStruct.day != timeStruct.day)
         {
            shouldCalcVolatility = true;
         }
      }

      if(shouldCalcVolatility)
      {
         if(ENABLE_LOGGING)
            Print("Calculating daily volatility at ", TimeToString(currentTime));
         CalculateDailyVolatility();
      }
   }

   // Check if we have an open position
   if(positionTicket > 0)
   {
      // Debug logging
      static datetime lastDebugTime = 0;
      if(ENABLE_LOGGING && currentTime - lastDebugTime >= 60) // Log once per minute
      {
         lastDebugTime = currentTime;
         Print("DEBUG: Checking position ", positionTicket, " at ", TimeToString(currentTime));

         if(PositionSelectByTicket(positionTicket))
         {
            Print("Position found. Entry time: ", TimeToString(entryTime));
         }
         else
         {
            Print("WARNING: Position ", positionTicket, " not found!");
            positionTicket = 0; // Reset if position doesn't exist
         }
      }

      if(PositionSelectByTicket(positionTicket))
      {
         // Check if it's time to close the position
         bool shouldClose = false;

         // Calculate hours since entry
         double hoursInPosition = (currentTime - entryTime) / 3600.0;

         // Simple approach: close after 2 hours
         if(hoursInPosition >= 2.0)
         {
            shouldClose = true;
            if(ENABLE_LOGGING)
            {
               Print("=== TIME TO CLOSE ===");
               Print("Entry time: ", TimeToString(entryTime));
               Print("Current time: ", TimeToString(currentTime));
               Print("Hours in position: ", DoubleToString(hoursInPosition, 2));
            }
         }

         // Alternative: Check specific exit time
         if(!shouldClose && timeStruct.hour == EXIT_HOUR && timeStruct.min >= EXIT_MINUTE)
         {
            // Check if we entered before midnight and it's now past midnight
            MqlDateTime entryTimeStruct;
            TimeToStruct(entryTime, entryTimeStruct);

            // If we entered at 23:00 and it's now 01:00+, we should close
            if(entryTimeStruct.hour == 23 && timeStruct.hour < 3)
            {
               shouldClose = true;
               if(ENABLE_LOGGING)
                  Print("Exit time reached (crossed midnight)");
            }
         }

         if(shouldClose)
         {
            Print("Attempting to close position...");
            ClosePosition();
         }
      }
   }
   else
   {
      // Reset ticket if position was closed externally
      if(positionTicket > 0)
      {
         positionTicket = 0;
      }

      // No open position, check if it's time to open
      bool isEntryTime = (timeStruct.hour == ENTRY_HOUR && timeStruct.min >= ENTRY_MINUTE && timeStruct.min < ENTRY_MINUTE + 5);

      if(isEntryTime && ENABLE_LOGGING)
      {
         Print("Entry time window reached! TradeTakenToday=", tradeTakenToday);
      }

      if(!tradeTakenToday && isEntryTime)
      {
         Print("Attempting to open position...");
         OpenPosition();
      }
   }
}

//+------------------------------------------------------------------+
//| Check if it's a new trading day                                 |
//+------------------------------------------------------------------+
void CheckNewTradingDay()
{
   datetime currentTime = TimeCurrent();
   MqlDateTime currentTimeStruct;
   TimeToStruct(currentTime, currentTimeStruct);

   // Create date without time
   currentTimeStruct.hour = 0;
   currentTimeStruct.min = 0;
   currentTimeStruct.sec = 0;
   datetime currentDate = StructToTime(currentTimeStruct);

   // Check if it's a new day
   if(currentDate != currentTradingDate)
   {
      if(currentTradingDate > 0 && ENABLE_LOGGING)
         Print("New trading day: ", TimeToString(currentDate, TIME_DATE));

      currentTradingDate = currentDate;

      // Reset trade taken flag if this is a new day AND we don't have an open position
      if(positionTicket > 0 && PositionSelectByTicket(positionTicket))
      {
         // We have an open position from yesterday, keep tradeTakenToday as true
         tradeTakenToday = true;
      }
      else
      {
         // No open position, reset the flag
         tradeTakenToday = false;
         positionTicket = 0;
      }

      // Check if we actually traded on this day before
      MqlDateTime lastTradeDt;
      TimeToStruct(lastTradeDate, lastTradeDt);
      MqlDateTime currentDt;
      TimeToStruct(currentDate, currentDt);

      if(lastTradeDate > 0 &&
         lastTradeDt.year == currentDt.year &&
         lastTradeDt.mon == currentDt.mon &&
         lastTradeDt.day == currentDt.day)
      {
         // We already traded today
         tradeTakenToday = true;
         if(ENABLE_LOGGING)
            Print("Already traded on this date");
      }
   }
}

//+------------------------------------------------------------------+
//| Open a long position                                             |
//+------------------------------------------------------------------+
void OpenPosition()
{
   // Double-check we haven't already traded today
   if(tradeTakenToday)
   {
      if(ENABLE_LOGGING)
         Print("Trade already taken today, skipping");
      return;
   }

   // Check if trade would close on Saturday
   if(SKIP_FRIDAY_TO_SATURDAY_TRADES)
   {
      datetime currentTime = TimeCurrent();
      MqlDateTime currentDT;
      TimeToStruct(currentTime, currentDT);

      // Calculate when the trade would close
      datetime exitTime = currentTime;
      MqlDateTime exitDT;
      TimeToStruct(exitTime, exitDT);
      exitDT.hour = EXIT_HOUR;
      exitDT.min = EXIT_MINUTE;
      exitDT.sec = 0;

      // Check if exit is next day
      bool exitIsNextDay = (EXIT_HOUR < ENTRY_HOUR || (EXIT_HOUR == ENTRY_HOUR && EXIT_MINUTE <= ENTRY_MINUTE));
      if(exitIsNextDay)
      {
         exitTime = StructToTime(exitDT);
         exitTime += 24 * 60 * 60; // Add 24 hours
         TimeToStruct(exitTime, exitDT);
      }
      else
      {
         exitTime = StructToTime(exitDT);
      }

      // Check if we're on Friday and exit would be Saturday
      if(currentDT.day_of_week == FRIDAY)
      {
         if(exitDT.day_of_week == SATURDAY)
         {
            if(ENABLE_LOGGING)
               Print("Trade skipped - Would close on Saturday");
            tradeTakenToday = true; // Mark as taken to prevent multiple attempts
            return;
         }
      }
   }

   // Check volatility filter if enabled
   if(ENABLE_VOLATILITY_FILTER && !volatilityFilterPassed)
   {
      // Track this check only once per day
      if(TimeCurrent() - lastVolFilterCheck > 86400) // More than 24 hours
      {
         tradesSkippedByVolFilter++;
         lastVolFilterCheck = TimeCurrent();
      }

      if(ENABLE_LOGGING)
      {
         Print("Trade skipped - Volatility filter not passed");
         Print("Current 30-day HV: ", DoubleToString(current30DayHV * 100, 2), "%",
               " <= Median 365-day HV: ", DoubleToString(median365DayHV * 100, 2), "%");
         Print("Total trades skipped by filter: ", tradesSkippedByVolFilter);
      }
      // Still mark trade as taken to prevent multiple attempts
      tradeTakenToday = true;
      return;
   }
   else if(ENABLE_VOLATILITY_FILTER && volatilityFilterPassed)
   {
      // Track allowed trades
      if(TimeCurrent() - lastVolFilterCheck > 86400) // More than 24 hours
      {
         tradesAllowedByVolFilter++;
         lastVolFilterCheck = TimeCurrent();

         if(ENABLE_LOGGING)
         {
            Print("Volatility filter PASSED - Trade allowed");
            Print("Current 30-day HV: ", DoubleToString(current30DayHV * 100, 2), "%",
                  " > Median 365-day HV: ", DoubleToString(median365DayHV * 100, 2), "%");
         }
      }
   }

   // Get current tick
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
   {
      Print("Error getting tick data");
      return;
   }

   // Check if market is open
   if(tick.ask <= 0 || tick.bid <= 0)
   {
      Print("Market appears to be closed - invalid prices");
      return;
   }

   // Calculate position size using risk management (100% risk to zero)
   double lotSize = CalculateLotSize();

   if(lotSize <= 0)
   {
      Print("Cannot calculate valid position size");
      return;
   }

   // Open buy position at market (always uses broker's ask price)
   if(trade.Buy(lotSize, _Symbol, 0, 0, 0, "GoLongBTC Entry"))
   {
      Print("Trade executed successfully!");
      ulong orderTicket = trade.ResultOrder();
      ulong dealTicket = trade.ResultDeal();
      Print("Order: ", orderTicket, ", Deal: ", dealTicket);

      // Note: Sleep doesn't work in backtest mode

      // Find the position ticket
      positionTicket = 0;
      int totalPositions = PositionsTotal();
      Print("Total positions after trade: ", totalPositions);

      for(int i = 0; i < totalPositions; i++)
      {
         ulong posTicket = PositionGetTicket(i);
         if(posTicket > 0 && PositionSelectByTicket(posTicket))
         {
            ulong posMagic = PositionGetInteger(POSITION_MAGIC);
            string posSymbol = PositionGetString(POSITION_SYMBOL);

            Print("Position ", i, ": Ticket=", posTicket, ", Symbol=", posSymbol, ", Magic=", posMagic);

            if(posMagic == MAGIC_NUMBER && posSymbol == _Symbol)
            {
               positionTicket = posTicket;
               Print("Found matching position!");
               break;
            }
         }
      }

      if(positionTicket == 0)
      {
         // In backtesting, the position ticket might be the same as order ticket
         positionTicket = orderTicket;
         Print("Using order ticket as position ticket: ", positionTicket);
      }

      tradeTakenToday = true;
      entryTime = TimeCurrent();
      lastTradeDate = TimeCurrent();  // Record when we actually took a trade

      // Store actual entry price
      if(PositionSelectByTicket(positionTicket))
      {
         actualEntryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      }

      if(ENABLE_LOGGING)
      {
         Print("=== POSITION OPENED ===");
         Print("Order Ticket: ", orderTicket);
         Print("Deal Ticket: ", dealTicket);
         Print("Position Ticket: ", positionTicket);
         Print("Entry price: ", DoubleToString(tick.ask, symbolCache.digits));
         Print("Lot size: ", DoubleToString(lotSize, 2));
         Print("Entry time: ", TimeToString(entryTime));

         // Calculate and display exit time
         MqlDateTime exitTimeStruct;
         TimeToStruct(entryTime, exitTimeStruct);
         exitTimeStruct.hour = EXIT_HOUR;
         exitTimeStruct.min = EXIT_MINUTE;
         exitTimeStruct.sec = 0;

         // Check if exit is next day
         bool exitIsNextDay = (EXIT_HOUR < ENTRY_HOUR || (EXIT_HOUR == ENTRY_HOUR && EXIT_MINUTE <= ENTRY_MINUTE));
         if(exitIsNextDay)
         {
            datetime tempExitTime = StructToTime(exitTimeStruct);
            tempExitTime += 24 * 60 * 60; // Add 24 hours
            TimeToStruct(tempExitTime, exitTimeStruct);
         }

         datetime expectedExitTime = StructToTime(exitTimeStruct);
         Print("Expected exit time: ", TimeToString(expectedExitTime));
         double hoursUntilExit = (double)(expectedExitTime - entryTime) / 3600.0;
         Print("Exit is ", exitIsNextDay ? "NEXT DAY" : "SAME DAY", " (",
               DoubleToString(hoursUntilExit, 1), " hours after entry)");
      }

      if(USE_SOUND)
         PlaySound(SOUND_FILE);
   }
   else
   {
      Print("Failed to open position. Error: ", GetLastError());
      ResetLastError();
   }
}

//+------------------------------------------------------------------+
//| Close the open position                                          |
//+------------------------------------------------------------------+
void ClosePosition()
{
   if(positionTicket > 0 && PositionSelectByTicket(positionTicket))
   {
      // Get position profit before closing
      double positionProfit = PositionGetDouble(POSITION_PROFIT);
      double positionVolume = PositionGetDouble(POSITION_VOLUME);
      double currentPrice = PositionGetDouble(POSITION_PRICE_CURRENT);

      // Debug: Check trading session
      if(ENABLE_LOGGING)
      {
         datetime from, to;
         if(SymbolInfoSessionTrade(_Symbol, MONDAY, 0, from, to))
         {
            Print("Trading session info - From: ", TimeToString(from, TIME_MINUTES),
                  " To: ", TimeToString(to, TIME_MINUTES));
         }

         // Check if trading is allowed
         bool tradeAllowed = (bool)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
         Print("Trade mode allowed: ", tradeAllowed);

         // Get current time for debugging
         MqlDateTime dt;
         TimeToStruct(TimeCurrent(), dt);
         Print("Attempting to close at: ", StringFormat("%02d:%02d:%02d", dt.hour, dt.min, dt.sec));
      }

      // Get current tick
      MqlTick tick;
      if(!SymbolInfoTick(_Symbol, tick))
      {
         if(ENABLE_LOGGING)
            Print("WARNING: Cannot get tick data");
         return;
      }

      // Log current prices
      if(ENABLE_LOGGING)
      {
         Print("Current Bid: ", DoubleToString(tick.bid, symbolCache.digits),
               ", Ask: ", DoubleToString(tick.ask, symbolCache.digits));
      }

      // Try to close position using PositionClose
      if(trade.PositionClose(positionTicket))
      {
         if(ENABLE_LOGGING)
         {
            Print("=== POSITION CLOSED ===");
            Print("Exit time: ", TimeToString(TimeCurrent()));
            Print("Entry price: ", DoubleToString(actualEntryPrice, symbolCache.digits));
            Print("Exit price: ", DoubleToString(currentPrice, symbolCache.digits));
            Print("Broker Reported Profit: $", DoubleToString(positionProfit, 2));

            if(USE_CUSTOM_SPREAD)
            {
               // Simple calculation: subtract the custom spread cost from profit
               double customSpreadCost = (CUSTOM_SPREAD_POINTS * _Point) * positionVolume;
               double adjustedProfit = positionProfit - customSpreadCost;

               Print("=== CUSTOM SPREAD ADJUSTMENT ===");
               Print("Position volume: ", DoubleToString(positionVolume, 2), " lots");
               Print("Custom spread: ", CUSTOM_SPREAD_POINTS, " points ($", DoubleToString(CUSTOM_SPREAD_POINTS * _Point, 2), "/lot)");
               Print("Total spread cost: -$", DoubleToString(customSpreadCost, 2));
               Print("Adjusted Profit: $", DoubleToString(adjustedProfit, 2));
            }
         }

         if(USE_SOUND)
            PlaySound(SOUND_FILE);

         // Reset position tracking
         positionTicket = 0;
         entryTime = 0;
         actualEntryPrice = 0;
      }
      else
      {
         int error = GetLastError();
         Print("Failed to close position. Error: ", error);

         // If market is closed, stop trying to close until market reopens
         if(error == 4756) // Market closed error
         {
            waitingForMarketOpen = true;

            // Only alert once per hour about market being closed
            datetime currentTime = TimeCurrent();
            if(currentTime - lastMarketClosedAlert > 3600)
            {
               Print("Market is closed. Will retry when market reopens.");
               lastMarketClosedAlert = currentTime;
            }
            // Don't reset position ticket - keep tracking the position
         }

         ResetLastError();
      }
   }
}

//+------------------------------------------------------------------+
//| Calculate lot size based on risk settings (like GoLongEA)       |
//+------------------------------------------------------------------+
double CalculateLotSize()
{
   // Update symbol cache
   UpdateSymbolCache();

   // Use current account balance
   double accountBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   double volume = 0;

   // Get current price
   MqlTick currentTick;
   if(!SymbolInfoTick(_Symbol, currentTick)) return 0;

   // Always use broker's ask price for lot calculation
   double price = currentTick.ask;
   if(price <= 0) return 0;

   // Calculate risk amount
   double riskAmount = accountBalance * RISK_PERCENT / 100.0;

   // Since we have no stop loss, we risk the entire price (risk to zero)
   double stopLossDistance = price;

   // Get tick information
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double pointsAtRisk = 0;

   if(tickValue > 0 && tickSize > 0 && stopLossDistance > 0)
   {
      pointsAtRisk = stopLossDistance / tickSize;
      if(pointsAtRisk > 0)
         volume = riskAmount / (pointsAtRisk * tickValue);
   }

   // Normalize volume
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   volume = MathMax(minLot, volume);
   volume = MathMin(maxLot, volume);
   volume = MathRound(volume / stepLot) * stepLot;

   if(ENABLE_LOGGING)
   {
      Print("=== LOT SIZE CALCULATION ===");
      Print("Account balance: $", DoubleToString(accountBalance, 2));
      Print("Risk percent: ", DoubleToString(RISK_PERCENT, 1), "%");
      Print("Risk amount: $", DoubleToString(riskAmount, 2));
      Print("Current price: ", DoubleToString(price, symbolCache.digits));
      Print("Stop loss distance (risk to zero): ", DoubleToString(stopLossDistance, symbolCache.digits));
      Print("Points at risk: ", DoubleToString(pointsAtRisk, 0));
      Print("Tick value: $", DoubleToString(tickValue, 4));
      Print("Tick size: ", DoubleToString(tickSize, symbolCache.digits));
      if(pointsAtRisk > 0 && tickValue > 0)
         Print("Calculated volume: ", DoubleToString(riskAmount / (pointsAtRisk * tickValue), 4));
      Print("Final lot size: ", DoubleToString(volume, 2));

      // Check if we hit max lot limit
      if(volume == maxLot && pointsAtRisk > 0 && tickValue > 0 && riskAmount / (pointsAtRisk * tickValue) > maxLot)
      {
         Print("WARNING: Position size limited by broker's max lot size: ", maxLot);
         Print("Wanted lots: ", DoubleToString(riskAmount / (pointsAtRisk * tickValue), 4));
      }
   }

   return volume;
}

//+------------------------------------------------------------------+
//| Calculate daily volatility metrics                               |
//+------------------------------------------------------------------+
void CalculateDailyVolatility()
{
   if(!ENABLE_VOLATILITY_FILTER)
      return;

   // Get current close price
   double currentClose = iClose(_Symbol, PERIOD_D1, 0);
   if(currentClose <= 0)
   {
      if(ENABLE_LOGGING)
         Print("WARNING: Invalid close price for volatility calculation");
      return;
   }

   // Add current close to array
   if(dailyClosesCount < MAX_DAILY_CLOSES)
   {
      ArrayResize(dailyCloses, dailyClosesCount + 1);
      dailyCloses[dailyClosesCount] = currentClose;
      dailyClosesCount++;
   }
   else
   {
      // Shift array and add new close
      for(int i = 0; i < MAX_DAILY_CLOSES - 1; i++)
         dailyCloses[i] = dailyCloses[i + 1];
      dailyCloses[MAX_DAILY_CLOSES - 1] = currentClose;
   }

   // Need at least 2 closes for log returns
   if(dailyClosesCount < 2)
   {
      if(ENABLE_LOGGING)
         Print("Not enough data for volatility calculation. Need at least 2 daily closes.");
      return;
   }

   // Calculate log returns
   CalculateLogReturns();

   // Need at least 30 log returns for HV calculation
   if(dailyClosesCount < VOLATILITY_LOOKBACK + 1)
   {
      if(ENABLE_LOGGING)
         Print("Not enough data for HV calculation. Have ", dailyClosesCount, " closes, need ", VOLATILITY_LOOKBACK + 1);
      return;
   }

   // Calculate 30-day historical volatility
   current30DayHV = Calculate30DayHV();

   // Add to rolling HV values
   if(hvValuesCount < MEDIAN_LOOKBACK)
   {
      ArrayResize(rollingHVValues, hvValuesCount + 1);
      rollingHVValues[hvValuesCount] = current30DayHV;
      hvValuesCount++;
   }
   else
   {
      // Shift array and add new HV
      for(int i = 0; i < MEDIAN_LOOKBACK - 1; i++)
         rollingHVValues[i] = rollingHVValues[i + 1];
      rollingHVValues[MEDIAN_LOOKBACK - 1] = current30DayHV;
   }

   // Calculate median if we have enough data
   if(hvValuesCount >= MEDIAN_LOOKBACK)
   {
      median365DayHV = CalculateMedian(rollingHVValues, MEDIAN_LOOKBACK);
      volatilityFilterPassed = (current30DayHV > median365DayHV);

      if(ENABLE_LOGGING)
      {
         Print("=== VOLATILITY FILTER UPDATE ===");
         Print("Calculation Time: ", TimeToString(TimeCurrent()));
         Print("Daily Closes Stored: ", dailyClosesCount);
         Print("HV Values Stored: ", hvValuesCount);
         Print("Current 30-day HV: ", DoubleToString(current30DayHV * 100, 2), "%");
         Print("365-day Median HV: ", DoubleToString(median365DayHV * 100, 2), "%");
         Print("Filter Passed: ", volatilityFilterPassed ? "YES - Trade Allowed" : "NO - Trade Blocked");

         // Show some recent log returns for verification
         if(ArraySize(dailyLogReturns) >= 5)
         {
            Print("Last 5 daily log returns:");
            int start = ArraySize(dailyLogReturns) - 5;
            for(int i = start; i < ArraySize(dailyLogReturns); i++)
            {
               Print("  Day ", i - start + 1, ": ", DoubleToString(dailyLogReturns[i] * 100, 4), "%");
            }
         }
      }
   }
   else
   {
      // Not enough data for median, default to allowing trades
      volatilityFilterPassed = true;
      if(ENABLE_LOGGING)
         Print("Not enough HV data for median. Have ", hvValuesCount, " values, need ", MEDIAN_LOOKBACK);
   }

   // Update last calculation date
   lastVolCalcDate = TimeCurrent();
}

//+------------------------------------------------------------------+
//| Calculate log returns from daily closes                          |
//+------------------------------------------------------------------+
void CalculateLogReturns()
{
   int returnsCount = dailyClosesCount - 1;
   ArrayResize(dailyLogReturns, returnsCount);

   for(int i = 0; i < returnsCount; i++)
   {
      if(dailyCloses[i] > 0 && dailyCloses[i + 1] > 0)
      {
         dailyLogReturns[i] = MathLog(dailyCloses[i + 1] / dailyCloses[i]);
      }
      else
      {
         dailyLogReturns[i] = 0;
      }
   }
}

//+------------------------------------------------------------------+
//| Calculate 30-day historical volatility                           |
//+------------------------------------------------------------------+
double Calculate30DayHV()
{
   // Get the last 30 log returns
   int startIdx = ArraySize(dailyLogReturns) - VOLATILITY_LOOKBACK;
   if(startIdx < 0) startIdx = 0;

   // Calculate mean
   double sum = 0;
   int count = 0;
   for(int i = startIdx; i < ArraySize(dailyLogReturns); i++)
   {
      sum += dailyLogReturns[i];
      count++;
   }
   double mean = sum / count;

   // Calculate standard deviation
   double sumSquaredDiff = 0;
   for(int i = startIdx; i < ArraySize(dailyLogReturns); i++)
   {
      double diff = dailyLogReturns[i] - mean;
      sumSquaredDiff += diff * diff;
   }

   double variance = sumSquaredDiff / (count - 1);  // Sample variance
   double stdDev = MathSqrt(variance);

   // Annualize (multiply by sqrt(365))
   double annualizedVol = stdDev * MathSqrt(365);

   return annualizedVol;
}

//+------------------------------------------------------------------+
//| Calculate median of an array                                     |
//+------------------------------------------------------------------+
double CalculateMedian(double &array[], int count)
{
   // Create a copy for sorting
   double sortedArray[];
   ArrayResize(sortedArray, count);
   ArrayCopy(sortedArray, array, 0, 0, count);

   // Sort the array
   ArraySort(sortedArray);

   // Calculate median
   if(count % 2 == 0)
   {
      // Even number of elements - average of two middle values
      int mid1 = count / 2 - 1;
      int mid2 = count / 2;
      return (sortedArray[mid1] + sortedArray[mid2]) / 2.0;
   }
   else
   {
      // Odd number of elements - middle value
      int mid = count / 2;
      return sortedArray[mid];
   }
}

//+------------------------------------------------------------------+
//| Update symbol information cache                                  |
//+------------------------------------------------------------------+
void UpdateSymbolCache()
{
   symbolCache.point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   symbolCache.tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   symbolCache.tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   symbolCache.minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   symbolCache.maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   symbolCache.lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   symbolCache.digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   symbolCache.isValid = true;
}