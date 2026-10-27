from datetime import timedelta

import pandas as pd

from src.storage.mongo import get_collection
from src.features.build_features import make_features
from src.models.model_store import load_model
from src.params.constants import (
    SUPPORTED_SYMBOLS,
    MONGO_COLLECTION,
)

SYMBOL = SUPPORTED_SYMBOLS[0].value

# How far ahead the "next" candle is, per Binance interval string.
INTERVAL_MINUTES = {"1m": 1, "5m": 5, "15m": 15, "1h": 60, "1d": 1440}


def predict_next_close_detailed(symbol=SYMBOL, n=1):
    """Predict the next candle's close from the latest candle in Mongo.

    Returns a dict with the prediction AND the timing info needed to store it:
      - source_kline_start_time : the candle fed to the model (the input)
      - target_kline_start_time : the candle being predicted (input + 1 interval)
      - predicted_close         : the model's forecast
    """
    # 1. The trained model (cached; reloaded only when a newer one was saved)
    model = load_model()

    # 2. Get the last N completed candles from Mongo (newest first)
    col = get_collection(MONGO_COLLECTION)
    docs = list(col.find({"symbol": symbol}).sort("kline_start_time", -1).limit(n))
    if not docs:
        raise ValueError("No candles in Mongo yet — run stream_live.py first.")

    # 3. Build the SAME features used in training, then predict
    df = pd.DataFrame(docs)
    X = make_features(df)
    predicted_close = float(model.predict(X)[0])   # row 0 = newest candle

    # 4. Work out which candle this prediction is FOR (the next one)
    source = docs[0]
    source_start = source["kline_start_time"]
    minutes = INTERVAL_MINUTES.get(source.get("interval", "1m"), 1)
    target_start = source_start + timedelta(minutes=minutes)

    return {
        "symbol": symbol,
        "source_kline_start_time": source_start,
        "target_kline_start_time": target_start,
        "predicted_close": predicted_close,
    }


def predict_next_close(symbol=SYMBOL, n=1):
    """Backwards-compatible helper: return just the predicted close value."""
    return predict_next_close_detailed(symbol=symbol, n=n)["predicted_close"]


if __name__ == "__main__":
    print("Predicted next close:", predict_next_close())
