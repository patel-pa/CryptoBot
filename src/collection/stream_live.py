import json

import websocket

from src.params.constants import SUPPORTED_SYMBOLS, DEFAULT_WS_INTERVAL
from src.storage.mongo import wait_for_mongo
from src.storage.mongo_writer import save_closed_candle
from src.utils.url_utils import build_stream_url
from src.utils.time_utils import ms_to_timestamp


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


def on_message(ws, message):
    payload = json.loads(message)
    data = payload.get("data", payload)      # combined stream wraps each event in "data"
    candle = parse_tick(data["k"])

    # Path A (forward every tick to FastAPI) → deferred until the API exists.

    # Path B: only completed candles are persisted to MongoDB.
    if candle["is_candle_closed"]:
        save_closed_candle(candle)
        print(f"Saved closed candle: {candle['symbol']} {candle['kline_start_time']}")


def on_error(ws, error):
    print(f"WebSocket error: {error}")


def on_close(ws, status_code, msg):
    print(f"WebSocket closed: {status_code} {msg}")


def on_open(ws):
    print("WebSocket connected — streaming live candles…")


def main():
    wait_for_mongo()                        # pods start in any order on Kubernetes
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
