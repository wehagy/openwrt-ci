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
# The world of the image lists the package by name, as the world of an
# official image does, so that `apk upgrade` on the device takes later
# versions from the feed. apk writes <name><><checksum> for a file, so the
# packages are installed once with `make manifest` to learn that world, and
# `make image` gets a FILES directory whose etc/apk/world is that world with
# the pin replaced by the name (the Image Builder copies FILES over the root
# after the packages are installed). The worlds of both steps are left as
# local-world-pinned and local-world for scripts/collect-images.sh.
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
package=${HARNESS_PACKAGE?HARNESS_PACKAGE is required}
apk_dir=${HARNESS_APK_DIR:-/harness/in}
out_dir=${HARNESS_OUT_DIR:-/harness/out}
apk_tool=${HARNESS_APK_TOOL:-staging_dir/host/bin/apk}
if [ -n "${package}" ]; then
	check_package_name "${package}"
fi

# ---------------------------------------------------------------------------
# ImageBuilder: it is in the image (the daily refresh runs setup.sh once, or
# copies the release container, which has it); nothing is downloaded here.
# ---------------------------------------------------------------------------
[ -f Makefile ] || die "no ImageBuilder in the image (no Makefile in ${PWD})"

# ---------------------------------------------------------------------------
# Build.
# ---------------------------------------------------------------------------
files_dir=
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
	# The world apk writes for the install by path (<name><><checksum>), taken
	# from the root of an install-only run of the Image Builder.
	make -s manifest PROFILE="${profile}" PACKAGES="${packages}" \
		>"${out_dir}/manifest-install.log" 2>&1 ||
		die "cannot install the packages to learn the world (see manifest-install.log)"
	target_dir=$(make -s val.TARGET_DIR) || die "cannot read TARGET_DIR of the Image Builder"
	cp "${target_dir}/etc/apk/world" "${out_dir}/local-world-pinned" ||
		die "cannot read the world of ${target_dir}"
	files_dir=$(mktemp -d) || die "cannot create the FILES directory"
	# The Image Builder copies FILES over the root with its modes: keep them
	# those of a normal root.
	mkdir -p "${files_dir}/etc/apk" || die "cannot create ${files_dir}/etc/apk"
	chmod 755 "${files_dir}" "${files_dir}/etc" "${files_dir}/etc/apk" ||
		die "cannot set the modes of ${files_dir}"
	plain_world=$(ib_plain_world "${out_dir}/local-world-pinned" "${package}")
	printf '%s\n' "${plain_world}" >"${files_dir}/etc/apk/world" ||
		die "cannot write the plain world"
	chmod 644 "${files_dir}/etc/apk/world" || die "cannot set the mode of the world"
fi

# Arguments of `make image`: FILES only with a package of our own (see above).
set -- PROFILE="${profile}" PACKAGES="${packages}"
if [ -n "${files_dir}" ]; then
	set -- "$@" FILES="${files_dir}"
fi

make_log=${out_dir}/make.log
make_rc=${out_dir}/make.rc
start=$(date +%s)
{
	rc=0
	make image "$@" 2>&1 || rc=$?
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

# The evidence that the image holds the built apk and lists it by name: the
# world of the image root, the record of the package in its apk database, and
# the record apk writes for the same .apk in a scratch root (same
# repositories, so its dependencies resolve).
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
	# The world of the image root (not of its pristine copy root.orig-*).
	cp "${target_dir}/etc/apk/world" "${out_dir}/local-world" ||
		die "cannot read the world of ${target_dir}"
	rm -rf "${files_dir}"
fi
