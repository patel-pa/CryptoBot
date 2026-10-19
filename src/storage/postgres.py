from functools import lru_cache

from sqlalchemy import create_engine, text
from sqlalchemy.exc import OperationalError

from src.config import postgres_settings
from src.utils.retry import retry


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


def test_connection():
    """Test the database connection."""
    try:
        ping()
        print("✓ Database connection successful!")
        return True
    except Exception as e:
        print(f"✗ Database connection failed: {e}")
        return False


if __name__ == "__main__":
    test_connection()
