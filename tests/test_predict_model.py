"""Tests for src/models/predict_model.py: the forecast from the newest stored candle.

MongoDB and the model are replaced by small fakes, so no database is needed.
The stored candles have the real shape: built by parse_tick(), the function the
streamer uses, plus the _id MongoDB adds.
"""
from datetime import timedelta

import pytest

import src.models.predict_model as predict_model
from src.collection.stream_live import parse_tick
from src.features.build_features import FEATURE_COLUMNS


class FakeCursor(list):
    """What find() returns: records the .sort(...).limit(...) arguments.

    It does not reorder anything, so the tests check the arguments: asking
    for the wrong order would forecast from the oldest candle.
    """

    def __init__(self, docs, calls):
        super().__init__(docs)
        self.calls = calls

    def sort(self, key, direction):
        self.calls["sort"] = (key, direction)
        return self

    def limit(self, n):
        self.calls["limit"] = n
        return self


class FakeCollection:
    def __init__(self, docs):
        self.docs = docs
        self.calls = {}

    def find(self, query):
        self.calls["find"] = query
        return FakeCursor(self.docs, self.calls)


class FakeModel:
    """Records the features it was given and always forecasts 123.0."""

    def __init__(self):
        self.X = None

    def predict(self, X):
        self.X = X
        return [123.0]


def stored_candle(interval="1m"):
    k = {"s": "BTCUSDT", "t": 1_793_000_000_000, "T": 1_793_000_059_999, "i": interval,
         "o": "100.0", "h": "110.0", "l": "90.0", "c": "105.0", "v": "12.5", "n": 42,
         "x": True}
    return {"_id": "65f0c0ffee", **parse_tick(k)}


@pytest.fixture
def fakes(monkeypatch):
    """fakes(docs) -> (collection, model), both installed in predict_model."""
    def install(docs):
        collection, model = FakeCollection(docs), FakeModel()
        monkeypatch.setattr(predict_model, "get_collection", lambda name: collection)
        monkeypatch.setattr(predict_model, "load_model", lambda: model)
        return collection, model
    return install


def test_the_newest_candle_of_the_symbol_is_used(fakes):
    collection, _ = fakes([stored_candle()])
    predict_model.predict_next_close_detailed(symbol="BTCUSDT")
    assert collection.calls == {"find": {"symbol": "BTCUSDT"},
                                "sort": ("kline_start_time", -1),     # newest first
                                "limit": 1}


def test_the_model_gets_the_training_features_in_order(fakes):
    _, model = fakes([stored_candle()])
    result = predict_model.predict_next_close_detailed(symbol="BTCUSDT")
    assert list(model.X.columns) == FEATURE_COLUMNS      # not _id, symbol or the times
    assert (model.X.dtypes == "float64").all()
    assert model.X.iloc[0].tolist() == [100.0, 110.0, 90.0, 105.0, 12.5, 42.0]
    assert result["predicted_close"] == 123.0
    assert isinstance(result["predicted_close"], float)


@pytest.mark.parametrize("interval, minutes", [("1m", 1), ("5m", 5), ("1h", 60)])
def test_the_forecast_is_for_the_next_candle(fakes, interval, minutes):
    candle = stored_candle(interval)
    fakes([candle])
    result = predict_model.predict_next_close_detailed(symbol="BTCUSDT")
    assert result["source_kline_start_time"] == candle["kline_start_time"]
    # The key under which the forecast is stored and joined with the real close.
    assert result["target_kline_start_time"] == candle["kline_start_time"] + timedelta(minutes=minutes)


def test_no_candle_yet_raises_its_own_error(fakes):
    fakes([])
    with pytest.raises(predict_model.NoCandlesYet, match="BTCUSDT"):
        predict_model.predict_next_close_detailed(symbol="BTCUSDT")
