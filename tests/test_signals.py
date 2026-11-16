"""Tests for src/utils/signals.py: SIGTERM stops a program like Ctrl+C."""
import os
import runpy
import signal
import subprocess
import sys
from pathlib import Path

import pytest

import src.utils.signals as signals

REPO_ROOT = Path(__file__).resolve().parents[1]

# "ready" is printed inside the try and the program sleeps in short steps, so the
# signal is handled within 50 ms wherever it arrives.
PROGRAM = """
import time
from src.utils.signals import stop_on_sigterm
stop_on_sigterm()
try:
    print("ready", flush=True)
    while True:
        time.sleep(0.05)
except KeyboardInterrupt:
    print("stopped cleanly", flush=True)
"""


@pytest.mark.skipif(os.name != "posix", reason="POSIX signals")
def test_sigterm_interrupts_the_program_at_once():
    proc = subprocess.Popen([sys.executable, "-c", PROGRAM], cwd=REPO_ROOT,
                            stdout=subprocess.PIPE, text=True)
    try:
        assert proc.stdout.readline().strip() == "ready"     # the handler is installed
        proc.send_signal(signal.SIGTERM)
        out, _ = proc.communicate(timeout=30)
    finally:
        proc.kill()
    assert out.strip() == "stopped cleanly"     # without the handler: killed, nothing printed
    assert proc.returncode == 0


class Installed(Exception):
    """Raised by the fake handler: stops the program before it connects to anything."""


@pytest.mark.parametrize("module", ["src.collection.stream_live", "src.cli", "src.storage.init_db"])
def test_each_entry_point_installs_the_handler(monkeypatch, module):
    def installed():
        raise Installed

    monkeypatch.setattr(signals, "stop_on_sigterm", installed)
    monkeypatch.delitem(sys.modules, module, raising=False)   # run it fresh, as `python -m` does
    with pytest.raises(Installed):
        runpy.run_module(module, run_name="__main__")
