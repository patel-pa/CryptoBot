"""Runtime configuration, read from environment variables.

Nothing is read or validated at import time: each settings function reads the
environment when it's called, i.e. when code first needs that database. Each
database is validated on its own, so a service only needs the variables of the
database it actually uses (the streamer never needs Postgres credentials).

Locally, a .env file in the repo root is loaded if present. docker compose and
Kubernetes pass real environment variables instead.
"""
import os
from dataclasses import dataclass, field
from urllib.parse import quote_plus

from dotenv import load_dotenv
from sqlalchemy.engine import URL

from src.params.constants import HISTORICAL_START_DATE

load_dotenv()   # no-op when there is no .env; never overrides real env vars


def _require(names):
    """Return {name: value} for env vars that must be set; list all missing ones."""
    values = {name: os.getenv(name) for name in names}
    missing = [name for name, value in values.items() if not value]
    if missing:
        raise EnvironmentError(
            f"Missing environment variables: {', '.join(missing)}. "
            "Set them in the environment or in a .env file (see .env.example)."
        )
    return values


def _port(name, default):
    """Read a port number from env var `name`, falling back to `default`."""
    raw = os.getenv(name)
    if not raw:
        return default
    try:
        return int(raw)
    except ValueError:
        raise EnvironmentError(f"{name} must be a port number, got {raw!r}") from None


@dataclass(frozen=True)
class PostgresSettings:
    host: str
    port: int
    user: str
    password: str = field(repr=False)   # keep passwords out of logs / tracebacks
    db: str

    def url(self):
        """SQLAlchemy URL. URL.create escapes special characters in the password
        (managed passwords from AWS Secrets Manager can contain @ / : etc.)."""
        return URL.create(
            "postgresql",
            username=self.user,
            password=self.password,
            host=self.host,
            port=self.port,
            database=self.db,
        )


@dataclass(frozen=True)
class MongoSettings:
    host: str
    port: int
    user: str
    password: str = field(repr=False)
    db: str

    def uri(self):
        """MongoDB connection string, with user and password percent-escaped."""
        return (
            f"mongodb://{quote_plus(self.user)}:{quote_plus(self.password)}"
            f"@{self.host}:{self.port}/?authSource=admin"
        )


def postgres_settings():
    env = _require(["POSTGRES_HOST", "POSTGRES_USER", "POSTGRES_PASSWORD", "POSTGRES_DB"])
    return PostgresSettings(
        host=env["POSTGRES_HOST"],
        port=_port("POSTGRES_PORT", 5432),
        user=env["POSTGRES_USER"],
        password=env["POSTGRES_PASSWORD"],
        db=env["POSTGRES_DB"],
    )


def mongo_settings():
    env = _require(["MONGO_HOST", "MONGO_USER", "MONGO_PASSWORD", "MONGO_DB"])
    return MongoSettings(
        host=env["MONGO_HOST"],
        port=_port("MONGO_PORT", 27017),
        user=env["MONGO_USER"],
        password=env["MONGO_PASSWORD"],
        db=env["MONGO_DB"],
    )


def historical_start_date():
    """Where an EMPTY database starts its backfill ('DD.MM.YYYYThh:mm').

    Env var HISTORICAL_START_DATE overrides the default in constants.py.
    """
    return os.getenv("HISTORICAL_START_DATE") or HISTORICAL_START_DATE
