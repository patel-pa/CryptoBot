from functools import lru_cache

from pymongo import MongoClient
from pymongo.errors import ConnectionFailure

from src.config import mongo_settings
from src.utils.retry import retry


@lru_cache(maxsize=1)
def get_db():
    """Handle to the configured database, created on first use (not at import).

    Importing this module therefore never needs the Mongo env vars; only code
    that actually talks to MongoDB does. Settings come from src.config.
    """
    settings = mongo_settings()
    # serverSelectionTimeoutMS keeps a bad connection from hanging ~30s before failing.
    client = MongoClient(settings.uri(), serverSelectionTimeoutMS=3000)
    return client[settings.db]


def get_collection(name):
    """Return a collection handle from the configured database."""
    return get_db()[name]


def ping():
    """Raise ConnectionFailure unless MongoDB answers a ping."""
    get_db().client.admin.command("ping")


def wait_for_mongo(attempts=20, base_delay=1.0, max_delay=10.0):
    """Block until MongoDB accepts connections; raise after `attempts` tries.

    Same role as wait_for_postgres(): pods start in any order on Kubernetes.
    Only connection errors are retried (ServerSelectionTimeoutError is one);
    a missing env var or a wrong password fails immediately.
    """
    retry(ping, attempts=attempts, base_delay=base_delay, max_delay=max_delay,
          exceptions=(ConnectionFailure,), what="MongoDB connection")
    print("✓ MongoDB reachable", flush=True)


def test_connection():
    """Test the MongoDB connection."""
    try:
        ping()
        print("✓ MongoDB connection successful!")
        return True
    except Exception as e:
        print(f"✗ MongoDB connection failed: {e}")
        return False


if __name__ == "__main__":
    test_connection()
