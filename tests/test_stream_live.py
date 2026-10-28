"""Tests for the closed-candle trigger in src/collection/stream_live.py.

MongoDB and the API are replaced by fakes, and the retry waits are recorded
instead of slept, so no database, API or network is needed.
"""
import json
import threading
from types import SimpleNamespace

import pytest
import requests
from pymongo.errors import AutoReconnect

import src.collection.stream_live as stream_live
import src.utils.retry as retry_module

API = "http://api.test:8000"
FORECAST = {"symbol": "BTCUSDT", "predicted_next_close": 106.5,
            "target_time": "1970-01-01T00:02:00"}


def kline(closed):
    """The inner 'k' object of a Binance kline message."""
    return {"s": "BTCUSDT", "t": 60_000, "T": 119_999, "i": "1m",
            "o": "100", "h": "110", "l": "90", "c": "105", "v": "2", "n": 7,
            "x": closed}


def message(closed):
    """A whole WebSocket message, as the combined stream sends it."""
    return json.dumps({"stream": "btcusdt@kline_1m", "data": {"e": "kline", "k": kline(closed)}})


def closed_candle():
    return stream_live.parse_tick(kline(closed=True))


def receive(msg):
    """on_message(), then wait until the worker thread has done the closed-candle work.

    The worker runs tasks one at a time, in order: once an empty task
    submitted after the message has run, the message's work is finished.
    """
    stream_live.on_message(None, msg)
    stream_live.closed_candle_worker.submit(lambda: None).result(timeout=5)


def api_response(status, body):
    """A real requests.Response, so raise_for_status() behaves as in production."""
    response = requests.Response()
    response.status_code = status
    response._content = json.dumps(body).encode()
    response.encoding = "utf-8"
    response.url = f"{API}/predict?symbol=BTCUSDT"
    return response


class Fakes:
    """Stand-ins for save_closed_candle() and requests.post(); records the calls."""

    def __init__(self):
        self.calls = []           # "save" / "post", in call order
        self.waits = []           # retry delays, recorded instead of slept
        self.save_errors = []     # exceptions for the next saves to raise, one per call
        self.post_results = []    # per call: an exception to raise or a Response; then 200
        self.post_url = None
        self.post_kwargs = None

    def save(self, candle):
        self.calls.append("save")
        if self.save_errors:
            raise self.save_errors.pop(0)

    def post(self, url, **kwargs):
        self.calls.append("post")
        self.post_url, self.post_kwargs = url, kwargs
        result = self.post_results.pop(0) if self.post_results else api_response(200, FORECAST)
        if isinstance(result, Exception):
            raise result
        return result


@pytest.fixture
def fakes(monkeypatch):
    f = Fakes()
    monkeypatch.setattr(stream_live, "save_closed_candle", f.save)
    monkeypatch.setattr(stream_live.requests, "post", f.post)
    monkeypatch.setattr(retry_module, "time", SimpleNamespace(sleep=f.waits.append))
    monkeypatch.setenv("API_BASE", API)
    return f


def test_closed_candle_is_saved_then_forecast(fakes, capsys):
    receive(message(closed=True))
    assert fakes.calls == ["save", "post"]       # stored first: /predict reads it from Mongo
    assert fakes.post_url == f"{API}/predict"
    assert fakes.post_kwargs == {"params": {"symbol": "BTCUSDT"},
                                 "timeout": stream_live.PREDICT_TIMEOUT}
    assert "Forecast for BTCUSDT 1970-01-01T00:02:00: 106.50" in capsys.readouterr().out


def test_open_candle_triggers_nothing(fakes):
    receive(message(closed=False))
    assert fakes.calls == []


def test_on_message_does_not_wait_for_the_closed_candle_work(monkeypatch):
    """A slow database or API must not hold up the WebSocket loop (keepalive pongs)."""
    release, finished = threading.Event(), threading.Event()

    def slow_work(candle):
        release.wait(5)
        finished.set()

    monkeypatch.setattr(stream_live, "on_candle_closed", slow_work)
    stream_live.on_message(None, message(closed=True))
    assert not finished.is_set()                 # on_message returned while the work waits
    release.set()
    assert finished.wait(5)                      # ... and the work still ran, on the worker


def test_mongo_blip_is_retried(fakes):
    fakes.save_errors = [AutoReconnect("primary stepped down")]
    stream_live.on_candle_closed(closed_candle())
    assert fakes.calls == ["save", "save", "post"]
    assert fakes.waits == [1]


def test_save_failure_skips_the_forecast_without_raising(fakes, capsys):
    fakes.save_errors = [AutoReconnect("no primary")] * 3
    stream_live.on_candle_closed(closed_candle())     # must not raise
    assert fakes.calls == ["save"] * 3                # gave up after 3 tries, no forecast
    assert fakes.waits == [1, 2]
    assert "Could not save closed candle BTCUSDT" in capsys.readouterr().out


def test_api_back_after_a_restart(fakes, capsys):
    fakes.post_results = [requests.ConnectionError("connection refused")]
    stream_live.on_candle_closed(closed_candle())
    assert fakes.calls == ["save", "post", "post"]
    assert fakes.waits == [1]
    assert "Forecast for BTCUSDT" in capsys.readouterr().out


def test_unreachable_api_is_given_up_without_raising(fakes, capsys):
    fakes.post_results = [requests.ConnectionError("connection refused")] * 3
    stream_live.on_candle_closed(closed_candle())     # must not raise
    assert fakes.calls == ["save", "post", "post", "post"]
    assert fakes.waits == [1, 2]
    assert "No forecast after BTCUSDT" in capsys.readouterr().out


def test_no_model_503_is_logged_not_retried(fakes, capsys):
    fakes.post_results = [api_response(503, {"detail": "No trained model is available yet."})]
    stream_live.on_candle_closed(closed_candle())
    assert fakes.calls == ["save", "post"]
    assert fakes.waits == []
    out = capsys.readouterr().out
    assert "API answered 503" in out
    assert "No trained model" in out


def test_slow_api_is_not_retried(fakes):
    fakes.post_results = [requests.ReadTimeout("read timed out")]
    stream_live.on_candle_closed(closed_candle())     # the API may still store it
    assert fakes.calls == ["save", "post"]
    assert fakes.waits == []
