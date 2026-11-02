#!/usr/bin/env sh
# Responsibility: run inside an official OpenWrt ImageBuilder container: put
# the built .apk into the ImageBuilder package directory, build one profile
# and copy the build output to the mounted output directory. The unsigned
# .apk needs no signature override: the ImageBuilder indexes its packages/
# directory itself and signs that index with its local key.
#
# The ImageBuilder fails or keeps going when an image does not fit the flash:
# check-size only prints "WARNING: Image file ... is too big" and deletes the
# image, so that message is turned into a failure here.
#
# Usage:
#   sh /harness/scripts/imagebuilder-make.sh
#
# Environment variables:
#   HARNESS_PROFILE       ImageBuilder PROFILE (required)
#   HARNESS_PACKAGES      packages to install, space separated (required)
#   HARNESS_TARGET_PATH   <target>/<subtarget> (required)
#   HARNESS_IB_SETUP      true: download the ImageBuilder with ./setup.sh
#                         first (snapshot tags); false: it is in the image
#   HARNESS_APK_DIR       directory with the built .apk (default: /harness/in)
#   HARNESS_PACKAGE       package name, to find its .apk (required)
#   HARNESS_OUT_DIR       writable output directory (default: /harness/out)

set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "${script_dir}/lib/common.sh"

profile=${HARNESS_PROFILE:?HARNESS_PROFILE is required}
packages=${HARNESS_PACKAGES:?HARNESS_PACKAGES is required}
target_path=${HARNESS_TARGET_PATH:?HARNESS_TARGET_PATH is required}
setup=${HARNESS_IB_SETUP:?HARNESS_IB_SETUP is required}
package=${HARNESS_PACKAGE:?HARNESS_PACKAGE is required}
apk_dir=${HARNESS_APK_DIR:-/harness/in}
out_dir=${HARNESS_OUT_DIR:-/harness/out}
check_package_name "${package}"

# ---------------------------------------------------------------------------
# ImageBuilder download (snapshot tags only).
# ---------------------------------------------------------------------------
setup_seconds=0
case "${setup}" in
true)
	start=$(date +%s)
	TARGET=${target_path} ./setup.sh
	end=$(date +%s)
	setup_seconds=$((end - start))
	;;
false) [ -f Makefile ] || die "no ImageBuilder in the image (no Makefile in ${PWD})" ;;
*) die "HARNESS_IB_SETUP must be true or false" ;;
esac
printf '%s\n' "${setup_seconds}" >"${out_dir}/setup-seconds"

# ---------------------------------------------------------------------------
# Build.
# ---------------------------------------------------------------------------
apk_file=$(find_apk "${apk_dir}" "${package}")
cp "${apk_file}" packages/ || die "cannot copy ${apk_file} to packages/"

make_log=${out_dir}/make.log
make_rc=${out_dir}/make.rc
start=$(date +%s)
{
	rc=0
	make image PROFILE="${profile}" PACKAGES="${packages}" 2>&1 || rc=$?
	echo "${rc}" >"${make_rc}"
} | tee "${make_log}"
end=$(date +%s)
printf '%s\n' "$((end - start))" >"${out_dir}/make-seconds"
read -r status <"${make_rc}"
[ "${status}" -eq 0 ] || die "make image failed with status ${status}"

# check-size turns "too big" into a WARNING and deletes the image.
if grep -E 'WARNING: Image file .* is too big' "${make_log}"; then
	die "an image of profile ${profile} does not fit the flash (ImageBuilder message above)"
fi

cp -R "bin/targets/${target_path}/." "${out_dir}/" ||
	die "cannot copy bin/targets/${target_path}"
