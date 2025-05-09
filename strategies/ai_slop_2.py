import MetaTrader5 as mt5
import pandas as pd
import numpy as np
from strategies.base_strategy import BaseStrategy
import sys
import os
from datetime import datetime, timedelta
import math

# Add parent directory to path to import needed functions
sys.path.append('..')
try:
    from generic_trader import get_candle_boundaries, get_server_time
except ImportError:
    raise ImportError("Could not import required functions from generic_trader.py")

# MACD Zero-Line Momentum Crossover Strategy Configuration
MACD_STRATEGY_CONFIG = {
    # Risk and Money Management
    'RISK_PERCENT': 0.01,           # 1% risk per trade
    'SL_ATR_MULT': 3.0,             # Stop loss multiplier of ATR
    'TP_ATR_MULT': 6.0,             # Take profit multiplier of ATR (2:1 reward-risk ratio)
    
    # MACD Configuration
    'MACD_FAST_LENGTH': 2,          # Fast length for MACD calculation
    'MACD_SLOW_LENGTH': 8,          # Slow length for MACD calculation
    'MACD_SIGNAL_SMOOTHING': 5,     # Signal line smoothing period
    
    # Signal Value Change Requirement
    'CHECK_CANDLES': 2,              # Number of candles to check for signal value change
    'MIN_SIGNAL_CHANGE': 1.0,        # Minimum required change in signal value between candles
    
    # Histogram Requirements
    'MIN_HISTOGRAM_VALUE': 10,      # Minimum histogram value to consider significant
    
    # Trading Behavior
    'WAIT_CANDLES_AFTER_EXIT': 0,   # Candles to wait after exit before re-entry
    'EXIT_THRESHOLD': 20.0,         # Exit when MACD is this many points above/below signal (in direction against the trade)
}

# Example command to run with custom MACD parameters:
# python generic_trader.py EURUSD --strategy ai_slop_2 --volume 0.01 --config '{"MACD_FAST_LENGTH": 2, "MACD_SLOW_LENGTH": 8, "MACD_SIGNAL_SMOOTHING": 5}'

# Example command with slope parameters:
# python generic_trader.py EURUSD --strategy ai_slop_2 --volume 0.01 --config '{"SLOPE_CHECK_CANDLES": 3, "MIN_SLOPE_THRESHOLD": 0.00002}'

class AISlope2Strategy(BaseStrategy):
    """
    MACD Signal Line Zero-Cross Momentum Strategy
    
    This strategy enters after a MACD Signal Line zero-line crossover, detecting both:
    - Immediate crossovers (current candle)
    - Recent crossovers (within the last few candles)
    
    It requires significant histogram momentum in the direction of the trade
    and checks the slope of the Signal line to ensure there's sufficient 
    directional movement, avoiding flat/choppy markets.
    
    # === MACD Signal Line Zero-Cross Momentum Strategy ===
    # Indicators: MACD(2, 8, 5) - configurable parameters
    # - MACD Line: Black line
    # - Signal Line: Red dotted line (zero-line crossover trigger)
    # - Histogram: Black bars representing difference between MACD and Signal lines
    #
    # Long Entry: After Signal line (red dotted) crosses above 0 (current or recent candles), with:
    #   - Rising histogram with significant positive value
    #   - MACD > Signal (black above red dotted line)
    #   - Sufficient positive Signal line slope (not too flat over the last N candles)
    # Long Exit:
    #   - When MACD crosses below signal (histogram becomes negative), OR
    #   - When MACD drops EXIT_THRESHOLD points below signal line
    #
    # Short Entry: After Signal line (red dotted) crosses below 0 (current or recent candles), with:
    #   - Falling histogram with significant negative value
    #   - MACD < Signal (black below red dotted line)
    #   - Sufficient negative Signal line slope (not too flat over the last N candles)
    # Short Exit:
    #   - When MACD crosses above signal (histogram becomes positive), OR
    #   - When MACD rises EXIT_THRESHOLD points above signal line
    #
    # Re-entry: Only after Signal line crosses zero again
    #
    # Exit Control:
    # - EXIT_THRESHOLD: Controls additional exit condition based on MACD vs Signal
    #   - For LONG: Exit when MACD drops below (Signal - EXIT_THRESHOLD)
    #   - For SHORT: Exit when MACD rises above (Signal + EXIT_THRESHOLD)
    """
    
    def __init__(self, symbol, timeframe, symbol_info, strategy_config=None):
        """Initialize the strategy with default parameters"""
        super().__init__(symbol, timeframe, symbol_info, strategy_config)
        
        # Merge provided config with default config
        self.config = {**MACD_STRATEGY_CONFIG, **(strategy_config or {})}
        
        # Strategy state variables
        self.last_trade_close_time = None
        self.data = pd.DataFrame()
        self.indicators = {}
        self.macd_data = None
        self.entry_decision = None
        self.price_levels = {'entry': None, 'stop': None, 'tp': None}
        self.last_processed_candle_time = None
        
        # MACD specific state tracking
        self.awaiting_next_signal_zero_cross = False
        self.candles_since_exit = 0
        self.crossover_candle_time = None  # Track when crossover happened
        self.can_enter_after_crossover = False  # Flag to only enter after complete crossover candle
        self.last_trade_direction = None  # Track if last trade was long or short
        
    def get_required_data_count(self):
        """Return the minimum number of candles needed for this strategy"""
        # Need enough data for MACD calculation plus buffer
        macd_slow = self.config['MACD_SLOW_LENGTH']
        macd_signal = self.config['MACD_SIGNAL_SMOOTHING']
        
        # Calculate minimum required bars
        required_bars = max(50, int((macd_slow * 3) + macd_signal))
        
        # Set a reasonable maximum to avoid MT5 data retrieval errors
        MAX_SAFE_BARS = 1000
        if required_bars > MAX_SAFE_BARS:
            print(f"⚠️ Limiting data request from {required_bars} to {MAX_SAFE_BARS} bars to avoid MT5 errors")
            required_bars = MAX_SAFE_BARS
            
        return required_bars
    
    def calculate_indicators(self):
        """Calculate MACD indicator values based on the latest data"""
        if self.data.empty or len(self.data) < self.config['MACD_SLOW_LENGTH']:
            return
            
        # Get MACD parameters from config
        macd_fast = self.config['MACD_FAST_LENGTH']
        macd_slow = self.config['MACD_SLOW_LENGTH']
        macd_signal = self.config['MACD_SIGNAL_SMOOTHING']
        
        # Calculate MACD components
        fast_ema = self.data['close'].ewm(span=macd_fast, adjust=False).mean()
        slow_ema = self.data['close'].ewm(span=macd_slow, adjust=False).mean()
        
        # MACD line is the difference between fast and slow EMAs
        macd_line = fast_ema - slow_ema
        
        # Signal line is EMA of MACD line
        signal_line = macd_line.ewm(span=macd_signal, adjust=False).mean()
        
        # Histogram is difference between MACD and signal line
        histogram = macd_line - signal_line
        
        # Store in indicators dict for easy access
        self.indicators['macd'] = macd_line
        self.indicators['signal'] = signal_line  
        self.indicators['histogram'] = histogram
        self.indicators['atr'] = self._calculate_atr(self.data)
        
        # Calculate MACD slope
        self._calculate_signal_change()
    
    def _calculate_atr(self, ohlc_data, period=14):
        """Calculate Average True Range (ATR) for stop loss and take profit levels"""
        if len(ohlc_data) < period + 1:
            return pd.Series(index=ohlc_data.index, dtype='float64')
            
        # Create a new DataFrame to avoid modifying the input
        df = pd.DataFrame(index=ohlc_data.index)
        
        # Calculate True Range
        df['high'] = ohlc_data['high']
        df['low'] = ohlc_data['low']
        df['close'] = ohlc_data['close']
        df['prev_close'] = ohlc_data['close'].shift(1)
        
        # Handle the first row where prev_close is NaN
        df.loc[df.index[0], 'prev_close'] = df['close'].iloc[0]
        
        # Calculate the three components of True Range
        df['tr1'] = df['high'] - df['low']
        df['tr2'] = abs(df['high'] - df['prev_close'])
        df['tr3'] = abs(df['low'] - df['prev_close'])
        
        # True Range is the maximum of the three components
        df['tr'] = df[['tr1', 'tr2', 'tr3']].max(axis=1)
        
        # Calculate Average True Range (ATR)
        df['atr'] = df['tr'].rolling(window=period, min_periods=1).mean()
        
        return df['atr']
    
    def _calculate_signal_change(self):
        """Calculate the change in Signal line values over recent candles"""
        if 'signal' not in self.indicators or len(self.indicators['signal']) < self.config['CHECK_CANDLES']:
            self.indicators['signal_change'] = 0
            return
            
        # Get last N candles of Signal values
        n_candles = self.config['CHECK_CANDLES']
        signal_values = self.indicators['signal'].iloc[-n_candles:].values
        
        # Calculate the change from first to last value
        first_value = signal_values[0]
        last_value = signal_values[-1]
        signal_change = last_value - first_value
        
        # Store the change value
        self.indicators['signal_change'] = signal_change
        
        # Create a simple visual indicator of the change direction
        if signal_change > 0:
            direction = "▲"
        elif signal_change < 0:
            direction = "▼"
        else:
            direction = "◆"
        
        # Log the change value for debugging (clean, compact format)
        print(f"📊 Signal: {first_value:.2f} → {last_value:.2f} ({direction} {signal_change:.2f})")
    
    def update_data(self, new_data):
        """Updates the strategy's data and recalculates indicators"""
        if new_data is not None and not new_data.empty:
            self.data = new_data.copy()
            self.calculate_indicators()
    
    def _check_macd_conditions(self):
        """Check MACD and Signal conditions for entry and exit decisions"""
        if self.data.empty or 'macd' not in self.indicators:
            return None
            
        # Get current and previous MACD values
        macd_current = self.indicators['macd'].iloc[-1]
        macd_previous = self.indicators['macd'].iloc[-2] if len(self.indicators['macd']) > 1 else 0
        
        # Get current and previous Signal values
        signal_current = self.indicators['signal'].iloc[-1]
        signal_previous = self.indicators['signal'].iloc[-2] if len(self.indicators['signal']) > 1 else 0
        
        # For recent crossovers, check a bit further back (last 3-4 candles)
        signal_values = [self.indicators['signal'].iloc[-i] for i in range(1, min(5, len(self.indicators['signal'])))]
        prev_signal_values = [self.indicators['signal'].iloc[-i] for i in range(2, min(6, len(self.indicators['signal'])))]
        
        # Get current and previous histogram values
        hist_current = self.indicators['histogram'].iloc[-1]
        hist_previous = self.indicators['histogram'].iloc[-2] if len(self.indicators['histogram']) > 1 else 0
        
        # Get Signal change if available
        signal_change = self.indicators.get('signal_change', 0)
        
        # Check if change meets minimum threshold (absolute value for short trades)
        min_change = self.config['MIN_SIGNAL_CHANGE']
        significant_change = abs(signal_change) >= min_change
        
        # Get minimum histogram value from config
        min_hist_value = self.config['MIN_HISTOGRAM_VALUE']
        
        # Calculate key conditions for long trades
        signal_zero_cross_up = signal_previous < 0 and signal_current >= 0
        
        # Check for recent crossover (within last 3-4 candles)
        recent_zero_cross_up = False
        recent_zero_cross_down = False
        
        # Look for a sign change from negative to positive (upward cross)
        for i in range(len(signal_values) - 1):
            if prev_signal_values[i] < 0 and signal_values[i] >= 0:
                recent_zero_cross_up = True
                break
                
        # Look for a sign change from positive to negative (downward cross)
        for i in range(len(signal_values) - 1):
            if prev_signal_values[i] > 0 and signal_values[i] <= 0:
                recent_zero_cross_down = True
                break
        
        macd_above_zero = macd_current > 0
        macd_below_zero = macd_current < 0
        signal_above_zero = signal_current > 0
        signal_below_zero = signal_current < 0
        histogram_rising = hist_current > hist_previous
        histogram_falling = hist_current < hist_previous
        histogram_positive = hist_current > 0
        histogram_negative = hist_current < 0
        macd_above_signal = macd_current > signal_current
        macd_below_signal = macd_current < signal_current
        
        # Check for significant histogram values
        significant_positive_histogram = hist_current >= min_hist_value
        significant_negative_histogram = hist_current <= -min_hist_value
        
        # Calculate key conditions for short trades
        signal_zero_cross_down = signal_previous > 0 and signal_current <= 0
        
        # Return all conditions as a dictionary
        return {
            # Long conditions
            'signal_zero_cross_up': signal_zero_cross_up,
            'recent_zero_cross_up': recent_zero_cross_up,
            'signal_above_zero': signal_above_zero,
            'macd_above_zero': macd_above_zero,
            'histogram_rising': histogram_rising,
            'histogram_positive': histogram_positive,
            'macd_above_signal': macd_above_signal,
            'significant_positive_histogram': significant_positive_histogram,
            
            # Short conditions
            'signal_zero_cross_down': signal_zero_cross_down,
            'recent_zero_cross_down': recent_zero_cross_down,
            'signal_below_zero': signal_below_zero,
            'macd_below_zero': macd_below_zero,
            'histogram_falling': histogram_falling,
            'histogram_negative': histogram_negative,
            'macd_below_signal': macd_below_signal,
            'significant_negative_histogram': significant_negative_histogram,
            
            # Common values
            'macd_value': macd_current,
            'signal_value': signal_current,
            'hist_value': hist_current,
            'hist_prev': hist_previous,
            'macd_prev': macd_previous,
            'signal_prev': signal_previous,
            'signal_change': signal_change,
            'significant_change': significant_change
        }
    
    def _calculate_price_levels(self, trade_type):
        """
        Calculate entry, stop loss, and take profit prices based on ATR
        
        Args:
            trade_type: mt5.ORDER_TYPE_BUY or mt5.ORDER_TYPE_SELL
        """
        if self.data.empty or 'atr' not in self.indicators:
            return None
            
        # Get the latest close price and ATR
        close_price = self.data['close'].iloc[-1]
        atr = self.indicators['atr'].iloc[-1]
        
        # Get ATR multipliers from config
        sl_mult = self.config['SL_ATR_MULT']
        tp_mult = self.config['TP_ATR_MULT']
        
        # Calculate price levels based on trade type
        entry = close_price
        
        if trade_type == mt5.ORDER_TYPE_BUY:
            # Long trade: SL below entry, TP above entry
            stop = entry - sl_mult * atr
            tp = entry + tp_mult * atr
        else:
            # Short trade: SL above entry, TP below entry
            stop = entry + sl_mult * atr
            tp = entry - tp_mult * atr
            
        # Store the price levels
        self.price_levels = {
            'entry': entry,
            'stop': stop,
            'tp': tp
        }
        
        # Log price levels
        print(f"Price Levels for {'LONG' if trade_type == mt5.ORDER_TYPE_BUY else 'SHORT'}:")
        print(f"  - Entry: {entry:.5f}")
        print(f"  - Stop Loss: {stop:.5f} ({sl_mult}x ATR = {sl_mult * atr:.5f})")
        print(f"  - Take Profit: {tp:.5f} ({tp_mult}x ATR = {tp_mult * atr:.5f})")
        print(f"  - Risk/Reward Ratio: 1:{tp_mult/sl_mult:.1f}")
            
        return self.price_levels
        
    def generate_entry_signal(self, open_positions=None):
        """
        Generate entry signals based on MACD zero-line crossover with momentum.
        Detects both immediate and recent crossovers (within the last few candles).
        
        Args:
            open_positions (list, optional): List of currently open positions
            
        Returns:
            tuple or None: (signal_type, entry_price, sl_price, tp_price) or None
        """
        # Skip if we have open positions
        if open_positions:
            return None
            
        # Check if position was recently closed
        if self.last_trade_close_time is not None:
            current_time = get_server_time()
            time_diff = (current_time - self.last_trade_close_time).total_seconds()
            wait_time = 60  # 1 minute wait after closing a position
            
            if time_diff < wait_time:
                print(f"⏳ Waiting {(wait_time - time_diff)/60:.1f} more minutes after last trade close")
                return None
        
        # Check if we're at the beginning of a new candle
        server_time = get_server_time()
        current_candle_start, current_candle_end = get_candle_boundaries(server_time, self.timeframe)
        time_since_candle_open = (server_time - current_candle_start).total_seconds()
        candle_total_seconds = (current_candle_end - current_candle_start).total_seconds()
        
        # Only trade in the first 20% of the candle's total time
        candle_entry_threshold = 0.2 * candle_total_seconds
        if time_since_candle_open > candle_entry_threshold:
            return None
            
        # Process new candle detection
        is_new_candle = False
        if self.last_processed_candle_time:
            # Get the last processed candle's start time
            last_candle_start, _ = get_candle_boundaries(self.last_processed_candle_time, self.timeframe)
            
            # Skip if we've already processed this candle
            if current_candle_start <= last_candle_start:
                return None
                
            print(f"🔄 CANDLE: New candle detected at {current_candle_start} ✅")
            is_new_candle = True
        else:
            print(f"🔄 CANDLE: Initial candle at {current_candle_start} - first run ✅")
            is_new_candle = True
            
        # Update the last processed candle time
        self.last_processed_candle_time = current_candle_start
        
        # Make sure we have MACD data calculated
        self.calculate_indicators()
        
        # Check candles since last exit counter
        if self.candles_since_exit < self.config['WAIT_CANDLES_AFTER_EXIT']:
            print(f"⏳ Waiting {self.config['WAIT_CANDLES_AFTER_EXIT'] - self.candles_since_exit} more candles after last exit")
            self.candles_since_exit += 1
            return None
            
        # Get MACD conditions
        conditions = self._check_macd_conditions()
        if not conditions:
            return None
            
        # Check for awaiting next zero cross
        if self.awaiting_next_signal_zero_cross:
            # Check for both immediate and recent crossovers
            if (conditions['signal_zero_cross_up'] or conditions['signal_zero_cross_down'] or 
                conditions['recent_zero_cross_up'] or conditions['recent_zero_cross_down']):
                
                cross_type = "up" if (conditions['signal_zero_cross_up'] or conditions['recent_zero_cross_up']) else "down"
                cross_timing = "recent" if (conditions['recent_zero_cross_up'] or conditions['recent_zero_cross_down']) else "immediate"
                
                print(f"🔄 Zero cross: {cross_timing} {cross_type}")
                self.awaiting_next_signal_zero_cross = False
                
                # If it's a recent crossover, treat it as if it already completed
                if conditions['recent_zero_cross_up'] or conditions['recent_zero_cross_down']:
                    print(f"📝 Recent crossover - ready to enter")
                    # Bypass waiting period but all trading criteria (slope, histogram, etc.)
                    # will still be evaluated before actually entering a trade
                    self.can_enter_after_crossover = True
                else:
                    # Record the crossover candle time - we'll enter on the next candle
                    self.crossover_candle_time = current_candle_start
                    print(f"📝 Immediate crossover - waiting for candle completion")
                    # We'll wait for the next candle before entering
                    self.can_enter_after_crossover = False
                
                return None
            else:
                print("⏳ Waiting for zero cross before new entry")
                return None
        
        # Check if we've seen a crossover in this candle or recently
        if conditions['signal_zero_cross_up'] or conditions['signal_zero_cross_down']:
            # Record the crossover candle time - we'll enter on the next candle
            self.crossover_candle_time = current_candle_start
            cross_type = "above" if conditions['signal_zero_cross_up'] else "below"
            print(f"📝 Zero cross: {cross_type} | Waiting for candle completion")
            # We'll wait for the next candle before entering
            self.can_enter_after_crossover = False
            return None
        elif conditions['recent_zero_cross_up'] or conditions['recent_zero_cross_down']:
            # For recent crossovers, no need to wait - consider it confirmed already
            cross_type = "above" if conditions['recent_zero_cross_up'] else "below"
            print(f"📝 Recent zero cross: {cross_type} | Ready to enter")
            # Allow entry without waiting for next candle, but all other conditions
            # (slope, histogram significance, etc.) must still be satisfied
            self.can_enter_after_crossover = True
        
        # If a crossover was detected on a previous candle and we have a new candle now, allow entry
        if self.crossover_candle_time is not None and is_new_candle:
            previous_candle_start, _ = get_candle_boundaries(self.crossover_candle_time, self.timeframe)
            if current_candle_start > previous_candle_start:
                print(f"✅ Crossover candle complete - ready to enter")
                self.can_enter_after_crossover = True
        
        # Evaluate buy/sell signal criteria
        buy_signal_ready = (conditions['signal_above_zero'] and 
                           conditions['macd_above_signal'] and  # MACD above signal (positive histogram)
                           self.can_enter_after_crossover and 
                           conditions['significant_change'] and 
                           conditions['signal_change'] > 0 and
                           conditions['significant_positive_histogram'])
        
        sell_signal_ready = (conditions['signal_below_zero'] and 
                            conditions['macd_below_signal'] and  # MACD below signal (negative histogram)
                            self.can_enter_after_crossover and 
                            conditions['significant_change'] and 
                            conditions['signal_change'] < 0 and
                            conditions['significant_negative_histogram'])
                
        # Log MACD state in a clean, compact format
        print("\n📊 INDICATOR VALUES:")
        print(f"  MACD (Black): {conditions['macd_value']:.2f} | Signal (Red): {conditions['signal_value']:.2f}")
        
        # Current histogram value and change
        hist_current = conditions['hist_value']
        hist_previous = conditions['hist_prev']
        hist_change = hist_current - hist_previous
        
        # Create direction indicator
        if hist_change > 0:
            hist_direction = "▲"
        elif hist_change < 0:
            hist_direction = "▼"
        else:
            hist_direction = "◆"
            
        # Show histogram values and signal
        print(f"  Histogram: {hist_previous:.2f} → {hist_current:.2f} ({hist_direction} {hist_change:.2f})")
        print(f"  Min Histogram Required: ±{self.config['MIN_HISTOGRAM_VALUE']:.2f} | Status: {'✅' if ((conditions['histogram_positive'] and conditions['significant_positive_histogram']) or (conditions['histogram_negative'] and conditions['significant_negative_histogram'])) else '❌'}")
        
        # Show signal change
        signal_change = conditions['signal_change']
        if signal_change > 0:
            change_direction = "▲"
        elif signal_change < 0:
            change_direction = "▼"
        else:
            change_direction = "◆"
        print(f"  Signal Change: {change_direction} {signal_change:.2f} | Min Required: {self.config['MIN_SIGNAL_CHANGE']:.2f} | Status: {'✅' if conditions['significant_change'] else '❌'}")
        
        # Show Zero crossovers
        zero_cross = "✅" if (conditions['signal_zero_cross_up'] or conditions['signal_zero_cross_down'] or conditions['recent_zero_cross_up'] or conditions['recent_zero_cross_down']) else "❌"
        cross_type = ""
        if conditions['signal_zero_cross_up'] or conditions['recent_zero_cross_up']:
            cross_type = "Upward"
        elif conditions['signal_zero_cross_down'] or conditions['recent_zero_cross_down']:
            cross_type = "Downward"
            
        recent = "Recent" if (conditions['recent_zero_cross_up'] or conditions['recent_zero_cross_down']) else "Immediate" if (conditions['signal_zero_cross_up'] or conditions['signal_zero_cross_down']) else ""
        
        if zero_cross == "✅":
            print(f"  Zero Cross: {zero_cross} | Type: {recent} {cross_type}")
        else:
            print(f"  Zero Cross: {zero_cross}")
            
        # Print whether we can enter after crossover
        print(f"  Entry Ready: {'✅' if self.can_enter_after_crossover else '❌'}")
        
        # Print overall signal assessment
        if buy_signal_ready:
            print(f"\n🟢 LONG SIGNAL: All conditions met for a long position")
        elif sell_signal_ready:
            print(f"\n🔴 SHORT SIGNAL: All conditions met for a short position")
        else:
            # Show a concise reason why there's no signal
            if not self.can_enter_after_crossover:
                print(f"\n❌ NO SIGNAL: Waiting for confirmation candle after zero-line crossover")
            elif not (conditions['signal_above_zero'] or conditions['signal_below_zero']):
                print(f"\n❌ NO SIGNAL: Signal not above/below zero")
            elif not conditions['significant_change']:
                print(f"\n❌ NO SIGNAL: Signal change too small")
            elif not ((conditions['histogram_positive'] and conditions['significant_positive_histogram']) or 
                     (conditions['histogram_negative'] and conditions['significant_negative_histogram'])):
                print(f"\n❌ NO SIGNAL: Histogram not significant")
            else:
                print(f"\n❌ NO SIGNAL: Missing required conditions")
        
        # Check LONG entry conditions: 
        # 1. Signal line (red dotted) above zero
        # 2. MACD is above signal line (positive histogram)
        # 3. Histogram is significant (above MIN_HISTOGRAM_VALUE)
        # 4. We're after a crossover candle (can_enter_after_crossover is True)
        # 5. Signal line change is sufficient
        if buy_signal_ready:
            
            print("🔼 ENTRY SIGNAL: LONG - Signal above zero with MACD > Signal and sufficient change")
            
            # Calculate price levels for trade
            self._calculate_price_levels(mt5.ORDER_TYPE_BUY)
            
            # Return signal with price levels (BUY for long MACD strategy)
            signal_type = mt5.ORDER_TYPE_BUY
            entry_price = self.price_levels['entry']
            sl_price = self.price_levels['stop']
            tp_price = self.price_levels['tp']
            
            # Store the signal for next cycle
            self.prev_signal = signal_type
            self.last_trade_direction = "LONG"
            
            # Set flag to require next Signal line zero cross for re-entry
            self.awaiting_next_signal_zero_cross = True
            self.candles_since_exit = 0
            self.crossover_candle_time = None
            self.can_enter_after_crossover = False
            
            # Log entry details
            print(f"✅ Generated BUY signal: Entry={entry_price:.5f}, SL={sl_price:.5f}, TP={tp_price:.5f}")
            print(f"📏 Risk parameters: SL={self.config['SL_ATR_MULT']}x ATR, TP={self.config['TP_ATR_MULT']}x ATR")
            
            return signal_type, entry_price, sl_price, tp_price
            
        # Check SHORT entry conditions:
        # 1. Signal line (red dotted) below zero
        # 2. MACD is below signal line (negative histogram)
        # 3. Histogram is significant (below -MIN_HISTOGRAM_VALUE)
        # 4. We're after a crossover candle (can_enter_after_crossover is True)
        # 5. Signal line change is sufficient and negative
        if sell_signal_ready:
            
            print("🔽 ENTRY SIGNAL: SHORT - Signal below zero with MACD < Signal and sufficient change")
            
            # Calculate price levels for trade
            self._calculate_price_levels(mt5.ORDER_TYPE_SELL)
            
            # Return signal with price levels (SELL for short MACD strategy)
            signal_type = mt5.ORDER_TYPE_SELL
            entry_price = self.price_levels['entry']
            sl_price = self.price_levels['stop']
            tp_price = self.price_levels['tp']
            
            # Store the signal for next cycle
            self.prev_signal = signal_type
            self.last_trade_direction = "SHORT"
            
            # Set flag to require next Signal line zero cross for re-entry
            self.awaiting_next_signal_zero_cross = True
            self.candles_since_exit = 0
            self.crossover_candle_time = None
            self.can_enter_after_crossover = False
            
            # Log entry details
            print(f"✅ Generated SELL signal: Entry={entry_price:.5f}, SL={sl_price:.5f}, TP={tp_price:.5f}")
            print(f"📏 Risk parameters: SL={self.config['SL_ATR_MULT']}x ATR, TP={self.config['TP_ATR_MULT']}x ATR")
            
            return signal_type, entry_price, sl_price, tp_price
            
        print("⏳ No valid entry signal yet")
        return None
        
    def generate_exit_signal(self, position):
        """
        Generate exit signals based on MACD and Signal line relationship.
        
        For LONG positions:
        - Exit when MACD crosses below signal (histogram becomes negative), OR
        - Exit when MACD drops EXIT_THRESHOLD points below signal
        
        For SHORT positions:
        - Exit when MACD crosses above signal (histogram becomes positive), OR
        - Exit when MACD rises EXIT_THRESHOLD points above signal
        
        Args:
            position (mt5.PositionInfo): The open position object to evaluate
            
        Returns:
            bool: True if the position should be closed, False otherwise
        """
        # Make sure indicators are calculated
        self.calculate_indicators()
        
        # Get MACD conditions
        conditions = self._check_macd_conditions()
        if not conditions:
            return False
            
        # Determine position type (LONG or SHORT)
        is_long = position.type == mt5.POSITION_TYPE_BUY
        is_short = position.type == mt5.POSITION_TYPE_SELL
        
        # Get current MACD values
        macd_current = conditions['macd_value']
        signal_current = conditions['signal_value']
        
        # Calculate the histogram (difference between MACD and Signal)
        macd_signal_diff = macd_current - signal_current
        
        # Get exit threshold from config
        exit_threshold = self.config['EXIT_THRESHOLD']
        
        # Initialize exit signal and reason
        exit_signal = False
        exit_reason = ""
        
        # Check exit conditions based on position type
        if is_long:
            # For LONG positions:
            # 1. Exit when MACD crosses below signal (histogram becomes negative)
            # 2. Exit when MACD drops EXIT_THRESHOLD points below signal
            
            # Condition 1: MACD below signal
            standard_exit = macd_signal_diff < 0
            
            # Condition 2: MACD at least EXIT_THRESHOLD points below signal
            threshold_exit = macd_current < (signal_current - exit_threshold)
            
            if standard_exit:
                exit_signal = True
                exit_reason = "MACD crossed below signal line (histogram became negative)"
            elif threshold_exit:
                exit_signal = True
                exit_reason = f"MACD ({macd_current:.2f}) dropped {exit_threshold:.2f} points below signal ({signal_current:.2f})"
        
        elif is_short:
            # For SHORT positions:
            # 1. Exit when MACD crosses above signal (histogram becomes positive)
            # 2. Exit when MACD rises EXIT_THRESHOLD points above signal
            
            # Condition 1: MACD above signal
            standard_exit = macd_signal_diff > 0
            
            # Condition 2: MACD at least EXIT_THRESHOLD points above signal
            threshold_exit = macd_current > (signal_current + exit_threshold)
            
            if standard_exit:
                exit_signal = True
                exit_reason = "MACD crossed above signal line (histogram became positive)"
            elif threshold_exit:
                exit_signal = True
                exit_reason = f"MACD ({macd_current:.2f}) rose {exit_threshold:.2f} points above signal ({signal_current:.2f})"
        
        # Log the exit signal if we're exiting
        if exit_signal:
            position_type = "LONG" if is_long else "SHORT"
            direction = "🔽" if is_long else "🔼"
            print(f"{direction} EXIT SIGNAL ({position_type}): {exit_reason}")
            print(f"{direction} MACD: {macd_current:.2f} | Signal: {signal_current:.2f} | Diff: {macd_signal_diff:.2f}")
            print(f"{direction} Exit threshold: {exit_threshold:.2f}")
        else:
            # Print current status for monitoring
            position_type = "LONG" if is_long else "SHORT"
            print(f"📊 Position: {position_type} | MACD: {macd_current:.2f} | Signal: {signal_current:.2f} | Diff: {macd_signal_diff:.2f}")
            
            if is_long:
                print(f"📊 Exit conditions:")
                print(f"  - MACD below Signal: {'✅' if standard_exit else '❌'}")
                threshold_value = signal_current - exit_threshold
                print(f"  - MACD below threshold ({threshold_value:.2f}): {'✅' if threshold_exit else '❌'}")
            else:
                print(f"📊 Exit conditions:")
                print(f"  - MACD above Signal: {'✅' if standard_exit else '❌'}")
                threshold_value = signal_current + exit_threshold
                print(f"  - MACD above threshold ({threshold_value:.2f}): {'✅' if threshold_exit else '❌'}")
        
        return exit_signal
        
    def reset_signal_state(self):
        """Reset strategy internal state after position closing or failed orders."""
        # Record the time of the position close
        self.last_trade_close_time = get_server_time()
        print(f"🕒 Position closed at {self.last_trade_close_time}")
        
        # Set flag to await next Signal line zero cross and reset candle counter
        self.awaiting_next_signal_zero_cross = True
        self.candles_since_exit = 0
        self.crossover_candle_time = None
        self.can_enter_after_crossover = False
        
        # Call the parent class method to reset other state
        super().reset_signal_state() 