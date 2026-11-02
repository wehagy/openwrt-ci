#!/usr/bin/env sh
# Responsibility: download an OpenWrt image, verify it against the sha256sums
# of its directory, unpack it to firmware.img and print its checksum and the
# date the server reports for it (Last-Modified; snapshot images are rebuilt
# daily).
#
# Snapshot lines (HARNESS_VERSION_URL set): the directory can be republished
# at any time, so the version.buildinfo is read before the sha256sums and the
# image and again after them. If it changed, the pair may be inconsistent and
# the download is repeated (up to 3 attempts); otherwise the version is the
# one of the image and is printed as HARNESS_RELEASE. A sha256 mismatch with
# an unchanged version still fails.
#
# Usage:
#   scripts/fetch-image.sh >> "$GITHUB_ENV"
#
# Environment variables:
#   HARNESS_IMAGE_URL        image URL (required)
#   HARNESS_SHA256SUMS_URL   sha256sums URL of the same directory (required)
#   HARNESS_VERSION_URL      snapshot only: version.buildinfo URL of the same
#                            directory (default: empty, no version check)
#   HARNESS_WORK_DIR         where files are written (default: .)

set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "${script_dir}/lib/common.sh"

image_url=${HARNESS_IMAGE_URL:?HARNESS_IMAGE_URL is required}
sums_url=${HARNESS_SHA256SUMS_URL:?HARNESS_SHA256SUMS_URL is required}
version_url=${HARNESS_VERSION_URL:-}
work_dir=${HARNESS_WORK_DIR:-.}
image_file=${image_url##*/}

# Print the version in version.buildinfo; the first line, with or without a
# trailing newline.
fetch_version() {
	curl -fsSL --retry 3 --connect-timeout 20 --max-time 60 \
		-o "${work_dir}/version.buildinfo" "${version_url}" ||
		die "cannot fetch ${version_url}"
	fetch_version_value=$(head -n 1 "${work_dir}/version.buildinfo")
	check_release "${fetch_version_value}"
	printf '%s\n' "${fetch_version_value}"
}

# ---------------------------------------------------------------------------
# Download: sha256sums first, then the image; a snapshot republished in
# between is detected by the version check (see the header).
# ---------------------------------------------------------------------------
attempt=1
while :; do
	release=
	if [ -n "${version_url}" ]; then
		release=$(fetch_version)
	fi
	curl -fsSL --retry 3 --connect-timeout 20 --max-time 60 -o "${work_dir}/sha256sums" "${sums_url}" ||
		die "cannot fetch ${sums_url}"
	curl -fsSL --retry 3 --connect-timeout 20 --max-time 600 -D "${work_dir}/headers" \
		-o "${work_dir}/${image_file}" "${image_url}" ||
		die "cannot fetch ${image_url}"
	[ -n "${version_url}" ] || break
	release_after=$(fetch_version)
	[ "${release}" != "${release_after}" ] || break
	[ "${attempt}" -lt 3 ] ||
		die "snapshot republished during each of ${attempt} downloads"
	printf 'warn: snapshot republished during the download (%s -> %s), retrying\n' \
		"${release}" "${release_after}" >&2
	attempt=$((attempt + 1))
	sleep 30
done

# -D records every response of a redirect chain; the last Last-Modified is the
# one of the file. Header names are case-insensitive. A missing header gives
# an empty date, which check_http_date rejects.
last_modified=$(awk -F': ' 'tolower($1) == "last-modified" { sub(/\r$/, "", $2); date = $2 } END { print date }' \
	"${work_dir}/headers")
check_http_date "${last_modified}"

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

[ -z "${version_url}" ] || printf 'HARNESS_RELEASE=%s\n' "${release}"
printf 'HARNESS_IMAGE_SHA256=%s\n' "${actual}"
printf 'HARNESS_IMAGE_DATE=%s\n' "${last_modified}"
work_abs=$(cd "${work_dir}" && pwd)
printf 'HARNESS_FIRMWARE=%s/firmware.img\n' "${work_abs}"
