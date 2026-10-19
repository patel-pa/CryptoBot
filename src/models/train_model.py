from pathlib import Path

import joblib
import pandas as pd
from sklearn.linear_model import LinearRegression
from sqlalchemy import text

from src.storage.postgres import get_engine, wait_for_postgres
from src.features.build_features import make_features, make_target
from src.params.constants import (
    SUPPORTED_SYMBOLS,
    POSTGRES_TABLE,
    MODEL_FILENAME,
)

# Save the trained artifact to the repo's models/ directory
MODEL_PATH = Path(__file__).resolve().parents[2] / "models" / MODEL_FILENAME
SYMBOL = SUPPORTED_SYMBOLS[0].value


def train():
    wait_for_postgres()                     # pods start in any order on Kubernetes

    # 1. Load historical candles (oldest -> newest) from Postgres
    df = pd.read_sql(
        text(f"SELECT * FROM {POSTGRES_TABLE} WHERE symbol = :s ORDER BY open_time"),
        get_engine(),
        params={"s": SYMBOL},
    )

    # 2. Build inputs (X) and target = next candle's close (y)
    X = make_features(df)
    y = make_target(df)

    # 3. Drop the last row — its "next close" is unknown (NaN)
    X = X[:-1]
    y = y[:-1]

    # 4. Train a simple regression (accuracy is not the goal here)
    model = LinearRegression()
    model.fit(X, y)

    # 5. Save the trained model to disk
    MODEL_PATH.parent.mkdir(exist_ok=True)
    joblib.dump(model, MODEL_PATH)
    print(f"Saved model to {MODEL_PATH} (trained on {len(X)} rows)")


if __name__ == "__main__":
    train()
