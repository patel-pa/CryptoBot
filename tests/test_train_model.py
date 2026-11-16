"""Tests for src/models/train_model.py: which rows the model learns from.

PostgreSQL is replaced by a small table and the model storage by a recorder.
"""
from decimal import Decimal

import pandas as pd
import pytest

import src.models.train_model as train_model

ROWS = 50


@pytest.fixture
def saved(monkeypatch):
    """Train on ROWS candles whose close rises by exactly 1 each minute; return the saved models."""
    table = pd.DataFrame({
        "open_time": pd.date_range("2026-10-01", periods=ROWS, freq="min"),
        # PostgreSQL NUMERIC columns arrive as Decimal values.
        "open": [Decimal(99 + i) for i in range(ROWS)],
        "high": [Decimal(101 + i) for i in range(ROWS)],
        "low": [Decimal(98 + i) for i in range(ROWS)],
        "close": [Decimal(100 + i) for i in range(ROWS)],
        "volume": [Decimal("12.5")] * ROWS,
        "number_of_trades": [40] * ROWS,
    })
    models = []
    monkeypatch.setattr(train_model, "wait_for_postgres", lambda: None)
    monkeypatch.setattr(train_model, "get_engine", lambda: None)
    monkeypatch.setattr(train_model.pd, "read_sql", lambda query, engine, params: table)
    monkeypatch.setattr(train_model, "save_model", lambda model: models.append(model) or "memory")
    train_model.train()
    return models


def test_train_saves_one_model_on_the_six_features(saved):
    assert len(saved) == 1
    assert saved[0].n_features_in_ == 6


def test_the_model_learns_the_next_close(saved):
    # Each row's target is the NEXT row's close; the last row (no next close yet) is left
    # out, otherwise its missing target would stop the training. For this series the
    # next close is always the current close + 1.
    last = pd.DataFrame([[148.0, 150.0, 147.0, 149.0, 12.5, 40.0]],
                        columns=["open", "high", "low", "close", "volume", "number_of_trades"])
    assert saved[0].predict(last)[0] == pytest.approx(150.0)
