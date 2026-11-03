"""Self-test of the generic service rule (no VM, no labgrid, no real clock).

The rule of test_package.py::test_services_running, implemented by
harness_util.judge_instances / service_sampler / split_disabled: after a start,
at least one instance of a procd service must be running and stable (constant
pid for a window), every running instance must be stable, and an instance that
is not running passes only if it exited with exit_code 0.

The ubus answers are JSON files in fixtures/ubus-service-list/.
chrony-healthy.json is the verbatim output of `ubus call service list` seen in
run 41552951052, job 125652090597 (x86-64, 128M); the other chrony files change
one field of it. The netbird and socat files have the same shape (a procd
service with one instance, or none); they were written by hand, not recorded.
"""

import json
from pathlib import Path

import harness_util
import pytest
from harness_util import (
    disabled_services,
    judge_instances,
    poll,
    service_sampler,
    split_disabled,
)

FIXTURES = Path(__file__).parent / "fixtures" / "ubus-service-list"
SERVICE_TIMEOUT = 60
SERVICE_STABLE = 10


def fixture(name):
    return (FIXTURES / f"{name}.json").read_text(encoding="utf-8")


class StubSsh:
    """Answers each `ubus call service list` with the next scripted answer.

    An answer is a fixture name (rc 0), or (text, rc). The last one repeats.
    """

    def __init__(self, answers):
        self.answers = list(answers)
        self.calls = []

    def run(self, cmd, timeout):
        self.calls.append((cmd, timeout))
        answer = self.answers[min(len(self.calls), len(self.answers)) - 1]
        text, rc = answer if isinstance(answer, tuple) else (fixture(answer), 0)
        return text.splitlines(), [], rc


@pytest.fixture
def clock(monkeypatch):
    """Virtual time: poll() sleeps by advancing it, so a test takes no time."""
    now = [1000.0]
    monkeypatch.setattr(harness_util.time, "monotonic", lambda: now[0])
    monkeypatch.setattr(
        harness_util.time, "sleep", lambda s: now.__setitem__(0, now[0] + s)
    )
    return now


def check(name, answers):
    """The poll of test_services_running against scripted answers."""
    ssh = StubSsh(answers)
    ok, detail = poll(
        service_sampler(ssh, name), SERVICE_TIMEOUT, stable_s=SERVICE_STABLE
    )
    return ok, detail, ssh


# --- pass --------------------------------------------------------------------


def test_netbird_single_instance_running_passes(clock):
    ok, detail, _ = check("netbird", ["netbird-healthy"])
    assert ok, detail


def test_chrony_daemon_running_and_hotplug_exited_0_passes(clock):
    ok, detail, _ = check("chronyd", ["chrony-healthy"])
    assert ok, detail
    assert "pid changes seen: 0" in detail


def test_a_service_that_comes_up_late_passes(clock):
    ok, detail, ssh = check("chronyd", ["unknown-service"] * 3 + ["chrony-healthy"])
    assert ok, detail
    assert len(ssh.calls) > 3


def test_a_single_pid_change_followed_by_a_stable_window_passes(clock):
    ok, detail, _ = check("chronyd", ["chrony-healthy", "chrony-daemon-restarted"])
    assert ok, detail
    assert "pid changes seen: 1" in detail


def test_the_query_names_the_service_and_is_bounded(clock):
    _, _, ssh = check("netbird", ["netbird-healthy"])
    cmd, timeout = ssh.calls[0]
    assert cmd == """ubus call service list '{"name": "netbird"}'"""
    assert timeout == 30


# --- fail --------------------------------------------------------------------


@pytest.mark.parametrize(
    ("answers", "reason", "name"),
    [
        (["netbird-exit0"], "no instance is running", "netbird"),
        (["chrony-daemon-exit0"], "no instance is running", "chronyd"),
        (["chrony-daemon-exit1"], "instance1 is not running (exit_code 1)", "chronyd"),
        (["chrony-hotplug-exit1"], "instance2 is not running (exit_code 1)", "chronyd"),
        (
            ["chrony-hotplug-no-exit-code"],
            "instance2 is not running (no exit_code)",
            "chronyd",
        ),
        (["socat-no-instance"], "no instance", "socat"),
        (["unknown-service"], "no instance", "chronyd"),
    ],
    ids=[
        "daemon-exited-0-alone",
        "chrony-daemon-exited-0",
        "daemon-exit-code-1",
        "oneshot-exit-code-1",
        "oneshot-without-exit-code",
        "no-instance-after-start",
        "service-unknown-to-procd",
    ],
)
def test_unhealthy_states_fail_for_the_whole_window(clock, answers, reason, name):
    ok, detail, ssh = check(name, answers)
    assert not ok
    assert reason in detail
    assert len(ssh.calls) > SERVICE_TIMEOUT / harness_util.POLL_INTERVAL


def test_a_pid_that_keeps_changing_fails(clock):
    ok, detail, _ = check("chronyd", ["chrony-healthy", "chrony-daemon-restarted"] * 40)
    assert not ok
    assert "all instances fine" in detail
    assert "pid changes seen: " in detail
    assert "pid changes seen: 0" not in detail


def test_a_service_that_stops_late_fails(clock):
    ok, detail, _ = check("chronyd", ["chrony-healthy"] * 3 + ["chrony-daemon-exit1"])
    assert not ok
    assert "exit_code 1" in detail


@pytest.mark.parametrize(
    "answer",
    [("", 1), ("Command failed: Not found", 4), ("not json", 0), ("[]", 0)],
    ids=["ubus-rc-1", "ubus-not-found", "unparsable", "wrong-json-type"],
)
def test_a_failing_or_unreadable_ubus_answer_fails(clock, answer):
    ok, detail, _ = check("chronyd", [answer])
    assert not ok
    assert any(m in detail for m in ("ubus rc=", "unparsable", "unexpected"))


# --- judge_instances ---------------------------------------------------------


def test_judge_accepts_running_with_pid_and_oneshot_exit_0():
    ok, problems = judge_instances(
        {
            "a": {"running": True, "pid": 7},
            "b": {"running": False, "exit_code": 0},
        }
    )
    assert (ok, problems) == (True, [])


@pytest.mark.parametrize("code", [True, False, "0", 0.0, None, 1, 137, -1])
def test_judge_accepts_only_the_integer_exit_code_0(code):
    instances = {"a": {"running": True, "pid": 7}, "b": {"running": False}}
    if code is not None:
        instances["b"]["exit_code"] = code
    ok, problems = judge_instances(instances)
    assert not ok
    assert len(problems) == 1
    assert problems[0].startswith("b is not running")


def test_judge_rejects_a_running_instance_without_a_pid():
    ok, problems = judge_instances({"a": {"running": True}})
    assert not ok
    assert "a is running without a pid" in problems
    assert "no instance is running" in problems


def test_judge_names_every_problem():
    ok, problems = judge_instances(
        {"a": {"running": False, "exit_code": 2}, "b": {"running": False}}
    )
    assert not ok
    assert problems == [
        "a is not running (exit_code 2)",
        "b is not running (no exit_code)",
        "no instance is running",
    ]


def test_judge_rejects_no_instance():
    assert judge_instances({}) == (False, ["no instance"])


# --- services declared disabled by default -----------------------------------


def test_disabled_services_are_split_from_the_checked_ones():
    checked, skipped = split_disabled("socat", ["socat", "socat-x"], ["socat"])
    assert (checked, skipped) == (["socat-x"], ["socat"])


def test_no_disabled_service_checks_every_script():
    assert split_disabled("chrony", ["chronyd"], []) == (["chronyd"], [])


def test_everything_disabled_leaves_nothing_to_check():
    assert split_disabled("socat", ["socat"], ["socat"]) == ([], ["socat"])


def test_a_disabled_name_the_package_does_not_install_fails():
    with pytest.raises(AssertionError) as info:
        split_disabled("socat", ["socat"], ["sokat"])
    assert "sokat" in str(info.value)
    assert "installs only ['socat']" in str(info.value)


def test_disabled_services_unset_or_empty_is_an_empty_list(monkeypatch):
    monkeypatch.delenv("HARNESS_SERVICES_DISABLED", raising=False)
    assert disabled_services() == []
    monkeypatch.setenv("HARNESS_SERVICES_DISABLED", "")
    assert disabled_services() == []


def test_disabled_services_accepts_spaces_and_commas(monkeypatch):
    monkeypatch.setenv("HARNESS_SERVICES_DISABLED", "socat, ssh-agent  socat\nx.y_z")
    assert disabled_services() == ["socat", "ssh-agent", "x.y_z"]


@pytest.mark.parametrize("value", ["a/b", "../x", "x;id", "$(id)", "-x", "é", "a" * 65])
def test_disabled_services_rejects_an_invalid_name(monkeypatch, value):
    monkeypatch.setenv("HARNESS_SERVICES_DISABLED", f"ok {value}")
    with pytest.raises(pytest.fail.Exception):
        disabled_services()


def test_fixtures_are_valid_json_and_the_chrony_one_is_the_recorded_shape():
    for path in FIXTURES.glob("*.json"):
        json.loads(path.read_text(encoding="utf-8"))
    chrony = json.loads(fixture("chrony-healthy"))["chronyd"]["instances"]
    assert chrony["instance1"]["running"] is True
    assert chrony["instance2"] == {
        "running": False,
        "incarnation": 16,
        "command": ["/usr/sbin/chrony-hotplug"],
        "term_timeout": 5,
        "exit_code": 0,
    }
