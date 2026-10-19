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
from urllib.parse import quote, quote_plus, urlencode

from dotenv import load_dotenv
from sqlalchemy.engine import URL

from src.params.constants import HISTORICAL_START_DATE

load_dotenv()   # no-op when there is no .env; never overrides real env vars

# libpq's sslmode values; RDS for PostgreSQL requires SSL, so on AWS use
# "require" (encrypted) or "verify-full" (encrypted + server certificate checked).
POSTGRES_SSL_MODES = ("disable", "allow", "prefer", "require", "verify-ca", "verify-full")


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


def _flag(name, default=False):
    """Read a yes/no env var: true/false, 1/0 or yes/no (any case)."""
    raw = os.getenv(name)
    if not raw:
        return default
    value = raw.strip().lower()
    if value in ("true", "1", "yes"):
        return True
    if value in ("false", "0", "no"):
        return False
    raise EnvironmentError(f"{name} must be true or false, got {raw!r}")


def _file(name):
    """Read an optional file path; if it is set, the file must exist."""
    path = os.getenv(name) or None
    if path and not os.path.isfile(path):
        raise EnvironmentError(f"{name} points to {path!r}, which is not a file")
    return path


@dataclass(frozen=True)
class PostgresSettings:
    host: str
    port: int
    user: str
    password: str = field(repr=False)   # keep passwords out of logs / tracebacks
    db: str
    sslmode: str | None = None           # unset = libpq default ("prefer")
    sslrootcert: str | None = None       # CA file, needed for "verify-full"

    def url(self):
        """SQLAlchemy URL. URL.create escapes special characters in the password
        (managed passwords from AWS Secrets Manager can contain @ / : etc.)."""
        query = {key: value for key, value in
                 (("sslmode", self.sslmode), ("sslrootcert", self.sslrootcert)) if value}
        return URL.create(
            "postgresql",
            username=self.user,
            password=self.password,
            host=self.host,
            port=self.port,
            database=self.db,
            query=query,
        )


@dataclass(frozen=True)
class MongoSettings:
    host: str
    port: int
    user: str
    password: str = field(repr=False)
    db: str
    tls: bool = False                    # Amazon DocumentDB requires TLS
    tls_ca_file: str | None = None       # CA file the server certificate is checked against

    def uri(self):
        """MongoDB connection string, with user, password and options escaped.

        With tls on (Amazon DocumentDB) it also sets retryWrites=false, because
        DocumentDB does not support retryable writes.
        """
        options = {"authSource": "admin"}
        if self.tls:
            options["tls"] = "true"
            options["retryWrites"] = "false"
            if self.tls_ca_file:
                options["tlsCAFile"] = self.tls_ca_file
        return (
            f"mongodb://{quote_plus(self.user)}:{quote_plus(self.password)}"
            f"@{self.host}:{self.port}/?{urlencode(options, quote_via=quote)}"
        )


def postgres_settings():
    env = _require(["POSTGRES_HOST", "POSTGRES_USER", "POSTGRES_PASSWORD", "POSTGRES_DB"])
    sslmode = os.getenv("POSTGRES_SSLMODE") or None
    if sslmode and sslmode not in POSTGRES_SSL_MODES:
        raise EnvironmentError(
            f"POSTGRES_SSLMODE must be one of {', '.join(POSTGRES_SSL_MODES)}, got {sslmode!r}")
    return PostgresSettings(
        host=env["POSTGRES_HOST"],
        port=_port("POSTGRES_PORT", 5432),
        user=env["POSTGRES_USER"],
        password=env["POSTGRES_PASSWORD"],
        db=env["POSTGRES_DB"],
        sslmode=sslmode,
        sslrootcert=_file("POSTGRES_SSLROOTCERT"),
    )


def mongo_settings():
    env = _require(["MONGO_HOST", "MONGO_USER", "MONGO_PASSWORD", "MONGO_DB"])
    return MongoSettings(
        host=env["MONGO_HOST"],
        port=_port("MONGO_PORT", 27017),
        user=env["MONGO_USER"],
        password=env["MONGO_PASSWORD"],
        db=env["MONGO_DB"],
        tls=_flag("MONGO_TLS"),
        tls_ca_file=_file("MONGO_TLS_CA_FILE"),
    )


def historical_start_date():
    """Where an EMPTY database starts its backfill ('DD.MM.YYYYThh:mm').

    Env var HISTORICAL_START_DATE overrides the default in constants.py.
    """
    return os.getenv("HISTORICAL_START_DATE") or HISTORICAL_START_DATE
