from abc import ABC, abstractmethod
import pandas as pd

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