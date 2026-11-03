#!/usr/bin/env sh
# Responsibility: build the Python environment of the openwrt-tests checkout
# and print the versions it resolved to. openwrt-tests is not pinned here and
# labgrid comes from PyPI (harness/uv.toml: latest 26.x), so neither is in the
# lock; every other dependency stays at the version of the seed lock
# (harness/openwrt-tests.uv.lock) and only changes when upstream's
# pyproject.toml asks for something the seed cannot satisfy.
#
# Usage:
#   scripts/prepare-tests-env.sh <openwrt-tests-dir> >> "$GITHUB_ENV"
#
# Prints (for GITHUB_ENV): UV_NO_SOURCES, UV_CONFIG_FILE, UV_EXCLUDE_NEWER
# (the later `uv run` must see the settings the lock was made with) and
# HARNESS_OPENWRT_TESTS_SHA, HARNESS_LABGRID_VERSION (read back from the
# checkout and from the lock that `uv sync --locked` installed).
#
# Environment variables:
#   HARNESS_TESTS_SHA          commit the checkout must be at (required)
#   HARNESS_TESTS_RESOLVED_AT  RFC 3339 instant: newest PyPI upload that may
#                              be resolved (required; resolve-tests-ref.sh)

set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "${script_dir}/lib/common.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/uv-lock.sh
. "${script_dir}/lib/uv-lock.sh"

[ "$#" -eq 1 ] || die "usage: prepare-tests-env.sh <openwrt-tests-dir>"
tests_dir=$1
expected_sha=${HARNESS_TESTS_SHA:?HARNESS_TESTS_SHA is required}
resolved_at=${HARNESS_TESTS_RESOLVED_AT:?HARNESS_TESTS_RESOLVED_AT is required}

actual_sha=$(git -C "${tests_dir}" rev-parse HEAD) ||
	die "${tests_dir} is not a git checkout"
[ "${actual_sha}" = "${expected_sha}" ] ||
	die "openwrt-tests is at ${actual_sha}, expected ${expected_sha}"

config_file=$(cd "${script_dir}/../harness" && pwd)/uv.toml
seed_lock=${config_file%/uv.toml}/openwrt-tests.uv.lock
[ -f "${config_file}" ] || die "no such file: ${config_file}"
[ -f "${seed_lock}" ] || die "no such file: ${seed_lock}"

UV_NO_SOURCES=1
UV_CONFIG_FILE=${config_file}
UV_EXCLUDE_NEWER=${resolved_at}
export UV_NO_SOURCES UV_CONFIG_FILE UV_EXCLUDE_NEWER

# The seed keeps the other dependencies where they are; labgrid is asked for
# again so that it moves to the newest 26.x as of the resolution instant.
cp "${seed_lock}" "${tests_dir}/uv.lock"
uv --project "${tests_dir}" lock --upgrade-package labgrid >&2
uv --project "${tests_dir}" sync --locked >&2

labgrid_version=$(lock_package_version "${tests_dir}/uv.lock" labgrid)

printf 'UV_NO_SOURCES=%s\n' "${UV_NO_SOURCES}"
printf 'UV_CONFIG_FILE=%s\n' "${UV_CONFIG_FILE}"
printf 'UV_EXCLUDE_NEWER=%s\n' "${UV_EXCLUDE_NEWER}"
printf 'HARNESS_OPENWRT_TESTS_SHA=%s\n' "${actual_sha}"
printf 'HARNESS_LABGRID_VERSION=%s\n' "${labgrid_version}"
