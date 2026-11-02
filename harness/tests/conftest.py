"""CI network setup for the QEMU VM, applied once per pytest session.

Copied into openwrt-tests/tests/ext/ at run time, so it is picked up as a
directory conftest without modifying any openwrt-tests file. It reuses the
session fixtures `strategy` and `target` (labgrid) and `setup_env`
(openwrt-tests/tests/conftest.py).

CI environment fixes, measured in the spike (runs 41354702952 and later):
  F1  The runner has no IPv6 egress but downloads.openwrt.org has an AAAA
      record, so fetches that pick IPv6 fail with EPERM. dnsmasq therefore
      filters AAAA answers.
  F2  Some images define only lan (malta-le 25.12, and malta-be on both
      lines, run 41376283543); without a wan interface the VM has no default
      route. wan is created (dhcp on eth1) if the configuration has none.
      The malta-le snapshot image already has one and is left alone. The
      decision reads the uci configuration, not the runtime state: netifd
      may not have loaded an existing wan yet.

After F1 and F2 the setup waits until the VM resolves an A record for
downloads.openwrt.org and has a default route, so the tests start from a
network that works.

  F3  Right after the route appears, one of the parallel fetches of the first
      `apk update` can fail with `wget: Failed to send request: Operation not
      permitted` while the others succeed (malta-le and malta-be, runs
      41427983225 and 41360955048; a different repository each time, so not
      a missing file). The route and the name resolve already, so the wait
      above cannot see it; the cause inside the VM was not proven. `apk
      update` only refreshes the indexes, so it is repeated a bounded number
      of times, but only when stderr has that error; any other failure
      (signature, 404, ...) fails at once. Every repeat is logged and noted
      in the job summary; the final failure fails the session with the
      output of all attempts made.
"""

import re

import pytest
from harness_util import apk_update, poll

CMD_TIMEOUT = 600
# Every command of a poll is short; a hung ssh must not outlive the deadline.
QUERY_TIMEOUT = 30
NETWORK_TIMEOUT = 120
DNS_NAME = "downloads.openwrt.org"
IPV4 = re.compile(r"\b\d{1,3}(?:\.\d{1,3}){3}\b")


@pytest.fixture(scope="session")
def vm_ssh(setup_env, strategy, target):
    """SSH driver of the booted VM (session scope, unlike ssh_command)."""
    strategy.transition("shell")
    return target.get_driver("SSHDriver")


@pytest.fixture(scope="session", autouse=True)
def ci_network(vm_ssh):
    """Apply F1 and F2, then wait for a default route and a working apk."""
    vm_ssh.run_check(
        "uci set dhcp.@dnsmasq[0].filter_aaaa=1"
        " && uci commit dhcp && /etc/init.d/dnsmasq restart",
        timeout=CMD_TIMEOUT,
    )

    # rc 0: wan is configured (leave it alone); rc 1: no such section.
    _, _, rc = vm_ssh.run("uci -q get network.wan", timeout=QUERY_TIMEOUT)
    assert rc in (0, 1), f"uci -q get network.wan failed with {rc}"
    if rc == 1:
        vm_ssh.run_check(
            "uci set network.wan=interface"
            " && uci set network.wan.device=eth1"
            " && uci set network.wan.proto=dhcp"
            " && uci commit network && /etc/init.d/network reload",
            timeout=CMD_TIMEOUT,
        )

    def has_default_route():
        # BusyBox `ip route show default` does not filter, so match here.
        out, _, _ = vm_ssh.run("ip route", timeout=QUERY_TIMEOUT)
        return any(line.startswith("default ") for line in out), out

    def resolves_a_record():
        # BusyBox nslookup prints the server first, then "Name:" followed by
        # the answers; only an IPv4 address after "Name:" is an A record.
        out, _, _ = vm_ssh.run(f"nslookup {DNS_NAME}", timeout=QUERY_TIMEOUT)
        after_name = False
        found = False
        for line in out:
            if line.strip().startswith("Name:"):
                after_name = True
            elif after_name and "Address" in line:
                found = found or bool(IPV4.search(line))
        return found, out

    def network_works():
        route_ok, route = has_default_route()
        dns_ok, dns = resolves_a_record()
        return (
            route_ok and dns_ok,
            f"default route: {route_ok} {route}; dns: {dns_ok} {dns}",
        )

    ok, detail = poll(network_works, NETWORK_TIMEOUT)
    assert ok, (
        f"network not ready after {NETWORK_TIMEOUT} s (needs a default route"
        f" and an A record for {DNS_NAME}): {detail}"
    )

    apk_update(vm_ssh, CMD_TIMEOUT)
