# openwrt-ci

Reusable base of an OpenWrt package CI: build a package with the official SDK,
test it in QEMU and build firmware images with it using the official Image
Builder. This repository holds only the base (reusable workflows, scripts,
pinned tooling, the generic package test) and its own CI, which tests the base
with a sample package (`chrony`). The packages themselves, their
package-specific tests and the planned upstream pull request automation live in
[wehagy/openwrt-ci-packages](https://github.com/wehagy/openwrt-ci-packages),
which calls the workflows below.

## Status

| Done                                                                              | Pending                                             |
|-----------------------------------------------------------------------------------|-----------------------------------------------------|
| SDK build (`build.yml`) on lines `25.12` and `main`, architectures given by the caller | NetBird runtime tests (caller repository)           |
| Own SDK image on GHCR, rebuilt when older than 1 day or on request                | Scheduled SDK image refresh (none today: lazy only) |
| QEMU test (`test.yml`) on lines `25.12` and `main`, sources `feed` and `artifact` | Upstream PR automation and testing (caller repository) |
| QEMU targets `x86-64`, `armsr-armv8`, `malta-le`, `malta-be` on both lines        |                                                     |
| Image build (`images.yml`) on lines `25.12` and `main`, profiles and packages given by the caller |                                                     |
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
  - `images.yml`: the globs of the files kept as artifacts. The image
    choices of a caller (profiles, packages) are inputs of `images.yml`, not
    data of this repository; the base has no default profile.
  - `targets.yml`: per-QEMU-target data (`x86-64`, `armsr-armv8`, `malta-le`,
    `malta-be`) and the image name per line.
  - `selftests/`: pytest tests of the harness helpers (no VM).
  - `tests/`: pytest tests run inside the VMs through
    [aparcar/openwrt-tests](https://github.com/aparcar/openwrt-tests).
  - `openwrt-tests.uv.lock`: pinned Python environment of those tests.
- `scripts/` (POSIX shell, used by the workflows)
  - SDK image: `resolve-sdk.sh`, `sdk-age-selftest.sh`,
    `sdk-image-ensure.sh`, `sdk-image-info.sh`.
  - Build: `resolve-build.sh`, `collect-apk.sh`, `build-summary.sh`; feed
    source: `resolve-feed.sh`, `feed-record.sh`, `feed-inputs-selftest.sh`.
  - Test: `validate-inputs.sh`, `caller-inputs-selftest.sh`, `matrix.sh`,
    `resolve.sh`, `fetch-image.sh`, `fetch-package.sh`, `prepare-target.sh`,
    `run-tests.sh`, `summary.sh`.
  - Image inputs: `resolve-profiles.sh` (profiles against `profiles.json`),
    `resolve-archs.sh` (architecture matrix of `build.yml`),
    `image-inputs-selftest.sh`, `lib/image-inputs.sh` (validators).
  - Images: `resolve-image.sh`, `pull-imagebuilder.sh`,
    `imagebuilder-make.sh` (runs inside the Image Builder container) with
    `ib-setup.sh` and `ib-setup-selftest.sh`,
    `check-image-outcome.sh`, `collect-images.sh`, `image-summary.sh`.
  - `lib/common.sh`: shared helpers. `lib/selftest.sh` (case bookkeeping of
    the self-tests), `lib/ghcr.sh` (registry reads),
    `lib/sdk-age.sh` (age rule and reuse/rebuild decision),
    `lib/sdk-labels.sh` (image label keys).
- `docker/sdk-image/Dockerfile`: derives the SDK image from the official one.
- `.github/workflows/`
  - `build.yml`: reusable SDK build.
  - `test.yml`: reusable QEMU test.
  - `images.yml`: reusable Image Builder build.
  - `ci.yml`: the base's own CI, calls the three workflows above for the sample
    package `chrony` on push to `feat/**`.
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
    with: {line: "25.12", package: chrony, ci_ref: main}
  test:
    needs: build
    uses: wehagy/openwrt-ci/.github/workflows/test.yml@main
    with:
      line: "25.12"
      package: chrony
      source: artifact
      ci_ref: main
      tests_path: packages/chrony/tests   # optional
      test_secrets: EXAMPLE_KEY           # optional
    secrets: inherit                       # only with test_secrets
  image:
    needs: build
    uses: wehagy/openwrt-ci/.github/workflows/images.yml@main
    with:
      line: "25.12"
      package: chrony
      ci_ref: main
      profiles: |                          # optional: see images.yml
        x86/64/generic
        ath79/generic/tplink_archer-c7-v4:too-big
      packages: luci-ssl -dnsmasq dnsmasq-full
```
(with the same `profiles:` given to `build.yml`.)

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
`packages/chrony/tests`). When set, only that directory is checked out
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

### Test targets and VM memory (`targets`, `memory`, `test.yml`)

By default every package is tested on the four targets of
`harness/targets.yml` with 128M of VM memory. A caller whose package needs
something else says so in its inputs:

| Input     | Meaning                                         | Accepted                                                  |
|-----------|-------------------------------------------------|-----------------------------------------------------------|
| `targets` | targets to test, separated by spaces or newlines | 1 to 16 ids of `[a-z0-9][a-z0-9-]*`, each a key of `targets.yml` with an image for the line; empty: all (`x86-64`, `armsr-armv8`, `malta-le`, `malta-be`) |
| `memory`  | VM memory of every tested target                | `NNNM` from `64M` to `1024M`; empty: the `memory` of `targets.yml` |

- 128M is the default of the `targets/qemu_*.yaml` files of
  [aparcar/openwrt-tests](https://github.com/aparcar/openwrt-tests) (checked at
  commit `b3a04b2`: `qemu_x86-64.yaml`, `qemu_armsr-armv8.yaml`,
  `qemu_malta-le.yaml`, `qemu_malta-be.yaml`), and the value of `memory` in
  `targets.yml`. A package that needs more passes `memory`: netbird was
  OOM-killed at 128M on `x86-64` (run 41480369349), so its caller passes `256M`.
- The `targets` job validates both inputs and builds the matrix
  (`scripts/matrix.sh`); an unknown id fails there with `unknown test target
  '<id>' on line <line> (known: ...)` and a memory outside the range with
  `invalid VM memory (allowed: <megabytes>M from 64M to 1024M)`, before any VM
  starts. The memory is shown in the summary of the `targets` job and of each
  VM job (`target: ..., memory: ...`).
- Pass the same `targets` to `build.yml`: its default `archs` (`@tests
  @profiles`) take the architectures of the chosen targets, plus those of the
  image profiles, so a subset builds only what the tests and images need.
  `scripts/image-inputs-selftest.sh` covers the validators, the selection and
  the memory override.

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
  can read all its secrets anyway. The runner process (`Runner.Worker`) keeps
  the secrets in its memory, because it builds the step environment and masks
  the log; nothing here changes that, and a process with `ptrace` or root can
  read them.
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
Packages > the package named by `sdk_container` (`openwrt-sdk` by default) >
Package settings > Manage Actions access > Add
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

Optional inputs: `archs` and `profiles` (see "Architectures");
`refresh_sdk` (boolean, default `false`): rebuild the SDK
images of the line even when they are fresh; `sdk_container` (see above);
`feed_repository` and `feed_ref` (see "Feed source"); `ci_ref` (see above).
Outputs: `feed_repository`, `feed_ref` and `feed_sha` (see "Feed source").

The caller must grant `packages: write` to the job that calls `build.yml`
(`ci.yml` does); the workflow itself needs it only in `sdk-image`.

- Three jobs, `feed` once and the other two per architecture of the `archs`
  input (`fail-fast: false`; by default `x86_64`, `aarch64_generic`,
  `mipsel_24kc`, `mips_24kc`, those of the QEMU test targets). `sdk` (the build)
  needs `sdk-image`, which waits for all the architectures.
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
  - Default feed ref of `openwrt/packages`: `openwrt-25.12` for `25.12`,
    `master` for `main` (the `packages_branch` key).
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
    /users/<owner>/packages/container/<name>/versions/<id>`, or `/orgs/<owner>/...`
    for an organization; `<name>` is the last component of `sdk_container`,
    `openwrt-sdk` by default; the version whose `name` is its manifest
    digest). The package versions before and
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
- The full feed tree is checked out (Go packages include `lang/golang` by
  relative path; by default `openwrt/packages`, see "Feed source"), then built
  with `openwrt/gh-action-sdk` pinned to commit `f5813d30`.
- `scripts/collect-apk.sh` takes the one `<package>-<version>.apk` of the SDK
  output (none or several fail the job).
- The job summary (`scripts/build-summary.sh`) lists line, arch, SDK image and
  digest and pin, its state (`reused` or `rebuilt`), creation date, SDK archive and
  sha256, feed repository, ref and commit, package version and build
  duration. The `sdk-image` job summary records the decision and, for a
  rebuild, the deleted version.
- Artifact: `apk-<package>-<line>-<arch>` (the `.apk` alone).

### Architectures (`archs`, `profiles`)

The architecture matrix of `sdk-image` and `sdk` is computed by the `feed` job
(`scripts/resolve-archs.sh`), so an invalid value fails before an SDK image is
rebuilt.

| Input      | Meaning                                                  | Accepted                                              |
|------------|----------------------------------------------------------|-------------------------------------------------------|
| `archs`    | package architectures to build, separated by spaces or newlines | `@tests`, `@profiles`, or a name `[a-z0-9][a-z0-9_-]*` (<= 64 chars); 1 to 16 after expansion; default `@tests @profiles` |
| `targets`  | QEMU test targets whose architectures `@tests` stands for | same value as the `targets` input of `test.yml`; empty: all |
| `profiles` | image profiles whose architectures `@profiles` adds       | same value as the `profiles` input of `images.yml` (see there); empty: none |

- `@tests` is the `arch` of every target of `harness/targets.yml` selected by
  `targets` (by default all: `x86_64`,
  `aarch64_generic`, `mipsel_24kc`, `mips_24kc`), so the architectures the QEMU
  jobs need are never listed twice. `@profiles` is the `arch_packages` of the
  `profiles.json` of each profile (see "Reusable workflow `images.yml`").
  Duplicates are dropped.
- A caller passes the same `profiles` to `build.yml` and `images.yml`, and the
  architectures of its images are built without being named. A caller that
  wants only the architecture of one profile passes `archs: "@profiles"`.
- A new architecture needs no change here: its SDK image
  `<sdk_container>:<arch>-<suffix>` is missing, so `sdk-image` builds and pushes
  it (see above; the caller needs write access to the package). The official
  container `docker.io/openwrt/sdk:<arch>-<suffix>` must exist; a name that
  does not exist fails at the pull in `sdk-image`.
- Job names (`<line> <arch>`, `sdk-image <line> <arch>`) and the artifact
  `apk-<package>-<line>-<arch>` are unchanged; only the set of architectures
  moved from the workflow file to the inputs.

### Feed source (`feed_repository`, `feed_ref`)

By default a build uses the branch of `openwrt/packages` named by the line
(`packages_branch`). A caller that builds another tree (a version bump pushed to
a test repository, an upstream pull request) passes:

| Input             | Meaning                         | Accepted                                                |
|-------------------|---------------------------------|---------------------------------------------------------|
| `feed_repository` | public GitHub repository        | `<owner>/<name>`; owner `[A-Za-z0-9-]` (<= 39, no leading `-`), name `[A-Za-z0-9._-]` (<= 100, no leading `-`, not `.`, `..` or `*.git`); default `openwrt/packages` |
| `feed_ref`        | what to build in that repository | a branch, a tag, a full commit SHA or `refs/pull/<n>/head` (<= 9 digits); empty: the line's `packages_branch` |

- Both values are validated by `scripts/resolve-feed.sh` (`check_feed_repository`
  and `check_feed_ref` of `lib/common.sh`) before anything is written to
  `$GITHUB_ENV`; nothing is echoed. A ref is `[A-Za-z0-9._/+-]`, at most 200
  characters, with no `..`, no leading `-`, no leading, trailing or doubled `/`,
  no component starting with `.`, no `.lock` or `.` ending; any other `refs/`
  name is refused.
- The job `feed` runs first (it also gates `sdk-image`, so an invalid input
  fails before an SDK image is rebuilt). It checks the feed out, reads the
  commit (`scripts/feed-record.sh`) and exposes it as the workflow outputs
  `feed_repository`, `feed_ref` and `feed_sha`; its job summary has the
  section `feed source` with the three values. The `sdk` jobs check out
  that SHA, so the five architectures build one tree even if the branch moves
  during the run, and fail if the checkout is not at that SHA.
- The summary of each `sdk` job has `packages feed: <repository> <ref> @ <sha>`.
- A caller reads the outputs with `needs.build.outputs.feed_sha` etc.
- Both summaries are also printed to the job log (`tee`), so the values can be
  read without the web page.
- `package` is passed to the SDK as the package to compile and must also be the
  name of the `.apk`: a source package whose apk has another name (e.g. `udns`
  builds `libudns`) fails at "no <package> .apk" or, for the binary name, at
  "No rule to make target package/<name>/download" (observed with PR 31056 of
  `openwrt/packages`).
- `images.yml` and `test.yml` do not read the feed: they use the `.apk` of the
  build artifact and the release or snapshot feed of OpenWrt, so they need no
  change.
- Tests: `scripts/feed-inputs-selftest.sh` (step "Feed source self-test" of the
  `feed` job, run by every caller) covers the validators, `resolve-feed.sh`,
  `resolve-build.sh` and `feed-record.sh` with fixed inputs, including values
  that must be refused (`..`, leading `-`, other `refs/` names, a newline, a
  forged `::error::` line) and the defaults of both lines. It needs `yq` and
  `git`.

## Reusable workflow `test.yml`

Inputs (`line`, `package`, `source` required; all validated by
`scripts/validate-inputs.sh` before use; an invalid value fails the run).
Optional: `tests_path`, `test_secrets`, `targets`, `memory` and `ci_ref` (see
above and "Test targets and VM memory").

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
  `*-vmlinux-initramfs.elf`; `armsr-armv8` and `malta-*` run from RAM (with the
  default 128M, see "Test targets and VM memory").
- Network of the VM (`harness/tests/conftest.py`): the session waits for a
  default route and an A record, then runs `apk update`, repeated up to 5 times, 5 s
  apart, only when stderr has `Failed to send request: Operation not
  permitted`; any other failure (`UNTRUSTED signature`, `404 Not Found`, ...)
  fails on the first attempt. `unavailable` alone does not qualify: the
  `1 unavailable, 0 stale` line of the lost fetch is what a missing file
  prints too. On `malta-le` and `malta-be` (where the test creates the `wan`
  interface) one of the parallel fetches of the first `apk update` failed with
  `wget: Failed to send request: Operation not permitted` while the other
  repositories succeeded, a different repository each time (runs
  41427983225, 41360955048); route and DNS were already up, and the cause
  inside the VM was not proven. Each repeat is logged as a `harness`
  warning with the output of `apk update` and added as a line to the job
  summary; after the last attempt, or at a failure that is not the lost
  fetch, the session fails with the output of the attempts made.
- Timeouts in the VM: queries are bounded at 30 s; the `apk` commands of
  `test_package.py` (`apk info -L`, `apk info -e`, `apk list -I`) at 120 s,
  because `apk info -L` right after the install took 0.5 to 15 s in healthy
  runs and once more than 30 s (`TimeoutExpired`, run 41437522326, job
  125258840649, `x86-64` on `main`, with netbird at 128 MB); that memory
  pressure is the cause is not proven.
- `harness/selftests/` (step "Harness helpers self-test" of `test.yml`) tests
  the retry helpers with a stub in place of the VM.
- Tests: install, `apk` reports the expected version, and every `/etc/init.d`
  script the package installs is a procd script whose instances all stay
  running with constant pids for 10 s. The service test is skipped only when
  the package installs no init script. The job summary lists passed, failed
  and skipped per test.

## Reusable workflow `images.yml`

Inputs (validated before use, like `build.yml`): `line` (a key of
`harness/lines.yml`) is required; optional `package`, `profiles`, `packages`
and `ci_ref` (see above). The base names no device: the image choices belong to
the caller (in [wehagy/openwrt-ci-packages](https://github.com/wehagy/openwrt-ci-packages),
`packages/<name>/config.yml`).

| Input      | Meaning                                                 | Accepted                                              |
|------------|---------------------------------------------------------|-------------------------------------------------------|
| `package`  | package built by `build.yml`, installed in every image  | as in `build.yml`; empty: images without a package of their own (no `apk-*` artifact is read, no manifest line is checked) |
| `profiles` | the images to build, separated by spaces or newlines    | `<target>/<subtarget>/<profile>[:too-big]`; target and subtarget `[a-z0-9]+` (<= 32), profile `[A-Za-z0-9_-]+` (<= 64); 1 to 16; empty: no image (the image jobs are skipped; the `profiles` job says `images: no profile given, no image is built` in its summary) |
| `packages` | packages added to every image next to the built one     | `<name>` adds, `-<name>` removes (Image Builder `PACKAGES` syntax, e.g. `-dnsmasq dnsmasq-full`); name as `package`; at most 100 and 2048 characters; empty: none |

- `:too-big` after a profile is the expectation described below (the image is
  known not to fit the flash).
- The job `profiles` (`scripts/resolve-profiles.sh`) reads, for each profile,
  the official `profiles.json` of its target and subtarget: for `25.12` the
  directory of the latest `25.12.x` release (as the Image Builder tag), for
  `main` the snapshot directory (`image_base_url` of `harness/lines.yml`).
  - The file must exist (otherwise `target <t>/<s> does not exist on line <l>:
    no profiles.json at <url>`) and its `profiles` object must have the profile
    (otherwise `profile <p> does not exist in <t>/<s> on line <l> (<n> profiles
    there; nearest: ...)`). The package architecture is its `arch_packages`
    field. An invalid input fails here, within about a minute, before an SDK or
    Image Builder job exists.
  - The matrix has one entry per profile with the id (job name
    `<line> <id>`, artifact name), target, subtarget, profile, architecture and
    expectation. The id is the profile name in lower case with `_` as `-`
    (`glinet_gl-mt1300` is `glinet-gl-mt1300`); a profile called `generic` gets
    `<target>-<subtarget>` in front (`x86-64-generic`). Two entries with the
    same id fail.
  - The values are checked (charset, length, count) before anything is
    written to `$GITHUB_OUTPUT` or `$GITHUB_ENV`, and never echoed.
- One job per entry (`fail-fast: false`). The Image Builder package list is the
  `packages` input followed by the built package. After the build
  `scripts/collect-images.sh` checks the manifest: `<package> - <version>` is a
  line, every package added by `packages` is listed and every package removed
  with `-` is not (names are compared whole: `-dnsmasq` is satisfied by
  `dnsmasq-full`).
- `scripts/image-inputs-selftest.sh` (step "Image inputs self-test" of the
  `profiles` job here and of the `feed` job of `build.yml`) proves the
  validators, the resolution against a fake mirror (`file://` URLs, no network)
  and the manifest check with fixed inputs.

- Image Builder: `docker.io/openwrt/imagebuilder:<target>-<subtarget>-<tag>`
  (`scripts/resolve-image.sh`).
  - `25.12` (`release_source: releases`): `<tag>` is the latest `25.12.x`
    release, found as `test.yml` finds its release (`latest_release` in
    `scripts/lib/common.sh`). The release image contains the Image Builder.
  - `main` (`release_source: snapshot`): `<tag>` is `main`, a snapshot tag
    that ships only `setup.sh`; the container downloads the Image Builder from
    `downloads.openwrt.org` when it starts (timed as "setup.sh" in the
    summary). Risk: that mirror gave ~330 KB/s from runners for the SDK.
  - The snapshot directory is published file by file. In runs 41427929552
    and 41427983225 (`ath79/generic`) `setup.sh` failed after an 8-15 minute
    download with `sha256sum: WARNING: 1 computed checksum did NOT match`:
    the `sha256sums` it got was signed on the day before and listed
    `c732955d...`, while the archive had been republished at 10:33:36 and the
    `sha256sums` only at 10:38:33 (`Last-Modified` read afterwards; the
    same archive then matched in run 41446811960). `scripts/ib-setup.sh`
    (called by `imagebuilder-make.sh`) therefore runs `setup.sh` again, up to
    3 times with 120 s between them, when and only when its output has the
    checksum mismatch; each retry prints `warn: image builder archive did not
    match sha256sums (attempt N of 3), retrying in 120 s` and a
    `::warning title=Image Builder setup retried::` annotation (shown in the
    run summary), and any other failure, or a mismatch in all attempts,
    fails the job. A retry starts only if the time used, the wait and the
    longest attempt so far fit in `HARNESS_IB_SETUP_BUDGET` (default 3000 s;
    the `image` job times out at 90 min = 5400 s and the pull, `make image`
    and the upload need the rest; one attempt took 3235 s for bananapi);
    otherwise the job fails at once with `not retrying: <used> s used, a
    retry needs about <n> s, budget <b> s` instead of being killed by the
    timeout. A retry fetches
    `sha256sums` again and restores the keys that `setup.sh` deletes.
    `scripts/ib-setup-selftest.sh` (step "Image Builder setup self-test" of
    the `profiles` job) runs it against a fake `setup.sh`.
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
  profile's `:too-big` suffix:

  | suffix            | Image builds | Image too big (proven)                         |
  |-------------------|--------------|------------------------------------------------|
  | absent (default)  | job green    | job fails, message and sizes quoted            |
  | `:too-big`        | job fails: "now fits", remove the suffix | job green, no artifact |

  The summary of a `:too-big` job quotes the Image Builder messages with the
  actual and limit bytes (for a tplink-safeloader image, the root filesystem
  against its partition, because the warning has no size).
  - Failures: a `make` error or a missing `.apk` fails the Image Builder step
    in both cases. A profile with `:too-big` that is proven too big
    skips the manifest check (`scripts/collect-images.sh`) and the artifact
    because no image exists, so a wrong manifest or a missing package in such
    a profile is not detected.
  - `scripts/image-outcome-selftest.sh` (step "Outcome check self-test" of the
    `profiles` job in `images.yml`) runs `check-image-outcome.sh` on fixed
    `make.log` fixtures: the empty-size warning alone, `10 > 20`, a
    `partition too big` without or with a smaller root filesystem must fail;
    the real `totolink-x5000r` and `tplink-archer-c7-v4` messages are a green
    too big; a fitting image and a fitting `:too-big` profile ("now
    fits") are checked too.
- The job summary (`scripts/image-summary.sh`) lists profile, Image Builder
  image and digest, size and pull time, `setup.sh` and `make image` durations,
  the expectation and outcome, the manifest check, every artifact file with
  size and sha256 and, on failure or expected failure, the Image Builder
  messages of `make.log`.
- Artifact: `images-<package>-<line>-<profile id>` (`nopkg` stands for the
  package when there is none; no artifact for a profile that is too big as
  expected).

## Own CI `ci.yml`

Tests the base with the sample package `chrony`. Every call passes
`ci_ref: ${{ github.sha }}`, the commit under test. On push to `feat/**` and on
`workflow_dispatch`.
Dispatch inputs: `refresh_sdk` (boolean, passed to `build.yml`) and `lines`
(`both`, `25.12` or `main`: the other build job is skipped); `package`
(default `chrony`), `feed_repository` and `feed_ref` (passed to `build.yml`,
see "Feed source"); `stages` (`all`, or `build` to skip the test and image
jobs); `profiles` and `packages` (the `profiles` and `packages` inputs; empty
profiles: `x86/64/generic`, passed to `build.yml` and `images.yml` like any caller; empty packages: the CI uses
`-dnsmasq dnsmasq-full`, which exercises the removal syntax and the manifest
check). Each build job has `packages: write`. The job `feed-report` prints the
feed outputs (`feed_repository`, `feed_ref`, `feed_sha`) of the builds that
succeeded.

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
- Build images with the package: call `images.yml` with the same `line`,
  `package`, `profiles` and `packages`, `needs:` the build job; pass the same
  `profiles` to `build.yml`, so that the architectures of the images are built.
- Package trees other than the line's branch of `openwrt/packages` (a test
  repository, an upstream pull request): `feed_repository` and `feed_ref` (see
  "Feed source"). Local feeds of the calling repository are not supported.

## Pinned test environment

The `openwrt-tests` checkout is pinned to `OPENWRT_TESTS_REF` in `test.yml`.
Its Python environment is pinned by `harness/openwrt-tests.uv.lock` (Python
3.15, labgrid at a fixed commit) and installed with `uv sync --locked`, so the
job fails if the lock no longer matches that `pyproject.toml`. To regenerate
after changing the ref, copy the `pyproject.toml` of the new ref to an empty
directory, run `uv lock --python 3.15` there and copy `uv.lock` to
`harness/openwrt-tests.uv.lock`.
