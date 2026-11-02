#!/usr/bin/env sh
# Responsibility: validate the inputs of one build job and resolve its data
# from harness/lines.yml, printed as KEY=value lines: the SDK image data (see
# resolve-sdk.sh) and the branch of the openwrt/packages feed to build from.
# Nothing is printed unless every input is valid, so the output is safe for
# $GITHUB_ENV.
#
# Usage:
#   scripts/resolve-build.sh <line> <arch> <package> >> "$GITHUB_ENV"
#
# Environment variables:
#   HARNESS_DIR  directory with lines.yml (default: <repo>/harness)
#   and those of resolve-sdk.sh

set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "${script_dir}/lib/common.sh"

[ "$#" -eq 3 ] || die "usage: resolve-build.sh <line> <arch> <package>"
LINE=$1
arch=$2
package=$3
export LINE
check_package_name "${package}"
harness_dir=${HARNESS_DIR:-${script_dir}/../harness}
lines_file=${harness_dir}/lines.yml

# Validates line and arch; nothing is printed on failure.
sdk_data=$("${script_dir}/resolve-sdk.sh" "${LINE}" "${arch}") ||
	die "cannot resolve the SDK image"
packages_branch=$(yq_get "${lines_file}" '.lines[strenv(LINE)].packages_branch')

printf '%s\n' "${sdk_data}"
printf 'HARNESS_PACKAGE=%s\n' "${package}"
printf 'HARNESS_PACKAGES_BRANCH=%s\n' "${packages_branch}"
