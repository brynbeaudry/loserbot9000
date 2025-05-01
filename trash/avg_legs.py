"""
📊 This script demonstrates how to calculate the *average directional leg size*
   (i.e., average run in one direction before a reversal) over the last hour
   using 1-minute candles from MetaTrader 5.

💡 It teaches:
- How to fetch historical market data with MT5’s Python API
- How to interpret DataFrame columns returned by MT5
- How to segment price movement into 'legs' based on direction
- How to measure and average the size of those legs
"""

import MetaTrader5 as mt5
import pandas as pd

# === Step 1: Connect to MetaTrader 5 and fetch last 60 minutes of 1-minute candles ===
symbol = "BTCUSD"                   # Instrument to analyze
timeframe = mt5.TIMEFRAME_M1        # 1-minute candles
num_candles = 60                    # 60 candles = 1 hour of data

# Initialize MT5 connection
mt5.initialize()

# Fetch 60 candles starting from the most recent (position 0)
rates = mt5.copy_rates_from_pos(symbol, timeframe, 0, num_candles)

# Shutdown MT5 connection after data is retrieved
mt5.shutdown()

# === Step 2: Convert raw rates to a pandas DataFrame for easier processing ===
df = pd.DataFrame(rates)

# 🗂️ df now contains these columns:
# - df['time']         : Unix timestamp (start of each candle)
# - df['open']         : Price at candle open
# - df['high']         : Highest price during candle
# - df['low']          : Lowest price during candle
# - df['close']        : Price at candle close
# - df['tick_volume']  : Number of ticks (price changes) in the candle
# - df['spread']       : Spread at candle open
# - df['real_volume']  : Actual traded volume (if supported by broker)

# === Step 3: Determine direction of each candle ===
# We classify each candle as 'up' if it closed higher than the previous,
# 'down' if it closed lower, and None if no change.
df['direction'] = df['close'].diff().apply(
    lambda x: 'up' if x > 0 else 'down' if x < 0 else None
)

# === Step 4: Segment the data into legs of consistent direction ===
legs = []                           # List to store the size of each leg
start_price = df['close'].iloc[0]   # Starting point of the first leg
current_dir = df['direction'].iloc[1]  # Initial direction

# Loop through candles and segment into directional legs
for i in range(2, len(df)):
    dir_now = df['direction'].iloc[i]    # Current direction
    price_now = df['close'].iloc[i]      # Current close price
    
    if dir_now != current_dir and dir_now is not None:
        # When direction changes, calculate leg size and save it
        leg_size = abs(price_now - start_price)
        legs.append(leg_size)

        # Start a new leg
        start_price = price_now
        current_dir = dir_now

# Add the last leg if not already captured
if len(legs) == 0 or start_price != df['close'].iloc[-1]:
    legs.append(abs(df['close'].iloc[-1] - start_price))

# === Step 5: Calculate the average leg size ===
# This tells us the average price movement before a reversal
avg_leg_size = sum(legs) / len(legs) if legs else 0

# 🖨️ Output the result
print(f"📊 Average leg size over the last hour: {avg_leg_size:.2f} price units")
