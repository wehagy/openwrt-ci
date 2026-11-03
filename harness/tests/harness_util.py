"""Small helpers shared by the harness tests (no pytest collection)."""

import json
import logging
import os
import re
import shlex
import time

import pytest

POLL_INTERVAL = 2.0
LOG = logging.getLogger("harness")
APK_UPDATE_ATTEMPTS = 5
APK_UPDATE_DELAY = 5
# stderr of the lost fetch (log of malta-le, job 125011711905; busybox wget
# prints it without a space after "wget").
APK_UPDATE_TRANSIENT = "Failed to send request: Operation not permitted"


def env(name):
    """Return a required environment variable or fail with a clear message."""
    value = os.environ.get(name)
    if not value:
        pytest.fail(f"environment variable {name} is required", pytrace=False)
    return value


def apk_timeout_kwargs():
    """Keyword arguments of vm_ssh.run for the apk commands of the generic test.

    HARNESS_APK_TIMEOUT empty or unset: no `timeout` argument, so labgrid's own
    default applies (SSHDriver.run has timeout=None: no per-command limit). The
    caller's `apk_timeout` input (test.yml) sets it, in seconds.
    """
    value = os.environ.get("HARNESS_APK_TIMEOUT", "")
    if not value:
        return {}
    if not value.isdigit():
        pytest.fail(
            f"HARNESS_APK_TIMEOUT must be whole seconds, got {value!r}",
            pytrace=False,
        )
    return {"timeout": int(value)}


# Name of an /etc/init.d script, as the caller may declare it disabled.
SERVICE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")


def disabled_services():
    """Init script names the caller declared disabled by default.

    HARNESS_SERVICES_DISABLED (the `services_disabled` input of test.yml) is a
    list separated by spaces or commas. The service check skips those scripts.
    """
    names = os.environ.get("HARNESS_SERVICES_DISABLED", "").replace(",", " ").split()
    for name in names:
        if not SERVICE_NAME.match(name):
            pytest.fail(
                f"HARNESS_SERVICES_DISABLED has an invalid service name: {name!r}",
                pytrace=False,
            )
    return sorted(set(names))


def split_disabled(package, names, disabled):
    """Split the init scripts into (to check, skipped as disabled by default).

    A declared name that the package does not install fails: it is a typo or
    a script that was renamed, and the check would silently cover less.
    """
    unknown = [name for name in disabled if name not in names]
    assert not unknown, (
        f"services_disabled names {unknown}, but {package} installs only"
        f" {names} under /etc/init.d"
    )
    return [n for n in names if n not in disabled], [n for n in names if n in disabled]


def judge_instances(instances):
    """Judge one `ubus call service list` sample of a procd service.

    Returns (ok, problems). The rule: the service has at least one instance
    that is running (with a pid); an instance that is not running passes only
    if it exited with exit_code 0 (a one-shot such as chrony-hotplug). Any
    other state fails: no instance, a daemon that exited 0 on its own, a
    non-zero or missing exit_code, a running instance without a pid.
    Stability over time is the sampler's business (service_sampler).
    """
    if not instances:
        return False, ["no instance"]
    problems = []
    running = 0
    for key, inst in sorted(instances.items()):
        if inst.get("running"):
            if inst.get("pid"):
                running += 1
            else:
                problems.append(f"{key} is running without a pid")
            continue
        code = inst.get("exit_code")
        if type(code) is not int or code != 0:
            shown = "no exit_code" if code is None else f"exit_code {code!r}"
            problems.append(f"{key} is not running ({shown})")
    if not running:
        problems.append("no instance is running")
    return not problems, problems


def service_sampler(vm_ssh, name, query_timeout=30):
    """Return sample() -> (ok, detail) for the poll of one service.

    A sample is ok when judge_instances accepts it and the state of every
    instance (pid of a running one, exit code of an exited one) equals the
    previous sample's. A restart loop therefore never gets ok for a whole
    stable window.
    """
    state = {"last": None, "changes": 0}

    def sample():
        query = json.dumps({"name": name})
        out, _, rc = vm_ssh.run(
            f"ubus call service list {shlex.quote(query)}", timeout=query_timeout
        )
        detail = "\n".join(out)
        if rc != 0:
            return False, f"ubus rc={rc}: {detail}"
        try:
            services = json.loads(detail)
        except json.JSONDecodeError:
            return False, f"unparsable ubus output: {detail}"
        if not isinstance(services, dict):
            return False, f"unexpected ubus output: {detail}"
        instances = services.get(name, {}).get("instances", {})
        seen = tuple(
            sorted(
                (k, i.get("pid") if i.get("running") else None, i.get("exit_code"))
                for k, i in instances.items()
            )
        )
        unchanged = seen == state["last"]
        if state["last"] is not None and not unchanged:
            state["changes"] += 1
        state["last"] = seen
        ok, problems = judge_instances(instances)
        why = "; ".join(problems) if problems else "all instances fine"
        return ok and unchanged, (
            f"{why}; pid changes seen: {state['changes']}; last ubus output: {detail}"
        )

    return sample


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


def retry(attempt, attempts, delay_s, what, sleep=None, transient=None, on_retry=None):
    """Call attempt() until it reports success, at most `attempts` times.

    attempt returns (ok, detail). Every failed attempt except the last is
    logged as a warning with its detail, so a flake that a retry absorbed
    stays visible in the job log; on_retry(what, number, attempts, delay_s),
    if given, is called as well (the job summary). If transient is given, a
    failure whose detail it rejects is final: it is not repeated. After the
    last failure the report is the caller's to make. `sleep` defaults to
    time.sleep, looked up at the call. Returns (ok, details), one detail per
    attempt made.
    """
    sleep = time.sleep if sleep is None else sleep
    details = []
    for number in range(1, attempts + 1):
        ok, detail = attempt()
        details.append(detail)
        if ok:
            return True, details
        if transient is not None and not transient(detail):
            return False, details
        if number < attempts:
            LOG.warning(
                "%s failed (attempt %d of %d), retrying in %s s: %s",
                what,
                number,
                attempts,
                delay_s,
                detail,
            )
            if on_retry is not None:
                on_retry(what, number, attempts, delay_s)
            sleep(delay_s)
    return False, details


def summary_note(what, number, attempts, delay_s):
    """Append a retry notice to the job summary, if there is one.

    The `harness` warning is only in the raw log; this puts an absorbed flake
    where the job summary is read. GITHUB_STEP_SUMMARY is unset outside CI.
    """
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if not path:
        return
    with open(path, "a", encoding="utf-8") as summary:
        summary.write(
            f"- :warning: `{what}` failed (attempt {number} of {attempts}) and was"
            f" repeated after {delay_s} s; its output is in the log (`harness`"
            " warning)\n"
        )


def lost_fetch(detail):
    """True if an `apk update` failure is the lost fetch seen in CI."""
    return APK_UPDATE_TRANSIENT in detail


def apk_update(
    vm_ssh,
    timeout,
    attempts=APK_UPDATE_ATTEMPTS,
    delay_s=APK_UPDATE_DELAY,
    sleep=None,
):
    """Run `apk update` in the VM, repeated only when a fetch was lost.

    The first `apk update` after the network came up can lose one of its
    parallel fetches: stderr has `wget: Failed to send request: Operation not
    permitted` and stdout `1 unavailable, 0 stale` (see conftest.py, F3). Only
    that error is repeated (the command only refreshes indexes, so it is
    safe); any other failure (signature, 404, ...) is final at once, because
    `unavailable` alone is also what a missing file prints. After the last
    failed attempt, or at a final one, the assertion carries the output of
    every attempt made.
    """

    def once():
        out, err, rc = vm_ssh.run("apk update", timeout=timeout)
        return rc == 0, f"rc={rc}; stdout: {out}; stderr: {err}"

    ok, details = retry(
        once,
        attempts,
        delay_s,
        "apk update",
        sleep=sleep,
        transient=lost_fetch,
        on_retry=summary_note,
    )
    if len(details) == attempts:
        outcome = f"in each of {attempts} attempts"
    else:
        outcome = f"on attempt {len(details)} (not a lost fetch, not repeated)"
    assert ok, f"apk update failed {outcome}:\n" + "\n".join(
        f"  attempt {n}: {d}" for n, d in enumerate(details, 1)
    )
