import MetaTrader5 as mt5
import pandas as pd
import numpy as np
from strategies.base_strategy import BaseStrategy
import sys
import os
from datetime import datetime, timedelta

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
    'SL_ATR_MULT': 2.0,             # Stop loss multiplier of ATR
    'TP_ATR_MULT': 4.0,             # Take profit multiplier of ATR (2:1 reward-risk ratio)
    
    # MACD Configuration
    'MACD_FAST_LENGTH': 2,          # Fast length for MACD calculation
    'MACD_SLOW_LENGTH': 8,          # Slow length for MACD calculation
    'MACD_SIGNAL_SMOOTHING': 5,     # Signal line smoothing period
    
    # Slope/Trend Filters
    'SLOPE_CHECK_CANDLES': 3,       # Number of candles to measure MACD slope
    'MIN_SLOPE_THRESHOLD': 0.00001, # Minimum allowed MACD slope
    
    # Trading Behavior
    'WAIT_CANDLES_AFTER_EXIT': 3,   # Candles to wait after exit before re-entry
}

# Example command to run with custom MACD parameters:
# python generic_trader.py EURUSD --strategy ai_slop_2 --volume 0.01 --config '{"MACD_FAST_LENGTH": 2, "MACD_SLOW_LENGTH": 8, "MACD_SIGNAL_SMOOTHING": 5}'

# Example command with slope parameters:
# python generic_trader.py EURUSD --strategy ai_slop_2 --volume 0.01 --config '{"SLOPE_CHECK_CANDLES": 3, "MIN_SLOPE_THRESHOLD": 0.00002}'

class AISlope2Strategy(BaseStrategy):
    """
    MACD Zero-Line Momentum Crossover Strategy
    
    This strategy enters after a complete MACD crossover candle has formed (waits for confirmation).
    It exits when the histogram becomes negative (for longs) or positive (for shorts).
    
    It checks the slope of the MACD line to ensure there's sufficient directional movement
    before entering a trade, avoiding flat/choppy markets.
    
    # === MACD Zero-Line Momentum Crossover Strategy ===
    # Indicators: MACD(2, 8, 5) - configurable parameters
    # Long Entry: After a complete candle where MACD crosses above 0, with:
    #   - Rising histogram 
    #   - MACD > Signal
    #   - Sufficient positive MACD slope (not too flat over the last N candles)
    # Long Exit: When histogram becomes negative (MACD crosses below signal line)
    #
    # Short Entry: After a complete candle where MACD crosses below 0, with:
    #   - Falling histogram
    #   - MACD < Signal
    #   - Sufficient negative MACD slope (not too flat over the last N candles)
    # Short Exit: When histogram becomes positive (MACD crosses above signal line)
    #
    # Re-entry: Only after MACD crosses zero again, with a complete confirmation candle
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
        self.awaiting_next_macd_zero_cross = False
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
        self._calculate_macd_slope()
    
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
    
    def _calculate_macd_slope(self):
        """Calculate the slope of the MACD line over recent candles"""
        if 'macd' not in self.indicators or len(self.indicators['macd']) < self.config['SLOPE_CHECK_CANDLES']:
            self.indicators['macd_slope'] = 0
            return
            
        # Get last N candles of MACD values for slope calculation
        n_candles = self.config['SLOPE_CHECK_CANDLES']
        macd_values = self.indicators['macd'].iloc[-n_candles:].values
        
        # Calculate slope using numpy's polyfit (linear regression)
        # x values are just the indices [0, 1, 2, ...] representing time periods
        x = np.arange(n_candles)
        slope, _ = np.polyfit(x, macd_values, 1)
        
        # Store the slope
        self.indicators['macd_slope'] = slope
        
        # Log the slope value for debugging
        print(f"📉 MACD Slope over {n_candles} candles: {slope:.8f}")
    
    def update_data(self, new_data):
        """Updates the strategy's data and recalculates indicators"""
        if new_data is not None and not new_data.empty:
            self.data = new_data.copy()
            self.calculate_indicators()
    
    def _check_macd_conditions(self):
        """Check MACD conditions for entry and exit decisions"""
        if self.data.empty or 'macd' not in self.indicators:
            return None
            
        # Get current and previous MACD values
        macd_current = self.indicators['macd'].iloc[-1]
        macd_previous = self.indicators['macd'].iloc[-2] if len(self.indicators['macd']) > 1 else 0
        
        # Get current and previous histogram values
        hist_current = self.indicators['histogram'].iloc[-1]
        hist_previous = self.indicators['histogram'].iloc[-2] if len(self.indicators['histogram']) > 1 else 0
        
        # Get current signal line value
        signal_current = self.indicators['signal'].iloc[-1]
        
        # Get MACD slope if available
        macd_slope = self.indicators.get('macd_slope', 0)
        
        # Check if slope meets minimum threshold (absolute value for short trades)
        min_slope = self.config['MIN_SLOPE_THRESHOLD']
        sufficient_slope = abs(macd_slope) >= min_slope
        
        # Calculate key conditions for long trades
        macd_zero_cross_up = macd_previous < 0 and macd_current >= 0
        macd_above_zero = macd_current > 0
        histogram_rising = hist_current > hist_previous
        histogram_falling = hist_current < hist_previous
        histogram_positive = hist_current > 0
        histogram_negative = hist_current < 0
        macd_above_signal = macd_current > signal_current
        macd_below_signal = macd_current < signal_current
        
        # Calculate key conditions for short trades
        macd_zero_cross_down = macd_previous > 0 and macd_current <= 0
        macd_below_zero = macd_current < 0
        
        # Return all conditions as a dictionary
        return {
            # Long conditions
            'macd_zero_cross_up': macd_zero_cross_up,
            'macd_above_zero': macd_above_zero,
            'histogram_rising': histogram_rising,
            'histogram_positive': histogram_positive,
            'macd_above_signal': macd_above_signal,
            
            # Short conditions
            'macd_zero_cross_down': macd_zero_cross_down,
            'macd_below_zero': macd_below_zero,
            'histogram_falling': histogram_falling,
            'histogram_negative': histogram_negative,
            'macd_below_signal': macd_below_signal,
            
            # Common values
            'macd_value': macd_current,
            'signal_value': signal_current,
            'hist_value': hist_current,
            'hist_prev': hist_previous,
            'macd_prev': macd_previous,
            'macd_slope': macd_slope,
            'sufficient_slope': sufficient_slope
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
        Only enters after a complete crossover candle has formed.
        
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
        if self.awaiting_next_macd_zero_cross:
            if conditions['macd_zero_cross_up'] or conditions['macd_zero_cross_down']:
                cross_type = "up" if conditions['macd_zero_cross_up'] else "down"
                print(f"🔄 MACD crossed {cross_type} zero line - resetting re-entry lock")
                self.awaiting_next_macd_zero_cross = False
                # Record the crossover candle time - we'll enter on the next candle
                self.crossover_candle_time = current_candle_start
                print(f"📝 MACD Crossover detected at {self.crossover_candle_time} - waiting for candle completion")
                # We'll wait for the next candle before entering
                self.can_enter_after_crossover = False
                return None
            else:
                print("⏳ Waiting for MACD to cross zero line before new entry")
                return None
        
        # Check if we've seen a crossover in this candle
        if conditions['macd_zero_cross_up'] or conditions['macd_zero_cross_down']:
            # Record the crossover candle time - we'll enter on the next candle
            self.crossover_candle_time = current_candle_start
            cross_type = "above" if conditions['macd_zero_cross_up'] else "below"
            print(f"📝 MACD Crossover {cross_type} zero detected at {self.crossover_candle_time} - waiting for candle completion")
            # We'll wait for the next candle before entering
            self.can_enter_after_crossover = False
            return None
            
        # If a crossover was detected on a previous candle and we have a new candle now, allow entry
        if self.crossover_candle_time is not None and is_new_candle:
            previous_candle_start, _ = get_candle_boundaries(self.crossover_candle_time, self.timeframe)
            if current_candle_start > previous_candle_start:
                print(f"✅ Crossover candle complete - ready to enter on this candle")
                self.can_enter_after_crossover = True
        
        # Evaluate buy/sell signal criteria
        buy_signal_ready = (conditions['macd_above_zero'] and 
                           conditions['histogram_rising'] and 
                           conditions['macd_above_signal'] and 
                           self.can_enter_after_crossover and 
                           conditions['sufficient_slope'] and 
                           conditions['macd_slope'] > 0)
        
        sell_signal_ready = (conditions['macd_below_zero'] and 
                            conditions['histogram_falling'] and 
                            conditions['macd_below_signal'] and 
                            self.can_enter_after_crossover and 
                            conditions['sufficient_slope'] and 
                            conditions['macd_slope'] < 0)
                
        # Log MACD state for analysis
        print("\n🔍 MACD ANALYSIS:")
        print(f"  - MACD: {conditions['macd_value']:.6f} {'✅ Above Zero' if conditions['macd_above_zero'] else '❌ Below Zero'}")
        print(f"  - Signal: {conditions['signal_value']:.6f}")
        print(f"  - Histogram: {conditions['hist_value']:.6f} {'✅ Rising' if conditions['histogram_rising'] else '❌ Falling'}")
        print(f"  - MACD > Signal: {'✅ Yes' if conditions['macd_above_signal'] else '❌ No'}")
        print(f"  - MACD < Signal: {'✅ Yes' if conditions['macd_below_signal'] else '❌ No'}")
        print(f"  - Zero-Line Crossover Up: {'✅ Yes' if conditions['macd_zero_cross_up'] else '❌ No'}")
        print(f"  - Zero-Line Crossover Down: {'✅ Yes' if conditions['macd_zero_cross_down'] else '❌ No'}")
        print(f"  - Entry Ready After Crossover: {'✅ Yes' if self.can_enter_after_crossover else '❌ No'}")
        print(f"  - MACD Slope: {conditions['macd_slope']:.8f} {'✅ Sufficient' if conditions['sufficient_slope'] else '❌ Too flat'}")
        
        # Print overall signal assessment
        if buy_signal_ready:
            print(f"🟢 BUY SIGNAL READY: All conditions met for a long position")
        elif sell_signal_ready:
            print(f"🔴 SELL SIGNAL READY: All conditions met for a short position")
        else:
            # Determine which conditions are preventing signal
            if not self.can_enter_after_crossover:
                print(f"⏳ NO SIGNAL YET: Waiting for confirmation candle after zero-line crossover")
            elif conditions['macd_above_zero'] and conditions['macd_slope'] > 0:
                print(f"⌛ POTENTIAL BUY: Missing conditions for long entry")
            elif conditions['macd_below_zero'] and conditions['macd_slope'] < 0:
                print(f"⌛ POTENTIAL SELL: Missing conditions for short entry")
            else:
                print(f"❌ NO SIGNAL: Conditions don't align for either buy or sell")
        
        # Check LONG entry conditions: 
        # 1. MACD above zero
        # 2. Histogram is rising
        # 3. MACD is above signal line
        # 4. We're after a crossover candle (can_enter_after_crossover is True)
        # 5. MACD slope is sufficient (not too flat)
        if buy_signal_ready:
            
            print("🔼 ENTRY SIGNAL: LONG - MACD above zero with rising histogram and sufficient slope after crossover confirmation")
            
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
            
            # Set flag to require next MACD zero cross for re-entry
            self.awaiting_next_macd_zero_cross = True
            self.candles_since_exit = 0
            self.crossover_candle_time = None
            self.can_enter_after_crossover = False
            
            # Log entry details
            print(f"✅ Generated BUY signal: Entry={entry_price:.5f}, SL={sl_price:.5f}, TP={tp_price:.5f}")
            print(f"📏 Risk parameters: SL={self.config['SL_ATR_MULT']}x ATR, TP={self.config['TP_ATR_MULT']}x ATR")
            
            return signal_type, entry_price, sl_price, tp_price
            
        # Check SHORT entry conditions:
        # 1. MACD below zero
        # 2. Histogram is falling
        # 3. MACD is below signal line
        # 4. We're after a crossover candle (can_enter_after_crossover is True)
        # 5. MACD slope is sufficient (not too flat) and negative
        if sell_signal_ready:
            
            print("🔽 ENTRY SIGNAL: SHORT - MACD below zero with falling histogram and sufficient slope after crossover confirmation")
            
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
            
            # Set flag to require next MACD zero cross for re-entry
            self.awaiting_next_macd_zero_cross = True
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
        Generate exit signals based on MACD histogram momentum change.
        Exit when the histogram stops increasing (for longs) or stops decreasing (for shorts).
        Exits are only triggered at the start of a new candle.
        
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
        
        # Check if this is a new candle
        server_time = get_server_time()
        current_candle_start, current_candle_end = get_candle_boundaries(server_time, self.timeframe)
        
        # Calculate how far we are into the current candle
        time_since_candle_open = (server_time - current_candle_start).total_seconds()
        candle_total_seconds = (current_candle_end - current_candle_start).total_seconds()
        candle_percent_complete = (time_since_candle_open / candle_total_seconds) * 100
        
        # Only consider exits at the beginning of a new candle (first 20% of candle time)
        if candle_percent_complete > 20:
            print(f"📊 Not checking exit conditions - {candle_percent_complete:.1f}% into current candle (exits only in first 20% of candle)")
            return False
            
        # Determine position type (LONG or SHORT)
        is_long = position.type == mt5.POSITION_TYPE_BUY
        is_short = position.type == mt5.POSITION_TYPE_SELL
        
        # Get current and previous histogram values
        hist_current = conditions['hist_value']
        hist_previous = conditions['hist_prev']
        
        # Only process an exit once per candle
        if self.last_processed_candle_time == current_candle_start:
            # We've already checked this candle for exit signals
            # Print current status for monitoring
            position_type = "LONG" if is_long else "SHORT"
            print(f"📊 MACD Status ({position_type}): Already checked this candle for exit signals")
            return False
            
        # We're at a new candle - update processed candle time and check exit conditions
        self.last_processed_candle_time = current_candle_start
        print(f"🔄 Checking exit conditions at start of new candle ({current_candle_start})")
        
        if is_long:
            # For LONG positions: exit when histogram stops increasing (turns downward)
            histogram_decreasing = hist_current < hist_previous
            
            if histogram_decreasing:
                print(f"🔽 EXIT SIGNAL (LONG): Histogram momentum changed to decreasing")
                print(f"🔽 Histogram: current={hist_current:.6f}, previous={hist_previous:.6f}")
                print(f"🔽 MACD={conditions['macd_value']:.6f}, Signal={conditions['signal_value']:.6f}")
                return True
        
        elif is_short:
            # For SHORT positions: exit when histogram stops decreasing (turns upward)
            histogram_increasing = hist_current > hist_previous
            
            if histogram_increasing:
                print(f"🔼 EXIT SIGNAL (SHORT): Histogram momentum changed to increasing")
                print(f"🔼 Histogram: current={hist_current:.6f}, previous={hist_previous:.6f}")
                print(f"🔼 MACD={conditions['macd_value']:.6f}, Signal={conditions['signal_value']:.6f}")
                return True
        
        # Print current status for monitoring
        position_type = "LONG" if is_long else "SHORT"
        print(f"📊 MACD Status ({position_type}): MACD={conditions['macd_value']:.6f} Signal={conditions['signal_value']:.6f}")
        print(f"📊 Histogram: current={hist_current:.6f}, previous={hist_previous:.6f}, delta={hist_current-hist_previous:.6f}")
        
        if is_long:
            print(f"📊 Exit condition: Histogram decreasing={'Yes' if hist_current < hist_previous else 'No'}")
        else:
            print(f"📊 Exit condition: Histogram increasing={'Yes' if hist_current > hist_previous else 'No'}")
        
        return False
        
    def reset_signal_state(self):
        """Reset strategy internal state after position closing or failed orders."""
        # Record the time of the position close
        self.last_trade_close_time = get_server_time()
        print(f"🕒 Position closed at {self.last_trade_close_time}")
        
        # Set flag to await next MACD zero cross and reset candle counter
        self.awaiting_next_macd_zero_cross = True
        self.candles_since_exit = 0
        self.crossover_candle_time = None
        self.can_enter_after_crossover = False
        
        # Call the parent class method to reset other state
        super().reset_signal_state() 