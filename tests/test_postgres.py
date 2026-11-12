"""Tests for create_schema() in src/storage/postgres.py, with a fake engine (no database).

That two callers at the same moment really wait for each other is a Postgres feature
(advisory locks); these tests check that create_schema() uses it correctly, and that
init-db (one of those callers) goes through it.
"""
from contextlib import contextmanager

import src.storage.init_db as init_db
import src.storage.postgres as pg


class FakeEngine:
    """Records the statements of each transaction opened with begin()."""

    def __init__(self):
        self.transactions = []

    @contextmanager
    def begin(self):
        statements = []
        self.transactions.append(statements)
        yield FakeConnection(statements)


class FakeConnection:
    def __init__(self, statements):
        self.statements = statements

    def execute(self, statement, parameters=None):
        self.statements.append((str(statement), parameters))

    def exec_driver_sql(self, sql):
        self.statements.append((sql, None))


def test_takes_the_lock_then_creates_the_schema_in_the_same_transaction(monkeypatch):
    engine = FakeEngine()
    monkeypatch.setattr(pg, "get_engine", lambda: engine)

    pg.create_schema()

    assert len(engine.transactions) == 1               # lock and schema: one transaction
    (lock_sql, lock_params), (schema_sql, _) = engine.transactions[0]
    # The _xact_ variant: released by the commit. The session-level pg_advisory_lock
    # would stay held on the pooled connection after the transaction.
    assert "pg_advisory_xact_lock(:id)" in lock_sql
    assert lock_params == {"id": pg.SCHEMA_LOCK_ID}
    assert schema_sql == pg.SCHEMA_FILE.read_text(encoding="utf-8")


def test_schema_only_creates_what_is_missing():
    """Run by every backfill, so it must never fail or change anything that exists."""
    statements = [s.strip() for s in pg.SCHEMA_FILE.read_text(encoding="utf-8").split(";")]
    statements = [s for s in statements if s]
    assert statements
    for statement in statements:
        assert statement.upper().startswith(("CREATE TABLE IF NOT EXISTS",
                                             "CREATE INDEX IF NOT EXISTS")), statement


def test_init_db_creates_the_tables_through_the_locked_function(monkeypatch):
    """init-db can run at the same moment as the ingest and retrain jobs."""
    calls = []
    monkeypatch.setattr(init_db, "create_schema", lambda: calls.append("create schema"))
    init_db.init_postgres()
    assert calls == ["create schema"]
