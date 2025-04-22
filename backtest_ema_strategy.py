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
    MIN_SLOPE_THRESHOLD, MAX_OPPOSITE_SLOPE,
    calculate_slope, check_slope_conditions,
    check_separation, check_price_confirmation,
    calculate_stop_distance, execute_trade,
    get_ema_signals, get_current_signal,
    find_and_close_positions, get_historical_data
)

# Number of hours to backtest
BACKTEST_HOURS = 3

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

def get_ema_signals_backtest(minute_data, symbol_info, prev_signal=None):
    """Backtest version of get_ema_signals that works with historical data
    
    Args:
        minute_data: Array of rate data for the current minute
        symbol_info: Symbol information from MT5
        prev_signal: Previous trading signal for state tracking
        
    Returns:
        str or None: "BUY", "SELL", or previous signal if no new crossover
    """
    # Convert to DataFrame
    df = pd.DataFrame(minute_data)
    df['time'] = pd.to_datetime(df['time'], unit='s')
    
    # Calculate TEMA (Triple Exponential Moving Average) for fast EMA
    df['ema1'] = df['close'].ewm(span=FAST_EMA, adjust=False).mean()
    df['ema2'] = df['ema1'].ewm(span=FAST_EMA, adjust=False).mean()
    df['ema3'] = df['ema2'].ewm(span=FAST_EMA, adjust=False).mean()
    df['fast_ema'] = (3 * df['ema1']) - (3 * df['ema2']) + df['ema3']
    
    # Calculate regular slow EMA
    df['slow_ema'] = df['close'].ewm(span=SLOW_EMA, adjust=False).mean()
    
    # Get current and previous values
    current_fast = df['fast_ema'].iloc[-1]
    current_slow = df['slow_ema'].iloc[-1]
    prev_fast = df['fast_ema'].iloc[-2]
    prev_slow = df['slow_ema'].iloc[-2]
    
    # Calculate slopes over last few periods
    fast_slope = calculate_slope(df['fast_ema'])
    slow_slope = calculate_slope(df['slow_ema'])
    
    diff = current_fast - current_slow
    diff_points = abs(diff / symbol_info.point)
    
    # Check for trend correction first - when both EMAs are trending against current position
    if prev_signal:
        if prev_signal == "BUY" and fast_slope < -MIN_SLOPE_THRESHOLD*2 and slow_slope < -MIN_SLOPE_THRESHOLD*2:
            # Both EMAs trending down strongly while we're in a buy
            print(f"\n⚠️ Trend Correction: Both EMAs trending down strongly against BUY position")
            print(f"Fast Slope: {fast_slope:.8f}")
            print(f"Slow Slope: {slow_slope:.8f}")
            return "SELL"
        elif prev_signal == "SELL" and fast_slope > MIN_SLOPE_THRESHOLD*2 and slow_slope > MIN_SLOPE_THRESHOLD*2:
            # Both EMAs trending up strongly while we're in a sell
            print(f"\n⚠️ Trend Correction: Both EMAs trending up strongly against SELL position")
            print(f"Fast Slope: {fast_slope:.8f}")
            print(f"Slow Slope: {slow_slope:.8f}")
            return "BUY"
    
    # Only proceed if minimum crossover threshold is met
    if diff_points < MIN_CROSSOVER_POINTS:
        return prev_signal
    
    # Check for crossover
    potential_signal = None
    crossover_detected = False

    if prev_fast <= prev_slow and current_fast > current_slow:
        crossover_detected = True
        if prev_signal != "BUY":
            potential_signal = "BUY"
    elif prev_fast >= prev_slow and current_fast < current_slow:
        crossover_detected = True
        if prev_signal != "SELL":
            potential_signal = "SELL"
            
    # If we detect a crossover, analyze it
    if crossover_detected and potential_signal:  # Only analyze if we have a potential new signal
        print(f"\nAnalyzing potential {potential_signal} Signal:")
        print(f"Initial Crossover: {diff_points:.1f} points")
        print(f"Fast EMA: {current_fast:.5f}")
        print(f"Slow EMA: {current_slow:.5f}")
        
        slope_ok = check_slope_conditions(df, potential_signal)
        separation_ok = check_separation(df, symbol_info, potential_signal)
        price_ok = check_price_confirmation(df, potential_signal)
        
        # If all conditions are met, return the new signal
        if slope_ok and separation_ok and price_ok:
            print(f"\n✅ Valid {potential_signal} Signal - All conditions met")
            print(f"Price: {df['close'].iloc[-1]:.2f}")
            print(f"Fast EMA: {current_fast:.2f}")
            print(f"Slow EMA: {current_slow:.2f}")
            return potential_signal

    # If no valid signal was generated, maintain previous signal
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
    
    print(f"\nBacktesting {symbol} for the last {BACKTEST_HOURS} hours")
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
    
    # Calculate required bars (hours * 60 for analysis + 100 for initial calculations)
    required_bars = (BACKTEST_HOURS * 60) + 100
    
    # Get historical data using copy_rates_from_pos
    print("\nFetching historical data from MT5...")
    rates = mt5.copy_rates_from_pos(symbol, mt5.TIMEFRAME_M1, 0, required_bars)
    if rates is None or len(rates) == 0:
        print("Failed to get historical data")
        return
        
    # Convert to DataFrame for easier handling
    df = pd.DataFrame(rates)
    df['time'] = pd.to_datetime(df['time'], unit='s')
    
    print(f"\nLoaded {len(rates)} minutes of data")
    print(f"Time range: {df['time'].iloc[0]} to {df['time'].iloc[-1]}")
    print(f"Price range: {df['close'].min():.2f} - {df['close'].max():.2f}")
    
    # Initialize variables for tracking trades
    trades = []
    current_position = None
    entry_price = None
    entry_time = None
    prev_signal = None
    ticket = 19960000
    signals_filtered = 0
    account_balance = 10000  # Starting balance
    
    # Store all minute data for analysis
    all_minute_data = []
    
    print("\nProcessing data minute by minute...")
    print(f"Initial balance: ${account_balance:.2f}")
    
    # Process each minute like the live strategy
    # Start from index 100 to ensure we have enough history for initial calculations
    # But only analyze the last X hours of data
    start_idx = max(len(df) - (BACKTEST_HOURS * 60), 100)  # Start at either 100 or last X hours, whichever is later
    
    for i in range(start_idx, len(df)):
        # Get the last 100 bars up to current minute
        minute_data = df.iloc[i-99:i+1].to_dict('records')
        current_time = df['time'].iloc[i]
        current_close = df['close'].iloc[i]
        
        # Calculate EMAs for this minute
        df_slice = df.iloc[i-99:i+1].copy()
        df_slice['ema1'] = df_slice['close'].ewm(span=FAST_EMA, adjust=False).mean()
        df_slice['ema2'] = df_slice['ema1'].ewm(span=FAST_EMA, adjust=False).mean()
        df_slice['ema3'] = df_slice['ema2'].ewm(span=FAST_EMA, adjust=False).mean()
        df_slice['fast_ema'] = (3 * df_slice['ema1']) - (3 * df_slice['ema2']) + df_slice['ema3']
        df_slice['slow_ema'] = df_slice['close'].ewm(span=SLOW_EMA, adjust=False).mean()
        
        # Store this minute's data
        current_data = {
            'time': current_time,
            'close': current_close,
            'fast_ema': df_slice['fast_ema'].iloc[-1],
            'slow_ema': df_slice['slow_ema'].iloc[-1],
            'separation': abs(df_slice['fast_ema'].iloc[-1] - df_slice['slow_ema'].iloc[-1]) / symbol_info.point,
            'fast_slope': calculate_slope(df_slice['fast_ema'].tail(SLOPE_PERIODS + 1)),
            'slow_slope': calculate_slope(df_slice['slow_ema'].tail(SLOPE_PERIODS + 1))
        }
        all_minute_data.append(current_data)
        
        # Get signal using historical data
        signal = get_ema_signals_backtest(minute_data, symbol_info, prev_signal)
        
        if signal and signal != prev_signal:
            signals_filtered += 1
            current_data['signal'] = signal
            # Close any existing position first
            if current_position is not None:
                exit_price = current_close
                profit, change_percent = calculate_profit(entry_price, exit_price, current_position, symbol)
                
                # Calculate actual volume based on risk
                stop_distance = calculate_stop_distance(entry_price, 0.01, symbol_info)
                volume = calculate_lot_size(symbol_info, account_balance, risk, stop_distance)
                
                trades.append({
                    'Time': entry_time,
                    'Symbol': symbol,
                    'Ticket': ticket,
                    'Type': current_position.lower(),
                    'Volume': volume,
                    'Price': entry_price,
                    'S/L': entry_price - stop_distance if current_position == "BUY" else entry_price + stop_distance,
                    'T/P': entry_price + stop_distance if current_position == "BUY" else entry_price - stop_distance,
                    'Time.1': current_time,
                    'Price.1': exit_price,
                    'Profit': profit,
                    'Change %': f"{change_percent:.2f}%"
                })
                ticket += 1
                current_position = None
                # Update account balance
                account_balance += profit
            
            # Open new position
            current_position = signal
            entry_price = current_close
            entry_time = current_time
            
            # Calculate stop distance and volume for new position
            stop_distance = calculate_stop_distance(entry_price, 0.01, symbol_info)
            volume = calculate_lot_size(symbol_info, account_balance, risk, stop_distance)
            
            print(f"\n✨ Valid {signal} signal at {entry_time}")
            print(f"Entry Price: {entry_price}")
            print(f"Stop Distance: {stop_distance}")
            print(f"Volume: {volume}")
            print(f"Account Balance: ${account_balance:.2f}")
        else:
            current_data['signal'] = None
        
        prev_signal = signal
    
    # Save minute-by-minute data to CSV
    minute_df = pd.DataFrame(all_minute_data)
    minute_filename = f'minute_data_{symbol}_{datetime.now().strftime("%Y%m%d_%H%M")}.csv'
    minute_df.to_csv(minute_filename, index=False)
    print(f"\nMinute-by-minute data saved to {minute_filename}")
    print(f"Data range: {minute_df['time'].iloc[0]} to {minute_df['time'].iloc[-1]}")
    print(f"Total minutes analyzed: {len(minute_df)}")
    
    print(f"\nSignals that passed filters: {signals_filtered}")
    
    # Close any remaining position at the end
    if current_position is not None:
        exit_price = df['close'].iloc[-1]
        profit, change_percent = calculate_profit(entry_price, exit_price, current_position, symbol)
        
        # Calculate volume based on risk
        stop_distance = calculate_stop_distance(entry_price, 0.01, symbol_info)
        volume = calculate_lot_size(symbol_info, account_balance, risk, stop_distance)
        
        trades.append({
            'Time': entry_time,
            'Symbol': symbol,
            'Ticket': ticket,
            'Type': current_position.lower(),
            'Volume': volume,
            'Price': entry_price,
            'S/L': entry_price - stop_distance if current_position == "BUY" else entry_price + stop_distance,
            'T/P': entry_price + stop_distance if current_position == "BUY" else entry_price - stop_distance,
            'Time.1': df['time'].iloc[-1],
            'Price.1': exit_price,
            'Profit': profit,
            'Change %': f"{change_percent:.2f}%"
        })
        # Update final balance
        account_balance += profit
    
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
        print(f"Starting Balance: $10000.00")
        print(f"Final Balance: ${account_balance:.2f}")
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

def simulate_live_trading(symbol, risk_percentage):
    """Simulate live trading behavior by checking signals every tick
    
    Args:
        symbol: Trading symbol
        risk_percentage: Risk percentage per trade
    """
    risk = risk_percentage / 100.0  # Convert to decimal
    
    print(f"\nSimulating live trading for {symbol} over the last {BACKTEST_HOURS} hours")
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
    
    # Calculate time range
    end_time = datetime.now()
    start_time = end_time - timedelta(hours=BACKTEST_HOURS)
    
    # Get tick data
    print("\nFetching tick data from MT5...")
    ticks = mt5.copy_ticks_range(symbol, start_time, end_time, mt5.COPY_TICKS_ALL)
    if ticks is None or len(ticks) == 0:
        print("Failed to get tick data")
        return
        
    # Convert to DataFrame
    df_ticks = pd.DataFrame(ticks)
    df_ticks['time'] = pd.to_datetime(df_ticks['time'], unit='s')
    df_ticks['mid_price'] = (df_ticks['bid'] + df_ticks['ask']) / 2
    
    print(f"\nLoaded {len(ticks)} ticks of data")
    print(f"Time range: {df_ticks['time'].iloc[0]} to {df_ticks['time'].iloc[-1]}")
    print(f"Price range: {df_ticks['bid'].min():.2f} - {df_ticks['ask'].max():.2f}")
    print(f"Average ticks per minute: {len(ticks) / (BACKTEST_HOURS * 60):.1f}")
    
    try:
        # Initialize variables for tracking trades and state
        trades = []
        check_data = []  # Store every tick's check data
        current_position = None
        entry_price = None
        entry_time = None
        prev_signal = None
        last_signal_time = None
        ticket = 19960000
        signals_filtered = 0
        
        # Process each tick
        print("\nProcessing tick by tick...")
        
        # Calculate initial EMAs using the first 100 ticks
        window_size = 100
        df_ticks['ema1'] = df_ticks['mid_price'].ewm(span=FAST_EMA, adjust=False).mean()
        df_ticks['ema2'] = df_ticks['ema1'].ewm(span=FAST_EMA, adjust=False).mean()
        df_ticks['ema3'] = df_ticks['ema2'].ewm(span=FAST_EMA, adjust=False).mean()
        df_ticks['fast_ema'] = (3 * df_ticks['ema1']) - (3 * df_ticks['ema2']) + df_ticks['ema3']
        df_ticks['slow_ema'] = df_ticks['mid_price'].ewm(span=SLOW_EMA, adjust=False).mean()
        
        # Process each tick after initial window
        for i in range(window_size, len(df_ticks)):
            current_tick = df_ticks.iloc[i]
            tick_time = current_tick['time']
            
            # Get current values
            current_price = float(current_tick['mid_price'])
            current_fast = float(current_tick['fast_ema'])
            current_slow = float(current_tick['slow_ema'])
            prev_fast = float(df_ticks.iloc[i-1]['fast_ema'])
            prev_slow = float(df_ticks.iloc[i-1]['slow_ema'])
            
            # Calculate separation and slopes
            separation = abs(current_fast - current_slow) / symbol_info.point
            fast_slope = float(calculate_slope(df_ticks['fast_ema'].iloc[i-SLOPE_PERIODS:i+1]))
            slow_slope = float(calculate_slope(df_ticks['slow_ema'].iloc[i-SLOPE_PERIODS:i+1]))
            
            # Store check data
            check_data.append({
                'timestamp': tick_time,
                'bid': float(current_tick['bid']),
                'ask': float(current_tick['ask']),
                'mid_price': current_price,
                'fast_ema': current_fast,
                'slow_ema': current_slow,
                'prev_fast_ema': prev_fast,
                'prev_slow_ema': prev_slow,
                'separation': float(separation),
                'fast_slope': fast_slope,
                'slow_slope': slow_slope,
                'crossover_up': bool(prev_fast <= prev_slow and current_fast > current_slow),
                'crossover_down': bool(prev_fast >= prev_slow and current_fast < current_slow),
                'prev_signal': prev_signal,
                'volume': int(current_tick['volume']),
                'spread': float(current_tick['ask'] - current_tick['bid'])
            })
            
            # Check for crossover
            potential_signal = None
            if prev_fast <= prev_slow and current_fast > current_slow:
                if prev_signal != "BUY":
                    potential_signal = "BUY"
            elif prev_fast >= prev_slow and current_fast < current_slow:
                if prev_signal != "SELL":
                    potential_signal = "SELL"
                    
            if potential_signal:
                # Check slope conditions
                if potential_signal == "BUY":
                    slope_ok = float(fast_slope) > MIN_SLOPE_THRESHOLD and float(slow_slope) > MAX_OPPOSITE_SLOPE
                else:  # SELL
                    slope_ok = float(fast_slope) < -MIN_SLOPE_THRESHOLD and float(slow_slope) < -MAX_OPPOSITE_SLOPE
                
                # Check separation
                sep_ok = float(separation) >= MIN_SEPARATION_POINTS
                
                # If conditions met, generate signal
                if slope_ok and sep_ok:
                    signals_filtered += 1
                    
                    # Close any existing position first
                    if current_position is not None:
                        exit_price = current_price
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
                            'Time.1': tick_time,
                            'Price.1': exit_price,
                            'Profit': profit,
                            'Change %': f"{change_percent:.2f}%"
                        })
                        ticket += 1
                        current_position = None
                    
                    # Open new position
                    current_position = potential_signal
                    entry_price = current_price
                    entry_time = tick_time
                    
                    print(f"\n✨ Valid {potential_signal} signal at {entry_time}")
                    print(f"Entry Price: {entry_price}")
                    print(f"Fast EMA: {current_fast:.5f}")
                    print(f"Slow EMA: {current_slow:.5f}")
                    print(f"Separation: {separation:.1f} points")
                    print(f"Fast Slope: {fast_slope:.8f}")
                    print(f"Slow Slope: {slow_slope:.8f}")
                    print(f"Spread: {float(current_tick['ask'] - current_tick['bid']):.5f}")
                    
                    last_signal_time = tick_time
                    prev_signal = potential_signal
        
        # After processing all ticks, check if we have any data to save
        if not check_data:
            print("\nNo data was processed during the backtest period")
            return
            
        # Save tick-by-tick check data to CSV
        check_df = pd.DataFrame(check_data)
        check_filename = f'tick_data_{symbol}_{datetime.now().strftime("%Y%m%d_%H%M")}.csv'
        check_df.to_csv(check_filename, index=False)
        print(f"\nTick-by-tick check data saved to {check_filename}")
        print(f"Data range: {check_df['timestamp'].min()} to {check_df['timestamp'].max()}")
        print(f"Total ticks analyzed: {len(check_df)}")
        
        print(f"\nSignals that passed filters: {signals_filtered}")
        
        # Close any remaining position at the end
        if current_position is not None:
            exit_price = float(check_df['mid_price'].iloc[-1])
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
                'Time.1': check_df['timestamp'].iloc[-1],
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
            
    except Exception as e:
        print(f"\nError during backtesting: {str(e)}")
        print("Current state:")
        print(f"Processing tick at: {tick_time if 'tick_time' in locals() else 'Unknown'}")
        print(f"Data processed so far: {len(check_data)} ticks")
        if check_data:
            print("Last processed tick data:")
            print(check_data[-1])
        raise  # Re-raise the exception for full traceback

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description='Backtest EMA Crossover Trading Strategy')
    parser.add_argument('symbol', help='Trading symbol (e.g., BTCUSD)')
    args = parse_arguments()
    
    if not initialize_mt5():
        print("Failed to initialize MT5")
        exit()
    
    simulate_live_trading(args.symbol, args.risk)  # Use new simulation function
    mt5.shutdown() 