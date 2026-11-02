#!/usr/bin/env sh
# Responsibility: pull an ImageBuilder container image, timing the download,
# and print its digest, size and pull duration as KEY=value lines.
#
# Usage:
#   scripts/pull-imagebuilder.sh <image> >> "$GITHUB_ENV"
#
# Environment variables: none.

set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "${script_dir}/lib/common.sh"

[ "$#" -eq 1 ] || die "usage: pull-imagebuilder.sh <image>"
image=$1

start=$(date +%s)
docker pull --quiet "${image}" >&2 || die "cannot pull ${image}"
end=$(date +%s)
digest=$(docker image inspect --format '{{index .RepoDigests 0}}' "${image}") ||
	die "cannot inspect ${image}"
size=$(docker image inspect --format '{{.Size}}' "${image}") ||
	die "cannot inspect ${image}"

printf 'HARNESS_IB_DIGEST=%s\n' "${digest}"
printf 'HARNESS_IB_SIZE_BYTES=%s\n' "${size}"
printf 'HARNESS_IB_PULL_SECONDS=%s\n' "$((end - start))"
