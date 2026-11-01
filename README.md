# openwrt-ci

Generic OpenWrt package CI: build packages, test them in QEMU, build images
and open upstream pull requests. Two OpenWrt lines are covered: `main`
(snapshots) and `25.12` (stable).

- `harness/`: per-line and per-QEMU-target data, plus the pytest tests that
  run inside the VMs through [aparcar/openwrt-tests](https://github.com/aparcar/openwrt-tests).
- `scripts/`: POSIX shell steps used by the workflows (resolve, fetch, prepare).
- `.github/workflows/test.yml`: reusable QEMU test workflow.
- `.github/workflows/ci.yml`: caller that tests a package on push.

Status: only line `25.12` and the `feed` package source are implemented.
