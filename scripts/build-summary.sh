#!/usr/bin/env sh
# Responsibility: print the Markdown job summary of one SDK build job (line,
# arch, SDK image, feed source: repository, ref and commit; package version,
# duration).
#
# Usage:
#   scripts/build-summary.sh >> "$GITHUB_STEP_SUMMARY"
#
# Environment variables (set by scripts/resolve-build.sh, the checkout step
# and scripts/collect-apk.sh):
#   HARNESS_LINE, HARNESS_ARCH, HARNESS_SDK_IMAGE, HARNESS_SDK_DIGEST,
#   HARNESS_SDK_CREATED, HARNESS_SDK_ARCHIVE, HARNESS_SDK_ARCHIVE_SHA256,
#   HARNESS_SDK_PIN (scripts/sdk-image-info.sh),
#   HARNESS_PACKAGES_REPOSITORY, HARNESS_PACKAGES_REF, HARNESS_PACKAGES_SHA,
#   HARNESS_PACKAGE,
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
sdk_pin=${HARNESS_SDK_PIN:?HARNESS_SDK_PIN is required}
packages_repository=${HARNESS_PACKAGES_REPOSITORY:?HARNESS_PACKAGES_REPOSITORY is required}
packages_ref=${HARNESS_PACKAGES_REF:?HARNESS_PACKAGES_REF is required}
packages_sha=${HARNESS_PACKAGES_SHA:?HARNESS_PACKAGES_SHA is required}
package=${HARNESS_PACKAGE:?HARNESS_PACKAGE is required}
version=${HARNESS_PACKAGE_VERSION:?HARNESS_PACKAGE_VERSION is required}
apk_file=${HARNESS_APK_FILE:?HARNESS_APK_FILE is required}
seconds=${HARNESS_BUILD_SECONDS:?HARNESS_BUILD_SECONDS is required}

printf '### build %s / %s\n' "${line}" "${arch}"
printf -- '- line: %s\n' "${line}"
printf -- '- arch: %s\n' "${arch}"
printf -- '- SDK image: %s (%s), built from %s\n' "${sdk_image}" "${sdk_digest}" "${sdk_pin}"
printf -- '- SDK image created %s\n' "${sdk_created}"
printf -- '- SDK archive: %s (sha256 %s)\n' "${sdk_archive}" "${sdk_archive_sha}"
printf -- '- packages feed: %s %s @ %s\n' \
	"${packages_repository}" "${packages_ref}" "${packages_sha}"
printf -- '- package: %s %s (%s)\n' "${package}" "${version}" "${apk_file}"
printf -- '- build duration: %s s\n' "${seconds}"
