"""Tests for GET /metrics and the request metrics (src/api/metrics.py).

Requests go through the real app, middleware included. A small helper plays
the web server (ASGI is the interface between a Python web app and its
server), so no HTTP client library is needed.
"""
import asyncio

import pytest
from prometheus_client import REGISTRY

import src.api.main as api
from src.models.model_store import ModelUnavailable


def request(method, path):
    """Send one HTTP request to the app; return (status, headers, body)."""
    scope = {
        "type": "http", "method": method, "path": path, "raw_path": path.encode(),
        "query_string": b"", "headers": [], "http_version": "1.1", "scheme": "http",
        "server": ("test", 80), "client": ("test", 1234), "root_path": "",
    }
    sent = []

    async def receive():
        return {"type": "http.request", "body": b"", "more_body": False}

    async def send(message):
        sent.append(message)

    asyncio.run(api.app(scope, receive, send))
    start = next(m for m in sent if m["type"] == "http.response.start")
    body = b"".join(m.get("body", b"") for m in sent if m["type"] == "http.response.body")
    return start["status"], dict(start["headers"]), body


def count(method, route, status):
    """How often a request was counted so far (the registry lives for the whole test run)."""
    labels = {"method": method, "route": route, "status": str(status)}
    return REGISTRY.get_sample_value("cryptobot_http_requests_total", labels) or 0.0


def test_metrics_endpoint_serves_prometheus_text():
    status, headers, body = request("GET", "/metrics")
    assert status == 200
    assert headers[b"content-type"].startswith(b"text/plain")
    text = body.decode()
    assert "cryptobot_http_requests_total" in text
    assert "cryptobot_http_request_duration_seconds" in text
    assert "python_info" in text                       # the library's standard metrics


def test_a_request_is_counted_and_timed_under_its_route():
    timed = {"method": "GET", "route": "/health"}
    before = count("GET", "/health", 200)
    timed_before = REGISTRY.get_sample_value(
        "cryptobot_http_request_duration_seconds_count", timed) or 0.0
    assert request("GET", "/health")[0] == 200
    assert count("GET", "/health", 200) == before + 1
    assert REGISTRY.get_sample_value(
        "cryptobot_http_request_duration_seconds_count", timed) == timed_before + 1


def test_unknown_paths_share_one_label():
    before = count("GET", "unmatched", 404)
    assert request("GET", "/no-such-page-1")[0] == 404
    assert request("GET", "/no-such-page-2")[0] == 404
    assert count("GET", "unmatched", 404) == before + 2
    assert count("GET", "/no-such-page-1", 404) == 0   # the raw path never becomes a label


def test_predict_without_a_model_is_counted_as_503(monkeypatch):
    def no_model(symbol):
        raise ModelUnavailable("no model yet")

    monkeypatch.setattr(api, "predict_next_close_detailed", no_model)
    before = count("POST", "/predict", 503)
    assert request("POST", "/predict")[0] == 503
    assert count("POST", "/predict", 503) == before + 1


def test_a_crash_is_counted_as_500(monkeypatch):
    def crash(symbol):
        raise RuntimeError("database gone")

    monkeypatch.setattr(api, "predict_next_close_detailed", crash)
    before = count("POST", "/predict", 500)
    with pytest.raises(RuntimeError):     # the server answers 500, then re-raises it for its log
        request("POST", "/predict")
    assert count("POST", "/predict", 500) == before + 1
