#!/usr/bin/env sh
# Responsibility: pull the harness Image Builder image of an image job from
# GHCR, timing the download, and print its digest, size and pull duration as
# KEY=value lines. The job only reads the image: the daily refresh
# (refresh-images.yml) writes it. A missing or private image fails the job
# with the command that refreshes it by hand; a stale one
# (scripts/image-stale-check.sh) only raises a warning annotation.
#
# Usage:
#   scripts/pull-imagebuilder.sh <image> >> "$GITHUB_ENV"
#
# Environment variables:
#   HARNESS_IB_GRACE_DAYS  grace period of the stale warning, whole days
#   HARNESS_IB_RELEASE     latest release of a release line (see
#                          scripts/image-stale-check.sh); empty for a snapshot
#   GITHUB_REPOSITORY      repository of the caller, in the refresh command

set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "${script_dir}/lib/common.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/image-decide.sh
. "${script_dir}/lib/image-decide.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/ghcr.sh
. "${script_dir}/lib/ghcr.sh"

[ "$#" -eq 1 ] || die "usage: pull-imagebuilder.sh <image>"
image=$1
grace=${HARNESS_IB_GRACE_DAYS:?HARNESS_IB_GRACE_DAYS is required}
repository=${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}
check_grace_days "${grace}"
case "${image}" in
ghcr.io/*/*:*) ;;
*) die "the Image Builder image must be ghcr.io/<owner>/<name>:<tag>" ;;
esac
tag=${image##*:}
check_sdk_tag "${tag}"
repo_path=${image#ghcr.io/}
repo_path=${repo_path%:*}
check_sdk_container "ghcr.io/${repo_path}"

work_dir=$(mktemp -d)
trap 'rm -rf "${work_dir}"' EXIT

# Anonymous, like the pull below: a private image is as good as a missing one.
ghcr_inspect "${repo_path}" "${tag}" "${work_dir}"
if [ ! -f "${work_dir}/config.json" ]; then
	image_missing_error "${image}" "${repository}"
	die "the Image Builder image ${image} is not readable anonymously (missing or private)"
fi
jq -c '.config.Labels // {}' "${work_dir}/config.json" >"${work_dir}/labels.json" ||
	die "cannot read the labels"
HARNESS_STALE_DAYS=${grace} GITHUB_REPOSITORY=${repository} \
	"${script_dir}/image-stale-check.sh" "${work_dir}/labels.json" "${image}" >&2

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
