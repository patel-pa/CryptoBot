from functools import lru_cache

from pymongo import MongoClient

from src.config import mongo_settings


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


def test_connection():
    """Test the MongoDB connection."""
    try:
        get_db().client.admin.command("ping")
        print("✓ MongoDB connection successful!")
        return True
    except Exception as e:
        print(f"✗ MongoDB connection failed: {e}")
        return False


if __name__ == "__main__":
    test_connection()
