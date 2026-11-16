"""Tests for the endpoints in src/api/main.py: /health (liveness), /ready
(readiness), /predict, /predictions and /charts.

Most endpoint functions are called directly; the input checks are tested
through the whole app (tests/asgi.py). No HTTP client library is needed; the
databases and the prediction are replaced by fakes.
"""
import asyncio
import json
import threading
from datetime import datetime, timedelta

import pandas as pd
import pytest
from fastapi import HTTPException
from pymongo.errors import ServerSelectionTimeoutError
from sqlalchemy.exc import OperationalError

import src.api.main as api
from src.models.model_store import ModelUnavailable
from src.models.predict_model import NoCandlesYet
from src.storage import mongo, postgres
from tests.asgi import request


def ok():
    """A database ping that succeeds."""


def pg_refused():
    raise OperationalError("SELECT 1", {}, Exception("could not connect to db-internal.example"))


def mongo_no_server():
    raise ServerSelectionTimeoutError("no servers available at mongo-internal.example")


@pytest.fixture
def pings(monkeypatch):
    """Replace both database pings: pings(postgres_ping=..., mongo_ping=...)."""
    def set_pings(postgres_ping=ok, mongo_ping=ok):
        monkeypatch.setattr(postgres, "ping", postgres_ping)
        monkeypatch.setattr(mongo, "ping", mongo_ping)
    return set_pings


def call_ready(after=None):
    """Run the /ready endpoint; return (status code, JSON body).

    `after` runs as soon as the endpoint has answered, still inside the event
    loop: asyncio.run() waits for every ping thread before it returns, so a
    blocked fake ping must be released there.
    """
    async def run():
        response = await api.ready()
        if after:
            after()
        return response

    response = asyncio.run(run())
    return response.status_code, json.loads(response.body)


def test_routes_are_registered():
    paths = {route.path for route in api.app.routes}
    assert {"/health", "/ready"} <= paths


def test_health_makes_no_database_calls(pings):
    calls = []
    pings(postgres_ping=lambda: calls.append("pg"), mongo_ping=lambda: calls.append("mongo"))
    assert api.health() == {"status": "ok"}
    assert calls == []


def test_ready_when_both_databases_answer(pings):
    pings()
    status, body = call_ready()
    assert status == 200
    assert body == {"status": "ready", "checks": {"postgres": "ok", "mongo": "ok"}}


def test_not_ready_when_postgres_is_down(pings):
    pings(postgres_ping=pg_refused)
    status, body = call_ready()
    assert status == 503
    assert body == {"status": "not ready", "checks": {"postgres": "unavailable", "mongo": "ok"}}


def test_not_ready_when_mongo_is_down(pings):
    pings(mongo_ping=mongo_no_server)
    status, body = call_ready()
    assert status == 503
    assert body["checks"] == {"postgres": "ok", "mongo": "unavailable"}


def test_error_details_are_not_exposed(pings):
    pings(postgres_ping=pg_refused, mongo_ping=mongo_no_server)
    _, body = call_ready()
    text = json.dumps(body)
    assert "db-internal" not in text
    assert "mongo-internal" not in text


def test_slow_database_reports_timeout_at_the_limit(pings, monkeypatch):
    monkeypatch.setattr(api, "READY_TIMEOUT_SECONDS", 0.2)
    release = threading.Event()
    pings(postgres_ping=lambda: release.wait(10))      # answers only once released
    # Released only after /ready has answered: without the time limit, /ready would
    # wait the full 10 s and then report "ok".
    status, body = call_ready(after=release.set)
    assert status == 503
    assert body["checks"] == {"postgres": "timeout", "mongo": "ok"}


def test_checks_run_in_parallel(pings, monkeypatch):
    monkeypatch.setattr(api, "READY_TIMEOUT_SECONDS", 10)
    # Each ping waits until both are running. One after the other, the first
    # would wait alone, give up after 5 s, and the database would count as down.
    both_running = threading.Barrier(2, timeout=5)
    pings(postgres_ping=both_running.wait, mongo_ping=both_running.wait)
    status, _ = call_ready()
    assert status == 200


def test_predict_accepts_post_only():
    methods = {method for route in api.app.routes if getattr(route, "path", None) == "/predict"
               for method in route.methods}
    assert methods == {"POST"}          # it writes; GET /predict answers 405 Method Not Allowed


def test_predict_stores_and_returns_the_forecast(monkeypatch):
    result = {"symbol": "BTCUSDT",
              "source_kline_start_time": datetime(2026, 10, 27, 14, 30),
              "target_kline_start_time": datetime(2026, 10, 27, 14, 31),
              "predicted_close": 67000.5}
    saved = []
    monkeypatch.setattr(api, "predict_next_close_detailed", lambda symbol: result)
    monkeypatch.setattr(api, "save_prediction", saved.append)
    assert api.predict() == {"symbol": "BTCUSDT", "predicted_next_close": 67000.5,
                             "target_time": datetime(2026, 10, 27, 14, 31)}
    assert saved == [result]


def test_predict_without_a_model_is_503_without_details(monkeypatch):
    def no_model(symbol):
        raise ModelUnavailable("no model at s3://secret-bucket/dev/model.pkl")
    monkeypatch.setattr(api, "predict_next_close_detailed", no_model)
    with pytest.raises(HTTPException) as exc:
        api.predict()
    assert exc.value.status_code == 503
    assert "secret-bucket" not in exc.value.detail


def test_predict_before_the_first_candle_is_404_with_a_fixed_message(monkeypatch):
    def no_candle(symbol):
        raise NoCandlesYet("no closed candle stored yet for BTCUSDT (mongo-internal.example)")
    monkeypatch.setattr(api, "predict_next_close_detailed", no_candle)
    with pytest.raises(HTTPException) as exc:
        api.predict()
    assert exc.value.status_code == 404
    assert exc.value.detail == "No closed candle is stored yet."


def test_a_model_error_is_not_turned_into_404(monkeypatch):
    def wrong_features(symbol):        # e.g. an older model after a feature change
        raise ValueError("X has 6 features, but LinearRegression is expecting 5 features")
    monkeypatch.setattr(api, "predict_next_close_detailed", wrong_features)
    with pytest.raises(ValueError, match="6 features"):    # the server turns it into a 500
        api.predict()


@pytest.fixture
def limits_asked(monkeypatch):
    """Fake databases for /charts and /predictions: no rows; each limit is recorded."""
    asked = []

    def read_sql(query, engine, params):
        asked.append(params["n"])
        return pd.DataFrame()

    class NoForecasts:
        def find(self, query):
            return self

        def sort(self, key, direction):
            return self

        def limit(self, n):
            asked.append(n)
            return []

    monkeypatch.setattr(api, "get_engine", lambda: None)
    monkeypatch.setattr(api.pd, "read_sql", read_sql)
    monkeypatch.setattr(api, "get_collection", lambda name: NoForecasts())
    return asked


@pytest.mark.parametrize("path, query", [
    ("/charts", "limit=-1"),            # Postgres would fail: a 500 before the bounds
    ("/charts", "limit=0"),
    ("/charts", "limit=1001"),
    ("/predictions", "limit=0"),        # MongoDB reads limit(0) as "no limit"
    ("/predictions", "limit=1441"),
])
def test_a_limit_out_of_range_is_422_before_any_database_call(limits_asked, path, query):
    assert request("GET", path, query)[0] == 422
    assert limits_asked == []


@pytest.mark.parametrize("path, query, limit", [
    ("/charts", "limit=1", 1),
    ("/charts", "limit=1000", 1000),
    ("/predictions", "limit=1", 1),
    ("/predictions", "limit=1440", 1440),
])
def test_a_limit_at_the_bounds_reaches_the_database(limits_asked, path, query, limit):
    assert request("GET", path, query)[0] == 200
    assert limits_asked == [limit]


# ------------------------------------------------- /predictions and /charts

class Cursor(list):
    """What find() returns: sort and limit really sort and cut, as in MongoDB."""

    def sort(self, key, direction):
        return Cursor(sorted(self, key=lambda d: d[key], reverse=direction == -1))

    def limit(self, n):
        return Cursor(self[:n])


class Collection:
    """A MongoDB collection in memory: find() with equality and {"$in": [...]} filters."""

    def __init__(self, docs):
        self.docs = docs

    def find(self, query, projection=None):
        def matches(doc):
            return all(doc.get(field) in want["$in"] if isinstance(want, dict) else doc.get(field) == want
                       for field, want in query.items())
        return Cursor(d for d in self.docs if matches(d))


T0 = datetime(2026, 11, 15, 16, 0)


@pytest.fixture
def stored(monkeypatch):
    """stored(forecasts, candles): the two collections /predictions reads."""
    def install(forecasts, candles):
        collections = {api.PREDICTIONS_COLLECTION: Collection(forecasts),
                       api.MONGO_COLLECTION: Collection(candles)}
        monkeypatch.setattr(api, "get_collection", lambda name: collections[name])
    return install


def forecast(minutes, predicted, symbol="BTCUSDT"):
    return {"symbol": symbol, "target_kline_start_time": T0 + timedelta(minutes=minutes),
            "predicted_close": predicted}


def test_predictions_are_oldest_first_and_joined_with_the_real_close(stored):
    stored(forecasts=[forecast(2, 102.0), forecast(0, 100.0), forecast(1, 101.0),
                      forecast(1, 9.0, symbol="ETHUSDT")],          # stored in any order
           candles=[{"symbol": "BTCUSDT", "kline_start_time": T0, "close": 99.5}])
    assert api.predictions(symbol="BTCUSDT", limit=3) == [
        {"target_time": T0, "predicted_close": 100.0, "actual_close": 99.5},
        {"target_time": T0 + timedelta(minutes=1), "predicted_close": 101.0, "actual_close": None},
        {"target_time": T0 + timedelta(minutes=2), "predicted_close": 102.0, "actual_close": None},
    ]                                    # actual_close stays None until that candle closed


def test_predictions_limit_1_is_the_newest_forecast(stored):
    # The dashboard shows rows[-1] of ?limit=1 as "the" forecast.
    stored(forecasts=[forecast(2, 102.0), forecast(0, 100.0), forecast(1, 101.0)], candles=[])
    assert [row["predicted_close"] for row in api.predictions(limit=1)] == [102.0]


def test_predictions_without_forecasts_is_an_empty_list(stored):
    stored(forecasts=[], candles=[])
    assert api.predictions() == []


def test_charts_returns_the_newest_candles_oldest_first(monkeypatch):
    asked = {}

    def read_sql(query, engine, params):           # PostgreSQL answers newest first
        asked.update(params, sql=str(query))
        return pd.DataFrame({"open_time": [T0 + timedelta(minutes=m) for m in (2, 1, 0)],
                             "close": [102.0, 101.0, 100.0]})

    monkeypatch.setattr(api, "get_engine", lambda: None)
    monkeypatch.setattr(api.pd, "read_sql", read_sql)
    rows = api.charts(symbol="BTCUSDT", limit=3)
    assert "ORDER BY open_time DESC LIMIT :n" in asked.pop("sql")   # the newest candles
    assert asked == {"s": "BTCUSDT", "n": 3}
    assert [row["close"] for row in rows] == [100.0, 101.0, 102.0]
