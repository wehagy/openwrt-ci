#!/usr/bin/env sh
# Responsibility: print the job matrix JSON (one entry per QEMU target that
# has an image for the line) from harness/targets.yml as a matrix=... line.
#
# The `targets` input of test.yml, when given, selects a subset: ids separated
# by spaces or newlines, each a key of targets.yml with an image for the line
# (an unknown id fails with the known ones). The matrix keeps the order of
# targets.yml and drops duplicates.
#
# Usage:
#   scripts/matrix.sh <line> >> "$GITHUB_OUTPUT"
#
# Environment variables:
#   HARNESS_DIR      directory with targets.yml (default: <repo>/harness)
#   HARNESS_TARGETS  optional; the targets to test (default: all of the line)

set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "${script_dir}/lib/common.sh"

[ "$#" -eq 1 ] || die "usage: matrix.sh <line>"
LINE=$1
export LINE
targets_file=${HARNESS_DIR:-${script_dir}/../harness}/targets.yml

check_line "${LINE}"

targets=$(yq -o=json -I=0 \
	'[.targets | to_entries | .[] | select(.value.images[strenv(LINE)] != null) | .key]' \
	"${targets_file}") || die "yq failed on ${targets_file}"
[ "${targets}" != '[]' ] || die "no target has an image for line ${LINE}"

requested=$(printf '%s' "${HARNESS_TARGETS:-}" | tr -d ' \n\t\r') || die "cannot read the targets"
if [ -n "${requested}" ]; then
	check_target_ids "${HARNESS_TARGETS}"
	# Every requested id must be a target of the line.
	known=$(printf '%s' "${targets}" | jq -r '.[]') || die "cannot read the targets"
	wanted=$(printf '%s' "${HARNESS_TARGETS}" | tr '\n\t\r' '   ')
	known_line=$(printf '%s' "${known}" | tr '\n' ' ' | sed 's/ $//') || die "cannot list the targets"
	for id in ${wanted}; do
		printf '%s\n' "${known}" | grep -qx -- "${id}" ||
			die "unknown test target '${id}' on line ${LINE} (known: ${known_line})"
	done
	targets=$(printf '%s' "${targets}" | jq -c --arg w "${wanted}" '($w | split(" ") | map(select(length > 0))) as $ids | map(select(. as $t | $ids | index($t)))') ||
		die "cannot select the targets"
fi

printf 'matrix={"target":%s}\n' "${targets}"
