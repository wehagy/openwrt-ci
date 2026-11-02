#!/usr/bin/env sh
# Responsibility: print the Markdown job summary of one image job: profile,
# ImageBuilder image and digest, timings, the manifest check, the image files
# with size and sha256 and, when the build did not succeed, the
# ImageBuilder's own messages.
#
# Usage:
#   scripts/image-summary.sh <ib-out-dir> <image-dir> >> "$GITHUB_STEP_SUMMARY"
#
# Environment variables (set by scripts/resolve-image.sh,
# scripts/pull-imagebuilder.sh, scripts/collect-images.sh and the workflow):
#   HARNESS_LINE, HARNESS_PROFILE_ID, HARNESS_PROFILE, HARNESS_PACKAGE,
#   HARNESS_IB_IMAGE, HARNESS_IB_DIGEST, HARNESS_IB_SIZE_BYTES,
#   HARNESS_IB_PULL_SECONDS, HARNESS_JOB_STATUS (required);
#   HARNESS_PACKAGE_VERSION, HARNESS_MANIFEST_LINE, HARNESS_MANIFEST_FILE
#   (set once known).

set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "${script_dir}/lib/common.sh"

[ "$#" -eq 2 ] || die "usage: image-summary.sh <ib-out-dir> <image-dir>"
ib_dir=$1
image_dir=$2
line=${HARNESS_LINE:?HARNESS_LINE is required}
profile_id=${HARNESS_PROFILE_ID:?HARNESS_PROFILE_ID is required}
profile=${HARNESS_PROFILE:?HARNESS_PROFILE is required}
package=${HARNESS_PACKAGE:?HARNESS_PACKAGE is required}
ib_image=${HARNESS_IB_IMAGE:?HARNESS_IB_IMAGE is required}
status=${HARNESS_JOB_STATUS:?HARNESS_JOB_STATUS is required}

# Markdown code fence.
fence="\`\`\`"

# Print "- label: <content of a one-line file>" if the file exists.
#
# Arguments:
#   $1  label
#   $2  file
#   $3  unit
file_item() {
	if [ -f "$2" ]; then
		read -r fi_value <"$2"
		printf -- '- %s: %s %s\n' "$1" "${fi_value}" "$3"
	fi
}

printf '### image %s / %s: %s\n' "${line}" "${profile_id}" "${status}"
printf -- '- profile: %s\n' "${profile}"
printf -- '- ImageBuilder image: %s (%s)\n' "${ib_image}" "${HARNESS_IB_DIGEST:-not pulled}"
printf -- '- ImageBuilder image size: %s bytes, pulled in %s s\n' \
	"${HARNESS_IB_SIZE_BYTES:-unknown}" "${HARNESS_IB_PULL_SECONDS:-unknown}"
file_item "ImageBuilder download in the container (setup.sh)" "${ib_dir}/setup-seconds" s
file_item "make image duration" "${ib_dir}/make-seconds" s
printf -- '- package: %s %s\n' "${package}" "${HARNESS_PACKAGE_VERSION:-unknown}"
if [ -n "${HARNESS_MANIFEST_LINE:-}" ]; then
	printf -- "- manifest check: \`%s\` is a line of \`%s\`\n" \
		"${HARNESS_MANIFEST_LINE}" "${HARNESS_MANIFEST_FILE:-the manifest}"
else
	printf -- '- manifest check: not passed\n'
fi

if [ -d "${image_dir}" ]; then
	printf '\n| image file | bytes | sha256 |\n|---|---|---|\n'
	for file in "${image_dir}"/*; do
		[ -f "${file}" ] || continue
		sha256sum "${file}" >"${ib_dir}/sum.tmp" || die "cannot checksum ${file}"
		read -r sum _ <"${ib_dir}/sum.tmp"
		bytes=$(wc -c <"${file}") || die "cannot size ${file}"
		printf '| %s | %s | %s |\n' "$(basename "${file}")" "${bytes}" "${sum}"
	done
fi

# The ImageBuilder's own messages, quoted verbatim.
if [ "${status}" != success ] && [ -f "${ib_dir}/make.log" ]; then
	printf '\nImageBuilder messages (WARNING, ERROR, space and size lines of make.log):\n\n%s\n' "${fence}"
	if messages=$(grep -E 'WARNING|ERROR|[Ee]rror|too big|[Nn]o space|exceed' "${ib_dir}/make.log"); then
		printf '%s\n' "${messages}" | tail -n 30
	else
		printf '(no matching line)\n'
	fi
	printf '%s\n\nLast 15 lines of make.log:\n\n%s\n' "${fence}" "${fence}"
	tail -n 15 "${ib_dir}/make.log"
	printf '%s\n' "${fence}"
fi
