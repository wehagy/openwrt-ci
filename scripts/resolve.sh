#!/usr/bin/env sh
# Responsibility: resolve the data of one (line, target) pair from
# harness/lines.yml and harness/targets.yml, including the latest stable
# release of the line, and print it as KEY=value lines.
#
# Usage:
#   scripts/resolve.sh <line> <target> >> "$GITHUB_ENV"
#
# Environment variables:
#   HARNESS_DIR      directory with lines.yml and targets.yml
#                    (default: <repo>/harness)
#   HARNESS_RELEASE  pin the release instead of scanning the releases index

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
# Release: latest non-rc release of the line, unless pinned.
# ---------------------------------------------------------------------------
release=${HARNESS_RELEASE:-}
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

# ---------------------------------------------------------------------------
# Target data and URLs.
# ---------------------------------------------------------------------------
arch=$(yq_get "${targets_file}" "${target_key}.arch")
path=$(yq_get "${targets_file}" "${target_key}.path")
image_pattern=$(yq_get "${targets_file}" "${target_key}.images[strenv(LINE)]")

# Expand the {release}, {path} and {arch} placeholders of a pattern.
#
# Arguments:
#   $1  pattern
expand() {
	printf '%s\n' "$1" | sed -e "s|{release}|${release}|g" \
		-e "s|{path}|${path}|g" -e "s|{arch}|${arch}|g"
}

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
printf 'HARNESS_RELEASE=%s\n' "${release}"
printf 'HARNESS_IMAGE_URL=%s/%s\n' "${image_base}" "${image_file}"
printf 'HARNESS_SHA256SUMS_URL=%s/sha256sums\n' "${image_base}"
printf 'HARNESS_FEED_URL=%s\n' "${feed_url}"
printf 'HARNESS_LG_ENV=%s\n' "${lg_env}"
printf 'HARNESS_MEMORY=%s\n' "${memory}"
printf 'HARNESS_KVM=%s\n' "${kvm}"
printf 'HARNESS_QEMU_PKG=%s\n' "${qemu_pkg}"
