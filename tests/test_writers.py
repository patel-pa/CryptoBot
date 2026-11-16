"""Tests for the idempotent writes: storing the same candle or forecast twice never
creates a duplicate (src/storage/mongo_writer.py, postgres_writer.py, init_db.py).

Retries rely on this: the streamer retries a failed POST /predict, and every
15-minute ingest may fetch candles that are already stored. No database is
needed: the writes are recorded and compared with the unique keys.
"""
import inspect
import re
from types import SimpleNamespace

import pytest
from sqlalchemy import Column, MetaData, Table
from sqlalchemy.dialects import postgresql

from src.params.constants import MONGO_COLLECTION, POSTGRES_TABLE, PREDICTIONS_COLLECTION
from src.storage import init_db, mongo_writer, postgres_writer
from src.storage.postgres import SCHEMA_FILE


class RecordingCollection:
    def __init__(self):
        self.updates = []        # (filter, update, upsert)
        self.indexes = []        # (keys, unique)

    def update_one(self, filter, update, upsert=False):
        self.updates.append((filter, update, upsert))

    def create_index(self, keys, unique=False):
        self.indexes.append((keys, unique))


@pytest.fixture
def collections(monkeypatch):
    """Every collection by name; init_mongo() has already created its indexes."""
    by_name = {MONGO_COLLECTION: RecordingCollection(), PREDICTIONS_COLLECTION: RecordingCollection()}
    monkeypatch.setattr(mongo_writer, "get_collection", lambda name: by_name[name])
    monkeypatch.setattr(init_db, "get_collection", lambda name: by_name[name])
    init_db.init_mongo()
    return by_name


def unique_fields(collection):
    """The field names of the collection's one unique index (the sort direction does not matter)."""
    [(keys, unique)] = collection.indexes
    assert unique is True
    return {field for field, _direction in keys}


@pytest.mark.parametrize("name, save, doc", [
    (MONGO_COLLECTION, mongo_writer.save_closed_candle,
     {"symbol": "BTCUSDT", "kline_start_time": "2026-11-15 16:00", "close": 99.5}),
    (PREDICTIONS_COLLECTION, mongo_writer.save_prediction,
     {"symbol": "BTCUSDT", "target_kline_start_time": "2026-11-15 16:01", "predicted_close": 100.0}),
])
def test_mongo_writes_are_upserts_on_the_unique_index(collections, name, save, doc):
    save(doc)
    [(filter, update, upsert)] = collections[name].updates
    assert upsert is True                                   # update in place, never insert twice
    assert set(filter) == unique_fields(collections[name])  # the same key the index guards
    assert update == {"$set": doc}


def test_postgres_insert_skips_rows_already_stored(monkeypatch):
    captured = {}

    class Frame:                    # stands in for the DataFrame: catches pandas' insert method
        def to_sql(self, name, con, if_exists, index, method):
            captured["method"] = method

    class Connection:
        def execute(self, statement):
            captured["sql"] = str(statement.compile(dialect=postgresql.dialect()))

    monkeypatch.setattr(postgres_writer, "get_engine", lambda: None)
    postgres_writer.save_to_postgres(Frame())
    table = Table(POSTGRES_TABLE, MetaData(), Column("symbol"), Column("open_time"), Column("close"))
    captured["method"](SimpleNamespace(table=table), Connection(), ["symbol", "open_time", "close"],
                       iter([("BTCUSDT", "2026-11-15 16:00", 99.5)]))
    assert "ON CONFLICT (symbol, open_time) DO NOTHING" in captured["sql"]


def test_postgres_conflict_keys_are_the_primary_key():
    primary_key = re.search(r"PRIMARY KEY \(([^)]*)\)", SCHEMA_FILE.read_text(encoding="utf-8"))
    conflict_keys = inspect.signature(postgres_writer.save_to_postgres).parameters["conflict_keys"].default
    assert [k.strip() for k in primary_key.group(1).split(",")] == list(conflict_keys)
