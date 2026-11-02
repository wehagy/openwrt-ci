#!/usr/bin/env sh
# Responsibility: resolve the data of one (line, target) pair from
# harness/lines.yml and harness/targets.yml and print it as KEY=value lines.
# The image version depends on the release_source of the line:
#   releases  the latest release of the line (scanned in the releases index,
#             or HARNESS_RELEASE) is printed as HARNESS_RELEASE and expanded
#             in the image and feed URLs.
#   snapshot  the version is not read here (a snapshot can be republished
#             before the image download): HARNESS_VERSION_URL is printed and
#             scripts/fetch-image.sh reads the version next to the download
#             and prints HARNESS_RELEASE. No URL contains the version.
#
# Usage:
#   scripts/resolve.sh <line> <target> >> "$GITHUB_ENV"
#
# Environment variables:
#   HARNESS_DIR      directory with lines.yml and targets.yml
#                    (default: <repo>/harness)
#   HARNESS_RELEASE  releases lines only: pin the release instead of scanning
#                    the releases index (ignored on snapshot lines)

set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "${script_dir}/lib/common.sh"

[ "$#" -eq 2 ] || die "usage: resolve.sh <line> <target>"
LINE=$1
TARGET=$2
export LINE TARGET
harness_dir=${HARNESS_DIR:-${script_dir}/../harness}
lines_file=${harness_dir}/lines.yml
targets_file=${harness_dir}/targets.yml

line_key='.lines[strenv(LINE)]'
target_key='.targets[strenv(TARGET)]'

work_dir=$(mktemp -d)
trap 'rm -rf "${work_dir}"' EXIT

# ---------------------------------------------------------------------------
# Target data and placeholder expansion.
# ---------------------------------------------------------------------------
arch=$(yq_get "${targets_file}" "${target_key}.arch")
path=$(yq_get "${targets_file}" "${target_key}.path")
image_pattern=$(yq_get "${targets_file}" "${target_key}.images[strenv(LINE)]")
release=${HARNESS_RELEASE:-}

# Expand the {release}, {path} and {arch} placeholders of a pattern.
#
# Arguments:
#   $1  pattern
expand() {
	printf '%s\n' "$1" | sed -e "s|{release}|${release}|g" \
		-e "s|{path}|${path}|g" -e "s|{arch}|${arch}|g"
}

# ---------------------------------------------------------------------------
# Release: for "releases", the pinned or the latest non-rc release of the
# line; for "snapshot", only the URL of its version file (see the header).
# ---------------------------------------------------------------------------
version_url=
release_source=$(yq_get "${lines_file}" "${line_key}.release_source")
case "${release_source}" in
releases)
	if [ -z "${release}" ]; then
		index_url=$(yq_get "${lines_file}" "${line_key}.releases_index_url")
		release_regex=$(yq_get "${lines_file}" "${line_key}.release_regex")
		curl -fsSL --retry 3 --connect-timeout 20 --max-time 60 -o "${work_dir}/index.html" "${index_url}" ||
			die "cannot fetch ${index_url}"
		grep -oE "href=\"${release_regex}/\"" "${work_dir}/index.html" \
			>"${work_dir}/hrefs" || die "no release ${release_regex} at ${index_url}"
		sed -e 's/^href="//' -e 's|/"$||' "${work_dir}/hrefs" >"${work_dir}/versions"
		sort -V -o "${work_dir}/sorted" "${work_dir}/versions"
		release=$(tail -n 1 "${work_dir}/sorted")
	fi
	# The release goes to GITHUB_ENV and into URLs: keep it to a safe
	# charset whatever its origin (pin or index page).
	check_release "${release}"
	;;
snapshot)
	release=
	version_pattern=$(yq_get "${lines_file}" "${line_key}.snapshot_version_url")
	version_url=$(expand "${version_pattern}")
	;;
*)
	die "unsupported release_source in ${lines_file}: ${release_source}"
	;;
esac

# ---------------------------------------------------------------------------
# URLs.
# ---------------------------------------------------------------------------
image_file=$(expand "${image_pattern}")
image_base_pattern=$(yq_get "${lines_file}" "${line_key}.image_base_url")
image_base=$(expand "${image_base_pattern}")
feed_pattern=$(yq_get "${lines_file}" "${line_key}.feed_base_url")
feed_url=$(expand "${feed_pattern}")
lg_env=$(yq_get "${targets_file}" "${target_key}.lg_env")
memory=$(yq_get "${targets_file}" "${target_key}.memory")
kvm=$(yq_get "${targets_file}" "${target_key}.kvm")
qemu_pkg=$(yq_get "${targets_file}" "${target_key}.qemu_pkg")

printf 'HARNESS_LINE=%s\n' "${LINE}"
printf 'HARNESS_TARGET=%s\n' "${TARGET}"
[ -z "${release}" ] || printf 'HARNESS_RELEASE=%s\n' "${release}"
printf 'HARNESS_VERSION_URL=%s\n' "${version_url}"
printf 'HARNESS_ARCH=%s\n' "${arch}"
printf 'HARNESS_IMAGE_URL=%s/%s\n' "${image_base}" "${image_file}"
printf 'HARNESS_SHA256SUMS_URL=%s/sha256sums\n' "${image_base}"
printf 'HARNESS_FEED_URL=%s\n' "${feed_url}"
printf 'HARNESS_LG_ENV=%s\n' "${lg_env}"
printf 'HARNESS_MEMORY=%s\n' "${memory}"
printf 'HARNESS_KVM=%s\n' "${kvm}"
printf 'HARNESS_QEMU_PKG=%s\n' "${qemu_pkg}"
