import pandas as pd

from src.features.build_features import FEATURE_COLUMNS, make_features, make_target


def _sample_df():
    return pd.DataFrame({
        "open": [1, 2, 3],
        "high": [2, 3, 4],
        "low": [0, 1, 2],
        "close": [1.5, 2.5, 3.5],
        "volume": [10, 20, 30],
        "number_of_trades": [5, 6, 7],
        "extra": ["a", "b", "c"],     # should be ignored by make_features
    })


def test_make_features_selects_only_feature_columns():
    X = make_features(_sample_df())
    assert list(X.columns) == FEATURE_COLUMNS


def test_make_features_are_all_float():
    X = make_features(_sample_df())
    assert (X.dtypes == "float64").all()


def test_make_target_is_next_close():
    y = make_target(_sample_df())
    # target = close shifted up by one; the last row's "next close" is unknown
    assert y.iloc[0] == 2.5
    assert y.iloc[1] == 3.5
    assert pd.isna(y.iloc[2])
