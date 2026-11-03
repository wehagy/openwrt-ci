#!/usr/bin/env sh
# Responsibility: pull the Image Builder image of an image job, timing the
# download, and print the image it pulled, whether it needs setup.sh, its
# digest, size and pull duration as KEY=value lines. The image is the harness
# image on GHCR, which only the daily refresh (refresh-images.yml) writes: a
# missing or private image fails the job with the command that refreshes it by
# hand (naming the repository that owns the refresh), a stale one
# (scripts/image-stale-check.sh) only raises a warning annotation.
#
# One exception, for a custom image whose profile is not in the refresh
# (HARNESS_IB_FALLBACK=true, set by custom-image.yml of the caller): when the
# harness image is missing, the job takes the official container instead,
# downloaded at run time (a snapshot container needs setup.sh, about 10
# minutes, run by imagebuilder-make.sh), and says so in a notice. Nothing is
# ever written to GHCR here. A private image or any other registry answer
# still fails.
#
# Usage:
#   scripts/pull-imagebuilder.sh <image> >> "$GITHUB_ENV"
#
# Environment variables:
#   HARNESS_IB_GRACE_DAYS  grace period of the stale warning, whole days
#   HARNESS_IB_RELEASE     latest release of a release line (see
#                          scripts/image-stale-check.sh); empty for a snapshot
#   HARNESS_REFRESH_REPOSITORY  repository that owns the refresh workflow
#                          (<owner>/<name>), in the refresh command
#   HARNESS_IB_FALLBACK    true to use the official container when the harness
#                          image is missing (default: false)
#   HARNESS_IB_OFFICIAL_IMAGE  that container,
#                          docker.io/openwrt/imagebuilder:<tag> (required with
#                          the fallback)
#   HARNESS_IB_OFFICIAL_SETUP  true when it needs setup.sh run in the job
#                          (required with the fallback)

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
repository=${HARNESS_REFRESH_REPOSITORY:?HARNESS_REFRESH_REPOSITORY is required}
fallback=${HARNESS_IB_FALLBACK:-false}
check_feed_repository "${repository}"
check_grace_days "${grace}"
check_bool "${fallback}"
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
setup=false
if [ -f "${work_dir}/config.json" ]; then
	jq -c '.config.Labels // {}' "${work_dir}/config.json" >"${work_dir}/labels.json" ||
		die "cannot read the labels"
	HARNESS_STALE_DAYS=${grace} HARNESS_REFRESH_REPOSITORY=${repository} \
		"${script_dir}/image-stale-check.sh" "${work_dir}/labels.json" "${image}" >&2
elif [ "${fallback}" = true ]; then
	official=${HARNESS_IB_OFFICIAL_IMAGE:?HARNESS_IB_OFFICIAL_IMAGE is required with the fallback}
	setup=${HARNESS_IB_OFFICIAL_SETUP:?HARNESS_IB_OFFICIAL_SETUP is required with the fallback}
	check_bool "${setup}"
	case "${official}" in
	docker.io/*/*:*) ;;
	*) die "the official Image Builder image must be docker.io/<owner>/<name>:<tag>" ;;
	esac
	case "${official}" in
	*[!A-Za-z0-9._/:-]*) die "invalid official Image Builder image" ;;
	*) ;;
	esac
	setup_note=
	if [ "${setup}" = true ]; then
		setup_note=' and downloads the Image Builder with setup.sh'
	fi
	printf '::notice title=Image Builder downloaded at run time::%s is not in the daily refresh, so this run uses the official %s%s. It is slower and not pinned by digest. To have the image ready, add the profile to a packages/<name>/config.yml of %s (the refresh builds what the configs name).\n' \
		"${image}" "${official}" "${setup_note}" "${repository}" >&2
	image=${official}
else
	image_missing_error "${image}" "${repository}"
	die "the Image Builder image ${image} is not readable anonymously (missing or private)"
fi

start=$(date +%s)
docker pull --quiet "${image}" >&2 || die "cannot pull ${image}"
end=$(date +%s)
digest=$(docker image inspect --format '{{index .RepoDigests 0}}' "${image}") ||
	die "cannot inspect ${image}"
size=$(docker image inspect --format '{{.Size}}' "${image}") ||
	die "cannot inspect ${image}"

printf 'HARNESS_IB_IMAGE=%s\n' "${image}"
printf 'HARNESS_IB_SETUP=%s\n' "${setup}"
printf 'HARNESS_IB_DIGEST=%s\n' "${digest}"
printf 'HARNESS_IB_SIZE_BYTES=%s\n' "${size}"
printf 'HARNESS_IB_PULL_SECONDS=%s\n' "$((end - start))"
