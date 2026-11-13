import pandas as pd

from src.params.constants import BINANCE_KLINES_COLUMNS
from src.utils.time_utils import ms_to_timestamp


def raw_to_dataframe(data):
    df = pd.DataFrame(data, columns=BINANCE_KLINES_COLUMNS)

    df["open_time"] = ms_to_timestamp(df["open_time"])
    df["close_time"] = ms_to_timestamp(df["close_time"])

    float_cols = [
        "open", "high", "low", "close", "volume",
        "quote_asset_volume", "taker_buy_base_volume", "taker_buy_quote_volume"
    ]
    df[float_cols] = df[float_cols].astype(float)
    df["number_of_trades"] = df["number_of_trades"].astype(int)

    return df
