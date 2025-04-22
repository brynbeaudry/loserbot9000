import MetaTrader5 as mt5
import argparse
import time
from datetime import datetime

# MT5 Account details
LOGIN = 795540
PASSWORD = "Os@8rD1V"
SERVER = "PUPrime-Demo"

def execute_trade(symbol, action, volume=0.01):
    """
    Execute a simple trade (buy or sell) for testing purposes.
    
    Args:
        symbol (str): Trading symbol (e.g., "XAUUSD.s")
        action (str): "buy" or "sell"
        volume (float): Trading volume (default: 0.01)
    """
    # Initialize MT5 connection
    if not mt5.initialize(login=LOGIN, password=PASSWORD, server=SERVER):
        print("❌ Initialization failed, error:", mt5.last_error())
        return

    print("✅ Connected to MT5!")
    
    # Get symbol info
    symbol_info = mt5.symbol_info(symbol)
    if symbol_info is None:
        print(f"❌ Failed to get symbol info for {symbol}")
        mt5.shutdown()
        return
        
    # Enable symbol for trading if needed
    if not symbol_info.visible:
        if not mt5.symbol_select(symbol, True):
            print(f"❌ Failed to select symbol {symbol}")
            mt5.shutdown()
            return
    
    # Print symbol info
    print(f"\nSymbol Info for {symbol}:")
    print(f"Point: {symbol_info.point}")
    print(f"Digits: {symbol_info.digits}")
    print(f"Trade Contract Size: {symbol_info.trade_contract_size}")
    print(f"Volume Min: {symbol_info.volume_min}")
    print(f"Volume Max: {symbol_info.volume_max}")
    print(f"Volume Step: {symbol_info.volume_step}")
    print(f"Trade Stops Level: {symbol_info.trade_stops_level}")
    
    # Get current price
    tick = mt5.symbol_info_tick(symbol)
    if tick is None:
        print("❌ Failed to get symbol price.")
        mt5.shutdown()
        return
    
    # Calculate entry price and stop levels
    entry_price = tick.ask if action == "buy" else tick.bid
    point = symbol_info.point
    digits = symbol_info.digits
    
    # Calculate stop distance based on trade_stops_level
    min_stop_distance = max(symbol_info.trade_stops_level * point, 50 * point)  # At least 50 points or trade_stops_level
    stop_distance = min_stop_distance
    
    # Normalize prices according to symbol digits
    entry_price = round(entry_price, digits)
    
    if action == "buy":
        stop_loss = round(entry_price - stop_distance, digits)
        take_profit = round(entry_price + stop_distance, digits)
        order_type = mt5.ORDER_TYPE_BUY
    else:
        stop_loss = round(entry_price + stop_distance, digits)
        take_profit = round(entry_price - stop_distance, digits)
        order_type = mt5.ORDER_TYPE_SELL
    
    print(f"\nTrading parameters:")
    print(f"Action: {action.upper()}")
    print(f"Entry Price: {entry_price}")
    print(f"Stop Loss: {stop_loss}")
    print(f"Take Profit: {take_profit}")
    print(f"Volume: {volume}")
    print(f"Stop Distance: {stop_distance/point:.1f} points")
    
    # First, execute the market order without SL/TP
    request = {
        "action": mt5.TRADE_ACTION_DEAL,
        "symbol": symbol,
        "volume": volume,
        "type": order_type,
        "price": entry_price,
        "deviation": 10,
        "magic": 123456,
        "comment": f"Test {action} trade",
        "type_time": mt5.ORDER_TIME_GTC,
        "type_filling": mt5.ORDER_FILLING_IOC,  # Changed to Immediate or Cancel
    }
    
    # Execute trade
    result = mt5.order_send(request)
    
    # Check result
    if result.retcode != mt5.TRADE_RETCODE_DONE:
        print(f"❌ Trade failed, retcode: {result.retcode}")
        print(f"Error description: {mt5.last_error()}")
        mt5.shutdown()
        return
    
    print(f"✅ Trade executed: {action.upper()} at {entry_price}")
    
    # Now modify the position to add SL/TP
    position = mt5.positions_get(symbol=symbol)
    if position:
        position = position[0]  # Get the first position
        
        # Create modification request
        modify_request = {
            "action": mt5.TRADE_ACTION_SLTP,
            "symbol": symbol,
            "position": position.ticket,
            "sl": stop_loss,
            "tp": take_profit,
        }
        
        # Modify the position
        modify_result = mt5.order_send(modify_request)
        
        if modify_result.retcode != mt5.TRADE_RETCODE_DONE:
            print(f"⚠️ Failed to set SL/TP, retcode: {modify_result.retcode}")
            print(f"Error description: {mt5.last_error()}")
        else:
            print(f"✅ Stop Loss and Take Profit set successfully")
            print(f"Stop Loss: {stop_loss}")
            print(f"Take Profit: {take_profit}")
    else:
        print("⚠️ Could not find the position to modify")
    
    # Gracefully disconnect
    mt5.shutdown()

def main():
    parser = argparse.ArgumentParser(description='Test MT5 trading with simple buy/sell')
    parser.add_argument('symbol', help='Trading symbol (e.g., XAUUSD.s)')
    parser.add_argument('action', choices=['buy', 'sell'], help='Trade action')
    parser.add_argument('--volume', type=float, default=0.01, help='Trading volume (default: 0.01)')
    
    args = parser.parse_args()
    
    print(f"Testing {args.action.upper()} trade for {args.symbol}")
    execute_trade(args.symbol, args.action, args.volume)

if __name__ == "__main__":
    main() 