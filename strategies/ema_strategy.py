import MetaTrader5 as mt5
import numpy as np
from strategies.base_strategy import BaseStrategy
import importlib
import sys

# Add parent directory to path to import get_candle_boundaries
sys.path.append('..')
# Try to import from the parent module
try:
    from generic_trader import get_candle_boundaries, get_server_time
except ImportError:
    # If import fails, raise the error
    raise

# Signal Filter Parameters (from ema_crossover_strategy.py)
SIGNAL_FILTERS = {
    'MIN_CROSSOVER_POINTS': 10,  # Minimum points required for initial crossover
    'MIN_SEPARATION_POINTS': 2,  # Minimum separation after crossover
    'SLOPE_PERIODS': 3,  # Periods to calculate slope over
    'MIN_SLOPE_THRESHOLD': 0.000001,  # Minimum slope for trend direction
    'MAX_OPPOSITE_SLOPE': -0.000002,  # Maximum allowed opposite slope
    'LOOKBACK_CANDLES': 3,  # Number of recent candles to check for crossover
}

class EMAStrategy(BaseStrategy):
    """Implementation of EMA crossover strategy compatible with generic_trader framework"""
    
    def __init__(self, symbol, timeframe, symbol_info, strategy_config=None):
        """Initialize the strategy with default parameters"""
        super().__init__(symbol, timeframe, symbol_info, strategy_config)
        self.last_trade_close_time = None  # Track when last trade was closed
        
    def calculate_indicators(self):
        """
        The indicators are already calculated in the DataFetcher class in generic_trader.py
        This function is only required by the BaseStrategy interface but doesn't need to do anything.
        """
        pass
        
    def get_required_data_count(self):
        """Return the minimum number of candles needed for this strategy"""
        return 50  # Should be enough for EMA calculation and analysis
    
    def calculate_slope(self, series, periods=SIGNAL_FILTERS['SLOPE_PERIODS']):
        """
        Calculate the slope of a series over specified periods
        
        Args:
            series (Series): Data series to calculate slope for
            periods (int): Number of periods to use
            
        Returns:
            float: The calculated slope value
        """
        if len(series) < periods:
            return 0
        
        y = series[-periods:].values
        x = np.arange(len(y))
        slope, _ = np.polyfit(x, y, 1)
        return slope
    
    def check_slope_conditions(self, direction="BUY"):
        """
        Check if slope conditions are met for the given trade direction
        
        Args:
            direction (str): Trade direction to check for ("BUY" or "SELL")
            
        Returns:
            bool: True if slope conditions are met
        """
        if len(self.data) < SIGNAL_FILTERS['SLOPE_PERIODS']:
            return False
            
        fast_slope = self.calculate_slope(self.data['fast_ema'])
        slow_slope = self.calculate_slope(self.data['slow_ema'])
        
        # Check if EMAs are relatively flat
        is_flat = (abs(fast_slope) < SIGNAL_FILTERS['MIN_SLOPE_THRESHOLD']/2 and 
                  abs(slow_slope) < SIGNAL_FILTERS['MIN_SLOPE_THRESHOLD']/2)
        
        # Relaxed slope conditions for early detection
        if direction == "BUY":
            if is_flat:
                # For flat trends, be more lenient
                slope_ok = fast_slope >= 0 and slow_slope > -SIGNAL_FILTERS['MIN_SLOPE_THRESHOLD']
            else:
                # Relaxed condition - just need fast EMA going up
                slope_ok = fast_slope > 0
            return slope_ok
        else:  # SELL
            if is_flat:
                # For flat trends, be more lenient
                slope_ok = fast_slope <= 0 and slow_slope < SIGNAL_FILTERS['MIN_SLOPE_THRESHOLD']
            else:
                # Relaxed condition - just need fast EMA going down
                slope_ok = fast_slope < 0
            return slope_ok
    
    def check_separation(self, direction="BUY"):
        """
        Check if EMAs have sufficient separation after crossover
        
        Args:
            direction (str): Trade direction to check for ("BUY" or "SELL")
            
        Returns:
            bool: True if EMAs have sufficient separation
        """
        if self.data.empty or len(self.data) < 2:
            return False
            
        current_fast = self.data['fast_ema'].iloc[-1]
        current_slow = self.data['slow_ema'].iloc[-1]
        
        diff = current_fast - current_slow
        point = self.get_point_value()
        diff_points = abs(diff / point)
        
        if direction == "BUY":
            sep_ok = diff > 0 and diff_points >= SIGNAL_FILTERS['MIN_SEPARATION_POINTS']
        else:  # SELL
            sep_ok = diff < 0 and diff_points >= SIGNAL_FILTERS['MIN_SEPARATION_POINTS']
            
        return sep_ok
    
    def check_price_confirmation(self, direction="BUY"):
        """
        Check if price confirms the signal direction
        Relaxed to check only against slow EMA
        
        Args:
            direction (str): Trade direction to check for ("BUY" or "SELL")
            
        Returns:
            bool: True if price confirms signal direction
        """
        if self.data.empty or len(self.data) < 1:
            return False
            
        last_close = self.data['close'].iloc[-1]
        slow_ema = self.data['slow_ema'].iloc[-1]
        
        if direction == "BUY":
            # Relaxed condition: only need to be above the slow EMA for BUY
            price_ok = last_close > slow_ema
        else:  # SELL
            # Relaxed condition: only need to be below the slow EMA for SELL
            price_ok = last_close < slow_ema
            
        return price_ok
    
    def is_time_in_candle(self, time_to_check, candle_time):
        """
        General utility method to check if a time is within a specific candle period
        
        Args:
            time_to_check: The timestamp to check
            candle_time: The timestamp of the candle to check against
            
        Returns:
            bool: True if time_to_check is within the candle that contains candle_time
        """
        if time_to_check is None or candle_time is None:
            return False
            
        try:
            # Get the boundaries of the candle containing candle_time
            candle_start, candle_end = get_candle_boundaries(candle_time, self.timeframe)
            
            # Check if time_to_check falls within these boundaries
            return candle_start <= time_to_check < candle_end
            
        except Exception as e:
            print(f"⚠️ Error in is_time_in_candle: {e}. Assuming times are not in the same candle.")
            return False
    
    def is_last_trade_in_current_candle(self):
        """
        Check if the last trade close time is within the current candle period
        
        Returns:
            bool: True if the last trade was closed in the current candle
        """
        if self.last_trade_close_time is None or self.data.empty:
            return False
            
        # Get the timestamp of the current candle
        current_candle_time = self.data.index[-1]
        
        # Check if last trade close time is in the current candle
        return self.is_time_in_candle(self.last_trade_close_time, current_candle_time)

    def get_candles_after_last_trade(self):
        """
        Identifies candles that formed completely after the last trade was closed.
        
        Returns:
            list: Indices of candles that formed after the last trade close time
        """
        if self.last_trade_close_time is None or self.data.empty:
            # If no previous trade or no data, consider all candles
            return list(range(len(self.data)))
            
        # Get candles that started after the last trade close time
        post_trade_candles = []
        for i in range(len(self.data)):
            candle_time = self.data.index[i]
            candle_start, _ = get_candle_boundaries(candle_time, self.timeframe)
            
            # If candle started after the trade closed, include it
            if candle_start > self.last_trade_close_time:
                post_trade_candles.append(i)
                
        return post_trade_candles
        
    def detect_recent_crossover(self):
        """
        Check if a crossover occurred in the last few candles
        
        Returns:
            tuple: (crossover_detected, signal_type, potential_signal, candles_ago)
            or (False, None, None, None) if no crossover detected
        """
        crossover_detected = False
        signal_type = None
        potential_signal = None
        candles_ago = None
        
        # Check if a crossover happened within the last few candles
        lookback = min(SIGNAL_FILTERS['LOOKBACK_CANDLES'], len(self.data)-1)
        
        for i in range(1, lookback+1):
            idx_fast = self.data['fast_ema'].iloc[-i]
            idx_slow = self.data['slow_ema'].iloc[-i]
            prev_idx_fast = self.data['fast_ema'].iloc[-(i+1)]
            prev_idx_slow = self.data['slow_ema'].iloc[-(i+1)]
            
            # BUY crossover within last few candles
            if prev_idx_fast <= prev_idx_slow and idx_fast > idx_slow:
                crossover_detected = True
                if not self.prev_signal or self.prev_signal == mt5.ORDER_TYPE_SELL:
                    potential_signal = "BUY"
                    signal_type = mt5.ORDER_TYPE_BUY
                    candles_ago = i
                    print(f"\n📊 Recent BUY Crossover detected {i} candles ago")
                    return crossover_detected, signal_type, potential_signal, candles_ago
                    
            # SELL crossover within last few candles
            elif prev_idx_fast >= prev_idx_slow and idx_fast < idx_slow:
                crossover_detected = True
                if not self.prev_signal or self.prev_signal == mt5.ORDER_TYPE_BUY:
                    potential_signal = "SELL"
                    signal_type = mt5.ORDER_TYPE_SELL
                    candles_ago = i
                    print(f"\n📊 Recent SELL Crossover detected {i} candles ago")
                    return crossover_detected, signal_type, potential_signal, candles_ago
                    
        # Check for immediate crossover (most recent candle)
        current_fast = self.data['fast_ema'].iloc[-1]
        current_slow = self.data['slow_ema'].iloc[-1]
        prev_fast = self.data['fast_ema'].iloc[-2]
        prev_slow = self.data['slow_ema'].iloc[-2]
        
        if prev_fast <= prev_slow and current_fast > current_slow:
            crossover_detected = True
            if not self.prev_signal or self.prev_signal == mt5.ORDER_TYPE_SELL:
                potential_signal = "BUY"
                signal_type = mt5.ORDER_TYPE_BUY
                candles_ago = 0
                print(f"\n📊 Analyzing BUY Signal (immediate crossover)")
                
        elif prev_fast >= prev_slow and current_fast < current_slow:
            crossover_detected = True
            if not self.prev_signal or self.prev_signal == mt5.ORDER_TYPE_BUY:
                potential_signal = "SELL"
                signal_type = mt5.ORDER_TYPE_SELL
                candles_ago = 0
                print(f"\n📊 Analyzing SELL Signal (immediate crossover)")
                
        return crossover_detected, signal_type, potential_signal, candles_ago
        
    def generate_entry_signal(self, open_positions=None):
        """
        Checks for EMA crossover entry signals with additional filters.
        Trend-based signals have been removed, now only using crossover signals.
        
        Args:
            open_positions (list, optional): List of currently open positions to check
                                            if previous position was closed by SL/TP.
            
        Returns:
            tuple or None: (signal_type, entry_price, None, None) or None
            The SL/TP will be calculated later based on actual entry price
        """
        if self.data.empty or len(self.data) < 10:  # Need at least 10 candles
            return None
            
        # Check if the previous signal is still valid (detects SL/TP closures)
        if open_positions is not None:
            self.check_if_prev_signal_valid(open_positions)
            
        # Check if last trade close time is in the current candle - if so, skip generating signals
        if self.is_last_trade_in_current_candle():
            print(f"⏳ Waiting for next candle after position close at {self.last_trade_close_time}")
            return None
            
        # Get current EMA values for logging
        current_fast = self.data['fast_ema'].iloc[-1]
        current_slow = self.data['slow_ema'].iloc[-1]
        prev_fast = self.data['fast_ema'].iloc[-2]
        prev_slow = self.data['slow_ema'].iloc[-2]
        point = self.get_point_value()
            
        # Try to detect a recent crossover
        crossover_detected, signal_type, potential_signal, candles_ago = self.detect_recent_crossover()
        
        # If we have a potential signal from crossover, analyze it
        if potential_signal:
            diff_value = current_fast - current_slow
            diff_points = abs(diff_value / point)
            
            # Log current state
            print(f"   Current Candle: Fast EMA = {current_fast:.5f}, Slow EMA = {current_slow:.5f} (Diff: {diff_value:.5f})")
            print(f"   Signal Strength: {diff_points:.1f} points (min required: {SIGNAL_FILTERS['MIN_CROSSOVER_POINTS']})")
            
            # Check conditions specific to signal type
            slope_ok = self.check_slope_conditions(potential_signal)
            price_ok = self.check_price_confirmation(potential_signal)
            
            print(f"Slope: {'✅' if slope_ok else '❌'}, Price: {'✅' if price_ok else '❌'}")
            
            # Validate crossover signal
            if slope_ok and price_ok:
                valid_signal = True
                print(f"\n🚀 VALID {potential_signal} SIGNAL - Crossover with confirming slope and price")
                
                # Get appropriate market price for entry
                entry_price = self.get_market_price(signal_type)
                
                # Store signal type for next cycle
                self.prev_signal = signal_type
                
                # Return signal info - SL/TP will be calculated by TradeExecutor
                return signal_type, entry_price, None, None
        
        return None
    
    def generate_exit_signal(self, position):
        """
        Checks if an existing position should be closed based on EMA crossover logic.
        This will close a position when the EMAs cross in the opposite direction.
        
        Args:
            position (mt5.PositionInfo): The open position object to evaluate
            
        Returns:
            bool: True if the position should be closed, False otherwise
        """
        if self.data.empty or len(self.data) < 2:
            return False
            
        # Get current and previous EMA values
        current_fast = self.data['fast_ema'].iloc[-1]
        current_slow = self.data['slow_ema'].iloc[-1]
        prev_fast = self.data['fast_ema'].iloc[-2]
        prev_slow = self.data['slow_ema'].iloc[-2]
        
        # Check for crossover against our position
        position_type = position.type  # 0 for Buy, 1 for Sell
        
        # Exit BUY position if Fast EMA crosses below Slow EMA
        if position_type == mt5.POSITION_TYPE_BUY and prev_fast >= prev_slow and current_fast < current_slow:
            print(f"⚠️ EXIT SIGNAL: Fast EMA crossed below Slow EMA - Close BUY position")
            return True
            
        # Exit SELL position if Fast EMA crosses above Slow EMA
        if position_type == mt5.POSITION_TYPE_SELL and prev_fast <= prev_slow and current_fast > current_slow:
            print(f"⚠️ EXIT SIGNAL: Fast EMA crossed above Slow EMA - Close SELL position")
            return True
            
        return False
        
    def reset_signal_state(self):
        """
        Reset strategy internal state after position closing or failed orders.
        Also records the timestamp when a position was closed to prevent immediate reentry.
        """
        # Record the time of the position close
        current_server_time = get_server_time()
        
        if not self.data.empty:
            # Use the timestamp of the current candle
            self.last_trade_close_time = current_server_time
            print(f"🕒 Position closed at {self.last_trade_close_time}. Waiting for next candle and new trend formation before new entry.")
        else:
            # If no data available, use server time
            self.last_trade_close_time = current_server_time
            print(f"🕒 Position closed at {self.last_trade_close_time} (server time). Waiting for next candle and new trend formation before new entry.")
            
        # Call the parent class method to reset other state
        super().reset_signal_state()

    def check_if_prev_signal_valid(self, open_positions):
        """
        Checks if the previous signal is still valid by checking if there are open positions.
        If the previous position was closed by SL/TP, we need to reset the signal state.
        
        Args:
            open_positions (list): List of currently open positions
            
        Returns:
            bool: True if signal was reset, False otherwise
        """
        # If we have prev_signal but no open positions, the position must have been closed externally
        # via SL/TP or manual intervention
        if self.prev_signal is not None and not open_positions:
            print(f"🔄 Detected position closed by SL/TP or manually. Resetting signal state.")
            self.reset_signal_state()
            return True
        return False 