"""Tests for the backfill in src/collection/fetch_historical.py.

Binance, Postgres and the pause between pages are replaced by a fake, so the
tests need no network and no database. (That importing the module runs no
backfill is checked in test_config.py.)
"""
import pytest

import src.collection.fetch_historical as fh
from src.utils.time_utils import to_ms

MINUTE = 60_000                             # ms
NOW = 10 * fh.PAGE_SIZE * MINUTE            # far enough ahead for several pages


def kline(open_ms):
    """One raw Binance kline row (12 fields), one minute long."""
    return [open_ms, "100", "110", "90", "105", "2.5", open_ms + MINUTE - 1,
            "250", 7, "1.0", "100", "0"]


def page(first_open_ms, n):
    return [kline(first_open_ms + i * MINUTE) for i in range(n)]


class FakeBackend:
    """Stand-in for Binance, Postgres and sleep(); records what the backfill does."""

    def __init__(self):
        self.last_close_ms = None   # what get_last_close_ms() returns (None = empty table)
        self.pages = []             # answers to the next Binance requests; then []
        self.requests = []          # keyword arguments of each Binance request
        self.saved = []             # DataFrames given to save_to_postgres()
        self.pauses = 0

    def get_last_close_ms(self, symbol):
        return self.last_close_ms

    def get_binance_data(self, **kwargs):
        self.requests.append(kwargs)
        return self.pages.pop(0) if self.pages else []

    def sleep(self, seconds):
        self.pauses += 1


@pytest.fixture
def backend(monkeypatch):
    b = FakeBackend()
    monkeypatch.setattr(fh, "wait_for_postgres", lambda: None)
    monkeypatch.setattr(fh, "get_last_close_ms", b.get_last_close_ms)
    monkeypatch.setattr(fh, "get_binance_data", b.get_binance_data)
    monkeypatch.setattr(fh, "save_to_postgres", b.saved.append)
    monkeypatch.setattr(fh, "sleep", b.sleep)
    return b


def test_resumes_one_ms_after_the_last_stored_candle(backend):
    backend.last_close_ms = 5 * MINUTE - 1
    fh.backfill(now_ms=NOW)
    assert backend.requests[0]["start_time"] == 5 * MINUTE
    assert backend.requests[0]["end_time"] == NOW


def test_empty_database_starts_at_the_configured_date(backend, monkeypatch):
    monkeypatch.setenv("HISTORICAL_START_DATE", "15.10.2026T00:00")   # not the default (01.10)
    fh.backfill(now_ms=to_ms("16.10.2026T00:00"))
    assert backend.requests[0]["start_time"] == to_ms("15.10.2026T00:00")


def test_saves_each_page_and_continues_after_its_last_candle(backend):
    backend.last_close_ms = MINUTE - 1
    backend.pages = [page(MINUTE, fh.PAGE_SIZE), page((fh.PAGE_SIZE + 1) * MINUTE, 3)]
    assert fh.backfill(now_ms=NOW) == fh.PAGE_SIZE + 3
    assert len(backend.requests) == 2                  # stopped after the partial page
    assert backend.requests[1]["start_time"] == (fh.PAGE_SIZE + 1) * MINUTE
    assert [len(df) for df in backend.saved] == [fh.PAGE_SIZE, 3]
    assert list(backend.saved[0].columns) == fh.DB_COLUMNS
    assert (backend.saved[0]["symbol"] == "BTCUSDT").all()
    assert backend.pauses == 1                         # one pause between the two requests


@pytest.mark.parametrize("now", [
    10 * MINUTE + 30_000,                              # 30 s into the candle opened at minute 10
    11 * MINUTE - 1,                                   # its last millisecond: trades can still land
], ids=["mid-minute", "last-millisecond"])
def test_the_candle_still_open_is_not_stored(backend, now):
    """Binance also returns the minute that is still open. Stored, its partial prices
    would stay forever: the next run starts after it, and inserts skip existing rows."""
    backend.last_close_ms = 8 * MINUTE - 1
    backend.pages = [page(8 * MINUTE, 3)]              # minutes 8 and 9 (closed), 10 (open)
    assert fh.backfill(now_ms=now) == 2
    assert len(backend.saved[0]) == 2
    assert len(backend.requests) == 1


def test_full_page_ending_with_the_open_candle_stops(backend):
    now = fh.PAGE_SIZE * MINUTE + 30_000               # the page's last candle is still open
    backend.last_close_ms = MINUTE - 1
    backend.pages = [page(MINUTE, fh.PAGE_SIZE)]
    assert fh.backfill(now_ms=now) == fh.PAGE_SIZE - 1
    assert len(backend.requests) == 1                  # no extra request for the open minute


def test_up_to_date_database_fetches_nothing(backend, capsys):
    backend.last_close_ms = NOW
    assert fh.backfill(now_ms=NOW) == 0
    assert backend.requests == []
    assert backend.saved == []
    assert "already up to date" in capsys.readouterr().out


def test_empty_answer_from_binance_stops(backend):
    backend.last_close_ms = MINUTE - 1                 # backend.pages is empty
    assert fh.backfill(now_ms=NOW) == 0
    assert len(backend.requests) == 1
    assert backend.saved == []
