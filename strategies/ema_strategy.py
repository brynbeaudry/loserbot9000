import MetaTrader5 as mt5
import numpy as np
from strategies.base_strategy import BaseStrategy

# Signal Filter Parameters (from ema_crossover_strategy.py)
SIGNAL_FILTERS = {
    'MIN_CROSSOVER_POINTS': 1,  # Minimum points required for initial crossover
    'MIN_SEPARATION_POINTS': 2,  # Minimum separation after crossover
    'SLOPE_PERIODS': 3,  # Periods to calculate slope over
    'MIN_SLOPE_THRESHOLD': 0.000001,  # Minimum slope for trend direction
    'MAX_OPPOSITE_SLOPE': -0.000002,  # Maximum allowed opposite slope
    'LOOKBACK_CANDLES': 5,  # Number of recent candles to check for crossover
}

class EMAStrategy(BaseStrategy):
    """Implementation of EMA crossover strategy compatible with generic_trader framework"""
    
    def __init__(self, symbol, timeframe, symbol_info, strategy_config=None):
        """Initialize the strategy with default parameters"""
        super().__init__(symbol, timeframe, symbol_info, strategy_config)
        
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
        
    def detect_existing_trend(self):
        """
        Check for strong existing trend when no crossover was detected
        
        Returns:
            tuple: (trend_detected, signal_type, potential_signal)
            or (False, None, None) if no strong trend detected
        """
        if self.data.empty or len(self.data) < 2:
            return False, None, None
            
        current_fast = self.data['fast_ema'].iloc[-1]
        current_slow = self.data['slow_ema'].iloc[-1]
        diff = current_fast - current_slow
        point = self.get_point_value()
        diff_points = abs(diff / point)
        
        # Need minimum separation for existing trend
        if diff_points < SIGNAL_FILTERS['MIN_SEPARATION_POINTS']:
            return False, None, None
            
        trend_detected = False
        signal_type = None
        potential_signal = None
        
        # Strong existing BUY trend
        if current_fast > current_slow and not self.prev_signal:
            trend_detected = True
            potential_signal = "BUY"
            signal_type = mt5.ORDER_TYPE_BUY
            print(f"\n📊 Analyzing existing BUY trend (no recent crossover):")
        # Strong existing SELL trend
        elif current_fast < current_slow and not self.prev_signal:
            trend_detected = True
            potential_signal = "SELL"
            signal_type = mt5.ORDER_TYPE_SELL
            print(f"\n📊 Analyzing existing SELL trend (no recent crossover):")
            
        return trend_detected, signal_type, potential_signal
    
    def generate_entry_signal(self):
        """
        Checks for EMA crossover entry signals with additional filters.
        Also considers existing strong trends even without recent crossover.
        
        Returns:
            tuple or None: (signal_type, entry_price, None, None) or None
            The SL/TP will be calculated later based on actual entry price
        """
        if self.data.empty or len(self.data) < 10:  # Need at least 10 candles
            return None
            
        # Get current EMA values for logging
        current_fast = self.data['fast_ema'].iloc[-1]
        current_slow = self.data['slow_ema'].iloc[-1]
        prev_fast = self.data['fast_ema'].iloc[-2]
        prev_slow = self.data['slow_ema'].iloc[-2]
        point = self.get_point_value()
            
        # Try to detect a recent crossover first
        crossover_detected, signal_type, potential_signal, candles_ago = self.detect_recent_crossover()
        
        # If no crossover detected, check for existing trend
        if not crossover_detected:
            trend_detected, signal_type, potential_signal = self.detect_existing_trend()
        else:
            trend_detected = False
                
        # If we have a potential signal, analyze it
        if potential_signal:
            diff_value = current_fast - current_slow
            diff_points = abs(diff_value / point)
            prev_diff = prev_fast - prev_slow
            
            # Log current state
            print(f"   Current Candle: Fast EMA = {current_fast:.5f}, Slow EMA = {current_slow:.5f} (Diff: {diff_value:.5f})")
            print(f"   Signal Strength: {diff_points:.1f} points (min required: {SIGNAL_FILTERS['MIN_CROSSOVER_POINTS']})")
            
            # Check conditions specific to signal type
            slope_ok = self.check_slope_conditions(potential_signal)
            price_ok = self.check_price_confirmation(potential_signal)
            
            print(f"Slope: {'✅' if slope_ok else '❌'}, Price: {'✅' if price_ok else '❌'}")
            
            # Signal validation logic based on detection method
            valid_signal = False
            
            # Crossover-based signal (less strict)
            if crossover_detected and slope_ok and price_ok:
                valid_signal = True
                print(f"\n🚀 VALID {potential_signal} SIGNAL - Crossover with confirming slope and price")
                
            # Existing trend signal (more strict - requires separation as well)
            elif trend_detected and slope_ok and price_ok and diff_points >= SIGNAL_FILTERS['MIN_SEPARATION_POINTS']:
                valid_signal = True
                print(f"\n🚀 VALID {potential_signal} SIGNAL - Strong existing trend")
                
            # If valid signal, calculate entry price and return signal
            if valid_signal:
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