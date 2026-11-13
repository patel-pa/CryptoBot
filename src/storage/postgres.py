from functools import lru_cache
from pathlib import Path

from sqlalchemy import create_engine, text
from sqlalchemy.exc import OperationalError

from src.config import postgres_settings
from src.utils.retry import retry

SCHEMA_FILE = Path(__file__).parent / "schema.sql"

# Any fixed number, the same in every process: the ID of the lock that create_schema()
# holds while it runs (nothing else in this project uses advisory locks).
SCHEMA_LOCK_ID = 2026_1112


@lru_cache(maxsize=1)
def get_engine():
    """Shared SQLAlchemy engine, created on first use (not at import time).

    Importing this module therefore never needs the Postgres env vars; only
    code that actually talks to Postgres does. Settings come from src.config.
    """
    return create_engine(
        postgres_settings().url(),
        # Check a pooled connection before reusing it, so one dropped while idle
        # (DB restart, failover) is replaced quietly instead of failing a query.
        pool_pre_ping=True,
        # Give up on a hung connection attempt (e.g. a firewall that drops
        # packets) after 10 s, so a retry can happen instead of waiting forever.
        connect_args={"connect_timeout": 10},
    )


def ping():
    """Raise OperationalError unless Postgres answers a trivial query."""
    with get_engine().connect() as conn:
        conn.execute(text("SELECT 1"))


def wait_for_postgres(attempts=20, base_delay=1.0, max_delay=10.0):
    """Block until Postgres accepts connections; raise after `attempts` tries.

    Entry points call this first. Kubernetes has no Compose `depends_on`: pods
    start in any order, so each process waits for the databases it needs
    (about 3 minutes with the defaults). Only connection errors are retried;
    a missing env var fails immediately.
    """
    retry(ping, attempts=attempts, base_delay=base_delay, max_delay=max_delay,
          exceptions=(OperationalError,), what="Postgres connection")
    print("✓ Postgres reachable", flush=True)


def create_schema():
    """Create the tables and indexes of schema.sql that don't exist yet (safe to repeat).

    Called by init-db AND by every backfill, so the ingest and retrain jobs work even
    when they start before init-db has finished (Kubernetes starts them in any order).
    Two `CREATE TABLE IF NOT EXISTS` at the same moment can still fail in Postgres
    (duplicate key in its catalog), so each caller first takes an advisory lock: a
    second caller waits until the first has committed, then finds everything there.
    Needs the table's owner (the master user today): Postgres checks ownership for
    CREATE INDEX even when the index already exists.
    """
    sql = SCHEMA_FILE.read_text(encoding="utf-8")
    with get_engine().begin() as conn:      # begin() = auto commit/rollback
        # Held until this transaction ends (commit or rollback), never longer.
        conn.execute(text("SELECT pg_advisory_xact_lock(:id)"), {"id": SCHEMA_LOCK_ID})
        conn.exec_driver_sql(sql)            # raw psycopg2 → allows multiple statements
