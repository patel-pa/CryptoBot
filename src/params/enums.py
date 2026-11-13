from enum import StrEnum


class Interval(StrEnum):
    ONE_MINUTE      = "1m"
    FIVE_MINUTES    = "5m"
    FIFTEEN_MINUTES = "15m"
    ONE_HOUR        = "1h"
    ONE_DAY         = "1d"


class Symbol(StrEnum):
    BTCUSDT = "BTCUSDT"
    ETHUSDT = "ETHUSDT"
