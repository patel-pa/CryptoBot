"""Tests for src/cli.py: the commands the scheduled jobs run, and their exit codes."""
import os
import subprocess
import sys
from pathlib import Path

import pytest

import src.cli as cli
import src.models.train_model as train_model

REPO_ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture
def steps(monkeypatch):
    """Replace the real work with recorders; the list shows which steps ran, in order."""
    done = []
    monkeypatch.setattr(cli, "backfill", lambda: done.append("backfill"))
    monkeypatch.setattr(train_model, "train", lambda: done.append("train"))   # imported by retrain()
    return done


def test_ingest_runs_the_backfill(steps, capsys):
    assert cli.main(["ingest"]) == 0
    assert steps == ["backfill"]
    out = capsys.readouterr().out
    assert "ingest: started" in out
    assert "ingest: finished in" in out


def test_retrain_ingests_first_then_trains(steps):
    assert cli.main(["retrain"]) == 0
    assert steps == ["backfill", "train"]


def test_failure_exits_1_and_does_not_train_on_stale_data(steps, monkeypatch, capsys):
    def binance_down():
        raise ConnectionError("Binance unreachable")

    monkeypatch.setattr(cli, "backfill", binance_down)
    assert cli.main(["retrain"]) == 1
    assert steps == []                                 # train() never ran
    captured = capsys.readouterr()
    assert "retrain: FAILED after" in captured.out
    assert "Binance unreachable" in captured.err       # the traceback, for the logs


@pytest.mark.parametrize("argv", [[], ["deploy"]])
def test_missing_or_unknown_command_exits_2(argv, steps):
    with pytest.raises(SystemExit) as exc:
        cli.main(argv)
    assert exc.value.code == 2                         # argparse's usage error
    assert steps == []


def test_exit_code_reaches_the_shell():
    """`python -m src.cli ingest` for real: with no database host it fails, and the
    process ends with exit code 1 (what Kubernetes reads to mark the Job failed)."""
    env = {**os.environ, "POSTGRES_HOST": ""}
    result = subprocess.run([sys.executable, "-m", "src.cli", "ingest"],
                            cwd=REPO_ROOT, env=env, capture_output=True, text=True, timeout=60)
    assert result.returncode == 1
    assert "ingest: FAILED" in result.stdout
