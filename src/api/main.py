import asyncio
import json

import pandas as pd
import websockets
from fastapi import FastAPI, HTTPException, WebSocket, WebSocketDisconnect
from fastapi.encoders import jsonable_encoder
from fastapi.responses import JSONResponse
from sqlalchemy import text

from src.storage import mongo, postgres
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
from src.models.model_store import ModelUnavailable
from src.models.predict_model import predict_next_close_detailed
from src.utils.url_utils import build_stream_url
from src.collection.stream_live import parse_tick

app = FastAPI(title="CryptoBot API")

DEFAULT_SYMBOL = SUPPORTED_SYMBOLS[0].value

# Upper bound for each /ready check. A Kubernetes readiness probe must answer
# quickly; the probe's own timeout (set in the manifests) is a bit higher.
READY_TIMEOUT_SECONDS = 2.0


@app.get("/health")
def health():
    """Liveness: the API process is up.

    Deliberately makes no database calls, so a database outage never makes
    Kubernetes restart healthy API pods (that is what /ready is for).
    """
    return {"status": "ok"}


async def _check(name, ping):
    """Run one blocking database ping in a worker thread, with a time limit.

    Returns "ok", "timeout" or "unavailable". Error details go to the log
    only: /ready may be reachable from outside, and driver error messages
    can contain internal host names.
    """
    try:
        await asyncio.wait_for(asyncio.to_thread(ping), timeout=READY_TIMEOUT_SECONDS)
        return "ok"
    except TimeoutError:
        print(f"Readiness: {name} did not answer within {READY_TIMEOUT_SECONDS:g}s", flush=True)
        return "timeout"
    except Exception as exc:
        print(f"Readiness: {name} unavailable: {exc!r}", flush=True)
        return "unavailable"


@app.get("/ready")
async def ready():
    """Readiness: can the API serve requests right now?

    Pings PostgreSQL and MongoDB in parallel: 200 if both answer, 503
    otherwise. Kubernetes only sends traffic to ready pods, and leaves an
    unready pod running (no restart) until its databases are back.
    """
    pg_status, mongo_status = await asyncio.gather(
        _check("postgres", postgres.ping),
        _check("mongo", mongo.ping),
    )
    checks = {"postgres": pg_status, "mongo": mongo_status}
    is_ready = all(status == "ok" for status in checks.values())
    return JSONResponse(
        status_code=200 if is_ready else 503,
        content={"status": "ready" if is_ready else "not ready", "checks": checks},
    )


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


@app.post("/predict")
def predict(symbol: str = DEFAULT_SYMBOL):
    """Forecast the close of the next candle, from the latest candle in Mongo.

    POST because it writes: the forecast is stored (upsert, one per target
    candle) so /predictions can chart predicted vs actual. The streamer calls
    this after each closed candle; readers use GET /predictions. Without a
    trained model this returns 503; /ready is not affected, because /charts
    and /predictions still work.
    """
    try:
        result = predict_next_close_detailed(symbol=symbol)
    except ModelUnavailable as e:
        print(f"/predict: {e}", flush=True)       # details (bucket, path) to the log only
        raise HTTPException(status_code=503, detail="No trained model is available yet.")
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
