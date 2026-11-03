#!/usr/bin/env sh
# Responsibility: validate a (line, arch) pair and resolve the SDK image data
# from harness/lines.yml, printed as KEY=value lines: the harness SDK image
# (own, on GHCR), the official base image it is derived from, its tag and the
# grace period of its stale warning. Nothing is printed unless every input is valid, so the output
# is safe for $GITHUB_ENV.
#
# Usage:
#   scripts/resolve-sdk.sh <line> <arch> >> "$GITHUB_ENV"
#
# Environment variables:
#   HARNESS_DIR                 directory with lines.yml (default: <repo>/harness)
#   HARNESS_SDK_CONTAINER       harness SDK image repository, required; set
#                               once, in .github/workflows/build.yml
#                               (ghcr.io/<owner>/openwrt-sdk)
#   HARNESS_SDK_BASE_CONTAINER  official SDK image repository
#                               (default: docker.io/openwrt/sdk)

set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "${script_dir}/lib/common.sh"

[ "$#" -eq 2 ] || die "usage: resolve-sdk.sh <line> <arch>"
LINE=$1
arch=$2
export LINE
check_line "${LINE}"
case "${arch}" in
*[!a-z0-9_-]* | '') die "invalid arch: ${arch}" ;;
*) ;;
esac
lines_file=${HARNESS_DIR:-${script_dir}/../harness}/lines.yml
# Registry names are lowercase; the owner may come from github.repository_owner.
container=$(printf '%s\n' "${HARNESS_SDK_CONTAINER:?HARNESS_SDK_CONTAINER is required}" | tr '[:upper:]' '[:lower:]') ||
	die "cannot normalise the SDK container"
check_sdk_container "${container}"
base_container=${HARNESS_SDK_BASE_CONTAINER:-docker.io/openwrt/sdk}
case "${base_container}" in
*[!a-z0-9./_-]* | '') die "invalid base SDK container" ;;
*) ;;
esac

line_key='.lines[strenv(LINE)]'
# A line that is not a key of lines.yml fails here, before any output.
sdk_suffix=$(yq_get "${lines_file}" "${line_key}.sdk_tag_suffix")
grace_days=$(yq_get "${lines_file}" "${line_key}.image_grace_days")
check_grace_days "${grace_days}"

# gh-action-sdk builds "<container>:<ARCH>", so the tag is <arch>-<suffix>.
tag="${arch}-${sdk_suffix}"
check_sdk_tag "${tag}"
printf 'HARNESS_LINE=%s\n' "${LINE}"
printf 'HARNESS_ARCH=%s\n' "${arch}"
printf 'HARNESS_SDK_CONTAINER=%s\n' "${container}"
printf 'HARNESS_SDK_ARCH=%s\n' "${tag}"
printf 'HARNESS_SDK_IMAGE=%s:%s\n' "${container}" "${tag}"
printf 'HARNESS_SDK_BASE_IMAGE=%s:%s\n' "${base_container}" "${tag}"
printf 'HARNESS_SDK_GRACE_DAYS=%s\n' "${grace_days}"
