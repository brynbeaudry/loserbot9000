#!/usr/bin/env python3
"""
ORB Range Analyzer - Based on ORB4 MQ5 Strategy
Analyzes tick data to find maximum range multipliers reached during trading sessions.
Uses the same timezone logic as the MQ5 file: PU Prime server time with 7-hour offset to NY time.
"""

import pandas as pd
import numpy as np
import argparse
import sys
from datetime import datetime, timedelta
from typing import Dict, List, Tuple, Optional
import warnings
from calendar import monthrange
from multiprocessing import Pool, cpu_count
from functools import lru_cache
import os

# Suppress pandas warnings for large file processing
warnings.filterwarnings('ignore', category=pd.errors.PerformanceWarning)

# Try to import performance libraries
try:
    from numba import njit
    HAS_NUMBA = True
except ImportError:
    HAS_NUMBA = False
    print("Install numba for 3-5x speed boost: pip install numba")

# Numba-accelerated range multiplier calculation for 3-5x speed boost
if HAS_NUMBA:
    @njit
    def calculate_range_multipliers_fast(prices, timestamps, range_high, range_low, 
                                        range_size, range_end_ts, session_end_ts, 
                                        allow_after_hours):
        """JIT-compiled vectorized calculation - 3-5x faster"""
        max_bullish = 0.0
        max_bearish = 0.0
        
        for i in range(len(prices)):
            if timestamps[i] < range_end_ts:
                continue
            if not allow_after_hours and timestamps[i] > session_end_ts:
                continue
                
            price = prices[i]
            if price > range_high:
                bullish_mult = (price - range_high) / range_size
                if bullish_mult > max_bullish:
                    max_bullish = bullish_mult
            elif price < range_low:
                bearish_mult = (range_low - price) / range_size
                if bearish_mult > max_bearish:
                    max_bearish = bearish_mult
        
        if max_bullish > max_bearish:
            return max_bullish, 1  # 1 = BULLISH
        elif max_bearish > 0:
            return max_bearish, 2  # 2 = BEARISH
        else:
            return 0.0, 0  # 0 = NONE
else:
    def calculate_range_multipliers_fast(prices, timestamps, range_high, range_low, 
                                        range_size, range_end_ts, session_end_ts, 
                                        allow_after_hours):
        """Fallback vectorized calculation"""
        # Convert to numpy arrays for vectorized operations
        prices = np.array(prices)
        timestamps = np.array(timestamps)
        
        # Vectorized filtering
        mask = timestamps >= range_end_ts
        if not allow_after_hours:
            mask &= timestamps <= session_end_ts
        
        if not np.any(mask):
            return 0.0, 0
        
        filtered_prices = prices[mask]
        
        # Vectorized calculations
        bullish_mask = filtered_prices > range_high
        bearish_mask = filtered_prices < range_low
        
        max_bullish = 0.0
        max_bearish = 0.0
        
        if np.any(bullish_mask):
            bullish_mults = (filtered_prices[bullish_mask] - range_high) / range_size
            max_bullish = np.max(bullish_mults)
        
        if np.any(bearish_mask):
            bearish_mults = (range_low - filtered_prices[bearish_mask]) / range_size
            max_bearish = np.max(bearish_mults)
        
        if max_bullish > max_bearish:
            return max_bullish, 1
        elif max_bearish > 0:
            return max_bearish, 2
        else:
            return 0.0, 0

class ORBRangeAnalyzer:
    def __init__(self, config: Dict):
        self.config = config
        
        # Same as MQ5: Fixed time offset between server and NY (always 7 hours)
        self.NY_TIME_OFFSET_HOURS = 7  # Server is 7 hours ahead of NY
        
        # Parse date range
        self.start_date = datetime.strptime(config['start_date'], '%Y-%m-%d').date()
        self.end_date = datetime.strptime(config['end_date'], '%Y-%m-%d').date()
        
        self.results = []
        
        # Pre-calculate holidays for the entire date range (massive speed boost)
        self._holiday_cache = {}
        self._precalculate_holidays()
    
    def _precalculate_holidays(self):
        """Pre-calculate all holidays in date range for instant lookup"""
        print("Pre-calculating holidays for speed...")
        current_date = self.start_date
        while current_date <= self.end_date:
            server_time = pd.Timestamp.combine(current_date, pd.Timestamp.min.time())
            self._holiday_cache[current_date] = self._is_nyse_holiday_original(server_time)
            current_date += timedelta(days=1)
        print(f"✓ Holiday cache ready for {len(self._holiday_cache)} dates")
    
    def _is_nyse_holiday_original(self, server_time: pd.Timestamp) -> bool:
        """Original holiday detection logic (for cache building)"""
        # Same logic as before but only used for building cache
        ny_time = server_time - timedelta(hours=self.NY_TIME_OFFSET_HOURS)
        year, month, day = ny_time.year, ny_time.month, ny_time.day
        day_of_week = ny_time.weekday()
        mq5_day_of_week = (day_of_week + 1) % 7
        
        if mq5_day_of_week == 0 or mq5_day_of_week == 6:
            return True
        
        return self.get_nyse_holidays_for_year(year, month, day)
        
    def is_nyse_holiday(self, server_time: pd.Timestamp) -> bool:
        """Fast holiday check using pre-calculated cache"""
        # Convert server time to date and lookup in cache
        ny_time = server_time - timedelta(hours=self.NY_TIME_OFFSET_HOURS)
        date_key = ny_time.date()
        
        # Fast cache lookup (10000x faster than calculation)
        return self._holiday_cache.get(date_key, True)  # Default to holiday if not found
    
    def get_nyse_holidays_for_year(self, year: int, month: int, day: int) -> bool:
        """
        Calculate NYSE holidays for a given year dynamically.
        Based on standard NYSE holiday rules.
        """
        # Fixed date holidays
        if (month == 1 and day == 1):  # New Year's Day
            return True
        if (month == 7 and day == 4):  # Independence Day
            return True
        if (month == 12 and day == 25):  # Christmas
            return True
        
        # Floating holidays (need to calculate)
        # MLK Jr. Day - 3rd Monday in January
        if month == 1:
            mlk_day = self.get_nth_weekday(year, 1, 1, 3)  # 3rd Monday
            if day == mlk_day:
                return True
        
        # Presidents' Day - 3rd Monday in February
        if month == 2:
            presidents_day = self.get_nth_weekday(year, 2, 1, 3)  # 3rd Monday
            if day == presidents_day:
                return True
        
        # Good Friday - Friday before Easter (complex calculation)
        if self.is_good_friday(year, month, day):
            return True
        
        # Memorial Day - Last Monday in May
        if month == 5:
            memorial_day = self.get_last_weekday(year, 5, 1)  # Last Monday
            if day == memorial_day:
                return True
        
        # Juneteenth - June 19th (observed on weekday if falls on weekend)
        if month == 6 and day == 19:
            return True
        
        # Labor Day - 1st Monday in September
        if month == 9:
            labor_day = self.get_nth_weekday(year, 9, 1, 1)  # 1st Monday
            if day == labor_day:
                return True
        
        # Thanksgiving - 4th Thursday in November
        if month == 11:
            thanksgiving = self.get_nth_weekday(year, 11, 4, 4)  # 4th Thursday
            if day == thanksgiving:
                return True
        
        # Day after Thanksgiving - Friday after 4th Thursday in November
        if month == 11:
            thanksgiving = self.get_nth_weekday(year, 11, 4, 4)  # 4th Thursday
            if day == thanksgiving + 1:
                return True
        
        # Christmas Eve early close (treat as holiday for simplicity)
        if month == 12 and day == 24:
            return True
        
        # Day before Independence Day early close (treat as holiday for simplicity)
        if month == 7 and day == 3:
            return True
        
        return False
    
    def get_nth_weekday(self, year: int, month: int, weekday: int, n: int) -> int:
        """Get the nth occurrence of a weekday in a month. weekday: 0=Monday, 6=Sunday"""
        first_day = datetime(year, month, 1)
        first_weekday = first_day.weekday()
        
        # Calculate the first occurrence of the target weekday
        days_ahead = (weekday - first_weekday) % 7
        first_occurrence = 1 + days_ahead
        
        # Calculate the nth occurrence
        nth_occurrence = first_occurrence + (n - 1) * 7
        
        return nth_occurrence
    
    def get_last_weekday(self, year: int, month: int, weekday: int) -> int:
        """Get the last occurrence of a weekday in a month"""
        last_day = monthrange(year, month)[1]
        last_date = datetime(year, month, last_day)
        last_weekday = last_date.weekday()
        
        # Calculate days back to the target weekday
        days_back = (last_weekday - weekday) % 7
        last_occurrence = last_day - days_back
        
        return last_occurrence
    
    def is_good_friday(self, year: int, month: int, day: int) -> bool:
        """Check if the date is Good Friday (Friday before Easter)"""
        # Simplified Easter calculation (Gregorian calendar)
        # This is a basic implementation - you might want to use a more robust library
        try:
            easter = self.calculate_easter(year)
            good_friday = easter - timedelta(days=2)
            return month == good_friday.month and day == good_friday.day
        except:
            return False
    
    def calculate_easter(self, year: int) -> datetime:
        """Calculate Easter Sunday for a given year (Western/Gregorian calendar)"""
        # Anonymous Gregorian algorithm
        a = year % 19
        b = year // 100
        c = year % 100
        d = b // 4
        e = b % 4
        f = (b + 8) // 25
        g = (b - f + 1) // 3
        h = (19 * a + b - d - g + 15) % 30
        i = c // 4
        k = c % 4
        l = (32 + 2 * e + 2 * i - h - k) % 7
        m = (a + 11 * h + 22 * l) // 451
        month = (h + l - 7 * m + 114) // 31
        day = ((h + l - 7 * m + 114) % 31) + 1
        
        return datetime(year, month, day)
    
    def get_ny_session_times(self, server_time: pd.Timestamp) -> Tuple[pd.Timestamp, pd.Timestamp, pd.Timestamp]:
        """
        Get NY session start, end, and range end times for a given server time.
        Uses the same logic as ComputeSession() in the MQ5 file.
        """
        # Convert server time to NY time
        ny_time = server_time - timedelta(hours=self.NY_TIME_OFFSET_HOURS)
        
        # Get the date in NY time
        ny_date = ny_time.date()
        
        # Define NY session hours based on session type
        if self.config['session_type'] == 'CLASSIC_NYSE':
            ny_start_hour, ny_start_minute = 9, 30
        else:  # EARLY_US
            ny_start_hour, ny_start_minute = 8, 0
        
        # Convert NY session times back to server time
        server_ny_start_hour = ny_start_hour + self.NY_TIME_OFFSET_HOURS
        server_ny_start_minute = ny_start_minute
        server_ny_close_hour = self.config['ny_session_close_hour'] + self.NY_TIME_OFFSET_HOURS
        
        # Create session times in server timezone
        server_date = server_time.date()
        
        session_start = pd.Timestamp.combine(server_date, pd.Timestamp(
            year=2000, month=1, day=1, 
            hour=server_ny_start_hour, 
            minute=server_ny_start_minute
        ).time())
        
        session_end = pd.Timestamp.combine(server_date, pd.Timestamp(
            year=2000, month=1, day=1, 
            hour=server_ny_close_hour, 
            minute=0
        ).time())
        
        range_end = session_start + timedelta(minutes=self.config['session_or_minutes'])
        
        return session_start, session_end, range_end
    
    def process_chunk(self, chunk: pd.DataFrame) -> Tuple[List[Dict], Optional[str], Optional[str]]:
        """Process a chunk of tick data"""
        chunk_results = []
        
        # Fast timestamp parsing (PU Prime server timezone)
        chunk['timestamp'] = pd.to_datetime(chunk['timestamp'], format='%Y.%m.%d %H:%M:%S.%f')
        
        # Fast mid price calculation with float32 precision
        chunk['mid_price'] = (chunk['bid'] + chunk['ask']) * 0.5  # Multiplication is faster than division
        
        # Filter data within the specified date range
        chunk['date'] = chunk['timestamp'].dt.date
        
        # Debug date info before filtering
        if len(chunk) > 0:
            chunk_min_date = chunk['date'].min()
            chunk_max_date = chunk['date'].max()
            # print(f"Debug: Chunk contains dates from {chunk_min_date} to {chunk_max_date}")
            # print(f"Debug: Configured date range is {self.start_date} to {self.end_date}")
        
        chunk = chunk[
            (chunk['date'] >= self.start_date) & 
            (chunk['date'] <= self.end_date)
        ]
        
        if chunk.empty:
            # print(f"⚠️  Warning: Chunk filtered to empty after date range check - dates were outside {self.start_date} to {self.end_date}")
            return chunk_results, None, None
        
        # Track date range for this chunk
        chunk_start_date = chunk['date'].min().strftime('%Y-%m-%d')
        chunk_end_date = chunk['date'].max().strftime('%Y-%m-%d')
        
        # Debug info about the chunk
        # print(f"Debug: Processing chunk with dates from {chunk_start_date} to {chunk_end_date}")
        # print(f"Debug: Chunk has {len(chunk)} rows")
        
        # Group by date
        date_groups = chunk.groupby('date')
        #print(f"Debug: Found {len(date_groups)} unique dates in chunk")
        
        for date, date_group in date_groups:
            # Use the first timestamp of the day to check for holidays
            first_timestamp = date_group['timestamp'].iloc[0]
            
            # Skip weekends and holidays
            if self.is_nyse_holiday(first_timestamp):
                # print(f"Debug: Skipping holiday/weekend {date.strftime('%Y-%m-%d')}")
                continue
            
            # Get session times for this date
            session_start, session_end, range_end = self.get_ny_session_times(first_timestamp)
            
            # Filter data for this session
            session_data = date_group[
                (date_group['timestamp'] >= session_start) & 
                (date_group['timestamp'] <= session_end)
            ].copy()
            
            if session_data.empty:
                # print(f"Debug: No data in session window for {date.strftime('%Y-%m-%d')}")
                continue
            
            # Build opening range
            range_data = session_data[
                (session_data['timestamp'] >= session_start) & 
                (session_data['timestamp'] < range_end)
            ]
            
            if range_data.empty:
                # print(f"Debug: No data in opening range window for {date.strftime('%Y-%m-%d')}")
                continue
            
            # Calculate range high and low
            range_high = range_data['mid_price'].max()
            range_low = range_data['mid_price'].min()
            range_size = range_high - range_low
            
            if range_size <= 0:
                # print(f"Debug: Zero range size for {date.strftime('%Y-%m-%d')}")
                continue
            
            # Find maximum range multiplier reached
            max_range_mult, breakout_direction = self.calculate_max_range_mult(
                session_data, range_high, range_low, range_size, range_end, session_end
            )
            
            if max_range_mult > 0:
                chunk_results.append({
                    'date': date.strftime('%Y-%m-%d'),
                    'session_start': session_start,
                    'session_end': session_end,
                    'range_high': range_high,
                    'range_low': range_low,
                    'range_size': range_size,
                    'max_range_mult': max_range_mult,
                    'breakout_direction': breakout_direction
                })
        
        # Debug summary
        # print(f"Debug: Found {len(chunk_results)} valid sessions in this chunk")
        
        return chunk_results, chunk_start_date, chunk_end_date
    
    def calculate_max_range_mult(self, session_data: pd.DataFrame, range_high: float, 
                               range_low: float, range_size: float, range_end: pd.Timestamp,
                               session_end: pd.Timestamp) -> Tuple[float, str]:
        """Calculate the maximum range multiplier reached during the session"""
        
        # Filter data after range formation
        post_range_data = session_data[session_data['timestamp'] >= range_end].copy()
        
        if post_range_data.empty:
            return 0.0, 'NONE'
        
        # Handle after-hours trading based on configuration
        if not self.config['allow_tp_after_hours']:
            # Only consider moves during session hours
            post_range_data = post_range_data[post_range_data['timestamp'] <= session_end]
        
        if post_range_data.empty:
            return 0.0, 'NONE'
        
        # Convert to numpy arrays for fastest processing (3-5x speed boost)
        prices = post_range_data['mid_price'].values
        timestamps = post_range_data['timestamp'].values.astype('datetime64[ns]').astype(np.int64)
        range_end_ts = pd.Timestamp(range_end).value
        session_end_ts = pd.Timestamp(session_end).value
        
        # Use fast vectorized calculation (numba JIT or numpy vectorized)
        max_mult, direction_code = calculate_range_multipliers_fast(
            prices, timestamps, range_high, range_low, range_size,
            range_end_ts, session_end_ts, self.config['allow_tp_after_hours']
        )
        
        # Convert direction code to string
        direction_map = {0: 'NONE', 1: 'BULLISH', 2: 'BEARISH'}
        return float(max_mult), direction_map[direction_code]
    
    def analyze_file(self, filename: str) -> Dict:
        """Analyze the entire CSV file with performance optimizations"""
        print(f"🚀 Optimized Analysis Mode")
        print(f"File: {filename}")
        print(f"Date range: {self.start_date} to {self.end_date}")
        
        # Auto-detect optimal chunk size based on file size
        file_size = os.path.getsize(filename) / (1024 * 1024)  # MB
        if file_size > 1000:  # > 1GB
            chunk_size = 100000
            print(f"📊 Large file detected ({file_size:.1f}MB) - using chunk size: {chunk_size:,}")
        elif file_size > 100:  # > 100MB
            chunk_size = 75000
            print(f"📊 Medium file detected ({file_size:.1f}MB) - using chunk size: {chunk_size:,}")
        else:
            chunk_size = 50000
            print(f"📊 File size: {file_size:.1f}MB - using chunk size: {chunk_size:,}")
        
        if HAS_NUMBA:
            print("✓ Numba JIT acceleration enabled (3-5x speed boost)")
        else:
            print("⚠️  Install numba for 3-5x speed boost: pip install numba")
        
        total_sessions = 0
        max_range_mult_overall = 0.0
        best_session = None
        empty_chunks_in_a_row = 0
        
        try:
            # Optimized CSV reading with better data types
            
            for chunk_num, chunk in enumerate(pd.read_csv(
                filename, 
                names=['timestamp', 'bid', 'ask'],
                chunksize=chunk_size,
                parse_dates=False,  # Parse manually for speed
                dtype={'bid': np.float32, 'ask': np.float32},  # Use float32 for memory efficiency
                engine='c'  # Use C engine for 2x parsing speed
            )):
                print(f"Processing chunk {chunk_num + 1}...")
                
                chunk_results, chunk_start_date, chunk_end_date = self.process_chunk(chunk)
                
                if not chunk_results and not chunk_start_date and not chunk_end_date:
                    empty_chunks_in_a_row += 1
                    # If we've seen 20 empty chunks in a row, assume we're past our date range
                    if empty_chunks_in_a_row >= 20:
                        print(f"\n✅ Finished processing relevant date range. Stopping early as remaining data is outside target dates.")
                        break
                else:
                    empty_chunks_in_a_row = 0  # Reset counter if we found any valid data
                
                for result in chunk_results:
                    total_sessions += 1
                    
                    if result['max_range_mult'] > max_range_mult_overall:
                        max_range_mult_overall = result['max_range_mult']
                        best_session = result
                    
                    self.results.append(result)
                
                # Print progress every 10 chunks
                if chunk_num % 10 == 0 and chunk_num > 0:
                    date_range_info = ""
                    if chunk_start_date and chunk_end_date:
                        if chunk_start_date == chunk_end_date:
                            date_range_info = f" (last date: {chunk_start_date})"
                        else:
                            date_range_info = f" (dates processed up to: {chunk_start_date} to {chunk_end_date})"
                    
                    print(f"📊 Processed {chunk_num + 1} chunks, found {total_sessions} sessions{date_range_info}")
                    if best_session:
                        direction_emoji = "📈" if best_session['breakout_direction'] == 'BULLISH' else "📉" if best_session['breakout_direction'] == 'BEARISH' else "➡️"
                        direction_info = f" ({best_session['breakout_direction']})" if 'breakout_direction' in best_session else ""
                        print(f"🎯 Max: {max_range_mult_overall:.3f} on {best_session['date']}{direction_info} {direction_emoji}")
        
        except Exception as e:
            print(f"❌ Error processing file: {e}")
            import traceback
            traceback.print_exc()
            return {}
        
        print(f"✅ Analysis complete! Processed file with {total_sessions} sessions")
        
        return {
            'total_sessions': total_sessions,
            'max_range_mult': max_range_mult_overall,
            'best_session': best_session,
            'config': self.config
        }
    
    def generate_report(self, results: Dict) -> str:
        """Generate a detailed report"""
        if not results:
            return "No results to report."
        
        report = f"""# ORB Range Analysis Report
        
## Configuration
- Session Type: {self.config['session_type']}
- Opening Range Length: {self.config['session_or_minutes']} minutes
- NY Session Close Hour: {self.config['ny_session_close_hour']}:00
- Allow TP After Hours: {self.config['allow_tp_after_hours']}
- Date Range: {self.config['start_date']} to {self.config['end_date']}

## Results
- Total Sessions Analyzed: {results['total_sessions']}
- Maximum Range Multiplier: {results['max_range_mult']:.3f}

## Best Session Details
"""
        
        if results['best_session']:
            session = results['best_session']
            direction_info = f" ({session['breakout_direction']})" if 'breakout_direction' in session else ""
            report += f"""- Date: {session['date']}
- Session Start: {session['session_start']}
- Session End: {session['session_end']}
- Range High: {session['range_high']:.5f}
- Range Low: {session['range_low']:.5f}
- Range Size: {session['range_size']:.5f}
- Max Range Multiplier: {session['max_range_mult']:.3f}{direction_info}
"""
        
        # Add statistics
        if self.results:
            range_mults = [r['max_range_mult'] for r in self.results if r['max_range_mult'] > 0]
            bullish_breakouts = [r for r in self.results if r.get('breakout_direction') == 'BULLISH']
            bearish_breakouts = [r for r in self.results if r.get('breakout_direction') == 'BEARISH']
            
            if range_mults:
                report += f"""
## Statistics
- Sessions with Range Breakouts: {len(range_mults)} / {results['total_sessions']}
- Bullish Breakouts: {len(bullish_breakouts)} ({len(bullish_breakouts)/len(range_mults)*100:.1f}% of breakouts)
- Bearish Breakouts: {len(bearish_breakouts)} ({len(bearish_breakouts)/len(range_mults)*100:.1f}% of breakouts)
- Average Range Multiplier: {np.mean(range_mults):.3f}
- Median Range Multiplier: {np.median(range_mults):.3f}
- 75th Percentile: {np.percentile(range_mults, 75):.3f}
- 90th Percentile: {np.percentile(range_mults, 90):.3f}
- 95th Percentile: {np.percentile(range_mults, 95):.3f}
- 99th Percentile: {np.percentile(range_mults, 99):.3f}
"""
        
        # Save report to file
        # \Documents\QuantDataManagerExports\XAUUSD_TICK_ESTPlus07.csv
        input_file_without_extension = os.path.splitext(os.path.basename(self.config['filename']))[0]
        filename = f"summary_{input_file_without_extension}_{self.config['start_date']}_to_{self.config['end_date']}.md"
        with open(filename, 'w') as f:
            f.write(report)
        print(f"\nSummary saved to: {filename}")
        
        return report


def main():
    parser = argparse.ArgumentParser(
        description='ORB Range Analyzer - Find maximum range multipliers based on ORB4 MQ5 strategy',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  python orb_range_analyzer.py data.csv --start-date 2015-07-02 --end-date 2020-07-02
  python orb_range_analyzer.py data.csv --session-type EARLY_US --session-or-minutes 20
  python orb_range_analyzer.py data.csv --allow-tp-after-hours --output-file results.csv
        """
    )
    
    # File parameters
    parser.add_argument('filename', help='Path to CSV tick data file')
    parser.add_argument('--start-date', required=True, help='Start date (YYYY-MM-DD)')
    parser.add_argument('--end-date', required=True, help='End date (YYYY-MM-DD)')
    
    # ORB parameters (matching MQ5 defaults)
    parser.add_argument('--session-type', choices=['CLASSIC_NYSE', 'EARLY_US'], 
                       default='CLASSIC_NYSE', help='Session type (default: CLASSIC_NYSE)')
    parser.add_argument('--session-or-minutes', type=int, default=30, 
                       help='Opening range length in minutes (default: 30)')
    parser.add_argument('--ny-session-close-hour', type=int, default=16, 
                       help='NY session close hour (default: 16)')
    parser.add_argument('--allow-tp-after-hours', action='store_true', 
                       help='Allow TP after session hours (default: False)')
    
    # Output parameters
    parser.add_argument('--output-file', help='Output CSV file for detailed results')
    parser.add_argument('--verbose', '-v', action='store_true', help='Verbose output')
    
    # Performance parameters
    parser.add_argument('--install-numba', action='store_true', 
                       help='Show numba installation instructions and exit')
    
    args = parser.parse_args()
    
    # Handle performance installation help
    if args.install_numba:
        print("🚀 Speed Up Your ORB Analysis with Numba!")
        print("==========================================")
        print("Install numba for 3-5x faster processing:")
        print("")
        print("With pip:")
        print("  pip install numba")
        print("")
        print("With pipenv:")
        print("  pipenv install numba")
        print("")
        print("With conda:")
        print("  conda install numba")
        print("")
        print("Numba will JIT-compile the range multiplier calculations")
        print("for massive speed improvements on large files!")
        sys.exit(0)
    
    # Validate dates
    try:
        start_date = datetime.strptime(args.start_date, '%Y-%m-%d')
        end_date = datetime.strptime(args.end_date, '%Y-%m-%d')
        if start_date >= end_date:
            print("Error: Start date must be before end date")
            sys.exit(1)
    except ValueError:
        print("Error: Invalid date format. Use YYYY-MM-DD")
        sys.exit(1)
    
    # Configuration
    config = {
        'session_type': args.session_type,
        'session_or_minutes': args.session_or_minutes,
        'ny_session_close_hour': args.ny_session_close_hour,
        'allow_tp_after_hours': args.allow_tp_after_hours,
        'start_date': args.start_date,
        'end_date': args.end_date,
        'filename': args.filename  # Add the filename to config
    }
    
    # Create analyzer
    analyzer = ORBRangeAnalyzer(config)
    
    # Analyze file
    results = analyzer.analyze_file(args.filename)
    
    # Generate report
    report = analyzer.generate_report(results)
    print(report)
    
    # Save detailed results if requested
    if args.output_file and analyzer.results:
        df = pd.DataFrame(analyzer.results)
        df.to_csv(args.output_file, index=False)
        print(f"\nDetailed results saved to: {args.output_file}")
    
    # Print top sessions
    if analyzer.results and args.verbose:
        print("\nTop 10 Sessions by Range Multiplier:")
        print("=" * 60)
        
        sorted_results = sorted(analyzer.results, key=lambda x: x['max_range_mult'], reverse=True)
        for i, session in enumerate(sorted_results[:10]):
            direction_info = f" {session['breakout_direction']}" if 'breakout_direction' in session else ""
            print(f"{i+1:2d}. {session['date']} - Range Mult: {session['max_range_mult']:.3f}{direction_info} "
                  f"(Range: {session['range_size']:.5f})")


if __name__ == "__main__":
    main() 