"""Self-test of the retry helpers of harness_util (no VM, no labgrid).

Runs in every QEMU job right after the environment is installed. A stub
stands in for the SSH driver, so the handling of the `apk update` flake
(F3 in harness/tests/conftest.py) is proven with injected failures.
"""

import logging

import pytest
from harness_util import APK_UPDATE_ATTEMPTS, apk_update, retry

EPERM = ["wgetFailed to send request: Operation not permitted"]


class StubSsh:
    """Answers `apk update` with the next scripted (out, err, rc)."""

    def __init__(self, answers):
        self.answers = list(answers)
        self.calls = []

    def run(self, cmd, timeout):
        self.calls.append((cmd, timeout))
        return self.answers[min(len(self.calls), len(self.answers)) - 1]


def failing(n):
    return [([], EPERM, 4)] * n


def test_retry_succeeds_at_once_without_sleeping():
    sleeps = []
    ok, details = retry(lambda: (True, "fine"), 3, 7, "x", sleep=sleeps.append)
    assert (ok, details, sleeps) == (True, ["fine"], [])


def test_retry_is_bounded_and_keeps_every_detail():
    sleeps = []
    results = iter(["a", "b", "c"])
    ok, details = retry(lambda: (False, next(results)), 3, 7, "x", sleep=sleeps.append)
    assert (ok, details, sleeps) == (False, ["a", "b", "c"], [7, 7])


def test_apk_update_absorbs_a_lost_fetch_and_says_so(caplog):
    ssh = StubSsh(failing(2) + [(["OK: 9973 distinct packages available"], [], 0)])
    with caplog.at_level(logging.WARNING, logger="harness"):
        apk_update(ssh, 600, sleep=lambda _s: None)
    assert ssh.calls == [("apk update", 600)] * 3
    warned = [r.getMessage() for r in caplog.records]
    assert len(warned) == 2
    assert all("Operation not permitted" in m for m in warned)


def test_apk_update_fails_after_the_last_attempt_with_all_output():
    ssh = StubSsh(failing(APK_UPDATE_ATTEMPTS + 3))
    with pytest.raises(AssertionError) as info:
        apk_update(ssh, 600, sleep=lambda _s: None)
    assert len(ssh.calls) == APK_UPDATE_ATTEMPTS
    message = str(info.value)
    assert f"each of {APK_UPDATE_ATTEMPTS} attempts" in message
    assert message.count("Operation not permitted") == APK_UPDATE_ATTEMPTS
