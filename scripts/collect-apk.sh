#!/usr/bin/env sh
# Responsibility: pick the one .apk of the package out of the SDK output
# tree, copy it alone to an output directory and print its name and version.
#
# Usage:
#   scripts/collect-apk.sh <sdk-output-dir> <out-dir> >> "$GITHUB_ENV"
#
# Environment variables:
#   HARNESS_PACKAGE  package name (required)

set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "${script_dir}/lib/common.sh"

package=${HARNESS_PACKAGE:?HARNESS_PACKAGE is required}
[ "$#" -eq 2 ] || die "usage: collect-apk.sh <sdk-output-dir> <out-dir>"
sdk_dir=$1
out_dir=$2
check_package_name "${package}"

apk_file=$(find_apk "${sdk_dir}" "${package}")
version=$(apk_version "${apk_file}" "${package}")
mkdir -p "${out_dir}" || die "cannot create ${out_dir}"
cp "${apk_file}" "${out_dir}/" || die "cannot copy ${apk_file}"

printf 'HARNESS_APK_FILE=%s\n' "$(basename "${apk_file}")"
printf 'HARNESS_PACKAGE_VERSION=%s\n' "${version}"
