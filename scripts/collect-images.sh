#!/usr/bin/env sh
# Responsibility: check that the ImageBuilder manifest lists the built
# package at the built version, then copy the firmware images (files matching
# the globs), the manifest and sha256sums of one build to an output
# directory. A missing manifest line, or no image file, is an error.
#
# Usage:
#   scripts/collect-images.sh <imagebuilder-out-dir> <image-dir> >> "$GITHUB_ENV"
#
# Environment variables:
#   HARNESS_PACKAGE          package name (required)
#   HARNESS_PACKAGE_VERSION  version of the built .apk (required)
#   HARNESS_IMAGE_GLOBS      space separated file name globs (required)

set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "${script_dir}/lib/common.sh"

package=${HARNESS_PACKAGE:?HARNESS_PACKAGE is required}
version=${HARNESS_PACKAGE_VERSION:?HARNESS_PACKAGE_VERSION is required}
globs=${HARNESS_IMAGE_GLOBS:?HARNESS_IMAGE_GLOBS is required}
[ "$#" -eq 2 ] || die "usage: collect-images.sh <imagebuilder-out-dir> <image-dir>"
ib_dir=$1
image_dir=$2
check_package_name "${package}"
check_apk_version "${version}"

# ---------------------------------------------------------------------------
# Manifest: "<package> - <version>" must be a whole line.
# ---------------------------------------------------------------------------
manifest=$(find "${ib_dir}" -maxdepth 1 -type f -name '*.manifest') ||
	die "cannot search ${ib_dir}"
[ -n "${manifest}" ] || die "no .manifest in ${ib_dir}"
manifest_count=$(printf '%s\n' "${manifest}" | wc -l)
[ "${manifest_count}" -eq 1 ] ||
	die "expected one .manifest in ${ib_dir}: ${manifest}"
expected="${package} - ${version}"
if ! grep -Fx -- "${expected}" "${manifest}"; then
	printf 'manifest lines mentioning %s:\n' "${package}" >&2
	grep -F -- "${package}" "${manifest}" >&2 || printf '(none)\n' >&2
	die "$(basename "${manifest}") has no line '${expected}'"
fi

# ---------------------------------------------------------------------------
# Images, manifest and checksums.
# ---------------------------------------------------------------------------
mkdir -p "${image_dir}" || die "cannot create ${image_dir}"
count=0
# No pathname expansion: the globs are patterns for find, not for the shell.
set -f
for glob in ${globs}; do
	found=$(find "${ib_dir}" -maxdepth 1 -type f -name "${glob}" | wc -l) ||
		die "cannot search ${ib_dir}"
	count=$((count + found))
	find "${ib_dir}" -maxdepth 1 -type f -name "${glob}" -exec cp {} "${image_dir}/" \; ||
		die "cannot copy images matching ${glob}"
done
[ "${count}" -gt 0 ] || die "no image matching '${globs}' in ${ib_dir}"
cp "${manifest}" "${ib_dir}/sha256sums" "${image_dir}/" ||
	die "cannot copy the manifest and sha256sums"

printf 'HARNESS_MANIFEST_LINE=%s\n' "${expected}"
printf 'HARNESS_MANIFEST_FILE=%s\n' "$(basename "${manifest}")"
