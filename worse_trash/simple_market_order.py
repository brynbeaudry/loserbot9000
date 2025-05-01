import MetaTrader5 as mt5
import argparse
import time
from datetime import datetime

# MT5 Account details
LOGIN = 795540
PASSWORD = "Os@8rD1V"
SERVER = "PUPrime-Demo"

def execute_market_order(symbol, action, volume=0.01):
    """
    Execute a simple market order without SL/TP for testing purposes.
    
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
    
    # Get account info
    account_info = mt5.account_info()
    if account_info is None:
        print("❌ Failed to get account info")
        mt5.shutdown()
        return
        
    print(f"\nAccount Info:")
    print(f"Balance: {account_info.balance}")
    print(f"Equity: {account_info.equity}")
    print(f"Margin: {account_info.margin}")
    print(f"Free Margin: {account_info.margin_free}")
    print(f"Margin Level: {account_info.margin_level}")
    
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
    print(f"Trade Mode: {symbol_info.trade_mode}")
    
    # Get current price
    tick = mt5.symbol_info_tick(symbol)
    if tick is None:
        print("❌ Failed to get symbol price.")
        mt5.shutdown()
        return
    
    # Calculate entry price
    entry_price = tick.ask if action == "buy" else tick.bid
    digits = symbol_info.digits
    entry_price = round(entry_price, digits)
    
    print(f"\nTrading parameters:")
    print(f"Action: {action.upper()}")
    print(f"Entry Price: {entry_price}")
    print(f"Volume: {volume}")
    
    # Try different order filling types
    filling_types = [
        mt5.ORDER_FILLING_FOK,  # Fill or Kill
        mt5.ORDER_FILLING_IOC,  # Immediate or Cancel
        mt5.ORDER_FILLING_RETURN  # Return remainder
    ]
    
    filling_type_names = ["Fill or Kill", "Immediate or Cancel", "Return remainder"]
    
    for i, filling_type in enumerate(filling_types):
        print(f"\nTrying order with {filling_type_names[i]}...")
        
        # Create market order request
        request = {
            "action": mt5.TRADE_ACTION_DEAL,
            "symbol": symbol,
            "volume": volume,
            "type": mt5.ORDER_TYPE_BUY if action == "buy" else mt5.ORDER_TYPE_SELL,
            "price": entry_price,
            "deviation": 10,
            "magic": 123456,
            "comment": f"Simple {action} market order",
            "type_time": mt5.ORDER_TIME_GTC,
            "type_filling": filling_type,
        }
        
        # Execute trade
        result = mt5.order_send(request)
        
        # Check result
        if result.retcode != mt5.TRADE_RETCODE_DONE:
            print(f"❌ Trade failed with {filling_type_names[i]}, retcode: {result.retcode}")
            print(f"Error description: {mt5.last_error()}")
        else:
            print(f"✅ Trade successful with {filling_type_names[i]}: {action.upper()} at {entry_price}")
            break
    
    # Try with a pending order if market orders fail
    if result.retcode != mt5.TRADE_RETCODE_DONE:
        print("\nTrying with a pending order...")
        
        # Calculate price for pending order
        if action == "buy":
            pending_price = tick.ask + 10 * symbol_info.point  # 10 points above current price
            order_type = mt5.ORDER_TYPE_BUY_LIMIT
        else:
            pending_price = tick.bid - 10 * symbol_info.point  # 10 points below current price
            order_type = mt5.ORDER_TYPE_SELL_LIMIT
            
        pending_price = round(pending_price, digits)
        
        # Create pending order request
        pending_request = {
            "action": mt5.TRADE_ACTION_PENDING,
            "symbol": symbol,
            "volume": volume,
            "type": order_type,
            "price": pending_price,
            "deviation": 10,
            "magic": 123456,
            "comment": f"Simple {action} pending order",
            "type_time": mt5.ORDER_TIME_GTC,
            "type_filling": mt5.ORDER_FILLING_FOK,
        }
        
        # Execute pending order
        pending_result = mt5.order_send(pending_request)
        
        # Check result
        if pending_result.retcode != mt5.TRADE_RETCODE_DONE:
            print(f"❌ Pending order failed, retcode: {pending_result.retcode}")
            print(f"Error description: {mt5.last_error()}")
        else:
            print(f"✅ Pending order placed: {action.upper()} at {pending_price}")
    
    # Gracefully disconnect
    mt5.shutdown()

def main():
    parser = argparse.ArgumentParser(description='Test MT5 trading with simple market orders')
    parser.add_argument('symbol', help='Trading symbol (e.g., XAUUSD.s)')
    parser.add_argument('action', choices=['buy', 'sell'], help='Trade action')
    parser.add_argument('--volume', type=float, default=0.01, help='Trading volume (default: 0.01)')
    
    args = parser.parse_args()
    
    print(f"Testing {args.action.upper()} market order for {args.symbol}")
    execute_market_order(args.symbol, args.action, args.volume)

if __name__ == "__main__":
    main() 