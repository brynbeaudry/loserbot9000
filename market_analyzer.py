"""
📊 MarketAnalyzer - Comprehensive Technical Analysis Data Exporter

This script:
1. Takes a symbol and time period (in hours) as parameters
2. Fetches historical market data from MetaTrader 5
3. Calculates multiple technical indicators (EMAs, MACD, RSI, ATR, etc.)
4. Calculates average directional leg sizes
5. Exports all data to a CSV file for further analysis

Usage:
    python market_analyzer.py SYMBOL HOURS [--timeframe M1|M5|M15|M30|H1|H4|D1] [--output filename.csv]

Example:
    python market_analyzer.py EURUSD 24 --timeframe M5 --output eurusd_analysis.csv
"""

import MetaTrader5 as mt5
import pandas as pd
import numpy as np
import argparse
from datetime import datetime
import os

# === Indicator Calculator Class ===
class IndicatorCalculator:
    """Provides methods for calculating technical indicators."""
    
    @staticmethod
    def calculate_ema(prices, period):
        """Calculate Exponential Moving Average"""
        if len(prices) < period:
            return pd.Series(index=prices.index, dtype='float64')
        return prices.ewm(span=period, adjust=False).mean()
        
    @staticmethod
    def calculate_macd(prices, fast_period=12, slow_period=26, signal_period=9):
        """Calculate Moving Average Convergence Divergence (MACD)"""
        if len(prices) < slow_period:
            # Return DataFrame with NaN columns if not enough data
            return pd.DataFrame(index=prices.index, data={
                'macd': np.nan,
                'macd_signal': np.nan,
                'macd_hist': np.nan
            })

        ema_fast = prices.ewm(span=fast_period, adjust=False).mean()
        ema_slow = prices.ewm(span=slow_period, adjust=False).mean()

        macd_line = ema_fast - ema_slow
        signal_line = macd_line.ewm(span=signal_period, adjust=False).mean()
        histogram = macd_line - signal_line

        # Create DataFrame with results
        macd_df = pd.DataFrame(index=prices.index)
        macd_df['macd'] = macd_line
        macd_df['macd_signal'] = signal_line
        macd_df['macd_hist'] = histogram

        return macd_df
        
    @staticmethod
    def calculate_rsi(prices, period=14):
        """Calculate Relative Strength Index (RSI)"""
        if len(prices) < period:
            return pd.Series(index=prices.index, dtype='float64')

        delta = prices.diff()
        gain = (delta.where(delta > 0, 0)).fillna(0)
        loss = (-delta.where(delta < 0, 0)).fillna(0)

        avg_gain = gain.ewm(com=period - 1, min_periods=period, adjust=False).mean()
        avg_loss = loss.ewm(com=period - 1, min_periods=period, adjust=False).mean()

        rs = avg_gain / avg_loss
        rsi = 100 - (100 / (1 + rs))

        # Handle division by zero if avg_loss is 0
        rsi = rsi.replace([np.inf, -np.inf], 100).fillna(50)
        
        return rsi
        
    @staticmethod
    def calculate_atr(ohlc_data, period=14):
        """
        Calculate Average True Range (ATR)
        """
        if len(ohlc_data) < period + 1:
            return pd.Series(index=ohlc_data.index, dtype='float64')
            
        # Create a new DataFrame to avoid modifying the input
        df = pd.DataFrame(index=ohlc_data.index)
        
        # Calculate True Range
        df['high'] = ohlc_data['high']
        df['low'] = ohlc_data['low']
        df['close'] = ohlc_data['close']
        df['prev_close'] = ohlc_data['close'].shift(1)
        
        # Handle the first row where prev_close is NaN
        df.loc[df.index[0], 'prev_close'] = df['close'].iloc[0]
        
        # Calculate the three components of True Range
        df['tr1'] = df['high'] - df['low']
        df['tr2'] = abs(df['high'] - df['prev_close'])
        df['tr3'] = abs(df['low'] - df['prev_close'])
        
        # True Range is the maximum of the three components
        df['tr'] = df[['tr1', 'tr2', 'tr3']].max(axis=1)
        
        # Calculate Average True Range (ATR)
        df['atr'] = df['tr'].rolling(window=period, min_periods=1).mean()
        
        return df['atr']
        
    @staticmethod
    def calculate_bollinger_bands(prices, period=20, std_dev=2):
        """Calculate Bollinger Bands"""
        if len(prices) < period:
            return pd.DataFrame(index=prices.index, data={
                'bb_middle': np.nan,
                'bb_upper': np.nan,
                'bb_lower': np.nan
            })
            
        # Calculate middle band (SMA)
        middle_band = prices.rolling(window=period).mean()
        
        # Calculate standard deviation
        std = prices.rolling(window=period).std()
        
        # Calculate upper and lower bands
        upper_band = middle_band + (std * std_dev)
        lower_band = middle_band - (std * std_dev)
        
        # Create DataFrame with results
        bb_df = pd.DataFrame(index=prices.index)
        bb_df['bb_middle'] = middle_band
        bb_df['bb_upper'] = upper_band
        bb_df['bb_lower'] = lower_band
        
        return bb_df
        
    @staticmethod
    def calculate_stochastic(ohlc_data, k_period=14, d_period=3, slowing=3):
        """Calculate Stochastic Oscillator"""
        if len(ohlc_data) < k_period:
            return pd.DataFrame(index=ohlc_data.index, data={
                'stoch_k': np.nan,
                'stoch_d': np.nan
            })
            
        # Get high and low for the last k_period periods
        low_min = ohlc_data['low'].rolling(window=k_period).min()
        high_max = ohlc_data['high'].rolling(window=k_period).max()
        
        # Calculate %K
        # %K = (Current Close - Lowest Low) / (Highest High - Lowest Low) * 100
        k = 100 * ((ohlc_data['close'] - low_min) / (high_max - low_min))
        
        # Apply slowing if specified (simple moving average)
        if slowing > 1:
            k = k.rolling(window=slowing).mean()
            
        # Calculate %D (simple moving average of %K)
        d = k.rolling(window=d_period).mean()
        
        # Create DataFrame with results
        stoch_df = pd.DataFrame(index=ohlc_data.index)
        stoch_df['stoch_k'] = k
        stoch_df['stoch_d'] = d
        
        return stoch_df

# === Leg Analysis Functions ===
def calculate_directional_legs(df):
    """
    Calculate directional legs (continuous price movements in one direction) 
    and their statistics.
    
    Args:
        df (DataFrame): DataFrame with 'close' column
        
    Returns:
        DataFrame: Original df with added 'direction' column
        list: List of leg sizes
        float: Average leg size
        float: Max leg size
        float: Min leg size
    """
    # Determine direction of each candle (up, down, or none)
    df['direction'] = df['close'].diff().apply(
        lambda x: 'up' if x > 0 else 'down' if x < 0 else None
    )
    
    # Find where direction changes to segment into legs
    legs = []
    start_price = df['close'].iloc[0]
    current_dir = df['direction'].iloc[1] if len(df) > 1 else None
    
    # Loop through candles and segment into directional legs
    for i in range(2, len(df)):
        dir_now = df['direction'].iloc[i]
        price_now = df['close'].iloc[i]
        
        if dir_now != current_dir and dir_now is not None:
            # When direction changes, calculate leg size and save it
            leg_size = abs(price_now - start_price)
            legs.append(leg_size)
            
            # Start a new leg
            start_price = price_now
            current_dir = dir_now
    
    # Add the last leg if not already captured
    if len(df) > 1 and (len(legs) == 0 or start_price != df['close'].iloc[-1]):
        legs.append(abs(df['close'].iloc[-1] - start_price))
        
    # Calculate leg statistics
    if legs:
        avg_leg_size = sum(legs) / len(legs)
        max_leg_size = max(legs) if legs else 0
        min_leg_size = min(legs) if legs else 0
    else:
        avg_leg_size = max_leg_size = min_leg_size = 0
        
    return df, legs, avg_leg_size, max_leg_size, min_leg_size

# === Main Analysis Function ===
def analyze_market_data(symbol, hours, timeframe_str, output_file):
    """
    Fetch data, calculate indicators, and export to CSV.
    
    Args:
        symbol (str): Trading symbol
        hours (int): Number of hours of data to analyze
        timeframe_str (str): Timeframe string (e.g., "M1", "M5")
        output_file (str): Output CSV filename
    """
    # Map timeframe string to MT5 constant
    timeframe_map = {
        "M1": mt5.TIMEFRAME_M1,
        "M5": mt5.TIMEFRAME_M5,
        "M15": mt5.TIMEFRAME_M15,
        "M30": mt5.TIMEFRAME_M30,
        "H1": mt5.TIMEFRAME_H1,
        "H4": mt5.TIMEFRAME_H4,
        "D1": mt5.TIMEFRAME_D1
    }
    
    if timeframe_str not in timeframe_map:
        print(f"❌ Invalid timeframe: {timeframe_str}. Using M1 as default.")
        timeframe = mt5.TIMEFRAME_M1
        candles_per_hour = 60
    else:
        timeframe = timeframe_map[timeframe_str]
        # Calculate candles per hour based on timeframe
        if timeframe == mt5.TIMEFRAME_M1:
            candles_per_hour = 60
        elif timeframe == mt5.TIMEFRAME_M5:
            candles_per_hour = 12
        elif timeframe == mt5.TIMEFRAME_M15:
            candles_per_hour = 4
        elif timeframe == mt5.TIMEFRAME_M30:
            candles_per_hour = 2
        elif timeframe == mt5.TIMEFRAME_H1:
            candles_per_hour = 1
        elif timeframe == mt5.TIMEFRAME_H4:
            candles_per_hour = 0.25
        else:  # Daily
            candles_per_hour = 1/24
    
    # Calculate number of candles needed
    num_candles = int(hours * candles_per_hour)
    if num_candles < 50:
        print(f"⚠️ Warning: Requesting only {num_candles} candles. Adding extra candles for reliable indicator calculation.")
        num_candles = max(num_candles, 50)
    
    # Initialize MT5 connection
    if not mt5.initialize():
        print(f"❌ Failed to initialize MT5: {mt5.last_error()}")
        return
    
    print(f"📈 Fetching {num_candles} {timeframe_str} candles for {symbol}...")
    
    try:
        # Fetch candles starting from the most recent
        rates = mt5.copy_rates_from_pos(symbol, timeframe, 0, num_candles)
        if rates is None or len(rates) == 0:
            print(f"❌ Failed to get data for {symbol}: {mt5.last_error()}")
            mt5.shutdown()
            return
            
        # Convert to pandas DataFrame
        df = pd.DataFrame(rates)
        
        # Convert timestamp to datetime
        df['time'] = pd.to_datetime(df['time'], unit='s')
        df.set_index('time', inplace=True)
        
        print(f"✅ Received {len(df)} candles from {df.index[0]} to {df.index[-1]}")
        
        # Calculate indicators
        print("🧮 Calculating technical indicators...")
        
        # EMAs with different periods
        df['ema_5'] = IndicatorCalculator.calculate_ema(df['close'], 5)
        df['ema_8'] = IndicatorCalculator.calculate_ema(df['close'], 8)
        df['ema_13'] = IndicatorCalculator.calculate_ema(df['close'], 13)
        df['ema_21'] = IndicatorCalculator.calculate_ema(df['close'], 21)
        df['ema_50'] = IndicatorCalculator.calculate_ema(df['close'], 50)
        df['ema_200'] = IndicatorCalculator.calculate_ema(df['close'], 200)
        
        # MACD
        macd_df = IndicatorCalculator.calculate_macd(df['close'])
        df = df.join(macd_df)
        
        # RSI
        df['rsi'] = IndicatorCalculator.calculate_rsi(df['close'])
        
        # ATR
        df['atr'] = IndicatorCalculator.calculate_atr(df)
        
        # Bollinger Bands
        bb_df = IndicatorCalculator.calculate_bollinger_bands(df['close'])
        df = df.join(bb_df)
        
        # Stochastic Oscillator
        stoch_df = IndicatorCalculator.calculate_stochastic(df)
        df = df.join(stoch_df)
        
        # Calculate directional legs and statistics
        print("📏 Analyzing price movements and calculating legs...")
        df, legs, avg_leg_size, max_leg_size, min_leg_size = calculate_directional_legs(df)
        
        # Add some derived signals and data points
        
        # EMA Crossovers (Fast/Slow)
        df['ema_5_8_cross'] = np.where(
            (df['ema_5'].shift(1) <= df['ema_8'].shift(1)) & 
            (df['ema_5'] > df['ema_8']), 
            1, np.where(
                (df['ema_5'].shift(1) >= df['ema_8'].shift(1)) & 
                (df['ema_5'] < df['ema_8']), 
                -1, 0
            )
        )
        
        # MACD Signal Crossovers
        df['macd_cross'] = np.where(
            (df['macd'].shift(1) <= df['macd_signal'].shift(1)) & 
            (df['macd'] > df['macd_signal']), 
            1, np.where(
                (df['macd'].shift(1) >= df['macd_signal'].shift(1)) & 
                (df['macd'] < df['macd_signal']), 
                -1, 0
            )
        )
        
        # Stochastic Signal Crossovers
        df['stoch_cross'] = np.where(
            (df['stoch_k'].shift(1) <= df['stoch_d'].shift(1)) & 
            (df['stoch_k'] > df['stoch_d']), 
            1, np.where(
                (df['stoch_k'].shift(1) >= df['stoch_d'].shift(1)) & 
                (df['stoch_k'] < df['stoch_d']), 
                -1, 0
            )
        )
        
        # RSI Overbought/Oversold
        df['rsi_signal'] = np.where(df['rsi'] < 30, 1, np.where(df['rsi'] > 70, -1, 0))
        
        # Bollinger Band Touch/Break
        df['bb_signal'] = np.where(df['close'] <= df['bb_lower'], 1, 
                          np.where(df['close'] >= df['bb_upper'], -1, 0))
        
        # Price vs EMA200 (Above/Below)
        df['trend_vs_ema200'] = np.where(df['close'] > df['ema_200'], 1, -1)
        
        # Potential Support/Resistance Levels based on price clusters
        # (This would require more complex logic - simplified here)
        df['support_resistance'] = df['close'].round(decimals=3)
        
        # Volatility adjusted ATR percentage
        df['atr_percent'] = (df['atr'] / df['close']) * 100
        
        # Calculate average ATR for the period
        avg_atr = df['atr'].mean()
        
        # Calculate suggested SL/TP based on ATR
        suggested_sl_pips = avg_atr * 1.25
        suggested_tp_pips = avg_atr * 2.0
        
        # Print summary statistics
        print("\n📊 Analysis Summary:")
        print(f"Symbol: {symbol}")
        print(f"Timeframe: {timeframe_str}")
        print(f"Period: {hours} hours ({len(df)} candles)")
        print(f"First candle: {df.index[0]}")
        print(f"Last candle: {df.index[-1]}")
        print(f"\nPrice Movement:")
        print(f"Starting price: {df['open'].iloc[0]:.5f}")
        print(f"Ending price: {df['close'].iloc[-1]:.5f}")
        print(f"Total change: {df['close'].iloc[-1] - df['open'].iloc[0]:.5f} ({((df['close'].iloc[-1] / df['open'].iloc[0]) - 1) * 100:.2f}%)")
        
        print(f"\nDirectional Leg Analysis:")
        print(f"Number of legs: {len(legs)}")
        print(f"Average leg size: {avg_leg_size:.5f}")
        print(f"Maximum leg size: {max_leg_size:.5f}")
        print(f"Minimum leg size: {min_leg_size:.5f}")
        
        print(f"\nVolatility:")
        print(f"Average ATR: {avg_atr:.5f}")
        print(f"ATR as % of price: {(avg_atr / df['close'].iloc[-1]) * 100:.2f}%")
        
        print(f"\nSuggested Stop Loss/Take Profit (based on ATR):")
        print(f"Stop Loss: {suggested_sl_pips:.5f} ({(suggested_sl_pips / df['close'].iloc[-1]) * 100:.2f}% of price)")
        print(f"Take Profit: {suggested_tp_pips:.5f} ({(suggested_tp_pips / df['close'].iloc[-1]) * 100:.2f}% of price)")
        
        # Transform column names to be more readable before exporting
        def make_columns_readable(df):
            """
            Transform column names to be more human-readable and descriptive.
            """
            column_mapping = {
                # Basic price and volume data
                'open': 'Open Price',
                'high': 'High Price',
                'low': 'Low Price',
                'close': 'Close Price',
                'tick_volume': 'Tick Volume',
                'spread': 'Spread (Points)',
                'real_volume': 'Trading Volume',
                
                # Moving averages
                'ema_5': 'EMA (5) - Fast Exponential Moving Average',
                'ema_8': 'EMA (8) - Short-term Trend',
                'ema_13': 'EMA (13) - Medium-term Trend',
                'ema_21': 'EMA (21) - Intermediate Trend',
                'ema_50': 'EMA (50) - Medium-Long Trend',
                'ema_200': 'EMA (200) - Long-term Trend',
                
                # MACD Indicator
                'macd': 'MACD Line',
                'macd_signal': 'MACD Signal Line',
                'macd_hist': 'MACD Histogram',
                
                # Other indicators
                'rsi': 'RSI (14) - Relative Strength Index',
                'atr': 'ATR (14) - Average True Range',
                'atr_percent': 'ATR % of Price',
                
                # Bollinger Bands
                'bb_middle': 'Bollinger Band - Middle (SMA 20)',
                'bb_upper': 'Bollinger Band - Upper (2 std dev)',
                'bb_lower': 'Bollinger Band - Lower (2 std dev)',
                
                # Stochastic Oscillator
                'stoch_k': 'Stochastic %K (14,3)',
                'stoch_d': 'Stochastic %D (3-period SMA of %K)',
                
                # Direction and analysis
                'direction': 'Candle Direction',
                'support_resistance': 'Potential Support/Resistance Level',
                
                # Signal indicators
                'ema_5_8_cross': 'EMA 5-8 Crossover Signal (1=Buy, -1=Sell)',
                'macd_cross': 'MACD Signal Line Crossover (1=Buy, -1=Sell)',
                'stoch_cross': 'Stochastic Crossover Signal (1=Buy, -1=Sell)',
                'rsi_signal': 'RSI Signal (1=Oversold, -1=Overbought)',
                'bb_signal': 'Bollinger Band Signal (1=Lower Band Touch, -1=Upper Band Touch)',
                'trend_vs_ema200': 'Trend vs EMA200 (1=Above/Bullish, -1=Below/Bearish)'
            }
            
            # Create a copy to avoid modifying the original DataFrame
            readable_df = df.copy()
            
            # Rename columns that are in the mapping
            renamed_columns = {}
            for col in readable_df.columns:
                if col in column_mapping:
                    renamed_columns[col] = column_mapping[col]
                else:
                    # Keep original name but make it more readable
                    renamed_columns[col] = ' '.join(word.capitalize() for word in col.split('_'))
            
            return readable_df.rename(columns=renamed_columns)
            
        # Convert data to human-readable format
        export_df = make_columns_readable(df)
        
        # Export data to CSV
        export_df.to_csv(output_file)
        
        # Add explanation of columns to summary file
        summary_description = """
Column Name Descriptions:
------------------------
* Open/High/Low/Close Price: Standard price data for each candle
* EMA (X): Exponential Moving Average with X periods, shows trend direction
* MACD Line: Moving Average Convergence/Divergence trend-following momentum indicator
* MACD Signal Line: 9-period EMA of MACD Line, used for crossover signals
* MACD Histogram: Difference between MACD Line and Signal Line
* RSI: Relative Strength Index, shows overbought/oversold conditions (>70=overbought, <30=oversold)
* ATR: Average True Range, measures volatility
* Bollinger Bands: Price channels based on standard deviation from SMA
* Stochastic %K/%D: Momentum oscillator comparing close price to high/low range
* Candle Direction: Whether the candle closed up or down from previous
* Crossover Signals: Values of 1 (buy), -1 (sell), or 0 (no signal) based on indicator crossovers
* Trend vs EMA200: Shows if price is above (1) or below (-1) the 200 EMA
"""
        
        # Add summary metrics to CSV with more descriptive names
        summary_df = pd.DataFrame([{
            'Analysis Time': datetime.now(),
            'Symbol': symbol,
            'Timeframe': timeframe_str,
            'Hours Analyzed': hours,
            'Number of Candles': len(df),
            'Starting Price': df['open'].iloc[0],
            'Ending Price': df['close'].iloc[-1],
            'Price Change': df['close'].iloc[-1] - df['open'].iloc[0],
            'Price Change (%)': ((df['close'].iloc[-1] / df['open'].iloc[0]) - 1) * 100,
            'Number of Price Legs': len(legs),
            'Average Leg Size': avg_leg_size,
            'Maximum Leg Size': max_leg_size,
            'Minimum Leg Size': min_leg_size,
            'Average ATR': avg_atr,
            'ATR as % of Price': (avg_atr / df['close'].iloc[-1]) * 100,
            'Suggested Stop Loss': suggested_sl_pips,
            'Suggested Take Profit': suggested_tp_pips,
            'SL as % of Price': (suggested_sl_pips / df['close'].iloc[-1]) * 100,
            'TP as % of Price': (suggested_tp_pips / df['close'].iloc[-1]) * 100
        }])
        
        # Generate file path
        if not output_file:
            timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
            output_file = f"{symbol}_{timeframe_str}_{hours}h_{timestamp}.csv"
        
        # Create directory if it doesn't exist
        output_dir = os.path.dirname(output_file)
        if output_dir and not os.path.exists(output_dir):
            os.makedirs(output_dir)
        
        # Export summary to separate file
        summary_file = output_file.replace('.csv', '_summary.csv')
        
        # Write column descriptions to the summary file first
        with open(summary_file, 'w') as f:
            f.write(summary_description)
            f.write("\n\nSummary Statistics:\n")
        
        # Append the summary DataFrame
        summary_df.to_csv(summary_file, index=False, mode='a')
        
        print(f"\n✅ Data exported to {output_file}")
        print(f"✅ Summary with column descriptions exported to {summary_file}")
        
    except Exception as e:
        print(f"❌ Error during analysis: {e}")
    finally:
        # Shutdown MT5 connection
        mt5.shutdown()

# === Parse Command Line Arguments ===
def parse_arguments():
    parser = argparse.ArgumentParser(description='Comprehensive Market Data Analyzer')
    parser.add_argument('symbol', help='Trading symbol (e.g., EURUSD)')
    parser.add_argument('hours', type=int, help='Number of hours of data to analyze')
    parser.add_argument('--timeframe', '-t', default='M1', 
                       choices=['M1', 'M5', 'M15', 'M30', 'H1', 'H4', 'D1'],
                       help='Timeframe to analyze')
    parser.add_argument('--output', '-o', help='Output CSV file path')
    return parser.parse_args()

# === Main Execution ===
if __name__ == "__main__":
    args = parse_arguments()
    analyze_market_data(args.symbol, args.hours, args.timeframe, args.output) 