#!/usr/bin/env sh
# Responsibility: print the Markdown job summary of one QEMU test job
# (line, target, image, package, pytest exit, per-test times, junit
# properties) from the HARNESS_* variables and the junit file.
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

printf '\nTests:\n'
if grep -o '<testcase [^>]*>' "${results}" >"${work_dir}/cases"; then
	sed -E 's/.* name="([^"]+)" time="([^"]+)".*/- \1: \2 s/' "${work_dir}/cases"
else
	printf -- '- none recorded\n'
fi

printf '\nJunit properties:\n'
if grep -o '<property name="[^"]*" value="[^"]*"' "${results}" >"${work_dir}/props"; then
	sed -E 's/<property name="([^"]*)" value="([^"]*)"/- \1: \2/' "${work_dir}/props"
else
	printf -- '- none recorded\n'
fi
