import MetaTrader5 as mt5
import pandas as pd
import numpy as np
import time
import argparse
from datetime import datetime, timedelta

# MT5 Account Configuration
LOGIN = 796068
PASSWORD = "52N1%!mm"
SERVER = "PUPrime-Demo"

# Trading Parameters
FAST_EMA = 2  # Period for TEMA calculation
SLOW_EMA = 8
RISK_PERCENTAGE = 0.01  # 1% risk per trade
MAGIC_NUMBER = 234000
DEVIATION = 20  # Price deviation allowed for market orders

def initialize_mt5():
    """Initialize connection to MetaTrader 5 platform
    
    Returns:
        bool: True if initialization successful, False otherwise
    """
    if not mt5.initialize(login=LOGIN, password=PASSWORD, server=SERVER):
        print("❌ Initialization failed:", mt5.last_error())
        return False
    return True

def check_autotrading_enabled():
    """Check if AutoTrading is enabled in MT5 terminal
    
    Returns:
        bool: True if AutoTrading is enabled, False otherwise
    """
    terminal_info = mt5.terminal_info()
    if terminal_info is None or not terminal_info.trade_allowed:
        print("\n❌ ERROR: AutoTrading is disabled in MT5 terminal!")
        print("Please enable AutoTrading (click the 'AutoTrading' button in MT5 toolbar)")
        return False
    return True

def get_account_info():
    """Get current account information
    
    Returns:
        AccountInfo object or None if failed
    """
    account = mt5.account_info()
    if account is None:
        print("Failed to get account info")
        return None
    return account

def calculate_lot_size(symbol_info, account_balance, risk_percentage, stop_distance):
    """Calculate the appropriate lot size based on account balance and risk
    
    Args:
        symbol_info: Symbol information from MT5
        account_balance: Current account balance
        risk_percentage: Percentage of account to risk per trade
        stop_distance: Distance to stop loss in points
        
    Returns:
        float: Calculated lot size respecting symbol limits
    """
    # Calculate the value we're willing to risk
    risk_amount = account_balance * risk_percentage
    
    # Calculate pip value and required lot size
    pip_value = symbol_info.trade_contract_size * stop_distance
    lot_size = risk_amount / pip_value
    
    # Round to the nearest valid volume step
    lot_size = round(lot_size / symbol_info.volume_step) * symbol_info.volume_step
    
    # Ensure within symbol limits
    return max(min(lot_size, symbol_info.volume_max), symbol_info.volume_min)

def calculate_position_size(account_balance, risk_percentage, entry_price, stop_loss, symbol_info):
    """Calculate position size based on risk management parameters
    
    Args:
        account_balance: Current account balance
        risk_percentage: Percentage of account to risk
        entry_price: Entry price for the trade
        stop_loss: Stop loss price
        symbol_info: Symbol information from MT5
        
    Returns:
        float: Position size in lots
    """
    risk_amount = account_balance * risk_percentage
    price_risk = abs(entry_price - stop_loss)
    position_size = risk_amount / (price_risk * symbol_info.trade_contract_size)
    # Round to the nearest valid volume step
    position_size = round(position_size / symbol_info.volume_step) * symbol_info.volume_step
    return max(min(position_size, symbol_info.volume_max), symbol_info.volume_min)

def calculate_stop_distance(price, risk_percentage, symbol_info):
    """Calculate stop loss distance based on risk percentage
    
    Args:
        price: Current market price
        risk_percentage: Percentage of price to use for stop
        symbol_info: Symbol information from MT5
        
    Returns:
        float: Stop distance in price units
    """
    # Use risk percentage of price as base distance, but ensure it respects minimum stops
    base_distance = price * risk_percentage
    min_stop_distance = symbol_info.trade_stops_level * symbol_info.point
    
    # Use whichever is larger
    return max(base_distance, min_stop_distance)

def get_historical_data(symbol):
    """Get historical price data for EMA calculation
    
    Args:
        symbol: Trading symbol
        
    Returns:
        DataFrame or None: Historical price data with calculated EMAs
    """
    rates = mt5.copy_rates_from_pos(symbol, mt5.TIMEFRAME_M1, 0, 100)
    if rates is None:
        print("❌ Failed to get historical data")
        return None
        
    df = pd.DataFrame(rates)
    df['time'] = pd.to_datetime(df['time'], unit='s')
    
    # Calculate TEMA (Triple Exponential Moving Average)
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

def get_ema_signals(symbol, prev_signal=None):
    """Get trading signals based on EMA crossover
    
    Args:
        symbol: Trading symbol
        prev_signal: Previous trading signal for state tracking
        
    Returns:
        str or None: "BUY", "SELL", or previous signal if no new crossover
    """
    df = get_historical_data(symbol)
    if df is None:
        return None
    
    # Get current and previous values
    current_fast = df['fast_ema'].iloc[-1]
    current_slow = df['slow_ema'].iloc[-1]
    prev_fast = df['fast_ema'].iloc[-2]
    prev_slow = df['slow_ema'].iloc[-2]
    
    # Check for crossover - only return signal on actual cross and if different from previous signal
    if prev_fast <= prev_slow and current_fast > current_slow:
        if prev_signal != "BUY":  # Only signal if it's a new crossover
            print(f"\n🟢 BUY Signal - Fast EMA crossed above Slow EMA at price: {df['close'].iloc[-1]:.2f}")
            return "BUY"
    elif prev_fast >= prev_slow and current_fast < current_slow:
        if prev_signal != "SELL":  # Only signal if it's a new crossover
            print(f"\n🔴 SELL Signal - Fast EMA crossed below Slow EMA at price: {df['close'].iloc[-1]:.2f}")
            return "SELL"
    
    # No new crossover
    return prev_signal

def get_current_signal(symbol):
    """Get current trading signal based on EMA positions without waiting for crossover
    
    Args:
        symbol: Trading symbol
        
    Returns:
        str or None: "BUY" if fast above slow, "SELL" if fast below slow
    """
    df = get_historical_data(symbol)
    if df is None:
        return None
    
    # Get current values
    current_fast = df['fast_ema'].iloc[-1]
    current_slow = df['slow_ema'].iloc[-1]
    
    # Calculate the difference
    diff = current_fast - current_slow
    diff_points = abs(diff / mt5.symbol_info(symbol).point)
    
    print(f"\nCurrent EMA Positions:")
    print(f"TEMA ({FAST_EMA}): {current_fast:.5f}")
    print(f"Slow EMA ({SLOW_EMA}): {current_slow:.5f}")
    print(f"Difference: {diff:.5f} ({diff_points:.1f} points)")
    
    # Check current position
    if current_fast > current_slow:
        print("TEMA is above Slow EMA - Bullish position")
        return "BUY"
    elif current_fast < current_slow:
        print("TEMA is below Slow EMA - Bearish position")
        return "SELL"
    return None

def is_trade_successful(result):
    """Check if a trade was successful based on MT5's result
    
    Args:
        result: MT5 order result object
        
    Returns:
        bool: True if trade was successful
    """
    return (
        result and result.retcode in [10009, 10027] 
        or str(mt5.last_error()) == "(1, 'Success')"
    ) and result.deal > 0

def is_modification_successful(result):
    """Check if a position modification was successful
    
    Args:
        result: MT5 order result object
        
    Returns:
        bool: True if modification was successful
    """
    return (
        result and result.retcode in [10009, 10027] 
        or str(mt5.last_error()) == "(1, 'Success')"
    )

def close_position(symbol, position):
    """Close an open position
    
    Args:
        symbol: Trading symbol
        position: Position object to close
        
    Returns:
        bool: True if position was closed successfully
    """
    # Get the current price for the close
    price = mt5.symbol_info_tick(symbol).ask if position.type == mt5.POSITION_TYPE_SELL else mt5.symbol_info_tick(symbol).bid
    
    # Create the request
    close_request = {
        "action": mt5.TRADE_ACTION_DEAL,
        "symbol": symbol,
        "position": position.ticket,  # Use the ticket number, not the position object
        "volume": position.volume,
        "type": mt5.ORDER_TYPE_BUY if position.type == mt5.POSITION_TYPE_SELL else mt5.ORDER_TYPE_SELL,
        "price": price,  # Current market price
        "deviation": DEVIATION,
        "magic": MAGIC_NUMBER,
        "comment": "Close position",
        "type_time": mt5.ORDER_TIME_GTC,
        "type_filling": mt5.ORDER_FILLING_IOC,
    }
    
    # Send order to close position
    result = mt5.order_send(close_request)
    if not is_trade_successful(result):
        print(f"Failed to close position {position.ticket}: {mt5.last_error()}")
        return False
        
    print(f"Position {position.ticket} closed successfully")
    return True

def find_and_close_positions(symbol, current_signal):
    """Find and close positions opposite to the current signal
    
    Args:
        symbol: Trading symbol
        current_signal: Current trading signal ("BUY" or "SELL")
    """
    positions = mt5.positions_get(symbol=symbol)
    if positions is None or len(positions) == 0:
        return
        
    close_type = mt5.POSITION_TYPE_SELL if current_signal == "BUY" else mt5.POSITION_TYPE_BUY
    
    for position in positions:
        if position.type == close_type:
            print(f"\nClosing {position.type} position {position.ticket} before opening new {current_signal}")
            if not close_position(symbol, position):
                print(f"Warning: Failed to close position {position.ticket}, proceeding with caution")

def execute_trade(symbol, action, risk_percentage):
    """Execute a trade with the given parameters
    
    Args:
        symbol: Trading symbol
        action: Trade action ("buy" or "sell")
        risk_percentage: Risk percentage for the trade
        
    Returns:
        bool: True if trade was executed successfully
    """
    # Get symbol info for price digits
    symbol_info = mt5.symbol_info(symbol)
    if symbol_info is None:
        print(f"Failed to get symbol info for {symbol}")
        return False
    
    digits = symbol_info.digits

    # Get the current price
    price = mt5.symbol_info_tick(symbol).ask if action == "buy" else mt5.symbol_info_tick(symbol).bid
    if not price:
        print("Failed to get current price")
        return False

    # Get account info for risk calculation
    account = mt5.account_info()
    if account is None:
        print("Failed to get account info")
        return False

    print(f"Executing {action.upper()} at price: {price}")

    # Calculate stop distance
    stop_distance = calculate_stop_distance(price, RISK_PERCENTAGE, symbol_info)
    
    # Calculate appropriate lot size based on risk
    volume = calculate_lot_size(symbol_info, account.balance, risk_percentage, stop_distance)
    print(f"Account Balance: ${account.balance:.2f}")
    print(f"Risk Amount ({risk_percentage*100}%): ${account.balance * risk_percentage:.2f}")
    print(f"Calculated lot size: {volume}")

    # Store initial positions to compare later
    initial_positions = mt5.positions_get(symbol=symbol)
    initial_position_tickets = set()
    if initial_positions:
        initial_position_tickets = {pos.ticket for pos in initial_positions}

    # Create trade request without SL/TP first
    request = {
        "action": mt5.TRADE_ACTION_DEAL,
        "symbol": symbol,
        "volume": float(volume),
        "type": mt5.ORDER_TYPE_BUY if action == "buy" else mt5.ORDER_TYPE_SELL,
        "price": price,
        "deviation": DEVIATION,
        "magic": MAGIC_NUMBER,
        "comment": "EMA crossover",
        "type_time": mt5.ORDER_TIME_GTC,
        "type_filling": mt5.ORDER_FILLING_IOC,
    }

    result = mt5.order_send(request)
    if not is_trade_successful(result):
        print(f"Failed to execute {action} trade: {mt5.last_error()}")
        return False

    print(f"{action.capitalize()} trade executed successfully! Deal #{result.deal}")

    # Find the new position and set SL/TP
    position = None
    for i in range(10):  # Try a few times to get the position
        positions = mt5.positions_get(symbol=symbol)
        if positions:
            for pos in positions:
                if pos.ticket not in initial_position_tickets:
                    position = pos
                    break
        if position:
            break
        time.sleep(0.1)

    if not position:
        print("Warning: Could not find position to modify SL/TP")
        return True  # Trade was still successful

    # Calculate SL and TP based on risk percentage
    stop_distance = calculate_stop_distance(price, 0.01, symbol_info)
    
    if action == "buy":
        sl = price - stop_distance
        tp = price + stop_distance
    else:
        sl = price + stop_distance
        tp = price - stop_distance

    # Round to appropriate number of digits
    sl = round(sl, digits)
    tp = round(tp, digits)

    print(f"\nSetting SL/TP:")
    print(f"Entry Price: {price}")
    print(f"Stop Loss: {sl} ({abs(price - sl)} distance)")
    print(f"Take Profit: {tp} ({abs(price - tp)} distance)")

    # Create modify request
    modify_request = {
        "action": mt5.TRADE_ACTION_SLTP,
        "symbol": symbol,
        "sl": sl,
        "tp": tp,
        "position": position.ticket
    }

    modify_result = mt5.order_send(modify_request)
    
    if not is_modification_successful(modify_result):
        print(f"Failed to set SL/TP: {mt5.last_error()}")
    else:
        print(f"Successfully set SL to {sl} and TP to {tp}")

    return True

def parse_arguments():
    """Parse command line arguments
    
    Returns:
        argparse.Namespace: Parsed arguments
    """
    parser = argparse.ArgumentParser(description='EMA Crossover Trading Strategy')
    parser.add_argument('symbol', help='Trading symbol (e.g., XAUUSD.s)')
    parser.add_argument('--risk', type=float, default=1.0, 
                       help='Risk percentage per trade (default: 1.0 means 1%)')
    parser.add_argument('--trade-on-start', action='store_true', 
                       help='Execute a trade based on current EMA positions at startup')
    return parser.parse_args()

def main():
    """Main function to run the EMA crossover trading strategy"""
    args = parse_arguments()
    risk = args.risk / 100.0  # Convert percentage to decimal

    # Initialize MT5 and check requirements
    if not initialize_mt5():
        return
    
    if not check_autotrading_enabled():
        mt5.shutdown()
        return
    
    account = get_account_info()
    if account is None:
        mt5.shutdown()
        return

    print(f"\nTrading {args.symbol} with {FAST_EMA}/{SLOW_EMA} EMA Crossover")
    print(f"Risk per trade: {args.risk}%")
    print(f"Balance: {account.balance:.2f}")
    
    # Trading state variables
    last_signal_time = None
    last_signal = None
    in_position = False
    current_position_type = None
    
    # Check current EMA positions if trading on start is enabled
    if args.trade_on_start:
        print("\nChecking current EMA positions...")
        signal = get_current_signal(args.symbol)  # Use get_current_signal for startup
        if signal:
            print(f"\nValid {signal} signal found at startup - EMAs are currently positioned for a {signal}")
            action = signal.lower()
            find_and_close_positions(args.symbol, signal)
            if execute_trade(args.symbol, action, risk):
                print("Initial trade executed successfully")
                last_signal = signal
                in_position = True
                current_position_type = action
        else:
            print("No clear EMA position advantage at startup - waiting for crossover")
    
    print("\nBot running... Press Ctrl+C to stop")
    
    # Main trading loop
    while True:
        try:
            current_time = datetime.now()
            
            # Check for new signals every second
            if last_signal_time is None or (current_time - last_signal_time).total_seconds() >= 1:
                signal = get_ema_signals(args.symbol, last_signal)
                
                if signal and signal != last_signal:
                    action = signal.lower()
                    should_trade = False
                    
                    if not in_position:
                        should_trade = True
                    elif current_position_type != action:  # Signal is opposite to current position
                        should_trade = True
                        find_and_close_positions(args.symbol, signal)
                        
                    if should_trade:
                        if execute_trade(args.symbol, action, risk):
                            last_signal = signal
                            last_signal_time = current_time
                            in_position = True
                            current_position_type = action
                
            time.sleep(0.1)  # Check every 100ms
            
        except KeyboardInterrupt:
            print("\nBot stopped")
            break
        except Exception as e:
            print(f"Error: {e}")
            time.sleep(0.1)
    
    mt5.shutdown()

if __name__ == "__main__":
    main()
