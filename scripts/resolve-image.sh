#!/usr/bin/env sh
# Responsibility: validate the inputs of one image job and resolve its data
# from harness/lines.yml and harness/images.yml, printed as KEY=value lines:
# ImageBuilder container image, package list, profile and the globs that
# select the image files. Nothing is printed unless every input and every
# value read from the YAML files is valid, so the output is safe for
# $GITHUB_ENV.
#
# The ImageBuilder tag is <target>-<subtarget>-<release> when the line's
# release_source is "releases" (the release image embeds the ImageBuilder),
# <target>-<subtarget>-<imagebuilder_tag_suffix> for "snapshot", a tag that
# ships only setup.sh (HARNESS_IB_SETUP=true: the ImageBuilder is downloaded when
# the container runs).
#
# Usage:
#   scripts/resolve-image.sh <line> <profile-id> <package> >> "$GITHUB_ENV"
#
# Environment variables:
#   HARNESS_DIR          directory with lines.yml and images.yml
#                        (default: <repo>/harness)
#   HARNESS_IB_CONTAINER ImageBuilder image repository
#                        (default: docker.io/openwrt/imagebuilder)

set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "${script_dir}/lib/common.sh"

[ "$#" -eq 3 ] || die "usage: resolve-image.sh <line> <profile-id> <package>"
LINE=$1
PROFILE_ID=$2
package=$3
export LINE PROFILE_ID
check_line "${LINE}"
check_charset "profile id" "${PROFILE_ID}" '[!a-z0-9-]'
check_package_name "${package}"
harness_dir=${HARNESS_DIR:-${script_dir}/../harness}
lines_file=${harness_dir}/lines.yml
images_file=${harness_dir}/images.yml
container=${HARNESS_IB_CONTAINER:-docker.io/openwrt/imagebuilder}

line_key='.lines[strenv(LINE)]'
profile_key='.profiles[strenv(PROFILE_ID)]'
target=$(yq_get "${images_file}" "${profile_key}.target")
subtarget=$(yq_get "${images_file}" "${profile_key}.subtarget")
profile=$(yq_get "${images_file}" "${profile_key}.profile")
arch=$(yq_get "${images_file}" "${profile_key}.arch")
extra_packages=$(yq_get "${images_file}" '.extra_packages')
image_globs=$(yq_get "${images_file}" '.image_globs')
release_source=$(yq_get "${lines_file}" "${line_key}.release_source")

check_charset "target" "${target}" '[!a-z0-9]'
check_charset "subtarget" "${subtarget}" '[!a-z0-9]'
check_charset "profile" "${profile}" '[!A-Za-z0-9_-]'
check_charset "arch" "${arch}" '[!a-z0-9_-]'
check_charset "image_globs" "${image_globs}" '[!A-Za-z0-9*._ -]'
for extra in ${extra_packages}; do
	check_package_name "${extra}"
done

case "${release_source}" in
releases)
	index_url=$(yq_get "${lines_file}" "${line_key}.releases_index_url")
	release_regex=$(yq_get "${lines_file}" "${line_key}.release_regex")
	tag_suffix=$(latest_release "${index_url}" "${release_regex}")
	setup=false
	;;
snapshot)
	tag_suffix=$(yq_get "${lines_file}" "${line_key}.imagebuilder_tag_suffix")
	setup=true
	;;
*) die "unsupported release_source of line ${LINE}" ;;
esac
check_charset "ImageBuilder tag suffix" "${tag_suffix}" '[!A-Za-z0-9._-]'

printf 'HARNESS_LINE=%s\n' "${LINE}"
printf 'HARNESS_PROFILE_ID=%s\n' "${PROFILE_ID}"
printf 'HARNESS_PROFILE=%s\n' "${profile}"
printf 'HARNESS_ARCH=%s\n' "${arch}"
printf 'HARNESS_PACKAGE=%s\n' "${package}"
printf 'HARNESS_PACKAGES=%s %s\n' "${extra_packages}" "${package}"
printf 'HARNESS_TARGET_PATH=%s/%s\n' "${target}" "${subtarget}"
printf 'HARNESS_IB_IMAGE=%s:%s-%s-%s\n' "${container}" "${target}" "${subtarget}" "${tag_suffix}"
printf 'HARNESS_IB_SETUP=%s\n' "${setup}"
printf 'HARNESS_IMAGE_GLOBS=%s\n' "${image_globs}"
