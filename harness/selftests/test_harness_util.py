"""Self-test of the retry helpers of harness_util (no VM, no labgrid).

Runs in every QEMU job right after the environment is installed. A stub
stands in for the SSH driver, so the handling of the `apk update` flake
(F3 in harness/tests/conftest.py) is proven with injected failures.
"""

import logging

import harness_util
import pytest
from harness_util import APK_UPDATE_ATTEMPTS, apk_update, retry

# The lost fetch as the log of malta-le (job 125011711905) shows it.
LOST_OUT = [
    " [https://downloads.openwrt.org/releases/25.12.6/packages/mipsel_24kc/base/packages.adb]",
    "1 unavailable, 0 stale; 10940 distinct packages available",
]
LOST_ERR = [
    "wgetFailed to send request: Operation not permitted",
    "ERROR: wget: exited with error 4",
    "WARNING: updating and opening https://x/packages.adb: unexpected end of file",
]
LOST = (LOST_OUT, LOST_ERR, 4)
# Failures that are not the lost fetch; the first two also say "unavailable".
NOT_FOUND = (
    ["1 unavailable, 0 stale; 10940 distinct packages available"],
    ["ERROR: https://downloads.openwrt.org/x/packages.adb: 404 Not Found"],
    1,
)
UNTRUSTED = ([], ["ERROR: https://x/packages.adb: UNTRUSTED signature"], 99)
OK = (["OK: 9973 distinct packages available"], [], 0)


class StubSsh:
    """Answers `apk update` with the next scripted (out, err, rc)."""

    def __init__(self, answers):
        self.answers = list(answers)
        self.calls = []

    def run(self, cmd, timeout):
        self.calls.append((cmd, timeout))
        return self.answers[min(len(self.calls), len(self.answers)) - 1]


def no_sleep(_s):
    pass


def test_limits_of_the_apk_update_retry_are_pinned():
    assert harness_util.APK_UPDATE_ATTEMPTS == 5
    assert harness_util.APK_UPDATE_DELAY == 5


def test_retry_succeeds_at_once_without_sleeping():
    sleeps = []
    ok, details = retry(lambda: (True, "fine"), 3, 7, "x", sleep=sleeps.append)
    assert (ok, details, sleeps) == (True, ["fine"], [])


def test_retry_is_bounded_and_keeps_every_detail():
    sleeps = []
    results = iter(["a", "b", "c"])
    ok, details = retry(lambda: (False, next(results)), 3, 7, "x", sleep=sleeps.append)
    assert (ok, details, sleeps) == (False, ["a", "b", "c"], [7, 7])


def test_retry_stops_at_a_failure_that_is_not_transient():
    sleeps = []
    results = iter(["transient", "final", "never"])
    ok, details = retry(
        lambda: (False, next(results)),
        5,
        7,
        "x",
        sleep=sleeps.append,
        transient=lambda d: d == "transient",
    )
    assert (ok, details, sleeps) == (False, ["transient", "final"], [7])


def test_apk_update_absorbs_a_lost_fetch_and_says_so(caplog):
    ssh = StubSsh([LOST, LOST, OK])
    with caplog.at_level(logging.WARNING, logger="harness"):
        apk_update(ssh, 600, sleep=no_sleep)
    assert ssh.calls == [("apk update", 600)] * 3
    warned = [r.getMessage() for r in caplog.records]
    assert len(warned) == 2
    assert all("Operation not permitted" in m for m in warned)


def test_apk_update_waits_the_default_delay_between_attempts(monkeypatch):
    sleeps = []
    monkeypatch.setattr(harness_util.time, "sleep", sleeps.append)
    with pytest.raises(AssertionError):
        apk_update(StubSsh([LOST]), 600)
    assert sleeps == [5, 5, 5, 5]


def test_apk_update_fails_after_the_last_attempt_with_all_output():
    ssh = StubSsh([LOST] * (APK_UPDATE_ATTEMPTS + 3))
    with pytest.raises(AssertionError) as info:
        apk_update(ssh, 600, sleep=no_sleep)
    assert len(ssh.calls) == 5
    message = str(info.value)
    assert "in each of 5 attempts" in message
    assert message.count("Operation not permitted") == 5


@pytest.mark.parametrize("answer", [NOT_FOUND, UNTRUSTED], ids=["404", "untrusted"])
def test_apk_update_does_not_repeat_another_failure(answer, caplog):
    ssh = StubSsh([answer, OK])
    sleeps = []
    with (
        caplog.at_level(logging.WARNING, logger="harness"),
        pytest.raises(AssertionError) as info,
    ):
        apk_update(ssh, 600, sleep=sleeps.append)
    assert len(ssh.calls) == 1
    assert sleeps == []
    assert caplog.records == []
    assert "not a lost fetch, not repeated" in str(info.value)
    assert str(answer[2]) in str(info.value)


def test_apk_update_stops_when_a_lost_fetch_is_followed_by_another_failure():
    ssh = StubSsh([LOST, NOT_FOUND, OK])
    with pytest.raises(AssertionError) as info:
        apk_update(ssh, 600, sleep=no_sleep)
    assert len(ssh.calls) == 2
    message = str(info.value)
    assert "on attempt 2 (not a lost fetch, not repeated)" in message
    assert "attempt 1:" in message
    assert "404 Not Found" in message


def test_apk_update_puts_each_absorbed_retry_in_the_job_summary(monkeypatch, tmp_path):
    summary = tmp_path / "summary.md"
    monkeypatch.setenv("GITHUB_STEP_SUMMARY", str(summary))
    apk_update(StubSsh([LOST, LOST, OK]), 600, sleep=no_sleep)
    lines = summary.read_text(encoding="utf-8").splitlines()
    assert len(lines) == 2
    assert "`apk update` failed (attempt 1 of 5)" in lines[0]
    assert "repeated after 5 s" in lines[0]
    assert "attempt 2 of 5" in lines[1]


def test_apk_update_writes_no_summary_when_nothing_was_repeated(monkeypatch, tmp_path):
    summary = tmp_path / "summary.md"
    monkeypatch.setenv("GITHUB_STEP_SUMMARY", str(summary))
    apk_update(StubSsh([OK]), 600, sleep=no_sleep)
    assert not summary.exists()


def test_apk_update_works_without_a_job_summary(monkeypatch):
    monkeypatch.delenv("GITHUB_STEP_SUMMARY", raising=False)
    apk_update(StubSsh([LOST, OK]), 600, sleep=no_sleep)
