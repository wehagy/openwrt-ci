"""Generic package test: works for any package, no per-package code.

Checks that the .apk installs, that apk reports it installed, and that the
services it ships are running. Every /etc/init.d/ script the package installs
must be a procd script. After a start, at least one instance must be running
and every running instance must keep its pid for a stable window; an instance
that is not running passes only if it exited with exit_code 0 (a one-shot);
anything else fails (harness_util.judge_instances). The service check is
skipped only for a package that installs no init script and for the scripts the
caller declares disabled by default (HARNESS_SERVICES_DISABLED). Records the package version, the line
and the image used as junit properties.

Environment variables:
  HARNESS_APK              host path of the .apk to install in the VM
  HARNESS_PACKAGE          package name
  HARNESS_PACKAGE_VERSION  version as in the feed, e.g. 0.78.1-r1
  HARNESS_LINE             OpenWrt line, e.g. 25.12
  HARNESS_RELEASE          release or snapshot version of the image, e.g. 25.12.6
                           or r37969-5799d2da76
  HARNESS_IMAGE_URL        URL of the image
  HARNESS_IMAGE_SHA256     sha256 of the downloaded image file
  HARNESS_SERVICES_DISABLED  optional; init scripts that are disabled by default
                           in the package (separated by spaces or commas)
"""

import re
import shlex
import time

import pytest
from harness_util import (
    LOG,
    apk_timeout_kwargs,
    disabled_services,
    env,
    poll,
    service_sampler,
    split_disabled,
)

# Emulated targets are slow; labgrid's run_check default is 30 s.
CMD_TIMEOUT = 600
# Queries and poll samples are short; a hung ssh must not outlive a deadline.
QUERY_TIMEOUT = 30
# The apk commands in the VM have no timeout of ours: labgrid's default applies
# (SSHDriver.run has none) unless the caller sets `apk_timeout` in test.yml, see
# apk_timeout_kwargs(). The duration of `apk info -L` is logged and recorded
# (apk_info_L_seconds) in every job.
SERVICE_TIMEOUT = 60
# procd reports an instance running right after the fork, before a missing
# binary makes exec fail; only a state that holds counts.
SERVICE_STABLE = 10
REMOTE_APK = "/tmp/package-under-test.apk"
INIT_SCRIPT = re.compile(r"^/?etc/init\.d/([^/\s]+)$")
# USE_PROCD=1, "1" or '1' on its own line (comment allowed).
PROCD_LINE = r"^[[:space:]]*USE_PROCD=(1|\"1\"|'1')[[:space:]]*(#.*)?$"


@pytest.fixture(scope="module")
def package():
    return env("HARNESS_PACKAGE")


@pytest.fixture(scope="module")
def install(vm_ssh):
    """Install the .apk once; the tests assert on the recorded result."""
    vm_ssh.put(env("HARNESS_APK"), REMOTE_APK)
    # initramfs targets have no persistent overlay, so apk refuses a local
    # file unless --force-non-repository is given.
    out, err, rc = vm_ssh.run(
        f"apk add --allow-untrusted --force-non-repository {REMOTE_APK}",
        timeout=CMD_TIMEOUT,
    )
    return {"out": out, "err": err, "rc": rc}


def _init_scripts(vm_ssh, package):
    """Names of the init scripts the package installed under /etc/init.d/.

    `apk info -L` prints "<name>-<version> contains:" and then one path per
    line. The header is required, so a changed output format or a failed
    listing fails the test instead of looking like a package without scripts.
    """
    start = time.monotonic()
    out, err, rc = vm_ssh.run(f"apk info -L {package}", **apk_timeout_kwargs())
    seconds = time.monotonic() - start
    LOG.info("harness: apk info -L %s took %.1f s", package, seconds)
    assert rc == 0, f"apk info -L {package} failed with {rc}: {err}"
    lines = [line.strip() for line in out if line.strip()]
    header = re.compile(rf"^{re.escape(package)}-\S+ contains:$")
    assert lines and header.match(lines[0]), (
        f"unexpected `apk info -L {package}` output (no 'contains:' header): {out}"
    )
    return [m.group(1) for line in lines[1:] if (m := INIT_SCRIPT.match(line))], seconds


def _is_procd(vm_ssh, name):
    """True for a procd script, False for another one; fails if unreadable."""
    path = f"/etc/init.d/{name}"
    _, err, rc = vm_ssh.run(
        f"grep -Eq {shlex.quote(PROCD_LINE)} {path}", timeout=QUERY_TIMEOUT
    )
    # grep: 0 match, 1 no match, 2 error (e.g. the file is missing).
    assert rc in (0, 1), f"cannot read {path} (grep rc={rc}): {err}"
    return rc == 0


def test_install_package(install):
    detail = "\n".join(install["out"] + install["err"])
    assert install["rc"] == 0, f"apk add failed with {install['rc']}:\n{detail}"


def test_package_is_installed(install, vm_ssh, package, record_property):
    _, _, rc = vm_ssh.run(f"apk info -e {package}", **apk_timeout_kwargs())
    assert rc == 0, f"apk info -e {package} failed with {rc}"

    out, _, rc = vm_ssh.run(f"apk list -I {package}", **apk_timeout_kwargs())
    assert rc == 0, f"apk list -I {package} failed with {rc}"
    # `apk list -I <glob>` may list several packages; pick the exact name:
    # "<package>-<version>" where the version starts with a digit.
    exact = re.compile(rf"^{re.escape(package)}-(\d\S*)$")
    names = [line.split()[0] for line in out if line.split()]
    matches = [name for name in names if exact.match(name)]
    assert len(matches) == 1, f"expected one {package} entry in {names!r}"
    installed = matches[0]
    expected = f"{package}-{env('HARNESS_PACKAGE_VERSION')}"
    assert installed == expected, f"installed {installed!r}, expected {expected!r}"

    record_property("package", package)
    record_property("package_version", installed.removeprefix(f"{package}-"))
    record_property("line", env("HARNESS_LINE"))
    record_property("openwrt_release", env("HARNESS_RELEASE"))
    record_property("image_url", env("HARNESS_IMAGE_URL"))
    record_property("image_sha256", env("HARNESS_IMAGE_SHA256"))


def test_services_running(install, vm_ssh, package, record_property):
    names, seconds = _init_scripts(vm_ssh, package)
    record_property("apk_info_L_seconds", f"{seconds:.1f}")
    if not names:
        pytest.skip(f"{package} installs no /etc/init.d script, nothing to check")

    names, disabled = split_disabled(package, names, disabled_services())
    for name in disabled:
        LOG.warning("harness: service %s skipped, declared disabled by default", name)
        record_property(f"service_{name}", "skipped: disabled by default")
    if not names:
        pytest.skip(
            f"every init script of {package} is declared disabled by default"
            f" ({', '.join(disabled)}), nothing to check"
        )

    failures = [
        f"/etc/init.d/{name} is not a procd script (no USE_PROCD=1)"
        for name in names
        if not _is_procd(vm_ssh, name)
    ]
    assert not failures, "\n".join(failures)

    for name in names:
        # The install may have started the service; stop it first so the check
        # proves a fresh start works. The stop status is not checked (the
        # service may not be running); the start status is.
        vm_ssh.run(f"/etc/init.d/{name} stop", timeout=CMD_TIMEOUT)
        _, _, start_rc = vm_ssh.run(f"/etc/init.d/{name} start", timeout=CMD_TIMEOUT)
        if start_rc != 0:
            failures.append(f"service {name} start failed with rc={start_rc}")
            continue
        ok, detail = poll(
            service_sampler(vm_ssh, name, QUERY_TIMEOUT),
            SERVICE_TIMEOUT,
            stable_s=SERVICE_STABLE,
        )
        if not ok:
            failures.append(
                f"service {name}: not healthy and stable for {SERVICE_STABLE} s"
                f" (waited {SERVICE_TIMEOUT} s): {detail}"
            )
    assert not failures, "\n".join(failures)
