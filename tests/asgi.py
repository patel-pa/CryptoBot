"""Send a request through the whole app (routing, validation, middleware) in tests.

A small helper plays the web server (ASGI is the interface between a Python web
app and its server), so no HTTP client library is needed.
"""
import asyncio

import src.api.main as api


def request(method, path, query=""):
    """Send one HTTP request to the app; return (status, headers, body).

    `query` is the part after "?", e.g. "limit=5".
    """
    scope = {
        "type": "http", "method": method, "path": path, "raw_path": path.encode(),
        "query_string": query.encode(), "headers": [], "http_version": "1.1",
        "scheme": "http", "server": ("test", 80), "client": ("test", 1234), "root_path": "",
    }
    sent = []

    async def receive():
        return {"type": "http.request", "body": b"", "more_body": False}

    async def send(message):
        sent.append(message)

    asyncio.run(api.app(scope, receive, send))
    start = next(m for m in sent if m["type"] == "http.response.start")
    body = b"".join(m.get("body", b"") for m in sent if m["type"] == "http.response.body")
    return start["status"], dict(start["headers"]), body
