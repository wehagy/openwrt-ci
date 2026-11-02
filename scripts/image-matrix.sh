#!/usr/bin/env sh
# Responsibility: print the job matrix JSON (one entry per profile) from
# harness/images.yml as a matrix=... line.
#
# Usage:
#   scripts/image-matrix.sh >> "$GITHUB_OUTPUT"
#
# Environment variables:
#   HARNESS_DIR  directory with images.yml (default: <repo>/harness)

set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "${script_dir}/lib/common.sh"

[ "$#" -eq 0 ] || die "usage: image-matrix.sh"
images_file=${HARNESS_DIR:-${script_dir}/../harness}/images.yml

profiles=$(yq -o=json -I=0 '[.profiles | keys | .[]]' "${images_file}") ||
	die "yq failed on ${images_file}"
[ "${profiles}" != '[]' ] || die "no profile in ${images_file}"

printf 'matrix={"profile":%s}\n' "${profiles}"
