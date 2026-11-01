# openwrt-ci

Generic OpenWrt package CI: test packages in QEMU today; build packages,
build images and open upstream pull requests are planned.

Status: only the OpenWrt line `25.12` (stable) and the `feed` package source
exist. The `main` line (snapshots) is pending slice P1b; the SDK build,
image build and pull request steps are not implemented.

- `harness/`: per-line and per-QEMU-target data (`lines.yml`, `targets.yml`),
  the pytest tests that run inside the VMs through
  [aparcar/openwrt-tests](https://github.com/aparcar/openwrt-tests), and
  `openwrt-tests.uv.lock`.
- `scripts/`: POSIX shell steps used by the workflows (validate-inputs,
  matrix, resolve, fetch-image, fetch-package, prepare-target, summary).
- `.github/workflows/test.yml`: reusable QEMU test workflow.
- `.github/workflows/ci.yml`: caller that tests a package on push to `feat/**`.

## Reusable workflow `test.yml`

Inputs (all required, all validated before use; an invalid value fails the
run):

| Input     | Meaning                                    | Accepted                           |
|-----------|--------------------------------------------|------------------------------------|
| `line`    | OpenWrt line, a key of `harness/lines.yml` | `main` or `NN.NN` (only `25.12` is defined today) |
| `package` | package name to install and check          | `[a-z0-9][a-z0-9._+-]*`, <= 128 chars |
| `source`  | where the `.apk` comes from                | `feed` (official release feed)     |

One job per target of `harness/targets.yml` that has an image for the line
(`x86-64`, `armsr-armv8`, `malta-le`). Each job downloads the latest stable
release image of the line, verifies its sha256, boots it in QEMU, installs the
package and runs `harness/tests/test_package.py`: install, `apk` reports the
expected version, and every `/etc/init.d` script the package installs is a
procd script whose instances all stay running with constant pids for 10 s.
The service test is skipped only when the package installs no init script. The
job summary lists passed, failed and skipped per test.

Artifacts per job: `qemu-<package>-<line>-<target>` (`results.xml`) and
`qemu-<package>-<line>-<target>-logs` (labgrid logs, `pip-freeze.txt`).

## Pinned test environment

The `openwrt-tests` checkout is pinned to `OPENWRT_TESTS_REF` in `test.yml`.
Its Python environment is pinned by `harness/openwrt-tests.uv.lock` (Python
3.13, labgrid at a fixed commit) and installed with `uv sync --locked`, so the
job fails if the lock no longer matches that `pyproject.toml`. To regenerate
after changing the ref, copy the `pyproject.toml` of the new ref to an empty
directory, run `uv lock --python 3.13` there and copy `uv.lock` to
`harness/openwrt-tests.uv.lock`.
