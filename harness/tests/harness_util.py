"""Small helpers shared by the harness tests (no pytest collection)."""

import os
import time

import pytest

POLL_INTERVAL = 2.0


def env(name):
    """Return a required environment variable or fail with a clear message."""
    value = os.environ.get(name)
    if not value:
        pytest.fail(f"environment variable {name} is required", pytrace=False)
    return value


def poll(check, timeout_s, interval_s=POLL_INTERVAL):
    """Call check() until it reports success or the deadline passes.

    check returns (ok, detail). Returns (ok, detail) of the last call, so the
    caller can put the last observed state in its assertion message.
    """
    deadline = time.monotonic() + timeout_s
    while True:
        ok, detail = check()
        if ok or time.monotonic() >= deadline:
            return ok, detail
        time.sleep(interval_s)
