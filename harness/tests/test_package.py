"""Generic package test: works for any package, no per-package code.

Checks that the .apk installs, that apk reports it installed, and that every
procd init script the package ships under /etc/init.d/ starts a running
service instance. Records the package version, the line and the image used
as junit properties.

Environment variables:
  HARNESS_APK              host path of the .apk to install in the VM
  HARNESS_PACKAGE          package name
  HARNESS_PACKAGE_VERSION  version as in the feed, e.g. 0.78.1-r1
  HARNESS_LINE             OpenWrt line, e.g. 25.12
  HARNESS_RELEASE          OpenWrt release of the image, e.g. 25.12.6
  HARNESS_IMAGE_URL        URL of the image
  HARNESS_IMAGE_SHA256     sha256 of the downloaded image file
"""

import json
import os
import re

import pytest
from harness_util import env, poll

# Emulated targets are slow; labgrid's run_check default is 30 s.
CMD_TIMEOUT = 600
SERVICE_TIMEOUT = 60
# procd reports an instance running right after the fork, before a missing
# binary makes exec fail; only a state that holds counts.
SERVICE_STABLE = 10
REMOTE_APK = "/tmp/package-under-test.apk"
INIT_SCRIPT = re.compile(r"^/?etc/init\.d/([^/\s]+)$")


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
    """Names of the init scripts the package installed under /etc/init.d/."""
    out, _, rc = vm_ssh.run(f"apk info -L {package}")
    assert rc == 0, f"apk info -L {package} failed with {rc}"
    return [m.group(1) for line in out if (m := INIT_SCRIPT.match(line.strip()))]


def _is_procd(vm_ssh, name):
    _, _, rc = vm_ssh.run(f"grep -q '^USE_PROCD=1' /etc/init.d/{name}")
    return rc == 0


def _service_running(vm_ssh, name):
    """(running, detail): any instance of the service reported as running."""
    query = json.dumps({"name": name})
    out, _, rc = vm_ssh.run(f"ubus call service list '{query}'")
    detail = "\n".join(out)
    if rc != 0:
        return False, f"ubus rc={rc}: {detail}"
    try:
        services = json.loads(detail)
    except json.JSONDecodeError:
        return False, f"unparsable ubus output: {detail}"
    instances = services.get(name, {}).get("instances", {})
    return any(i.get("running") for i in instances.values()), detail


def test_install_package(install):
    detail = "\n".join(install["out"] + install["err"])
    assert install["rc"] == 0, f"apk add failed with {install['rc']}:\n{detail}"


def test_package_is_installed(install, vm_ssh, package, record_property):
    _, _, rc = vm_ssh.run(f"apk info -e {package}")
    assert rc == 0, f"apk info -e {package} failed with {rc}"

    out, _, rc = vm_ssh.run(f"apk list -I {package}")
    assert rc == 0, f"apk list -I {package} failed with {rc}"
    installed = out[0].split()[0] if out else ""
    expected = f"{package}-{env('HARNESS_PACKAGE_VERSION')}"
    assert installed == expected, f"installed {installed!r}, expected {expected!r}"

    record_property("package", package)
    record_property("package_version", installed.removeprefix(f"{package}-"))
    record_property("line", env("HARNESS_LINE"))
    record_property("openwrt_release", env("HARNESS_RELEASE"))
    record_property("image_url", env("HARNESS_IMAGE_URL"))
    record_property("image_sha256", env("HARNESS_IMAGE_SHA256"))


def test_services_running(install, vm_ssh, package):
    scripts = [s for s in _init_scripts(vm_ssh, package) if _is_procd(vm_ssh, s)]
    if not scripts:
        pytest.skip(f"{package} ships no procd init script")

    if os.environ.get("HARNESS_SABOTAGE_DELETE_BINARY"):
        out, _, _ = vm_ssh.run(f"apk info -L {package}")
        for line in out:
            if re.match(r"^/?usr/s?bin/", line.strip()):
                vm_ssh.run_check(f"rm -f /{line.strip().lstrip('/')}")

    failures = []
    for name in scripts:
        # apk may already have started the service; restart it so the check
        # proves it can start, not that an old process survived.
        vm_ssh.run(f"/etc/init.d/{name} stop", timeout=CMD_TIMEOUT)
        _, _, start_rc = vm_ssh.run(f"/etc/init.d/{name} start", timeout=CMD_TIMEOUT)
        ok, detail = poll(
            lambda n=name: _service_running(vm_ssh, n),
            SERVICE_TIMEOUT,
            stable_s=SERVICE_STABLE,
        )
        if not ok:
            failures.append(
                f"service {name} not running (needs {SERVICE_STABLE} s stable,"
                f" waited {SERVICE_TIMEOUT} s)"
                f" (start rc={start_rc}): {detail}"
            )
    assert not failures, "\n".join(failures)
