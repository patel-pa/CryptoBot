from pathlib import Path
from src.storage.postgres import get_engine, wait_for_postgres
from src.storage.mongo import get_collection, wait_for_mongo
from src.params.constants import MONGO_COLLECTION, PREDICTIONS_COLLECTION

SCHEMA_FILE = Path(__file__).parent / "schema.sql"


def init_postgres():
    sql = SCHEMA_FILE.read_text(encoding="utf-8")
    with get_engine().begin() as conn:          # begin() = auto commit/rollback
        conn.exec_driver_sql(sql)         # raw psycopg2 → allows multiple statements
    print("✓ Postgres tables ready")


def init_mongo():
    collection = get_collection(MONGO_COLLECTION)
    # Unique index = idempotency: a re-inserted closed candle is rejected,
    # mirroring the (symbol, open_time) primary key in Postgres.
    collection.create_index(
        [("symbol", 1), ("kline_start_time", -1)],
        unique=True,
    )
    print(f"✓ Mongo index ready on '{MONGO_COLLECTION}'")

    # One stored forecast per predicted candle: unique on (symbol, target time).
    predictions = get_collection(PREDICTIONS_COLLECTION)
    predictions.create_index(
        [("symbol", 1), ("target_kline_start_time", -1)],
        unique=True,
    )
    print(f"✓ Mongo index ready on '{PREDICTIONS_COLLECTION}'")


def init_db():
    # Kubernetes starts pods in any order (no Compose `depends_on`), so wait
    # for both databases before touching them.
    wait_for_postgres()
    wait_for_mongo()
    init_postgres()
    init_mongo()


if __name__ == "__main__":
    init_db()
