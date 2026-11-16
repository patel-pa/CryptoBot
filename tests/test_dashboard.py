"""Tests for the messages of the Streamlit dashboard (src/visualization/app.py).

Streamlit's own test runner (streamlit.testing) runs the script without a
browser or server; the API is replaced by fake answers to requests.get. The
page is public on AWS: errors must be short and name no internal address.
"""
from unittest import mock

import pytest
import requests
from streamlit.testing.v1 import AppTest

APP = "../src/visualization/app.py"          # relative to this file

# app.py switches off pandas' new string type (a crash workaround, see its comment);
# pandas warns that this switch goes away in pandas 4.0. Known, so allowed here only.
pytestmark = pytest.mark.filterwarnings(
    "ignore:The 'future.infer_string' option is deprecated:pandas.errors.Pandas4Warning")


def run_dashboard(fake_get):
    with mock.patch("requests.get", fake_get):
        return AppTest.from_file(APP, default_timeout=60).run()


def test_an_unreachable_api_gives_a_short_message():
    def api_down(url, *args, **kwargs):
        raise requests.ConnectionError("refused by localhost:8000")

    page = run_dashboard(api_down)
    assert not page.exception                               # no traceback on the page
    assert "not reachable" in page.error[0].value
    assert "localhost" not in page.error[0].value
    assert "uvicorn" not in page.error[0].value             # no developer commands


def test_a_failing_charts_call_gives_a_short_message():
    def charts_fail(url, *args, **kwargs):
        if url.endswith("/health"):
            return mock.Mock(status_code=200)
        if url.endswith("/charts"):
            raise requests.ConnectionError("HTTPConnectionPool(host='api-internal', port=8000)")
        raise AssertionError(f"unexpected request {url}")

    page = run_dashboard(charts_fail)
    assert not page.exception
    assert "price history is unavailable" in page.error[0].value
    assert "api-internal" not in page.error[0].value
