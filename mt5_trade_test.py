import MetaTrader5 as mt5
import argparse
import time
from datetime import datetime

# MT5 Account details
LOGIN = 795540
PASSWORD = "Os@8rD1V"
SERVER = "PUPrime-Demo"

def test_trade(symbol, action, volume=0.01):
    """
    Test different approaches to execute trades and understand retcode 10027.
    
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
    print(f"Login: {account_info.login}")
    print(f"Server: {account_info.server}")
    print(f"Balance: {account_info.balance}")
    print(f"Equity: {account_info.equity}")
    print(f"Margin: {account_info.margin}")
    print(f"Free Margin: {account_info.margin_free}")
    print(f"Margin Level: {account_info.margin_level}")
    print(f"Currency: {account_info.currency}")
    
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
    
    # Test 1: Try with a pending order (Buy Stop)
    print("\nTest 1: Trying with a Buy Stop order...")
    
    # Calculate price for pending order (10 points above current price for buy stop)
    pending_price = entry_price + 10 * symbol_info.point
    pending_price = round(pending_price, digits)
    
    # Create a pending order request
    pending_request = {
        "action": mt5.TRADE_ACTION_PENDING,
        "symbol": symbol,
        "volume": volume,
        "type": mt5.ORDER_TYPE_BUY_STOP if action == "buy" else mt5.ORDER_TYPE_SELL_STOP,
        "price": pending_price,
        "deviation": 10,
        "magic": 123456,
        "comment": f"Test {action} pending order",
        "type_time": mt5.ORDER_TIME_GTC,
        "type_filling": mt5.ORDER_FILLING_FOK,
    }
    
    # Execute pending order
    pending_result = mt5.order_send(pending_request)
    
    # Check result
    if pending_result is None:
        print(f"❌ Pending order failed completely")
        print(f"Error description: {mt5.last_error()}")
    elif pending_result.retcode != mt5.TRADE_RETCODE_DONE:
        print(f"❌ Pending order failed, retcode: {pending_result.retcode}")
        print(f"Error description: {mt5.last_error()}")
    else:
        print(f"✅ Pending order placed: {action.upper()} at {pending_price}")
        
        # Try to delete the pending order
        delete_request = {
            "action": mt5.TRADE_ACTION_REMOVE,
            "order": pending_result.order,
            "symbol": symbol,
        }
        
        delete_result = mt5.order_send(delete_request)
        
        if delete_result is None:
            print(f"❌ Failed to delete pending order completely")
            print(f"Error description: {mt5.last_error()}")
        elif delete_result.retcode != mt5.TRADE_RETCODE_DONE:
            print(f"❌ Failed to delete pending order, retcode: {delete_result.retcode}")
            print(f"Error description: {mt5.last_error()}")
        else:
            print(f"✅ Pending order deleted")
    
    # Test 2: Try with a market order and no price
    print("\nTest 2: Trying with a market order and no price...")
    
    # Create a market order request without price
    market_request = {
        "action": mt5.TRADE_ACTION_DEAL,
        "symbol": symbol,
        "volume": volume,
        "type": mt5.ORDER_TYPE_BUY if action == "buy" else mt5.ORDER_TYPE_SELL,
        "deviation": 10,
        "magic": 123456,
        "comment": f"Test {action} market order",
        "type_time": mt5.ORDER_TIME_GTC,
        "type_filling": mt5.ORDER_FILLING_FOK,
    }
    
    # Execute market order
    market_result = mt5.order_send(market_request)
    
    # Check result
    if market_result is None:
        print(f"❌ Market order failed completely")
        print(f"Error description: {mt5.last_error()}")
    elif market_result.retcode != mt5.TRADE_RETCODE_DONE:
        print(f"❌ Market order failed, retcode: {market_result.retcode}")
        print(f"Error description: {mt5.last_error()}")
    else:
        print(f"✅ Market order successful: {action.upper()}")
    
    # Test 3: Try with a market order and current price
    print("\nTest 3: Trying with a market order and current price...")
    
    # Create a market order request with current price
    market_price_request = {
        "action": mt5.TRADE_ACTION_DEAL,
        "symbol": symbol,
        "volume": volume,
        "type": mt5.ORDER_TYPE_BUY if action == "buy" else mt5.ORDER_TYPE_SELL,
        "price": entry_price,
        "deviation": 10,
        "magic": 123456,
        "comment": f"Test {action} market order with price",
        "type_time": mt5.ORDER_TIME_GTC,
        "type_filling": mt5.ORDER_FILLING_FOK,
    }
    
    # Execute market order with price
    market_price_result = mt5.order_send(market_price_request)
    
    # Check result
    if market_price_result is None:
        print(f"❌ Market order with price failed completely")
        print(f"Error description: {mt5.last_error()}")
    elif market_price_result.retcode != mt5.TRADE_RETCODE_DONE:
        print(f"❌ Market order with price failed, retcode: {market_price_result.retcode}")
        print(f"Error description: {mt5.last_error()}")
    else:
        print(f"✅ Market order with price successful: {action.upper()} at {entry_price}")
    
    # Test 4: Try with a different order filling type
    print("\nTest 4: Trying with a different order filling type...")
    
    # Create a market order request with IOC filling type
    ioc_request = {
        "action": mt5.TRADE_ACTION_DEAL,
        "symbol": symbol,
        "volume": volume,
        "type": mt5.ORDER_TYPE_BUY if action == "buy" else mt5.ORDER_TYPE_SELL,
        "price": entry_price,
        "deviation": 10,
        "magic": 123456,
        "comment": f"Test {action} market order with IOC",
        "type_time": mt5.ORDER_TIME_GTC,
        "type_filling": mt5.ORDER_FILLING_IOC,
    }
    
    # Execute market order with IOC
    ioc_result = mt5.order_send(ioc_request)
    
    # Check result
    if ioc_result is None:
        print(f"❌ Market order with IOC failed completely")
        print(f"Error description: {mt5.last_error()}")
    elif ioc_result.retcode != mt5.TRADE_RETCODE_DONE:
        print(f"❌ Market order with IOC failed, retcode: {ioc_result.retcode}")
        print(f"Error description: {mt5.last_error()}")
    else:
        print(f"✅ Market order with IOC successful: {action.upper()} at {entry_price}")
    
    # Test 5: Try with a different symbol format
    print("\nTest 5: Trying with a different symbol format...")
    
    # Try with alternative symbol format (without .s)
    alt_symbol = symbol.replace(".s", "")
    print(f"Trying with alternative symbol: {alt_symbol}")
    
    # Get symbol info for alternative symbol
    alt_symbol_info = mt5.symbol_info(alt_symbol)
    if alt_symbol_info is None:
        print(f"❌ Failed to get symbol info for {alt_symbol}")
    else:
        # Enable symbol for trading if needed
        if not alt_symbol_info.visible:
            if not mt5.symbol_select(alt_symbol, True):
                print(f"❌ Failed to select symbol {alt_symbol}")
            else:
                # Get current price for alternative symbol
                alt_tick = mt5.symbol_info_tick(alt_symbol)
                if alt_tick is None:
                    print("❌ Failed to get symbol price for alternative symbol.")
                else:
                    # Calculate entry price for alternative symbol
                    alt_entry_price = alt_tick.ask if action == "buy" else alt_tick.bid
                    alt_digits = alt_symbol_info.digits
                    alt_entry_price = round(alt_entry_price, alt_digits)
                    
                    print(f"Alternative symbol price: {alt_entry_price}")
                    
                    # Create a market order request for alternative symbol
                    alt_request = {
                        "action": mt5.TRADE_ACTION_DEAL,
                        "symbol": alt_symbol,
                        "volume": volume,
                        "type": mt5.ORDER_TYPE_BUY if action == "buy" else mt5.ORDER_TYPE_SELL,
                        "price": alt_entry_price,
                        "deviation": 10,
                        "magic": 123456,
                        "comment": f"Test {action} market order with alternative symbol",
                        "type_time": mt5.ORDER_TIME_GTC,
                        "type_filling": mt5.ORDER_FILLING_FOK,
                    }
                    
                    # Execute market order for alternative symbol
                    alt_result = mt5.order_send(alt_request)
                    
                    # Check result
                    if alt_result is None:
                        print(f"❌ Market order with alternative symbol failed completely")
                        print(f"Error description: {mt5.last_error()}")
                    elif alt_result.retcode != mt5.TRADE_RETCODE_DONE:
                        print(f"❌ Market order with alternative symbol failed, retcode: {alt_result.retcode}")
                        print(f"Error description: {mt5.last_error()}")
                    else:
                        print(f"✅ Market order with alternative symbol successful: {action.upper()} at {alt_entry_price}")
    
    # Gracefully disconnect
    mt5.shutdown()

def main():
    parser = argparse.ArgumentParser(description='Test MT5 trading with different approaches')
    parser.add_argument('symbol', help='Trading symbol (e.g., XAUUSD.s)')
    parser.add_argument('action', choices=['buy', 'sell'], help='Trade action')
    parser.add_argument('--volume', type=float, default=0.01, help='Trading volume (default: 0.01)')
    
    args = parser.parse_args()
    
    print(f"Testing {args.action.upper()} trade for {args.symbol}")
    test_trade(args.symbol, args.action, args.volume)

if __name__ == "__main__":
    main() 