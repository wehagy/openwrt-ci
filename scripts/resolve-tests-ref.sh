#!/usr/bin/env sh
# Responsibility: resolve the branch of aparcar/openwrt-tests that the QEMU
# jobs follow to one commit, once per workflow run, so that every target job
# of the run tests with the same openwrt-tests (a job that resolved the branch
# itself could see a push that landed between two jobs). Also prints the
# instant of the resolution: the jobs resolve the PyPI dependencies as of
# that instant (scripts/prepare-tests-env.sh), so a release published during
# the run cannot split the targets either.
#
# Usage:
#   scripts/resolve-tests-ref.sh >> "$GITHUB_OUTPUT"
#
# Prints: tests_sha=<40 hex digits>, tests_resolved_at=<UTC, RFC 3339>
#
# Environment variables:
#   HARNESS_TESTS_REPO_URL  repository to read (default
#                           https://github.com/aparcar/openwrt-tests)
#   HARNESS_TESTS_BRANCH    branch to follow (default main)

set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "${script_dir}/lib/common.sh"

repo=${HARNESS_TESTS_REPO_URL:-https://github.com/aparcar/openwrt-tests}
branch=${HARNESS_TESTS_BRANCH:-main}

# Take the instant before the lookup: a release between the two is excluded
# from the dependencies, a commit of the tests never is.
resolved_at=$(date -u +%Y-%m-%dT%H:%M:%SZ) || die "cannot read the clock"
line=$(git ls-remote --exit-code "${repo}" "refs/heads/${branch}") ||
	die "cannot read refs/heads/${branch} of ${repo}"
sha=${line%%[[:space:]]*}
case "${sha}" in
*[!0-9a-f]* | '') die "unexpected answer of git ls-remote for ${branch}" ;;
*) ;;
esac
[ "${#sha}" -eq 40 ] || die "unexpected answer of git ls-remote for ${branch}"

printf 'tests_sha=%s\n' "${sha}"
printf 'tests_resolved_at=%s\n' "${resolved_at}"
printf 'openwrt-tests %s -> %s (as of %s)\n' "${branch}" "${sha}" "${resolved_at}" >&2
