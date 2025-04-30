import MetaTrader5 as mt5
import pandas as pd
import numpy as np
import time
import argparse
import importlib
from abc import ABC, abstractmethod
from datetime import datetime, timedelta
import pytz # Added for timezone handling

# ===== Configuration Constants =====

# Account Configuration (Example - Should be secured)
ACCOUNT_CONFIG = {
    'LOGIN': 797241,
    'PASSWORD': "rZ#PWM!5",
    'SERVER': "PUPrime-Demo"
}


# Core Trader Configuration
CORE_CONFIG = {
    'TIMEFRAME': mt5.TIMEFRAME_M1,
    'LOOP_SLEEP_SECONDS': 0.1,
    'DATA_FETCH_COUNT': 150, # Candles to fetch for analysis + buffer
    'FAST_EMA': 2,  # Period for TEMA calculation (added for DataFetcher)
    'SLOW_EMA': 8   # Period for regular EMA (added for DataFetcher)
}

# Risk Management Configuration
RISK_CONFIG = {
    'DEFAULT_RISK_PERCENTAGE': 0.01,  # Default 1% risk per trade
    'MAGIC_NUMBER': 234000,
    'DEVIATION': 20,  # Price deviation allowed for market orders
    'DEFAULT_TP_RATIO': 1.0 # Default Take Profit / Stop Loss ratio
}

# Position Management Configuration (Can be overridden by strategy)
POSITION_CONFIG = {
    'MIN_POSITION_AGE_MINUTES': 2,      # Minimum position age for management checks
    'WAIT_CANDLES_AFTER_CLOSE': 3      # Candles to wait before entering new trade after closing one
}

# --- Indicator Calculation Class ---
class IndicatorCalculator:
    """Provides static methods for calculating technical indicators."""

    @staticmethod
    def calculate_tema(prices, period):
        """Calculate Triple Exponential Moving Average"""
        if prices.isnull().all() or len(prices) < period:
            return pd.Series(index=prices.index, dtype='float64')
        ema1 = prices.ewm(span=period, adjust=False).mean()
        ema2 = ema1.ewm(span=period, adjust=False).mean()
        ema3 = ema2.ewm(span=period, adjust=False).mean()
        tema = (3 * ema1) - (3 * ema2) + ema3
        return tema

    @staticmethod
    def calculate_regular_ema(prices, period):
        """Calculate standard Exponential Moving Average"""
        if prices.isnull().all() or len(prices) < period:
            return pd.Series(index=prices.index, dtype='float64')
        return prices.ewm(span=period, adjust=False).mean()

    @staticmethod
    def calculate_rsi(prices, period=14):
        """Calculate Relative Strength Index (RSI)"""
        if prices.isnull().all() or len(prices) < period:
            return pd.Series(index=prices.index, dtype='float64')

        delta = prices.diff()
        gain = (delta.where(delta > 0, 0)).fillna(0)
        loss = (-delta.where(delta < 0, 0)).fillna(0)

        avg_gain = gain.ewm(com=period - 1, min_periods=period, adjust=False).mean()
        avg_loss = loss.ewm(com=period - 1, min_periods=period, adjust=False).mean()

        rs = avg_gain / avg_loss
        rsi = 100 - (100 / (1 + rs))

        # Handle potential division by zero if avg_loss is 0
        rsi = rsi.replace([np.inf, -np.inf], 100).fillna(50) # Treat 0 loss as max strength (RSI 100), fill initial NaNs with 50

        return rsi

    @staticmethod
    def calculate_macd(prices, fast_period=12, slow_period=26, signal_period=9):
        """Calculate Moving Average Convergence Divergence (MACD)"""
        if prices.isnull().all() or len(prices) < slow_period:
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

    # --- Add more indicator methods here (e.g., MACD, Bollinger Bands) ---

# Indicator Configuration (Used by DataFetcher)
INDICATOR_CONFIG = [
    {
        'name': 'fast_ema', # Column name in DataFrame
        'function': IndicatorCalculator.calculate_tema,
        'params': {'period': CORE_CONFIG['FAST_EMA']}, # Parameters for the function
        'input_col': 'close' # Input column from DataFrame
    },
    {
        'name': 'slow_ema',
        'function': IndicatorCalculator.calculate_regular_ema,
        'params': {'period': CORE_CONFIG['SLOW_EMA']},
        'input_col': 'close'
    },
    {
        'name': 'rsi',
        'function': IndicatorCalculator.calculate_rsi,
        'params': {'period': 14}, # Example RSI period
        'input_col': 'close'
    },
    {
        # Note: This entry defines multiple output columns
        'name': 'macd_data', # A base name, actual columns defined in output_cols
        'function': IndicatorCalculator.calculate_macd,
        'params': {'fast_period': 12, 'slow_period': 26, 'signal_period': 9}, # Standard MACD periods
        'input_col': 'close',
        'output_cols': ['macd', 'macd_signal', 'macd_hist'] # Function returns these columns
    },
    # --- Add more indicators here ---
]

# --- Helper Functions ---

def get_server_time():
    """Gets the current server time based on broker settings."""
    server_info = ACCOUNT_CONFIG.get('SERVER', '')
    server_offset_hours = 3 # Default GMT+3

    # Example specific logic for PU Prime (adjust as needed for other brokers)
    if "PUPrime" in server_info:
        current_month = datetime.now().month
        server_offset_hours = 3 if 4 <= current_month <= 10 else 2 # DST/Standard time

    try:
        # Use timezone-aware UTC time and add offset
        server_time = datetime.now(pytz.UTC) + timedelta(hours=server_offset_hours)
        # Make it naive for easier comparison with MT5 times if necessary,
        # but keeping TZ is generally better. Let's return TZ-aware.
        return server_time
    except Exception as e:
        print(f"Error getting server time: {e}. Falling back to naive UTC+offset.")
        # Fallback to naive UTC time + offset
        return datetime.utcnow() + timedelta(hours=server_offset_hours)

def get_timeframe_minutes(timeframe):
    """Convert MT5 timeframe constant to minutes."""
    timeframe_map = {
        mt5.TIMEFRAME_M1: 1, mt5.TIMEFRAME_M5: 5, mt5.TIMEFRAME_M15: 15,
        mt5.TIMEFRAME_M30: 30, mt5.TIMEFRAME_H1: 60, mt5.TIMEFRAME_H4: 240,
        mt5.TIMEFRAME_D1: 1440, mt5.TIMEFRAME_W1: 10080, mt5.TIMEFRAME_MN1: 43200,
    }
    return timeframe_map.get(timeframe, 1) # Default to 1 min

def get_candle_boundaries(timestamp, timeframe):
    """Calculate the start and end time of the candle containing the timestamp."""
    try:
        dt = timestamp
        if isinstance(timestamp, str):
            dt = datetime.fromisoformat(timestamp)

        # Ensure dt is timezone-aware (assume UTC if naive, adjust as needed)
        if dt.tzinfo is None or dt.tzinfo.utcoffset(dt) is None:
             dt = pytz.UTC.localize(dt) # Or use the broker's timezone if known

        timeframe_minutes = get_timeframe_minutes(timeframe)
        seconds_per_candle = timeframe_minutes * 60
        timestamp_value = int(dt.timestamp())

        candle_start_ts = (timestamp_value // seconds_per_candle) * seconds_per_candle
        candle_end_ts = candle_start_ts + seconds_per_candle

        # Return timezone-aware datetime objects
        candle_start = datetime.fromtimestamp(candle_start_ts, tz=pytz.UTC)
        candle_end = datetime.fromtimestamp(candle_end_ts, tz=pytz.UTC)

        return candle_start, candle_end

    except Exception as e:
        print(f"Error in get_candle_boundaries: {e}")
        raise ValueError(f"Invalid timestamp or timeframe: {timestamp} ({type(timestamp)}), {timeframe}")


# --- Core Classes ---

class MT5Helper:
    """Helper class for MT5 connection and basic operations."""
    @staticmethod
    def initialize_mt5():
        if not mt5.initialize(login=ACCOUNT_CONFIG['LOGIN'],
                             password=ACCOUNT_CONFIG['PASSWORD'],
                             server=ACCOUNT_CONFIG['SERVER']):
            print("❌ MT5 Initialization failed:", mt5.last_error())
            return False
        print("✅ MT5 Initialized successfully.")
        return True

    @staticmethod
    def check_autotrading_enabled():
        terminal_info = mt5.terminal_info()
        if terminal_info is None or not terminal_info.trade_allowed:
            print("❌ ERROR: AutoTrading is disabled in MT5 terminal!")
            return False
        print("✅ AutoTrading is enabled.")
        return True

    @staticmethod
    def get_account_info():
        account = mt5.account_info()
        if account is None:
            print("❌ Failed to get account info:", mt5.last_error())
        return account

    @staticmethod
    def is_trade_successful(result):
        # MT5 success codes for placing/closing orders/deals.
        # Code 10009: Request completed.
        # Code 10008: Request executing. (Sometimes returned on success)
        # Code 10027: Market order closed by stop loss.
        # Check last_error as well for robustness.
        success = (result is not None and
                   result.retcode in [mt5.TRADE_RETCODE_DONE, mt5.TRADE_RETCODE_PLACED, 10008, 10027] and
                   (result.deal > 0 or result.order > 0)) # Deal for market orders, order for pending/SL/TP mods
        if not success:
             # Sometimes the retcode is misleading, check last_error
             last_err_code, last_err_msg = mt5.last_error()
             if last_err_code == 1: # Error code 1 often means "Success" or "No error"
                 success = (result is not None and (result.deal > 0 or result.order > 0))

        return success


    @staticmethod
    def is_modification_successful(result):
         # Similar check for modification results (SL/TP)
         success = (result is not None and
                    result.retcode in [mt5.TRADE_RETCODE_DONE, mt5.TRADE_RETCODE_PLACED, 10008])
         if not success:
              last_err_code, last_err_msg = mt5.last_error()
              if last_err_code == 1:
                  success = True # Modification likely succeeded even if retcode isn't perfect
         return success


    @staticmethod
    def get_open_positions(symbol=None, magic=None):
        if magic is None:
            magic = RISK_CONFIG['MAGIC_NUMBER'] # Default to our magic number

        try:
            if symbol:
                positions = mt5.positions_get(symbol=symbol)
            else:
                positions = mt5.positions_get()

            if positions is None:
                #print(f"Could not get positions: {mt5.last_error()}")
                return [] # Return empty list on failure

            # Filter by magic number
            return [p for p in positions if p.magic == magic]
        except Exception as e:
            print(f"Exception getting positions: {e}")
            return []


    @staticmethod
    def shutdown():
        print("🔌 Shutting down MT5 connection.")
        mt5.shutdown()

class DataFetcher:
    """Handles data retrieval from MT5 and adds configured indicators."""

    @staticmethod
    def get_historical_data(symbol, timeframe, count):
        try:
            rates = mt5.copy_rates_from_pos(symbol, timeframe, 0, count)
            if rates is None or len(rates) == 0:
                print(f"❌ Failed to get historical data for {symbol} ({timeframe}): {mt5.last_error()}")
                return None

            df = pd.DataFrame(rates)
            # Convert MT5 timestamp (seconds since epoch) to datetime objects (UTC)
            df['time'] = pd.to_datetime(df['time'], unit='s', utc=True)
            df.set_index('time', inplace=True) # Set time as index for easier slicing

            # Dynamically calculate and add indicators based on config
            if not df.empty:
                for indicator_conf in INDICATOR_CONFIG:
                    input_col_name = indicator_conf.get('input_col', 'close') # Default to 'close'
                    output_col_name = indicator_conf['name']
                    calc_function = indicator_conf['function']
                    params = indicator_conf.get('params', {})
                    output_cols = indicator_conf.get('output_cols') # Check for multiple output cols

                    if input_col_name in df.columns:
                        input_series = df[input_col_name]
                        try:
                            # Pass the input series and other params to the function
                            if output_cols:
                                # Function returns a DataFrame with multiple columns
                                indicator_df = calc_function(input_series, **params)
                                # Merge the results into the main DataFrame
                                df = df.join(indicator_df, how='left')
                                #print(f"Calculated multi-indicator: {output_cols}")
                            else:
                                # Function returns a single Series
                                df[output_col_name] = calc_function(input_series, **params)
                                #print(f"Calculated indicator: {output_col_name}")
                        except Exception as e:
                            print(f"❌ Error calculating indicator '{output_col_name}': {e}")
                            # Add NaN column(s) on error
                            if output_cols:
                                for col in output_cols:
                                    df[col] = np.nan
                            else:
                                df[output_col_name] = np.nan
                    else:
                        print(f"⚠️ Input column '{input_col_name}' not found for indicator '{output_col_name}'. Skipping.")
                        # Ensure all expected output columns exist, even if NaN
                        if output_cols:
                            for col in output_cols:
                                df[col] = np.nan
                        else:
                            df[output_col_name] = np.nan
            else:
                 print("⚠️ DataFrame is empty, cannot calculate indicators.")


            return df
        except Exception as e:
            print(f"Exception in get_historical_data: {e}")
            return None

    @staticmethod
    def get_current_price(symbol, price_type="both"):
        tick = mt5.symbol_info_tick(symbol)
        if tick is None:
            print(f"❌ Failed to get tick for {symbol}: {mt5.last_error()}")
            return None if price_type == "both" else None
        if price_type == "bid":
            return tick.bid
        elif price_type == "ask":
            return tick.ask
        else:
            return (tick.bid, tick.ask)

    @staticmethod
    def get_symbol_info(symbol):
        symbol_info = mt5.symbol_info(symbol)
        if symbol_info is None:
            print(f"❌ Failed to get symbol info for {symbol}: {mt5.last_error()}")
        return symbol_info

class RiskManager:
    """Handles position sizing and risk calculations."""
    @staticmethod
    def calculate_position_size(symbol_info, account_balance, risk_percentage, entry_price, stop_loss_price):
        """Calculates position size based on risk % and stop loss distance."""
        if stop_loss_price == entry_price: # Avoid division by zero
             print("⚠️ Entry price equals stop loss price. Cannot calculate position size.")
             return symbol_info.volume_min

        risk_amount = account_balance * risk_percentage
        price_risk_per_contract = abs(entry_price - stop_loss_price) * symbol_info.trade_contract_size
        tick_value = symbol_info.tick_value
        tick_size = symbol_info.tick_size

        # Calculate risk in account currency
        # price_risk_per_contract is in quote currency. We need to convert it to deposit currency.
        # This depends on the symbol (e.g., EURUSD vs USDJPY)
        # A simpler (though less precise for non-USD accounts/crosses) approach:
        if price_risk_per_contract == 0:
             print("⚠️ Price risk is zero. Cannot calculate position size.")
             return symbol_info.volume_min

        # Simpler calculation assuming pip value is relatively constant near entry
        # More accurate calculation would involve currency conversion rates if needed
        # Let's use the price_risk * contract_size directly if symbol currency matches account currency
        # This needs improvement for multi-currency environments.
        # For now, assume account currency matches quote currency or base currency value adjustment is simple.

        position_size = risk_amount / price_risk_per_contract
        # If tick_value is available and makes sense, use it (more accurate for non-forex):
        # Example: If tick_value represents profit per tick per lot:
        # points_risk = abs(entry_price - stop_loss_price) / symbol_info.point
        # risk_per_lot = points_risk * tick_value * (1/tick_size) # Need to verify this formula based on broker specifics
        # if risk_per_lot > 0:
        #    position_size = risk_amount / risk_per_lot


        # Ensure volume step and limits
        if symbol_info.volume_step == 0: # Avoid division by zero if step is invalid
            rounded_size = round(position_size, 8) # Use reasonable precision
        else:
            rounded_size = round(position_size / symbol_info.volume_step) * symbol_info.volume_step

        final_size = max(min(rounded_size, symbol_info.volume_max), symbol_info.volume_min)

        # Prevent minuscule sizes very close to zero after rounding
        if final_size < symbol_info.volume_min:
             final_size = symbol_info.volume_min

        if final_size > symbol_info.volume_max:
             final_size = symbol_info.volume_max


        #print(f"Risk Amount: {risk_amount:.2f}, Price Risk: {abs(entry_price - stop_loss_price)}, Price Risk Per Contract: {price_risk_per_contract}")
        #print(f"Calculated Size: {position_size:.4f}, Rounded Size: {rounded_size:.4f}, Final Size: {final_size:.4f}")

        return final_size


class TradeExecutor:
    """Handles trade execution and position management."""
    @staticmethod
    def execute_trade(symbol, trade_action, volume, price, sl_price, tp_price, magic_number, deviation):
        """Executes a market order with SL and TP."""
        order_type = mt5.ORDER_TYPE_BUY if trade_action == mt5.ORDER_TYPE_BUY else mt5.ORDER_TYPE_SELL
        request = {
            "action": mt5.TRADE_ACTION_DEAL,
            "symbol": symbol,
            "volume": float(volume),
            "type": order_type,
            "price": price,
            "sl": float(sl_price) if sl_price is not None else 0.0,
            "tp": float(tp_price) if tp_price is not None else 0.0,
            "deviation": deviation,
            "magic": magic_number,
            "comment": "Generic Trader Execution",
            "type_time": mt5.ORDER_TIME_GTC,
            "type_filling": mt5.ORDER_FILLING_FOK, # Or IOC - FOK preferred for market orders with SL/TP
        }

        print(f"▶️ Sending {('BUY' if order_type == mt5.ORDER_TYPE_BUY else 'SELL')} Order: Vol={volume}, Price={price}, SL={sl_price}, TP={tp_price}")
        result = mt5.order_send(request)

        if result is None:
            print(f"❌ Order Send Failed (None result): {mt5.last_error()}")
            return None
        elif MT5Helper.is_trade_successful(result):
            print(f"✅ Order Sent Successfully: Deal={result.deal}, Order={result.order}, Retcode={result.retcode}")
            return result.deal # Return deal ticket if successful
        else:
            print(f"❌ Order Send Failed: Retcode={result.retcode}, Comment={result.comment}, Error={mt5.last_error()}")
            return None

    @staticmethod
    def close_position(position, deviation):
        """Closes a specific open position."""
        symbol = position.symbol
        volume = position.volume
        ticket = position.ticket
        position_type = position.type # 0 for Buy, 1 for Sell
        magic = position.magic

        close_order_type = mt5.ORDER_TYPE_SELL if position_type == mt5.POSITION_TYPE_BUY else mt5.ORDER_TYPE_BUY
        price_type = "bid" if position_type == mt5.POSITION_TYPE_BUY else "ask" # Price to close at
        price = DataFetcher.get_current_price(symbol, price_type)

        if price is None:
            print(f"❌ Cannot close position {ticket}, failed to get price for {symbol}")
            return False

        request = {
            "action": mt5.TRADE_ACTION_DEAL,
            "symbol": symbol,
            "volume": volume,
            "type": close_order_type,
            "position": ticket,
            "price": price,
            "deviation": deviation,
            "magic": magic, # Use position's magic number
            "comment": "Generic Trader Close",
            "type_time": mt5.ORDER_TIME_GTC,
            "type_filling": mt5.ORDER_FILLING_IOC,
        }

        print(f"▶️ Sending Close Order for Position {ticket} ({('BUY' if position_type == mt5.POSITION_TYPE_BUY else 'SELL')} at {price})")
        result = mt5.order_send(request)

        if result is None:
            print(f"❌ Close Order Failed (None result) for {ticket}: {mt5.last_error()}")
            return False
        elif MT5Helper.is_trade_successful(result):
            print(f"✅ Position {ticket} Closed Successfully: Deal={result.deal}, Retcode={result.retcode}")
            return True
        else:
            print(f"❌ Close Order Failed for {ticket}: Retcode={result.retcode}, Comment={result.comment}, Error={mt5.last_error()}")
            # Consider retrying or logging persistence issues
            return False

    @staticmethod
    def close_all_symbol_positions(symbol, magic_number):
        """Closes all open positions for a specific symbol and magic number."""
        positions = MT5Helper.get_open_positions(symbol, magic_number)
        if not positions:
            #print(f"No open positions found for {symbol} with magic {magic_number} to close.")
            return True # No positions is success in this context

        print(f"Attempting to close {len(positions)} positions for {symbol} (Magic: {magic_number})...")
        all_closed = True
        for position in positions:
            if not TradeExecutor.close_position(position, RISK_CONFIG['DEVIATION']):
                all_closed = False
                print(f"⚠️ Failed to close position {position.ticket}.")
                # Decide if you want to stop or continue closing others
        if all_closed:
            print(f"✅ All positions for {symbol} closed.")
        else:
            print(f"⚠️ Some positions for {symbol} may not have closed.")
        return all_closed


# --- Strategy Interface ---

class BaseStrategy(ABC):
    """Abstract Base Class for all trading strategies."""

    def __init__(self, symbol, timeframe, symbol_info, strategy_config=None):
        """
        Initialize the strategy.

        Args:
            symbol (str): The trading symbol.
            timeframe (int): The MT5 timeframe constant.
            symbol_info (mt5.SymbolInfo): MT5 symbol information object.
            strategy_config (dict, optional): Strategy-specific configuration. Defaults to None.
        """
        self.symbol = symbol
        self.timeframe = timeframe
        self.symbol_info = symbol_info
        self.config = strategy_config or {}
        self.data = pd.DataFrame() # To store historical data and indicators

    def update_data(self, new_data):
        """
        Updates the strategy's internal data cache. Can be overridden for complex merging.
        Default implementation replaces the data.
        """
        if new_data is not None and not new_data.empty:
            self.data = new_data.copy()
            #print(f"Strategy data updated. Last candle time: {self.data.index[-1]}")


    @abstractmethod
    def calculate_indicators(self):
        """
        Calculate necessary indicators and store them in self.data.
        This method should modify self.data inplace.
        """
        pass

    @abstractmethod
    def generate_entry_signal(self):
        """
        Checks the latest data and indicators to generate an entry signal.

        Returns:
            tuple or None: (signal_type, entry_price, stop_loss_price, take_profit_price) or None
            signal_type (int): mt5.ORDER_TYPE_BUY or mt5.ORDER_TYPE_SELL
            entry_price (float): Suggested entry price (e.g., current ask/bid).
            stop_loss_price (float): Calculated stop loss price.
            take_profit_price (float): Calculated take profit price.
            Returns None if no entry signal.
        """
        pass

    @abstractmethod
    def generate_exit_signal(self, position):
        """
        Checks the latest data and indicators to see if an existing position should be closed.

        Args:
            position (mt5.PositionInfo): The open position object to evaluate.

        Returns:
            bool: True if the position should be closed, False otherwise.
        """
        pass

    def get_required_data_count(self):
        """
        Returns the minimum number of historical data points needed by the strategy.
        Should be overridden by subclasses if they need more than a default small buffer.
        """
        return 50 # Default minimum reasonable buffer

    def get_config(self, key, default=None):
        """Helper to get strategy-specific config values."""
        return self.config.get(key, default)

# --- Main Execution ---

def parse_arguments():
    """Parse command line arguments."""
    parser = argparse.ArgumentParser(description='Generic MT5 Trading Bot')
    parser.add_argument('symbol', help='Trading symbol (e.g., XAUUSD.s)')
    parser.add_argument('--strategy', default='strategies.ema_strategy.EMAStrategy',
                       help='Python path to the strategy class (e.g., strategies.my_strategy.MyStrategy)')
    parser.add_argument('--risk', type=float, default=RISK_CONFIG['DEFAULT_RISK_PERCENTAGE'] * 100.0,
                       help=f'Risk percentage per trade (default: {RISK_CONFIG["DEFAULT_RISK_PERCENTAGE"] * 100.0})')
    # Add more arguments as needed (e.g., config file path)
    return parser.parse_args()

def load_strategy_class(strategy_path):
    """Dynamically loads the strategy class from the given path."""
    try:
        module_path, class_name = strategy_path.rsplit('.', 1)
        module = importlib.import_module(module_path)
        strategy_class = getattr(module, class_name)
        if not issubclass(strategy_class, BaseStrategy):
            raise TypeError(f"{strategy_path} is not a subclass of BaseStrategy")
        return strategy_class
    except (ImportError, AttributeError, ValueError, TypeError) as e:
        print(f"❌ Error loading strategy '{strategy_path}': {e}")
        return None

def main():
    """Main trading loop."""
    args = parse_arguments()
    risk_percentage = args.risk / 100.0 # Convert percentage to decimal

    if not MT5Helper.initialize_mt5(): return
    if not MT5Helper.check_autotrading_enabled(): MT5Helper.shutdown(); return

    account_info = MT5Helper.get_account_info()
    if not account_info: MT5Helper.shutdown(); return

    symbol_info = DataFetcher.get_symbol_info(args.symbol)
    if not symbol_info: MT5Helper.shutdown(); return

    # --- Strategy Loading ---
    StrategyClass = load_strategy_class(args.strategy)
    if StrategyClass is None: MT5Helper.shutdown(); return

    # TODO: Load strategy-specific config from file or args if needed
    strategy_config = {} # Example: Load from json file based on strategy name/args
    strategy = StrategyClass(args.symbol, CORE_CONFIG['TIMEFRAME'], symbol_info, strategy_config)
    print(f"📈 Strategy Loaded: {args.strategy}")
    print(f"💰 Risk Per Trade: {args.risk}% | Initial Balance: ${account_info.balance:.2f}")
    print(f" S Symbol: {args.symbol} | Timeframe: {CORE_CONFIG['TIMEFRAME']}") # Add timeframe name later

    # --- State Variables ---
    last_data_fetch_time = None
    timeframe_seconds = get_timeframe_minutes(CORE_CONFIG['TIMEFRAME']) * 60
    required_data_count = max(CORE_CONFIG['DATA_FETCH_COUNT'], strategy.get_required_data_count())
    candles_since_last_close = 0
    waiting_after_close = False

    print("🤖 Bot running... Press Ctrl+C to stop")
    try:
        while True:
            current_time = get_server_time()
            # --- Data Fetching & Indicator Calculation ---
            # Fetch data roughly once per timeframe or if not fetched recently
            should_fetch = (last_data_fetch_time is None or
                            (current_time - last_data_fetch_time).total_seconds() >= timeframe_seconds / 2) # Fetch mid-candle too

            if should_fetch:
                #print(f"Fetching data at {current_time}...")
                df = DataFetcher.get_historical_data(args.symbol, CORE_CONFIG['TIMEFRAME'], required_data_count)
                if df is not None and not df.empty:
                    strategy.update_data(df)
                    strategy.calculate_indicators()
                    last_data_fetch_time = current_time
                    #print(f"Indicators calculated. Last data point: {strategy.data.index[-1]}")

                    # Update candle count after closing position
                    if waiting_after_close:
                         candles_since_last_close += 1
                         print(f"⏳ Waiting period: {candles_since_last_close}/{POSITION_CONFIG['WAIT_CANDLES_AFTER_CLOSE']} candles passed since close.")
                         if candles_since_last_close >= POSITION_CONFIG['WAIT_CANDLES_AFTER_CLOSE']:
                             print("✅ Waiting period finished.")
                             waiting_after_close = False
                             candles_since_last_close = 0

                else:
                    print("⚠️ Failed to fetch or update data, skipping cycle.")
                    time.sleep(CORE_CONFIG['LOOP_SLEEP_SECONDS'] * 10) # Longer sleep on data error
                    continue # Skip rest of the loop if data is bad

            # --- Position Management ---
            open_positions = MT5Helper.get_open_positions(args.symbol) # Filtered by magic number
            account_info = MT5Helper.get_account_info() # Update balance info
            if not account_info:
                print("⚠️ Could not get account info, skipping cycle.")
                time.sleep(CORE_CONFIG['LOOP_SLEEP_SECONDS'] * 5)
                continue

            position_closed_this_cycle = False
            if open_positions:
                #print(f"Managing {len(open_positions)} open position(s)...")
                for pos in open_positions:
                    # Check if strategy wants to exit this position
                    if strategy.generate_exit_signal(pos):
                        print(f"🚪 Strategy generated exit signal for position {pos.ticket}.")
                        if TradeExecutor.close_position(pos, RISK_CONFIG['DEVIATION']):
                            position_closed_this_cycle = True
                            # Reset waiting period if we closed a position
                            waiting_after_close = True
                            candles_since_last_close = 0
                            print(f"⏳ Waiting period activated ({POSITION_CONFIG['WAIT_CANDLES_AFTER_CLOSE']} candles).")
                        else:
                            print(f"⚠️ Failed to close position {pos.ticket} on exit signal.")
                            # Decide on error handling: retry? stop? log?

            # --- Entry Signal Check ---
            # Only check for entries if no positions are open (or strategy allows multiple)
            # and not in the waiting period after a close.
            open_positions = MT5Helper.get_open_positions(args.symbol) # Re-check after potential closes
            if not open_positions and not waiting_after_close:
                 #print("Checking for entry signals...")
                 entry_signal = strategy.generate_entry_signal()
                 if entry_signal:
                     signal_type, entry_price, sl_price, tp_price = entry_signal
                     trade_action = signal_type # Should be mt5.ORDER_TYPE_BUY or mt5.ORDER_TYPE_SELL

                     # Ensure prices are valid floats
                     if not all(isinstance(p, (int, float)) for p in [entry_price, sl_price, tp_price] if p is not None):
                          print(f"⚠️ Invalid prices received from strategy: Entry={entry_price}, SL={sl_price}, TP={tp_price}")
                          continue

                     # Round prices to symbol digits
                     digits = symbol_info.digits
                     sl_price = round(sl_price, digits) if sl_price is not None else None
                     tp_price = round(tp_price, digits) if tp_price is not None else None
                     entry_price = round(entry_price, digits) # Adjust entry based on type later if needed

                     if sl_price is None:
                         print("⚠️ Strategy provided entry signal without Stop Loss. Skipping trade.")
                         continue # Require SL for risk management

                     # Calculate volume
                     volume = RiskManager.calculate_position_size(
                         symbol_info, account_info.balance, risk_percentage, entry_price, sl_price
                     )

                     if volume < symbol_info.volume_min:
                         print(f"⚠️ Calculated volume {volume} is below minimum {symbol_info.volume_min}. Skipping trade.")
                         continue

                     print(f"🎯 Entry Signal Received: {'BUY' if trade_action == mt5.ORDER_TYPE_BUY else 'SELL'}")
                     print(f"   Entry={entry_price}, SL={sl_price}, TP={tp_price}, Vol={volume}")

                     # Execute Trade
                     deal_ticket = TradeExecutor.execute_trade(
                         args.symbol, trade_action, volume, entry_price, sl_price, tp_price,
                         RISK_CONFIG['MAGIC_NUMBER'], RISK_CONFIG['DEVIATION']
                     )
                     if deal_ticket:
                         print(f"✅ Trade Executed. Deal Ticket: {deal_ticket}")
                         # Optional: Add delay or confirmation check
                     else:
                         print(f"❌ Trade Execution Failed.")
                         # Optional: Log error, maybe retry later


            # --- Loop Sleep ---
            time.sleep(CORE_CONFIG['LOOP_SLEEP_SECONDS'])

    except KeyboardInterrupt:
        print("🛑 Bot stopped by user.")
    except Exception as e:
        print(f"💥 UNHANDLED EXCEPTION: {e}")
        import traceback
        traceback.print_exc()
    finally:
        print("Performing final cleanup...")
        # Optional: Try to close any remaining open positions managed by this bot instance
        TradeExecutor.close_all_symbol_positions(args.symbol, RISK_CONFIG['MAGIC_NUMBER'])
        MT5Helper.shutdown()
        print("Cleanup finished. Exiting.")


if __name__ == "__main__":
    main() 