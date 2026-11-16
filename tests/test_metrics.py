"""Tests for GET /metrics and the request metrics (src/api/metrics.py).

Requests go through the real app, middleware included (tests/asgi.py).
"""
import pytest
from prometheus_client import REGISTRY

import src.api.main as api
from src.models.model_store import ModelUnavailable
from src.models.predict_model import NoCandlesYet
from tests.asgi import request


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


def test_predict_before_the_first_candle_is_counted_as_404(monkeypatch):
    def no_candle(symbol):
        raise NoCandlesYet("no closed candle stored yet")

    monkeypatch.setattr(api, "predict_next_close_detailed", no_candle)
    before = count("POST", "/predict", 404)
    assert request("POST", "/predict")[0] == 404
    assert count("POST", "/predict", 404) == before + 1


def test_a_model_error_is_counted_as_500(monkeypatch):
    def broken_input(symbol):
        raise ValueError("Input X contains NaN.")

    monkeypatch.setattr(api, "predict_next_close_detailed", broken_input)
    before = count("POST", "/predict", 500)
    with pytest.raises(ValueError):
        request("POST", "/predict")
    assert count("POST", "/predict", 500) == before + 1
