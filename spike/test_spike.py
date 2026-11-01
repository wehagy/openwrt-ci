"""Spike checks for aparcar/openwrt-tests: boot, internet, local .apk install.

Environment variables:
  SPIKE_RELEASE      expected DISTRIB_RELEASE (e.g. 25.12.6)
  SPIKE_APK          host path of the .apk to install in the VM
  SPIKE_APK_BIN      command that prints the package version (e.g. "netbird version")
  SPIKE_APK_VERSION  expected first line printed by SPIKE_APK_BIN
"""

import os

# Emulated (TCG) targets need minutes for apk and Go binaries; labgrid's
# run_check default is 30 s.
CMD_TIMEOUT = 600


def test_boot_release(shell_command):
    out = shell_command.run_check("cat /etc/openwrt_release")
    # Diagnostic only: memory and tmpfs headroom land in the console log.
    shell_command.run("free -m; df -h / /tmp")
    assert f"DISTRIB_RELEASE='{os.environ['SPIKE_RELEASE']}'" in out


def test_internet(ssh_command):
    ssh_command.run_check("apk update", timeout=CMD_TIMEOUT)


def test_install_local_apk(ssh_command):
    ssh_command.put(os.environ["SPIKE_APK"], "/tmp/spike.apk")
    # initramfs targets have no persistent overlay, so apk refuses a local file
    # unless --force-non-repository is given.
    ssh_command.run_check(
        "apk add --allow-untrusted --force-non-repository /tmp/spike.apk",
        timeout=CMD_TIMEOUT,
    )
    out = ssh_command.run_check(os.environ["SPIKE_APK_BIN"], timeout=CMD_TIMEOUT)
    assert out[0].strip() == os.environ["SPIKE_APK_VERSION"]
