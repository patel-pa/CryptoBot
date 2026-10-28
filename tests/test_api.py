"""Tests for /health (liveness), /ready (readiness) and /predict, in
src/api/main.py.

The endpoint functions are called directly, so no HTTP client library is
needed; the database pings and the prediction are replaced by fakes.
"""
import asyncio
import json
import time
from datetime import datetime

import pytest
from fastapi import HTTPException
from pymongo.errors import ServerSelectionTimeoutError
from sqlalchemy.exc import OperationalError

import src.api.main as api
from src.models.model_store import ModelUnavailable
from src.storage import mongo, postgres


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


def call_ready():
    """Run the /ready endpoint; return (status code, JSON body, seconds it took).

    The time is measured inside the event loop: when asyncio.run() closes the
    loop it waits for any ping thread still sleeping, which is not part of
    the endpoint's response time.
    """
    async def timed():
        start = time.monotonic()
        response = await api.ready()
        return response, time.monotonic() - start

    response, elapsed = asyncio.run(timed())
    return response.status_code, json.loads(response.body), elapsed


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
    status, body, _ = call_ready()
    assert status == 200
    assert body == {"status": "ready", "checks": {"postgres": "ok", "mongo": "ok"}}


def test_not_ready_when_postgres_is_down(pings):
    pings(postgres_ping=pg_refused)
    status, body, _ = call_ready()
    assert status == 503
    assert body == {"status": "not ready", "checks": {"postgres": "unavailable", "mongo": "ok"}}


def test_not_ready_when_mongo_is_down(pings):
    pings(mongo_ping=mongo_no_server)
    status, body, _ = call_ready()
    assert status == 503
    assert body["checks"] == {"postgres": "ok", "mongo": "unavailable"}


def test_error_details_are_not_exposed(pings):
    pings(postgres_ping=pg_refused, mongo_ping=mongo_no_server)
    _, body, _ = call_ready()
    text = json.dumps(body)
    assert "db-internal" not in text
    assert "mongo-internal" not in text


def test_slow_database_reports_timeout_at_the_limit(pings, monkeypatch):
    monkeypatch.setattr(api, "READY_TIMEOUT_SECONDS", 0.2)
    pings(postgres_ping=lambda: time.sleep(1.5))
    status, body, elapsed = call_ready()
    assert status == 503
    assert body["checks"] == {"postgres": "timeout", "mongo": "ok"}
    assert elapsed < 1.0               # answered at the 0.2 s limit, not after 1.5 s


def test_checks_run_in_parallel(pings):
    pings(postgres_ping=lambda: time.sleep(0.5), mongo_ping=lambda: time.sleep(0.5))
    status, _, elapsed = call_ready()
    assert status == 200
    assert elapsed < 0.9               # one after the other would take 1.0 s


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
