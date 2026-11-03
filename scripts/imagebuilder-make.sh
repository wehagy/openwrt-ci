#!/usr/bin/env sh
# Responsibility: run inside an official OpenWrt ImageBuilder container: put
# the built .apk (when there is a package of our own) into the ImageBuilder
# package directory, build one profile
# and copy the build output to the mounted output directory.
#
# The built package is requested by the path of its .apk (lib/ib-pins.sh), not
# by name: apk installs that file whatever version the official feeds hold,
# equal or higher included, and the apk of the feeds never wins. The mechanism
# is native to apk, it needs no change to the ImageBuilder and no change to the
# package version. Three files are left in the output directory for
# scripts/collect-images.sh, which proves that the image holds that very apk:
# local-apk.dump (metadata of the .apk), local-installed.db (the record of the
# package in the apk database of the image root) and local-expected.db (the
# record apk writes when it installs the same .apk in a scratch root).
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
#                         is requested by the path of its .apk either way
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
	local_apk=${PWD}/packages/$(basename "${apk_file}")
	cp "${apk_file}" "${local_apk}" || die "cannot copy ${apk_file} to packages/"
	# A .apk installed by path must carry a signature the keys of the
	# ImageBuilder trust (the index of packages/ is signed by the Makefile, a
	# file given by path is not covered by it): sign the copy with the local
	# key of the ImageBuilder, which the Makefile creates on first use.
	make -s _check_keys || die "cannot create the local signing key"
	"${apk_tool}" --allow-untrusted --keys-dir "${PWD}/keys" adbsign \
		--sign-key "${PWD}/keys/local-private-key.pem" "${local_apk}" ||
		die "cannot sign ${local_apk} with the local key"
	packages=$(ib_local_packages "${packages}" "${package}" "${local_apk}")
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

# The evidence that the image holds the built apk: the record of the package
# in the apk database of the image root, and the record apk writes for the same
# .apk in a scratch root (same repositories, so its dependencies resolve).
if [ -n "${package}" ]; then
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
	arch=$(sed -n 's/^CONFIG_TARGET_ARCH_PACKAGES="\(.*\)"$/\1/p' .config) ||
		die "cannot read .config"
	[ -n "${arch}" ] || die "no CONFIG_TARGET_ARCH_PACKAGES in .config"
	scratch=$(mktemp -d) || die "cannot create a scratch root"
	"${apk_tool}" --root "${scratch}" --keys-dir "${PWD}/keys" --no-logfile \
		--arch "${arch}" --repositories-file repositories \
		--repository packages/packages.adb \
		add --usermode --initdb --no-scripts "${local_apk}" ||
		die "cannot install ${apk_file} in a scratch root"
	installed_record "${scratch}/lib/apk/db/installed" "${package}" \
		>"${out_dir}/local-expected.db"
	[ -s "${out_dir}/local-expected.db" ] || die "${package} is not in the scratch root"
	rm -rf "${scratch}"
fi
