#!/usr/bin/env sh
# Responsibility: print the job matrix JSON (one entry per QEMU target that
# has an image for the line) from harness/targets.yml as a matrix=... line.
#
# Usage:
#   scripts/matrix.sh <line> >> "$GITHUB_OUTPUT"
#
# Environment variables:
#   HARNESS_DIR  directory with targets.yml (default: <repo>/harness)

set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "${script_dir}/lib/common.sh"

[ "$#" -eq 1 ] || die "usage: matrix.sh <line>"
LINE=$1
export LINE
targets_file=${HARNESS_DIR:-${script_dir}/../harness}/targets.yml

targets=$(yq -o=json -I=0 \
	'[.targets | to_entries | .[] | select(.value.images[strenv(LINE)] != null) | .key]' \
	"${targets_file}") || die "yq failed on ${targets_file}"
[ "${targets}" != '[]' ] || die "no target has an image for line ${LINE}"

printf 'matrix={"target":%s}\n' "${targets}"
