"""Spike checks for aparcar/openwrt-tests: boot, internet, local .apk install.

Environment variables:
  SPIKE_RELEASE      expected DISTRIB_RELEASE (e.g. 25.12.6)
  SPIKE_APK          host path of the .apk to install in the VM
  SPIKE_APK_BIN      command that prints the package version (e.g. "netbird version")
  SPIKE_APK_VERSION  expected first line printed by SPIKE_APK_BIN
"""

import os


def test_boot_release(shell_command):
    out = shell_command.run_check("cat /etc/openwrt_release")
    assert f"DISTRIB_RELEASE='{os.environ['SPIKE_RELEASE']}'" in out


def test_internet(ssh_command):
    ssh_command.run_check("apk update")


def test_install_local_apk(ssh_command):
    ssh_command.put(os.environ["SPIKE_APK"], "/tmp/spike.apk")
    ssh_command.run_check("apk add --allow-untrusted /tmp/spike.apk")
    out = ssh_command.run_check(os.environ["SPIKE_APK_BIN"])
    assert out[0].strip() == os.environ["SPIKE_APK_VERSION"]
