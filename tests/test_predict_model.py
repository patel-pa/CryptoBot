"""Tests for src/models/predict_model.py: the forecast from the newest stored candle.

MongoDB and the model are replaced by small fakes, so no database is needed.
"""
import pytest

import src.models.predict_model as predict_model


class FakeCursor(list):
    """What find() returns: supports the .sort(...).limit(...) chain."""

    def sort(self, key, direction):
        return self

    def limit(self, n):
        return self


class FakeCollection:
    def __init__(self, docs):
        self.docs = docs

    def find(self, query):
        return FakeCursor(self.docs)


def test_no_candle_yet_raises_its_own_error(monkeypatch):
    monkeypatch.setattr(predict_model, "load_model", lambda: object())
    monkeypatch.setattr(predict_model, "get_collection", lambda name: FakeCollection([]))
    with pytest.raises(predict_model.NoCandlesYet, match="BTCUSDT"):
        predict_model.predict_next_close_detailed(symbol="BTCUSDT")
