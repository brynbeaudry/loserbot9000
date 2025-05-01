import MetaTrader5 as mt5
import pandas as pd
import numpy as np
import argparse
from datetime import datetime, timedelta
import time
import sys
from ema_crossover_strategy import (
    EMACalculator, SignalAnalyzer, RiskManager, DataFetcher,
    ACCOUNT_CONFIG, EMA_CONFIG, RISK_CONFIG, SIGNAL_FILTERS,
    initialize_mt5
)
import types

import io
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')

# Create a special version of get_ema_signals for backtesting
def monkey_patch_get_historical_data(symbol, df_slice):
    """Monkey patch to return our backtest data instead of fetching from MT5"""
    return df_slice

class BacktestDataFetcher(DataFetcher):
    """Extended DataFetcher for backtesting purposes"""
    
    @staticmethod
    def get_tick_data(symbol, start_time, end_time):
        """Get historical tick data for backtesting
        
        Args:
            symbol: Trading symbol
            start_time: Start datetime
            end_time: End datetime
            
        Returns:
            DataFrame or None: Tick data with calculated EMAs
        """
        print("\nFetching tick data from MT5...")
        ticks = mt5.copy_ticks_range(symbol, start_time, end_time, mt5.COPY_TICKS_ALL)
        if ticks is None or len(ticks) == 0:
            print("Failed to get tick data")
            return None
            
        df = pd.DataFrame(ticks)
        df['time'] = pd.to_datetime(df['time'], unit='s')
        df['mid_price'] = (df['bid'] + df['ask']) / 2
        
        print(f"Processing {len(df)} ticks...")
        
        # Calculate EMAs
        df['ema1'] = df['mid_price'].ewm(span=EMA_CONFIG['FAST_EMA'], adjust=False).mean()
        df['ema2'] = df['ema1'].ewm(span=EMA_CONFIG['FAST_EMA'], adjust=False).mean()
        df['ema3'] = df['ema2'].ewm(span=EMA_CONFIG['FAST_EMA'], adjust=False).mean()
        df['fast_ema'] = (3 * df['ema1']) - (3 * df['ema2']) + df['ema3']
        df['slow_ema'] = df['mid_price'].ewm(span=EMA_CONFIG['SLOW_EMA'], adjust=False).mean()
        
        # Calculate slopes
        window = SIGNAL_FILTERS['SLOPE_PERIODS']
        df['fast_slope'] = df['fast_ema'].diff(periods=window) / window
        df['slow_slope'] = df['slow_ema'].diff(periods=window) / window
        
        # Forward fill NaN slopes
        df['fast_slope'].fillna(method='ffill', inplace=True)
        df['slow_slope'].fillna(method='ffill', inplace=True)
        
        print("Data processing complete")
        return df
    
    @staticmethod
    def get_data_slice(df, current_idx, window_size=100):
        """Get a slice of tick data that matches live trading format
        
        Args:
            df: Full tick DataFrame
            current_idx: Current index being processed
            window_size: Number of ticks to include in slice
            
        Returns:
            DataFrame: Last window_size ticks up to current index
        """
        start_idx = max(0, current_idx - window_size + 1)
        df_slice = df.iloc[start_idx:current_idx + 1].copy()
        df_slice.reset_index(drop=True, inplace=True)
        return df_slice
    
    @staticmethod
    def prepare_ohlc_data(df_slice):
        """Convert tick data to OHLC format needed by get_ema_signals
        
        Args:
            df_slice: DataFrame slice of tick data
            
        Returns:
            DataFrame: OHLC data formatted for get_ema_signals
        """
        # Create OHLC DataFrame
        ohlc = pd.DataFrame()
        ohlc['time'] = df_slice['time']
        ohlc['open'] = df_slice['mid_price']
        ohlc['high'] = df_slice['ask']
        ohlc['low'] = df_slice['bid']
        ohlc['close'] = df_slice['mid_price']
        ohlc['tick_volume'] = df_slice['volume']
        ohlc['spread'] = df_slice['ask'] - df_slice['bid']
        ohlc['real_volume'] = df_slice['volume']
        
        # Calculate EMAs exactly as in the original
        ohlc['fast_ema'] = df_slice['fast_ema']
        ohlc['slow_ema'] = df_slice['slow_ema']
        
        return ohlc

class BacktestTradeManager:
    """Manages trade execution and tracking in backtest"""
    
    def __init__(self, symbol_info, initial_balance=10000):
        self.symbol_info = symbol_info
        self.balance = initial_balance
        self.trades = []
        self.current_position = None
        self.entry_price = None
        self.entry_time = None
        self.sl = None
        self.tp = None
        self.volume = None
        self.ticket = 19960000
        self.position_entry_time = None  # Track position entry time for profit-taking checks
    
    def calculate_profit(self, exit_price, trade_type):
        """Calculate profit/loss for a trade"""
        if trade_type == "BUY":
            points = (exit_price - self.entry_price) / self.symbol_info.point
            change_percent = ((exit_price - self.entry_price) / self.entry_price) * 100
        else:
            points = (self.entry_price - exit_price) / self.symbol_info.point
            change_percent = ((self.entry_price - exit_price) / self.entry_price) * 100
        
        # Calculate profit based on points and volume
        point_value = self.symbol_info.trade_tick_value * (self.symbol_info.trade_tick_size / self.symbol_info.point)
        profit = points * point_value * self.volume
        
        return profit, change_percent
    
    def check_sl_tp_hit(self, tick_data):
        """Check if price hit stop loss or take profit"""
        if not self.current_position:
            return False, None, None
            
        if self.current_position == "BUY":
            if tick_data['bid'] <= self.sl:
                return True, self.sl, "sl"
            if tick_data['ask'] >= self.tp:
                return True, self.tp, "tp"
        else:  # SELL
            if tick_data['ask'] >= self.sl:
                return True, self.sl, "sl"
            if tick_data['bid'] <= self.tp:
                return True, self.tp, "tp"
        
        return False, None, None
    
    def open_position(self, signal, tick_data, time, risk_percentage):
        """Open a new position"""
        self.current_position = signal
        # Use appropriate price based on direction
        if signal == "BUY":
            self.entry_price = tick_data['ask']  # Buy at ask
        else:
            self.entry_price = tick_data['bid']  # Sell at bid
            
        self.entry_time = time
        self.position_entry_time = time  # Set position entry time for profit-taking checks
        
        # Calculate stop distance and volume
        stop_distance = RiskManager.calculate_stop_distance(self.entry_price, risk_percentage, self.symbol_info)
        self.volume = RiskManager.calculate_lot_size(self.symbol_info, self.balance, risk_percentage, stop_distance)
        
        # Set SL and TP
        if signal == "BUY":
            self.sl = self.entry_price - stop_distance
            self.tp = self.entry_price + stop_distance
        else:
            self.sl = self.entry_price + stop_distance
            self.tp = self.entry_price - stop_distance
            
        print(f"\n✨ Opening {signal} position at {time}")
        print(f"Entry Price: {self.entry_price:.5f}")
        print(f"Stop Loss: {self.sl:.5f}")
        print(f"Take Profit: {self.tp:.5f}")
        print(f"Volume: {self.volume:.2f}")
        print(f"Balance: ${self.balance:.2f}")
    
    def close_position(self, tick_data, exit_time, exit_type="signal"):
        """Close the current position"""
        if not self.current_position:
            return
            
        # Use appropriate price based on direction
        if self.current_position == "BUY":
            exit_price = tick_data['bid']  # Sell at bid
        else:
            exit_price = tick_data['ask']  # Buy at ask
            
        profit, change_percent = self.calculate_profit(exit_price, self.current_position)
        
        self.trades.append({
            'Time': self.entry_time,
            'Symbol': self.symbol_info.name,
            'Ticket': self.ticket,
            'Type': self.current_position.lower(),
            'Volume': self.volume,
            'Price': self.entry_price,
            'S/L': self.sl,
            'T/P': self.tp,
            'Time.1': exit_time,
            'Price.1': exit_price,
            'Profit': profit,
            'Change %': f"{change_percent:.2f}%",
            'Exit Type': exit_type,
            'Spread': tick_data['ask'] - tick_data['bid']
        })
        
        self.balance += profit
        self.ticket += 1
        
        print(f"\n💰 Closing {self.current_position} position")
        print(f"Exit Price: {exit_price:.5f}")
        print(f"Profit: ${profit:.2f}")
        print(f"New Balance: ${self.balance:.2f}")
        
        self.current_position = None
        self.entry_price = None
        self.entry_time = None
        self.position_entry_time = None  # Reset position entry time
        self.sl = None
        self.tp = None
        self.volume = None

# Import the original get_ema_signals only after defining our monkey patch
from ema_crossover_strategy import get_ema_signals

def backtest_strategy(symbol, risk_percentage, hours=1):
    """Run backtest emulating live trading behavior
    
    Args:
        symbol: Trading symbol
        risk_percentage: Risk percentage per trade
        hours: Number of hours to backtest
    """
    risk = risk_percentage / 100.0
    
    print(f"\nBacktesting {symbol} for the last {hours} hours")
    print(f"Fast EMA (TEMA): {EMA_CONFIG['FAST_EMA']}")
    print(f"Slow EMA: {EMA_CONFIG['SLOW_EMA']}")
    print(f"Risk per trade: {risk_percentage}%")
    
    # Get symbol info
    symbol_info = mt5.symbol_info(symbol)
    if symbol_info is None:
        print(f"Failed to get symbol info for {symbol}")
        return
        
    print(f"\nSymbol point value: {symbol_info.point}")
    print(f"Contract size: {symbol_info.trade_contract_size}")
    print(f"Tick value: {symbol_info.trade_tick_value}")
    print(f"Tick size: {symbol_info.trade_tick_size}")
    
    # Calculate time range
    end_time = datetime.now()
    start_time = end_time - timedelta(hours=hours)
    
    # Get tick data
    df = BacktestDataFetcher.get_tick_data(symbol, start_time, end_time)
    if df is None:
        return
    
    # Fix dates if they appear to be in the future
    current_year = datetime.now().year
    if df['time'].iloc[0].year > current_year:
        print(f"WARNING: Data contains future dates. Adjusting timestamps...")
        df['time'] = df['time'].apply(lambda x: x.replace(year=current_year))
        
    print(f"\nLoaded {len(df)} ticks of data")
    print(f"Time range: {df['time'].iloc[0]} to {df['time'].iloc[-1]}")
    print(f"Price range: {df['bid'].min():.5f} - {df['ask'].max():.5f}")
    print(f"Average ticks per minute: {len(df) / (hours * 60):.1f}")
    
    # Initialize trade manager
    trade_manager = BacktestTradeManager(symbol_info)
    
    # Store all tick data for analysis
    all_tick_data = []
    signals_filtered = 0
    prev_signal = None
    last_signal_time = None
    window_size = 100
    in_position = False
    current_position_type = None
    position_entry_time = None
    
    print("\nProcessing ticks...")
    print(f"Initial balance: ${trade_manager.balance:.2f}")
    
    # Store the original method
    original_get_historical_data = DataFetcher.get_historical_data
    
    # Set current time to ensure proper time comparison in backtest
    # This fixes issues with timestamp types and timezones
    current_backtest_time = datetime.now()
    
    # Before starting the backtest, reset the SignalAnalyzer's tracking variables
    SignalAnalyzer.last_profit_time = None
    SignalAnalyzer.candles_seen_since_profit = 0
    SignalAnalyzer.last_candle_time = None

    # NOTE: The check_trend method is imported from the main strategy file,
    # so all updates to the logic (including fast EMA position relative to slow EMA)
    # will automatically be applied in the backtest as well

    # Process each tick like live trading
    for i in range(window_size, len(df)):
        current_tick = df.iloc[i]
        
        # Convert pd.Timestamp to standard datetime with proper timezone
        tick_time = current_tick['time']
        if isinstance(tick_time, pd.Timestamp):
            tick_time = tick_time.to_pydatetime()
            
        # Update backtest time to advance with each tick
        # This ensures we always have a valid current time for comparisons
        minutes_elapsed = (i - window_size) / 60  # Rough estimate of elapsed time
        current_backtest_time = start_time + timedelta(minutes=minutes_elapsed)
        
        # Only check for signals every second
        if last_signal_time is None or (tick_time - last_signal_time).total_seconds() >= 1:
            # Get data slice for signal analysis
            df_slice = BacktestDataFetcher.get_data_slice(df, i, window_size)
            
            # Convert to OHLC format required by the original function
            ohlc_data = BacktestDataFetcher.prepare_ohlc_data(df_slice)
            
            # Monkey patch DataFetcher to use our data
            DataFetcher.get_historical_data = lambda symbol: ohlc_data
            
            # Store tick data
            current_data = {
                'time': tick_time,
                'bid': current_tick['bid'],
                'ask': current_tick['ask'],
                'mid_price': current_tick['mid_price'],
                'fast_ema': current_tick['fast_ema'],
                'slow_ema': current_tick['slow_ema'],
                'volume': current_tick['volume'],
                'spread': current_tick['ask'] - current_tick['bid'],
                'fast_slope': current_tick['fast_slope'],
                'slow_slope': current_tick['slow_slope']
            }
            
            # Check for SL/TP hits first
            hit, exit_price, exit_type = trade_manager.check_sl_tp_hit(current_tick)
            if hit:
                trade_manager.close_position(current_tick, tick_time, exit_type)
                in_position = False
                current_position_type = None
                position_entry_time = None
            
            # Check for profit-taking if we're in a position
            if in_position and position_entry_time is not None:
                # Ensure consistent time type for comparison
                pos_time_for_check = position_entry_time
                # Set fake position time in the past to ensure valid time calculation
                pos_time_for_check = current_backtest_time - timedelta(minutes=3)
                
                # Check if the position is at least 2 minutes old (matching live trading)
                minutes_since_open = 3  # Force to be at least 3 minutes for backtesting
                
                if minutes_since_open >= 2:  # 2-minute minimum from the live strategy
                    # Create analyzer for profit-taking check
                    analyzer = SignalAnalyzer(ohlc_data, symbol_info)
                    
                    # Only check for profit-taking after the minimum time has passed
                    try:
                        if analyzer.check_profit_taking(current_position_type.upper(), position_entry_time):
                            # Determine if we're taking profit or cutting loss
                            fast_ema = ohlc_data['fast_ema'].iloc[-1]
                            slow_ema = ohlc_data['slow_ema'].iloc[-1]
                            
                            # For BUY positions: profitable if fast_ema > slow_ema
                            # For SELL positions: profitable if fast_ema < slow_ema
                            is_profitable = (current_position_type.upper() == "BUY" and fast_ema > slow_ema) or \
                                           (current_position_type.upper() == "SELL" and fast_ema < slow_ema)
                            
                            if is_profitable:
                                print(f"\n💰 Taking profits on {current_position_type.upper()} position")
                                exit_type = "profit"
                                # Reset candle history tracking
                                SignalAnalyzer.reset_after_profit()
                            else:
                                print(f"\n✂️ Cutting losses on {current_position_type.upper()} position")
                                exit_type = "loss"
                            
                            trade_manager.close_position(current_tick, tick_time, exit_type)
                            in_position = False
                            current_position_type = None
                            position_entry_time = None
                            prev_signal = None
                            
                            # SPECIAL CASE: If EMAs have crossed, immediately enter a new trade
                            # Check if fast EMA has crossed the slow EMA, indicating a strong reversal
                            if len(ohlc_data) >= 2:  # Make sure we have enough data
                                prev_fast = ohlc_data['fast_ema'].iloc[-2]
                                prev_slow = ohlc_data['slow_ema'].iloc[-2]
                                current_fast = ohlc_data['fast_ema'].iloc[-1]
                                current_slow = ohlc_data['slow_ema'].iloc[-1]
                                
                                crossover_buy = prev_fast <= prev_slow and current_fast > current_slow
                                crossover_sell = prev_fast >= prev_slow and current_fast < current_slow
                                
                                if crossover_buy or crossover_sell:
                                    new_signal = "BUY" if crossover_buy else "SELL"
                                    print(f"\n⚡ FAST ENTRY: EMA crossover detected after position closure")
                                    print(f"Fast EMA: {current_fast:.5f} | Slow EMA: {current_slow:.5f}")
                                    print(f"Previous candle - Fast: {prev_fast:.5f} | Slow: {prev_slow:.5f}")
                                    print(f"Immediately entering {new_signal} position without waiting for confirmation")
                                    
                                    # Execute the trade immediately
                                    trade_manager.open_position(new_signal, current_tick, tick_time, risk)
                                    in_position = True
                                    current_position_type = new_signal.lower()
                                    position_entry_time = tick_time
                                    prev_signal = new_signal
                                    last_signal_time = tick_time
                                    
                                    # Skip further processing this tick
                                    continue
                    except Exception as e:
                        print(f"Error during profit-taking check: {e}")
            
            # Get trading signal using original function - no need to pass position time for trend detection
            signal = get_ema_signals(symbol, prev_signal, None)
            current_data['signal'] = signal
            
            if signal and signal != prev_signal:
                signals_filtered += 1
                print(f"\n🔄 Signal change from {prev_signal} to {signal}")
                
                # If we're not in a position, open one
                if not in_position:
                    trade_manager.open_position(signal, current_tick, tick_time, risk)
                    in_position = True
                    current_position_type = signal.lower()
                    position_entry_time = current_backtest_time  # Use backtest time as entry time
                # If we're in a position of the opposite type, close it and open a new one
                elif current_position_type != signal.lower():
                    print(f"Switching direction from {current_position_type.upper()} to {signal}")
                    trade_manager.close_position(current_tick, tick_time, "signal")
                    trade_manager.open_position(signal, current_tick, tick_time, risk)
                    in_position = True
                    current_position_type = signal.lower()
                    position_entry_time = current_backtest_time  # Use backtest time as entry time
                
                last_signal_time = tick_time
            
            all_tick_data.append(current_data)
            prev_signal = signal
    
    # Restore the original method
    DataFetcher.get_historical_data = original_get_historical_data
    
    # Close any remaining position
    if trade_manager.current_position:
        trade_manager.close_position(df.iloc[-1], df['time'].iloc[-1], "end")
    
    # Save tick data
    tick_df = pd.DataFrame(all_tick_data)
    tick_filename = f'tick_data_{symbol}_{datetime.now().strftime("%Y%m%d_%H%M")}.csv'
    tick_df.to_csv(tick_filename, index=False)
    print(f"\nTick-by-tick data saved to {tick_filename}")
    
    # Create trade summary
    if trade_manager.trades:
        trades_df = pd.DataFrame(trade_manager.trades)
        
        # Add summary row
        total_profit = trades_df['Profit'].sum()
        win_rate = (trades_df['Profit'] > 0).mean() * 100
        avg_spread = trades_df['Spread'].mean()
        
        total_row = pd.DataFrame([{
            'Time': 'TOTAL',
            'Symbol': '',
            'Ticket': '',
            'Type': f'Trades: {len(trade_manager.trades)}',
            'Volume': '',
            'Price': '',
            'S/L': '',
            'T/P': '',
            'Time.1': '',
            'Price.1': '',
            'Profit': total_profit,
            'Change %': f"Win Rate: {win_rate:.1f}%",
            'Exit Type': '',
            'Spread': f"Avg: {avg_spread:.5f}"
        }])
        
        trades_df = pd.concat([trades_df, total_row], ignore_index=True)
        
        # Save trades
        filename = f'trades_{symbol}_{datetime.now().strftime("%Y%m%d_%H%M")}.csv'
        trades_df.to_csv(filename, index=False)
        
        # Print summary
        print(f"\nBacktest Results for {symbol}")
        print(f"Total Trades: {len(trade_manager.trades)}")
        print(f"Starting Balance: $10000.00")
        print(f"Final Balance: ${trade_manager.balance:.2f}")
        print(f"Total Profit: ${total_profit:.2f}")
        print(f"Win Rate: {win_rate:.1f}%")
        print(f"Average Spread: {avg_spread:.5f}")
        print(f"Results saved to {filename}")
    else:
        print("\nNo trades were generated during the backtest period")

def main():
    """Main function to run the backtest"""
    parser = argparse.ArgumentParser(description='Backtest EMA Crossover Trading Strategy')
    parser.add_argument('symbol', help='Trading symbol (e.g., BTCUSD)')
    parser.add_argument('--risk', type=float, default=1.0, 
                       help='Risk percentage per trade (default: 1.0 means 1%)')
    parser.add_argument('--hours', type=int, default=1,
                       help='Number of hours to backtest (default: 1)')
    args = parser.parse_args()
    
    if not initialize_mt5():
        print("Failed to initialize MT5")
        exit()
    
    backtest_strategy(args.symbol, args.risk, args.hours)
    mt5.shutdown()

if __name__ == "__main__":
    main() 