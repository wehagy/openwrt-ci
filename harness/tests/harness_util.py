"""Small helpers shared by the harness tests (no pytest collection)."""

import logging
import os
import time

import pytest

POLL_INTERVAL = 2.0
LOG = logging.getLogger("harness")
APK_UPDATE_ATTEMPTS = 5
APK_UPDATE_DELAY = 5


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


def retry(attempt, attempts, delay_s, what, sleep=time.sleep):
    """Call attempt() until it reports success, at most `attempts` times.

    attempt returns (ok, detail). Every failed attempt except the last is
    logged as a warning with its detail, so a flake that a retry absorbed
    stays visible in the job log; after the last one the failure is the
    caller's to report. Returns (ok, details), one detail per attempt made.
    """
    details = []
    for number in range(1, attempts + 1):
        ok, detail = attempt()
        details.append(detail)
        if ok:
            return True, details
        if number < attempts:
            LOG.warning(
                "%s failed (attempt %d of %d), retrying in %s s: %s",
                what,
                number,
                attempts,
                delay_s,
                detail,
            )
            sleep(delay_s)
    return False, details


def apk_update(
    vm_ssh,
    timeout,
    attempts=APK_UPDATE_ATTEMPTS,
    delay_s=APK_UPDATE_DELAY,
    sleep=time.sleep,
):
    """Run `apk update` in the VM, repeated on failure.

    The first `apk update` after the network came up can lose one of its
    parallel fetches with `wget: Failed to send request: Operation not
    permitted` (see conftest.py, F3); the command only refreshes indexes, so
    repeating it is safe. After the last failed attempt the assertion carries
    the output of every attempt.
    """

    def once():
        out, err, rc = vm_ssh.run("apk update", timeout=timeout)
        return rc == 0, f"rc={rc}; stdout: {out}; stderr: {err}"

    ok, details = retry(once, attempts, delay_s, "apk update", sleep=sleep)
    assert ok, f"apk update failed in each of {attempts} attempts:\n" + "\n".join(
        f"  attempt {n}: {d}" for n, d in enumerate(details, 1)
    )
