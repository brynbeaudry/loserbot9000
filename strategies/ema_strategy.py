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
}

class EMAStrategy(BaseStrategy):
    """Implementation of EMA crossover strategy compatible with generic_trader framework"""
    
    def __init__(self, symbol, timeframe, symbol_info, strategy_config=None):
        """Initialize the strategy with default parameters"""
        super().__init__(symbol, timeframe, symbol_info, strategy_config)
        self.prev_signal = None
        
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
        """Calculate the slope of a series over specified periods"""
        if len(series) < periods:
            return 0
        
        y = series[-periods:].values
        x = np.arange(len(y))
        slope, _ = np.polyfit(x, y, 1)
        return slope
    
    def check_slope_conditions(self, direction="BUY"):
        """Check if slope conditions are met for the given trade direction"""
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
        """Check if EMAs have sufficient separation after crossover"""
        if self.data.empty or len(self.data) < 2:
            return False
            
        current_fast = self.data['fast_ema'].iloc[-1]
        current_slow = self.data['slow_ema'].iloc[-1]
        
        diff = current_fast - current_slow
        
        # Get the point value safely
        try:
            from generic_trader import DataFetcher
            point = DataFetcher.get_symbol_point(self.symbol_info)
        except (ImportError, ValueError) as e:
            print(f"⚠️ Error getting point value: {e}")
            # Cannot proceed without a valid point value
            raise ValueError(f"Cannot check separation without a valid point value: {e}")
            
        diff_points = abs(diff / point)
        
        if direction == "BUY":
            sep_ok = diff > 0 and diff_points >= SIGNAL_FILTERS['MIN_SEPARATION_POINTS']
        else:  # SELL
            sep_ok = diff < 0 and diff_points >= SIGNAL_FILTERS['MIN_SEPARATION_POINTS']
            
        # print(f"Separation Check ({direction}) - {diff_points:.1f} points - {'✅' if sep_ok else '❌'}")
        return sep_ok
    
    def check_price_confirmation(self, direction="BUY"):
        """
        Check if price confirms the signal direction
        Relaxed to check only against slow EMA
        """
        if self.data.empty or len(self.data) < 1:
            return False
            
        last_close = self.data['close'].iloc[-1]
        fast_ema = self.data['fast_ema'].iloc[-1]
        slow_ema = self.data['slow_ema'].iloc[-1]
        
        if direction == "BUY":
            # Relaxed condition: only need to be above the slow EMA for BUY
            price_ok = last_close > slow_ema
        else:  # SELL
            # Relaxed condition: only need to be below the slow EMA for SELL
            price_ok = last_close < slow_ema
            
        return price_ok
    
    def generate_entry_signal(self):
        """
        Checks for EMA crossover entry signals with additional filters.
        Also considers existing strong trends even without recent crossover.
        
        Returns:
            tuple or None: (signal_type, entry_price, None, None) or None
            The SL/TP will be calculated by the risk manager based on the risk parameter
        """
        if self.data.empty or len(self.data) < 10:  # Need at least 10 candles
            return None
            
        # Get current and previous values
        current_fast = self.data['fast_ema'].iloc[-1]
        current_slow = self.data['slow_ema'].iloc[-1]
        prev_fast = self.data['fast_ema'].iloc[-2]
        prev_slow = self.data['slow_ema'].iloc[-2]
        
        # Get the point value safely
        try:
            from generic_trader import DataFetcher
            point = DataFetcher.get_symbol_point(self.symbol_info)
        except (ImportError, ValueError) as e:
            print(f"⚠️ Error getting point value: {e}")
            raise ValueError(f"Cannot generate entry signal without a valid point value: {e}")
            
        # Initialize variables
        potential_signal = None
        signal_type = None
        crossover_detected = False
        recent_crossover = False
        
        # Check if a crossover happened within the last 5 candles
        for i in range(1, min(6, len(self.data)-1)):  # Check last 5 candles
            idx_fast = self.data['fast_ema'].iloc[-i]
            idx_slow = self.data['slow_ema'].iloc[-i]
            prev_idx_fast = self.data['fast_ema'].iloc[-(i+1)]
            prev_idx_slow = self.data['slow_ema'].iloc[-(i+1)]
            
            # BUY crossover within last few candles
            if prev_idx_fast <= prev_idx_slow and idx_fast > idx_slow:
                recent_crossover = True
                if not self.prev_signal or self.prev_signal == mt5.ORDER_TYPE_SELL:
                    potential_signal = "BUY"
                    signal_type = mt5.ORDER_TYPE_BUY
                    print(f"\n📊 Recent BUY Crossover detected {i} candles ago")
                    break
                    
            # SELL crossover within last few candles
            elif prev_idx_fast >= prev_idx_slow and idx_fast < idx_slow:
                recent_crossover = True
                if not self.prev_signal or self.prev_signal == mt5.ORDER_TYPE_BUY:
                    potential_signal = "SELL"
                    signal_type = mt5.ORDER_TYPE_SELL
                    print(f"\n📊 Recent SELL Crossover detected {i} candles ago")
                    break
        
        # Check for immediate crossover if no recent one was found
        if not recent_crossover:
            if prev_fast <= prev_slow and current_fast > current_slow:
                crossover_detected = True
                if not self.prev_signal or self.prev_signal == mt5.ORDER_TYPE_SELL:
                    potential_signal = "BUY"
                    signal_type = mt5.ORDER_TYPE_BUY
            elif prev_fast >= prev_slow and current_fast < current_slow:
                crossover_detected = True
                if not self.prev_signal or self.prev_signal == mt5.ORDER_TYPE_BUY:
                    potential_signal = "SELL"
                    signal_type = mt5.ORDER_TYPE_SELL
        
        # Get current EMA diff for strength analysis
        diff = current_fast - current_slow
        diff_points = abs(diff / point)
        
        # Check for strong existing trend if no crossover detected
        if not (crossover_detected or recent_crossover) and diff_points >= SIGNAL_FILTERS['MIN_SEPARATION_POINTS']:
            # Strong existing BUY trend
            if current_fast > current_slow and not self.prev_signal:
                potential_signal = "BUY"
                signal_type = mt5.ORDER_TYPE_BUY
                print(f"\n📊 Analyzing existing BUY trend (no recent crossover):")
            # Strong existing SELL trend
            elif current_fast < current_slow and not self.prev_signal:
                potential_signal = "SELL"
                signal_type = mt5.ORDER_TYPE_SELL
                print(f"\n📊 Analyzing existing SELL trend (no recent crossover):")
                
        # If we have a potential signal (crossover or strong trend), analyze it
        if potential_signal:
            diff_value = current_fast - current_slow
            diff_points = abs(diff_value / point)
            prev_diff = prev_fast - prev_slow
            
            # Create a detailed log message with EMA values and differences
            if crossover_detected:
                print(f"\n📊 Analyzing {potential_signal} Signal (immediate crossover):")
                print(f"   Previous Candle: Fast EMA = {prev_fast:.5f}, Slow EMA = {prev_slow:.5f} (Diff: {prev_diff:.5f})")
            print(f"   Current Candle:  Fast EMA = {current_fast:.5f}, Slow EMA = {current_slow:.5f} (Diff: {diff_value:.5f})")
            print(f"   Signal Strength: {diff_points:.1f} points (min required: {SIGNAL_FILTERS['MIN_CROSSOVER_POINTS']})")
            
            slope_ok = self.check_slope_conditions(potential_signal)
            separation_ok = True  # Relaxed - we'll just require EMA orientation rather than specific separation
            price_ok = self.check_price_confirmation(potential_signal)
            
            print(f"Slope: {'✅' if slope_ok else '❌'}, Price: {'✅' if price_ok else '❌'}")
            
            # Relaxed condition check for immediate or recent crossovers
            if (crossover_detected or recent_crossover) and slope_ok and price_ok:
                print(f"\n🚀 VALID {potential_signal} SIGNAL - Crossover with confirming slope and price")
                
                # Get current price for entry
                if potential_signal == "BUY":
                    if 'ask' in self.data.columns:
                        entry_price = self.data['ask'].iloc[-1]
                    else:
                        entry_price = self.data['close'].iloc[-1]
                        print("⚠️ Warning: Using close price instead of ask price for BUY order")
                    
                    self.prev_signal = mt5.ORDER_TYPE_BUY
                else:  # SELL
                    if 'bid' in self.data.columns:
                        entry_price = self.data['bid'].iloc[-1]
                    else:
                        entry_price = self.data['close'].iloc[-1]
                        print("⚠️ Warning: Using close price instead of bid price for SELL order")
                    
                    self.prev_signal = mt5.ORDER_TYPE_SELL
                
                # Return entry signal - SL/TP will be calculated by RiskManager based on risk parameter
                return signal_type, entry_price, None, None
            
            # Stricter condition check for existing trends (no recent crossover)
            elif not (crossover_detected or recent_crossover) and slope_ok and separation_ok and price_ok and diff_points >= SIGNAL_FILTERS['MIN_SEPARATION_POINTS']:
                print(f"\n🚀 VALID {potential_signal} SIGNAL - Strong existing trend")
                
                # Get current price for entry
                if potential_signal == "BUY":
                    if 'ask' in self.data.columns:
                        entry_price = self.data['ask'].iloc[-1]
                    else:
                        entry_price = self.data['close'].iloc[-1]
                        print("⚠️ Warning: Using close price instead of ask price for BUY order")
                    
                    self.prev_signal = mt5.ORDER_TYPE_BUY
                else:  # SELL
                    if 'bid' in self.data.columns:
                        entry_price = self.data['bid'].iloc[-1]
                    else:
                        entry_price = self.data['close'].iloc[-1]
                        print("⚠️ Warning: Using close price instead of bid price for SELL order")
                    
                    self.prev_signal = mt5.ORDER_TYPE_SELL
                
                # Return entry signal - SL/TP will be calculated by RiskManager based on risk parameter
                return signal_type, entry_price, None, None
        
        return None
    
    def generate_exit_signal(self, position):
        """
        Checks if an existing position should be closed based on EMA crossover logic.
        This will close a position when the EMAs cross in the opposite direction.
        
        Args:
            position: MT5 position information object
            
        Returns:
            bool: True if the position should be closed, False otherwise
        """
        if self.data.empty or len(self.data) < 2:
            return False
            
        # Get current and previous values
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