from datetime import UTC, datetime

import pandas as pd

from src.params.constants import DATE_INPUT_FORMAT


def to_ms(dt_str: str) -> int:
    """
    Convert a datetime string to milliseconds since Unix epoch (UTC).

    Args:
        dt_str: Datetime string in 'DD.MM.YYYYThh:mm' format, e.g. '01.01.2024T00:00'

    Returns:
        Integer milliseconds since Unix epoch.
    """
    dt = datetime.strptime(dt_str, DATE_INPUT_FORMAT).replace(tzinfo=UTC)
    return int(dt.timestamp() * 1000)


def ms_to_timestamp(ms: int | pd.Series) -> pd.Timestamp | pd.Series:
    """
    Convert milliseconds since Unix epoch to a pandas Timestamp or Series of Timestamps.

    Args:
        ms: Integer milliseconds or a pandas Series of integer milliseconds.

    Returns:
        pd.Timestamp if input is a scalar, pd.Series of Timestamps if input is a Series.
    """
    return pd.to_datetime(ms, unit="ms")

