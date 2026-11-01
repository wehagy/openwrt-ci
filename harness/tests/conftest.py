"""CI network setup for the QEMU VM, applied once per pytest session.

Copied into openwrt-tests/tests/ext/ at run time, so it is picked up as a
directory conftest without modifying any openwrt-tests file. It reuses the
session fixtures `strategy` and `target` (labgrid) and `setup_env`
(openwrt-tests/tests/conftest.py).

CI environment fixes, measured in the spike (runs 41354702952 and later):
  F1  The runner has no IPv6 egress but downloads.openwrt.org has an AAAA
      record, so fetches that pick IPv6 fail with EPERM. dnsmasq therefore
      filters AAAA answers.
  F2  malta-le 25.12 board.json defines only lan; without a wan interface
      the VM has no default route. wan is created (dhcp on eth1) if missing.
"""

import pytest
from harness_util import poll

CMD_TIMEOUT = 600
NETWORK_TIMEOUT = 120


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

    _, _, rc = vm_ssh.run("ubus call network.interface.wan status")
    if rc != 0:
        vm_ssh.run_check(
            "uci set network.wan=interface"
            " && uci set network.wan.device=eth1"
            " && uci set network.wan.proto=dhcp"
            " && uci commit network && /etc/init.d/network reload",
            timeout=CMD_TIMEOUT,
        )

    def has_default_route():
        out, _, _ = vm_ssh.run("ip route show default")
        return bool(out), out

    ok, detail = poll(has_default_route, NETWORK_TIMEOUT)
    assert ok, f"no default route after {NETWORK_TIMEOUT} s: {detail}"

    vm_ssh.run_check("apk update", timeout=CMD_TIMEOUT)
