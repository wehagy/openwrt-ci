# openwrt-ci

Generic OpenWrt package CI: build a package with the official SDK and test it
in QEMU. Image builds and upstream pull requests are planned.

## Status

| Done                                                                  | Pending                                           |
|-----------------------------------------------------------------------|---------------------------------------------------|
| SDK build (`build.yml`) on lines `25.12` and `main`, 5 architectures  | QEMU images and tests for line `main` (slice P1b) |
| QEMU test (`test.yml`) on line `25.12`, sources `feed` and `artifact` | QEMU target for `mips_24kc` (`malta-be`)          |
| `ci.yml`: build both lines, then test the `25.12` build               | NetBird runtime tests                             |
|                                                                       | Image build                                       |
|                                                                       | Upstream PR automation and upstream PR testing    |

## Layout

- `harness/`
  - `lines.yml`: per-line data. `25.12` has all keys; `main` has only the
    build keys (`sdk_tag_suffix`, `packages_branch`, `imagebuilder_tag_suffix`),
    so `scripts/resolve.sh` fails for `main` until P1b.
  - `targets.yml`: per-QEMU-target data (`x86-64`, `armsr-armv8`, `malta-le`),
    image names only for `25.12`.
  - `tests/`: pytest tests run inside the VMs through
    [aparcar/openwrt-tests](https://github.com/aparcar/openwrt-tests).
  - `openwrt-tests.uv.lock`: pinned Python environment of those tests.
- `scripts/` (POSIX shell, used by the workflows)
  - Build: `resolve-build.sh`, `collect-apk.sh`, `build-summary.sh`.
  - Test: `validate-inputs.sh`, `matrix.sh`, `resolve.sh`, `fetch-image.sh`,
    `fetch-package.sh`, `prepare-target.sh`, `summary.sh`.
  - `lib/common.sh`: shared helpers.
- `.github/workflows/`
  - `build.yml`: reusable SDK build.
  - `test.yml`: reusable QEMU test.
  - `ci.yml`: caller, runs on push to `feat/**`.

## Reusable workflow `build.yml`

Inputs (both required):

| Input     | Meaning                                                    | Accepted                              |
|-----------|------------------------------------------------------------|---------------------------------------|
| `line`    | OpenWrt line, a key of `harness/lines.yml` with build keys | `25.12` or `main`                     |
| `package` | package to build, a directory of `openwrt/packages`        | `[a-z0-9][a-z0-9._+-]*`, <= 128 chars |

- One job per architecture: `x86_64`, `aarch64_generic`, `aarch64_cortex-a53`,
  `mipsel_24kc`, `mips_24kc` (`fail-fast: false`).
- `scripts/resolve-build.sh` validates the inputs and reads `sdk_tag_suffix`
  and `packages_branch` from `lines.yml`.
  - SDK image: `docker.io/openwrt/sdk:<arch>-<sdk_tag_suffix>`.
  - Feed branch of `openwrt/packages`: `openwrt-25.12` for `25.12`, `master`
    for `main`.
- The full `openwrt/packages` tree is checked out (Go packages include
  `lang/golang` by relative path), then built with `openwrt/gh-action-sdk`
  pinned to commit `f5813d30`.
- `scripts/collect-apk.sh` takes the one `<package>-<version>.apk` of the SDK
  output (none or several fail the job).
- The job summary (`scripts/build-summary.sh`) lists line, arch, SDK image and
  digest, `openwrt/packages` branch and commit, package version and build
  duration.
- Artifact: `apk-<package>-<line>-<arch>` (the `.apk` alone).

## Reusable workflow `test.yml`

Inputs (all required, all validated by `scripts/validate-inputs.sh` before
use; an invalid value fails the run):

| Input     | Meaning                                    | Accepted                              |
|-----------|--------------------------------------------|---------------------------------------|
| `line`    | OpenWrt line, a key of `harness/lines.yml` | `main` or `NN.NN` (only `25.12` has QEMU data today) |
| `package` | package name to install and check          | `[a-z0-9][a-z0-9._+-]*`, <= 128 chars |
| `source`  | where the `.apk` comes from                | `feed` (official release feed) or `artifact` (`apk-<package>-<line>-<arch>` from `build.yml` in the same workflow run) |

- One job per target of `harness/targets.yml` that has an image for the line
  (`x86-64`, `armsr-armv8`, `malta-le`). Each job downloads the latest stable
  release image of the line, verifies its sha256, boots it in QEMU, gets the
  `.apk` (`scripts/fetch-package.sh`) and runs `harness/tests/test_package.py`.
- With `source: artifact`, a target uses the artifact of its `arch` in
  `targets.yml` (`x86_64`, `aarch64_generic`, `mipsel_24kc`).
  `aarch64_cortex-a53` and `mips_24kc` are built but not tested yet.
- Tests: install, `apk` reports the expected version, and every `/etc/init.d`
  script the package installs is a procd script whose instances all stay
  running with constant pids for 10 s. The service test is skipped only when
  the package installs no init script. The job summary lists passed, failed
  and skipped per test.

## Caller `ci.yml`

On push to `feat/**`, for package `netbird`:

| Job           | Calls       | Inputs                            | Needs         |
|---------------|-------------|-----------------------------------|---------------|
| `build-25-12` | `build.yml` | `line: 25.12`                     |               |
| `build-main`  | `build.yml` | `line: main`                      |               |
| `test-25-12`  | `test.yml`  | `line: 25.12`, `source: artifact` | `build-25-12` |

Line `main` is only built: it has no QEMU images until P1b.

## Artifacts

| Name                                  | From        | Content                        |
|---------------------------------------|-------------|--------------------------------|
| `apk-<package>-<line>-<arch>`         | `build.yml` | the built `.apk`               |
| `qemu-<package>-<line>-<target>`      | `test.yml`  | `results.xml` (junit)          |
| `qemu-<package>-<line>-<target>-logs` | `test.yml`  | labgrid logs, `pip-freeze.txt` |

## Adding a package

Only what the code supports today:

- Build and test a package of `openwrt/packages`: call `build.yml` with `line`
  and `package`, then `test.yml` with the same `line` and `package`,
  `source: artifact` and `needs:` the build job. `ci.yml` does this for
  `netbird`.
- Test a package of the official release feed without building it: call
  `test.yml` with `source: feed`.
- `harness/tests/test_package.py` is generic: no per-package code or data.
  Package-specific runtime tests do not exist yet.
- Packages outside `openwrt/packages` (local feeds, upstream PRs) are not
  supported yet.

## Pinned test environment

The `openwrt-tests` checkout is pinned to `OPENWRT_TESTS_REF` in `test.yml`.
Its Python environment is pinned by `harness/openwrt-tests.uv.lock` (Python
3.15, labgrid at a fixed commit) and installed with `uv sync --locked`, so the
job fails if the lock no longer matches that `pyproject.toml`. To regenerate
after changing the ref, copy the `pyproject.toml` of the new ref to an empty
directory, run `uv lock --python 3.15` there and copy `uv.lock` to
`harness/openwrt-tests.uv.lock`.
