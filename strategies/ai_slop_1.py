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

# AI SLope Strategy Configuration
AI_SLOP_CONFIG = {
    # Risk and Money Management
    'RISK_PERCENT': 0.01,           # 1% risk per trade
    'SL_ATR_MULT': 2.0,             # Stop loss multiplier of ATR
    'TP_ATR_MULT': 4.0,             # Take profit multiplier of ATR
    
    # Filter Thresholds
    'MAX_SPREAD_POINTS': 2000,      # Maximum allowed spread in points (increased for crypto)
    'MAX_VOLATILITY_PERCENT': 0.75, # Maximum allowed ATR as % of price
    'MIN_VOLUME_QUANTILE': 0.1,     # Minimum volume quantile threshold (lowered for crypto)
    
    # Technical Parameters
    'EMA200_SLOPE_LOOKBACK': 50,    # Bars to measure EMA200 slope
    'EMA50_SLOPE_LOOKBACK': 20,     # Bars to measure EMA50 slope
    'MACD_HIST_MEAN_WINDOW': 5,     # Bars for MACD histogram mean
    'RSI_MEAN_WINDOW': 5,           # Bars for RSI mean
    
    # Momentum Thresholds
    'RSI_BULLISH_THRESHOLD': 55,    # RSI above this is bullish
    'RSI_BEARISH_THRESHOLD': 45,    # RSI below this is bearish
    
    # Data Analysis
    'TIMEFRAME': 'M5',              # Timeframe to use for analysis
    'ANALYSIS_HOURS': 24,           # Hours of data to analyze
    'TEMP_DATA_DIR': 'temp_data'    # Directory for temporary data files
}

class AISlope1Strategy(BaseStrategy):
    """
    AI Slope Strategy that analyzes market data before making trading decisions.
    Implements a trend-following approach with momentum confirmation and ATR-based risk management.
    """
    
    def __init__(self, symbol, timeframe, symbol_info, strategy_config=None):
        """Initialize the strategy with default parameters"""
        super().__init__(symbol, timeframe, symbol_info, strategy_config)
        
        # Merge provided config with default config
        self.config = {**AI_SLOP_CONFIG, **(strategy_config or {})}
        
        # State variables
        self.last_trade_close_time = None
        self.analysis_data = None
        self.indicators = {}
        self.derived_metrics = {}
        self.entry_decision = None
        self.price_levels = {'entry': None, 'stop': None, 'tp': None}
        
        # Create temp directory if it doesn't exist
        os.makedirs(self.config['TEMP_DATA_DIR'], exist_ok=True)
        
    def get_required_data_count(self):
        """Return the minimum number of candles needed for this strategy"""
        return 250  # Need enough data for EMA200 and other indicators
    
    def calculate_indicators(self):
        """Indicators are loaded from the analysis data or calculated on demand"""
        pass
    
    # === Internal indicator calculation methods ===
    def _calculate_ema(self, prices, period):
        """Calculate Exponential Moving Average"""
        if len(prices) < period:
            return pd.Series(index=prices.index, dtype='float64')
        return prices.ewm(span=period, adjust=False).mean()
        
    def _calculate_macd(self, prices, fast_period=12, slow_period=26, signal_period=9):
        """Calculate Moving Average Convergence Divergence (MACD)"""
        if len(prices) < slow_period:
            # Return DataFrame with NaN columns if not enough data
            return pd.DataFrame(index=prices.index, data={
                'macd': np.nan,
                'macd_signal': np.nan,
                'macd_hist': np.nan
            })

        ema_fast = prices.ewm(span=fast_period, adjust=False).mean()
        ema_slow = prices.ewm(span=slow_period, adjust=False).mean()

        macd_line = ema_fast - ema_slow
        signal_line = macd_line.ewm(span=signal_period, adjust=False).mean()
        histogram = macd_line - signal_line

        # Create DataFrame with results
        macd_df = pd.DataFrame(index=prices.index)
        macd_df['macd'] = macd_line
        macd_df['macd_signal'] = signal_line
        macd_df['macd_hist'] = histogram

        return macd_df
        
    def _calculate_rsi(self, prices, period=14):
        """Calculate Relative Strength Index (RSI)"""
        if len(prices) < period:
            return pd.Series(index=prices.index, dtype='float64')

        delta = prices.diff()
        gain = (delta.where(delta > 0, 0)).fillna(0)
        loss = (-delta.where(delta < 0, 0)).fillna(0)

        avg_gain = gain.ewm(com=period - 1, min_periods=period, adjust=False).mean()
        avg_loss = loss.ewm(com=period - 1, min_periods=period, adjust=False).mean()

        rs = avg_gain / avg_loss
        rsi = 100 - (100 / (1 + rs))

        # Handle division by zero if avg_loss is 0
        rsi = rsi.replace([np.inf, -np.inf], 100).fillna(50)
        
        return rsi
        
    def _calculate_atr(self, ohlc_data, period=14):
        """
        Calculate Average True Range (ATR)
        """
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
        
    def _calculate_bollinger_bands(self, prices, period=20, std_dev=2):
        """Calculate Bollinger Bands"""
        if len(prices) < period:
            return pd.DataFrame(index=prices.index, data={
                'bb_middle': np.nan,
                'bb_upper': np.nan,
                'bb_lower': np.nan
            })
            
        # Calculate middle band (SMA)
        middle_band = prices.rolling(window=period).mean()
        
        # Calculate standard deviation
        std = prices.rolling(window=period).std()
        
        # Calculate upper and lower bands
        upper_band = middle_band + (std * std_dev)
        lower_band = middle_band - (std * std_dev)
        
        # Create DataFrame with results
        bb_df = pd.DataFrame(index=prices.index)
        bb_df['bb_middle'] = middle_band
        bb_df['bb_upper'] = upper_band
        bb_df['bb_lower'] = lower_band
        
        return bb_df
        
    def _calculate_stochastic(self, ohlc_data, k_period=14, d_period=3, slowing=3):
        """Calculate Stochastic Oscillator"""
        if len(ohlc_data) < k_period:
            return pd.DataFrame(index=ohlc_data.index, data={
                'stoch_k': np.nan,
                'stoch_d': np.nan
            })
            
        # Get high and low for the last k_period periods
        low_min = ohlc_data['low'].rolling(window=k_period).min()
        high_max = ohlc_data['high'].rolling(window=k_period).max()
        
        # Calculate %K
        # %K = (Current Close - Lowest Low) / (Highest High - Lowest Low) * 100
        k = 100 * ((ohlc_data['close'] - low_min) / (high_max - low_min))
        
        # Apply slowing if specified (simple moving average)
        if slowing > 1:
            k = k.rolling(window=slowing).mean()
            
        # Calculate %D (simple moving average of %K)
        d = k.rolling(window=d_period).mean()
        
        # Create DataFrame with results
        stoch_df = pd.DataFrame(index=ohlc_data.index)
        stoch_df['stoch_k'] = k
        stoch_df['stoch_d'] = d
        
        return stoch_df

    def _calculate_directional_legs(self, df):
        """
        Calculate directional legs (continuous price movements in one direction) 
        and their statistics.
        
        Args:
            df (DataFrame): DataFrame with 'close' column
            
        Returns:
            DataFrame: Original df with added 'direction' column
            list: List of leg sizes
            float: Average leg size
            float: Max leg size
            float: Min leg size
        """
        # Determine direction of each candle (up, down, or none)
        df['direction'] = df['close'].diff().apply(
            lambda x: 'up' if x > 0 else 'down' if x < 0 else None
        )
        
        # Find where direction changes to segment into legs
        legs = []
        start_price = df['close'].iloc[0]
        current_dir = df['direction'].iloc[1] if len(df) > 1 else None
        
        # Loop through candles and segment into directional legs
        for i in range(2, len(df)):
            dir_now = df['direction'].iloc[i]
            price_now = df['close'].iloc[i]
            
            if dir_now != current_dir and dir_now is not None:
                # When direction changes, calculate leg size and save it
                leg_size = abs(price_now - start_price)
                legs.append(leg_size)
                
                # Start a new leg
                start_price = price_now
                current_dir = dir_now
        
        # Add the last leg if not already captured
        if len(df) > 1 and (len(legs) == 0 or start_price != df['close'].iloc[-1]):
            legs.append(abs(df['close'].iloc[-1] - start_price))
            
        # Calculate leg statistics
        if legs:
            avg_leg_size = sum(legs) / len(legs)
            max_leg_size = max(legs) if legs else 0
            min_leg_size = min(legs) if legs else 0
        else:
            avg_leg_size = max_leg_size = min_leg_size = 0
            
        return df, legs, avg_leg_size, max_leg_size, min_leg_size
    
    def _run_market_analysis(self):
        """
        Run market analysis to generate data for decision making.
        This is a key step that generates the data for our strategy.
        """
        try:
            # Generate a temporary filename for the analysis data
            timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
            temp_csv = os.path.join(self.config['TEMP_DATA_DIR'], 
                                   f"{self.symbol}_{timestamp}_analysis.csv")
            
            # Map timeframe string to MT5 constant
            timeframe_map = {
                "M1": mt5.TIMEFRAME_M1, "M5": mt5.TIMEFRAME_M5,
                "M15": mt5.TIMEFRAME_M15, "M30": mt5.TIMEFRAME_M30,
                "H1": mt5.TIMEFRAME_H1, "H4": mt5.TIMEFRAME_H4, 
                "D1": mt5.TIMEFRAME_D1
            }
            timeframe = timeframe_map.get(self.config['TIMEFRAME'], mt5.TIMEFRAME_M5)
            
            # Calculate candles to fetch
            hours = self.config['ANALYSIS_HOURS']
            if timeframe == mt5.TIMEFRAME_M1:
                candles_per_hour = 60
            elif timeframe == mt5.TIMEFRAME_M5:
                candles_per_hour = 12
            elif timeframe == mt5.TIMEFRAME_M15:
                candles_per_hour = 4
            elif timeframe == mt5.TIMEFRAME_M30:
                candles_per_hour = 2
            elif timeframe == mt5.TIMEFRAME_H1:
                candles_per_hour = 1
            else:
                candles_per_hour = 1  # Default fallback
                
            num_candles = int(hours * candles_per_hour)
            num_candles = max(num_candles, 250)  # Ensure enough for indicators
            
            print(f"📊 Running market analysis for {self.symbol} ({self.config['TIMEFRAME']}, {self.config['ANALYSIS_HOURS']}h)...")
            print(f"📈 Fetching {num_candles} {self.config['TIMEFRAME']} candles for {self.symbol}...")
                
            # Use existing MT5 connection to get data (no initialize/shutdown)
            rates = mt5.copy_rates_from_pos(self.symbol, timeframe, 0, num_candles)
            if rates is None or len(rates) == 0:
                print(f"❌ Failed to get data for {self.symbol}: {mt5.last_error()}")
                return False
                
            # Create dataframe and calculate indicators
            df = pd.DataFrame(rates)
            df['time'] = pd.to_datetime(df['time'], unit='s', utc=True)
            df.set_index('time', inplace=True)
            
            print(f"✅ Received {len(df)} candles from {df.index[0]} to {df.index[-1]}")
            
            # Calculate indicators using our own methods
            print("🧮 Calculating technical indicators...")
            
            # EMAs
            df['ema_5'] = self._calculate_ema(df['close'], 5)
            df['ema_8'] = self._calculate_ema(df['close'], 8)
            df['ema_13'] = self._calculate_ema(df['close'], 13)
            df['ema_21'] = self._calculate_ema(df['close'], 21)
            df['ema_50'] = self._calculate_ema(df['close'], 50)
            df['ema_200'] = self._calculate_ema(df['close'], 200)
            
            # MACD
            macd_df = self._calculate_macd(df['close'])
            df = df.join(macd_df)
            
            # RSI
            df['rsi'] = self._calculate_rsi(df['close'])
            
            # ATR
            df['atr'] = self._calculate_atr(df)
            
            # Bollinger Bands
            bb_df = self._calculate_bollinger_bands(df['close'])
            df = df.join(bb_df)
            
            # Stochastic
            stoch_df = self._calculate_stochastic(df)
            df = df.join(stoch_df)
            
            # Directional legs
            print("📏 Analyzing price movements and calculating legs...")
            df, legs, avg_leg_size, max_leg_size, min_leg_size = self._calculate_directional_legs(df)
            
            # Add ATR percent
            df['atr_percent'] = (df['atr'] / df['close']) * 100
            
            # Save to CSV
            df.to_csv(temp_csv)
            
            # Load the generated CSV file for processing
            self._load_analysis_data(temp_csv)
            
            # Clean up temporary file
            try:
                os.remove(temp_csv)
            except Exception as e:
                print(f"⚠️ Warning: Could not clean up temporary file: {e}")
                
            return True
        except Exception as e:
            print(f"❌ Error running market analysis: {e}")
            return False
    
    def _load_analysis_data(self, csv_path):
        """
        Load the analysis data from CSV and prepare it for use.
        
        Args:
            csv_path (str): Path to the CSV file with analysis data
        """
        try:
            # Step 1: LOAD DATA
            df = pd.read_csv(csv_path)
            
            # Handle time column naming from market_analyzer output
            time_col = "time" if "time" in df.columns else df.columns[0]
            
            df[time_col] = pd.to_datetime(df[time_col], utc=True)
            df.sort_values(time_col, inplace=True)
            df.set_index(time_col, inplace=True)
            
            # Store the loaded data
            self.analysis_data = df
            
            print(f"✅ Loaded analysis data with {len(df)} rows")
            return True
        except Exception as e:
            print(f"❌ Error loading analysis data: {e}")
            self.analysis_data = None
            return False
    
    def _ensure_indicators(self):
        """
        Step 2: ENSURE INDICATORS
        Ensure all required indicators are available, computing any that are missing.
        """
        if self.analysis_data is None or self.analysis_data.empty:
            print("❌ No analysis data available to compute indicators")
            return False
        
        df = self.analysis_data
        
        # Map of indicator names to their readable column names from market_analyzer
        indicator_map = {
            'ema5': 'EMA (5) - Fast Exponential Moving Average',
            'ema8': 'EMA (8) - Short-term Trend',
            'ema13': 'EMA (13) - Medium-term Trend',
            'ema21': 'EMA (21) - Intermediate Trend',
            'ema50': 'EMA (50) - Medium-Long Trend',
            'ema200': 'EMA (200) - Long-term Trend',
            'rsi14': 'RSI (14) - Relative Strength Index',
            'macd_hist': 'MACD Histogram',
            'atr14': 'ATR (14) - Average True Range',
            'bb_upper': 'Bollinger Band - Upper (2 std dev)',
            'bb_lower': 'Bollinger Band - Lower (2 std dev)',
            'close': 'Close Price',
            'open': 'Open Price',
            'high': 'High Price',
            'low': 'Low Price',
            'spread': 'Spread (Points)',
            'tick_volume': 'Tick Volume',
            'stoch_k': 'Stochastic %K (14,3)',
            'stoch_d': 'Stochastic %D (3-period SMA of %K)',
            'atr_percent': 'ATR % of Price'
        }
        
        # Initialize indicators dictionary
        self.indicators = {}
        
        # Loop through each indicator and get it from the DataFrame or calculate it
        for key, col_name in indicator_map.items():
            # Check if the indicator is already in the DataFrame
            if col_name in df.columns:
                self.indicators[key] = df[col_name]
            else:
                # If not, calculate it based on the key
                if key == 'ema5':
                    self.indicators[key] = self._calculate_ema(df['close'], 5)
                elif key == 'ema8':
                    self.indicators[key] = self._calculate_ema(df['close'], 8)
                elif key == 'ema13':
                    self.indicators[key] = self._calculate_ema(df['close'], 13)
                elif key == 'ema21':
                    self.indicators[key] = self._calculate_ema(df['close'], 21)
                elif key == 'ema50':
                    self.indicators[key] = self._calculate_ema(df['close'], 50)
                elif key == 'ema200':
                    self.indicators[key] = self._calculate_ema(df['close'], 200)
                elif key == 'rsi14':
                    # Use our internal calculation method
                    self.indicators[key] = self._calculate_rsi(df['close'])
                elif key == 'macd_hist':
                    macd_df = self._calculate_macd(df['close'])
                    self.indicators[key] = macd_df['macd_hist']
                elif key == 'atr14':
                    self.indicators[key] = self._calculate_atr(df)
                elif key == 'atr_percent':
                    # Calculate if missing
                    if 'atr14' not in self.indicators:
                        self.indicators['atr14'] = self._calculate_atr(df)
                    self.indicators[key] = (self.indicators['atr14'] / df['close']) * 100
                elif key in ['bb_upper', 'bb_lower']:
                    # Calculate Bollinger Bands if not already present
                    if 'bb_upper' not in self.indicators and 'bb_lower' not in self.indicators:
                        bb_df = self._calculate_bollinger_bands(df['close'])
                        self.indicators['bb_upper'] = bb_df['bb_upper']
                        self.indicators['bb_lower'] = bb_df['bb_lower']
                elif key in ['stoch_k', 'stoch_d']:
                    # Calculate Stochastic if not already present
                    if 'stoch_k' not in self.indicators and 'stoch_d' not in self.indicators:
                        stoch_df = self._calculate_stochastic(df)
                        self.indicators['stoch_k'] = stoch_df['stoch_k']
                        self.indicators['stoch_d'] = stoch_df['stoch_d']
                else:
                    # For basic price data, handle missing columns
                    if key in df.columns:
                        self.indicators[key] = df[key]
                    else:
                        print(f"⚠️ Warning: Could not find or calculate indicator '{key}'")
                        self.indicators[key] = pd.Series(index=df.index, dtype='float64')
        
        print("✅ Indicators prepared")
        return True
        
    def _calculate_derived_metrics(self):
        """
        Step 3: DERIVED METRICS
        Calculate derived metrics used for decision making.
        """
        if not self.indicators:
            print("❌ No indicators available to calculate derived metrics")
            return False
            
        # Get lookback parameters from config
        ema200_lookback = self.config['EMA200_SLOPE_LOOKBACK']
        ema50_lookback = self.config['EMA50_SLOPE_LOOKBACK']
        macd_window = self.config['MACD_HIST_MEAN_WINDOW']
        rsi_window = self.config['RSI_MEAN_WINDOW']
        
        # Calculate slopes and means
        self.derived_metrics = {
            'ema200_slope50': self.indicators['ema200'].diff(ema200_lookback).iloc[-1] / ema200_lookback,
            'ema50_slope20': self.indicators['ema50'].diff(ema50_lookback).iloc[-1] / ema50_lookback,
            'macd_hist_mean5': self.indicators['macd_hist'].tail(macd_window).mean(),
            'rsi_mean5': self.indicators['rsi14'].tail(rsi_window).mean(),
            'stoch_k_last': self.indicators['stoch_k'].iloc[-1],
            'stoch_d_last': self.indicators['stoch_d'].iloc[-1],
            'atr_percent': self.indicators['atr_percent'].iloc[-1]
        }
        
        print("✅ Derived metrics calculated")
        return True
        
    def _apply_filters(self):
        """
        Step 4: FILTERS
        Apply filters to determine if we should skip the trade.
        
        Returns:
            bool: True if all filters pass (trade allowed), False otherwise
        """
        # Get latest values for filtering
        spread = self.indicators['spread'].iloc[-1]
        atr_percent = self.derived_metrics['atr_percent']
        tick_volume = self.indicators['tick_volume'].iloc[-1]
        min_volume = self.indicators['tick_volume'].quantile(self.config['MIN_VOLUME_QUANTILE'])
        
        # Adjust filter thresholds based on symbol type
        is_crypto = 'BTC' in self.symbol or 'ETH' in self.symbol or 'XRP' in self.symbol
        
        # Set appropriate spread limit based on symbol type
        max_spread = self.config['MAX_SPREAD_POINTS']
        if is_crypto:
            # Use higher spread limit for crypto
            max_spread = max(self.config['MAX_SPREAD_POINTS'], 2000)
            print(f"🪙 Detected crypto symbol, using adjusted spread limit: {max_spread}")
        
        # Check each filter
        spread_ok = spread <= max_spread
        volatility_ok = atr_percent <= self.config['MAX_VOLATILITY_PERCENT']
        
        # For volume filtering, be more lenient with crypto
        if is_crypto and tick_volume > 0:
            # For crypto, just ensure we have some minimal volume
            volume_ok = True
            print("🪙 Crypto volume filter: Minimal volume check only")
        else:
            volume_ok = tick_volume >= min_volume
        
        # Log filter results
        print(f"Filter Results:")
        print(f"  - Spread: {spread:.1f} pts {'✅' if spread_ok else '❌'} (max: {max_spread})")
        print(f"  - Volatility: {atr_percent:.2f}% {'✅' if volatility_ok else '❌'} (max: {self.config['MAX_VOLATILITY_PERCENT']}%)")
        print(f"  - Volume: {tick_volume:.0f} {'✅' if volume_ok else '❌'} (min: {min_volume:.0f})")
        
        # Return True only if all filters pass
        return spread_ok and volatility_ok and volume_ok
        
    def _classify_trend(self):
        """
        Step 5: TREND CLASSIFICATION
        Classify the current market trend.
        
        Returns:
            str: 'uptrend', 'downtrend', or 'neutral'
        """
        # Get latest values and slopes
        ema50_last = self.indicators['ema50'].iloc[-1]
        ema200_last = self.indicators['ema200'].iloc[-1]
        ema200_slope = self.derived_metrics['ema200_slope50']
        
        # Classify trend based on EMA relationship and slope
        if (ema50_last > ema200_last) and (ema200_slope > 0):
            trend = 'uptrend'
        elif (ema50_last < ema200_last) and (ema200_slope < 0):
            trend = 'downtrend'
        else:
            trend = 'neutral'
            
        print(f"Trend Classification: {trend.upper()}")
        return trend
        
    def _confirm_momentum(self):
        """
        Step 6: MOMENTUM CONFIRMATION
        Check if momentum indicators confirm the trend direction.
        
        Returns:
            tuple: (bullish_momentum, bearish_momentum)
        """
        # Get momentum indicators
        macd_hist_mean = self.derived_metrics['macd_hist_mean5']
        rsi_mean = self.derived_metrics['rsi_mean5']
        stoch_k = self.derived_metrics['stoch_k_last']
        stoch_d = self.derived_metrics['stoch_d_last']
        
        # Get config thresholds
        rsi_bullish = self.config['RSI_BULLISH_THRESHOLD']
        rsi_bearish = self.config['RSI_BEARISH_THRESHOLD']
        
        # Check bullish momentum conditions
        bullish_mom = (macd_hist_mean > 0) and (rsi_mean > rsi_bullish) and (stoch_k > stoch_d)
        
        # Check bearish momentum conditions
        bearish_mom = (macd_hist_mean < 0) and (rsi_mean < rsi_bearish) and (stoch_k < stoch_d)
        
        print(f"Momentum Analysis:")
        print(f"  - MACD Histogram Mean: {macd_hist_mean:.6f} {'✅' if macd_hist_mean > 0 else '❌'} for bulls")
        print(f"  - RSI Mean: {rsi_mean:.2f} {'✅' if rsi_mean > rsi_bullish else '❌'} for bulls, {'✅' if rsi_mean < rsi_bearish else '❌'} for bears")
        print(f"  - Stochastic K vs D: {stoch_k:.2f} vs {stoch_d:.2f} {'✅' if stoch_k > stoch_d else '❌'} for bulls")
        print(f"  - Overall Momentum: {'BULLISH ✅' if bullish_mom else ''} {'BEARISH ✅' if bearish_mom else ''} {'NEUTRAL ⚠️' if not (bullish_mom or bearish_mom) else ''}")
        
        return (bullish_mom, bearish_mom)
        
    def _make_entry_decision(self):
        """
        Step 7: ENTRY DECISION
        Determine whether to enter a long position, short position, or skip.
        
        Returns:
            str: 'long', 'short', or 'skip'
        """
        # Skip if filters don't pass
        if not self._apply_filters():
            print("❌ Trade skipped: One or more filters failed")
            return 'skip'
            
        # Get trend classification
        trend = self._classify_trend()
        
        # Get momentum confirmation
        bullish_mom, bearish_mom = self._confirm_momentum()
        
        # Make entry decision
        if trend == 'uptrend' and bullish_mom:
            decision = 'long'
            print("🔼 Entry Decision: LONG - Uptrend with bullish momentum")
        elif trend == 'downtrend' and bearish_mom:
            decision = 'short'
            print("🔽 Entry Decision: SHORT - Downtrend with bearish momentum")
        else:
            decision = 'skip'
            print("⏹️ Entry Decision: SKIP - Conditions not optimal")
            
        return decision
        
    def _calculate_price_levels(self):
        """
        Step 8: PRICE LEVELS
        Calculate entry, stop loss, and take profit prices.
        
        Returns:
            dict: Dictionary with 'entry', 'stop', and 'tp' keys
        """
        # Get the latest close price and ATR
        close_price = self.indicators['close'].iloc[-1]
        atr = self.indicators['atr14'].iloc[-1]
        
        # Get ATR multipliers from config
        sl_mult = self.config['SL_ATR_MULT']
        tp_mult = self.config['TP_ATR_MULT']
        
        # Calculate price levels based on entry decision
        if self.entry_decision == 'long':
            entry = close_price
            stop = entry - sl_mult * atr
            tp = entry + tp_mult * atr
        elif self.entry_decision == 'short':
            entry = close_price
            stop = entry + sl_mult * atr
            tp = entry - tp_mult * atr
        else:
            entry = stop = tp = None
            
        # Store the price levels
        self.price_levels = {
            'entry': entry,
            'stop': stop,
            'tp': tp
        }
        
        if entry is not None:
            print(f"Price Levels:")
            print(f"  - Entry: {entry:.5f}")
            print(f"  - Stop Loss: {stop:.5f} ({sl_mult}x ATR)")
            print(f"  - Take Profit: {tp:.5f} ({tp_mult}x ATR)")
            
        return self.price_levels
        
    def generate_entry_signal(self, open_positions=None):
        """
        Generates entry signals based on comprehensive market analysis.
        
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
            wait_time = 300  # 5 minutes wait after closing a position
            
            if time_diff < wait_time:
                print(f"⏳ Waiting for {(wait_time - time_diff)/60:.1f} more minutes after last trade close")
                return None
            
        print("\n🔄 Starting AISlope1 analysis pipeline")
            
        # Step 1-3: Run market analysis and prepare data
        if not self._run_market_analysis():
            return None
            
        # Step 2: Ensure indicators are available
        if not self._ensure_indicators():
            return None
            
        # Step 3: Calculate derived metrics
        if not self._calculate_derived_metrics():
            return None
            
        # Step 7: Make entry decision
        self.entry_decision = self._make_entry_decision()
        
        # Skip if decision is not to enter
        if self.entry_decision == 'skip':
            return None
            
        # Step 8: Calculate price levels
        self._calculate_price_levels()
        
        # We don't calculate position size - the fixed volume from command line is used
        # This matches how the EMA strategy works
        
        # Map decision to MT5 order type
        if self.entry_decision == 'long':
            signal_type = mt5.ORDER_TYPE_BUY
        elif self.entry_decision == 'short':
            signal_type = mt5.ORDER_TYPE_SELL
        else:
            return None
            
        # Return signal with price levels
        entry_price = self.price_levels['entry']
        sl_price = self.price_levels['stop']
        tp_price = self.price_levels['tp']
        
        # Store the signal for next cycle
        self.prev_signal = signal_type
        
        print(f"✅ Generated {self.entry_decision.upper()} signal: Entry={entry_price:.5f}, SL={sl_price:.5f}, TP={tp_price:.5f}")
        
        return signal_type, entry_price, sl_price, tp_price
        
    def generate_exit_signal(self, position):
        """
        This strategy does not generate exit signals - relies on SL/TP.
        
        Args:
            position (mt5.PositionInfo): The open position object to evaluate
            
        Returns:
            bool: Always False - no active exit signals
        """
        # This strategy relies solely on SL/TP for position management
        return False
        
    def reset_signal_state(self):
        """
        Reset strategy internal state after position closing or failed orders.
        Also records the timestamp when a position was closed to prevent immediate reentry.
        """
        # Record the time of the position close
        self.last_trade_close_time = get_server_time()
        print(f"🕒 Position closed at {self.last_trade_close_time}. Waiting before new entry.")
            
        # Call the parent class method to reset other state
        super().reset_signal_state() 