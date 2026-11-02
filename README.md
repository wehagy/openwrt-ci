# openwrt-ci

Reusable base of an OpenWrt package CI: build a package with the official SDK,
test it in QEMU and build firmware images with it using the official Image
Builder. This repository holds only the base (reusable workflows, scripts,
pinned tooling, the generic package test) and its own CI, which tests the base
with a sample package (`netbird`). The packages themselves, their
package-specific tests and the planned upstream pull request automation live in
[wehagy/openwrt-ci-packages](https://github.com/wehagy/openwrt-ci-packages),
which calls the workflows below.

## Status

| Done                                                                              | Pending                                             |
|-----------------------------------------------------------------------------------|-----------------------------------------------------|
| SDK build (`build.yml`) on lines `25.12` and `main`, 5 architectures              | NetBird runtime tests (caller repository)           |
| Own SDK image on GHCR, rebuilt when older than 1 day or on request                | Scheduled SDK image refresh (none today: lazy only) |
| QEMU test (`test.yml`) on lines `25.12` and `main`, sources `feed` and `artifact` | Upstream PR automation and testing (caller repository) |
| QEMU targets `x86-64`, `armsr-armv8`, `malta-le`, `malta-be` on both lines        |                                                     |
| Image build (`images.yml`) on lines `25.12` and `main`, 8 profiles                |                                                     |
| `ci.yml`: build both lines, then test each build and build its images             |                                                     |
| Callable from another repository: `ci_ref`, `tests_path`, `test_secrets`, `sdk_container` |                              |

## Layout

- `harness/`
  - `lines.yml`: per-line data. `release_source` selects how the image
    version is found: `releases` (`25.12`: latest `25.12.x` of the releases
    index) or `snapshot` (`main`: the `version.buildinfo` of the target
    directory, e.g. `r37969-5799d2da76`). Both lines also have the build
    keys (`sdk_tag_suffix`, `sdk_max_age_days`, `packages_branch`,
    `imagebuilder_tag_suffix`).
  - `images.yml`: image profiles (target, subtarget, profile, package
    architecture), extra packages and the globs of the files kept as artifacts.
  - `targets.yml`: per-QEMU-target data (`x86-64`, `armsr-armv8`, `malta-le`,
    `malta-be`) and the image name per line.
  - `tests/`: pytest tests run inside the VMs through
    [aparcar/openwrt-tests](https://github.com/aparcar/openwrt-tests).
  - `openwrt-tests.uv.lock`: pinned Python environment of those tests.
- `scripts/` (POSIX shell, used by the workflows)
  - SDK image: `resolve-sdk.sh`, `sdk-age-selftest.sh`,
    `sdk-image-ensure.sh`, `sdk-image-info.sh`.
  - Build: `resolve-build.sh`, `collect-apk.sh`, `build-summary.sh`.
  - Test: `validate-inputs.sh`, `caller-inputs-selftest.sh`, `matrix.sh`,
    `resolve.sh`, `fetch-image.sh`, `fetch-package.sh`, `prepare-target.sh`,
    `run-tests.sh`, `summary.sh`.
  - Images: `image-matrix.sh`, `resolve-image.sh`, `pull-imagebuilder.sh`,
    `imagebuilder-make.sh` (runs inside the Image Builder container),
    `check-image-outcome.sh`, `collect-images.sh`, `image-summary.sh`.
  - `lib/common.sh`: shared helpers. `lib/ghcr.sh` (registry reads),
    `lib/sdk-age.sh` (age rule and reuse/rebuild decision),
    `lib/sdk-labels.sh` (image label keys).
- `docker/sdk-image/Dockerfile`: derives the SDK image from the official one.
- `.github/workflows/`
  - `build.yml`: reusable SDK build.
  - `test.yml`: reusable QEMU test.
  - `images.yml`: reusable Image Builder build.
  - `ci.yml`: the base's own CI, calls the three workflows above for the sample
    package `netbird` on push to `feat/**`.
- `scripts/` also has: `report-revisions.sh` (prints the harness and caller
  commits of a job), `install-tests.sh` (copies the pytest files),
  `with-test-secrets.sh` (exports the caller secrets to the tests only).
- `harness/sample-tests/`: caller tests of this repository, used by `ci.yml`
  (see "Package tests").

## Using the base from another repository

```yaml
jobs:
  build:
    permissions: {contents: read, packages: write}
    uses: wehagy/openwrt-ci/.github/workflows/build.yml@main
    with: {line: "25.12", package: netbird, ci_ref: main}
  test:
    needs: build
    uses: wehagy/openwrt-ci/.github/workflows/test.yml@main
    with:
      line: "25.12"
      package: netbird
      source: artifact
      ci_ref: main
      tests_path: packages/netbird/tests   # optional
      test_secrets: NB_SETUP_KEY           # optional
    secrets: inherit                       # only with test_secrets
```

No tags are used: the callers follow a branch (`@main`).

### Self-checkout (`ci_ref`)

A reusable workflow runs in the caller's context: a plain `actions/checkout`
fetches the calling repository, so `scripts/`, `harness/` and `docker/` would be
missing. Every job of the three workflows therefore starts with the same two
steps: check out `wehagy/openwrt-ci` at `ci_ref` (default `main`) into
`ci-base/`, then `ci-base/scripts/report-revisions.sh`, which prints

```
harness: wehagy/openwrt-ci ref <ci_ref> -> <sha of ci-base>
caller: <owner>/<repo> run commit <GITHUB_SHA>
```

(and appends it to the job summary). Every script then runs as
`ci-base/scripts/...`; the data files are found relative to the script.

- `ci_ref` is an input of `build.yml`, `test.yml` and `images.yml`. A caller
  that uses `@<ref>` must pass `ci_ref: <ref>`; the workflow file comes from
  the `uses:` ref, the scripts from `ci_ref`, and nothing keeps them equal.
  A branch that moves between the two reads gets mixed versions (risk).
- `ci.yml` of this repository passes `ci_ref: ${{ github.sha }}`, so a branch
  tests its own scripts (the local `uses: ./...` is the same commit).
- Why a step in each job and not a composite action: a composite action must
  be named with a fixed `uses: wehagy/openwrt-ci/...@<ref>` (no expression is
  allowed there) before any checkout exists, so it would pin its own ref apart
  from `ci_ref` and a branch would run the action from `main`. The cost is 11
  copied lines in six jobs.
- The harness repository is the `HARNESS_CI_REPOSITORY` env of each workflow
  (`wehagy/openwrt-ci`); a fork changes it.

### Package tests (`tests_path`, `test.yml`)

`tests_path` is a directory of the calling repository (e.g.
`packages/netbird/tests`). When set, only that directory is checked out
(`sparse-checkout`, into `caller/`) and its top-level `*.py` files are copied
to `openwrt-tests/tests/ext/` next to the generic test, so they run in the same
pytest session and VM (`scripts/install-tests.sh`) and can import
`harness_util` and use the fixtures of `conftest.py` (`vm_ssh`). A file named
like a harness file (`conftest.py`, `harness_util.py`, `test_package.py`) fails
the job. Empty input, a missing directory or no `*.py` file: only the generic
test runs (`::notice::` in the log). The value is validated
(`scripts/validate-inputs.sh`: relative, `[A-Za-z0-9._/-]`, at most 256
characters, no `..` or `.` component, no leading `-` (git could read it as an
option) and no `.git` component in any letter case).

Tests of this logic:

- `scripts/caller-inputs-selftest.sh` (step "Self-test the caller inputs" of
  the `targets` job in `test.yml`, so every caller runs it too) runs, with
  fixed inputs, `check_tests_path`, `check_secret_names`, `validate-inputs.sh`,
  `install-tests.sh` (only top-level `*.py` copied, name collisions fail and
  leave the harness file intact, missing directory) and
  `with-test-secrets.sh`. It runs every case and fails at the end if one
  failed. It needs `jq` and `/proc`.
- `ci.yml` calls `test.yml` with `tests_path: harness/sample-tests` and
  `test_secrets: SAMPLE_SECRET` (`secrets: inherit`), so the base tests its
  caller side without the calling repository. `test_caller_contract.py`
  checks inside the QEMU job: the files sit next to the harness files, the
  listed secret is exported (empty here: the base defines none), `GITHUB_TOKEN`
  and the secrets JSON are not in the environment of pytest, and no ancestor
  of pytest has `HARNESS_SECRETS_JSON` in its `/proc/<pid>/environ`.

### Secrets for the tests (`test_secrets`, `test.yml`)

The base names no secret. The caller passes `secrets: inherit` and lists the
names in `test_secrets` (spaces or commas, 1 to 32 names, `[A-Z][A-Z0-9_]*`).
Names that change how a process behaves are refused: `GITHUB_*`, `RUNNER_*`,
`ACTIONS_*`, `HARNESS_*`, `LD_*`, `BASH_*`, `PYTHON*`, `UV_*`, `PYTEST_*`,
`LG_*`, `NODE_OPTIONS`, `PATH`, `HOME`, `SHELL`, `IFS`, `ENV`, `PS4`, `TMPDIR`.

- The step `Run tests` gets `toJSON(secrets)` and the names as env and runs
  `exec ci-base/scripts/with-test-secrets.sh ci-base/scripts/run-tests.sh`.
  The wrapper exports each named secret as an environment variable (not
  `GITHUB_ENV`), removes the JSON and `exec`s `run-tests.sh` (uv, pytest).
  Values are masked by GitHub; the log shows only `test-secrets: NAME is set`
  or `... is absent or empty`.
- What this does and does not give: the list limits what the tests receive,
  and no process above pytest keeps the JSON with all the caller secrets in
  its environment (the step's bash is replaced by the wrapper, which is
  replaced by `run-tests.sh`; proved by `caller-inputs-selftest.sh` and by
  `test_no_ancestor_keeps_the_secrets_json`, which read `/proc/<pid>/environ`
  of every ancestor). It is hygiene against accidental exposure, not
  isolation: the tests are code of the calling repository, whose own workflow
  can read all its secrets anyway.
- A name that is not a secret of the caller is exported empty: a test sees an
  empty variable and can skip with a reason. Without `secrets: inherit`,
  `toJSON(secrets)` holds only `github_token` (measured: keys
  `["github_token"]` with and without `inherit` in a repository with no other
  secret), so every listed name is absent.
- Why not an explicit `secrets:` entry: the base would have to declare names, or
  one opaque `test_env` secret the caller composes. `inherit` plus a list keeps
  the base generic and the caller in control. It requires the caller and the
  base to be able to use `secrets: inherit` (same owner or organization).
- Limit: the env block of the `Run tests` step prints `toJSON(secrets)`, so the
  log shows the names of all secrets the caller passed (`"NAME": "***"`), never
  their values.

### SDK image access (`sdk_container`, `build.yml`)

`sdk_container` (default `ghcr.io/wehagy/openwrt-sdk`) names the GHCR
repository of the SDK image. Reusing a fresh image needs only a public read.
When a run has to rebuild it, `sdk-image` pushes with the caller's
`GITHUB_TOKEN`, which needs the package to allow that repository: GitHub >
Packages > `openwrt-sdk` > Package settings > Manage Actions access > Add
Repository > the calling repository, role Write (Admin to also delete the
superseded `-prev` version). A denied push fails the job with
`::error::push of ... denied. The GITHUB_TOKEN of <repo> needs write access to
the package ...` after printing the registry error.

### Known limits

- `ci_ref` and the `uses:` ref are two inputs; a branch that moves between the
  read of the workflow file and the checkout mixes versions.
- `/orgs/<owner>/packages/...` (owner an organization) is written but was not
  exercised: every run so far had a user owner.
- A push denied by the registry is reported with the permission to grant; the
  message was not provoked in a run (a fresh image is always reused).
- A rebuild started by a caller needs the package role Write; deleting the old
  `-prev` version probably needs Admin (not exercised).

## Reusable workflow `build.yml`

Inputs (`line` and `package` required):

| Input     | Meaning                                                    | Accepted                              |
|-----------|------------------------------------------------------------|---------------------------------------|
| `line`    | OpenWrt line, a key of `harness/lines.yml` with build keys | `25.12` or `main`                     |
| `package` | package to build, a directory of `openwrt/packages`        | `[a-z0-9][a-z0-9._+-]*`, <= 128 chars |

Optional inputs: `refresh_sdk` (boolean, default `false`): rebuild the SDK
images of the line even when they are fresh; `sdk_container` (see above);
`ci_ref` (see above).

The caller must grant `packages: write` to the job that calls `build.yml`
(`ci.yml` does); the workflow itself needs it only in `sdk-image`.

- Two jobs, each one per architecture: `x86_64`, `aarch64_generic`,
  `aarch64_cortex-a53`, `mipsel_24kc`, `mips_24kc` (`fail-fast: false`).
  `sdk` (the build) needs `sdk-image`, which waits for all five architectures.
- The SDK image repository is named once, by the workflow `env`
  `HARNESS_SDK_CONTAINER` (the `sdk_container` input, default
  `ghcr.io/wehagy/openwrt-sdk`): `sdk-image` publishes it, `sdk` reads it and
  passes it to the action as `CONTAINER`. `scripts/resolve-sdk.sh` has no
  default.
- `scripts/resolve-build.sh` validates the inputs and reads `sdk_tag_suffix`,
  `sdk_max_age_days` and `packages_branch` from `lines.yml`.
  - Official SDK container: `docker.io/openwrt/sdk:<arch>-<sdk_tag_suffix>`.
    Snapshot containers ship only `setup.sh`, which downloads the ~280 MB SDK
    from the OpenWrt mirror (13-14 min from the runners).
  - Harness SDK image: `<sdk_container>:<arch>-<sdk_tag_suffix>` (default
    `ghcr.io/wehagy/openwrt-sdk`),
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
    `<sdk_container>:<tag>`, set to the time just before
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
    /users/<owner>/packages/container/openwrt-sdk/versions/<id>`, or `/orgs/<owner>/...`
    for an organization; the version
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
  - Permissions: `contents: read`, `packages: write` (the `GITHUB_TOKEN` of the
    calling repository pushes and deletes; see "SDK image access"). The label
    `org.opencontainers.image.source` names the harness repository
    (`HARNESS_CI_REPOSITORY`); the package must be public, because `sdk` reads
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

Inputs (`line`, `package`, `source` required; all validated by
`scripts/validate-inputs.sh` before use; an invalid value fails the run).
Optional: `tests_path`, `test_secrets` and `ci_ref` (see above).

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

## Reusable workflow `images.yml`

Inputs (validated before use, like `build.yml`): `line` (a key of
`harness/lines.yml`) and `package`, both required; optional `ci_ref` (see
above).

- One job per profile of `harness/images.yml` (`fail-fast: false`), from the
  profiles and extra packages of
  [wehagy/owpib](https://github.com/wehagy/owpib); extra packages
  `luci-app-attendedsysupgrade luci-app-uhttpd luci-ssl owut` plus the built
  package:

  | Profile id                          | Target / subtarget | Profile                             | Package arch         |
  |-------------------------------------|--------------------|-------------------------------------|----------------------|
  | `x86-64-generic`                    | `x86/64`           | `generic`                           | `x86_64`             |
  | `xiaomi-mi-router-ax3000t-ubootmod` | `mediatek/filogic` | `xiaomi_mi-router-ax3000t-ubootmod` | `aarch64_cortex-a53` |
  | `acer-predator-w6x-stock`           | `mediatek/filogic` | `acer_predator-w6x-stock`           | `aarch64_cortex-a53` |
  | `bananapi-bpi-r3`                   | `mediatek/filogic` | `bananapi_bpi-r3`                   | `aarch64_cortex-a53` |
  | `tplink-archer-c7-v4`               | `ath79/generic`    | `tplink_archer-c7-v4`               | `mips_24kc`          |
  | `totolink-x5000r`                   | `ramips/mt7621`    | `totolink_x5000r`                   | `mipsel_24kc`        |
  | `glinet-gl-mt1300`                  | `ramips/mt7621`    | `glinet_gl-mt1300`                  | `mipsel_24kc`        |
  | `buffalo-wzr-hp-g450h`              | `ath79/generic`    | `buffalo_wzr-hp-g450h`              | `mips_24kc`          |

  The last two are 32 MB flash devices added to learn whether the package
  fits a 32 MB device. Both have a size check in the image build
  (`Build/check-size`, `include/image-commands.mk`) against the firmware
  partition, tag `v25.12.6` of `openwrt/openwrt`:

  | Profile                | `IMAGE_SIZE`                                    | Flash layout                                                                                                                                       |
  |------------------------|-------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------|
  | `glinet_gl-mt1300`     | `32448k` (`ramips/image/mt7621.mk:1563`)        | one SPI NOR; partitions `u-boot` ... `firmware` `0x50000` + `0x1fb0000` = `0x2000000` (`ramips/dts/mt7621_glinet_gl-mt1300.dts:121`)             |
  | `buffalo_wzr-hp-g450h` | `32256k` (`ath79/image/generic.mk:729`)         | two SPI NOR chips concatenated (`ath79/dts/ar7242_buffalo_wzr-bhr.dtsi:61-63`); `firmware` `0x60000` + `0x1f80000` (`...wzr-bhr.dtsi:89-90`)      |

  A profile with `expect: too-big` in `harness/images.yml` is an expected
  failure (see below); the two 32 MB profiles have none unless their image was
  measured too big.

- Image Builder: `docker.io/openwrt/imagebuilder:<target>-<subtarget>-<tag>`
  (`scripts/resolve-image.sh`).
  - `25.12` (`release_source: releases`): `<tag>` is the latest `25.12.x`
    release, found as `test.yml` finds its release (`latest_release` in
    `scripts/lib/common.sh`). The release image contains the Image Builder.
  - `main` (`release_source: snapshot`): `<tag>` is `main`, a snapshot tag
    that ships only `setup.sh`; the container downloads the Image Builder from
    `downloads.openwrt.org` when it starts (timed as "setup.sh" in the
    summary). Risk: that mirror gave ~330 KB/s from runners for the SDK.
- The `.apk` of `apk-<package>-<line>-<arch>` is copied to the Image Builder
  `packages/` directory. It is unsigned and needs no signature override: the
  Image Builder (`CONFIG_SIGNATURE_CHECK=y`) indexes `packages/` itself with
  `apk mkndx --allow-untrusted` and signs that index with its local key.
- `scripts/collect-images.sh` requires the line `<package> - <version>` in
  `*.manifest` (version of the built `.apk`), then keeps the files matching
  `image_globs` plus the manifest and `sha256sums`.
- An image that does not fit the flash: the Image Builder does not fail, it
  only prints `WARNING: Image file ... is too big: <size> > <limit>` and
  deletes the image (`Build/check-size`); `tplink-safeloader` refuses earlier
  with `file-system partition too big (more than <limit> bytes)` and the
  warning then has an empty size. That empty-size warning is printed whenever
  the image file does not exist, whatever removed it (`include/image-commands.mk`:
  `... && mv $@.new $@ || rm -f $@`), so it proves nothing.
  `scripts/check-image-outcome.sh` accepts "too big" only with numbers: a
  `check-size` message with `<size>` > `<limit>`, or a `partition too big`
  message with the size of `root.squashfs` (`rootfs-bytes`, the `dd` "bytes
  copied" line before the message) > `<limit>`. Any "too big" message that is
  not proven so (size not above the limit, root filesystem not above the
  partition, no root filesystem size) or only empty-size warnings: the job
  fails ("not proven by numbers"). The proven result is compared with the
  profile's `expect` key of `harness/images.yml`:

  | `expect`          | Image builds | Image too big (proven)                         |
  |-------------------|--------------|------------------------------------------------|
  | absent (default)  | job green    | job fails, message and sizes quoted            |
  | `too-big`         | job fails: "now fits", remove the key | job green, no artifact |

  `tplink-archer-c7-v4` and `totolink-x5000r` (16 MB flash) are `expect:
  too-big`. The summary of such a job quotes the Image Builder messages with
  the actual and limit bytes (for the TP-Link, the root filesystem against its
  partition, because the warning has no size).
  - Failures: a `make` error or a missing `.apk` fails the Image Builder step
    in both cases. A profile with `expect: too-big` that is proven too big
    skips the manifest check (`scripts/collect-images.sh`) and the artifact
    because no image exists, so a wrong manifest or a missing package in such
    a profile is not detected.
  - `scripts/image-outcome-selftest.sh` (step "Outcome check self-test" of the
    `profiles` job in `images.yml`) runs `check-image-outcome.sh` on fixed
    `make.log` fixtures: the empty-size warning alone, `10 > 20`, a
    `partition too big` without or with a smaller root filesystem must fail;
    the real `totolink-x5000r` and `tplink-archer-c7-v4` messages are a green
    too big; a fitting image and a fitting `expect: too-big` profile ("now
    fits") are checked too.
- The job summary (`scripts/image-summary.sh`) lists profile, Image Builder
  image and digest, size and pull time, `setup.sh` and `make image` durations,
  the expectation and outcome, the manifest check, every artifact file with
  size and sha256 and, on failure or expected failure, the Image Builder
  messages of `make.log`.
- Artifact: `images-<package>-<line>-<profile id>` (none for a profile that is
  too big as expected).

## Own CI `ci.yml`

Tests the base with the sample package `netbird`. Every call passes
`ci_ref: ${{ github.sha }}`, the commit under test. On push to `feat/**` and on
`workflow_dispatch`.
Dispatch inputs: `refresh_sdk` (boolean, passed to `build.yml`) and `lines`
(`both`, `25.12` or `main`: the other build job is skipped). Each build job
has `packages: write`.

| Job           | Calls       | Inputs                            | Needs         |
|---------------|-------------|-----------------------------------|---------------|
| `build-25-12` | `build.yml` | `line: 25.12`                     |               |
| `build-main`  | `build.yml` | `line: main`                      |               |
| `test-25-12`  | `test.yml`  | `line: 25.12`, `source: artifact` | `build-25-12` |
| `test-main`   | `test.yml`  | `line: main`, `source: artifact`  | `build-main`  |
| `image-25-12` | `images.yml` | `line: 25.12`                    | `build-25-12` |
| `image-main`  | `images.yml` | `line: main`                     | `build-main`  |

## Artifacts

| Name                                  | From        | Content                        |
|---------------------------------------|-------------|--------------------------------|
| `apk-<package>-<line>-<arch>`         | `build.yml` | the built `.apk`               |
| `images-<package>-<line>-<profile>`   | `images.yml` | sysupgrade/factory/combined/sdcard images, `*.manifest`, `sha256sums` |
| `qemu-<package>-<line>-<target>`      | `test.yml`  | `results.xml` (junit)          |
| `qemu-<package>-<line>-<target>-logs` | `test.yml`  | labgrid logs, `pip-freeze.txt` |

## Adding a package

Packages are added in the calling repository
([wehagy/openwrt-ci-packages](https://github.com/wehagy/openwrt-ci-packages),
`packages/<name>/`), not here. Only what the code supports today:

- Build and test a package of `openwrt/packages`: call `build.yml` with `line`
  and `package`, then `test.yml` with the same `line` and `package`,
  `source: artifact` and `needs:` the build job; pass `ci_ref`.
- Test a package of the official release feed without building it: call
  `test.yml` with `source: feed`.
- `harness/tests/test_package.py` is generic: no per-package code or data.
  Package-specific runtime tests are files in the caller repository, given by
  `tests_path`; they do not exist yet.
- Build images with the package: call `images.yml` with the same `line` and
  `package`, `needs:` the build job.
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
