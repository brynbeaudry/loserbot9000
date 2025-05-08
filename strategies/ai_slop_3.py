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
    from generic_trader import get_candle_boundaries, get_server_time, IndicatorCalculator
except ImportError:
    raise ImportError("Could not import required functions from generic_trader.py")

# AI Slop 3 Strategy Configuration - Market Structure Based
AI_SLOP_3_CONFIG = {
    # Risk and Money Management
    'RISK_PERCENT': 0.01,           # 1% risk per trade
    'SL_ATR_MULT': 1.0,             # Stop loss multiplier of ATR
    'TP_ATR_MULT': 2.0,             # Take profit multiplier of ATR
    
    # Market Structure Parameters
    'SWING_LOOKBACK': 3,           # Candles to look back for swing points
    'MIN_SWING_SIZE_ATR': 0.2,      # Minimum swing size as ATR multiple
    'CONSECUTIVE_HIGHS': 2,         # Number of consecutive higher highs needed
    'CONSECUTIVE_LOWS': 2,          # Number of consecutive lower lows needed
    'USE_CLOSE_PRICE': True,        # Use closing prices for swing detection instead of highs/lows
    
    # EMA Configuration
    'FAST_EMA': 8,                  # Fast EMA period (8 by default)
    'SLOW_EMA': 25,                 # Slow EMA period (25 by default)
    
    # Trading Behavior
    'WAIT_CANDLES_AFTER_EXIT': 3,   # Candles to wait after exit before re-entry
    
    # Data Analysis
    'REQUIRED_DATA_CANDLES': 50,   # Minimum candles required for analysis
}

class AISlope3Strategy(BaseStrategy):
    """
    AI Slope 3 Strategy based on EMA and Market Structure.
    
    This strategy focuses on identifying higher highs and lower lows to determine market direction,
    using EMAs to confirm the trend. It looks for strong alignment between multiple factors:
    
    Key features:
    1. EMA crossover and directional movement for trend confirmation
    2. Market structure analysis (higher highs, lower lows)
    3. Short-term price direction analysis
    4. Strategic entry based on trend alignment of multiple factors
    """
    
    def __init__(self, symbol, timeframe, symbol_info, strategy_config=None):
        """Initialize the strategy with default parameters"""
        super().__init__(symbol, timeframe, symbol_info, strategy_config)
        
        # Merge provided config with default config
        self.config = {**AI_SLOP_3_CONFIG, **(strategy_config or {})}
        
        # State variables
        self.data = pd.DataFrame()
        self.indicators = {}
        self.market_structure = {}
        self.entry_decision = None
        self.price_levels = {'entry': None, 'stop': None, 'tp': None}
        self.last_processed_candle_time = None
        self.last_trade_close_time = None
        self.candles_since_exit = 0
    
    def get_required_data_count(self):
        """Return the minimum number of candles needed for this strategy"""
        return self.config['REQUIRED_DATA_CANDLES']
    
    def calculate_indicators(self):
        """Calculate required indicators based on the latest data"""
        if self.data.empty or len(self.data) < 50:  # Need minimum data
            return False
            
        # Calculate ATR for risk management and swing identification
        self.indicators['atr'] = self._calculate_atr(self.data)
        
        # Calculate EMAs for trend identification
        fast_ema_period = self.config['FAST_EMA']
        slow_ema_period = self.config['SLOW_EMA']
        
        self.indicators[f'ema{fast_ema_period}'] = self._calculate_ema(self.data['close'], fast_ema_period)
        self.indicators[f'ema{slow_ema_period}'] = self._calculate_ema(self.data['close'], slow_ema_period)
        
        # Analyze market structure (swing highs/lows)
        self._analyze_market_structure()
        
        return True
    
    def _calculate_ema(self, prices, period):
        """Calculate Exponential Moving Average"""
        if len(prices) < period:
            return pd.Series(index=prices.index, dtype='float64')
        return prices.ewm(span=period, adjust=False).mean()
    
    def _calculate_atr(self, ohlc_data, period=14):
        """Calculate Average True Range (ATR)"""
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
    
    def _analyze_market_structure(self):
        """
        Analyze market structure by identifying swing highs and lows,
        then detecting higher highs, lower lows patterns.
        """
        if self.data.empty or len(self.data) < self.config['SWING_LOOKBACK'] * 2:
            return
            
        # Get parameters
        lookback = self.config['SWING_LOOKBACK']
        min_swing_size = self.config['MIN_SWING_SIZE_ATR'] * self.indicators['atr'].iloc[-1]
        
        # Identify swing highs and lows
        highs, lows = self._find_swing_points(lookback, min_swing_size)
        
        # Get the current price data index to help determine recency
        current_index = len(self.data) - 1
        
        # Determine the most recent swing point by comparing distance from current index
        most_recent_high_index = None
        most_recent_low_index = None
        most_recent_high_distance = float('inf')
        most_recent_low_distance = float('inf')
        
        for idx, _ in highs:
            distance = current_index - idx
            if distance < most_recent_high_distance:
                most_recent_high_distance = distance
                most_recent_high_index = idx
                
        for idx, _ in lows:
            distance = current_index - idx
            if distance < most_recent_low_distance:
                most_recent_low_distance = distance
                most_recent_low_index = idx
        
        # Determine which is more recent - the closest high or the closest low
        last_swing = 'none'
        if most_recent_high_index is not None and most_recent_low_index is not None:
            if most_recent_high_distance < most_recent_low_distance:
                last_swing = 'high'
            else:
                last_swing = 'low'
        elif most_recent_high_index is not None:
            last_swing = 'high'
        elif most_recent_low_index is not None:
            last_swing = 'low'
            
        # Get the last swing high/low for reference
        last_swing_high = highs[-1] if len(highs) > 0 else None
        last_swing_low = lows[-1] if len(lows) > 0 else None
        
        # Analyze short-term price direction (last 5 candles)
        # This helps identify emerging trends even before swing points form
        short_term_direction = 'neutral'
        if len(self.data) >= 5:
            # Get the last 5 closes
            last_5_closes = self.data['close'].iloc[-5:].values
            
            # Calculate the linear regression slope
            x = np.arange(len(last_5_closes))
            slope, _, _, _, _ = np.polyfit(x, last_5_closes, 1, full=True)
            
            # Normalize the slope relative to the average price
            avg_price = np.mean(last_5_closes)
            norm_slope = slope[0] / avg_price * 100  # As percentage of average price
            
            # Determine direction based on slope
            if norm_slope > 0.1:  # More than 0.1% per candle
                short_term_direction = 'up'
                print(f"  - Short-term price slope: {norm_slope:.4f}% per candle (UPWARD)")
            elif norm_slope < -0.1:  # Less than -0.1% per candle
                short_term_direction = 'down'
                print(f"  - Short-term price slope: {norm_slope:.4f}% per candle (DOWNWARD)")
            else:
                print(f"  - Short-term price slope: {norm_slope:.4f}% per candle (FLAT)")
                
            # Also check the simple price change
            price_change_pct = (last_5_closes[-1] - last_5_closes[0]) / last_5_closes[0] * 100
            print(f"  - Price change over last 5 candles: {price_change_pct:.2f}%")
            
            # Look for any consecutive increases/decreases
            consecutive_up = 0
            consecutive_down = 0
            max_up = 0
            max_down = 0
            
            for i in range(1, len(last_5_closes)):
                if last_5_closes[i] > last_5_closes[i-1]:
                    consecutive_up += 1
                    consecutive_down = 0
                    max_up = max(max_up, consecutive_up)
                elif last_5_closes[i] < last_5_closes[i-1]:
                    consecutive_down += 1
                    consecutive_up = 0
                    max_down = max(max_down, consecutive_down)
            
            # If we have 3 or more consecutive increases/decreases, that's significant
            if max_up >= 3 and short_term_direction != 'up':
                print(f"  - Found {max_up} consecutive up candles (BULLISH)")
                short_term_direction = 'up'
            elif max_down >= 3 and short_term_direction != 'down':
                print(f"  - Found {max_down} consecutive down candles (BEARISH)")
                short_term_direction = 'down'
        
        # Store results
        self.market_structure = {
            'swing_highs': highs,
            'swing_lows': lows,
            'higher_highs': self._has_consecutive_higher_patterns(highs, self.config['CONSECUTIVE_HIGHS']),
            'lower_lows': self._has_consecutive_lower_patterns(lows, self.config['CONSECUTIVE_LOWS']),
            'last_swing_high': last_swing_high,
            'last_swing_low': last_swing_low,
            'last_swing': last_swing,
            'most_recent_high_distance': most_recent_high_distance if most_recent_high_index is not None else None,
            'most_recent_low_distance': most_recent_low_distance if most_recent_low_index is not None else None,
            'short_term_direction': short_term_direction
        }
        
        # Log some analysis
        print("\n🔍 MARKET STRUCTURE ANALYSIS:")
        print(f"  - Identified {len(highs)} swing highs and {len(lows)} swing lows")
        if most_recent_high_index is not None:
            print(f"  - Most recent swing high: {most_recent_high_distance} candles ago")
        if most_recent_low_index is not None:
            print(f"  - Most recent swing low: {most_recent_low_distance} candles ago")
        print(f"  - Higher Highs Pattern: {'✅ Detected' if self.market_structure['higher_highs'] else '❌ Not present'}")
        print(f"  - Lower Lows Pattern: {'✅ Detected' if self.market_structure['lower_lows'] else '❌ Not present'}")
        print(f"  - Most recent swing point is a {self.market_structure['last_swing']}")
        print(f"  - Short-term price direction: {self.market_structure['short_term_direction'].upper()}")
        
        # Determine trend direction based on both swing patterns and short-term direction
        if self.market_structure['higher_highs'] and not self.market_structure['lower_lows']:
            self.market_structure['trend'] = 'up'
            print(f"  - Market structure indicates UPTREND (higher highs) 📈")
        elif self.market_structure['lower_lows'] and not self.market_structure['higher_highs']:
            self.market_structure['trend'] = 'down'
            print(f"  - Market structure indicates DOWNTREND (lower lows) 📉")
        elif self.market_structure['higher_highs'] and self.market_structure['lower_lows']:
            self.market_structure['trend'] = 'choppy'
            print(f"  - Market structure is CHOPPY/SIDEWAYS (both higher highs and lower lows) 📊")
        else:
            # If no clear market structure pattern, use the short-term direction
            if self.market_structure['short_term_direction'] != 'neutral':
                self.market_structure['trend'] = self.market_structure['short_term_direction']
                print(f"  - No clear swing pattern, using short-term direction: {self.market_structure['short_term_direction'].upper()} ⚖️")
            else:
                self.market_structure['trend'] = 'neutral'
                print(f"  - Market structure is NEUTRAL (no clear pattern) ⚖️")
    
    def _find_swing_points(self, lookback, min_size):
        """
        Find swing highs and lows in the price data
        
        Args:
            lookback: Number of candles to look back/forward for comparison
            min_size: Minimum price difference to consider a valid swing
            
        Returns:
            tuple: (swing_highs, swing_lows) where each is a list of (index, price) tuples
        """
        # Determine which price series to use based on configuration
        use_close = self.config.get('USE_CLOSE_PRICE', False)
        
        if use_close:
            # Use closing prices for both highs and lows
            print("  - Using CLOSING PRICES for swing detection")
            price_series = self.data['close']
            swing_high_series = price_series
            swing_low_series = price_series
        else:
            # Use high/low prices for swing detection
            print("  - Using HIGH/LOW prices for swing detection")
            swing_high_series = self.data['high']
            swing_low_series = self.data['low']
        
        # Initialize lists for swing points
        swing_highs = []
        swing_lows = []
        
        # For smaller timeframes, use a more adaptive approach to swing detection
        # Use a smaller lookback for minute-level data while still requiring some confirmation
        actual_lookback = min(lookback, max(3, len(swing_high_series) // 30))  # More adaptive lookback
        
        # Allow swing detection in more recent candles by reducing the forward lookback for newer candles
        data_length = len(swing_high_series)
        
        # Min required lookback for first few candles
        min_lookback = 2
        
        # Skip the first few candles that can't be properly analyzed
        for i in range(actual_lookback, data_length - min_lookback):
            # For candles near the end, reduce the forward lookback requirement
            forward_lookback = min(actual_lookback, data_length - i - 1)
            
            # Special case for recent candles: reduce requirements
            is_recent = (data_length - 1 - i) <= 2  # Last 2 candles get special treatment
            required_checks = 1 if is_recent else min(2, actual_lookback)
            
            # Check for swing high - more relaxed criteria near the end of the data
            is_swing_high = True
            
            # Backward check (requires full lookback)
            for j in range(1, min(required_checks, actual_lookback) + 1):
                if swing_high_series.iloc[i] <= swing_high_series.iloc[i-j]:
                    is_swing_high = False
                    break
                    
            # Forward check (adaptive lookback)
            if is_swing_high and forward_lookback > 0:
                for j in range(1, min(required_checks, forward_lookback) + 1):
                    if i+j < data_length and swing_high_series.iloc[i] <= swing_high_series.iloc[i+j]:
                        is_swing_high = False
                        break
            
            # Check for swing low - more relaxed criteria near the end of the data
            is_swing_low = True
            
            # Backward check (requires full lookback)
            for j in range(1, min(required_checks, actual_lookback) + 1):
                if swing_low_series.iloc[i] >= swing_low_series.iloc[i-j]:
                    is_swing_low = False
                    break
                    
            # Forward check (adaptive lookback)
            if is_swing_low and forward_lookback > 0:
                for j in range(1, min(required_checks, forward_lookback) + 1):
                    if i+j < data_length and swing_low_series.iloc[i] >= swing_low_series.iloc[i+j]:
                        is_swing_low = False
                        break
            
            # For small timeframes, even minor swings can be significant
            # Add valid swing points that meet minimum size requirement
            if is_swing_high:
                # Use a smaller window for size comparison on smaller timeframes
                comparison_window = min(actual_lookback, 5)
                
                # Check size against surrounding candles
                left_values = swing_high_series.iloc[max(0, i-comparison_window):i].values
                right_values = swing_high_series.iloc[i+1:min(data_length, i+comparison_window+1)].values
                
                left_size = swing_high_series.iloc[i] - (max(left_values) if len(left_values) > 0 else swing_high_series.iloc[i])
                right_size = swing_high_series.iloc[i] - (max(right_values) if len(right_values) > 0 else swing_high_series.iloc[i])
                
                # For minute-level data, adjust the minimum size requirement dynamically
                # based on the ATR to catch smaller swings
                dynamic_min_size = min(min_size, self.indicators['atr'].iloc[-1] * 0.1)
                
                # More lenient for recent candles
                if is_recent:
                    dynamic_min_size *= 0.5  # Reduce threshold by half for recent candles
                
                if max(left_size, right_size) >= dynamic_min_size:
                    swing_highs.append((i, swing_high_series.iloc[i]))
                    
            if is_swing_low:
                # Use a smaller window for size comparison on smaller timeframes
                comparison_window = min(actual_lookback, 5)
                
                # Check size against surrounding candles
                left_values = swing_low_series.iloc[max(0, i-comparison_window):i].values
                right_values = swing_low_series.iloc[i+1:min(data_length, i+comparison_window+1)].values
                
                left_size = (min(left_values) if len(left_values) > 0 else swing_low_series.iloc[i]) - swing_low_series.iloc[i]
                right_size = (min(right_values) if len(right_values) > 0 else swing_low_series.iloc[i]) - swing_low_series.iloc[i]
                
                # For minute-level data, adjust the minimum size requirement dynamically
                dynamic_min_size = min(min_size, self.indicators['atr'].iloc[-1] * 0.1)
                
                # More lenient for recent candles
                if is_recent:
                    dynamic_min_size *= 0.5  # Reduce threshold by half for recent candles
                
                if max(left_size, right_size) >= dynamic_min_size:
                    swing_lows.append((i, swing_low_series.iloc[i]))
                    
        # Special handling for the most recent candle
        # If the last candle is higher than several previous ones, treat it as a potential swing high
        if data_length >= 4:  # Need at least 4 candles to make this determination
            last_idx = data_length - 1
            last_high = swing_high_series.iloc[last_idx]
            last_low = swing_low_series.iloc[last_idx]
            
            # Check if last candle might be a swing high (higher than 2 previous candles)
            if all(last_high > swing_high_series.iloc[last_idx-i] for i in range(1, min(3, last_idx))):
                # Check if it's noticeably higher
                if (last_high - max(swing_high_series.iloc[last_idx-2:last_idx])) > self.indicators['atr'].iloc[-1] * 0.05:
                    print(f"  - Detected potential swing high in most recent candle at {last_high:.5f}")
                    swing_highs.append((last_idx, last_high))
            
            # Check if last candle might be a swing low (lower than 2 previous candles)
            if all(last_low < swing_low_series.iloc[last_idx-i] for i in range(1, min(3, last_idx))):
                # Check if it's noticeably lower
                if (min(swing_low_series.iloc[last_idx-2:last_idx]) - last_low) > self.indicators['atr'].iloc[-1] * 0.05:
                    print(f"  - Detected potential swing low in most recent candle at {last_low:.5f}")
                    swing_lows.append((last_idx, last_low))
                    
        # Show last 5 candles for reference
        print(f"\n  - Last 5 candles (most recent first):")
        for i in range(data_length-1, max(0, data_length-6), -1):
            candle_ago = data_length - 1 - i
            if use_close:
                print(f"    Candle {candle_ago} bars ago: Close={self.data['close'].iloc[i]:.5f}")
            else:
                print(f"    Candle {candle_ago} bars ago: High={self.data['high'].iloc[i]:.5f}, Low={self.data['low'].iloc[i]:.5f}")
                
        # Show detected swing points for clarity
        if swing_highs:
            most_recent_high = max(swing_highs, key=lambda x: x[0])
            print(f"  - Most recent swing high detected at index {most_recent_high[0]}, price {most_recent_high[1]:.5f}")
        if swing_lows:
            most_recent_low = max(swing_lows, key=lambda x: x[0])
            print(f"  - Most recent swing low detected at index {most_recent_low[0]}, price {most_recent_low[1]:.5f}")
                    
        return swing_highs, swing_lows
    
    def _has_consecutive_higher_patterns(self, swing_points, count):
        """
        Check if there are consecutive higher swing points
        
        Args:
            swing_points: List of (index, price) tuples
            count: Number of consecutive higher points required
            
        Returns:
            bool: True if consecutive higher pattern exists
        """
        if len(swing_points) < count + 1:
            return False
            
        # Get the most recent swing points
        recent_points = swing_points[-count-1:]
        
        # Check for consecutively higher points
        is_higher = True
        for i in range(1, len(recent_points)):
            if recent_points[i][1] <= recent_points[i-1][1]:
                is_higher = False
                break
                
        return is_higher
    
    def _has_consecutive_lower_patterns(self, swing_points, count):
        """
        Check if there are consecutive lower swing points
        
        Args:
            swing_points: List of (index, price) tuples
            count: Number of consecutive lower points required
            
        Returns:
            bool: True if consecutive lower pattern exists
        """
        if len(swing_points) < count + 1:
            return False
            
        # Get the most recent swing points
        recent_points = swing_points[-count-1:]
        
        # Check for consecutively lower points
        is_lower = True
        for i in range(1, len(recent_points)):
            if recent_points[i][1] >= recent_points[i-1][1]:
                is_lower = False
                break
                
        return is_lower
    
    def update_data(self, new_data):
        """Updates the strategy's data and recalculates indicators"""
        if new_data is not None and not new_data.empty:
            self.data = new_data.copy()
            self.calculate_indicators()
    
    def generate_entry_signal(self, open_positions=None):
        """
        Generates entry signals based on market structure analysis.
        Only enters when clear higher highs/lower lows are identified.
        
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
        
        # Make sure we have indicators calculated
        self.calculate_indicators()
        
        # Check candles since last exit counter
        if self.candles_since_exit < self.config['WAIT_CANDLES_AFTER_EXIT']:
            print(f"⏳ Waiting {self.config['WAIT_CANDLES_AFTER_EXIT'] - self.candles_since_exit} more candles after last exit")
            self.candles_since_exit += 1
            return None
            
        # If indicators or market structure are missing, skip
        if not self.indicators or not self.market_structure:
            print("❌ Missing indicators or market structure analysis")
            return None
        
        # Analyze entry conditions based on market structure and indicators
        entry_signal = self._evaluate_entry_conditions()
        
        # If no valid entry signal, return None
        if entry_signal is None:
            return None
            
        # Calculate price levels for the trade
        signal_type, entry_reason = entry_signal
        self._calculate_price_levels(signal_type)
        
        # Get the price levels
        entry_price = self.price_levels['entry']
        sl_price = self.price_levels['stop']
        tp_price = self.price_levels['tp']
        
        # Log the entry signal
        direction = "LONG" if signal_type == mt5.ORDER_TYPE_BUY else "SHORT"
        print(f"\n🎯 {direction} ENTRY SIGNAL: {entry_reason}")
        print(f"📊 Entry price: {entry_price:.5f}, SL: {sl_price:.5f}, TP: {tp_price:.5f}")
        
        # Return the signal
        return signal_type, entry_price, sl_price, tp_price
    
    def _evaluate_entry_conditions(self):
        """
        Evaluate if current market conditions warrant an entry based on trend alignment between
        EMAs and market structure.
        
        Returns (signal_type, reason) or None if no entry.
        """
        # Get latest data
        current_price = self.data['close'].iloc[-1]
        atr = self.indicators['atr'].iloc[-1]
        
        # Get EMA values for trend determination
        fast_ema_period = self.config['FAST_EMA']
        slow_ema_period = self.config['SLOW_EMA']
        fast_ema = self.indicators[f'ema{fast_ema_period}'].iloc[-1]
        slow_ema = self.indicators[f'ema{slow_ema_period}'].iloc[-1]
        
        # Get some recent EMAs for slope calculation
        if len(self.indicators[f'ema{fast_ema_period}']) > 3:
            fast_ema_prev = self.indicators[f'ema{fast_ema_period}'].iloc[-3]
            slow_ema_prev = self.indicators[f'ema{slow_ema_period}'].iloc[-3]
            
            # Calculate EMA slopes (direction)
            fast_ema_slope = (fast_ema - fast_ema_prev) / fast_ema_prev * 100
            slow_ema_slope = (slow_ema - slow_ema_prev) / slow_ema_prev * 100
            
            # Determine if EMAs are trending in the same direction
            fast_ema_rising = fast_ema_slope > 0
            fast_ema_falling = fast_ema_slope < 0
            slow_ema_rising = slow_ema_slope > 0
            slow_ema_falling = slow_ema_slope < 0
            
            # Check if both EMAs are moving in the same direction
            emas_aligned_bullish = fast_ema_rising and slow_ema_rising
            emas_aligned_bearish = fast_ema_falling and slow_ema_falling
        else:
            # Not enough data for slope calculation
            emas_aligned_bullish = False
            emas_aligned_bearish = False
            fast_ema_slope = 0
            slow_ema_slope = 0
        
        # Calculate EMA crossover status
        ema_bullish = fast_ema > slow_ema
        ema_bearish = fast_ema < slow_ema
        
        # Get market structure info
        trend = self.market_structure.get('trend', 'neutral')
        higher_highs = self.market_structure.get('higher_highs', False)
        lower_lows = self.market_structure.get('lower_lows', False)
        last_swing = self.market_structure.get('last_swing', None)
        short_term_direction = self.market_structure.get('short_term_direction', 'neutral')
        
        # Print analysis details
        print("\n📊 TREND ALIGNMENT ANALYSIS:")
        print(f"  - Current Price: {current_price:.5f}")
        print(f"  - EMA{fast_ema_period}: {fast_ema:.5f} (slope: {fast_ema_slope:.4f}%)")
        print(f"  - EMA{slow_ema_period}: {slow_ema:.5f} (slope: {slow_ema_slope:.4f}%)")
        print(f"  - EMA Position: {'BULLISH' if ema_bullish else 'BEARISH'} (Fast EMA {'above' if ema_bullish else 'below'} Slow EMA)")
        print(f"  - EMA Direction: {'ALIGNED' if (emas_aligned_bullish or emas_aligned_bearish) else 'MIXED'} ({'rising' if emas_aligned_bullish else 'falling' if emas_aligned_bearish else 'mixed'})")
        print(f"  - Market Structure Trend: {trend.upper()}")
        print(f"  - Short-term Direction: {short_term_direction.upper()}")
        print(f"  - Higher Highs: {'✅' if higher_highs else '❌'}")
        print(f"  - Lower Lows: {'✅' if lower_lows else '❌'}")
        
        # For less strict conditions, calculate how many factors are aligned
        bullish_factors = sum([
            ema_bullish,                  # Fast EMA above Slow EMA
            fast_ema_rising,              # Fast EMA rising
            slow_ema_rising,              # Slow EMA rising
            trend == 'up',                # Market structure trend
            higher_highs,                 # Higher highs pattern
            short_term_direction == 'up'  # Short-term price direction
        ])
        
        bearish_factors = sum([
            ema_bearish,                   # Fast EMA below Slow EMA
            fast_ema_falling,              # Fast EMA falling
            slow_ema_falling,              # Slow EMA falling
            trend == 'down',               # Market structure trend
            lower_lows,                    # Lower lows pattern
            short_term_direction == 'down' # Short-term price direction
        ])
        
        print(f"  - Bullish alignment factors: {bullish_factors}/6")
        print(f"  - Bearish alignment factors: {bearish_factors}/6")
        
        # Determine if we can trade based on trend alignment
        # Require at least 3 out of 6 factors aligned in the same direction (lowered from 4)
        # and ensure that EMA position is correct (fast above/below slow)
        can_go_long = bullish_factors >= 3 and ema_bullish
        can_go_short = bearish_factors >= 3 and ema_bearish
        
        # For market structure factors, we need at least one structural confirmation
        market_structure_bullish = higher_highs or trend == 'up'
        market_structure_bearish = lower_lows or trend == 'down'
        
        # Add market structure requirement
        can_go_long = can_go_long and market_structure_bullish
        can_go_short = can_go_short and market_structure_bearish
        
        if not (can_go_long or can_go_short):
            print("❌ No clear trend alignment - cannot determine trade direction")
            return None
            
        # Log the primary trend direction
        if can_go_long:
            print(f"✅ BULLISH TREND ALIGNMENT: {bullish_factors}/6 factors aligned")
            return mt5.ORDER_TYPE_BUY, f"Bullish trend alignment ({bullish_factors}/6 factors)"
        else:
            print(f"✅ BEARISH TREND ALIGNMENT: {bearish_factors}/6 factors aligned")
            return mt5.ORDER_TYPE_SELL, f"Bearish trend alignment ({bearish_factors}/6 factors)"
    
    def _calculate_price_levels(self, signal_type):
        """
        Calculate entry, stop loss, and take profit prices based on
        market structure and ATR.
        
        Args:
            signal_type: MT5 order type (BUY/SELL)
        """
        if self.data.empty or 'atr' not in self.indicators:
            return None
            
        # Get the latest close price and ATR
        close_price = self.data['close'].iloc[-1]
        atr = self.indicators['atr'].iloc[-1]
        
        # Get ATR multipliers from config
        sl_mult = self.config['SL_ATR_MULT']
        tp_mult = self.config['TP_ATR_MULT']
        
        # Get market structure swing points
        swing_highs = self.market_structure.get('swing_highs', [])
        swing_lows = self.market_structure.get('swing_lows', [])
        
        # Sort swing points by recency (most recent first)
        swing_highs = sorted(swing_highs, key=lambda x: x[0], reverse=True)
        swing_lows = sorted(swing_lows, key=lambda x: x[0], reverse=True)
        
        # Print summary of available market structure
        print("\n🏛️ MARKET STRUCTURE FOR SL/TP PLACEMENT:")
        print(f"  - Found {len(swing_highs)} swing highs and {len(swing_lows)} swing lows")
        
        # Initialize price levels with close price
        entry = close_price
        stop = None
        tp = None
        
        # STOP LOSS PLACEMENT BASED ON MARKET STRUCTURE
        if signal_type == mt5.ORDER_TYPE_BUY:
            # For a LONG position:
            # 1. Primary SL: Below the most recent swing low
            # 2. Backup SL: ATR-based if no suitable swing low
            
            # Find the most recent swing low below current price
            valid_sl_points = [(i, price) for i, price in swing_lows if price < close_price]
            
            if valid_sl_points:
                # Get the most recent one
                recent_low_idx, recent_low_price = valid_sl_points[0]
                distance_in_candles = len(self.data) - 1 - recent_low_idx
                
                # Use this swing low if it's reasonably recent (within 20 candles)
                if distance_in_candles <= 20:
                    # Place stop just below the swing low with a buffer
                    stop = recent_low_price - (0.1 * atr)
                    print(f"  - Using swing low at {recent_low_price:.5f} ({distance_in_candles} candles ago) for stop placement")
            
            # If no suitable swing low found or stop is too far, use ATR-based stop
            if stop is None or (close_price - stop) > sl_mult * atr * 3:
                stop = close_price - sl_mult * atr
                print(f"  - Using ATR-based stop: {sl_mult}x ATR below entry")
                
            # TAKE PROFIT PLACEMENT - Either:
            # 1. Target the next swing high above current price
            # 2. Use ATR multiple if no suitable target
            
            valid_tp_points = [(i, price) for i, price in swing_highs if price > close_price]
            
            if valid_tp_points:
                # Get the nearest swing high above current price
                next_high_idx, next_high_price = valid_tp_points[0]
                
                # Use this swing high as TP target with a buffer
                tp = next_high_price - (0.1 * atr)
                print(f"  - Using next swing high at {next_high_price:.5f} for take profit")
            
            # If no suitable swing high found or TP gives poor R:R, use ATR-based TP
            # Calculate risk
            risk = close_price - stop
            
            # If no TP set yet or TP gives poor R:R, use ATR-based TP
            if tp is None or (tp - close_price) < risk * 1.5:
                # Aim for at least 1.5:1 reward-to-risk ratio, with minimum of tp_mult * ATR
                tp_distance = max(risk * 1.5, tp_mult * atr)
                tp = close_price + tp_distance
                print(f"  - Using ATR-based take profit: {tp_mult}x ATR above entry")
            
        else:  # SELL order
            # For a SHORT position:
            # 1. Primary SL: Above the most recent swing high
            # 2. Backup SL: ATR-based if no suitable swing high
            
            # Find the most recent swing high above current price
            valid_sl_points = [(i, price) for i, price in swing_highs if price > close_price]
            
            if valid_sl_points:
                # Get the most recent one
                recent_high_idx, recent_high_price = valid_sl_points[0]
                distance_in_candles = len(self.data) - 1 - recent_high_idx
                
                # Use this swing high if it's reasonably recent (within 20 candles)
                if distance_in_candles <= 20:
                    # Place stop just above the swing high with a buffer
                    stop = recent_high_price + (0.1 * atr)
                    print(f"  - Using swing high at {recent_high_price:.5f} ({distance_in_candles} candles ago) for stop placement")
            
            # If no suitable swing high found or stop is too far, use ATR-based stop
            if stop is None or (stop - close_price) > sl_mult * atr * 3:
                stop = close_price + sl_mult * atr
                print(f"  - Using ATR-based stop: {sl_mult}x ATR above entry")
                
            # TAKE PROFIT PLACEMENT - Either:
            # 1. Target the next swing low below current price
            # 2. Use ATR multiple if no suitable target
            
            valid_tp_points = [(i, price) for i, price in swing_lows if price < close_price]
            
            if valid_tp_points:
                # Get the nearest swing low below current price
                next_low_idx, next_low_price = valid_tp_points[0]
                
                # Use this swing low as TP target with a buffer
                tp = next_low_price + (0.1 * atr)
                print(f"  - Using next swing low at {next_low_price:.5f} for take profit")
            
            # Calculate risk
            risk = stop - close_price
            
            # If no TP set yet or TP gives poor R:R, use ATR-based TP
            if tp is None or (close_price - tp) < risk * 1.5:
                # Aim for at least 1.5:1 reward-to-risk ratio, with minimum of tp_mult * ATR
                tp_distance = max(risk * 1.5, tp_mult * atr)
                tp = close_price - tp_distance
                print(f"  - Using ATR-based take profit: {tp_mult}x ATR below entry")
            
        # Store calculated levels
        self.price_levels = {
            'entry': entry,
            'stop': stop,
            'tp': tp
        }
        
        # Calculate reward-to-risk ratio
        risk = abs(entry - stop)
        reward = abs(tp - entry)
        rr_ratio = reward / risk if risk > 0 else 0
        
        # Log the price levels
        print(f"\n💰 TRADE LEVELS:")
        print(f"  - Entry: {entry:.5f}")
        print(f"  - Stop Loss: {stop:.5f} (Distance: {abs(entry - stop):.5f})")
        print(f"  - Take Profit: {tp:.5f} (Distance: {abs(entry - tp):.5f})")
        print(f"  - Reward-to-Risk Ratio: {rr_ratio:.2f}")
        
        return self.price_levels
    
    def generate_exit_signal(self, position):
        """
        Generates exit signals based on trend alignment changes.
        
        Args:
            position (mt5.PositionInfo): The open position object to evaluate
            
        Returns:
            bool: True if the position should be closed, False otherwise
        """
        # Make sure indicators are calculated
        self.calculate_indicators()
        
        # If indicators or market structure are missing, don't exit
        if not self.indicators or not self.market_structure:
            return False
        
        # Get EMA values for trend determination
        fast_ema_period = self.config['FAST_EMA']
        slow_ema_period = self.config['SLOW_EMA']
        fast_ema = self.indicators[f'ema{fast_ema_period}'].iloc[-1]
        slow_ema = self.indicators[f'ema{slow_ema_period}'].iloc[-1]
        
        # Get previous EMA values for slope calculation
        if len(self.indicators[f'ema{fast_ema_period}']) > 3:
            fast_ema_prev = self.indicators[f'ema{fast_ema_period}'].iloc[-3]
            fast_ema_slope = (fast_ema - fast_ema_prev) / fast_ema_prev * 100
        else:
            fast_ema_slope = 0
            
        # Get market structure info
        trend = self.market_structure.get('trend', 'neutral')
        short_term_direction = self.market_structure.get('short_term_direction', 'neutral')
        
        # Calculate EMA relationship
        ema_bullish = fast_ema > slow_ema
        ema_bearish = fast_ema < slow_ema
        
        # Get current price and position details
        current_price = self.data['close'].iloc[-1]
        entry_price = position.price_open
        is_long = position.type == mt5.POSITION_TYPE_BUY
        is_short = position.type == mt5.POSITION_TYPE_SELL
        
        # Calculate position profit
        profit_in_points = 0
        profit_percent = 0
        
        if is_long:
            profit_in_points = current_price - entry_price
            profit_percent = (profit_in_points / entry_price) * 100
            
            # Exit scenarios for LONG positions:
            # 1. EMA crossover (fast EMA crosses below slow EMA)
            if ema_bearish:
                print(f"🚨 EMA BEARISH CROSS: Fast EMA crossed below Slow EMA (profit: {profit_percent:.2f}%)")
                return True
                
            # 2. Both market structure and short-term direction turn bearish
            if trend == 'down' and short_term_direction == 'down':
                print(f"🚨 BEARISH STRUCTURE: Market structure and short-term direction both bearish (profit: {profit_percent:.2f}%)")
                return True
                
            # 3. Fast EMA slope turns significantly negative while in profit
            if profit_percent > 1.0 and fast_ema_slope < -0.1:
                print(f"🚨 MOMENTUM LOSS: Fast EMA slope turned negative ({fast_ema_slope:.4f}%) while in profit (profit: {profit_percent:.2f}%)")
                return True
            
        elif is_short:
            profit_in_points = entry_price - current_price
            profit_percent = (profit_in_points / entry_price) * 100
            
            # Exit scenarios for SHORT positions:
            # 1. EMA crossover (fast EMA crosses above slow EMA)
            if ema_bullish:
                print(f"🚨 EMA BULLISH CROSS: Fast EMA crossed above Slow EMA (profit: {profit_percent:.2f}%)")
                return True
                
            # 2. Both market structure and short-term direction turn bullish
            if trend == 'up' and short_term_direction == 'up':
                print(f"🚨 BULLISH STRUCTURE: Market structure and short-term direction both bullish (profit: {profit_percent:.2f}%)")
                return True
                
            # 3. Fast EMA slope turns significantly positive while in profit
            if profit_percent > 1.0 and fast_ema_slope > 0.1:
                print(f"🚨 MOMENTUM LOSS: Fast EMA slope turned positive ({fast_ema_slope:.4f}%) while in profit (profit: {profit_percent:.2f}%)")
                return True
        
        # Log the current state
        position_type = "LONG" if is_long else "SHORT"
        
        print(f"📊 Position: {position_type} | Price: {current_price:.5f}")
        print(f"  - Entry price: {entry_price:.5f}")
        print(f"  - Current profit: {profit_in_points:.5f} pts ({profit_percent:.2f}%)")
        print(f"  - Fast EMA: {fast_ema:.5f}, Slow EMA: {slow_ema:.5f}")
        print(f"  - Fast EMA slope: {fast_ema_slope:.4f}%/candle")
        print(f"  - Market structure: {trend.upper()}")
        print(f"  - Short-term direction: {short_term_direction.upper()}")
        
        # Additional exit logic for trailing management
        # If we're in significant profit, tighten the exit criteria
        if is_long and profit_percent > 3.0:
            if short_term_direction == 'down':
                print(f"🔒 LOCKING PROFIT: Short-term direction turned down while in significant profit ({profit_percent:.2f}%)")
                return True
        elif is_short and profit_percent > 3.0:
            if short_term_direction == 'up':
                print(f"🔒 LOCKING PROFIT: Short-term direction turned up while in significant profit ({profit_percent:.2f}%)")
                return True
            
        # Emergency exit if position has significant loss (SL didn't trigger for some reason)
        if is_long and ((entry_price - current_price) / entry_price * 100) > 5.0:
            print(f"🚨 EMERGENCY EXIT (LONG): Price dropped more than 5% from entry")
            return True
            
        if is_short and ((current_price - entry_price) / entry_price * 100) > 5.0:
            print(f"🚨 EMERGENCY EXIT (SHORT): Price rose more than 5% from entry")
            return True
        
        # No exit signal - we trust the SL/TP levels for primary exit
        return False
        
    def reset_signal_state(self):
        """Reset strategy internal state after position closing or failed orders."""
        # Record the time of the position close
        self.last_trade_close_time = get_server_time()
        print(f"🕒 Position closed at {self.last_trade_close_time}")
        
        # Reset candle counter
        self.candles_since_exit = 0
        
        # Call the parent class method to reset other state
        super().reset_signal_state() 