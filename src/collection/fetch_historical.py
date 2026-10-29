from time import sleep, time_ns

import requests

from src.config import historical_start_date
from src.params.constants import BINANCE_KLINES_URL, DEFAULT_REST_INTERVAL, SUPPORTED_SYMBOLS
from src.storage.postgres import wait_for_postgres
from src.storage.postgres_writer import get_last_close_ms, save_to_postgres
from src.utils.dataframe_utils import raw_to_dataframe
from src.utils.retry import retry
from src.utils.time_utils import to_ms

SYMBOL = SUPPORTED_SYMBOLS[0].value
PAGE_SIZE = 1000                            # Binance's maximum candles per request

# Columns to persist, in the DB's order.
DB_COLUMNS = ["symbol", "open_time", "open", "high", "low", "close",
              "volume", "close_time", "number_of_trades"]


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

    def fetch():
        response = requests.get(BINANCE_KLINES_URL, params=params, timeout=10)
        response.raise_for_status()
        return response.json()

    # A transient network blip, a 429 (rate limit), or a 5xx during the long
    # backfill shouldn't crash the whole run. Retrying is safe: the outer loop
    # resumes from the last stored candle, so re-fetching a page never
    # duplicates or skips data. Waits 2, 4, 8, 16 s between the 5 attempts.
    return retry(fetch, attempts=5, base_delay=2, max_delay=30,
                 exceptions=(requests.RequestException,), what="Binance request")


def backfill(symbol=SYMBOL, now_ms=None):
    """Store every closed candle missing from Postgres; return how many were stored.

    Resumes 1 ms after the newest stored candle; an empty database starts at
    HISTORICAL_START_DATE. Safe to run again at any time (the scheduled ingest
    job runs it every 15 minutes). `now_ms` can be fixed in tests.
    """
    wait_for_postgres()                     # pods start in any order on Kubernetes

    last_close_ms = get_last_close_ms(symbol)
    if last_close_ms is not None:
        start_time = last_close_ms + 1          # resume 1ms after last stored candle
    else:
        start_time = to_ms(historical_start_date())  # empty DB → configured start

    end_time = now_ms if now_ms is not None else time_ns() // 1_000_000

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
        page = get_binance_data(
            symbol=symbol,
            interval=DEFAULT_REST_INTERVAL,
            start_time=start_time,
            end_time=end_time,
            limit=PAGE_SIZE,
        )
        # Binance also returns the minute that is still open (it closes after
        # end_time), with partial prices. Store only closed candles: stored now, the
        # open one would never be corrected (the next run starts after it, and the
        # insert skips rows that exist). The next run fetches it once it has closed.
        batch = [k for k in page if k[6] < end_time]     # k[6] = close_time (ms)
        if not batch:
            break

        df = raw_to_dataframe(batch)
        df["symbol"] = symbol
        save_to_postgres(df[DB_COLUMNS])        # small batched upsert for THIS page

        total_saved += len(batch)
        print(f"Saved {total_saved:,} candles for {symbol} "
              f"(through {df['open_time'].iloc[-1]})", flush=True)

        start_time = batch[-1][6] + 1           # 1ms after last candle's close_time
        if len(batch) < PAGE_SIZE:              # partial page or open candle reached → done
            break
        sleep(0.15)                             # respect Binance rate limits

    if total_saved == 0:
        print("No new candles to fetch — database is already up to date.", flush=True)
    else:
        print(f"Backfill complete: {total_saved:,} candles for {symbol}.", flush=True)
    return total_saved


if __name__ == "__main__":
    backfill()
