from functools import lru_cache

from sqlalchemy import create_engine, text

from src.config import postgres_settings


@lru_cache(maxsize=1)
def get_engine():
    """Shared SQLAlchemy engine, created on first use (not at import time).

    Importing this module therefore never needs the Postgres env vars; only
    code that actually talks to Postgres does. Settings come from src.config.
    """
    return create_engine(postgres_settings().url())


def test_connection():
    """Test the database connection."""
    try:
        with get_engine().connect() as connection:
            connection.execute(text("SELECT 1"))
            print("✓ Database connection successful!")
            return True
    except Exception as e:
        print(f"✗ Database connection failed: {e}")
        return False


if __name__ == "__main__":
    test_connection()
