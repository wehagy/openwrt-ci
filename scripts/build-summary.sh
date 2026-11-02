#!/usr/bin/env sh
# Responsibility: print the Markdown job summary of one SDK build job (line,
# arch, SDK image, packages feed commit, package version, duration).
#
# Usage:
#   scripts/build-summary.sh >> "$GITHUB_STEP_SUMMARY"
#
# Environment variables (set by scripts/resolve-build.sh, the checkout step
# and scripts/collect-apk.sh):
#   HARNESS_LINE, HARNESS_ARCH, HARNESS_SDK_IMAGE, HARNESS_SDK_DIGEST,
#   HARNESS_SDK_CREATED, HARNESS_SDK_ARCHIVE, HARNESS_SDK_ARCHIVE_SHA256,
#   HARNESS_SDK_STATE (scripts/sdk-image-info.sh),
#   HARNESS_PACKAGES_BRANCH, HARNESS_PACKAGES_SHA, HARNESS_PACKAGE,
#   HARNESS_PACKAGE_VERSION, HARNESS_APK_FILE, HARNESS_BUILD_SECONDS

set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "${script_dir}/lib/common.sh"

line=${HARNESS_LINE:?HARNESS_LINE is required}
arch=${HARNESS_ARCH:?HARNESS_ARCH is required}
sdk_image=${HARNESS_SDK_IMAGE:?HARNESS_SDK_IMAGE is required}
sdk_digest=${HARNESS_SDK_DIGEST:?HARNESS_SDK_DIGEST is required}
sdk_created=${HARNESS_SDK_CREATED:?HARNESS_SDK_CREATED is required}
sdk_archive=${HARNESS_SDK_ARCHIVE:?HARNESS_SDK_ARCHIVE is required}
sdk_archive_sha=${HARNESS_SDK_ARCHIVE_SHA256:?HARNESS_SDK_ARCHIVE_SHA256 is required}
sdk_state=${HARNESS_SDK_STATE:?HARNESS_SDK_STATE is required}
packages_branch=${HARNESS_PACKAGES_BRANCH:?HARNESS_PACKAGES_BRANCH is required}
packages_sha=${HARNESS_PACKAGES_SHA:?HARNESS_PACKAGES_SHA is required}
package=${HARNESS_PACKAGE:?HARNESS_PACKAGE is required}
version=${HARNESS_PACKAGE_VERSION:?HARNESS_PACKAGE_VERSION is required}
apk_file=${HARNESS_APK_FILE:?HARNESS_APK_FILE is required}
seconds=${HARNESS_BUILD_SECONDS:?HARNESS_BUILD_SECONDS is required}

printf '### build %s / %s\n' "${line}" "${arch}"
printf -- '- line: %s\n' "${line}"
printf -- '- arch: %s\n' "${arch}"
printf -- '- SDK image: %s (%s)\n' "${sdk_image}" "${sdk_digest}"
printf -- '- SDK image state: %s, created %s\n' "${sdk_state}" "${sdk_created}"
printf -- '- SDK archive: %s (sha256 %s)\n' "${sdk_archive}" "${sdk_archive_sha}"
printf -- '- packages feed: openwrt/packages %s @ %s\n' \
	"${packages_branch}" "${packages_sha}"
printf -- '- package: %s %s (%s)\n' "${package}" "${version}" "${apk_file}"
printf -- '- build duration: %s s\n' "${seconds}"
