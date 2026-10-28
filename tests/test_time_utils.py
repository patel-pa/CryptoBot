import pandas as pd

from src.utils.time_utils import ms_to_timestamp, to_ms


def test_to_ms_epoch():
    # 1970-01-01T00:00 UTC is exactly 0 ms since the epoch
    assert to_ms("01.01.1970T00:00") == 0


def test_to_ms_one_minute_after_epoch():
    assert to_ms("01.01.1970T00:01") == 60_000


def test_ms_to_timestamp_scalar_roundtrip():
    ms = to_ms("01.01.2026T00:00")
    ts = ms_to_timestamp(ms)
    assert isinstance(ts, pd.Timestamp)
    assert ts == pd.Timestamp("2026-01-01 00:00:00")


def test_ms_to_timestamp_series():
    out = ms_to_timestamp(pd.Series([0, 60_000]))
    assert list(out) == [
        pd.Timestamp("1970-01-01 00:00:00"),
        pd.Timestamp("1970-01-01 00:01:00"),
    ]
