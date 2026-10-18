import json

import pandas as pd
import websockets
from fastapi import FastAPI, HTTPException, WebSocket, WebSocketDisconnect
from fastapi.encoders import jsonable_encoder
from sqlalchemy import text

from src.storage.postgres import get_engine
from src.storage.mongo import get_collection
from src.storage.mongo_writer import save_prediction
from src.params.constants import (
    POSTGRES_TABLE,
    SUPPORTED_SYMBOLS,
    DEFAULT_WS_INTERVAL,
    MONGO_COLLECTION,
    PREDICTIONS_COLLECTION,
)
from src.models.predict_model import predict_next_close_detailed
from src.utils.url_utils import build_stream_url
from src.collection.stream_live import parse_tick

app = FastAPI(title="CryptoBot API")

DEFAULT_SYMBOL = SUPPORTED_SYMBOLS[0].value


@app.get("/health")
def health():
    """Quick check that the API is running."""
    return {"status": "ok"}


@app.get("/charts")
def charts(symbol: str = DEFAULT_SYMBOL, limit: int = 100):
    """Recent historical candles from Postgres, oldest -> newest (for charting)."""
    query = text(
        f"SELECT * FROM {POSTGRES_TABLE} WHERE symbol = :s "
        f"ORDER BY open_time DESC LIMIT :n"
    )
    df = pd.read_sql(query, get_engine(), params={"s": symbol, "n": limit})
    records = df.to_dict(orient="records")
    return records[::-1]  # reverse DESC fetch back into chronological order


@app.get("/predict")
def predict(symbol: str = DEFAULT_SYMBOL):
    """Predicted close of the next candle, from the latest candle in Mongo.

    The forecast is also persisted (upsert) so /predictions can chart the
    predicted-vs-actual history later.
    """
    try:
        result = predict_next_close_detailed(symbol=symbol)
    except ValueError as e:
        raise HTTPException(status_code=404, detail=str(e))
    save_prediction(result)
    return {
        "symbol": symbol,
        "predicted_next_close": result["predicted_close"],
        "target_time": result["target_kline_start_time"],
    }


@app.get("/predictions")
def predictions(symbol: str = DEFAULT_SYMBOL, limit: int = 240):
    """Recent stored forecasts, each joined with the candle's ACTUAL close.

    Rows are oldest -> newest, with fields:
      target_time, predicted_close, actual_close (None until that candle closes).
    """
    preds_col = get_collection(PREDICTIONS_COLLECTION)
    closed_col = get_collection(MONGO_COLLECTION)

    docs = list(
        preds_col.find({"symbol": symbol})
        .sort("target_kline_start_time", -1)
        .limit(limit)
    )
    docs.reverse()                       # oldest -> newest, for charting
    if not docs:
        return []

    # Fetch the actual close for every predicted candle in ONE query.
    targets = [d["target_kline_start_time"] for d in docs]
    actuals = {
        c["kline_start_time"]: float(c["close"])
        for c in closed_col.find(
            {"symbol": symbol, "kline_start_time": {"$in": targets}},
            {"kline_start_time": 1, "close": 1},
        )
    }

    return [
        {
            "target_time": d["target_kline_start_time"],
            "predicted_close": float(d["predicted_close"]),
            "actual_close": actuals.get(d["target_kline_start_time"]),
        }
        for d in docs
    ]


@app.websocket("/stream")
async def stream(websocket: WebSocket):
    """Path A: relay every live tick from Binance straight to the browser."""
    await websocket.accept()
    url = build_stream_url(SUPPORTED_SYMBOLS, DEFAULT_WS_INTERVAL)
    try:
        async with websockets.connect(url) as binance:
            async for message in binance:                 # one message ~per second
                payload = json.loads(message)
                data = payload.get("data", payload)       # combined stream wraps in "data"
                candle = parse_tick(data["k"])
                await websocket.send_json(jsonable_encoder(candle))
    except WebSocketDisconnect:
        pass 