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

# ADX Breakout Strategy Configuration
ADX_BREAKOUT_CONFIG = {
    # ADX Parameters
    'ADX_SMOOTH_PERIOD': 14,       # ADX Smoothing Period
    'ADX_PERIOD': 14,              # ADX Period
    'ADX_LOWER_LEVEL': 18,         # ADX Lower Level (consolidation threshold)
    
    # Box and Risk Parameters
    'BOX_LOOKBACK': 20,            # Breakout Box Lookback Period
    'PROFIT_TARGET_MULTIPLE': .9,  # Profit Target Box Width Multiple
    'STOP_LOSS_MULTIPLE': 0.4,     # Stop Loss Box Width Multiple
    
    # Direction Control
    'ENABLE_DIRECTION': 0,         # Both(0), Long(1), Short(-1)
    
    # Override ATR-based SL/TP from generic_trader
    'USE_CUSTOM_SLTP': True,       # Use custom SL/TP calculation based on box width
    
    # Logging and Debugging
    'VERBOSE_LOGGING': False,      # Enable detailed logging
}

class AISlope4Strategy(BaseStrategy):
    """
    Rob Booker ADX Breakout Strategy
    
    This strategy is based on ADX (Average Directional Index) to identify consolidation periods
    and trades breakouts from these consolidations.
    
    Strategy Logic:
    1. When ADX drops below a threshold, the market is considered in consolidation
    2. A box is created around the highs and lows of the last N candles
    3. When price breaks outside of the box (close crosses above/below), a trade is taken
    4. Stop loss is placed at a percentage of the box size
    5. Profit target is placed at a multiple of the box size
    
    # === ADX BREAKOUT STRATEGY ===
    # Indicators: ADX(14)
    # - When ADX < threshold (18), market is in consolidation (low directional strength)
    # - Box is formed using highest high and lowest low of last 20 candles
    #
    # Long Entry:
    #   - ADX below threshold (in consolidation)
    #   - Price closes above the upper level of the box
    # Long Exit:
    #   - Profit target: Entry + (Box Width * Profit Multiple)
    #   - Stop loss: Entry - (Box Width * Stop Loss Multiple)
    #
    # Short Entry:
    #   - ADX below threshold (in consolidation)
    #   - Price closes below the lower level of the box
    # Short Exit:
    #   - Profit target: Entry - (Box Width * Profit Multiple)
    #   - Stop loss: Entry + (Box Width * Stop Loss Multiple)
    """
    
    def __init__(self, symbol, timeframe, symbol_info, strategy_config=None):
        """Initialize the strategy with default parameters"""
        super().__init__(symbol, timeframe, symbol_info, strategy_config)
        
        # Merge provided config with default config
        self.config = {**ADX_BREAKOUT_CONFIG, **(strategy_config or {})}
        
        # Strategy state variables
        self.data = pd.DataFrame()
        self.indicators = {}
        self.entry_decision = None
        self.price_levels = {'entry': None, 'stop': None, 'tp': None}
        self.last_processed_candle_time = None
        
        # ADX Breakout specific state tracking
        self.box_upper_level = None
        self.box_lower_level = None
        self.box_width = None
        self.is_adx_low = False
        self.in_position = False
        self.position_price = None
        self.position_type = None  # "LONG" or "SHORT"
        self.position_tickets = []  # List of open position tickets
        
        # Add flags for pending signals (to be executed on next candle)
        self.pending_buy_signal = False
        self.pending_sell_signal = False
        
        # Print strategy configuration
        self._print_config()
    
    def _print_config(self):
        """Print the current strategy configuration"""
        # Map MT5 timeframe to human-readable string
        timeframe_names = {
            mt5.TIMEFRAME_M1: "1 minute",
            mt5.TIMEFRAME_M5: "5 minutes",
            mt5.TIMEFRAME_M15: "15 minutes",
            mt5.TIMEFRAME_M30: "30 minutes",
            mt5.TIMEFRAME_H1: "1 hour",
            mt5.TIMEFRAME_H4: "4 hours",
            mt5.TIMEFRAME_D1: "1 day",
            mt5.TIMEFRAME_W1: "1 week",
            mt5.TIMEFRAME_MN1: "1 month"
        }
        timeframe_name = timeframe_names.get(self.timeframe, f"Unknown ({self.timeframe})")
        
        print("\n=== ADX BREAKOUT STRATEGY CONFIGURATION ===")
        print(f"Symbol: {self.symbol}")
        print(f"Timeframe: {timeframe_name}")
        print(f"ADX Smooth Period: {self.config['ADX_SMOOTH_PERIOD']}")
        print(f"ADX Period: {self.config['ADX_PERIOD']}")
        print(f"ADX Lower Level: {self.config['ADX_LOWER_LEVEL']}")
        print(f"Box Lookback: {self.config['BOX_LOOKBACK']}")
        print(f"Profit Target Multiple: {self.config['PROFIT_TARGET_MULTIPLE']}")
        print(f"Stop Loss Multiple: {self.config['STOP_LOSS_MULTIPLE']}")
        direction_map = {0: "Both", 1: "Long Only", -1: "Short Only"}
        print(f"Direction: {direction_map[self.config['ENABLE_DIRECTION']]}")
        print("===========================================\n")
    
    def get_required_data_count(self):
        """Return the minimum number of candles needed for this strategy"""
        # We need enough data for ADX calculation plus our box lookback
        adx_period = self.config['ADX_PERIOD']
        adx_smooth = self.config['ADX_SMOOTH_PERIOD']
        box_lookback = self.config['BOX_LOOKBACK']
        
        # Calculate minimum required bars
        required_bars = max(100, int(adx_period + adx_smooth + box_lookback + 20))
        
        # Set a reasonable maximum to avoid MT5 data retrieval errors
        MAX_SAFE_BARS = 1000
        if required_bars > MAX_SAFE_BARS:
            print(f"⚠️ Limiting data request from {required_bars} to {MAX_SAFE_BARS} bars to avoid MT5 errors")
            required_bars = MAX_SAFE_BARS
            
        return required_bars
    
    def update_position_status(self, open_positions):
        """
        Update internal position tracking state based on MT5 open positions.
        This matches TradingView's strategy.position_size behavior.
        
        Args:
            open_positions (list): List of open positions from MT5
        """
        previous_status = self.in_position
        
        if open_positions:
            self.in_position = True
            self.position_tickets = [pos.ticket for pos in open_positions]
            
            # Set position type based on first position
            pos_type = open_positions[0].type
            self.position_type = "LONG" if pos_type == mt5.POSITION_TYPE_BUY else "SHORT"
            
            # Store average position price
            total_volume = sum(pos.volume for pos in open_positions)
            weighted_price = sum(pos.price_open * pos.volume for pos in open_positions) / total_volume
            self.position_price = weighted_price
            
            # Log only if state changed or verbose logging enabled
            if not previous_status or self.config['VERBOSE_LOGGING']:
                print(f"🔹 Position status: IN POSITION ({self.position_type}) - {len(open_positions)} positions")
                print(f"🔹 Average entry price: {self.position_price:.2f}")
        else:
            # No open positions
            self.in_position = False
            self.position_tickets = []
            self.position_price = None
            self.position_type = None
            
            # Log only if state changed or verbose logging enabled
            if previous_status or self.config['VERBOSE_LOGGING']:
                print(f"🔹 Position status: NO OPEN POSITIONS")
                
        # Return whether status changed
        return previous_status != self.in_position
        
    def calculate_indicators(self):
        """
        Calculate ADX indicator values and box levels based on the latest data.
        Implementation is simplified for maximum reliability.
        """
        if self.data.empty or len(self.data) < (self.config['ADX_PERIOD'] + self.config['ADX_SMOOTH_PERIOD']):
            return
            
        # Get parameters from config
        adx_smooth_period = self.config['ADX_SMOOTH_PERIOD']
        adx_period = self.config['ADX_PERIOD']
        adx_lower_level = self.config['ADX_LOWER_LEVEL']
        box_lookback = self.config['BOX_LOOKBACK']
        
        # Get current server time for logging
        server_time = get_server_time()
        
        # === Calculate ADX using TA-Lib equivalent methods ===
        # Calculate True Range
        high = self.data['high']
        low = self.data['low']
        close = self.data['close']
        
        # True Range is max of (high-low, abs(high-prev_close), abs(low-prev_close))
        prev_close = close.shift(1).fillna(close)
        tr = pd.DataFrame({
            'hl': high - low,
            'hpc': (high - prev_close).abs(),
            'lpc': (low - prev_close).abs()
        }).max(axis=1)
        
        # Simple RMA/EMA implementation with alpha=1/period
        def rma(series, period):
            return series.ewm(alpha=1/period, min_periods=period, adjust=False).mean()
        
        # Directional Movement
        pos_dm = high.diff().clip(lower=0)
        neg_dm = low.diff().multiply(-1).clip(lower=0)
        
        # Where pos_dm > neg_dm and pos_dm > 0, else 0
        pos_dm = pd.Series(np.where((pos_dm > neg_dm) & (pos_dm > 0), pos_dm, 0), index=pos_dm.index)
        # Where neg_dm > pos_dm and neg_dm > 0, else 0
        neg_dm = pd.Series(np.where((neg_dm > pos_dm) & (neg_dm > 0), neg_dm, 0), index=neg_dm.index)
        
        # Smoothed values
        smoothed_tr = rma(tr, adx_period)
        smoothed_pos_dm = rma(pos_dm, adx_period)
        smoothed_neg_dm = rma(neg_dm, adx_period)
        
        # DI+ and DI-
        di_plus = 100 * smoothed_pos_dm / smoothed_tr
        di_minus = 100 * smoothed_neg_dm / smoothed_tr
        
        # DX and ADX
        dx = 100 * (di_plus - di_minus).abs() / (di_plus + di_minus)
        adx = rma(dx, adx_smooth_period)
        
        # Store ADX, DI+, DI- in indicators dictionary
        self.indicators['adx'] = adx
        self.indicators['di_plus'] = di_plus
        self.indicators['di_minus'] = di_minus
        
        # Check if ADX is below the lower level (consolidation)
        current_adx = self.indicators['adx'].iloc[-1]
        self.is_adx_low = current_adx < adx_lower_level
        
        # === TradingView Box Level Calculation ===
        # In TradingView: boxUpperLevel = strategy.position_size == 0 ? highest(high, boxLookBack)[1] : boxUpperLevel[1]
        # Only update box levels when not in a position, otherwise keep previous values
        if not self.in_position:
            # Log position status for clarity
            if self.config['VERBOSE_LOGGING']:
                print(f"🔹 No open positions - calculating box levels")
                
            old_upper = self.box_upper_level
            old_lower = self.box_lower_level
            
            if len(self.data) > box_lookback:
                # [1] in PineScript refers to the previous bar (offset by 1)
                # highest(high, boxLookBack)[1] means:
                #   1. Take the highest high over the lookback period
                #   2. Then get the value from the previous bar
                
                # First, get the range of bars for the lookback excluding the current bar
                # We need (lookback+1) bars: 1 for the [1] offset, and lookback for the range
                if len(self.data) >= (box_lookback + 1):
                    # Get lookback range ending at the previous bar (not including current)
                    prev_bar_idx = -2  # Index of the previous bar (-1 is current, -2 is previous)
                    lookback_start_idx = prev_bar_idx - box_lookback + 1
                    
                    # Get the slice of data for the lookback period
                    lookback_highs = self.data['high'].iloc[lookback_start_idx:prev_bar_idx+1]
                    lookback_lows = self.data['low'].iloc[lookback_start_idx:prev_bar_idx+1]
                    
                    # Calculate highest high and lowest low in this range
                    if not lookback_highs.empty and not lookback_lows.empty:
                        self.box_upper_level = lookback_highs.max()
                        self.box_lower_level = lookback_lows.min()
                        self.box_width = self.box_upper_level - self.box_lower_level
                        
                        # Add extra debug for box calculation
                        if self.config['VERBOSE_LOGGING']:
                            print(f"\nBox calculation details:")
                            print(f"Current bar index: -1, Previous bar index: -2")
                            print(f"Lookback range: {lookback_start_idx} to {prev_bar_idx}")
                            print(f"Lookback period high values: {list(lookback_highs)}")
                            print(f"Lookback period low values: {list(lookback_lows)}")
                            print(f"Highest high: {self.box_upper_level}")
                            print(f"Lowest low: {self.box_lower_level}")
                    
                    # Log box level changes if there's a significant change
                    if old_upper != self.box_upper_level or old_lower != self.box_lower_level:
                        if self.config['VERBOSE_LOGGING']:
                            print(f"Box updated: Upper={self.box_upper_level:.2f}, Lower={self.box_lower_level:.2f}")
        else:
            # In position - maintain current box levels (don't update)
            if self.config['VERBOSE_LOGGING']:
                print(f"🔹 In {self.position_type} position - keeping existing box levels")
        
        # Always print the essential information
        current_close = close.iloc[-1] if not close.empty else None
        if current_close is not None and self.box_upper_level is not None:
            # Check for crosses - EXACTLY like TradingView's cross() function
            prev_close = close.iloc[-2] if len(close) > 1 else current_close
            cross_above_upper = current_close > self.box_upper_level and prev_close <= self.box_upper_level
            cross_below_lower = current_close < self.box_lower_level and prev_close >= self.box_lower_level
            
            # Only print crosses
            if cross_above_upper:
                if self.is_adx_low:
                    print(f"📈 CROSS UP: {current_close:.2f} crossed above box upper {self.box_upper_level:.2f} - ADX LOW, Valid Signal")
                else:
                    print(f"📈 CROSS UP: {current_close:.2f} crossed above box upper {self.box_upper_level:.2f} - ADX HIGH, No Trade")
            if cross_below_lower:
                if self.is_adx_low:
                    print(f"📉 CROSS DOWN: {current_close:.2f} crossed below box lower {self.box_lower_level:.2f} - ADX LOW, Valid Signal")
                else:
                    print(f"📉 CROSS DOWN: {current_close:.2f} crossed below box lower {self.box_lower_level:.2f} - ADX HIGH, No Trade")
        
        # Print minimal but essential info
        adx_status = "LOW ✓" if self.is_adx_low else "HIGH ✗"
        position_status = f"IN {self.position_type}" if self.in_position else "NO POSITION"
        print(f"Upper={self.box_upper_level:.2f}, Lower={self.box_lower_level:.2f} | ADX={current_adx:.2f}/{adx_lower_level} ({adx_status}) | {position_status}")
    
    def update_data(self, new_data):
        """Updates the strategy's data and recalculates indicators"""
        if new_data is not None and not new_data.empty:
            self.data = new_data.copy()
            
            # Verify the data timeframe matches what's expected
            if len(self.data) > 2 and self.config['VERBOSE_LOGGING']:
                self._verify_data_timeframe()
                
            # Calculate indicators with the latest data
            self.calculate_indicators()
    
    def _verify_data_timeframe(self):
        """Verify that the data timeframe matches the expected timeframe"""
        try:
            # Get the expected timeframe in minutes
            timeframe_names = {
                mt5.TIMEFRAME_M1: 1,
                mt5.TIMEFRAME_M5: 5,
                mt5.TIMEFRAME_M15: 15,
                mt5.TIMEFRAME_M30: 30,
                mt5.TIMEFRAME_H1: 60,
                mt5.TIMEFRAME_H4: 240,
                mt5.TIMEFRAME_D1: 1440,
            }
            expected_minutes = timeframe_names.get(self.timeframe, 0)
            
            if expected_minutes == 0:
                return  # Unknown timeframe, can't verify
            
            # Calculate the average time difference between candles (in minutes)
            time_diffs = []
            for i in range(1, min(10, len(self.data))):
                # Calculate difference in minutes
                current = self.data.index[-i]
                previous = self.data.index[-i-1]
                diff_minutes = (current - previous).total_seconds() / 60
                time_diffs.append(diff_minutes)
            
            avg_diff = sum(time_diffs) / len(time_diffs)
            min_diff = min(time_diffs)
            max_diff = max(time_diffs)
            
            # Check if the diff is roughly what we expect
            tolerance = 0.1  # 10% tolerance
            is_match = abs(avg_diff - expected_minutes) / expected_minutes < tolerance
            
            # Print detailed timeframe information 
            print(f"\n⏱️ TIMEFRAME VERIFICATION:")
            print(f"⏱️ Configured timeframe: {expected_minutes} minutes")
            print(f"⏱️ Actual data timeframe: avg={avg_diff:.1f} min (range: {min_diff:.1f}-{max_diff:.1f} min)")
            print(f"⏱️ Timeframe match: {'✅' if is_match else '❌'}")
            
            if not is_match:
                print(f"⚠️ WARNING: Data timeframe ({avg_diff:.1f} min) does not match configured timeframe ({expected_minutes} min)")
                print(f"⚠️ This may cause the strategy to behave differently than expected!")
        
        except Exception as e:
            print(f"❌ Error verifying timeframe: {e}")
    
    def _calculate_price_levels(self, trade_type):
        """
        Calculate entry, stop loss, and take profit prices based on box width,
        matching the PineScript implementation exactly.
        
        In PineScript:
        profitTarget = strategy.position_size > 0 ? strategy.position_avg_price + profitTargetMultiple*boxWidth 
                   : strategy.position_size < 0 ? strategy.position_avg_price - profitTargetMultiple*boxWidth : na
        stopLoss = strategy.position_size > 0 ? strategy.position_avg_price - stopLossMultiple*boxWidth 
                : strategy.position_size < 0 ? strategy.position_avg_price + stopLossMultiple*boxWidth : na
        
        Args:
            trade_type: mt5.ORDER_TYPE_BUY or mt5.ORDER_TYPE_SELL
        """
        if self.box_width is None:
            return None
            
        # Get the latest close price for entry
        close_price = self.data['close'].iloc[-1]
        
        # Get multipliers from config
        sl_mult = self.config['STOP_LOSS_MULTIPLE']
        tp_mult = self.config['PROFIT_TARGET_MULTIPLE']
        
        # Calculate price levels based on trade type
        entry = close_price  # Use close price for entry
        
        if trade_type == mt5.ORDER_TYPE_BUY:
            # Long trade: SL below entry, TP above entry
            stop = entry - sl_mult * self.box_width
            tp = entry + tp_mult * self.box_width
        else:
            # Short trade: SL above entry, TP below entry
            stop = entry + sl_mult * self.box_width
            tp = entry - tp_mult * self.box_width
            
        # Store the price levels
        self.price_levels = {
            'entry': entry,
            'stop': stop,
            'tp': tp
        }
        
        # Log price levels minimally
        print(f"Entry={entry:.2f}, SL={stop:.2f} ({sl_mult}x box width), TP={tp:.2f} ({tp_mult}x box width)")
            
        return self.price_levels
        
    def generate_entry_signal(self, open_positions=None):
        """
        Generate entry signals based on price breaking out of the consolidation box
        when ADX is below the threshold.
        
        IMPORTANT: The strategy only trades when there are NO open positions,
        exactly matching TradingView's behavior using strategy.position_size == 0.
        
        Args:
            open_positions (list, optional): List of currently open positions
            
        Returns:
            tuple or None: (signal_type, entry_price, sl_price, tp_price) or None
        """
        # Update position status (matches TradingView's strategy.position_size)
        position_changed = self.update_position_status(open_positions)
        
        # =================================================================
        # CRITICAL: Skip if we have open positions (strategy.position_size != 0)
        # =================================================================
        if self.in_position:
            print(f"🔒 No new trades allowed: Position already open ({self.position_type})")
            return None
            
        # Double-check open_positions manually (equivalent to strategy.opentrades == 0)
        if open_positions and len(open_positions) > 0:
            print(f"🔒 No new trades allowed: {len(open_positions)} positions already open")
            return None
        
        # Skip if we're missing necessary data or indicators
        if self.data.empty or 'adx' not in self.indicators:
            return None
        
        # Get server time and candle boundaries    
        server_time = get_server_time()
        current_candle_start, current_candle_end = get_candle_boundaries(server_time, self.timeframe)
        
        # Check if this is a new candle since our last check
        is_new_candle = False
        if self.last_processed_candle_time is None:
            is_new_candle = True
        else:
            last_candle_start, _ = get_candle_boundaries(self.last_processed_candle_time, self.timeframe)
            if current_candle_start > last_candle_start:
                is_new_candle = True
                
        # Only process signals at the start of new candles
        # This ensures we're checking for crossovers exactly once per candle
        if is_new_candle:
            # Update the last processed candle time 
            self.last_processed_candle_time = current_candle_start
            
            # Skip if box levels not calculated
            if self.box_upper_level is None or self.box_lower_level is None:
                return None
            
            # Get latest price data for crossover detection (current & previous bar)
            current_close = self.data['close'].iloc[-1]
            previous_close = self.data['close'].iloc[-2] if len(self.data) > 1 else current_close
            
            # Check current ADX value
            current_adx = self.indicators['adx'].iloc[-1]
            self.is_adx_low = current_adx < self.config['ADX_LOWER_LEVEL']
            
            # Check direction settings
            enable_direction = self.config['ENABLE_DIRECTION']
            can_go_long = enable_direction == 0 or enable_direction == 1
            can_go_short = enable_direction == 0 or enable_direction == -1
            
            # Check for breakouts - EXACTLY match TradingView's cross() function
            # cross(a, b) = a[0] > b[0] and a[1] <= b[1]
            
            # Long entry: cross(close, boxUpperLevel) - EXACT PineScript implementation
            cross_above_upper = current_close > self.box_upper_level and previous_close <= self.box_upper_level
            
            # Short entry: cross(close, boxLowerLevel) - EXACT PineScript implementation 
            cross_below_lower = current_close < self.box_lower_level and previous_close >= self.box_lower_level
            
            # EXACTLY matching TradingView's logic:
            # isBuyValid = strategy.position_size == 0 and cross(close, boxUpperLevel) and isADXLow
            # isSellValid = strategy.position_size == 0 and cross(close, boxLowerLevel) and isADXLow
            is_buy_valid = cross_above_upper and self.is_adx_low and can_go_long
            is_sell_valid = cross_below_lower and self.is_adx_low and can_go_short
            
            if is_buy_valid:
                print(f"🔼 LONG SIGNAL: Price {current_close:.2f} crossed above box upper {self.box_upper_level:.2f} with ADX {current_adx:.2f} < {self.config['ADX_LOWER_LEVEL']} (Consolidation)")
                print(f"✅ NO OPEN POSITIONS - New trade allowed")
                
                # Calculate price levels for trade
                self._calculate_price_levels(mt5.ORDER_TYPE_BUY)
                
                # Return long signal with price levels
                signal_type = mt5.ORDER_TYPE_BUY
                entry_price = self.price_levels['entry']
                sl_price = self.price_levels['stop']
                tp_price = self.price_levels['tp']
                
                # Mark that we're now in a position
                self.in_position = True
                self.position_price = entry_price
                self.position_type = "LONG"
                
                # Add a flag to tell the generic trader to use our custom SL/TP
                self.use_custom_sltp = self.config.get('USE_CUSTOM_SLTP', True)
                
                return signal_type, entry_price, sl_price, tp_price
                
            elif is_sell_valid:
                print(f"🔽 SHORT SIGNAL: Price {current_close:.2f} crossed below box lower {self.box_lower_level:.2f} with ADX {current_adx:.2f} < {self.config['ADX_LOWER_LEVEL']} (Consolidation)")
                print(f"✅ NO OPEN POSITIONS - New trade allowed")
                
                # Calculate price levels for trade
                self._calculate_price_levels(mt5.ORDER_TYPE_SELL)
                
                # Return short signal with price levels
                signal_type = mt5.ORDER_TYPE_SELL
                entry_price = self.price_levels['entry']
                sl_price = self.price_levels['stop']
                tp_price = self.price_levels['tp']
                
                # Mark that we're now in a position
                self.in_position = True
                self.position_price = entry_price
                self.position_type = "SHORT"
                
                # Add a flag to tell the generic trader to use our custom SL/TP
                self.use_custom_sltp = self.config.get('USE_CUSTOM_SLTP', True)
                
                return signal_type, entry_price, sl_price, tp_price
        
        # Always print the current box & ADX status for the most recent bar
        if not self.data.empty and 'adx' in self.indicators:
            current_adx = self.indicators['adx'].iloc[-1]
            adx_status = "LOW ✓" if self.is_adx_low else "HIGH ✗" 
            position_status = f"IN {self.position_type}" if self.in_position else "NO POSITION"
            
            if self.box_upper_level is not None and self.box_lower_level is not None:
                print(f"Upper={self.box_upper_level:.2f}, Lower={self.box_lower_level:.2f} | ADX={current_adx:.2f}/{self.config['ADX_LOWER_LEVEL']} ({adx_status}) | {position_status}")
        
        # No valid signal
        return None
    
    def generate_exit_signal(self, position):
        """
        Generate exit signals based on take profit and stop loss levels.
        This strategy uses fixed TP/SL levels set at entry, so we don't need
        dynamic exit conditions.
        
        Args:
            position (mt5.PositionInfo): The open position object to evaluate
            
        Returns:
            bool: True if the position should be closed, False otherwise
        """
        # This strategy uses fixed TP/SL levels set at entry
        # The generic_trader.py will handle the TP/SL exits automatically
        return False
    
    def reset_signal_state(self):
        """Reset strategy internal state after position closing or failed orders."""
        # Reset position tracking flag
        old_position_status = self.in_position
        old_position_type = self.position_type
        
        self.in_position = False
        self.position_price = None
        self.position_type = None
        self.position_tickets = []
        
        # Log position closure if there was a position
        if old_position_status:
            print(f"🔹 Position closed: {old_position_type} position has been closed")
        
        # Call the parent class method to reset other state
        super().reset_signal_state() 