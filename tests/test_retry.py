"""Tests for src/utils/retry.py and the wait_for_* startup helpers."""
from types import SimpleNamespace

import pytest
from pymongo.errors import ServerSelectionTimeoutError
from sqlalchemy.exc import OperationalError

import src.utils.retry as retry_module
from src.storage import mongo, postgres
from src.utils.retry import retry


class Flaky:
    """Callable that raises `exc` for the first `failures` calls, then returns."""

    def __init__(self, failures, exc=None, result="ok"):
        self.failures = failures
        self.exc = exc or RuntimeError("boom")
        self.result = result
        self.calls = 0

    def __call__(self):
        self.calls += 1
        if self.calls <= self.failures:
            raise self.exc
        return self.result


def connection_refused():
    return OperationalError("SELECT 1", {}, Exception("connection refused"))


@pytest.fixture
def no_sleep(monkeypatch):
    """Record the backoff delays instead of sleeping (only inside retry())."""
    delays = []
    monkeypatch.setattr(retry_module, "time", SimpleNamespace(sleep=delays.append))
    return delays


# --- retry() ---------------------------------------------------------------

def test_first_success_returns_without_sleeping():
    delays = []
    assert retry(Flaky(0), sleep=delays.append) == "ok"
    assert delays == []


def test_backoff_doubles_and_is_capped():
    delays = []
    func = Flaky(5)
    assert retry(func, attempts=6, base_delay=1, max_delay=10, sleep=delays.append) == "ok"
    assert func.calls == 6
    assert delays == [1, 2, 4, 8, 10]


def test_last_error_is_raised_after_final_attempt():
    delays = []
    func = Flaky(99)
    with pytest.raises(RuntimeError, match="boom"):
        retry(func, attempts=3, base_delay=1, sleep=delays.append)
    assert func.calls == 3
    assert delays == [1, 2]            # no sleep after the last attempt


def test_unlisted_exceptions_are_not_retried():
    delays = []
    func = Flaky(1, exc=KeyError("config"))
    with pytest.raises(KeyError):
        retry(func, attempts=5, exceptions=(ValueError,), sleep=delays.append)
    assert func.calls == 1
    assert delays == []


def test_zero_attempts_is_rejected():
    with pytest.raises(ValueError):
        retry(lambda: None, attempts=0)


# --- wait_for_postgres / wait_for_mongo (ping replaced by a fake) -----------

def test_wait_for_postgres_retries_until_db_answers(monkeypatch, no_sleep):
    ping = Flaky(2, exc=connection_refused(), result=None)
    monkeypatch.setattr(postgres, "ping", ping)
    postgres.wait_for_postgres(attempts=5, base_delay=1)
    assert ping.calls == 3
    assert no_sleep == [1, 2]


def test_wait_for_postgres_gives_up(monkeypatch, no_sleep):
    ping = Flaky(99, exc=connection_refused())
    monkeypatch.setattr(postgres, "ping", ping)
    with pytest.raises(OperationalError):
        postgres.wait_for_postgres(attempts=3, base_delay=1)
    assert ping.calls == 3


def test_wait_for_postgres_fails_fast_on_config_errors(monkeypatch, no_sleep):
    def ping():
        raise EnvironmentError("Missing environment variables: POSTGRES_HOST")
    monkeypatch.setattr(postgres, "ping", ping)
    with pytest.raises(EnvironmentError):
        postgres.wait_for_postgres(attempts=5)
    assert no_sleep == []


def test_wait_for_mongo_retries_until_db_answers(monkeypatch, no_sleep):
    ping = Flaky(1, exc=ServerSelectionTimeoutError("no servers"), result=None)
    monkeypatch.setattr(mongo, "ping", ping)
    mongo.wait_for_mongo(attempts=5, base_delay=1)
    assert ping.calls == 2
    assert no_sleep == [1]


# --- the real ping() against a closed port ---------------------------------
# Nothing listens on 127.0.0.1:1, so the drivers fail with their real
# connection-error types; this proves wait_for_* retries the right ones.

@pytest.fixture
def unreachable_dbs(monkeypatch):
    for key, value in {
        "POSTGRES_HOST": "127.0.0.1", "POSTGRES_PORT": "1", "POSTGRES_USER": "x",
        "POSTGRES_PASSWORD": "x", "POSTGRES_DB": "x",
        "MONGO_HOST": "127.0.0.1", "MONGO_PORT": "1", "MONGO_USER": "x",
        "MONGO_PASSWORD": "x", "MONGO_DB": "x",
    }.items():
        monkeypatch.setenv(key, value)
    postgres.get_engine.cache_clear()
    mongo.get_db.cache_clear()
    yield
    if postgres.get_engine.cache_info().currsize:
        postgres.get_engine().dispose()
    if mongo.get_db.cache_info().currsize:
        mongo.get_db().client.close()
    postgres.get_engine.cache_clear()
    mongo.get_db.cache_clear()


def test_real_postgres_ping_is_retried_then_raised(unreachable_dbs, no_sleep):
    with pytest.raises(OperationalError):
        postgres.wait_for_postgres(attempts=2, base_delay=1)
    assert no_sleep == [1]             # retried once, then gave up


def test_real_mongo_ping_raises_connection_failure(unreachable_dbs):
    with pytest.raises(ServerSelectionTimeoutError):   # ~3 s: the client's timeout
        mongo.wait_for_mongo(attempts=1)
