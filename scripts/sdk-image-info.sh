#!/usr/bin/env sh
# Responsibility: pin the harness SDK image of one build job. It reads the image
# of the tag anonymously from GHCR (the same access the build gets) and prints
# KEY=value lines: the pin <tag>@<digest> the build must use, the digest,
# creation time, SDK archive, its sha256 and whether this run built the image
# or reused one. It fails the job when the image is not publicly readable or
# its labels are invalid. It does not apply the age rule again: whether the
# image is fresh enough was decided by the sdk-image job of this run (an image
# reused at 23 h 55 min must not fail the build that starts after 24 h).
# Nothing is printed unless every check passed, so the output is safe for
# $GITHUB_ENV.
#
# Usage:
#   scripts/sdk-image-info.sh >> "$GITHUB_ENV"
#
# Environment variables (set by scripts/resolve-sdk.sh and the workflow):
#   HARNESS_SDK_CONTAINER, HARNESS_SDK_ARCH
#   GITHUB_RUN_ID, GITHUB_RUN_ATTEMPT

set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "${script_dir}/lib/common.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/sdk-age.sh
. "${script_dir}/lib/sdk-age.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/ghcr.sh
. "${script_dir}/lib/ghcr.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/sdk-labels.sh
. "${script_dir}/lib/sdk-labels.sh"

container=${HARNESS_SDK_CONTAINER:?HARNESS_SDK_CONTAINER is required}
tag=${HARNESS_SDK_ARCH:?HARNESS_SDK_ARCH is required}
run_id=${GITHUB_RUN_ID:?GITHUB_RUN_ID is required}
run_attempt=${GITHUB_RUN_ATTEMPT:?GITHUB_RUN_ATTEMPT is required}

check_sdk_container "${container}"
check_sdk_tag "${tag}"
case "${run_id}${run_attempt}" in
*[!0-9]* | '') die "invalid run id or attempt" ;;
*) ;;
esac

repo_path=${container#ghcr.io/}
work_dir=$(mktemp -d)
trap 'rm -rf "${work_dir}"' EXIT

# No GHCR_USER: this read is anonymous on purpose.
ghcr_inspect "${repo_path}" "${tag}" "${work_dir}"
[ -f "${work_dir}/config.json" ] ||
	die "the SDK image ${container}:${tag} is not readable anonymously (missing or private)"
digest=$(ghcr_digest "${work_dir}")
created=$(ghcr_label "${work_dir}" "${label_created}")
archive=$(ghcr_label "${work_dir}" "${label_archive}")
archive_sha=$(ghcr_label "${work_dir}" "${label_archive_sha}")
built_run=$(ghcr_label "${work_dir}" "${label_run_id}")
built_attempt=$(ghcr_label "${work_dir}" "${label_run_attempt}")

created_epoch=$(utc_to_epoch "${created}")
check_digest "${digest}"
check_sdk_archive "${archive_sha}" "${archive}"
case "${built_run}${built_attempt}" in
*[!0-9]* | '') die "invalid run labels on the SDK image" ;;
*) ;;
esac

if [ "${built_run}" = "${run_id}" ] && [ "${built_attempt}" = "${run_attempt}" ]; then
	state=rebuilt
else
	state=reused
fi

# stderr: stdout goes to $GITHUB_ENV.
now=$(date +%s)
printf 'sdk-image-info: pinned %s@%s, age %s s (not re-checked: decided by sdk-image)\n' \
	"${tag}" "${digest}" "$((now - created_epoch))" >&2
printf 'HARNESS_SDK_PIN=%s@%s\n' "${tag}" "${digest}"
printf 'HARNESS_SDK_DIGEST=%s\n' "${digest}"
printf 'HARNESS_SDK_CREATED=%s\n' "${created}"
printf 'HARNESS_SDK_ARCHIVE=%s\n' "${archive}"
printf 'HARNESS_SDK_ARCHIVE_SHA256=%s\n' "${archive_sha}"
printf 'HARNESS_SDK_STATE=%s\n' "${state}"
