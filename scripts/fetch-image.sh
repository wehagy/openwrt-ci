#!/usr/bin/env sh
# Responsibility: download an OpenWrt image, verify it against the release
# sha256sums, unpack it to firmware.img and print its checksum.
#
# Usage:
#   scripts/fetch-image.sh >> "$GITHUB_ENV"
#
# Environment variables:
#   HARNESS_IMAGE_URL        image URL (required)
#   HARNESS_SHA256SUMS_URL   sha256sums URL of the same directory (required)
#   HARNESS_WORK_DIR         where files are written (default: .)

set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "${script_dir}/lib/common.sh"

image_url=${HARNESS_IMAGE_URL:?HARNESS_IMAGE_URL is required}
sums_url=${HARNESS_SHA256SUMS_URL:?HARNESS_SHA256SUMS_URL is required}
work_dir=${HARNESS_WORK_DIR:-.}
image_file=${image_url##*/}

curl -fsSL --retry 3 -o "${work_dir}/${image_file}" "${image_url}" ||
	die "cannot fetch ${image_url}"
curl -fsSL --retry 3 -o "${work_dir}/sha256sums" "${sums_url}" ||
	die "cannot fetch ${sums_url}"

# sha256sums lines are "<hash> *<file>"; compare the file name literally.
expected=$(awk -v f="${image_file}" '$2 == "*" f { print $1 }' "${work_dir}/sha256sums")
[ -n "${expected}" ] || die "${image_file} not listed in ${sums_url}"
sha256sum "${work_dir}/${image_file}" >"${work_dir}/actual.sha256"
read -r actual _ <"${work_dir}/actual.sha256"
[ "${actual}" = "${expected}" ] ||
	die "sha256 mismatch for ${image_file}: ${actual} != ${expected}"

case "${image_file}" in
*.gz)
	# gzip exits 2 on trailing garbage after the stream; that is a warning
	# for OpenWrt combined images, any other status is a failure.
	gunzip_rc=0
	gzip -dc "${work_dir}/${image_file}" >"${work_dir}/firmware.img" ||
		gunzip_rc=$?
	[ "${gunzip_rc}" -eq 0 ] || [ "${gunzip_rc}" -eq 2 ] ||
		die "gzip failed with status ${gunzip_rc}"
	;;
*)
	cp "${work_dir}/${image_file}" "${work_dir}/firmware.img"
	;;
esac

printf 'HARNESS_IMAGE_SHA256=%s\n' "${actual}"
work_abs=$(cd "${work_dir}" && pwd)
printf 'HARNESS_FIRMWARE=%s/firmware.img\n' "${work_abs}"
