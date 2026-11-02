#!/usr/bin/env sh
# Responsibility: check that the ImageBuilder manifest lists the built
# package at the built version and the packages the caller asked for (and not
# those it removed), then copy the firmware images (files matching the globs),
# the manifest and sha256sums of one build to an output directory. A missing
# or unexpected manifest line, or no image file, is an error.
#
# Usage:
#   scripts/collect-images.sh <imagebuilder-out-dir> <image-dir> >> "$GITHUB_ENV"
#
# Environment variables:
#   HARNESS_PACKAGE          package name; empty: no package of our own, the
#                            manifest line check is skipped (required to be set)
#   HARNESS_PACKAGE_VERSION  version of the built .apk (required with a package)
#   HARNESS_IMAGE_PACKAGES   the `packages` input: <name> must be in the
#                            manifest, -<name> must not (default: empty)
#   HARNESS_IMAGE_GLOBS      space separated file name globs (required)

set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "${script_dir}/lib/common.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/image-inputs.sh
. "${script_dir}/lib/image-inputs.sh"

package=${HARNESS_PACKAGE?HARNESS_PACKAGE is required}
version=${HARNESS_PACKAGE_VERSION:-}
image_packages=${HARNESS_IMAGE_PACKAGES:-}
globs=${HARNESS_IMAGE_GLOBS:?HARNESS_IMAGE_GLOBS is required}
[ "$#" -eq 2 ] || die "usage: collect-images.sh <imagebuilder-out-dir> <image-dir>"
ib_dir=$1
image_dir=$2
if [ -n "${package}" ]; then
	check_package_name "${package}"
	check_apk_version "${version}"
fi
check_image_packages "${image_packages}"

# ---------------------------------------------------------------------------
# Manifest: "<package> - <version>" must be a whole line; every package the
# caller added must be listed, every package it removed must not.
# ---------------------------------------------------------------------------
manifest=$(find "${ib_dir}" -maxdepth 1 -type f -name '*.manifest') ||
	die "cannot search ${ib_dir}"
[ -n "${manifest}" ] || die "no .manifest in ${ib_dir}"
manifest_count=$(printf '%s\n' "${manifest}" | wc -l)
[ "${manifest_count}" -eq 1 ] ||
	die "expected one .manifest in ${ib_dir}: ${manifest}"
expected=
if [ -n "${package}" ]; then
	expected="${package} - ${version}"
	if ! grep -Fxq -- "${expected}" "${manifest}"; then
		printf 'manifest lines mentioning %s:\n' "${package}" >&2
		grep -F -- "${package}" "${manifest}" >&2 || printf '(none)\n' >&2
		die "$(basename "${manifest}") has no line '${expected}'"
	fi
fi
# The tokens were validated above, so the glob characters are not in them.
for token in ${image_packages}; do
	name=${token#-}
	# A manifest line is "<name> - <version>"; the name is compared whole
	# (a prefix match would take dnsmasq-full for dnsmasq).
	listed=$(awk -v n="${name}" '$1 == n && $2 == "-" { found = 1 } END { print found + 0 }' "${manifest}") ||
		die "cannot read ${manifest}"
	case "${token}:${listed}" in
	-*:1) die "$(basename "${manifest}") lists ${name}, which the packages input removes" ;;
	-*:0) ;;
	*:0) die "$(basename "${manifest}") does not list ${name}, which the packages input adds" ;;
	*:1) ;;
	*) die "cannot check ${name} in $(basename "${manifest}")" ;;
	esac
done

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

if [ -n "${expected}" ]; then
	printf 'HARNESS_MANIFEST_LINE=%s\n' "${expected}"
fi
printf 'HARNESS_MANIFEST_FILE=%s\n' "$(basename "${manifest}")"
