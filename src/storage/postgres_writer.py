from sqlalchemy import text
from sqlalchemy.dialects.postgresql import insert
from src.storage.postgres import get_engine
from src.params.constants import POSTGRES_TABLE


def get_last_close_ms(symbol, table=POSTGRES_TABLE):
    """Return the latest close_time (ms epoch) for a symbol, or None if empty."""
    sql = text(
        f"SELECT (EXTRACT(EPOCH FROM MAX(close_time)) * 1000)::BIGINT "
        f"FROM {table} WHERE symbol = :symbol"
    )
    with get_engine().connect() as conn:
        result = conn.execute(sql, {"symbol": symbol}).scalar()
    return int(result) if result is not None else None


def save_to_postgres(df, table=POSTGRES_TABLE, conflict_keys=("symbol", "open_time")):
    def upsert_nothing(tbl, conn, keys, data_iter):
        rows = [dict(zip(keys, r)) for r in data_iter]
        stmt = insert(tbl.table).values(rows).on_conflict_do_nothing(
            index_elements=list(conflict_keys)
        )
        conn.execute(stmt)

    df.to_sql(table, get_engine(), if_exists="append", index=False, method=upsert_nothing)
