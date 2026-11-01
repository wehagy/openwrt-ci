#!/usr/bin/env sh
# Responsibility: print the Markdown job summary of one QEMU test job
# (line, target, image, package, pytest exit, per-test status and time,
# junit properties) from the HARNESS_* variables and the junit file.
#
# Usage:
#   scripts/summary.sh <results.xml> <pytest-exit> <total-seconds> >> "$GITHUB_STEP_SUMMARY"
#
# Environment variables (all set by scripts/resolve.sh and the fetch scripts):
#   HARNESS_LINE, HARNESS_TARGET, HARNESS_RELEASE, HARNESS_KVM, HARNESS_MEMORY,
#   HARNESS_IMAGE_URL, HARNESS_IMAGE_SHA256, HARNESS_PACKAGE,
#   HARNESS_PACKAGE_VERSION

set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "${script_dir}/lib/common.sh"

line=${HARNESS_LINE:?HARNESS_LINE is required}
target=${HARNESS_TARGET:?HARNESS_TARGET is required}
release=${HARNESS_RELEASE:?HARNESS_RELEASE is required}
kvm=${HARNESS_KVM:?HARNESS_KVM is required}
memory=${HARNESS_MEMORY:?HARNESS_MEMORY is required}
image_url=${HARNESS_IMAGE_URL:?HARNESS_IMAGE_URL is required}
image_sha256=${HARNESS_IMAGE_SHA256:?HARNESS_IMAGE_SHA256 is required}
package=${HARNESS_PACKAGE:?HARNESS_PACKAGE is required}
package_version=${HARNESS_PACKAGE_VERSION:?HARNESS_PACKAGE_VERSION is required}

[ "$#" -eq 3 ] || die "usage: summary.sh <results.xml> <pytest-exit> <total-seconds>"
results=$1
pytest_rc=$2
total=$3

work_dir=$(mktemp -d)
trap 'rm -rf "${work_dir}"' EXIT

printf '### %s / %s\n' "${line}" "${target}"
printf -- '- line: %s (release %s)\n' "${line}" "${release}"
printf -- '- target: %s, kvm: %s, memory: %s\n' \
	"${target}" "${kvm}" "${memory}"
printf -- '- image: %s\n' "${image_url}"
printf -- '- image sha256: %s\n' "${image_sha256}"
printf -- '- package: %s %s\n' "${package}" "${package_version}"
printf -- '- pytest exit: %s, total: %s s\n' "${pytest_rc}" "${total}"

if [ ! -f "${results}" ]; then
	printf -- '- no junit file at %s\n' "${results}"
	exit 0
fi

# One line per testcase: status (passed/failed/skipped), name, time and, for a
# skip, its reason. pytest writes the whole junit file on one line, so the
# file is split at each "<testcase " first. A <failure> or <error> element
# counts as failed.
printf '\nTests:\n'
sed -e 's/<testcase /\n<testcase /g' "${results}" >"${work_dir}/split"
awk '
function attr(text, key,    pos, rest) {
	pos = match(text, " " key "=\"[^\"]*\"")
	if (pos == 0) {
		return ""
	}
	rest = substr(text, RSTART + length(key) + 3)
	return substr(rest, 1, index(rest, "\"") - 1)
}
/^<testcase / {
	chunk = $0
	sub(/<\/testcase>.*/, "", chunk)
	status = "passed"
	reason = ""
	if (chunk ~ /<(failure|error)[ >\/]/) {
		status = "failed"
	} else if (chunk ~ /<skipped[ >\/]/) {
		status = "skipped"
		reason = attr(substr(chunk, index(chunk, "<skipped")), "message")
	}
	count[status]++
	line = "- " status ": " attr(chunk, "name") " (" attr(chunk, "time") " s)"
	if (reason != "") {
		line = line " - " reason
	}
	print line
}
END {
	if (count["passed"] + count["failed"] + count["skipped"] == 0) {
		print "- none recorded"
	} else {
		printf "\ntotals: %d passed, %d failed, %d skipped\n", count["passed"], count["failed"], count["skipped"]
	}
}
' "${work_dir}/split"

printf '\nJunit properties:\n'
if grep -o '<property name="[^"]*" value="[^"]*"' "${results}" >"${work_dir}/props"; then
	sed -E 's/<property name="([^"]*)" value="([^"]*)"/- \1: \2/' "${work_dir}/props"
else
	printf -- '- none recorded\n'
fi
