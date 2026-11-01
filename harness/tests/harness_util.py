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


def poll(check, timeout_s, interval_s=POLL_INTERVAL, stable_s=0.0):
    """Call check() until it reports success or the deadline passes.

    check returns (ok, detail). Success needs ok for stable_s seconds without
    interruption, so a state that holds only for an instant does not count.
    Returns (ok, detail) of the last call, so the caller can put the last
    observed state in its assertion message.
    """
    deadline = time.monotonic() + timeout_s
    ok_since = None
    while True:
        ok, detail = check()
        now = time.monotonic()
        if not ok:
            ok_since = None
        elif ok_since is None:
            ok_since = now
        if ok and now - ok_since >= stable_s:
            return True, detail
        if now >= deadline:
            return False, detail
        time.sleep(interval_s)
