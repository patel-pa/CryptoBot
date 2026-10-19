"""Tests for src/config.py: env-var settings, read lazily, with safe URLs."""
import os
import subprocess
import sys
from pathlib import Path

import pytest
from pymongo.uri_parser import parse_uri
from sqlalchemy.engine import make_url

from src import config
from src.params.constants import HISTORICAL_START_DATE

REPO_ROOT = Path(__file__).resolve().parents[1]

PG_ENV = {
    "POSTGRES_HOST": "pg.example.com",
    "POSTGRES_PORT": "5433",
    "POSTGRES_USER": "cryptobot",
    "POSTGRES_PASSWORD": "secret",
    "POSTGRES_DB": "cryptobot",
}
MONGO_ENV = {
    "MONGO_HOST": "mongo.example.com",
    "MONGO_PORT": "27018",
    "MONGO_USER": "cryptobot",
    "MONGO_PASSWORD": "secret",
    "MONGO_DB": "cryptobot",
}
# Characters that break a hand-built URL: @ / : # ? %
TRICKY_PASSWORD = "p@ss:w/rd#?%"


@pytest.fixture
def pg_env(monkeypatch):
    for key, value in PG_ENV.items():
        monkeypatch.setenv(key, value)
    for key in ("POSTGRES_SSLMODE", "POSTGRES_SSLROOTCERT"):
        monkeypatch.delenv(key, raising=False)


@pytest.fixture
def mongo_env(monkeypatch):
    for key, value in MONGO_ENV.items():
        monkeypatch.setenv(key, value)
    for key in ("MONGO_TLS", "MONGO_TLS_CA_FILE"):
        monkeypatch.delenv(key, raising=False)


@pytest.fixture
def ca_file(tmp_path):
    """A stand-in CA file. The space in the name must survive URI escaping."""
    path = tmp_path / "ca bundle.pem"
    path.write_text("placeholder, not a real certificate")
    return str(path)


def test_postgres_settings_from_env(pg_env):
    s = config.postgres_settings()
    assert (s.host, s.port, s.user, s.password, s.db) == (
        "pg.example.com", 5433, "cryptobot", "secret", "cryptobot")


def test_missing_postgres_vars_are_all_listed(monkeypatch):
    for key in PG_ENV:
        monkeypatch.delenv(key, raising=False)
    with pytest.raises(EnvironmentError) as exc:
        config.postgres_settings()
    message = str(exc.value)
    for key in ("POSTGRES_HOST", "POSTGRES_USER", "POSTGRES_PASSWORD", "POSTGRES_DB"):
        assert key in message
    assert "POSTGRES_PORT" not in message          # optional: has a default


def test_empty_value_counts_as_missing(pg_env, monkeypatch):
    monkeypatch.setenv("POSTGRES_PASSWORD", "")
    with pytest.raises(EnvironmentError, match="POSTGRES_PASSWORD"):
        config.postgres_settings()


def test_mongo_settings_do_not_need_postgres_vars(mongo_env, monkeypatch):
    for key in PG_ENV:
        monkeypatch.delenv(key, raising=False)
    assert config.mongo_settings().host == "mongo.example.com"


def test_ports_default_when_unset(pg_env, mongo_env, monkeypatch):
    monkeypatch.delenv("POSTGRES_PORT")
    monkeypatch.delenv("MONGO_PORT")
    assert config.postgres_settings().port == 5432
    assert config.mongo_settings().port == 27017


def test_invalid_port_is_rejected(pg_env, monkeypatch):
    monkeypatch.setenv("POSTGRES_PORT", "abc")
    with pytest.raises(EnvironmentError, match="POSTGRES_PORT"):
        config.postgres_settings()


def test_postgres_url_escapes_special_characters(pg_env, monkeypatch):
    monkeypatch.setenv("POSTGRES_PASSWORD", TRICKY_PASSWORD)
    rendered = config.postgres_settings().url().render_as_string(hide_password=False)
    parsed = make_url(rendered)                    # round-trip through the string form
    assert parsed.password == TRICKY_PASSWORD
    assert (parsed.host, parsed.port, parsed.database) == ("pg.example.com", 5433, "cryptobot")


def test_mongo_uri_escapes_special_characters(mongo_env, monkeypatch):
    monkeypatch.setenv("MONGO_PASSWORD", TRICKY_PASSWORD)
    parsed = parse_uri(config.mongo_settings().uri())
    assert parsed["password"] == TRICKY_PASSWORD
    assert parsed["nodelist"] == [("mongo.example.com", 27018)]
    assert parsed["options"]["authSource"] == "admin"


def test_mongo_uri_without_tls_is_unchanged(mongo_env):
    assert parse_uri(config.mongo_settings().uri())["options"] == {"authSource": "admin"}


def test_mongo_uri_with_tls_for_documentdb(mongo_env, monkeypatch, ca_file):
    monkeypatch.setenv("MONGO_TLS", "true")
    monkeypatch.setenv("MONGO_TLS_CA_FILE", ca_file)
    options = parse_uri(config.mongo_settings().uri())["options"]
    assert options["tls"] is True
    assert options["retryWrites"] is False          # DocumentDB has no retryable writes
    assert options["tlsCAFile"] == ca_file
    assert options["authSource"] == "admin"


@pytest.mark.parametrize("raw, expected", [
    ("true", True), ("TRUE", True), ("1", True), ("yes", True),
    ("false", False), ("0", False), ("no", False),
])
def test_mongo_tls_flag_values(mongo_env, monkeypatch, raw, expected):
    monkeypatch.setenv("MONGO_TLS", raw)
    assert config.mongo_settings().tls is expected


def test_invalid_mongo_tls_flag_is_rejected(mongo_env, monkeypatch):
    monkeypatch.setenv("MONGO_TLS", "maybe")
    with pytest.raises(EnvironmentError, match="MONGO_TLS"):
        config.mongo_settings()


def test_missing_ca_file_is_rejected(mongo_env, monkeypatch, tmp_path):
    monkeypatch.setenv("MONGO_TLS_CA_FILE", str(tmp_path / "missing.pem"))
    with pytest.raises(EnvironmentError, match="MONGO_TLS_CA_FILE"):
        config.mongo_settings()


def test_postgres_url_has_no_ssl_options_by_default(pg_env):
    assert dict(config.postgres_settings().url().query) == {}


def test_postgres_ssl_settings_go_into_the_url(pg_env, monkeypatch, ca_file):
    monkeypatch.setenv("POSTGRES_SSLMODE", "verify-full")
    monkeypatch.setenv("POSTGRES_SSLROOTCERT", ca_file)
    url = config.postgres_settings().url()
    assert dict(url.query) == {"sslmode": "verify-full", "sslrootcert": ca_file}
    parsed = make_url(url.render_as_string(hide_password=False))   # survives the string form
    assert dict(parsed.query) == {"sslmode": "verify-full", "sslrootcert": ca_file}


def test_invalid_postgres_sslmode_is_rejected(pg_env, monkeypatch):
    monkeypatch.setenv("POSTGRES_SSLMODE", "on")
    with pytest.raises(EnvironmentError, match="POSTGRES_SSLMODE"):
        config.postgres_settings()


def test_passwords_are_not_in_repr(pg_env, mongo_env):
    assert "secret" not in repr(config.postgres_settings())
    assert "secret" not in repr(config.mongo_settings())


def test_historical_start_date_default_and_override(monkeypatch):
    monkeypatch.delenv("HISTORICAL_START_DATE", raising=False)
    assert config.historical_start_date() == HISTORICAL_START_DATE
    monkeypatch.setenv("HISTORICAL_START_DATE", "15.10.2026T00:00")
    assert config.historical_start_date() == "15.10.2026T00:00"


def test_importing_the_app_needs_no_db_env_vars():
    """Every module imports cleanly without any DB settings (they're read lazily).

    Runs in a fresh interpreter so modules already imported by other tests
    don't hide an import-time read. (A local .env would mask a regression here;
    CI has none, so CI is the real guard.)
    """
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(("POSTGRES_", "MONGO_"))}
    result = subprocess.run(
        [sys.executable, "-c",
         "import src.api.main, src.storage.init_db, src.models.train_model"],
        cwd=REPO_ROOT, env=env, capture_output=True, text=True,
    )
    assert result.returncode == 0, result.stderr
