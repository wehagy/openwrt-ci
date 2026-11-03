#!/usr/bin/env sh
# Responsibility: pin the harness SDK image of one build job. It reads the image
# of the tag anonymously from GHCR (the same access the build gets) and prints
# KEY=value lines: the pin <tag>@<digest> the build must use, the digest,
# creation time, SDK archive and its sha256. The build only reads the image:
# the daily refresh (refresh-images.yml) writes it. A missing or private image
# fails the job with the command that refreshes it by hand; an image that is
# stale (scripts/image-stale-check.sh) only raises a warning annotation, since
# a build on yesterday's SDK is still a valid build. Nothing is printed unless
# every check passed, so the output is safe for $GITHUB_ENV.
#
# Usage:
#   scripts/sdk-image-info.sh >> "$GITHUB_ENV"
#
# Environment variables (set by scripts/resolve-sdk.sh and the workflow):
#   HARNESS_SDK_CONTAINER, HARNESS_SDK_ARCH, HARNESS_SDK_GRACE_DAYS
#   GITHUB_REPOSITORY  repository of the caller, in the refresh command

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
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/sdk-labels.sh
. "${script_dir}/lib/sdk-labels.sh"

container=${HARNESS_SDK_CONTAINER:?HARNESS_SDK_CONTAINER is required}
tag=${HARNESS_SDK_ARCH:?HARNESS_SDK_ARCH is required}
grace=${HARNESS_SDK_GRACE_DAYS:?HARNESS_SDK_GRACE_DAYS is required}
repository=${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}

check_sdk_container "${container}"
check_sdk_tag "${tag}"
check_grace_days "${grace}"

repo_path=${container#ghcr.io/}
work_dir=$(mktemp -d)
trap 'rm -rf "${work_dir}"' EXIT

# No GHCR_USER: this read is anonymous on purpose.
ghcr_inspect "${repo_path}" "${tag}" "${work_dir}"
if [ ! -f "${work_dir}/config.json" ]; then
	image_missing_error "${container}:${tag}" "${repository}"
	die "the SDK image ${container}:${tag} is not readable anonymously (missing or private)"
fi
digest=$(ghcr_digest "${work_dir}")
created=$(ghcr_label "${work_dir}" "${label_created}")
archive=$(ghcr_label "${work_dir}" "${label_archive}")
archive_sha=$(ghcr_label "${work_dir}" "${label_archive_sha}")

created_epoch=$(utc_to_epoch "${created}")
check_digest "${digest}"
check_sdk_archive "${archive_sha}" "${archive}"

# Stale is a warning, never a failure; its output goes to stderr because
# stdout is the file of the job environment.
jq -c '.config.Labels // {}' "${work_dir}/config.json" >"${work_dir}/labels.json" ||
	die "cannot read the labels"
HARNESS_STALE_DAYS=${grace} GITHUB_REPOSITORY=${repository} \
	"${script_dir}/image-stale-check.sh" "${work_dir}/labels.json" "${container}:${tag}" >&2

# stderr: stdout goes to $GITHUB_ENV.
now=$(date +%s)
printf 'sdk-image-info: pinned %s@%s, age %s s\n' \
	"${tag}" "${digest}" "$((now - created_epoch))" >&2
printf 'HARNESS_SDK_PIN=%s@%s\n' "${tag}" "${digest}"
printf 'HARNESS_SDK_DIGEST=%s\n' "${digest}"
printf 'HARNESS_SDK_CREATED=%s\n' "${created}"
printf 'HARNESS_SDK_ARCHIVE=%s\n' "${archive}"
printf 'HARNESS_SDK_ARCHIVE_SHA256=%s\n' "${archive_sha}"
