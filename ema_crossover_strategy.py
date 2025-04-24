import MetaTrader5 as mt5
import pandas as pd
import numpy as np
import time
import argparse
from datetime import datetime, timedelta

# ===== Configuration Constants =====

# Account Configuration
ACCOUNT_CONFIG = {
    'LOGIN': 796068,
    'PASSWORD': "52N1%!mm",
    'SERVER': "PUPrime-Demo"
}

# EMA Parameters
EMA_CONFIG = {
    'FAST_EMA': 2,  # Period for TEMA calculation
    'SLOW_EMA': 8,  # Period for regular EMA
}

# Risk Management Configuration
RISK_CONFIG = {
    'RISK_PERCENTAGE': 0.01,  # 1% risk per trade
    'MAGIC_NUMBER': 234000,
    'DEVIATION': 20  # Price deviation allowed for market orders
}

# Signal Filter Parameters
SIGNAL_FILTERS = {
    'MIN_CROSSOVER_POINTS': 1,  # Minimum points required for initial crossover
    'MIN_SEPARATION_POINTS': 2,  # Minimum separation after crossover
    'SLOPE_PERIODS': 3,  # Periods to calculate slope over
    'MIN_SLOPE_THRESHOLD': 0.000001,  # Minimum slope for trend direction
    'MAX_OPPOSITE_SLOPE': -0.000002,  # Maximum allowed opposite slope
    'PRICE_CONFIRM_PERIODS': 2,  # Periods to wait for price confirmation
    'TREND_MIN_CANDLES': 3,      # Minimum candles required showing the same trend
    'TREND_HISTORY_LENGTH': 4,   # Number of candles to analyze for trend
    'TREND_THRESHOLD_MULT': 0.5  # Multiplier for trend threshold (applied to point value)
}

# Position Management Configuration
POSITION_CONFIG = {
    'REQUIRED_NEW_CANDLES': 3,      # Number of new candles required after profit-taking
    'MIN_POSITION_AGE_MINUTES': 2,  # Minimum position age for profit-taking/loss-cutting
    'MIN_AGAINST_CANDLES': 2,       # Minimum candles showing reversal for taking profit/cutting loss
}

class EMACalculator:
    """Handles EMA calculations and slope analysis"""
    
    @staticmethod
    def calculate_tema(prices, period):
        """Calculate Triple Exponential Moving Average
        
        Args:
            prices: Price series
            period: EMA period
            
        Returns:
            Series: TEMA values
        """
        ema1 = prices.ewm(span=period, adjust=False).mean()
        ema2 = ema1.ewm(span=period, adjust=False).mean()
        ema3 = ema2.ewm(span=period, adjust=False).mean()
        tema = (3 * ema1) - (3 * ema2) + ema3
        return tema
    
    @staticmethod
    def calculate_regular_ema(prices, period):
        """Calculate standard Exponential Moving Average
        
        Args:
            prices: Price series
            period: EMA period
            
        Returns:
            Series: EMA values
        """
        return prices.ewm(span=period, adjust=False).mean()
    
    @staticmethod
    def calculate_slope(series, periods=SIGNAL_FILTERS['SLOPE_PERIODS']):
        """Calculate the slope of a series over specified periods"""
        if len(series) < periods:
            return 0
        
        y = series[-periods:].values
        x = np.arange(len(y))
        slope, _ = np.polyfit(x, y, 1)
        return slope

    @staticmethod
    def calculate_emas_for_dataframe(df):
        """Calculate EMAs for a dataframe with price data
        
        Args:
            df: DataFrame with 'close' column
            
        Returns:
            DataFrame: Input dataframe with 'fast_ema' and 'slow_ema' columns added
        """
        df['fast_ema'] = EMACalculator.calculate_tema(df['close'], EMA_CONFIG['FAST_EMA'])
        df['slow_ema'] = EMACalculator.calculate_regular_ema(df['close'], EMA_CONFIG['SLOW_EMA'])
        return df

class SignalAnalyzer:
    """Analyzes price action for trading signals"""
    
    # Tracking variables (state)
    last_profit_time = None         # When we last took profits
    candles_seen_since_profit = 0   # Number of candles seen since profit
    last_candle_time = None         # Last candle timestamp seen
    is_in_waiting_period = False    # Flag to track if we're in a waiting period after profit
    
    def __init__(self, df, symbol_info):
        self.df = df
        self.symbol_info = symbol_info
        
        # Process new candle counting if in post-profit mode
        if SignalAnalyzer.is_in_waiting_period:
            current_candle_time = self.df['time'].iloc[-1]

            print(f"🕒 Current candle time: {current_candle_time}")
            print(f"🕒 Last candle time: {SignalAnalyzer.last_candle_time}")
            print(f"🕒 Candles since profit: {SignalAnalyzer.candles_seen_since_profit}/{POSITION_CONFIG['REQUIRED_NEW_CANDLES']}")
            print(f"Is in waiting period: {SignalAnalyzer.is_in_waiting_period}")
            # Only count new candles (if the timestamp is different from last seen)
            if SignalAnalyzer.last_candle_time is None or current_candle_time != SignalAnalyzer.last_candle_time:
                SignalAnalyzer.candles_seen_since_profit += 1
                SignalAnalyzer.last_candle_time = current_candle_time
                print(f"🕒 Candles since profit: {SignalAnalyzer.candles_seen_since_profit}/{POSITION_CONFIG['REQUIRED_NEW_CANDLES']}")
                
                # If we've seen enough new candles, exit post-profit mode
                if SignalAnalyzer.candles_seen_since_profit >= POSITION_CONFIG['REQUIRED_NEW_CANDLES']:
                    print(f"✅ Collected {SignalAnalyzer.candles_seen_since_profit} new candles after profit - Ready for new trend signals")
                    SignalAnalyzer.last_profit_time = None
                    SignalAnalyzer.candles_seen_since_profit = 0
                    SignalAnalyzer.is_in_waiting_period = False

    @staticmethod
    def reset_after_profit():
        """Reset candle history tracking after taking profit"""
        SignalAnalyzer.last_profit_time = datetime.now()
        SignalAnalyzer.candles_seen_since_profit = 0
        SignalAnalyzer.last_candle_time = None
        SignalAnalyzer.is_in_waiting_period = True
        print(f"🔄 Waiting period activated - need {POSITION_CONFIG['REQUIRED_NEW_CANDLES']} new candles")

    def check_slope_conditions(self, direction="BUY"):
        """Check if slope conditions are met for the given direction"""
        fast_slope = EMACalculator.calculate_slope(self.df['fast_ema'])
        slow_slope = EMACalculator.calculate_slope(self.df['slow_ema'])
        
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
        diff = self.df['fast_ema'].iloc[-1] - self.df['slow_ema'].iloc[-1]
        diff_points = abs(diff / self.symbol_info.point)
        
        if direction == "BUY":
            sep_ok = diff > 0 and diff_points >= SIGNAL_FILTERS['MIN_SEPARATION_POINTS']
        else:  # SELL
            sep_ok = diff < 0 and diff_points >= SIGNAL_FILTERS['MIN_SEPARATION_POINTS']
            
        # print(f"Separation Check ({direction}) - {diff_points:.1f} points - {'✅' if sep_ok else '❌'}")
        return sep_ok
    
    def check_price_confirmation(self, direction="BUY"):
        """Check if price confirms the signal direction"""
        last_close = self.df['close'].iloc[-1]
        fast_ema = self.df['fast_ema'].iloc[-1]
        slow_ema = self.df['slow_ema'].iloc[-1]
        
        if direction == "BUY":
            price_ok = last_close > fast_ema and last_close > slow_ema
        else:  # SELL
            price_ok = last_close < fast_ema and last_close < slow_ema
            
        # print(f"Price Confirmation ({direction}) - {'✅' if price_ok else '❌'}")
        return price_ok
    
    def check_trend(self):
        """Check the current EMA trend direction based solely on recent candle history
        
        Analyzes EMA slopes over multiple candles to detect if both EMAs
        are trending consistently in the same direction.
        
        Returns:
            str or None: "BUY" for uptrend, "SELL" for downtrend, None if no clear trend
        """
        # Configuration settings for trend detection from SIGNAL_FILTERS
        min_required_trend_candles = SIGNAL_FILTERS['TREND_MIN_CANDLES']
        history_length = SIGNAL_FILTERS['TREND_HISTORY_LENGTH']
        trend_threshold = self.symbol_info.point * SIGNAL_FILTERS['TREND_THRESHOLD_MULT']
        
        # If we're in post-profit waiting period, don't generate trend signals
        if SignalAnalyzer.is_in_waiting_period:
            print(f"⏳ Waiting period active - skipping trend analysis")
            return None

        # Check if we have enough data
        if len(self.df) < history_length:
            print(f"📊 Need {history_length} candles for trend analysis")
            return None
            
        # Get candles for trend analysis (newest to oldest)
        last_candles = min(history_length, len(self.df))
        
        # Get EMA values for the last few candles (newest to oldest)
        fast_ema_values = [self.df['fast_ema'].iloc[-i] for i in range(1, last_candles+1)]
        slow_ema_values = [self.df['slow_ema'].iloc[-i] for i in range(1, last_candles+1)]
        
        # Check the current EMA positions
        current_fast_ema = fast_ema_values[0]
        current_slow_ema = slow_ema_values[0]
        fast_above_slow = current_fast_ema > current_slow_ema
        
        # Calculate slopes directly from the values
        fast_ema_slopes = []
        slow_ema_slopes = []
        
        for i in range(len(fast_ema_values)-1):
            # Calculate slope as the difference between successive values
            fast_slope = fast_ema_values[i] - fast_ema_values[i+1]
            slow_slope = slow_ema_values[i] - slow_ema_values[i+1]
            
            fast_ema_slopes.append(fast_slope)
            slow_ema_slopes.append(slow_slope)
        
        # Count how many candles show uptrend/downtrend for both EMAs
        uptrend_count = sum(1 for i in range(len(fast_ema_slopes)) 
                         if fast_ema_slopes[i] > trend_threshold and 
                            slow_ema_slopes[i] > trend_threshold)
        
        downtrend_count = sum(1 for i in range(len(fast_ema_slopes)) 
                           if fast_ema_slopes[i] < -trend_threshold and 
                              slow_ema_slopes[i] < -trend_threshold)
        
        # Check if most recent candle shows a trend
        current_uptrend = (len(fast_ema_slopes) > 0 and
                          fast_ema_slopes[0] > trend_threshold and 
                          slow_ema_slopes[0] > trend_threshold)
        
        current_downtrend = (len(fast_ema_slopes) > 0 and 
                            fast_ema_slopes[0] < -trend_threshold and 
                            slow_ema_slopes[0] < -trend_threshold)
        
        # Print trend analysis - make more concise
        print(f"📊 Trend: ⬆️ {uptrend_count}/{len(fast_ema_slopes)} ⬇️ {downtrend_count}/{len(fast_ema_slopes)} | Fast {fast_above_slow and '>' or '<'} Slow")
        
        # Check for BUY signal - need uptrend AND fast EMA above slow EMA
        if uptrend_count >= min_required_trend_candles and fast_above_slow:
            print(f"⬆️ BUY SIGNAL: EMAs trending up for {uptrend_count} candles with Fast > Slow")
            return "BUY"
            
        # Check for SELL signal - need downtrend AND fast EMA below slow EMA
        elif downtrend_count >= min_required_trend_candles and not fast_above_slow:
            print(f"⬇️ SELL SIGNAL: EMAs trending down for {downtrend_count} candles with Fast < Slow")
            return "SELL"
            
        # If conditions aren't fully met, explain why
        if uptrend_count >= min_required_trend_candles and not fast_above_slow:
            print(f"⚠️ Uptrend detected but Fast < Slow - no BUY")
        elif downtrend_count >= min_required_trend_candles and fast_above_slow:
            print(f"⚠️ Downtrend detected but Fast > Slow - no SELL")
            
        return None

    def check_profit_taking(self, position_type, position_time=None):
        """Check if we should take profits or cut losses on the current position
        
        Analyzes candle history to detect if there's a consistent trend against our position.
        Takes profits when the fast EMA is moving against us while we're still profitable.
        Also cuts losses when the position is moving significantly against us.
        Ensures the position has been open long enough before considering any action.
        
        Args:
            position_type: Current position type ("BUY" or "SELL")
            position_time: Datetime when the position was opened
            
        Returns:
            bool: True if we should close the position, False otherwise
        """
        try:
            # Configuration settings for profit-taking
            min_history_candles = 5     # Minimum candles needed for analysis
            min_against_candles = POSITION_CONFIG['MIN_AGAINST_CANDLES']  # Candles showing reversal needed
            min_position_age = POSITION_CONFIG['MIN_POSITION_AGE_MINUTES']  # Minimum position age in minutes
            
            # Validate position type
            if not position_type:
                print("❌ No position type provided for profit-taking analysis")
                return False
                
            if position_type not in ["BUY", "SELL"]:
                print(f"❌ Invalid position type for profit-taking analysis: {position_type}")
                return False
            
            # Validate we have enough history data
            if len(self.df) < min_history_candles:
                print(f"❌ Not enough history for profit-taking analysis: {len(self.df)} candles (need {min_history_candles})")
                return False
                
            # DETAILED DEBUG: Print DataFrame information
            print("\n🔍 DEBUG: DataFrame Information")
            print(f"DataFrame shape: {self.df.shape}")
            print(f"DataFrame columns: {self.df.columns.tolist()}")
            print(f"DataFrame index: {type(self.df.index)}")
            
            # Show the most recent few candles with timestamps
            num_candles_to_show = min(min_history_candles, len(self.df))
            print(f"\n🕒 Last {num_candles_to_show} candles:")
            for i in range(num_candles_to_show):
                candle = self.df.iloc[-(i+1)]
                print(f"Candle -{i+1}: Time={candle['time']} | Open={candle['open']:.5f} | High={candle['high']:.5f} | Low={candle['low']:.5f} | Close={candle['close']:.5f} | Fast EMA={candle['fast_ema']:.5f} | Slow EMA={candle['slow_ema']:.5f}")
            
            # Debug position time
            print(f"\n⏱️ DEBUG: Position Time Information")
            print(f"Position type: {position_type}")
            print(f"Position time passed to function: {position_time} (Type: {type(position_time)})")
            print(f"Current system time: {datetime.now()}")
            
            # Check if the position is old enough to consider profit-taking or loss-cutting
            if not self._is_position_mature_enough(position_time, min_position_age):
                print("⏱️ Position not mature enough for profit-taking analysis")
                return False
            
            # Analyze the candle history - this is where the actual decision is made
            result = self._analyze_position_for_exit(position_type, min_against_candles)
            print(f"Profit-taking analysis result: {result}")
            return result
            
        except Exception as e:
            print(f"❌ Error in check_profit_taking: {e}")
            import traceback
            traceback.print_exc()
            return False

    def _is_position_mature_enough(self, position_time, min_position_age):
        """Check if the position has been open long enough to consider profit-taking
        
        Args:
            position_time: Datetime when the position was opened
            min_position_age: Minimum position age in minutes
            
        Returns:
            bool: True if position is mature enough, False otherwise
        """
        # Add trade age check - don't take profits on new positions
        if position_time is None:
            print("WARNING: No position_time provided, skipping age check!")
            # If no position time was provided, we can't check the age, so default to safe behavior
            return False
        
        # Verify position_time is a valid datetime
        if not isinstance(position_time, datetime):
            print(f"ERROR: position_time is not a datetime object: {position_time} ({type(position_time)})")
            return False
        
        # Use the system time for comparing, not the candle time
        current_time = datetime.now()
        print(f"Current system time for comparison: {current_time}")
        
        # Debug time calculation
        try:
            # Calculate time difference in minutes directly
            time_diff = current_time - position_time
            minutes_since_open = time_diff.total_seconds() / 60
            print(f"Time difference calculation success: {minutes_since_open:.2f} minutes")
            
            # Safeguard against negative time differences (clock adjustment issues)
            if minutes_since_open < 0:
                print(f"WARNING: Negative time difference detected! Using absolute value.")
                minutes_since_open = abs(minutes_since_open)
        except Exception as e:
            print(f"Error calculating time difference: {e}")
            print(f"current_time = {current_time} ({type(current_time)})")
            print(f"position_time = {position_time} ({type(position_time)})")
            minutes_since_open = 0  # Default to 0 if there's an error
        
        # Require minimum time before considering profit-taking or loss-cutting
        print(f"Minutes since position opened: {minutes_since_open:.1f}")
        print(f"Minimum required: {min_position_age} minutes")
        
        if minutes_since_open < min_position_age:
            print(f"\n⏱️ Position too new for profit-taking/loss-cutting ({minutes_since_open:.1f} minutes old)")
            print(f"Will check for profit-taking/loss-cutting after {min_position_age} minutes")
            return False
        else:
            print(f"\n⏱️ Position age: {minutes_since_open:.1f} minutes (minimum {min_position_age} minutes required)")
            return True
            
    def _analyze_position_for_exit(self, position_type, min_against_candles):
        """Analyze candle history to determine if we should exit the position
        
        Args:
            position_type: Current position type ("BUY" or "SELL")
            min_against_candles: Minimum candles showing reversal needed
            
        Returns:
            bool: True if we should exit the position, False otherwise
        """
        try:
            # Look at a longer history of candles
            min_history_candles = 5
            candle_history_length = min(min_history_candles, len(self.df))
            candle_history = [self.df.iloc[-i] for i in range(1, candle_history_length+1)]
            
            # Get EMA values for all candles in our history
            fast_ema_values = [candle['fast_ema'] for candle in candle_history]
            slow_ema_values = [candle['slow_ema'] for candle in candle_history]
            close_values = [candle['close'] for candle in candle_history]
            
            # Current values (newest candle)
            fast_ema_current = fast_ema_values[0]
            slow_ema_current = slow_ema_values[0]
            current_close = close_values[0]
            
            # Calculate EMA crossing and direction
            fast_above_slow = fast_ema_current > slow_ema_current
            
            # Debug print values before calculating deltas
            print(f"\n🔍 DEBUG: EMA Values for Analysis")
            print(f"Fast EMA values: {fast_ema_values}")
            print(f"Slow EMA values: {slow_ema_values}")
            print(f"Close values: {close_values}")
            
            # Make sure we have enough values to calculate deltas
            if len(fast_ema_values) < 2:
                print("❌ Not enough data points to calculate EMA deltas")
                return False
            
            # Analyze fast EMA direction over multiple candles
            ema_deltas = [fast_ema_values[i] - fast_ema_values[i+1] for i in range(len(fast_ema_values)-1)]
            price_deltas = [close_values[i] - close_values[i+1] for i in range(len(close_values)-1)]
            
            # Check if the most recent fast EMA movement is against our position
            current_ema_delta = ema_deltas[0] if ema_deltas else 0
            
            # Print detailed info about the current values
            print(f"\n📈 Current EMA Analysis:")
            print(f"Current Fast EMA: {fast_ema_current:.6f}")
            print(f"Current Slow EMA: {slow_ema_current:.6f}")
            print(f"Fast Above Slow: {fast_above_slow}")
            print(f"Current Fast EMA Delta: {current_ema_delta:.8f}")
            print(f"EMA Deltas: {ema_deltas}")
            print(f"Price Deltas: {price_deltas}")
            
            # Determine position-specific analysis
            if position_type == "BUY":
                return self._analyze_buy_position_for_exit(fast_ema_current, slow_ema_current, ema_deltas, 
                                                          price_deltas, current_ema_delta, fast_above_slow, 
                                                          min_against_candles)
            elif position_type == "SELL":
                return self._analyze_sell_position_for_exit(fast_ema_current, slow_ema_current, ema_deltas, 
                                                           price_deltas, current_ema_delta, fast_above_slow, 
                                                           min_against_candles)
            else:
                print(f"Unknown position type: {position_type}")
                return False
        except Exception as e:
            print(f"❌ Error in _analyze_position_for_exit: {e}")
            import traceback
            traceback.print_exc()
            return False
            
    def _analyze_buy_position_for_exit(self, fast_ema_current, slow_ema_current, ema_deltas, 
                                      price_deltas, current_ema_delta, fast_above_slow, min_against_candles):
        """Analyze if a BUY position should be exited
        
        Args:
            fast_ema_current: Current fast EMA value
            slow_ema_current: Current slow EMA value
            ema_deltas: List of EMA delta values (newest to oldest)
            price_deltas: List of price delta values (newest to oldest)
            current_ema_delta: Most recent EMA delta
            fast_above_slow: Whether fast EMA is above slow EMA
            min_against_candles: Minimum candles showing reversal needed
            
        Returns:
            bool: True if we should exit the position, False otherwise
        """
        # For BUY positions
        profitable = fast_above_slow  # Fast EMA still above slow EMA
        ema_against_position = current_ema_delta < 0  # Negative delta = fast EMA going down
        
        # Check if we have any additional evidence of reversal in the candle history
        # Count how many of the last candles show EMA moving against our position
        against_count = sum(1 for delta in ema_deltas if delta < 0)
        
        # Print detailed analysis of candle history
        print(f"\n📊 BUY Position Candle History Analysis (newest to oldest):")
        print(f"Current Fast EMA: {fast_ema_current:.5f}")
        print(f"Current Slow EMA: {slow_ema_current:.5f}")
        print(f"Fast EMA deltas: {', '.join([f'{d:.7f}' for d in ema_deltas])}")
        print(f"Price deltas: {', '.join([f'{d:.7f}' for d in price_deltas])}")
        print(f"Current EMA Delta: {current_ema_delta:.7f} ({'DOWN' if current_ema_delta < 0 else 'UP'})")
        print(f"Candles showing EMA against position: {against_count}/{len(ema_deltas)}")
        print(f"Fast EMA vs Slow EMA: {fast_ema_current:.5f} vs {slow_ema_current:.5f} (Profitable: {profitable})")
        print(f"Required against candles for profit/loss: {min_against_candles}")
        
        # PROFIT TAKING: Take profit if multiple candles show fast EMA movement against our position
        # and we're still profitable
        if profitable and ema_against_position and against_count >= min_against_candles:
            print(f"\n💰 PROFIT TAKING SIGNAL: Fast EMA trending down in BUY position")
            print(f"Evidence from candle history: {against_count}/{len(ema_deltas)} candles show downward movement")
            print(f"Still profitable (Fast EMA > Slow EMA): {fast_ema_current:.5f} > {slow_ema_current:.5f}")
            return True
            
        # LOSS CUTTING: Cut losses if both EMAs are clearly trending down for multiple candles
        # or if the fast EMA has crossed below the slow EMA
        elif not profitable and against_count >= min_against_candles:
            print(f"\n✂️ LOSS CUTTING SIGNAL: Fast EMA below Slow EMA in BUY position")
            print(f"Evidence from candle history: {against_count}/{len(ema_deltas)} candles show downward movement")
            print(f"Position not profitable (Fast EMA < Slow EMA): {fast_ema_current:.5f} < {slow_ema_current:.5f}")
            return True
            
        print("No position management signal detected for BUY position")
        return False
        
    def _analyze_sell_position_for_exit(self, fast_ema_current, slow_ema_current, ema_deltas, 
                                       price_deltas, current_ema_delta, fast_above_slow, min_against_candles):
        """Analyze if a SELL position should be exited
        
        Args:
            fast_ema_current: Current fast EMA value
            slow_ema_current: Current slow EMA value
            ema_deltas: List of EMA delta values (newest to oldest)
            price_deltas: List of price delta values (newest to oldest)
            current_ema_delta: Most recent EMA delta
            fast_above_slow: Whether fast EMA is above slow EMA
            min_against_candles: Minimum candles showing reversal needed
            
        Returns:
            bool: True if we should exit the position, False otherwise
        """
        # For SELL positions
        profitable = not fast_above_slow  # Fast EMA still below slow EMA
        ema_against_position = current_ema_delta > 0  # Positive delta = fast EMA going up
        
        # Check if we have any additional evidence of reversal in the candle history
        # Count how many of the last candles show EMA moving against our position
        against_count = sum(1 for delta in ema_deltas if delta > 0)
        
        # Print detailed analysis of candle history
        print(f"\n📊 SELL Position Candle History Analysis (newest to oldest):")
        print(f"Current Fast EMA: {fast_ema_current:.5f}")
        print(f"Current Slow EMA: {slow_ema_current:.5f}")
        print(f"Fast EMA deltas: {', '.join([f'{d:.7f}' for d in ema_deltas])}")
        print(f"Price deltas: {', '.join([f'{d:.7f}' for d in price_deltas])}")
        print(f"Current EMA Delta: {current_ema_delta:.7f} ({'UP' if current_ema_delta > 0 else 'DOWN'})")
        print(f"Candles showing EMA against position: {against_count}/{len(ema_deltas)}")
        print(f"Fast EMA vs Slow EMA: {fast_ema_current:.5f} vs {slow_ema_current:.5f} (Profitable: {profitable})")
        print(f"Required against candles for profit/loss: {min_against_candles}")
        
        # PROFIT TAKING: Take profit if multiple candles show fast EMA movement against our position
        # and we're still profitable
        if profitable and ema_against_position and against_count >= min_against_candles:
            print(f"\n💰 PROFIT TAKING SIGNAL: Fast EMA trending up in SELL position")
            print(f"Evidence from candle history: {against_count}/{len(ema_deltas)} candles show upward movement")
            print(f"Still profitable (Fast EMA < Slow EMA): {fast_ema_current:.5f} < {slow_ema_current:.5f}")
            return True
            
        # LOSS CUTTING: Cut losses if both EMAs are clearly trending up for multiple candles
        # or if the fast EMA has crossed above the slow EMA
        elif not profitable and against_count >= min_against_candles:
            print(f"\n✂️ LOSS CUTTING SIGNAL: Fast EMA above Slow EMA in SELL position")
            print(f"Evidence from candle history: {against_count}/{len(ema_deltas)} candles show upward movement")
            print(f"Position not profitable (Fast EMA > Slow EMA): {fast_ema_current:.5f} > {slow_ema_current:.5f}")
            return True
        
        print("No position management signal detected for SELL position")
        return False

class RiskManager:
    """Handles position sizing and risk calculations"""
    
    @staticmethod
    def calculate_lot_size(symbol_info, account_balance, risk_percentage, stop_distance):
        """Calculate the appropriate lot size based on account balance and risk
        
        Args:
            symbol_info: Symbol information from MT5
            account_balance: Current account balance
            risk_percentage: Percentage of account to risk
            stop_distance: Distance to stop loss in price units
            
        Returns:
            float: Position size in lots
        """
        risk_amount = account_balance * risk_percentage
        pip_value = symbol_info.trade_contract_size * stop_distance
        lot_size = risk_amount / pip_value
        
        # Round to the nearest valid volume step
        lot_size = round(lot_size / symbol_info.volume_step) * symbol_info.volume_step
        
        # Ensure within symbol limits
        return max(min(lot_size, symbol_info.volume_max), symbol_info.volume_min)
    
    @staticmethod
    def calculate_stop_distance(price, risk_percentage, symbol_info):
        """Calculate stop loss distance based on risk percentage
        
        Args:
            price: Current price
            risk_percentage: Percentage of risk
            symbol_info: Symbol information from MT5
            
        Returns:
            float: Stop loss distance
        """
        base_distance = price * risk_percentage
        min_stop_distance = symbol_info.trade_stops_level * symbol_info.point
        return max(base_distance, min_stop_distance)
        
    @staticmethod
    def calculate_position_size(account_balance, risk_percentage, entry_price, stop_loss, symbol_info):
        """Calculate position size based on risk management parameters
        
        Args:
            account_balance: Current account balance
            risk_percentage: Percentage of account to risk
            entry_price: Entry price for the trade
            stop_loss: Stop loss price
            symbol_info: Symbol information from MT5
            
        Returns:
            float: Position size in lots
        """
        risk_amount = account_balance * risk_percentage
        price_risk = abs(entry_price - stop_loss)
        position_size = risk_amount / (price_risk * symbol_info.trade_contract_size)
        
        # Round to the nearest valid volume step
        position_size = round(position_size / symbol_info.volume_step) * symbol_info.volume_step
        
        # Ensure within symbol limits
        return max(min(position_size, symbol_info.volume_max), symbol_info.volume_min)
        
    @staticmethod
    def calculate_stop_and_take_profit(price, action, stop_distance, tp_ratio=1.0):
        """Calculate stop loss and take profit levels
        
        Args:
            price: Entry price
            action: Trade action ("buy" or "sell")
            stop_distance: Distance to stop loss
            tp_ratio: Take profit to stop loss ratio (default 1.0 for 1:1 risk/reward)
            
        Returns:
            tuple: (stop_loss_price, take_profit_price)
        """
        if action == "buy":
            sl = price - stop_distance
            tp = price + (stop_distance * tp_ratio)
        else:  # sell
            sl = price + stop_distance
            tp = price - (stop_distance * tp_ratio)
            
        return sl, tp

class DataFetcher:
    """Handles data retrieval and preparation"""
    
    @staticmethod
    def get_historical_data(symbol, timeframe=mt5.TIMEFRAME_M1, count=100):
        """Get historical price data for EMA calculation
        
        Args:
            symbol: Trading symbol
            timeframe: MT5 timeframe constant (default: M1)
            count: Number of candles to retrieve
            
        Returns:
            DataFrame or None: DataFrame with price data and EMAs, or None on failure
        """
        # Get additional candles for slope calculation
        total_candles = count + SIGNAL_FILTERS['SLOPE_PERIODS']
        
        rates = mt5.copy_rates_from_pos(symbol, timeframe, 0, total_candles)
        if rates is None:
            print("❌ Failed to get historical data")
            return None
            
        df = pd.DataFrame(rates)
        df['time'] = pd.to_datetime(df['time'], unit='s')
        
        # Calculate EMAs using the EMACalculator
        return EMACalculator.calculate_emas_for_dataframe(df)
        
    @staticmethod
    def get_current_price(symbol, price_type="both"):
        """Get current price for a symbol
        
        Args:
            symbol: Trading symbol
            price_type: Price type to return - "bid", "ask", or "both" (default)
            
        Returns:
            float or tuple: Current price(s)
        """
        tick = mt5.symbol_info_tick(symbol)
        if tick is None:
            print(f"Failed to get price for {symbol}")
            return None
        
        if price_type == "bid":
            return tick.bid
        elif price_type == "ask":
            return tick.ask
        else:
            return (tick.bid, tick.ask)
            
    @staticmethod
    def get_symbol_info(symbol):
        """Get symbol information
        
        Args:
            symbol: Trading symbol
            
        Returns:
            SymbolInfo object or None: Symbol information from MT5
        """
        symbol_info = mt5.symbol_info(symbol)
        if symbol_info is None:
            print(f"Failed to get symbol info for {symbol}")
            return None
        return symbol_info

class MT5Helper:
    """Helper class for MT5 operations"""
    
    @staticmethod
    def initialize_mt5():
        """Initialize connection to MetaTrader 5 platform
        
        Returns:
            bool: True if initialization successful, False otherwise
        """
        if not mt5.initialize(login=ACCOUNT_CONFIG['LOGIN'], 
                             password=ACCOUNT_CONFIG['PASSWORD'], 
                             server=ACCOUNT_CONFIG['SERVER']):
            print("❌ Initialization failed:", mt5.last_error())
            return False
        return True
    
    @staticmethod
    def check_autotrading_enabled():
        """Check if AutoTrading is enabled in MT5 terminal
        
        Returns:
            bool: True if AutoTrading is enabled, False otherwise
        """
        terminal_info = mt5.terminal_info()
        if terminal_info is None or not terminal_info.trade_allowed:
            print("\n❌ ERROR: AutoTrading is disabled in MT5 terminal!")
            print("Please enable AutoTrading (click the 'AutoTrading' button in MT5 toolbar)")
            return False
        return True
    
    @staticmethod
    def get_account_info():
        """Get current account information
        
        Returns:
            AccountInfo object or None if failed
        """
        account = mt5.account_info()
        if account is None:
            print("Failed to get account info")
            return None
        return account
        
    @staticmethod
    def is_trade_successful(result):
        """Check if a trade was successful based on MT5's result
        
        Args:
            result: MT5 order result object
            
        Returns:
            bool: True if trade was successful
        """
        return (
            result and result.retcode in [10009, 10027] 
            or str(mt5.last_error()) == "(1, 'Success')"
        ) and result.deal > 0
    
    @staticmethod
    def is_modification_successful(result):
        """Check if a position modification was successful
        
        Args:
            result: MT5 order result object
            
        Returns:
            bool: True if modification was successful
        """
        return (
            result and result.retcode in [10009, 10027] 
            or str(mt5.last_error()) == "(1, 'Success')"
        )
        
    @staticmethod
    def get_open_positions(symbol=None):
        """Get all open positions for a symbol or all symbols
        
        Args:
            symbol: Trading symbol or None for all symbols
            
        Returns:
            tuple or None: Open positions from MT5
        """
        if symbol:
            return mt5.positions_get(symbol=symbol)
        else:
            return mt5.positions_get()
            
    @staticmethod
    def shutdown():
        """Shutdown MT5 connection"""
        mt5.shutdown()

class TradeExecutor:
    """Handles trade execution and position management"""
    
    @staticmethod
    def close_position(symbol, position):
        """Close an open position
        
        Args:
            symbol: Trading symbol
            position: Position object to close
            
        Returns:
            bool: True if position was closed successfully
        """
        # Get the current price for the close
        price = mt5.symbol_info_tick(symbol).ask if position.type == mt5.POSITION_TYPE_SELL else mt5.symbol_info_tick(symbol).bid
        
        # Create the request
        close_request = {
            "action": mt5.TRADE_ACTION_DEAL,
            "symbol": symbol,
            "position": position.ticket,  # Use the ticket number, not the position object
            "volume": position.volume,
            "type": mt5.ORDER_TYPE_BUY if position.type == mt5.POSITION_TYPE_SELL else mt5.ORDER_TYPE_SELL,
            "price": price,  # Current market price
            "deviation": RISK_CONFIG['DEVIATION'],
            "magic": RISK_CONFIG['MAGIC_NUMBER'],
            "comment": "Close position",
            "type_time": mt5.ORDER_TIME_GTC,
            "type_filling": mt5.ORDER_FILLING_IOC,
        }
        
        # Send order to close position
        result = mt5.order_send(close_request)
        if not MT5Helper.is_trade_successful(result):
            print(f"Failed to close position {position.ticket}: {mt5.last_error()}")
            return False
            
        print(f"Position {position.ticket} closed successfully")
        return True

    @staticmethod
    def find_and_close_positions(symbol, current_signal, close_type="OPPOSITE"):
        """Find and close positions based on the current signal
        
        Args:
            symbol: Trading symbol
            current_signal: Current trading signal ("BUY", "SELL")
            close_type: Type of positions to close - "OPPOSITE" (default) or "ALL"
        
        Returns:
            bool: True if positions were closed successfully
        """
        positions = MT5Helper.get_open_positions(symbol)
        if positions is None or len(positions) == 0:
            print(f"No positions found to close")
            return False
        
        positions_closed = False
        
        if close_type == "ALL":
            # Close all positions regardless of type
            print(f"Closing ALL positions for {symbol}")
            for position in positions:
                position_type = "BUY" if position.type == mt5.POSITION_TYPE_BUY else "SELL"
                print(f"\nClosing {position_type} position {position.ticket}")
                if TradeExecutor.close_position(symbol, position):
                    positions_closed = True
                else:
                    print(f"Warning: Failed to close position {position.ticket}")
        else:
            # Close only positions opposite to the current signal
            close_position_type = mt5.POSITION_TYPE_SELL if current_signal == "BUY" else mt5.POSITION_TYPE_BUY
            
            for position in positions:
                if position.type == close_position_type:
                    position_type = "SELL" if position.type == mt5.POSITION_TYPE_SELL else "BUY"
                    print(f"\nClosing {position_type} position {position.ticket} before opening new {current_signal}")
                    if TradeExecutor.close_position(symbol, position):
                        positions_closed = True
                    else:
                        print(f"Warning: Failed to close position {position.ticket}")
        
        return positions_closed

    @staticmethod
    def execute_trade(symbol, action, risk_percentage):
        """Execute a trade with the given parameters
        
        Args:
            symbol: Trading symbol
            action: Trade action ("buy" or "sell")
            risk_percentage: Risk percentage for the trade
            
        Returns:
            tuple: (success_bool, position_ticket)
        """
        # Get symbol info for price digits
        symbol_info = DataFetcher.get_symbol_info(symbol)
        if symbol_info is None:
            return False, None
        
        digits = symbol_info.digits
    
        # Get the current price
        price = DataFetcher.get_current_price(symbol, "ask" if action == "buy" else "bid")
        if not price:
            print("❌ Failed to get current price")
            return False, None
    
        # Get account info for risk calculation
        account = MT5Helper.get_account_info()
        if account is None:
            print("❌ Failed to get account info")
            return False, None
    
        print(f"🔍 {action.upper()} @ {price}")
    
        # Calculate stop distance
        stop_distance = RiskManager.calculate_stop_distance(price, RISK_CONFIG['RISK_PERCENTAGE'], symbol_info)
        
        # Calculate appropriate lot size based on risk
        volume = RiskManager.calculate_lot_size(symbol_info, account.balance, risk_percentage, stop_distance)
        print(f"💱 Volume: {volume} lots | Risk: ${account.balance * risk_percentage:.2f}")
    
        # Store initial positions to compare later
        initial_positions = MT5Helper.get_open_positions(symbol)
        initial_position_tickets = set()
        if initial_positions:
            initial_position_tickets = {pos.ticket for pos in initial_positions}
    
        # Create trade request without SL/TP first
        request = {
            "action": mt5.TRADE_ACTION_DEAL,
            "symbol": symbol,
            "volume": float(volume),
            "type": mt5.ORDER_TYPE_BUY if action == "buy" else mt5.ORDER_TYPE_SELL,
            "price": price,
            "deviation": RISK_CONFIG['DEVIATION'],
            "magic": RISK_CONFIG['MAGIC_NUMBER'],
            "comment": "EMA crossover",
            "type_time": mt5.ORDER_TIME_GTC,
            "type_filling": mt5.ORDER_FILLING_IOC,
        }
    
        result = mt5.order_send(request)
        if not MT5Helper.is_trade_successful(result):
            print(f"❌ Failed to execute {action} trade: {mt5.last_error()}")
            return False, None
    
        print(f"✅ {action.upper()} order sent - Deal #{result.deal}")
    
        # Find the new position and set SL/TP
        position = None
        for i in range(10):  # Try a few times to get the position
            positions = MT5Helper.get_open_positions(symbol)
            if positions:
                for pos in positions:
                    if pos.ticket not in initial_position_tickets:
                        position = pos
                        break
            if position:
                break
            time.sleep(0.1)
    
        if not position:
            print("⚠️ Could not find position to set SL/TP")
            return True, result.deal  # Trade was still successful
    
        # Calculate SL and TP based on risk percentage
        sl, tp = RiskManager.calculate_stop_and_take_profit(price, action, stop_distance)
    
        # Round to appropriate number of digits
        sl = round(sl, digits)
        tp = round(tp, digits)
    
        print(f"🛡️ SL: {sl} | 🎯 TP: {tp}")
    
        # Create modify request
        modify_request = {
            "action": mt5.TRADE_ACTION_SLTP,
            "symbol": symbol,
            "sl": sl,
            "tp": tp,
            "position": position.ticket
        }
    
        modify_result = mt5.order_send(modify_request)
        
        if not MT5Helper.is_modification_successful(modify_result):
            print(f"⚠️ Failed to set SL/TP: {mt5.last_error()}")
        
        return True, position.ticket

class SignalProcessor:
    """Handles signal detection and processing"""
    
    @staticmethod
    def get_current_signal(symbol, analyzer):
        """Get current trading signal based on EMA crossover check
        
        Args:
            symbol: Trading symbol
            analyzer: SignalAnalyzer instance
            
        Returns:
            str or None: "BUY", "SELL", or None if no clear signal
        """
        # Use the same crossover logic as get_ema_signals
        return SignalProcessor.get_ema_signals(symbol, None, None, analyzer)
    
    @staticmethod
    def get_ema_signals(symbol, prev_signal=None, position_entry_time=None, analyzer=None):
        """Get trading signals based on EMA crossover with additional filters
        
        Args:
            symbol: Trading symbol
            prev_signal: Previous trading signal (can be None)
            position_entry_time: Not used, kept for backward compatibility
            analyzer: SignalAnalyzer instance
            
        Returns:
            str or None: Trading signal or None if no clear signal
        """
        # Ensure analyzer is provided
        if analyzer is None:
            raise ValueError("Analyzer must be provided to get_ema_signals")
        
        # Use the analyzer's data
        df = analyzer.df
        symbol_info = analyzer.symbol_info
        
        # Check for consistent trend direction based only on recent candle history
        # This doesn't depend on previous signals or position entry time
        trend_signal = analyzer.check_trend()
        if trend_signal:
            return trend_signal
        
        # Get current and previous values
        if len(df) < 2:
            print("Not enough candles for crossover analysis")
            return prev_signal
            
        current_fast = df['fast_ema'].iloc[-1]
        current_slow = df['slow_ema'].iloc[-1]
        prev_fast = df['fast_ema'].iloc[-2]
        prev_slow = df['slow_ema'].iloc[-2]
        
        diff = current_fast - current_slow
        diff_points = abs(diff / symbol_info.point)
        
        # Only proceed if minimum crossover threshold is met
        if diff_points < SIGNAL_FILTERS['MIN_CROSSOVER_POINTS']:
            return prev_signal
        
        # Check for crossover
        potential_signal = None
        crossover_detected = False
    
        if prev_fast <= prev_slow and current_fast > current_slow:
            crossover_detected = True
            if not prev_signal or prev_signal == "SELL":
                potential_signal = "BUY"
        elif prev_fast >= prev_slow and current_fast < current_slow:
            crossover_detected = True
            if not prev_signal or prev_signal == "BUY":
                potential_signal = "SELL"
                
        # If we detect a crossover, analyze it
        if crossover_detected and potential_signal:
            print(f"\nAnalyzing potential {potential_signal} Signal:")
            print(f"Initial Crossover: {diff_points:.1f} points")
            print(f"Fast EMA: {current_fast:.5f}")
            print(f"Slow EMA: {current_slow:.5f}")
            
            slope_ok = analyzer.check_slope_conditions(potential_signal)
            separation_ok = analyzer.check_separation(potential_signal)
            price_ok = analyzer.check_price_confirmation(potential_signal)
            
            if slope_ok and separation_ok and price_ok:
                print(f"\n✅ Valid {potential_signal} Signal - All conditions met")
                print(f"Price: {df['close'].iloc[-1]:.2f}")
                print(f"Fast EMA: {current_fast:.2f}")
                print(f"Slow EMA: {current_slow:.2f}")
                return potential_signal
    
        return prev_signal

def parse_arguments():
    """Parse command line arguments
    
    Returns:
        argparse.Namespace: Parsed arguments
    """
    parser = argparse.ArgumentParser(description='EMA Crossover Trading Strategy')
    parser.add_argument('symbol', help='Trading symbol (e.g., XAUUSD.s)')
    parser.add_argument('--risk', type=float, default=1.0, 
                       help='Risk percentage per trade (default: 1.0 means 1%)')
    parser.add_argument('--trade-on-start', action='store_true', 
                       help='Execute a trade based on current EMA positions at startup')
    return parser.parse_args()

def handle_initial_position(symbol, risk):
    """Handle initial position setup if trading on start
    
    Args:
        symbol: Trading symbol
        risk: Risk percentage (decimal)
        
    Returns:
        tuple: (signal, position_entry_time, position_ticket) or (None, None, None) if no trade
    """
    print("\nChecking current EMA positions...")
    df = DataFetcher.get_historical_data(symbol)
    if df is None:
        print("Failed to get historical data - waiting for crossover")
        return None, None, None
        
    current_fast = df['fast_ema'].iloc[-1]
    current_slow = df['slow_ema'].iloc[-1]
    
    print(f"Fast EMA: {current_fast:.5f}")
    print(f"Slow EMA: {current_slow:.5f}")
    
    if current_fast > current_slow:
        signal = "BUY"
    else:
        signal = "SELL"
        
    print(f"\nInitializing {signal} position based on current EMA positions")
    action = signal.lower()
    TradeExecutor.find_and_close_positions(symbol, signal)
    success, ticket = TradeExecutor.execute_trade(symbol, action, risk)
    
    if success:
        print("Initial trade executed successfully")
        position_entry_time = datetime.now()  # Record position entry time
        
        # Debug position entry time
        print(f"\n⏱️ DEBUG: Position Entry Time Set")
        print(f"position_entry_time = {position_entry_time} (Type: {type(position_entry_time)})")
        print(f"Current system time: {datetime.now()}")
        
        return signal, position_entry_time, ticket
    else:
        print("Failed to execute initial trade")
        return None, None, None

def handle_position_management(symbol, current_position_type, position_entry_time, analyzer):
    """Handle position management (profit taking, loss cutting)
    
    Args:
        symbol: Trading symbol
        current_position_type: Current position type ("buy" or "sell")
        position_entry_time: Datetime when position was opened
        analyzer: SignalAnalyzer instance
        
    Returns:
        tuple: (action_taken, in_position, current_position_type, position_entry_time)
            action_taken: True if position was closed
            in_position: False if position was closed
            current_position_type: None if position was closed
            position_entry_time: None if position was closed
    """
    try:
        # Ensure analyzer is provided
        if analyzer is None:
            raise ValueError("Analyzer must be provided to handle_position_management")
        
        # Print debug info for position type
        print(f"⚙️ Position check: {current_position_type.upper() if current_position_type else 'None'}")
        
        print(f"\n⚙️ Checking position management for {current_position_type.upper()} position")
        
        # Make sure we convert the position type to uppercase for the analyzer
        position_type_upper = current_position_type.upper() if current_position_type else None
        
        # Check if we should take profits or cut losses
        if analyzer.check_profit_taking(position_type_upper, position_entry_time):
            # Determine if we're taking profit or cutting loss based on EMA positions
            fast_ema = analyzer.df['fast_ema'].iloc[-1]
            slow_ema = analyzer.df['slow_ema'].iloc[-1]
            
            # For BUY positions: profitable if fast_ema > slow_ema
            # For SELL positions: profitable if fast_ema < slow_ema
            is_profitable = (position_type_upper == "BUY" and fast_ema > slow_ema) or \
                           (position_type_upper == "SELL" and fast_ema < slow_ema)
            
            if is_profitable:
                print(f"\n💰 Taking profits on {position_type_upper} position")
            else:
                print(f"\n✂️ Cutting losses on {position_type_upper} position")
            
            # Close all positions
            print(f"‼️ CLOSING POSITION at {datetime.now()}")
            positions_closed = TradeExecutor.find_and_close_positions(symbol, position_type_upper, "ALL")
            
            if positions_closed:
                print(f"✅ Position closed")
                position_entry_time = None
                return True, False, None, None
    except Exception as e:
        print(f"Error during position management check: {e}")
        import traceback
        traceback.print_exc()
    
    return False, True, current_position_type, position_entry_time

def check_for_immediate_reversal(symbol, risk, analyzer):
    """Check if there's an immediate reversal after closing a position
    
    Args:
        symbol: Trading symbol
        risk: Risk percentage (decimal)
        analyzer: SignalAnalyzer instance
        
    Returns:
        tuple: (signal, position_entry_time, ticket) or (None, None, None) if no reversal
    """
    # Ensure analyzer is provided
    if analyzer is None:
        raise ValueError("Analyzer must be provided to check_for_immediate_reversal")
    
    df = analyzer.df
    
    # Check if fast EMA has crossed the slow EMA, indicating a strong reversal
    if len(df) < 2:
        print("Not enough candles for reversal analysis")
        return None, None, None
    
    prev_fast = df['fast_ema'].iloc[-2]
    prev_slow = df['slow_ema'].iloc[-2]
    current_fast = df['fast_ema'].iloc[-1]
    current_slow = df['slow_ema'].iloc[-1]
    
    crossover_buy = prev_fast <= prev_slow and current_fast > current_slow
    crossover_sell = prev_fast >= prev_slow and current_fast < current_slow
    
    if crossover_buy or crossover_sell:
        new_signal = "BUY" if crossover_buy else "SELL"
        print(f"⚡ REVERSAL: Immediate {new_signal} signal")
        
        # Execute the trade immediately
        new_action = new_signal.lower()
        success, ticket = TradeExecutor.execute_trade(symbol, new_action, risk)
        
        if success:
            print(f"✅ {new_signal} position opened (reversal)")
            position_entry_time = datetime.now()
            return new_signal, position_entry_time, ticket
    
    return None, None, None

def main():
    """Main function to run the EMA crossover trading strategy"""
    args = parse_arguments()
    risk = args.risk / 100.0  # Convert percentage to decimal

    # Initialize MT5 and check requirements
    if not MT5Helper.initialize_mt5():
        return
    
    if not MT5Helper.check_autotrading_enabled():
        MT5Helper.shutdown()
        return
    
    account = MT5Helper.get_account_info()
    if account is None:
        MT5Helper.shutdown()
        return

    print(f"\n🚀 Trading {args.symbol} with {EMA_CONFIG['FAST_EMA']}/{EMA_CONFIG['SLOW_EMA']} EMA")
    print(f"💰 Risk: {args.risk}% | Balance: ${account.balance:.2f}")
    
    # Trading state variables
    last_signal_time = None
    last_signal = None
    in_position = False
    current_position_type = None
    position_entry_time = None  # Track when position was opened
    position_ticket = None  # Track position ticket number
    
    # Create a persistent analyzer that we'll update with new data each iteration
    # Initialize it with empty data for now - we'll update it in the loop
    analyzer = None
    
    # Check current EMA positions if trading on start is enabled
    if args.trade_on_start:
        last_signal, position_entry_time, position_ticket = handle_initial_position(args.symbol, risk)
        if last_signal:
            last_signal_time = datetime.now()
            in_position = True
            current_position_type = last_signal.lower()
    
    print("\n🤖 Bot running... Press Ctrl+C to stop")

    # Main trading loop
    try:
        while True:
            try:
                current_time = datetime.now()
                
                # Check for new signals every second
                if last_signal_time is None or (current_time - last_signal_time).total_seconds() >= 1:
                    
                    # ===== STEP 1: FETCH MARKET DATA =====
                    # Always fetch latest data to update our analyzer
                    df = DataFetcher.get_historical_data(args.symbol)
                    symbol_info = DataFetcher.get_symbol_info(args.symbol)
                    
                    if df is None or symbol_info is None:
                        print("❌ Failed to get market data")
                        time.sleep(0.1)
                        continue
                    
                    # ===== STEP 2: UPDATE OR CREATE ANALYZER =====
                    # If this is the first run or if analyzer needs to be recreated
                    if analyzer is None:
                        analyzer = SignalAnalyzer(df, symbol_info)
                    else:
                        # Update the existing analyzer with new data
                        analyzer.df = df
                        analyzer.symbol_info = symbol_info
                        
                        # Call any initialization logic that would normally happen in __init__
                        # This is critical for candle counting during waiting periods
                        if SignalAnalyzer.is_in_waiting_period:
                            current_candle_time = df['time'].iloc[-1]
                            
                            # Only count new candles (if the timestamp is different from last seen)
                            if SignalAnalyzer.last_candle_time is None or current_candle_time != SignalAnalyzer.last_candle_time:
                                SignalAnalyzer.candles_seen_since_profit += 1
                                SignalAnalyzer.last_candle_time = current_candle_time
                                print(f"⏳ Waiting: {SignalAnalyzer.candles_seen_since_profit}/{POSITION_CONFIG['REQUIRED_NEW_CANDLES']} candles")
                                
                                # If we've seen enough new candles, exit post-profit mode
                                if SignalAnalyzer.candles_seen_since_profit >= POSITION_CONFIG['REQUIRED_NEW_CANDLES']:
                                    print(f"✅ Waiting period complete")
                                    SignalAnalyzer.last_profit_time = None
                                    SignalAnalyzer.candles_seen_since_profit = 0
                                    SignalAnalyzer.is_in_waiting_period = False
                    
                    # ===== STEP 3: HANDLE EXISTING POSITIONS =====
                    # Manage any open positions (profit-taking/loss-cutting)
                    if in_position and position_entry_time is not None:
                        position_closed, in_position, current_position_type, position_entry_time = handle_position_management(
                            args.symbol, current_position_type, position_entry_time, analyzer
                        )
                        
                        # If we closed a position, check for immediate reversal opportunity
                        if position_closed:
                            # First, check for immediate reversal before deciding on waiting period
                            new_signal, new_entry_time, new_ticket = check_for_immediate_reversal(args.symbol, risk, analyzer)
                            
                            if new_signal:
                                # If there's an immediate reversal signal, enter the new position without waiting
                                last_signal = new_signal
                                last_signal_time = current_time
                                in_position = True
                                current_position_type = new_signal.lower()
                                position_entry_time = new_entry_time
                                position_ticket = new_ticket
                                continue
                            else:
                                # No immediate reversal detected - activate waiting period
                                print(f"🔍 No reversal - waiting period activated")
                                SignalAnalyzer.reset_after_profit()
                                # Reset trading state since we didn't enter a new position
                                last_signal = None
                                last_signal_time = None
                    
                    # ===== STEP 4: CHECK WAITING PERIOD =====
                    # Skip signal checks if we're in post-profit waiting period
                    if SignalAnalyzer.is_in_waiting_period:
                        time.sleep(0.1)
                        continue
                    
                    # ===== STEP 5: CHECK FOR NEW SIGNALS =====
                    # Pass our persistent analyzer instance 
                    signal = SignalProcessor.get_ema_signals(args.symbol, last_signal, position_entry_time, analyzer)
                    
                    # ===== STEP 6: EXECUTE TRADES IF NEEDED =====
                    if signal and signal != last_signal:
                        action = signal.lower()
                        should_trade = False
                        
                        if not in_position:
                            should_trade = True
                        elif current_position_type != action:  # Signal is opposite to current position
                            should_trade = True
                            print(f"🔄 {current_position_type.upper()} ➡️ {action.upper()}")
                            positions_closed = TradeExecutor.find_and_close_positions(args.symbol, signal)
                            
                            if positions_closed:
                                position_entry_time = None
                        
                        if should_trade:
                            success, ticket = TradeExecutor.execute_trade(args.symbol, action, risk)
                            if success:
                                last_signal = signal
                                last_signal_time = current_time
                                in_position = True
                                current_position_type = action
                                position_entry_time = datetime.now()  # Record position entry time
                                position_ticket = ticket
                                print(f"✅ {action.upper()} position opened")
                
                time.sleep(0.1)  # Check every 100ms
                
            except Exception as e:
                print(f"❌ Error: {e}")
                time.sleep(0.1)
                
    except KeyboardInterrupt:
        print("\n🛑 Bot stopped")
    finally:
        MT5Helper.shutdown()

if __name__ == "__main__":
    main()
