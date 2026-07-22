import sys
import os
from time import sleep, time_ns

sys.path.append(os.path.abspath(os.path.join(os.getcwd(), '..')))

import requests
import pandas as pd
from dotenv import load_dotenv
load_dotenv()

from src.utils.time_utils import to_ms
from src.params.constants import BINANCE_KLINES_URL, HISTORICAL_START_DATE, DEFAULT_REST_INTERVAL
from src.utils.dataframe_utils import raw_to_dataframe

from src.storage.postgres_writer import save_to_postgres, get_last_close_ms



def get_binance_data(
    symbol: str = "BTCUSDT",
    interval: str = "1m",
    start_time: int | None = None,
    end_time: int | None = None,
    limit: int = 1000
    ):
    params = {
        "symbol": symbol,
        "interval": interval,
        "limit": limit,
    }
    if start_time is not None:
        params["startTime"] = start_time
    if end_time is not None:
        params["endTime"] = end_time

    # Bounded retry with exponential backoff. A transient network blip, a 429
    # (rate limit), or a 5xx during the long backfill shouldn't crash the whole
    # run. This is safe to retry: the outer loop resumes from the last stored
    # candle, so re-fetching a page never duplicates or skips data.
    last_error = None
    for attempt in range(1, 6):                       # up to 5 attempts
        try:
            response = requests.get(BINANCE_KLINES_URL, params=params, timeout=10)
            response.raise_for_status()
            return response.json()
        except requests.RequestException as exc:
            last_error = exc
            if attempt == 5:
                break
            backoff = min(2 ** attempt, 30)           # 2, 4, 8, 16 → capped at 30s
            print(f"Binance request failed (attempt {attempt}/5): {exc}. "
                  f"Retrying in {backoff}s…", flush=True)
            sleep(backoff)
    raise last_error                                  # exhausted retries — surface it


SYMBOL = "BTCUSDT"

# Columns to persist, in the DB's order.
DB_COLUMNS = ["symbol", "open_time", "open", "high", "low", "close",
              "volume", "close_time", "number_of_trades"]

last_close_ms = get_last_close_ms(SYMBOL)
if last_close_ms is not None:
    start_time = last_close_ms + 1              # resume 1ms after last stored candle
else:
    start_time = to_ms(HISTORICAL_START_DATE)   # empty DB → default start

end_time  = time_ns() // 1_000_000          # now, in ms

# Persist each 1000-candle page AS SOON AS it arrives, instead of accumulating
# the whole history in memory and writing it once at the very end. Why this is
# better (and NOT harder on Postgres):
#   • the dashboard sees data within seconds, not after the full ~280k-row backfill
#   • memory stays bounded — one page at a time, never the whole history in RAM
#   • each write is a small, fast-committing 1000-row upsert (ON CONFLICT DO
#     NOTHING) — far gentler than one multi-million-parameter INSERT
#   • the write rate is capped by the fetch loop's sleep(0.15) + API latency
#     (~2 pages/sec), so Postgres is idle most of the time — no chance of overload
#   • if the run is interrupted, the rows already saved let the NEXT run resume
#     from get_last_close_ms instead of starting over
total_saved = 0
while start_time < end_time:
    batch = get_binance_data(
        symbol=SYMBOL,
        interval=DEFAULT_REST_INTERVAL,
        start_time=start_time,
        end_time=end_time,
        limit=1000,
    )
    if not batch:
        break

    df = raw_to_dataframe(batch)
    df["symbol"] = SYMBOL
    save_to_postgres(df[DB_COLUMNS])        # small batched upsert for THIS page

    total_saved += len(batch)
    print(f"Saved {total_saved:,} candles for {SYMBOL} "
          f"(through {df['open_time'].iloc[-1]})", flush=True)

    start_time = batch[-1][6] + 1           # 1ms after last candle's close_time
    if len(batch) < 1000:                   # last (partial) page → done
        break
    sleep(0.15)                             # respect Binance rate limits


if total_saved == 0:
    print("No new candles to fetch — database is already up to date.")
else:
    print(f"Backfill complete: {total_saved:,} candles for {SYMBOL}.")

