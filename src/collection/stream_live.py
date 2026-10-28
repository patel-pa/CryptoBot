import json
from concurrent.futures import ThreadPoolExecutor

import requests
import websocket
from pymongo.errors import ConnectionFailure

from src.config import api_base_url
from src.params.constants import SUPPORTED_SYMBOLS, DEFAULT_WS_INTERVAL
from src.storage.mongo import wait_for_mongo
from src.storage.mongo_writer import save_closed_candle
from src.utils.retry import retry
from src.utils.url_utils import build_stream_url
from src.utils.time_utils import ms_to_timestamp

# Candles close once a minute: with 3 tries (waits 1 s, 2 s) and short request
# timeouts, one candle's work is done well before the next one closes.
ATTEMPTS = 3
PREDICT_TIMEOUT = (3, 10)        # seconds: (connect to the API, wait for its answer)

# One worker thread handles closed candles, in order. The WebSocket loop only
# hands them over: if it waited for a slow database or API, it could not read
# the keepalive pong in time, and the connection would be dropped and reopened.
closed_candle_worker = ThreadPoolExecutor(max_workers=1, thread_name_prefix="closed-candle")


def parse_tick(k):
    """Decode a Binance kline payload (the inner 'k' object) into a flat doc.
    Mirrors parse_tick() from notebook 02."""
    return {
        "symbol": k["s"],
        "kline_start_time": ms_to_timestamp(k["t"]),
        "kline_close_time": ms_to_timestamp(k["T"]),
        "interval": k["i"],
        "open": float(k["o"]),
        "high": float(k["h"]),
        "low": float(k["l"]),
        "close": float(k["c"]),
        "volume": float(k["v"]),
        "number_of_trades": k["n"],
        "is_candle_closed": k["x"],
    }


def request_forecast(symbol):
    """POST /predict: the API forecasts the candle after the one just stored.

    Retried only when the request may not have reached the API (connection
    refused or dropped, API restarting). Retrying a POST is safe here: the
    API keeps one forecast per target candle (upsert), never a duplicate.
    An error answer (503 = no model yet) or a slow API is not retried.
    """
    def post():
        response = requests.post(f"{api_base_url()}/predict", params={"symbol": symbol},
                                 timeout=PREDICT_TIMEOUT)
        response.raise_for_status()
        return response.json()

    return retry(post, attempts=ATTEMPTS, exceptions=(requests.ConnectionError,),
                 what="Forecast request")


def on_candle_closed(candle):
    """A candle has closed: store it, then ask the API to forecast the next one.

    The ONE place that reacts to a closed candle, so the direct API call can
    later be swapped for a queue message (SQS) without touching the
    WebSocket code. Runs on closed_candle_worker. Never raises: failures are
    logged and the stream goes on.
    """
    symbol, start = candle["symbol"], candle["kline_start_time"]
    try:
        # Upsert, so a retried write never stores the candle twice.
        retry(lambda: save_closed_candle(candle), attempts=ATTEMPTS,
              exceptions=(ConnectionFailure,), what="Saving the closed candle")
    except Exception as exc:
        print(f"Could not save closed candle {symbol} {start}: {exc!r}. "
              "No forecast for it.", flush=True)
        return
    print(f"Saved closed candle: {symbol} {start}", flush=True)

    try:
        forecast = request_forecast(symbol)
        print(f"Forecast for {symbol} {forecast['target_time']}: "
              f"{forecast['predicted_next_close']:.2f}", flush=True)
    except requests.HTTPError as exc:       # the API answered, with an error status
        print(f"No forecast after {symbol} {start}: API answered "
              f"{exc.response.status_code} {exc.response.text[:200]}", flush=True)
    except Exception as exc:                # unreachable after the retries, too slow, ...
        print(f"No forecast after {symbol} {start}: {exc!r}", flush=True)


def on_message(ws, message):
    payload = json.loads(message)
    data = payload.get("data", payload)      # combined stream wraps each event in "data"
    candle = parse_tick(data["k"])

    # Path A (every tick to the browser) is the API's /stream endpoint.

    # Path B: only completed candles are stored, and each one triggers a forecast
    # (on the worker thread, so this loop goes straight back to reading).
    if candle["is_candle_closed"]:
        closed_candle_worker.submit(on_candle_closed, candle)


def on_error(ws, error):
    print(f"WebSocket error: {error}")


def on_close(ws, status_code, msg):
    print(f"WebSocket closed: {status_code} {msg}")


def on_open(ws):
    print("WebSocket connected — streaming live candles…")


def main():
    wait_for_mongo()                        # pods start in any order on Kubernetes
    # Fails fast on a malformed API_BASE. The API itself may still be starting:
    # the stream runs anyway, forecasts begin as soon as the API answers.
    print(f"Forecasts: POST {api_base_url()}/predict after each closed candle", flush=True)
    url = build_stream_url(SUPPORTED_SYMBOLS, DEFAULT_WS_INTERVAL)
    ws = websocket.WebSocketApp(
        url,
        on_open=on_open,
        on_message=on_message,
        on_error=on_error,
        on_close=on_close,
    )
    # Auto-reconnect 5s after any drop, with keepalive pings (every 20s, 10s
    # timeout) so a dead connection is detected and re-established instead of
    # silently leaving a gap in closed_candles.
    ws.run_forever(reconnect=5, ping_interval=20, ping_timeout=10)


if __name__ == "__main__":
    main()
