#!/usr/bin/env sh
# Responsibility: resolve the build data of one (line, arch) pair from
# harness/lines.yml and print it as KEY=value lines: SDK container image and
# tag, and the branch of the openwrt/packages feed to build from.
#
# Usage:
#   scripts/resolve-build.sh <line> <arch> >> "$GITHUB_ENV"
#
# Environment variables:
#   HARNESS_DIR            directory with lines.yml (default: <repo>/harness)
#   HARNESS_SDK_CONTAINER  SDK image repository
#                          (default: docker.io/openwrt/sdk)

set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "${script_dir}/lib/common.sh"

[ "$#" -eq 2 ] || die "usage: resolve-build.sh <line> <arch>"
LINE=$1
arch=$2
export LINE
harness_dir=${HARNESS_DIR:-${script_dir}/../harness}
lines_file=${harness_dir}/lines.yml
container=${HARNESS_SDK_CONTAINER:-docker.io/openwrt/sdk}

line_key='.lines[strenv(LINE)]'
sdk_suffix=$(yq_get "${lines_file}" "${line_key}.sdk_tag_suffix")
packages_branch=$(yq_get "${lines_file}" "${line_key}.packages_branch")

# gh-action-sdk builds "<container>:<ARCH>", so the tag is <arch>-<suffix>.
printf 'HARNESS_LINE=%s\n' "${LINE}"
printf 'HARNESS_ARCH=%s\n' "${arch}"
printf 'HARNESS_SDK_CONTAINER=%s\n' "${container}"
printf 'HARNESS_SDK_ARCH=%s-%s\n' "${arch}" "${sdk_suffix}"
printf 'HARNESS_SDK_IMAGE=%s:%s-%s\n' "${container}" "${arch}" "${sdk_suffix}"
printf 'HARNESS_PACKAGES_BRANCH=%s\n' "${packages_branch}"
