"""Bounded retry with capped exponential backoff.

For anything that fails transiently: a database that isn't accepting
connections yet (Kubernetes starts pods in any order, there is no Compose
`depends_on`), or a Binance request that hits a rate limit or a network blip.
"""
import time


def retry(func, *, attempts=5, base_delay=1.0, max_delay=30.0,
          exceptions=(Exception,), what=None, sleep=None):
    """Call `func()` until it returns, trying at most `attempts` times.

    Between tries it waits base_delay, then double each time, capped at
    max_delay (base 1 / max 10 gives 1, 2, 4, 8, 10, 10, ... seconds).
    Only the listed `exceptions` are retried; anything else propagates at
    once, so a misconfiguration fails fast instead of being retried for
    minutes. After the last failed try the last exception is re-raised.

    `what` names the operation in the progress lines; `sleep` can be
    replaced in tests.
    """
    if attempts < 1:
        raise ValueError("attempts must be at least 1")
    name = what or getattr(func, "__name__", "operation")
    wait = sleep or time.sleep
    for attempt in range(1, attempts + 1):
        try:
            return func()
        except exceptions as exc:
            if attempt == attempts:
                raise
            delay = min(base_delay * 2 ** (attempt - 1), max_delay)
            print(f"{name} failed (attempt {attempt}/{attempts}): {exc}. "
                  f"Retrying in {delay:g}s…", flush=True)
            wait(delay)
