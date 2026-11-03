#!/usr/bin/env sh
# Responsibility: run inside an official OpenWrt ImageBuilder container: put
# the built .apk (when there is a package of our own) into the ImageBuilder
# package directory, build one profile
# and copy the build output to the mounted output directory. The unsigned
# .apk needs no signature override: the ImageBuilder indexes its packages/
# directory itself and signs that index with its local key.
#
# The built package is requested as <name>=<version>, the version read from
# the metadata of the .apk (apk adbdump), so that the ImageBuilder cannot take
# a higher or equal version from the official feeds (lib/ib-pins.sh). Three
# files are left in the output directory for scripts/collect-images.sh, which
# proves that the image holds that very apk: local-apk.dump (metadata of the
# .apk), local-index.dump (the local packages.adb) and local-installed.db (the
# record of the package in the apk database of the image root).
#
# An image that does not fit the flash is not a make failure: check-size only
# prints "WARNING: Image file ... is too big: <size> > <limit>" and deletes
# the image (some images are refused earlier by the tool that packs them, e.g.
# "file-system partition too big"). Whether that is expected is decided by
# scripts/check-image-outcome.sh on the host from make.log; here only the size
# of the root filesystem is recorded, because the messages do not always state
# the size of the image (rootfs-bytes).
#
# Usage:
#   sh /harness/scripts/imagebuilder-make.sh
#
# Environment variables:
#   HARNESS_PROFILE       ImageBuilder PROFILE (required)
#   HARNESS_PACKAGES      packages to install, space separated, `-name` removes
#                         one (Image Builder syntax); may be empty (required to
#                         be set). The built package may be listed by name; it
#                         is requested as name=<version> either way
#   HARNESS_TARGET_PATH   <target>/<subtarget> (required)
#   HARNESS_IB_SETUP      true: download the ImageBuilder with ./setup.sh
#                         first (snapshot tags; scripts/ib-setup.sh retries a
#                         sha256 mismatch within HARNESS_IB_SETUP_BUDGET);
#                         false: it is in the image
#   HARNESS_APK_DIR       directory with the built .apk (default: /harness/in)
#   HARNESS_PACKAGE       package name, to find its .apk; empty: no package of
#                         our own, nothing to copy (required to be set)
#   HARNESS_OUT_DIR       writable output directory (default: /harness/out)
#   HARNESS_APK_TOOL      apk of the ImageBuilder (default:
#                         staging_dir/host/bin/apk, relative to the
#                         ImageBuilder directory)

set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "${script_dir}/lib/common.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/ib-pins.sh
. "${script_dir}/lib/ib-pins.sh"

profile=${HARNESS_PROFILE:?HARNESS_PROFILE is required}
packages=${HARNESS_PACKAGES?HARNESS_PACKAGES is required}
target_path=${HARNESS_TARGET_PATH:?HARNESS_TARGET_PATH is required}
setup=${HARNESS_IB_SETUP:?HARNESS_IB_SETUP is required}
package=${HARNESS_PACKAGE?HARNESS_PACKAGE is required}
apk_dir=${HARNESS_APK_DIR:-/harness/in}
out_dir=${HARNESS_OUT_DIR:-/harness/out}
apk_tool=${HARNESS_APK_TOOL:-staging_dir/host/bin/apk}
if [ -n "${package}" ]; then
	check_package_name "${package}"
fi

# ---------------------------------------------------------------------------
# ImageBuilder download (snapshot tags only).
# ---------------------------------------------------------------------------
setup_seconds=0
case "${setup}" in
true)
	start=$(date +%s)
	# Repeats setup.sh when the mirror serves an archive that does not match
	# the sha256sums (see scripts/ib-setup.sh); any other failure is final.
	TARGET=${target_path} "${script_dir}/ib-setup.sh"
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
if [ -n "${package}" ]; then
	apk_file=$(find_apk "${apk_dir}" "${package}")
	# The version comes from the metadata of the .apk, not from its file name;
	# the two must agree.
	"${apk_tool}" adbdump "${apk_file}" >"${out_dir}/local-apk.dump" ||
		die "cannot read the metadata of ${apk_file}"
	meta_name=$(adb_info_field "${out_dir}/local-apk.dump" name)
	meta_version=$(adb_info_field "${out_dir}/local-apk.dump" version)
	[ "${meta_name}" = "${package}" ] || die "${apk_file} is the package '${meta_name}', not ${package}"
	check_apk_version "${meta_version}"
	file_version=$(apk_version "${apk_file}" "${package}")
	[ "${file_version}" = "${meta_version}" ] ||
		die "the file name of ${apk_file} does not match its version ${meta_version}"
	cp "${apk_file}" packages/ || die "cannot copy ${apk_file} to packages/"
	ib_fix_format_packages Makefile
	packages=$(ib_pin_packages "${packages}" "${package}" "${meta_version}")
	printf 'imagebuilder-make: PACKAGES=%s\n' "${packages}"
fi

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

# Size of the root filesystem the ImageBuilder packed, for the cases where the
# "too big" message has no image size. Not an error when none is found.
find build_dir -type f -name root.squashfs -exec stat -c %s {} + \
	>"${out_dir}/rootfs-bytes" || die "cannot size the root filesystem"

cp -R "bin/targets/${target_path}/." "${out_dir}/" ||
	die "cannot copy bin/targets/${target_path}"

# The evidence that the image holds the built apk: the local index and the
# record of the package in the apk database of the image root.
if [ -n "${package}" ]; then
	"${apk_tool}" adbdump packages/packages.adb >"${out_dir}/local-index.dump" ||
		die "cannot read the local index packages/packages.adb"
	installed_dbs=$(find build_dir -path '*/lib/apk/db/installed' -type f) ||
		die "cannot search build_dir"
	[ -n "${installed_dbs}" ] || die "no apk database of the image root in build_dir"
	# The root of the image and its pristine copy (root.orig-*) both hold the
	# database; the package must have the same record in each.
	: >"${out_dir}/local-installed.db"
	for installed_db in ${installed_dbs}; do
		installed_record "${installed_db}" "${package}" >"${out_dir}/installed.record"
		[ -s "${out_dir}/installed.record" ] || die "${package} is not in ${installed_db}"
		if [ -s "${out_dir}/local-installed.db" ]; then
			cmp -s "${out_dir}/installed.record" "${out_dir}/local-installed.db" ||
				die "${package} has another record in ${installed_db}"
		else
			cp "${out_dir}/installed.record" "${out_dir}/local-installed.db" ||
				die "cannot write local-installed.db"
		fi
	done
	rm -f "${out_dir}/installed.record"
fi
