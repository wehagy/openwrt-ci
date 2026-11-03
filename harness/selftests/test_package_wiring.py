"""Self-test of the wiring of test_package.py::test_services_running.

test_services.py proves the rule (judge_instances, service_sampler, poll). This
file runs the real test function against a scripted VM and a virtual clock, so
what only test_package.py decides is proven offline too: the stable window
(SERVICE_STABLE) and the deadline (SERVICE_TIMEOUT) it hands to poll(), the
stop-then-start order, and what it does with services_disabled (skip, warn on a
name the package does not install, skip the whole test when nothing is left).
"""

import json

import harness_util
import pytest
import test_package as tp
from test_services import fixture

PACKAGE = "chrony"


class Vm:
    """A VM that answers the commands of test_services_running."""

    def __init__(self, scripts, ubus, procd=True, start_rc=0):
        self.scripts = scripts
        self.ubus = list(ubus)
        self.procd = procd
        self.start_rc = start_rc
        self.cmds = []
        self.samples = 0

    def run(self, cmd, timeout=None, **_):
        self.cmds.append(cmd)
        if cmd.startswith("apk info -L"):
            paths = [f"etc/init.d/{name}" for name in self.scripts]
            return [f"{PACKAGE}-4.9-r1 contains:", *paths], [], 0
        if cmd.startswith("grep -Eq"):
            return [], [], 0 if self.procd else 1
        if cmd.endswith(" start"):
            return [], [], self.start_rc
        if cmd.startswith("ubus call service list"):
            self.samples += 1
            name = json.loads(cmd.split("'")[1])["name"]
            answer = self.ubus[min(self.samples, len(self.ubus)) - 1]
            text = fixture(answer).replace("chronyd", name)
            return text.splitlines(), [], 0
        return [], [], 0  # stop


@pytest.fixture
def clock(monkeypatch):
    now = [1000.0]
    monkeypatch.setattr(harness_util.time, "monotonic", lambda: now[0])
    monkeypatch.setattr(
        harness_util.time, "sleep", lambda s: now.__setitem__(0, now[0] + s)
    )
    return now


@pytest.fixture
def props():
    return {}


def run_test(vm, props, monkeypatch, disabled=""):
    """Run the test; returns the skip reason, or None when it ran to the end.

    A skip is returned, not raised: raised inside a test of ours it would make
    this test "skipped" (neither green nor red) instead of failing it.
    """
    monkeypatch.setenv("HARNESS_SERVICES_DISABLED", disabled)
    try:
        tp.test_services_running(
            None, vm, PACKAGE, lambda k, v: props.__setitem__(k, v)
        )
    except pytest.skip.Exception as skipped:
        return str(skipped)
    return None


def test_a_healthy_service_passes_after_a_stop_and_a_start(clock, props, monkeypatch):
    vm = Vm(["chronyd"], ["chrony-healthy"])
    assert run_test(vm, props, monkeypatch) is None
    cmds = [c for c in vm.cmds if c.startswith("/etc/init.d/")]
    assert cmds == ["/etc/init.d/chronyd stop", "/etc/init.d/chronyd start"]
    assert vm.samples >= tp.SERVICE_STABLE / harness_util.POLL_INTERVAL
    assert "services_disabled_unknown" not in props


def test_a_service_that_dies_before_the_stable_window_ends_fails(
    clock, props, monkeypatch
):
    # healthy for 3 samples (4 s), then the daemon exits 1: only a window of
    # SERVICE_STABLE seconds can tell this from a healthy service.
    vm = Vm(["chronyd"], ["chrony-healthy"] * 3 + ["chrony-daemon-exit1"])
    with pytest.raises(AssertionError) as info:
        run_test(vm, props, monkeypatch)
    assert "not healthy and stable for 10 s (waited 60 s)" in str(info.value)
    assert "exit_code 1" in str(info.value)


def test_a_service_that_starts_late_passes_within_the_deadline(
    clock, props, monkeypatch
):
    # nothing for 20 s, then healthy: needs a deadline longer than a few seconds.
    vm = Vm(["chronyd"], ["unknown-service"] * 10 + ["chrony-healthy"])
    assert run_test(vm, props, monkeypatch) is None


def test_a_service_that_never_comes_up_fails_after_the_deadline(
    clock, props, monkeypatch
):
    vm = Vm(["chronyd"], ["unknown-service"])
    start = clock[0]
    with pytest.raises(AssertionError) as info:
        run_test(vm, props, monkeypatch)
    waited = clock[0] - start
    assert (
        tp.SERVICE_TIMEOUT
        <= waited
        < tp.SERVICE_TIMEOUT + 2 * harness_util.POLL_INTERVAL
    )
    assert "no instance" in str(info.value)


def test_a_failed_start_is_reported_without_polling(clock, props, monkeypatch):
    vm = Vm(["chronyd"], ["chrony-healthy"], start_rc=3)
    with pytest.raises(AssertionError) as info:
        run_test(vm, props, monkeypatch)
    assert "service chronyd start failed with rc=3" in str(info.value)
    assert vm.samples == 0


def test_a_script_that_is_not_procd_fails(clock, props, monkeypatch):
    vm = Vm(["chronyd"], ["chrony-healthy"], procd=False)
    with pytest.raises(AssertionError) as info:
        run_test(vm, props, monkeypatch)
    assert "/etc/init.d/chronyd is not a procd script" in str(info.value)


# --- services_disabled -------------------------------------------------------


def test_a_disabled_script_is_not_started_nor_sampled(clock, props, monkeypatch):
    vm = Vm(["chronyd", "chrony-x"], ["chrony-healthy"])
    assert run_test(vm, props, monkeypatch, disabled="chrony-x") is None
    assert not any("chrony-x" in c and c.startswith("/etc/init.d") for c in vm.cmds)
    assert props["service_chrony-x"] == "skipped: disabled by default"
    assert "services_disabled_unknown" not in props


def test_every_script_disabled_skips_the_test(clock, props, monkeypatch):
    vm = Vm(["chronyd"], ["chrony-healthy"])
    reason = run_test(vm, props, monkeypatch, disabled="chronyd")
    assert "every init script of chrony is declared disabled by default" in reason
    assert vm.samples == 0
    assert props["service_chronyd"] == "skipped: disabled by default"


def test_a_name_the_package_does_not_install_warns_and_the_rest_is_checked(
    clock, props, monkeypatch, caplog
):
    vm = Vm(["chronyd"], ["chrony-healthy"])
    with caplog.at_level("WARNING", logger="harness"):
        assert run_test(vm, props, monkeypatch, disabled="sokat") is None
    assert props["services_disabled_unknown"] == "sokat"
    assert "services_disabled names ['sokat']" in caplog.text
    assert vm.samples > 0, "the script the package does install must still be checked"


def test_an_unknown_name_does_not_hide_a_broken_service(clock, props, monkeypatch):
    vm = Vm(["chronyd"], ["chrony-daemon-exit1"])
    with pytest.raises(AssertionError) as info:
        run_test(vm, props, monkeypatch, disabled="sokat")
    assert "exit_code 1" in str(info.value)
    assert props["services_disabled_unknown"] == "sokat"


def test_known_and_unknown_names_together(clock, props, monkeypatch):
    vm = Vm(["chronyd", "chrony-x"], ["chrony-healthy"])
    assert run_test(vm, props, monkeypatch, disabled="chrony-x,sokat nope") is None
    assert props["services_disabled_unknown"] == "nope sokat"
    assert props["service_chrony-x"] == "skipped: disabled by default"


def test_a_package_without_init_scripts_is_skipped(clock, props, monkeypatch):
    vm = Vm([], ["chrony-healthy"])
    reason = run_test(vm, props, monkeypatch, disabled="sokat")
    assert reason == "chrony installs no /etc/init.d script, nothing to check"
    assert vm.samples == 0


# --- junit properties of the installed package ---------------------------------


class ListVm:
    """A VM whose apk reports one installed package."""

    def run(self, cmd, timeout=None, **_):
        if cmd.startswith("apk info -e"):
            return [], [], 0
        return [f"{PACKAGE}-4.9-r1 x86_64 {{{PACKAGE}}} (GPL-2.0) [installed]"], [], 0


INSTALLED_ENV = {
    "HARNESS_PACKAGE_VERSION": "4.9-r1",
    "HARNESS_LINE": "25.12",
    "HARNESS_RELEASE": "25.12.6",
    "HARNESS_IMAGE_URL": "https://example.invalid/image",
    "HARNESS_IMAGE_SHA256": "0" * 64,
}
TESTS_ENV = {
    "HARNESS_OPENWRT_TESTS_SHA": "b2ed9fe7057af3b52bb94a89ead366b9c526fe8e",
    "HARNESS_LABGRID_VERSION": "26.0.1",
}


def installed(props):
    tp.test_package_is_installed(
        None, ListVm(), PACKAGE, lambda k, v: props.__setitem__(k, v)
    )


def test_the_resolved_tests_environment_is_recorded(props, monkeypatch):
    for name, value in {**INSTALLED_ENV, **TESTS_ENV}.items():
        monkeypatch.setenv(name, value)
    installed(props)
    assert props["openwrt_tests_sha"] == TESTS_ENV["HARNESS_OPENWRT_TESTS_SHA"]
    assert props["labgrid_version"] == "26.0.1"
    assert props["package_version"] == "4.9-r1"


@pytest.mark.parametrize("missing", sorted(TESTS_ENV))
def test_a_job_without_a_resolved_version_fails(props, monkeypatch, missing):
    for name, value in {**INSTALLED_ENV, **TESTS_ENV}.items():
        monkeypatch.setenv(name, value)
    monkeypatch.delenv(missing)
    with pytest.raises(pytest.fail.Exception, match=missing):
        installed(props)
