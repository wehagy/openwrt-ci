"""Network diagnostics for the spike: why apk/uclient-fetch fail with EPERM.

Records facts as junit properties (results.xml) and never fails, so the other
spike tests still run on the same VM. Hypotheses measured:
  H1 IPv6: the VM gets an IPv6 route via QEMU user networking, but the runner
     has no IPv6 egress; fetches that pick an AAAA address fail.
  H2 concurrency: apk fetches several indexes at once; parallel TLS fetches
     fail where sequential ones succeed.
"""

URL = "https://downloads.openwrt.org/releases/25.12.6/targets/"
TRIES = 10
CMD_TIMEOUT = 600


def _sh(ssh, cmd):
    out, err, rc = ssh.run(cmd, timeout=CMD_TIMEOUT)
    return f"rc={rc}\n" + "\n".join(out + err)


def _count(ssh, flag):
    script = (
        f"ok=0; fail=0; for i in $(seq {TRIES}); do "
        f"if uclient-fetch {flag} -q -O /dev/null {URL} 2>>/tmp/fetch{flag}.err; "
        "then ok=$((ok+1)); else fail=$((fail+1)); fi; done; "
        f"echo ok=$ok fail=$fail; sort /tmp/fetch{flag}.err | uniq -c"
    )
    return _sh(ssh, script)


def test_netdiag(ssh_command, record_property):
    ssh = ssh_command
    record_property("ip_addr", _sh(ssh, "ip -br addr"))
    record_property("ip_route", _sh(ssh, "ip route; ip -6 route"))
    record_property("resolv", _sh(ssh, "cat /tmp/resolv.conf.d/resolv.conf.auto"))
    record_property("nslookup", _sh(ssh, "nslookup downloads.openwrt.org"))
    record_property("fetch_default", _count(ssh, ""))
    record_property("fetch_v4", _count(ssh, "-4"))
    record_property("fetch_v6", _count(ssh, "-6"))
    parallel = (
        "for r in 1 2 3; do for i in 1 2 3 4 5 6 7 8; do "
        f"(uclient-fetch -q -O /dev/null {URL} && echo ok || echo fail) & done; "
        "wait; done 2>&1 | sort | uniq -c"
    )
    record_property("fetch_parallel_8x3", _sh(ssh, parallel))
    record_property("nft_output", _sh(ssh, "nft list chain inet fw4 output"))
    record_property("logread", _sh(ssh, "logread | tail -n 40"))
