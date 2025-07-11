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
    'SL_ATR_MULT': 3.0,             # Stop loss multiplier of ATR
    'TP_ATR_MULT': 6.0,            # Take profit multiplier of ATR
    
    # Filter Thresholds
    'MAX_SPREAD_POINTS': 2000,      # Maximum allowed spread in points (increased for crypto)
    'MAX_VOLATILITY_PERCENT': 0.75, # Maximum allowed ATR as % of price
    'MIN_VOLUME_QUANTILE': 0.1,     # Minimum volume quantile threshold (lowered for crypto)
    
    # EMA Configuration
    'LONG_EMA_PERIOD': 100,         # Period for the long-term EMA (e.g. 200, 100)
    'MEDIUM_EMA_PERIOD': 25,        # Period for the medium-term EMA
    'FAST_EMA_PERIOD': 13,          # Period for the fast EMA
    'FASTER_EMA_PERIOD': 8,        # Period for the faster EMA
    'FASTEST_EMA_PERIOD': 5,        # Period for the fastest EMA
    'ULTRA_FAST_EMA_PERIOD': 3,     # Period for the ultra-fast EMA
    
    # Technical Parameters
    'LONG_EMA_SLOPE_LOOKBACK': 50,  # Bars to measure long-term EMA slope
    'MEDIUM_EMA_SLOPE_LOOKBACK': 20,# Bars to measure medium-term EMA slope
    'MACD_HIST_MEAN_WINDOW': 5,     # Bars for MACD histogram mean
    'RSI_MEAN_WINDOW': 5,           # Bars for RSI mean
    
    # Trend Strength Parameters
    'MIN_TREND_STRENGTH': 0.3,      # Minimum trend strength score (0-1)
    'PRICE_DISTANCE_FACTOR': 0.5,   # Factor for how close price should be to MA for entry
    
    # Momentum Confirmation Parameters
    'MOMENTUM_INDICATORS_REQUIRED': 3,  # Number of indicators required (3 out of 5 - more strict than before)
    'MOMENTUM_INDICATORS_TOTAL': 5,     # Total number of indicators used (MACD, RSI, Stochastic, EMA50, BB)
    'MOMENTUM_LOOKBACK': 3,             # Additional lookback periods for momentum consistency check
    
    # Momentum Thresholds
    'RSI_BULLISH_THRESHOLD': 55,    # RSI above this is bullish
    'RSI_BEARISH_THRESHOLD': 45,    # RSI below this is bearish
    
    # Trading Behavior
    'ALLOW_REVERSAL_TRADES': False,  # Allow trading potential trend reversals (when momentum contradicts trend)
    
    # Data Analysis
    'TIMEFRAME': 'M1',              # Default timeframe to use for analysis (M1 provides more signals)
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
        
        # The timeframe passed from generic_trader is stored in self.timeframe
        # It's an MT5 constant like mt5.TIMEFRAME_M1, mt5.TIMEFRAME_M5, etc.
        # The config contains a string version just for display purposes
        
        # State variables
        self.last_trade_close_time = None
        self.analysis_data = None
        self.indicators = {}
        self.derived_metrics = {}
        self.entry_decision = None
        self.price_levels = {'entry': None, 'stop': None, 'tp': None}
        
        # Track the last processed candle to only trade at new candle formation
        self.last_processed_candle_time = None
        
        # Create temp directory if it doesn't exist
        os.makedirs(self.config['TEMP_DATA_DIR'], exist_ok=True)
        
    def get_required_data_count(self):
        """Return the minimum number of candles needed for this strategy"""
        # Ensure we have enough data for the longest EMA plus a buffer
        longest_ema = max(
            self.config['LONG_EMA_PERIOD'],
            self.config['MEDIUM_EMA_PERIOD'],
            self.config['FAST_EMA_PERIOD'],
            self.config['FASTER_EMA_PERIOD'],
            self.config['FASTEST_EMA_PERIOD'],
            self.config['ULTRA_FAST_EMA_PERIOD']
        )
        
        # Calculate required bars with a safety factor
        required_bars = int(longest_ema * 1.5)
        
        # Set a reasonable maximum to avoid MT5 data retrieval errors
        # MT5 may have limits on how much historical data can be retrieved at once
        MAX_SAFE_BARS = 1000
        
        if required_bars > MAX_SAFE_BARS:
            print(f"⚠️ Limiting data request from {required_bars} to {MAX_SAFE_BARS} bars to avoid MT5 errors")
            required_bars = MAX_SAFE_BARS
            
        return required_bars
    
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
            
            # Convert MT5 timeframe constant to string for display purposes
            timeframe_str_map = {
                mt5.TIMEFRAME_M1: "M1",
                mt5.TIMEFRAME_M5: "M5",
                mt5.TIMEFRAME_M15: "M15",
                mt5.TIMEFRAME_M30: "M30",
                mt5.TIMEFRAME_H1: "H1",
                mt5.TIMEFRAME_H4: "H4",
                mt5.TIMEFRAME_D1: "D1"
            }
            timeframe_str = timeframe_str_map.get(self.timeframe, "M1")
            
            # Use the timeframe constant passed from generic_trader
            timeframe = self.timeframe  # Use MT5 timeframe constant from parent
            
            # Calculate candles to fetch based on analysis hours
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
            
            # Ensure we have enough candles for the longest EMA
            longest_ema = max(
                self.config['LONG_EMA_PERIOD'],
                self.config['MEDIUM_EMA_PERIOD'],
                self.config['FAST_EMA_PERIOD'],
                self.config['FASTER_EMA_PERIOD'],
                self.config['FASTEST_EMA_PERIOD'],
                self.config['ULTRA_FAST_EMA_PERIOD']
            )
            
            # Calculate required candles with safety buffer
            required_candles = int(longest_ema * 2)  # Double the longest EMA for safety
            
            # Set a maximum limit to avoid MT5 errors
            MAX_SAFE_BARS = 1000
            
            # Use the larger of time-based or EMA-based requirements, but cap at maximum
            num_candles = min(max(num_candles, required_candles), MAX_SAFE_BARS)
            
            print(f"📊 Running market analysis for {self.symbol} ({timeframe_str}, {self.config['ANALYSIS_HOURS']}h)...")
            print(f"📈 Fetching {num_candles} {timeframe_str} candles for {self.symbol}...")
                
            # Use existing MT5 connection to get data (no initialize/shutdown)
            try:
                rates = mt5.copy_rates_from_pos(self.symbol, timeframe, 0, num_candles)
                if rates is None or len(rates) == 0:
                    err_code, err_msg = mt5.last_error()
                    print(f"❌ Failed to get data for {self.symbol}: Error {err_code}: {err_msg}")
                    return False
            except Exception as e:
                print(f"❌ Exception getting historical data: {e}")
                print(f"⚠️ Make sure {self.symbol} is available in your MT5 terminal and has sufficient history")
                return False
                
            # Create dataframe and calculate indicators
            df = pd.DataFrame(rates)
            df['time'] = pd.to_datetime(df['time'], unit='s', utc=True)
            df.set_index('time', inplace=True)
            
            print(f"✅ Received {len(df)} candles from {df.index[0]} to {df.index[-1]}")
            
            # Calculate indicators using our own methods
            print("🧮 Calculating technical indicators...")
            
            # Get EMA periods from config
            ultra_fast_ema = self.config['ULTRA_FAST_EMA_PERIOD']
            fastest_ema = self.config['FASTEST_EMA_PERIOD']
            faster_ema = self.config['FASTER_EMA_PERIOD']
            fast_ema = self.config['FAST_EMA_PERIOD']
            medium_ema = self.config['MEDIUM_EMA_PERIOD']
            long_ema = self.config['LONG_EMA_PERIOD']
            
            # EMAs with configurable periods
            df[f'ema_{ultra_fast_ema}'] = self._calculate_ema(df['close'], ultra_fast_ema)
            df[f'ema_{fastest_ema}'] = self._calculate_ema(df['close'], fastest_ema)
            df[f'ema_{faster_ema}'] = self._calculate_ema(df['close'], faster_ema)
            df[f'ema_{fast_ema}'] = self._calculate_ema(df['close'], fast_ema)
            df[f'ema_{medium_ema}'] = self._calculate_ema(df['close'], medium_ema)
            df[f'ema_{long_ema}'] = self._calculate_ema(df['close'], long_ema)
            
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
            import traceback
            traceback.print_exc()
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
        
        # Get EMA periods from config
        ultra_fast_ema = self.config['ULTRA_FAST_EMA_PERIOD']
        fastest_ema = self.config['FASTEST_EMA_PERIOD']
        faster_ema = self.config['FASTER_EMA_PERIOD']
        fast_ema = self.config['FAST_EMA_PERIOD']
        medium_ema = self.config['MEDIUM_EMA_PERIOD']
        long_ema = self.config['LONG_EMA_PERIOD']
        
        # Map of indicator names to their readable column names from market_analyzer
        indicator_map = {
            f'ema{ultra_fast_ema}': f'EMA ({ultra_fast_ema}) - Ultra-Fast Exponential Moving Average',
            f'ema{fastest_ema}': f'EMA ({fastest_ema}) - Fastest-term Trend',
            f'ema{faster_ema}': f'EMA ({faster_ema}) - Faster-term Trend',
            f'ema{fast_ema}': f'EMA ({fast_ema}) - Fast-term Trend',
            f'ema{medium_ema}': f'EMA ({medium_ema}) - Medium-term Trend',
            f'ema{long_ema}': f'EMA ({long_ema}) - Long-term Trend',
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
                if key == f'ema{ultra_fast_ema}':
                    self.indicators[key] = self._calculate_ema(df['close'], ultra_fast_ema)
                elif key == f'ema{fastest_ema}':
                    self.indicators[key] = self._calculate_ema(df['close'], fastest_ema)
                elif key == f'ema{faster_ema}':
                    self.indicators[key] = self._calculate_ema(df['close'], faster_ema)
                elif key == f'ema{fast_ema}':
                    self.indicators[key] = self._calculate_ema(df['close'], fast_ema)
                elif key == f'ema{medium_ema}':
                    self.indicators[key] = self._calculate_ema(df['close'], medium_ema)
                elif key == f'ema{long_ema}':
                    self.indicators[key] = self._calculate_ema(df['close'], long_ema)
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
        
        # Ensure compatibility with other methods by creating aliases for common EMA references
        self.indicators['ema50'] = self.indicators[f'ema{medium_ema}']
        self.indicators['ema200'] = self.indicators[f'ema{long_ema}']
        
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
        long_ema_lookback = self.config['LONG_EMA_SLOPE_LOOKBACK']
        medium_ema_lookback = self.config['MEDIUM_EMA_SLOPE_LOOKBACK']
        macd_window = self.config['MACD_HIST_MEAN_WINDOW']
        rsi_window = self.config['RSI_MEAN_WINDOW']
        
        # Get EMA periods from config
        medium_ema = self.config['MEDIUM_EMA_PERIOD']
        long_ema = self.config['LONG_EMA_PERIOD']
        
        # Calculate slopes and means
        self.derived_metrics = {
            'long_ema_slope': self.indicators[f'ema{long_ema}'].diff(long_ema_lookback).iloc[-1] / long_ema_lookback,
            'medium_ema_slope': self.indicators[f'ema{medium_ema}'].diff(medium_ema_lookback).iloc[-1] / medium_ema_lookback,
            'macd_hist_mean5': self.indicators['macd_hist'].tail(macd_window).mean(),
            'rsi_mean5': self.indicators['rsi14'].tail(rsi_window).mean(),
            'stoch_k_last': self.indicators['stoch_k'].iloc[-1],
            'stoch_d_last': self.indicators['stoch_d'].iloc[-1],
            'atr_percent': self.indicators['atr_percent'].iloc[-1]
        }
        
        # Create compatible aliases for existing methods
        self.derived_metrics['ema200_slope50'] = self.derived_metrics['long_ema_slope']
        self.derived_metrics['ema50_slope20'] = self.derived_metrics['medium_ema_slope']
        
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
        # Get EMA periods from config
        medium_ema = self.config['MEDIUM_EMA_PERIOD']
        long_ema = self.config['LONG_EMA_PERIOD']
        
        # Get latest values and slopes
        medium_ema_last = self.indicators[f'ema{medium_ema}'].iloc[-1]
        long_ema_last = self.indicators[f'ema{long_ema}'].iloc[-1]
        long_ema_slope = self.derived_metrics['long_ema_slope']
        medium_ema_slope = self.derived_metrics['medium_ema_slope']
        
        # Detailed trend analysis for logging
        print("\n📈 TREND ANALYSIS DETAILS:")
        print(f"  - EMA{medium_ema} ({medium_ema_last:.5f}) vs EMA{long_ema} ({long_ema_last:.5f}): {'ABOVE ✅' if medium_ema_last > long_ema_last else 'BELOW ❌'}")
        print(f"  - EMA{long_ema} Slope: {long_ema_slope:.8f} ({'RISING ✅' if long_ema_slope > 0 else 'FALLING ❌'})")
        print(f"  - EMA{medium_ema} Slope: {medium_ema_slope:.8f} ({'RISING ✅' if medium_ema_slope > 0 else 'FALLING ❌'})")
        
        # Classify trend based on EMA relationship and slope
        uptrend_conditions = [
            medium_ema_last > long_ema_last,
            long_ema_slope > 0
        ]
        
        downtrend_conditions = [
            medium_ema_last < long_ema_last,
            long_ema_slope < 0
        ]
        
        # Count how many conditions are met
        uptrend_score = sum(uptrend_conditions)
        downtrend_score = sum(downtrend_conditions)
        
        if uptrend_score == 2:
            trend = 'uptrend'
            print(f"  - STRONG UPTREND: EMA{medium_ema} > EMA{long_ema} and EMA{long_ema} rising")
        elif downtrend_score == 2:
            trend = 'downtrend'
            print(f"  - STRONG DOWNTREND: EMA{medium_ema} < EMA{long_ema} and EMA{long_ema} falling")
        elif uptrend_score > downtrend_score:
            trend = 'uptrend'
            print(f"  - WEAK UPTREND: Not all conditions met")
        elif downtrend_score > uptrend_score:
            trend = 'downtrend'
            print(f"  - WEAK DOWNTREND: Not all conditions met")
        else:
            trend = 'neutral'
            print(f"  - NEUTRAL TREND: Mixed signals")
            
        print(f"  - FINAL TREND CLASSIFICATION: {trend.upper()}")
        return trend
        
    def _confirm_momentum(self):
        """
        Step 6: MOMENTUM CONFIRMATION
        Check if momentum indicators confirm the trend direction.
        Enhanced to use multiple indicators with configurable threshold.
        
        Returns:
            tuple: (bullish_momentum, bearish_momentum)
        """
        # Get momentum indicators for the most recent candle
        macd_hist_mean = self.derived_metrics['macd_hist_mean5']
        rsi_mean = self.derived_metrics['rsi_mean5']
        stoch_k = self.derived_metrics['stoch_k_last']
        stoch_d = self.derived_metrics['stoch_d_last']
        
        # Get latest prices and indicators
        last_close = self.indicators['close'].iloc[-1]
        medium_ema = self.config['MEDIUM_EMA_PERIOD']
        medium_ema_last = self.indicators[f'ema{medium_ema}'].iloc[-1]
        bb_upper = self.indicators['bb_upper'].iloc[-1]
        bb_lower = self.indicators['bb_lower'].iloc[-1]
        bb_middle = (bb_upper + bb_lower) / 2
        
        # Get config settings
        rsi_bullish = self.config['RSI_BULLISH_THRESHOLD']
        rsi_bearish = self.config['RSI_BEARISH_THRESHOLD']
        required_indicators = self.config['MOMENTUM_INDICATORS_REQUIRED']
        total_indicators = self.config['MOMENTUM_INDICATORS_TOTAL']
        lookback = self.config['MOMENTUM_LOOKBACK']
        
        # 1. MACD Histogram
        macd_bullish = macd_hist_mean > 0
        macd_bearish = macd_hist_mean < 0
        
        # 2. RSI
        rsi_bullish_signal = rsi_mean > rsi_bullish
        rsi_bearish_signal = rsi_mean < rsi_bearish
        
        # 3. Stochastic
        stoch_bullish = stoch_k > stoch_d
        stoch_bearish = stoch_k < stoch_d
        
        # 4. Price vs Medium EMA
        ema_bullish = last_close > medium_ema_last
        ema_bearish = last_close < medium_ema_last
        
        # 5. Bollinger Band position
        # Middle to upper band is bullish territory, middle to lower is bearish
        bb_bullish = last_close > bb_middle
        bb_bearish = last_close < bb_middle
        
        # Count bullish signals
        bullish_count = sum([
            macd_bullish,
            rsi_bullish_signal,
            stoch_bullish,
            ema_bullish,
            bb_bullish
        ])
        
        # Count bearish signals
        bearish_count = sum([
            macd_bearish,
            rsi_bearish_signal,
            stoch_bearish,
            ema_bearish,
            bb_bearish
        ])
        
        # Check if we have enough confirming indicators
        bullish_mom = bullish_count >= required_indicators
        bearish_mom = bearish_count >= required_indicators
        
        # Additional check for historical momentum consistency
        # This helps ensure the momentum signal isn't just momentary
        if bullish_mom or bearish_mom:
            consistent = self._check_momentum_consistency(lookback, 
                                                        bullish_mom, 
                                                        bearish_mom)
            if not consistent:
                print("⚠️ Momentum not consistent over lookback period")
                bullish_mom = bearish_mom = False
        
        # Log individual indicator statuses
        print(f"Momentum Analysis:")
        print(f"  - MACD Histogram Mean: {macd_hist_mean:.6f} {'✅' if macd_bullish else '❌'} for bulls")
        print(f"  - RSI Mean: {rsi_mean:.2f} {'✅' if rsi_bullish_signal else '❌'} for bulls, {'✅' if rsi_bearish_signal else '❌'} for bears")
        print(f"  - Stochastic K vs D: {stoch_k:.2f} vs {stoch_d:.2f} {'✅' if stoch_bullish else '❌'} for bulls")
        print(f"  - Price vs EMA{medium_ema}: {last_close:.5f} vs {medium_ema_last:.5f} {'✅' if ema_bullish else '❌'} for bulls")
        print(f"  - Bollinger Position: {'Above Middle ✅' if bb_bullish else 'Below Middle ❌'} for bulls")
        print(f"  - Indicator Count: {bullish_count}/{total_indicators} bullish, {bearish_count}/{total_indicators} bearish")
        print(f"  - Requirement: {required_indicators}/{total_indicators} indicators needed")
        print(f"  - Overall Momentum: {'BULLISH ✅' if bullish_mom else ''} {'BEARISH ✅' if bearish_mom else ''} {'NEUTRAL ⚠️' if not (bullish_mom or bearish_mom) else ''}")
        
        return (bullish_mom, bearish_mom)
        
    def _check_momentum_consistency(self, lookback, is_bullish, is_bearish):
        """
        Check if momentum is consistent over the lookback period.
        
        Args:
            lookback (int): Number of periods to look back
            is_bullish (bool): Current bullish momentum status
            is_bearish (bool): Current bearish momentum status
            
        Returns:
            bool: True if momentum is consistent with recent history
        """
        # Skip if we're not analyzing any particular momentum
        if not (is_bullish or is_bearish):
            return False
            
        # Get recent values from indicators
        macd_hist = self.indicators['macd_hist'].tail(lookback+1)
        rsi = self.indicators['rsi14'].tail(lookback+1)
        
        if is_bullish:
            # For bullish momentum, check if:
            # 1. MACD histogram trend is upward or positive
            macd_positive_count = (macd_hist > 0).sum()
            macd_uptrend = macd_positive_count >= (lookback / 2)
            
            # 2. RSI is trending up
            rsi_diff = rsi.diff().dropna()
            rsi_up_count = (rsi_diff > 0).sum()
            rsi_uptrend = rsi_up_count >= (len(rsi_diff) / 2)
            
            # Need both conditions for consistency
            consistent = macd_uptrend and rsi_uptrend
            
        elif is_bearish:
            # For bearish momentum, check if:
            # 1. MACD histogram trend is downward or negative
            macd_negative_count = (macd_hist < 0).sum()
            macd_downtrend = macd_negative_count >= (lookback / 2)
            
            # 2. RSI is trending down
            rsi_diff = rsi.diff().dropna()
            rsi_down_count = (rsi_diff < 0).sum()
            rsi_downtrend = rsi_down_count >= (len(rsi_diff) / 2)
            
            # Need both conditions for consistency
            consistent = macd_downtrend and rsi_downtrend
            
        else:
            consistent = False
            
        print(f"  - Historical momentum {'consistent ✅' if consistent else 'inconsistent ❌'} over {lookback} periods")
        return consistent
        
    def _calculate_trend_strength(self):
        """
        Calculate the trend strength based on multiple factors.
        Returns a score between 0-1 where higher values indicate stronger trends.
        """
        try:
            # Get EMA periods from config
            medium_ema = self.config['MEDIUM_EMA_PERIOD']
            long_ema = self.config['LONG_EMA_PERIOD']
            
            # Get key indicators for trend strength calculation
            ema_medium = self.indicators[f'ema{medium_ema}'].iloc[-20:]  # Last 20 values
            ema_long = self.indicators[f'ema{long_ema}'].iloc[-20:]
            price = self.indicators['close'].iloc[-20:]  # Recent price movement
            
            # 1. Calculate EMA slope consistencies
            ema_medium_changes = ema_medium.diff().dropna()
            ema_long_changes = ema_long.diff().dropna()
            
            # Percentage of bars where slope is consistent with trend
            if len(ema_medium_changes) > 0:
                ema_medium_slope_consistency = len(ema_medium_changes[ema_medium_changes > 0]) / len(ema_medium_changes) \
                    if self.entry_decision == 'long' else \
                    len(ema_medium_changes[ema_medium_changes < 0]) / len(ema_medium_changes)
            else:
                ema_medium_slope_consistency = 0.5
                
            if len(ema_long_changes) > 0:
                ema_long_slope_consistency = len(ema_long_changes[ema_long_changes > 0]) / len(ema_long_changes) \
                    if self.entry_decision == 'long' else \
                    len(ema_long_changes[ema_long_changes < 0]) / len(ema_long_changes)
            else:
                ema_long_slope_consistency = 0.5
            
            # 2. Calculate price movement consistency with trend
            price_changes = price.diff().dropna()
            if len(price_changes) > 0:
                price_consistency = len(price_changes[price_changes > 0]) / len(price_changes) \
                    if self.entry_decision == 'long' else \
                    len(price_changes[price_changes < 0]) / len(price_changes)
            else:
                price_consistency = 0.5
            
            # 3. Calculate EMA alignment strength (how far apart EMAs are)
            ema_gap = (abs(ema_medium.iloc[-1] - ema_long.iloc[-1]) / ema_medium.iloc[-1]) * 100  # Gap as % of price
            # Normalize gap to 0-1 scale (larger gaps up to 2% of price get higher scores)
            ema_gap_score = min(ema_gap / 2.0, 1.0)
            
            # 4. Calculate ADX-like trend strength using recent price movement
            # (simplified approach - true ADX is more complex)
            range_sum = 0
            directional_movement = 0
            for i in range(1, min(14, len(price))):
                day_range = max(price.iloc[i] - price.iloc[i-1], 0) if self.entry_decision == 'long' \
                    else max(price.iloc[i-1] - price.iloc[i], 0)
                range_sum += abs(price.iloc[i] - price.iloc[i-1])
                directional_movement += day_range
            
            dm_strength = directional_movement / range_sum if range_sum > 0 else 0.5
            
            # Combine factors with weightings
            weights = {
                'ema_medium_consistency': 0.25,
                'ema_long_consistency': 0.15,
                'price_consistency': 0.30,
                'ema_gap': 0.10,
                'dm_strength': 0.20
            }
            
            trend_strength = (
                weights['ema_medium_consistency'] * ema_medium_slope_consistency +
                weights['ema_long_consistency'] * ema_long_slope_consistency +
                weights['price_consistency'] * price_consistency +
                weights['ema_gap'] * ema_gap_score +
                weights['dm_strength'] * dm_strength
            )
            
            # Ensure trend strength is within 0-1 bounds
            trend_strength = max(0.0, min(1.0, trend_strength))
            
            return trend_strength
            
        except Exception as e:
            print(f"⚠️ Error calculating trend strength: {e}")
            return 0.5  # Return neutral value on error
            
    def _check_price_position(self):
        """
        Check if price is in a good position for entry relative to moving averages.
        Avoid entries when price has already moved too far from its average.
        
        Returns:
            bool: True if price position is favorable for entry
        """
        try:
            # Get fast EMA period from config
            fast_ema = self.config['FAST_EMA_PERIOD']
            
            # Get relevant indicators
            close = self.indicators['close'].iloc[-1]
            ema_fast = self.indicators[f'ema{fast_ema}'].iloc[-1]  # Medium-term EMA
            atr = self.indicators['atr14'].iloc[-1]
            
            # Calculate distance as multiple of ATR
            distance = abs(close - ema_fast) / atr
            
            # Get the maximum allowed distance based on config
            max_distance = self.config['PRICE_DISTANCE_FACTOR'] * self.config['SL_ATR_MULT']
            
            # Check if price is not too extended
            price_position_ok = distance <= max_distance
            
            if not price_position_ok:
                print(f"⚠️ Price too far from EMA{fast_ema}: {distance:.2f} ATR (max: {max_distance:.2f} ATR)")
            else:
                print(f"✅ Price position ok: {distance:.2f} ATR from EMA{fast_ema}")
                
            return price_position_ok
            
        except Exception as e:
            print(f"⚠️ Error checking price position: {e}")
            return True  # Allow entry on error (fail-safe)
    
    def _make_entry_decision(self):
        """
        Step 7: ENTRY DECISION
        Determine whether to enter a long position, short position, or skip.
        Enhanced with trend strength and price position checks.
        
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
        
        # Check if reversal trades are allowed
        allow_reversal = self.config.get('ALLOW_REVERSAL_TRADES', False)
        
        # Get EMA periods from config
        medium_ema = self.config['MEDIUM_EMA_PERIOD']
        long_ema = self.config['LONG_EMA_PERIOD']
        
        # Log detailed decision reasoning
        print("\n🔍 DECISION ANALYSIS:")
        
        # Check trend and momentum alignment for possible long entry
        if trend == 'uptrend':
            print(f"  - Uptrend detected (EMA{medium_ema} > EMA{long_ema}, positive slopes) ✅")
            if bullish_mom:
                print("  - Bullish momentum confirmed ✅")
                print("  - TREND-MOMENTUM ALIGNMENT: Potentially valid LONG setup ✅")
                self.entry_decision = 'long'
            else:
                print("  - Bullish momentum NOT confirmed ❌")
                print(f"    → Needed: Bullish MACD, RSI > {self.config['RSI_BULLISH_THRESHOLD']}, Stochastic K>D, etc.")
                print("    → Got: Not enough bullish indicators")
                print("  - TREND-MOMENTUM MISMATCH: Uptrend with non-bullish momentum - NO TRADE ❌")
                return 'skip'
        # Check trend and momentum alignment for possible short entry
        elif trend == 'downtrend':
            print(f"  - Downtrend detected (EMA{medium_ema} < EMA{long_ema}, negative slopes) ✅")
            if bearish_mom:
                print("  - Bearish momentum confirmed ✅")
                print("  - TREND-MOMENTUM ALIGNMENT: Potentially valid SHORT setup ✅")
                self.entry_decision = 'short'
            else:
                print("  - Bearish momentum NOT confirmed ❌")
                print(f"    → Needed: Negative MACD, RSI < {self.config['RSI_BEARISH_THRESHOLD']}, Stochastic K<D, etc.")
                print("    → Got: Too many bullish indicators, not enough bearish ones")
                print("  - TREND-MOMENTUM MISMATCH: Downtrend with bullish momentum")
                
                # Check if we should allow potential reversal trades
                if allow_reversal and bullish_mom:
                    print("    → POTENTIAL TREND REVERSAL DETECTED")
                    print("    → REVERSAL TRADES ENABLED: Taking LONG trade against trend ⚠️")
                    self.entry_decision = 'long'
                else:
                    print("    → This is a potential trend reversal signal, but we're avoiding it for safety")
                    print("    → Waiting for momentum to align with trend direction")
                    return 'skip'
        # Neutral trend but potentially strong momentum
        elif allow_reversal:
            if bullish_mom:
                print(f"  - Neutral trend with strong BULLISH momentum")
                print("  - REVERSAL TRADES ENABLED: Taking LONG trade based on momentum only ⚠️")
                self.entry_decision = 'long'
            elif bearish_mom:
                print(f"  - Neutral trend with strong BEARISH momentum")
                print("  - REVERSAL TRADES ENABLED: Taking SHORT trade based on momentum only ⚠️")
                self.entry_decision = 'short'
            else:
                print("  - Neutral trend with NO clear momentum - NO TRADE ❌")
                return 'skip'
        # Neutral trend - no trade (if reversal trades not allowed)
        else:
            print("  - Neutral trend detected - NO TRADE ❌")
            return 'skip'
            
        # Now check trend strength
        trend_strength = self._calculate_trend_strength()
        min_strength = self.config['MIN_TREND_STRENGTH']
        
        print(f"  - Trend strength: {trend_strength:.2f} (minimum: {min_strength:.2f})")
        if trend_strength < min_strength and not (allow_reversal and (bullish_mom or bearish_mom)):
            print("  - Trend not strong enough - NO TRADE ❌")
            return 'skip'
            
        # Check if price is in a good position for entry
        if not self._check_price_position():
            print("  - Price position unfavorable - NO TRADE ❌")
            return 'skip'
            
        # All checks passed, confirm the entry decision
        if self.entry_decision == 'long':
            if trend == 'downtrend' and allow_reversal:
                print("🔼 FINAL DECISION: LONG (REVERSAL TRADE) ⚠️")
            else:
                print(f"🔼 FINAL DECISION: LONG - Strong uptrend with bullish momentum ✅")
        else:
            if trend == 'uptrend' and allow_reversal:
                print("🔽 FINAL DECISION: SHORT (REVERSAL TRADE) ⚠️")
            else:
                print(f"🔽 FINAL DECISION: SHORT - Strong downtrend with bearish momentum ✅")
            
        return self.entry_decision
        
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
            print(f"  - Stop Loss: {stop:.5f} ({sl_mult}x ATR = {sl_mult * atr:.5f})")
            print(f"  - Take Profit: {tp:.5f} ({tp_mult}x ATR = {tp_mult * atr:.5f})")
            print(f"  - Risk/Reward Ratio: 1:{tp_mult/sl_mult:.1f}")
            
        return self.price_levels
        
    def generate_entry_signal(self, open_positions=None):
        """
        Generates entry signals based on comprehensive market analysis.
        Only makes decisions at the start of a new candle.
        
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
        
        # Check if we're at the beginning of a new candle
        server_time = get_server_time()
        current_candle_start, current_candle_end = get_candle_boundaries(server_time, self.timeframe)
        time_since_candle_open = (server_time - current_candle_start).total_seconds()
        candle_total_seconds = (current_candle_end - current_candle_start).total_seconds()
        
        # Only trade in the first 20% of the candle's total time
        candle_entry_threshold = 0.2 * candle_total_seconds
        if time_since_candle_open > candle_entry_threshold:
            remaining = current_candle_end - server_time
            # print(f"⏱️ TIMING: Too far into candle ({(time_since_candle_open/candle_total_seconds)*100:.1f}% elapsed). Next candle in {remaining.total_seconds()/60:.1f} min.")
            return None
        # else:
            #print(f"⏱️ TIMING: Within entry window ({(time_since_candle_open/candle_total_seconds)*100:.1f}% of candle elapsed, max 20%) ✅")
            
        # Only proceed if this is a new candle we haven't processed yet
        if self.last_processed_candle_time:
            # Use strict comparison with candle boundaries
            # Get the last processed candle's start time
            last_candle_start, _ = get_candle_boundaries(self.last_processed_candle_time, self.timeframe)
            
            # Skip if we've already processed this candle
            if current_candle_start <= last_candle_start:
                # print(f"🔄 CANDLE: Already processed this candle - skipping.")
                return None
                
            # Calculate minutes since candle opened
            minutes_since_open = (server_time - current_candle_start).total_seconds() / 60
            print(f"🔄 CANDLE: New candle detected at {current_candle_start} ✅")
            
        else:
            # First run - just log the current candle time
            print(f"🔄 CANDLE: Initial candle at {current_candle_start} - first run ✅")
            
        print("\n🔄 Starting AISlope1 analysis pipeline")
        
        # Update the last processed candle time
        self.last_processed_candle_time = current_candle_start
            
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
        print(f"📏 Risk parameters: SL multiplier={self.config['SL_ATR_MULT']}x ATR, TP multiplier={self.config['TP_ATR_MULT']}x ATR")
        
        return signal_type, entry_price, sl_price, tp_price
        
    def _get_current_candle_time(self):
        """
        Get the start time of the current candle.
        
        Returns:
            datetime or None: Start time of the current candle, or None if error
        """
        try:
            # Get the most recent candle
            rates = mt5.copy_rates_from_pos(self.symbol, self.timeframe, 0, 1)
            if rates is None or len(rates) == 0:
                print(f"⚠️ Could not get current candle data for {self.symbol}")
                return None
                
            # Get the current server time for proper timezone reference
            server_time = get_server_time()
            
            # Convert the timestamp to datetime using server timezone
            candle_time = datetime.fromtimestamp(rates[0]['time'], tz=server_time.tzinfo)
            
            # Get the candle boundaries to ensure we're working with the candle start time
            try:
                candle_start, _ = get_candle_boundaries(candle_time, self.timeframe)
                return candle_start
            except Exception as e:
                print(f"⚠️ Error getting candle boundaries: {e}. Using raw candle time.")
                return candle_time
                
        except Exception as e:
            print(f"❌ Error getting current candle time: {e}")
            return None
            
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
        # Record the time of the position close using server time
        self.last_trade_close_time = get_server_time()
        print(f"🕒 Position closed at {self.last_trade_close_time}. Waiting before new entry.")
        
        # Update the last processed candle time to the current candle
        # This prevents immediate reentry within the same candle
        current_candle_start, _ = get_candle_boundaries(self.last_trade_close_time, self.timeframe)
        self.last_processed_candle_time = current_candle_start
        print(f"🔄 Updated last processed candle to {current_candle_start}")
            
        # Call the parent class method to reset other state
        super().reset_signal_state() 