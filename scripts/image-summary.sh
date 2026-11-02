#!/usr/bin/env sh
# Responsibility: print the Markdown job summary of one image job: profile,
# ImageBuilder image and digest, timings, the manifest check, the image files
# with size and sha256 and, when the build did not succeed, the
# ImageBuilder's own messages.
#
# Usage:
#   scripts/image-summary.sh <ib-out-dir> <image-dir> | tee -a "$GITHUB_STEP_SUMMARY"
#
# Environment variables (set by scripts/resolve-image.sh,
# scripts/pull-imagebuilder.sh, scripts/collect-images.sh and the workflow):
#   HARNESS_LINE, HARNESS_PROFILE_ID, HARNESS_PROFILE, HARNESS_PACKAGE,
#   HARNESS_IB_IMAGE, HARNESS_IB_DIGEST, HARNESS_IB_SIZE_BYTES,
#   HARNESS_IB_PULL_SECONDS, HARNESS_JOB_STATUS (required);
#   HARNESS_PACKAGE_VERSION, HARNESS_MANIFEST_LINE, HARNESS_MANIFEST_FILE
#   (set once known), HARNESS_EXPECT (fits or too-big). The outcome and the
#   sizes are read from the files scripts/check-image-outcome.sh writes to
#   <ib-out-dir>.

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

expect=${HARNESS_EXPECT:-fits}
# Written by check-image-outcome.sh, also when the check failed.
outcome=unknown
if [ -f "${ib_dir}/outcome" ]; then
	read -r outcome <"${ib_dir}/outcome"
fi
heading=${status}
if [ "${expect}" = too-big ] && [ "${outcome}" = too-big ] && [ "${status}" = success ]; then
	heading="success (expected failure: the image does not fit the flash)"
fi
printf '### image %s / %s: %s\n' "${line}" "${profile_id}" "${heading}"
printf -- '- profile: %s\n' "${profile}"
printf -- '- ImageBuilder image: %s (%s)\n' "${ib_image}" "${HARNESS_IB_DIGEST:-not pulled}"
printf -- '- ImageBuilder image size: %s bytes, pulled in %s s\n' \
	"${HARNESS_IB_SIZE_BYTES:-unknown}" "${HARNESS_IB_PULL_SECONDS:-unknown}"
file_item "ImageBuilder download in the container (setup.sh)" "${ib_dir}/setup-seconds" s
file_item "make image duration" "${ib_dir}/make-seconds" s
printf -- '- package: %s %s\n' "${package}" "${HARNESS_PACKAGE_VERSION:-unknown}"
if [ "${expect}" = too-big ]; then
	printf -- '- expectation: too-big (harness/images.yml): the job passes only if the image does not fit\n'
else
	printf -- '- expectation: fits\n'
fi
printf -- '- outcome: %s\n' "${outcome}"
if [ "${outcome}" = too-big ]; then
	file_item "too big, compared" "${ib_dir}/size-what" ""
	file_item "actual size" "${ib_dir}/size-actual" bytes
	file_item "limit" "${ib_dir}/size-limit" bytes
fi
if [ -n "${HARNESS_MANIFEST_LINE:-}" ]; then
	printf -- "- manifest check: \`%s\` is a line of \`%s\`\n" \
		"${HARNESS_MANIFEST_LINE}" "${HARNESS_MANIFEST_FILE:-the manifest}"
elif [ "${outcome}" = too-big ]; then
	printf -- '- manifest check: skipped, no image was built\n'
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

# The ImageBuilder's own messages, quoted verbatim: on failure, and for an
# expected failure the "too big" lines that explain it.
if [ "${outcome}" = too-big ] && [ -f "${ib_dir}/too-big-messages" ]; then
	printf '\nImageBuilder "too big" messages:\n\n%s\n' "${fence}"
	cat "${ib_dir}/too-big-messages"
	printf '%s\n' "${fence}"
fi
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
