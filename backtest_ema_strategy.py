import MetaTrader5 as mt5
import pandas as pd
import numpy as np
import argparse
from datetime import datetime, timedelta
import time
from ema_crossover_strategy import (
    initialize_mt5, LOGIN, PASSWORD, SERVER,
    FAST_EMA, SLOW_EMA, MIN_CROSSOVER_POINTS,
    MIN_SEPARATION_POINTS, SLOPE_PERIODS,
    calculate_slope, check_slope_conditions,
    check_separation, check_price_confirmation,
    calculate_stop_distance, execute_trade,
    get_ema_signals, get_current_signal,
    find_and_close_positions, get_historical_data
)

def parse_arguments():
    """Parse command line arguments
    
    Returns:
        argparse.Namespace: Parsed arguments
    """
    parser = argparse.ArgumentParser(description='Backtest EMA Crossover Trading Strategy')
    parser.add_argument('symbol', help='Trading symbol (e.g., BTCUSD)')
    parser.add_argument('--risk', type=float, default=1.0, 
                       help='Risk percentage per trade (default: 1.0 means 1%)')
    return parser.parse_args()

def get_historical_data_for_backtest(symbol, start_time, end_time):
    """Get historical price data for backtesting
    
    Args:
        symbol: Trading symbol
        start_time: Start datetime
        end_time: End datetime
        
    Returns:
        DataFrame or None: Historical price data with calculated EMAs
    """
    rates = mt5.copy_rates_range(symbol, mt5.TIMEFRAME_M1, start_time, end_time)
    if rates is None:
        print("❌ Failed to get historical data")
        return None
        
    df = pd.DataFrame(rates)
    df['time'] = pd.to_datetime(df['time'], unit='s')
    
    # Calculate TEMA (Triple Exponential Moving Average) for fast EMA
    # First EMA
    df['ema1'] = df['close'].ewm(span=FAST_EMA, adjust=False).mean()
    # EMA of EMA1
    df['ema2'] = df['ema1'].ewm(span=FAST_EMA, adjust=False).mean()
    # EMA of EMA2
    df['ema3'] = df['ema2'].ewm(span=FAST_EMA, adjust=False).mean()
    
    # Calculate TEMA using the formula: TEMA = (3 * EMA1) - (3 * EMA2) + EMA3
    df['fast_ema'] = (3 * df['ema1']) - (3 * df['ema2']) + df['ema3']
    
    # Calculate regular slow EMA
    df['slow_ema'] = df['close'].ewm(span=SLOW_EMA, adjust=False).mean()
    
    return df

def get_historical_data_slice(df, current_idx):
    """Get a slice of historical data that matches live trading data format
    
    Args:
        df: Full historical DataFrame
        current_idx: Current index being processed
        
    Returns:
        DataFrame: Last 100 bars up to current index
    """
    # Get last 100 bars up to current point, matching live trading
    start_idx = max(0, current_idx - 99)  # Get 100 bars or all available if less
    df_slice = df.iloc[start_idx:current_idx + 1].copy()
    df_slice.reset_index(drop=True, inplace=True)
    return df_slice

def get_historical_ema_signals(df_slice, symbol_info, prev_signal=None):
    """Get trading signals based on EMA crossover with additional filters
    using historical data slice
    
    Args:
        df_slice: DataFrame slice up to current point
        symbol_info: Symbol information from MT5
        prev_signal: Previous trading signal for state tracking
        
    Returns:
        str or None: "BUY", "SELL", or previous signal if no new crossover
    """
    if len(df_slice) < 100:  # Need enough data for calculations
        return prev_signal
        
    # Calculate TEMA (Triple Exponential Moving Average) for fast EMA
    df_slice['ema1'] = df_slice['close'].ewm(span=FAST_EMA, adjust=False).mean()
    df_slice['ema2'] = df_slice['ema1'].ewm(span=FAST_EMA, adjust=False).mean()
    df_slice['ema3'] = df_slice['ema2'].ewm(span=FAST_EMA, adjust=False).mean()
    df_slice['fast_ema'] = (3 * df_slice['ema1']) - (3 * df_slice['ema2']) + df_slice['ema3']
    
    # Calculate regular slow EMA
    df_slice['slow_ema'] = df_slice['close'].ewm(span=SLOW_EMA, adjust=False).mean()
    
    # Get current and previous values
    current_fast = df_slice['fast_ema'].iloc[-1]
    current_slow = df_slice['slow_ema'].iloc[-1]
    prev_fast = df_slice['fast_ema'].iloc[-2]
    prev_slow = df_slice['slow_ema'].iloc[-2]
    
    diff = current_fast - current_slow
    diff_points = abs(diff / symbol_info.point)
    
    # Only proceed if minimum crossover threshold is met
    if diff_points < MIN_CROSSOVER_POINTS:
        return prev_signal
    
    # Check for crossover
    potential_signal = None
    if prev_fast <= prev_slow and current_fast > current_slow:
        if prev_signal != "BUY":
            potential_signal = "BUY"
    elif prev_fast >= prev_slow and current_fast < current_slow:
        if prev_signal != "SELL":
            potential_signal = "SELL"
            
    if potential_signal:
        print(f"\nAnalyzing {potential_signal} Signal:")
        print(f"Initial Crossover: {diff_points:.1f} points")
        
        # Apply additional filters
        if not check_slope_conditions(df_slice, potential_signal):
            print("❌ Rejected: Slope conditions not met")
            return prev_signal
            
        if not check_separation(df_slice, symbol_info, potential_signal):
            print("❌ Rejected: Insufficient EMA separation")
            return prev_signal
            
        if not check_price_confirmation(df_slice, potential_signal):
            print("❌ Rejected: Price action not confirming")
            return prev_signal
            
        # All filters passed
        print(f"\n✅ Valid {potential_signal} Signal - All conditions met")
        print(f"Price: {df_slice['close'].iloc[-1]:.2f}")
        print(f"Fast EMA: {current_fast:.2f}")
        print(f"Slow EMA: {current_slow:.2f}")
        return potential_signal
    
    return prev_signal

def calculate_profit(entry_price, exit_price, trade_type, symbol):
    """Calculate profit/loss for a trade
    
    Args:
        entry_price: Entry price
        exit_price: Exit price
        trade_type: "BUY" or "SELL"
        symbol: Trading symbol
        
    Returns:
        tuple: (profit in dollars, change in percentage)
    """
    symbol_info = mt5.symbol_info(symbol)
    if symbol_info is None:
        return 0, 0
        
    # Use fixed lot size of 0.11 to match live trading
    lot_size = 0.11
    
    if trade_type == "BUY":
        points = (exit_price - entry_price) / symbol_info.point
        change_percent = ((exit_price - entry_price) / entry_price) * 100
    else:
        points = (entry_price - exit_price) / symbol_info.point
        change_percent = ((entry_price - exit_price) / entry_price) * 100
    
    # Calculate profit based on points and lot size
    point_value = 0.1  # Standard point value for most pairs
    profit = points * point_value * lot_size
    
    return profit, change_percent

def calculate_stop_levels(price, symbol_info, action):
    """Calculate stop loss and take profit levels exactly as in live strategy
    
    Args:
        price: Entry price
        symbol_info: Symbol information
        action: "BUY" or "SELL"
        
    Returns:
        tuple: (stop_loss, take_profit) prices
    """
    stop_distance = calculate_stop_distance(price, 0.01, symbol_info)
    
    if action == "BUY":
        sl = price - stop_distance
        tp = price + stop_distance
    else:
        sl = price + stop_distance
        tp = price - stop_distance
    
    return round(sl, symbol_info.digits), round(tp, symbol_info.digits)

def check_sl_tp_hit(row, entry_price, sl, tp, trade_type):
    """Check if price hit stop loss or take profit
    
    Args:
        row: DataFrame row with OHLC data
        entry_price: Entry price of trade
        sl: Stop loss price
        tp: Take profit price
        trade_type: "BUY" or "SELL"
        
    Returns:
        tuple: (bool if exit triggered, exit price, exit type)
    """
    if trade_type == "BUY":
        # Check if low hit SL or high hit TP
        if row['low'] <= sl:
            return True, sl, "sl"
        if row['high'] >= tp:
            return True, tp, "tp"
    else:  # SELL
        # Check if high hit SL or low hit TP
        if row['high'] >= sl:
            return True, sl, "sl"
        if row['low'] <= tp:
            return True, tp, "tp"
    
    return False, None, None

def backtest_strategy(symbol, risk_percentage):
    """Run backtest on today's data
    
    Args:
        symbol: Trading symbol
        risk_percentage: Risk percentage per trade
    """
    risk = risk_percentage / 100.0  # Convert to decimal
    
    # Get last hour's data plus enough history for calculations
    now = datetime.now()
    start_time = now - timedelta(hours=2)  # Get extra hour for initial calculations
    end_time = now - timedelta(minutes=1)
    
    print(f"\nBacktesting {symbol} from {start_time.strftime('%Y-%m-%d %H:%M')} to {end_time.strftime('%Y-%m-%d %H:%M')}")
    print(f"Fast EMA (TEMA): {FAST_EMA}")
    print(f"Slow EMA: {SLOW_EMA}")
    
    # Get symbol info for calculations
    symbol_info = mt5.symbol_info(symbol)
    if symbol_info is None:
        print(f"Failed to get symbol info for {symbol}")
        return
        
    print(f"\nSymbol point value: {symbol_info.point}")
    print(f"Minimum crossover points required: {MIN_CROSSOVER_POINTS}")
    print(f"Minimum separation points required: {MIN_SEPARATION_POINTS}")
    
    # Get historical data
    print("\nFetching historical data from MT5...")
    rates = mt5.copy_rates_range(symbol, mt5.TIMEFRAME_M1, start_time, end_time)
    if rates is None or len(rates) == 0:
        print("Failed to get historical data")
        return
        
    df = pd.DataFrame(rates)
    df['time'] = pd.to_datetime(df['time'], unit='s')
    
    print(f"\nLoaded {len(df)} minutes of data")
    print(f"Time range: {df['time'].iloc[0]} to {df['time'].iloc[-1]}")
    print(f"Price range: {df['close'].min():.2f} - {df['close'].max():.2f}")
    
    # Initialize variables for tracking trades
    trades = []
    current_position = None
    entry_price = None
    entry_time = None
    prev_signal = None
    ticket = 19960000
    crossovers_detected = 0
    signals_filtered = 0
    
    print("\nProcessing data minute by minute...")
    
    # Process each minute like the live strategy
    # Start from 100 bars in to have enough history
    for i in range(100, len(df)):
        # Get the last 100 bars up to current minute
        current_time = df.iloc[i]['time']
        minute_df = df.iloc[i-100:i+1].copy()
        minute_df.reset_index(drop=True, inplace=True)
        
        # Calculate EMAs exactly as in live trading
        minute_df['ema1'] = minute_df['close'].ewm(span=FAST_EMA, adjust=False).mean()
        minute_df['ema2'] = minute_df['ema1'].ewm(span=FAST_EMA, adjust=False).mean()
        minute_df['ema3'] = minute_df['ema2'].ewm(span=FAST_EMA, adjust=False).mean()
        minute_df['fast_ema'] = (3 * minute_df['ema1']) - (3 * minute_df['ema2']) + minute_df['ema3']
        minute_df['slow_ema'] = minute_df['close'].ewm(span=SLOW_EMA, adjust=False).mean()
        
        current_fast = minute_df['fast_ema'].iloc[-1]
        current_slow = minute_df['slow_ema'].iloc[-1]
        prev_fast = minute_df['fast_ema'].iloc[-2]
        prev_slow = minute_df['slow_ema'].iloc[-2]
        current_close = minute_df['close'].iloc[-1]
        
        print(f"\nAt {current_time}:")
        print(f"Close: {current_close:.5f}")
        print(f"Fast EMA: {current_fast:.5f}")
        print(f"Slow EMA: {current_slow:.5f}")
        print(f"Separation: {abs(current_fast - current_slow) / symbol_info.point:.1f} points")
        
        # Check for potential crossover
        if (prev_fast <= prev_slow and current_fast > current_slow) or \
           (prev_fast >= prev_slow and current_fast < current_slow):
            crossovers_detected += 1
            print(f"\n🔄 Potential crossover at {current_time}")
            print(f"Previous Fast: {prev_fast:.5f}")
            print(f"Previous Slow: {prev_slow:.5f}")
            print(f"Current Fast: {current_fast:.5f}")
            print(f"Current Slow: {current_slow:.5f}")
            print(f"Separation: {abs(current_fast - current_slow) / symbol_info.point:.1f} points")
            print(f"Close price: {current_close:.5f}")
        
        # Get signal using historical data function
        signal = get_historical_ema_signals(minute_df, symbol_info, prev_signal)
        
        if signal and signal != prev_signal:
            signals_filtered += 1
            # Close any existing position first
            if current_position is not None:
                exit_price = current_close
                profit, change_percent = calculate_profit(entry_price, exit_price, current_position, symbol)
                
                trades.append({
                    'Time': entry_time,
                    'Symbol': symbol,
                    'Ticket': ticket,
                    'Type': current_position.lower(),
                    'Volume': 0.11,
                    'Price': entry_price,
                    'S/L': 0,
                    'T/P': 0,
                    'Time.1': current_time,
                    'Price.1': exit_price,
                    'Profit': profit,
                    'Change %': f"{change_percent:.2f}%"
                })
                ticket += 1
                current_position = None
            
            # Open new position
            current_position = signal
            entry_price = current_close
            entry_time = current_time
            
            print(f"\n✨ Valid {signal} signal at {entry_time}")
            print(f"Entry Price: {entry_price}")
            print(f"Fast EMA: {current_fast:.5f}")
            print(f"Slow EMA: {current_slow:.5f}")
        
        prev_signal = signal
    
    print(f"\nCrossovers detected: {crossovers_detected}")
    print(f"Signals that passed filters: {signals_filtered}")
    
    # Close any remaining position at the end
    if current_position is not None:
        exit_price = df['close'].iloc[-1]
        profit, change_percent = calculate_profit(entry_price, exit_price, current_position, symbol)
        
        trades.append({
            'Time': entry_time,
            'Symbol': symbol,
            'Ticket': ticket,
            'Type': current_position.lower(),
            'Volume': 0.11,
            'Price': entry_price,
            'S/L': 0,
            'T/P': 0,
            'Time.1': df['time'].iloc[-1],
            'Price.1': exit_price,
            'Profit': profit,
            'Change %': f"{change_percent:.2f}%"
        })
    
    # Create and save trades DataFrame
    if trades:
        trades_df = pd.DataFrame(trades)
        
        # Add total row
        total_profit = trades_df['Profit'].sum()
        win_rate = (trades_df['Profit'] > 0).mean() * 100
        
        total_row = pd.DataFrame([{
            'Time': 'TOTAL',
            'Symbol': '',
            'Ticket': '',
            'Type': f'Trades: {len(trades)}',
            'Volume': '',
            'Price': '',
            'S/L': '',
            'T/P': '',
            'Time.1': '',
            'Price.1': '',
            'Profit': total_profit,
            'Change %': f"Win Rate: {win_rate:.1f}%"
        }])
        
        trades_df = pd.concat([trades_df, total_row], ignore_index=True)
        
        # Save to CSV
        filename = f'trades_{symbol}_{datetime.now().strftime("%Y%m%d_%H%M")}.csv'
        trades_df.to_csv(filename, index=False)
        
        # Print summary
        print(f"\nBacktest Results for {symbol}")
        print(f"Total Trades: {len(trades)}")
        print(f"Total Profit: ${total_profit:.2f}")
        print(f"Win Rate: {win_rate:.1f}%")
        print(f"Results saved to {filename}")
    else:
        print("\nNo trades were generated during the backtest period")

def run_historical_backtest(symbol):
    """Run historical data through the exact same strategy logic
    
    Args:
        symbol: Trading symbol to backtest
    """
    # Get symbol info
    symbol_info = mt5.symbol_info(symbol)
    if symbol_info is None:
        print(f"Failed to get symbol info for {symbol}")
        return
    
    # Get today's start and current time
    now = datetime.now()
    start_time = datetime(now.year, now.month, now.day)
    end_time = now - timedelta(minutes=5)
    
    print(f"\nBacktesting {symbol} from {start_time.strftime('%Y-%m-%d %H:%M')} to {end_time.strftime('%Y-%m-%d %H:%M')}")
    print(f"Fast EMA (TEMA): {FAST_EMA}")
    print(f"Slow EMA: {SLOW_EMA}")
    
    # Get historical data
    rates = mt5.copy_rates_range(symbol, mt5.TIMEFRAME_M1, start_time, end_time)
    if rates is None:
        print("Failed to get historical data")
        return
        
    df = pd.DataFrame(rates)
    df['time'] = pd.to_datetime(df['time'], unit='s')
    
    # Track trades
    trades = []
    prev_signal = None
    
    # Process each historical minute
    for i in range(100, len(df)):  # Start after enough data for calculations
        # Get data slice up to current point
        df_slice = df.iloc[:i+1].copy()
        current_time = df_slice.iloc[-1]['time']
        
        # Get signal using exact same logic as live strategy
        signal = get_historical_ema_signals(df_slice, symbol_info, prev_signal)
        
        if signal and signal != prev_signal:
            print(f"\nSignal change at {current_time}")
            print(f"Previous signal: {prev_signal}")
            print(f"New signal: {signal}")
            print(f"Price: {df_slice.iloc[-1]['close']}")
            
            trades.append({
                'Time': current_time,
                'Signal': signal,
                'Price': df_slice.iloc[-1]['close'],
                'Fast_EMA': df_slice['fast_ema'].iloc[-1],
                'Slow_EMA': df_slice['slow_ema'].iloc[-1]
            })
        
        prev_signal = signal
    
    # Print results
    if trades:
        print("\nDetected Signals:")
        for trade in trades:
            print(f"{trade['Time']}: {trade['Signal']} at {trade['Price']}")
            print(f"Fast EMA: {trade['Fast_EMA']:.5f}")
            print(f"Slow EMA: {trade['Slow_EMA']:.5f}\n")
    else:
        print("\nNo signals detected in historical data")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description='Backtest EMA Crossover Trading Strategy')
    parser.add_argument('symbol', help='Trading symbol (e.g., BTCUSD)')
    args = parse_arguments()
    
    if not initialize_mt5():
        print("Failed to initialize MT5")
        exit()
    
    backtest_strategy(args.symbol, args.risk)
    mt5.shutdown() 