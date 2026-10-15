from src.params.enums import Interval, Symbol

# All symbols the system collects, stores, and predicts for
SUPPORTED_SYMBOLS = [Symbol.BTCUSDT] #Symbol.ETHUSDT

# REST API: 15-minute candles for historical data / ML training
DEFAULT_REST_INTERVAL = Interval.ONE_MINUTE

# WebSocket: 1-minute candles for the live streaming dashboard
DEFAULT_WS_INTERVAL = Interval.ONE_MINUTE

# Binance REST API endpoint for historical OHLCV kline data
BINANCE_KLINES_URL = "https://api.binance.com/api/v3/klines"

# WebSocket host root — use build_stream_url() from src/utils/url_utils.py to build the full stream URL
BINANCE_WS_BASE_URL = "wss://stream.binance.com:9443"

# The 12 fields returned by Binance per candle — order matches the API response exactly
BINANCE_KLINES_COLUMNS = [
    "open_time",
    "open",
    "high",
    "low",
    "close",
    "volume",
    "close_time",
    "quote_asset_volume",
    "number_of_trades",
    "taker_buy_base_volume",
    "taker_buy_quote_volume",
    "ignore"
]


# Starting point for historical data collection (can be adjusted as needed)
HISTORICAL_START_DATE = "01.10.2026T00:00"

# Storage names — single source of truth, shared by writers, init, and ML
POSTGRES_TABLE = "ohlcv_data"        # historical candles (batch pipeline)
MONGO_COLLECTION = "closed_candles"  # completed live candles (stream pipeline)
PREDICTIONS_COLLECTION = "predictions"  # model forecasts (for predicted-vs-actual tracking)

# Trained ML model artifact (saved under the repo's models/ directory)
MODEL_FILENAME = "model.pkl"