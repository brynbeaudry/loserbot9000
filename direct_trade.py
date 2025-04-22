import MetaTrader5 as mt5
import argparse
import time
from datetime import datetime

# MT5 Account details
LOGIN = 795540
PASSWORD = "Os@8rD1V"
SERVER = "PUPrime-Demo"

# Strategy parameters (matching EMA strategy)
RISK_PERCENTAGE = 0.01  # 1% risk per trade

def calculate_position_size(account_balance, risk_percentage, entry_price, stop_loss, symbol_info):
    risk_amount = account_balance * risk_percentage
    price_risk = abs(entry_price - stop_loss)
    position_size = risk_amount / (price_risk * symbol_info.trade_contract_size)
    # Round to the nearest valid volume step
    position_size = round(position_size / symbol_info.volume_step) * symbol_info.volume_step
    return max(min(position_size, symbol_info.volume_max), symbol_info.volume_min)

def is_trade_successful(result):
    """Check if a trade was successful based on MT5's result"""
    return (
        result and result.retcode in [10009, 10027] 
        or str(mt5.last_error()) == "(1, 'Success')"
    ) and result.deal > 0

def is_modification_successful(result):
    """Check if a modification was successful based on MT5's result"""
    # For modifications, we don't need to check deal > 0
    return (
        result and result.retcode in [10009, 10027] 
        or str(mt5.last_error()) == "(1, 'Success')"
    )

def calculate_stop_distance(price, risk_percentage, symbol_info):
    """Calculate stop distance based on risk percentage of current price"""
    # Use 1% of price as base distance, but ensure it respects minimum stops
    base_distance = price * risk_percentage
    min_stop_distance = symbol_info.trade_stops_level * symbol_info.point
    
    # Use whichever is larger
    return max(base_distance, min_stop_distance)

def try_trade_with_symbol(symbol, action, volume):
    """Execute a trade with the given symbol and handle stop loss/take profit"""
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

    print(f"Executing {action.upper()} at price: {price}")

    # Store initial positions to compare later
    initial_positions = mt5.positions_get(symbol=symbol)
    initial_position_tickets = set()
    if initial_positions:
        initial_position_tickets = {pos.ticket for pos in initial_positions}
        print(f"Initial positions: {initial_position_tickets}")

    # Create trade request without SL/TP first
    request = {
        "action": mt5.TRADE_ACTION_DEAL,
        "symbol": symbol,
        "volume": float(volume),
        "type": mt5.ORDER_TYPE_BUY if action == "buy" else mt5.ORDER_TYPE_SELL,
        "price": price,
        "deviation": 20,
        "magic": 234000,
        "comment": "python script open",
        "type_time": mt5.ORDER_TIME_GTC,
        "type_filling": mt5.ORDER_FILLING_IOC,
    }

    result = mt5.order_send(request)
    if not is_trade_successful(result):
        error = mt5.last_error()
        print(f"Failed to execute trade: {error}")
        return False

    print(f"Trade executed successfully! Deal #{result.deal}")

    # Now find the new position by comparing with initial positions
    position = None
    print("\nSearching for new position...")
    for i in range(10):  # Try a few times to get the position
        positions = mt5.positions_get(symbol=symbol)
        if positions is None:
            print(f"Failed to get positions, error: {mt5.last_error()}")
            continue
            
        print(f"Found {len(positions)} total positions")
        if positions:
            # Look for a position that wasn't in our initial set
            for pos in positions:
                print(f"Checking position: Ticket #{pos.ticket}, Type: {'Buy' if pos.type == mt5.POSITION_TYPE_BUY else 'Sell'}, Time: {pos.time}")
                if pos.ticket not in initial_position_tickets:
                    position = pos
                    print(f"Found new position #{pos.ticket}")
                    break
        if position:
            break
        print(f"New position not found, attempt {i+1}/10")
        time.sleep(0.1)

    if not position:
        print("Warning: Could not find position to modify SL/TP")
        return True  # Trade was still successful

    # Calculate SL and TP based on risk percentage
    print(f"\nCalculating SL/TP levels:")
    print(f"Symbol point: {symbol_info.point}")
    print(f"Minimum stop level: {symbol_info.trade_stops_level} points")
    print(f"Contract size: {symbol_info.trade_contract_size}")
    
    # Calculate stop distance based on risk percentage (default 1%)
    stop_distance = calculate_stop_distance(price, 0.01, symbol_info)
    print(f"Stop distance: {stop_distance} ({stop_distance / symbol_info.point:.1f} points)")
    
    if action == "buy":
        sl = price - stop_distance
        tp = price + stop_distance
    else:
        sl = price + stop_distance
        tp = price - stop_distance

    # Round to appropriate number of digits
    sl = round(sl, digits)
    tp = round(tp, digits)

    print(f"Entry Price: {price}")
    print(f"Stop Loss: {sl} ({abs(price - sl)} distance, {abs(price - sl) / price * 100:.2f}% from entry)")
    print(f"Take Profit: {tp} ({abs(price - tp)} distance, {abs(price - tp) / price * 100:.2f}% from entry)")

    # Create modify request
    modify_request = {
        "action": mt5.TRADE_ACTION_SLTP,
        "symbol": symbol,
        "sl": sl,
        "tp": tp,
        "position": position.ticket
    }

    print("\nSending modify request...")
    modify_result = mt5.order_send(modify_request)
    
    if modify_result is None:
        print(f"Modification failed - no result returned")
        print(f"Last error: {mt5.last_error()}")
        return True
        
    print(f"Modification result - Retcode: {modify_result.retcode}")
    print(f"Modification comment: {modify_result.comment}")
    
    if not is_modification_successful(modify_result):
        print(f"Failed to set SL/TP: {mt5.last_error()}")
    else:
        print(f"Successfully set SL to {sl} and TP to {tp}")

    return True

def execute_direct_trade(symbol, action, volume=None):
    """
    Execute a trade using a different approach with more diagnostic information.
    
    Args:
        symbol (str): Trading symbol (e.g., "XAUUSD.s")
        action (str): "buy" or "sell"
        volume (float): Optional trading volume, if None will calculate based on risk
    """
    # Initialize MT5 connection
    if not mt5.initialize(login=LOGIN, password=PASSWORD, server=SERVER):
        print("❌ Initialization failed, error:", mt5.last_error())
        return

    print("✅ Connected to MT5!")
    
    # Get terminal info
    terminal_info = mt5.terminal_info()
    if terminal_info is None:
        print("❌ Failed to get terminal info")
        mt5.shutdown()
        return
    
    # Check if AutoTrading is enabled
    if not terminal_info.trade_allowed:
        print("\n❌ ERROR: AutoTrading is disabled in MT5 terminal!")
        print("Please enable AutoTrading (click the 'AutoTrading' button in MT5 toolbar)")
        mt5.shutdown()
        return
    
    # Try with original symbol first
    success = try_trade_with_symbol(symbol, action, volume)
    
    # If original symbol fails, try with alternative symbol
    if not success:
        alt_symbol = symbol.replace(".s", "")  # Try without the .s suffix
        print(f"\nTrying with alternative symbol: {alt_symbol}")
        try_trade_with_symbol(alt_symbol, action, volume)
    
    # Gracefully disconnect
    mt5.shutdown()

def main():
    parser = argparse.ArgumentParser(description='Test MT5 trading with direct approach')
    parser.add_argument('symbol', help='Trading symbol (e.g., XAUUSD.s)')
    parser.add_argument('action', choices=['buy', 'sell'], help='Trade action')
    parser.add_argument('--volume', type=float, help='Trading volume (optional, will calculate based on risk if not provided)')
    
    args = parser.parse_args()
    
    print(f"Testing {args.action.upper()} trade for {args.symbol}")
    execute_direct_trade(args.symbol, args.action, args.volume)

if __name__ == "__main__":
    main() 