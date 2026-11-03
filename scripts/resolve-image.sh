#!/usr/bin/env sh
# Responsibility: validate the inputs of one image job and resolve its data
# from harness/lines.yml and harness/images.yml and from the matrix entry that
# scripts/resolve-profiles.sh made, printed as KEY=value lines: ImageBuilder
# container image, package list, profile, artifact name and the globs that
# select the image files. Nothing is printed unless every input and every
# value read from the YAML files is valid, so the output is safe for
# $GITHUB_ENV.
#
# The ImageBuilder image is the harness image on GHCR,
# <HARNESS_IB_CONTAINER>:<target>-<subtarget>-<imagebuilder_tag_suffix>, which
# the daily refresh (refresh-images.yml) keeps up to date: a copy of the
# official release container for a "releases" line, the official snapshot
# container with setup.sh already run for a "snapshot" line. The job only reads
# it. HARNESS_IB_RELEASE is the latest release of a "releases" line now (empty
# for a snapshot), which scripts/image-stale-check.sh compares with the
# release the image holds.
#
# HARNESS_EXPECT is "too-big" for a profile given with the :too-big suffix
# (its image is known not to fit the flash), otherwise "fits".
#
# The package list of the Image Builder is the caller's `packages` input
# (additions and -removals) followed by the built package, if there is one.
# The artifact is images-<package>-<line>-<profile id>; without a package the
# word "nopkg" stands for the package.
#
# Usage:
#   scripts/resolve-image.sh <line> <profile-id> <package> >> "$GITHUB_ENV"
#   (<package> may be empty: images without a package of their own)
#
# Environment variables:
#   HARNESS_IMAGE_TARGET, HARNESS_IMAGE_SUBTARGET, HARNESS_IMAGE_DEVICE,
#   HARNESS_IMAGE_ARCH, HARNESS_IMAGE_EXPECT
#                        the matrix entry (required)
#   HARNESS_IMAGE_PACKAGES  the `packages` input (default: empty)
#   HARNESS_DIR          directory with lines.yml and images.yml
#                        (default: <repo>/harness)
#   HARNESS_IB_CONTAINER harness ImageBuilder image repository, required; set
#                        once, in .github/workflows/images.yml
#                        (ghcr.io/<owner>/openwrt-imagebuilder)

set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "${script_dir}/lib/common.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/image-inputs.sh
. "${script_dir}/lib/image-inputs.sh"

[ "$#" -eq 3 ] || die "usage: resolve-image.sh <line> <profile-id> <package>"
LINE=$1
PROFILE_ID=$2
package=$3
export LINE
check_line "${LINE}"
check_charset "profile id" "${PROFILE_ID}" '[!a-z0-9-]'
if [ -n "${package}" ]; then
	check_package_name "${package}"
fi
target=${HARNESS_IMAGE_TARGET:-}
[ -n "${target}" ] || die "HARNESS_IMAGE_TARGET is required"
subtarget=${HARNESS_IMAGE_SUBTARGET:-}
[ -n "${subtarget}" ] || die "HARNESS_IMAGE_SUBTARGET is required"
profile=${HARNESS_IMAGE_DEVICE:-}
[ -n "${profile}" ] || die "HARNESS_IMAGE_DEVICE is required"
arch=${HARNESS_IMAGE_ARCH:-}
[ -n "${arch}" ] || die "HARNESS_IMAGE_ARCH is required"
expect=${HARNESS_IMAGE_EXPECT:-}
[ -n "${expect}" ] || die "HARNESS_IMAGE_EXPECT is required"
image_packages=${HARNESS_IMAGE_PACKAGES:-}
harness_dir=${HARNESS_DIR:-${script_dir}/../harness}
lines_file=${harness_dir}/lines.yml
images_file=${harness_dir}/images.yml
# Registry names are lowercase; the owner may come from github.repository_owner.
container=$(printf '%s\n' "${HARNESS_IB_CONTAINER:?HARNESS_IB_CONTAINER is required}" | tr '[:upper:]' '[:lower:]') ||
	die "cannot normalise the Image Builder container"
check_sdk_container "${container}"

line_key='.lines[strenv(LINE)]'
image_globs=$(yq_get "${images_file}" '.image_globs')
release_source=$(yq_get "${lines_file}" "${line_key}.release_source")

check_charset "target" "${target}" '[!a-z0-9]'
check_charset "subtarget" "${subtarget}" '[!a-z0-9]'
check_charset "profile" "${profile}" '[!A-Za-z0-9_-]'
check_package_arch "${arch}"
case "${expect}" in
fits | too-big) ;;
*) die "invalid expect of profile ${PROFILE_ID} (allowed: fits, too-big)" ;;
esac
check_image_packages "${image_packages}"
check_charset "image_globs" "${image_globs}" '[!A-Za-z0-9*._ -]'

case "${release_source}" in
releases)
	index_url=$(yq_get "${lines_file}" "${line_key}.releases_index_url")
	release_regex=$(yq_get "${lines_file}" "${line_key}.release_regex")
	release=$(latest_release "${index_url}" "${release_regex}")
	check_charset "release" "${release}" '[!A-Za-z0-9._-]'
	;;
snapshot) release= ;;
*) die "unsupported release_source of line ${LINE}" ;;
esac
tag_suffix=$(yq_get "${lines_file}" "${line_key}.imagebuilder_tag_suffix")
grace_days=$(yq_get "${lines_file}" "${line_key}.image_grace_days")
check_grace_days "${grace_days}"
ib_image_tag=$(ib_tag "${target}" "${subtarget}" "${tag_suffix}")
check_sdk_tag "${ib_image_tag}"

printf 'HARNESS_LINE=%s\n' "${LINE}"
printf 'HARNESS_PROFILE_ID=%s\n' "${PROFILE_ID}"
printf 'HARNESS_PROFILE=%s\n' "${profile}"
printf 'HARNESS_ARCH=%s\n' "${arch}"
printf 'HARNESS_PACKAGE=%s\n' "${package}"
packages_line=$(image_packages_line "${image_packages}")
all_packages_line=$(image_packages_line "${image_packages} ${package}")
printf 'HARNESS_IMAGE_PACKAGES=%s\n' "${packages_line}"
printf 'HARNESS_PACKAGES=%s\n' "${all_packages_line}"
printf 'HARNESS_ARTIFACT=images-%s-%s-%s\n' "${package:-nopkg}" "${LINE}" "${PROFILE_ID}"
printf 'HARNESS_TARGET_PATH=%s/%s\n' "${target}" "${subtarget}"
printf 'HARNESS_IB_IMAGE=%s:%s\n' "${container}" "${ib_image_tag}"
printf 'HARNESS_IB_RELEASE=%s\n' "${release}"
printf 'HARNESS_IB_GRACE_DAYS=%s\n' "${grace_days}"
printf 'HARNESS_IMAGE_GLOBS=%s\n' "${image_globs}"
printf 'HARNESS_EXPECT=%s\n' "${expect}"
