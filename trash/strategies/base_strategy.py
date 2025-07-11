from abc import ABC, abstractmethod
import pandas as pd
import MetaTrader5 as mt5  # Import for constants and types

class BaseStrategy(ABC):
    """
    Abstract Base Class for all trading strategies.
    
    This class defines the common interface and shared functionality for trading strategies.
    Concrete strategy implementations should inherit from this class.
    """

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
        self.data = pd.DataFrame()  # To store historical data and indicators
        self.prev_signal = None     # For tracking previous trade direction
    
    def get_point_value(self):
        """
        Get the symbol's point value from MT5.
        
        The point value is crucial for proper calculation of stop levels,
        position sizing, and price movements.
        
        Returns:
            float: The point value for the symbol
            
        Raises:
            ValueError: If the point value cannot be determined
        """
        # First try to get point directly from symbol_info
        if hasattr(self.symbol_info, 'point') and self.symbol_info.point > 0:
            return self.symbol_info.point
            
        # Alternative way to get point value
        elif hasattr(self.symbol_info, 'trade_tick_size') and self.symbol_info.trade_tick_size > 0:
            return self.symbol_info.trade_tick_size
            
        # If we can't get a valid point value, we should raise an error
        # This is a critical value for trading calculations and we can't guess
        raise ValueError(
            f"Cannot determine point value for symbol {self.symbol}. "
            f"Symbol info lacks 'point' attribute or has invalid value. "
            f"Make sure the symbol is correctly specified and MT5 connection is valid."
        )

    def get_digits(self):
        """
        Get the number of decimal digits for the symbol from MT5.
        
        This is used for proper price rounding in orders.
        
        Returns:
            int: Number of decimal digits
            
        Raises:
            ValueError: If the digits value cannot be determined
        """
        if hasattr(self.symbol_info, 'digits'):
            return self.symbol_info.digits
            
        # If we can't get a valid digits value, raise an error
        raise ValueError(
            f"Cannot determine decimal digits for symbol {self.symbol}. "
            f"Symbol info lacks 'digits' attribute. "
            f"Make sure the symbol is correctly specified and MT5 connection is valid."
        )

    def update_data(self, new_data):
        """
        Updates the strategy's internal data cache. Can be overridden for complex merging.
        Default implementation replaces the data.
        
        Args:
            new_data (DataFrame): New price and indicator data
        """
        if new_data is not None and not new_data.empty:
            self.data = new_data.copy()
            #print(f"Strategy data updated. Last candle time: {self.data.index[-1]}")
    
    def get_market_price(self, order_type):
        """
        Get the appropriate market price for a given order type.
        
        Args:
            order_type (int): MT5 order type constant
            
        Returns:
            float: The appropriate price for the order type
        """
        # Check if bid/ask in dataframe (for backtesting support)
        if not self.data.empty:
            if order_type == mt5.ORDER_TYPE_BUY and 'ask' in self.data.columns:
                return self.data['ask'].iloc[-1]
            elif order_type == mt5.ORDER_TYPE_SELL and 'bid' in self.data.columns:
                return self.data['bid'].iloc[-1]
            else:
                # Fallback to close price with warning
                price = self.data['close'].iloc[-1]
                direction = "BUY" if order_type == mt5.ORDER_TYPE_BUY else "SELL"
                print(f"⚠️ Warning: Using close price instead of {'ask' if order_type == mt5.ORDER_TYPE_BUY else 'bid'} price for {direction} order")
                return price
        
        # Default fallback (should not reach here normally)
        return None

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
        
        Returns:
            int: The minimum number of candles required
        """
        return 50  # Default minimum reasonable buffer

    def get_config(self, key, default=None):
        """
        Helper to get strategy-specific config values.
        
        Args:
            key (str): Configuration key
            default: Default value if key not found
            
        Returns:
            The configuration value or default
        """
        return self.config.get(key, default)
    
    def reset_signal_state(self):
        """Reset strategy internal state after position closing or failed orders."""
        self.prev_signal = None 