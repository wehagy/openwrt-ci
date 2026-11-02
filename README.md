# openwrt-ci

Generic OpenWrt package CI: build a package with the official SDK and test it
in QEMU. Image builds and upstream pull requests are planned.

## Status

| Done                                                                              | Pending                                             |
|-----------------------------------------------------------------------------------|-----------------------------------------------------|
| SDK build (`build.yml`) on lines `25.12` and `main`, 5 architectures              | NetBird runtime tests                               |
| Own SDK image on GHCR, rebuilt when older than 1 day or on request                | Scheduled SDK image refresh (none today: lazy only) |
| QEMU test (`test.yml`) on lines `25.12` and `main`, sources `feed` and `artifact` | Image build                                         |
| QEMU targets `x86-64`, `armsr-armv8`, `malta-le`, `malta-be` on both lines        | Upstream PR automation and upstream PR testing      |
| `ci.yml`: build both lines, then test each build                                  |                                                     |

## Layout

- `harness/`
  - `lines.yml`: per-line data. `release_source` selects how the image
    version is found: `releases` (`25.12`: latest `25.12.x` of the releases
    index) or `snapshot` (`main`: the `version.buildinfo` of the target
    directory, e.g. `r37969-5799d2da76`). Both lines also have the build
    keys (`sdk_tag_suffix`, `sdk_max_age_days`, `packages_branch`,
    `imagebuilder_tag_suffix`).
  - `targets.yml`: per-QEMU-target data (`x86-64`, `armsr-armv8`, `malta-le`,
    `malta-be`) and the image name per line.
  - `tests/`: pytest tests run inside the VMs through
    [aparcar/openwrt-tests](https://github.com/aparcar/openwrt-tests).
  - `openwrt-tests.uv.lock`: pinned Python environment of those tests.
- `scripts/` (POSIX shell, used by the workflows)
  - SDK image: `resolve-sdk.sh`, `sdk-age-selftest.sh`,
    `sdk-image-ensure.sh`, `sdk-image-info.sh`.
  - Build: `resolve-build.sh`, `collect-apk.sh`, `build-summary.sh`.
  - Test: `validate-inputs.sh`, `matrix.sh`, `resolve.sh`, `fetch-image.sh`,
    `fetch-package.sh`, `prepare-target.sh`, `summary.sh`.
  - `lib/common.sh`: shared helpers. `lib/ghcr.sh` (registry reads),
    `lib/sdk-age.sh` (age rule and reuse/rebuild decision),
    `lib/sdk-labels.sh` (image label keys).
- `docker/sdk-image/Dockerfile`: derives the SDK image from the official one.
- `.github/workflows/`
  - `build.yml`: reusable SDK build.
  - `test.yml`: reusable QEMU test.
  - `ci.yml`: caller, runs on push to `feat/**`.

## Reusable workflow `build.yml`

Inputs (`line` and `package` required):

| Input     | Meaning                                                    | Accepted                              |
|-----------|------------------------------------------------------------|---------------------------------------|
| `line`    | OpenWrt line, a key of `harness/lines.yml` with build keys | `25.12` or `main`                     |
| `package` | package to build, a directory of `openwrt/packages`        | `[a-z0-9][a-z0-9._+-]*`, <= 128 chars |

Optional input `refresh_sdk` (boolean, default `false`): rebuild the SDK
images of the line even when they are fresh.

The caller must grant `packages: write` to the job that calls `build.yml`
(`ci.yml` does); the workflow itself needs it only in `sdk-image`.

- Two jobs, each one per architecture: `x86_64`, `aarch64_generic`,
  `aarch64_cortex-a53`, `mipsel_24kc`, `mips_24kc` (`fail-fast: false`).
  `sdk` (the build) needs `sdk-image`, which waits for all five architectures.
- The SDK image repository is named once, by the workflow `env`
  `HARNESS_SDK_CONTAINER` (`ghcr.io/<owner>/openwrt-sdk`, the owner of the
  calling repository): `sdk-image` publishes it, `sdk` reads it and passes it
  to the action as `CONTAINER`. `scripts/resolve-sdk.sh` has no default.
- `scripts/resolve-build.sh` validates the inputs and reads `sdk_tag_suffix`,
  `sdk_max_age_days` and `packages_branch` from `lines.yml`.
  - Official SDK container: `docker.io/openwrt/sdk:<arch>-<sdk_tag_suffix>`.
    Snapshot containers ship only `setup.sh`, which downloads the ~280 MB SDK
    from the OpenWrt mirror (13-14 min from the runners).
  - Harness SDK image: `ghcr.io/<owner>/openwrt-sdk:<arch>-<sdk_tag_suffix>`,
    the official container with `setup.sh` already run and removed
    (`docker/sdk-image/Dockerfile`). `openwrt/gh-action-sdk` builds from it
    (`CONTAINER` and `ARCH`), so its entrypoint finds no `setup.sh` and skips
    the download.
  - Feed branch of `openwrt/packages`: `openwrt-25.12` for `25.12`, `master`
    for `main`.
- Job `sdk-image` (`scripts/sdk-image-ensure.sh`), lazy refresh per (line,
  arch):
  - Starts with `scripts/sdk-age-selftest.sh`: fixed timestamps prove the age
    rule and `sdk_decide`, the one function that chooses `reuse` or
    `rebuild` (missing, unreadable creation time, created before the
    `refresh_sdk` request, stale, fresh up to and including
    `sdk_max_age_days`, created in the future), so a wrong comparison or a
    swapped branch fails the job.
  - Age: read from the registry API with `curl`, without pulling: the label
    `org.opencontainers.image.created` in the image config of
    `ghcr.io/<owner>/openwrt-sdk:<tag>`, set to the time just before
    `setup.sh` ran. An unreadable label is rebuilt, which heals it.
  - The image is pushed as one plain image manifest (`--provenance=false
    --sbom=false`): an index with attestation manifests would add untagged
    package versions that the delete of an old version would leave behind,
    and `lib/ghcr.sh` rejects an index.
  - Missing image, age over `sdk_max_age_days` (1 day for both lines) or
    `refresh_sdk`: pull the official container, run `setup.sh` in
    `docker build`, add labels, `docker buildx build --push`.
  - Retention: the superseded image is kept as `<tag>-prev` (current plus one
    previous), so a build that pinned it by digest keeps working. The
    package version that was `<tag>-prev` is deleted (`gh api -X DELETE
    /users/<owner>/packages/container/openwrt-sdk/versions/<id>`; the version
    whose `name` is its manifest digest). The package versions before and
    after the delete are printed in the log.
  - No `concurrency` group: GitHub cancels the older pending job of a group,
    which would cancel the build of a run when 3 runs (or several packages
    of one line) need the same rebuild. Instead the decision is made again
    after the local build, just before the push; a run that finds a fresh
    image pushed meanwhile discards its build (`another run pushed ...`).
    Runs that finish their builds together can still push twice: the last
    push holds the tag, the other image stays untagged (`warn: ... was moved
    by another run`), a leftover of about 1 GB to delete by hand.
  - Permissions: `contents: read`, `packages: write` (the `GITHUB_TOKEN`
    pushes and deletes). The package is linked to the repository by the label
    `org.opencontainers.image.source`; it must be public, because `sdk` reads
    it anonymously.
- The `sdk` job step `Pin the SDK image` (`scripts/sdk-image-info.sh`) reads
  the image anonymously and fails if it is not public or its labels are
  invalid. It does not apply the age rule again: `sdk-image` decided it for
  this run, so an image reused at 23 h 55 min does not fail a build that
  starts after 24 h. It records `<tag>@<digest>` (`HARNESS_SDK_PIN`), digest,
  creation time, SDK archive and its sha256, and `reused` or `rebuilt` (the
  image labels carry the run id and attempt that built it).
  `openwrt/gh-action-sdk` builds `FROM $CONTAINER:$ARCH` with `ARCH` set to
  the pin, so the build reads exactly the digest of the summary even if
  another run moves the tag meanwhile.
- The full `openwrt/packages` tree is checked out (Go packages include
  `lang/golang` by relative path), then built with `openwrt/gh-action-sdk`
  pinned to commit `f5813d30`.
- `scripts/collect-apk.sh` takes the one `<package>-<version>.apk` of the SDK
  output (none or several fail the job).
- The job summary (`scripts/build-summary.sh`) lists line, arch, SDK image and
  digest and pin, its state (`reused` or `rebuilt`), creation date, SDK archive and
  sha256, `openwrt/packages` branch and commit, package version and build
  duration. The `sdk-image` job summary records the decision and, for a
  rebuild, the deleted version.
- Artifact: `apk-<package>-<line>-<arch>` (the `.apk` alone).

## Reusable workflow `test.yml`

Inputs (all required, all validated by `scripts/validate-inputs.sh` before
use; an invalid value fails the run):

| Input     | Meaning                                    | Accepted                              |
|-----------|--------------------------------------------|---------------------------------------|
| `line`    | OpenWrt line, a key of `harness/lines.yml` | `main` or `NN.NN` (`25.12` and `main` have QEMU data) |
| `package` | package name to install and check          | `[a-z0-9][a-z0-9._+-]*`, <= 128 chars |
| `source`  | where the `.apk` comes from                | `feed` (apk feed of the line: release feed for `25.12`, snapshot feed for `main`) or `artifact` (`apk-<package>-<line>-<arch>` from `build.yml` in the same workflow run) |

- One job per target of `harness/targets.yml` that has an image for the line
  (`x86-64`, `armsr-armv8`, `malta-le`, `malta-be`; all four on both lines).
  Each job downloads the image (line `25.12`: latest stable release; line
  `main`: current snapshot), verifies its sha256 against the `sha256sums` of
  the same directory (downloaded first), boots it in QEMU, gets the `.apk`
  (`scripts/fetch-package.sh`) and runs `harness/tests/test_package.py`.
- Snapshot images are rebuilt daily and each target directory is published on
  its own, so two targets of one run can report different snapshot versions.
  The job summary therefore lists, per job, the release or snapshot version
  (`HARNESS_RELEASE`), the image URL, the image sha256 and the image date
  (`Last-Modified` of the file).
- For `main`, `scripts/fetch-image.sh` reads `version.buildinfo` before the
  `sha256sums` and the image and again after them; if it changed, the
  download is repeated (3 attempts), so the version in the summary is the one
  of the tested image. A sha256 mismatch with an unchanged version fails.
- With `source: artifact`, a target uses the artifact of its `arch` in
  `targets.yml` (`x86_64`, `aarch64_generic`, `mipsel_24kc`, `mips_24kc`).
  `aarch64_cortex-a53` is built but not tested yet (no QEMU target).
- Image formats (see `harness/targets.yml`): `x86-64` is a gzipped combined
  image; `armsr-armv8` (both lines) and `malta-le`/`malta-be` on `main` boot
  `*-initramfs-kernel.bin`; `malta-le`/`malta-be` on `25.12` boot
  `*-vmlinux-initramfs.elf`; `armsr-armv8` and `malta-*` run from RAM with
  256 MB.
- Tests: install, `apk` reports the expected version, and every `/etc/init.d`
  script the package installs is a procd script whose instances all stay
  running with constant pids for 10 s. The service test is skipped only when
  the package installs no init script. The job summary lists passed, failed
  and skipped per test.

## Caller `ci.yml`

On push to `feat/**` and on `workflow_dispatch`, for package `netbird`.
Dispatch inputs: `refresh_sdk` (boolean, passed to `build.yml`) and `lines`
(`both`, `25.12` or `main`: the other build job is skipped). Each build job
has `packages: write`.

| Job           | Calls       | Inputs                            | Needs         |
|---------------|-------------|-----------------------------------|---------------|
| `build-25-12` | `build.yml` | `line: 25.12`                     |               |
| `build-main`  | `build.yml` | `line: main`                      |               |
| `test-25-12`  | `test.yml`  | `line: 25.12`, `source: artifact` | `build-25-12` |
| `test-main`   | `test.yml`  | `line: main`, `source: artifact`  | `build-main`  |

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
