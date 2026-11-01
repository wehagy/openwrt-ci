"""Network diagnostics for the spike: why apk/uclient-fetch fail with EPERM.

Records facts as junit properties (results.xml) and never fails, so the other
spike tests still run on the same VM.

Findings of run 41354702952:
  - IPv6 fetches fail 10/10 with EPERM on every target (runner has no IPv6
    egress); downloads.openwrt.org has an AAAA record.
  - malta-le has no wan interface at all (no default route, empty resolv).
  - 8 parallel fetches x3 all passed on x86-64 and armsr (concurrency ruled out).

This version measures `apk update` before and after the CI fixes:
  F1 dnsmasq filter_aaaa=1 (IPv4 only, like the runner);
  F2 create wan (dhcp on eth1) when the image has none.
"""

URL = "https://downloads.openwrt.org/releases/25.12.6/targets/"
TRIES = 10
APK_TRIES = 5
CMD_TIMEOUT = 600


def _sh(ssh, cmd):
    out, err, rc = ssh.run(cmd, timeout=CMD_TIMEOUT)
    return f"rc={rc}\n" + "\n".join(out + err)


def _count(ssh, flag):
    script = (
        f"rm -f /tmp/fetch.err; ok=0; fail=0; for i in $(seq {TRIES}); do "
        f"if uclient-fetch {flag} -q -O /dev/null {URL} 2>>/tmp/fetch.err; "
        "then ok=$((ok+1)); else fail=$((fail+1)); fi; done; "
        "echo ok=$ok fail=$fail; sort /tmp/fetch.err | uniq -c"
    )
    return _sh(ssh, script)


def _apk_updates(ssh):
    script = (
        f"rm -f /tmp/apk.err; ok=0; fail=0; for i in $(seq {APK_TRIES}); do "
        "if apk update >/dev/null 2>>/tmp/apk.err; "
        "then ok=$((ok+1)); else fail=$((fail+1)); fi; done; "
        "echo ok=$ok fail=$fail; sort /tmp/apk.err | uniq -c | sort -rn | head"
    )
    return _sh(ssh, script)


def test_netdiag(ssh_command, record_property):
    ssh = ssh_command
    record_property("ip_addr", _sh(ssh, "ip addr"))
    record_property("ip_route", _sh(ssh, "ip route; ip -6 route"))
    record_property("uci_network", _sh(ssh, "uci show network"))
    record_property(
        "board_network", _sh(ssh, "jsonfilter -i /etc/board.json -e @.network")
    )
    record_property("nslookup", _sh(ssh, "nslookup downloads.openwrt.org"))
    record_property("fetch_default", _count(ssh, ""))
    record_property("fetch_v4", _count(ssh, "-4"))
    record_property("fetch_v6", _count(ssh, "-6"))
    record_property("apk_before", _apk_updates(ssh))

    # F2: some images (malta) ship without a wan interface.
    fix_wan = (
        "if ubus call network.interface.wan status >/dev/null 2>&1; "
        "then echo wan-present; else "
        "uci set network.wan=interface; uci set network.wan.device=eth1; "
        "uci set network.wan.proto=dhcp; uci commit network; "
        "/etc/init.d/network reload; sleep 10; echo wan-created; fi"
    )
    record_property("fix_wan", _sh(ssh, fix_wan))
    # F1: the runner has no IPv6 egress; answer only A records.
    fix_aaaa = (
        "uci set dhcp.@dnsmasq[0].filter_aaaa=1; uci commit dhcp; "
        "/etc/init.d/dnsmasq restart; sleep 3; echo done"
    )
    record_property("fix_aaaa", _sh(ssh, fix_aaaa))
    record_property("ip_route_after", _sh(ssh, "ip route"))
    record_property("nslookup_after", _sh(ssh, "nslookup downloads.openwrt.org"))
    record_property("fetch_default_after", _count(ssh, ""))
    record_property("apk_after", _apk_updates(ssh))
