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
        
        if direction == "BUY":
            if is_flat:
                # For flat trends, require stronger confirmation
                slope_ok = (fast_slope > SIGNAL_FILTERS['MIN_SLOPE_THRESHOLD']*2 and 
                          slow_slope > SIGNAL_FILTERS['MAX_OPPOSITE_SLOPE']*2)
            else:
                slope_ok = (fast_slope > SIGNAL_FILTERS['MIN_SLOPE_THRESHOLD'] and 
                          slow_slope > SIGNAL_FILTERS['MAX_OPPOSITE_SLOPE'])
            return slope_ok
        else:  # SELL
            if is_flat:
                # For flat trends, require stronger confirmation
                slope_ok = (fast_slope < -SIGNAL_FILTERS['MIN_SLOPE_THRESHOLD']*2 and 
                          slow_slope < -SIGNAL_FILTERS['MAX_OPPOSITE_SLOPE']*2)
            else:
                slope_ok = (fast_slope < -SIGNAL_FILTERS['MIN_SLOPE_THRESHOLD'] and 
                          slow_slope < -SIGNAL_FILTERS['MAX_OPPOSITE_SLOPE'])
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
        """Check if price confirms the signal direction"""
        if self.data.empty or len(self.data) < 1:
            return False
            
        last_close = self.data['close'].iloc[-1]
        fast_ema = self.data['fast_ema'].iloc[-1]
        slow_ema = self.data['slow_ema'].iloc[-1]
        
        if direction == "BUY":
            price_ok = last_close > fast_ema and last_close > slow_ema
        else:  # SELL
            price_ok = last_close < fast_ema and last_close < slow_ema
            
        # print(f"Price Confirmation ({direction}) - {'✅' if price_ok else '❌'}")
        return price_ok
    
    def generate_entry_signal(self):
        """
        Checks for EMA crossover entry signals with additional filters.
        
        Returns:
            tuple or None: (signal_type, entry_price, None, None) or None
            The SL/TP will be calculated by the risk manager based on the risk parameter
        """
        if self.data.empty or len(self.data) < 2:
            #print("Not enough data for EMA crossover analysis")
            return None
            
        # Get current and previous values
        current_fast = self.data['fast_ema'].iloc[-1]
        current_slow = self.data['slow_ema'].iloc[-1]
        prev_fast = self.data['fast_ema'].iloc[-2]
        prev_slow = self.data['slow_ema'].iloc[-2]
        
        # Check for minimum crossover threshold
        diff = current_fast - current_slow
        
        # Get the point value safely
        try:
            from generic_trader import DataFetcher
            point = DataFetcher.get_symbol_point(self.symbol_info)
        except (ImportError, ValueError) as e:
            print(f"⚠️ Error getting point value: {e}")
            # Cannot proceed without a valid point value
            raise ValueError(f"Cannot generate entry signal without a valid point value: {e}")
            
        diff_points = abs(diff / point)
        
        if diff_points < SIGNAL_FILTERS['MIN_CROSSOVER_POINTS']:
            return None
        
        # Check for crossover
        potential_signal = None
        crossover_detected = False
        
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
                
        # If we detect a crossover, analyze it
        if crossover_detected and potential_signal:
            print(f"\nAnalyzing potential {potential_signal} Signal:")
            
            slope_ok = self.check_slope_conditions(potential_signal)
            separation_ok = self.check_separation(potential_signal)
            price_ok = self.check_price_confirmation(potential_signal)
            
            print(f"Slope: {'✅' if slope_ok else '❌'}, Separation: {'✅' if separation_ok else '❌'}, Price: {'✅' if price_ok else '❌'}")
            
            if slope_ok and separation_ok and price_ok:
                print(f"\n✅ Valid {potential_signal} Signal - All conditions met")
                
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