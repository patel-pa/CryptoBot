"""Prometheus metrics for the API, served at GET /metrics.

Every HTTP request is counted and timed, labelled by its route PATTERN (e.g.
/predict), never the raw URL, so the number of label values stays small.
Forecast outcomes need no metric of their own: the status code of /predict
says it (200 stored, 503 no model yet, 404 no candle yet). The library adds
the standard Python and process metrics (memory, CPU, open files) by itself.
"""
import time

from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest

UNMATCHED = "unmatched"          # route label for paths that match no route (404)

REQUESTS = Counter(
    "cryptobot_http_requests_total",
    "HTTP requests handled by the API.",
    ["method", "route", "status"],
)
DURATION = Histogram(
    "cryptobot_http_request_duration_seconds",
    "Time the API took to answer an HTTP request, in seconds.",
    ["method", "route"],
)


def _route(request):
    route = request.scope.get("route")       # set by FastAPI once a route has matched
    return getattr(route, "path", None) or UNMATCHED


async def track_requests(request, call_next):
    """HTTP middleware: count and time every request (WebSockets are not HTTP)."""
    started = time.perf_counter()
    status = 500                             # a crashing handler is answered with a 500
    try:
        response = await call_next(request)
        status = response.status_code
        return response
    finally:
        method, route = request.method, _route(request)
        REQUESTS.labels(method, route, str(status)).inc()
        DURATION.labels(method, route).observe(time.perf_counter() - started)


def render():
    """The current metrics in Prometheus' text format, as (body, content type)."""
    return generate_latest(), CONTENT_TYPE_LATEST
