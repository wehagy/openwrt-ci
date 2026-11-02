#!/usr/bin/env sh
# Responsibility: read the harness SDK image of one build job anonymously from
# GHCR (the same access the build gets) and print what the job summary
# records as KEY=value lines: digest, creation time, SDK archive, its sha256
# and whether this run rebuilt the image or reused one. It also fails the job
# when the image is not publicly readable, is older than the line's maximum
# age, or was not rebuilt by this run although a refresh was requested.
# Nothing is printed unless every check passed, so the output is safe for
# $GITHUB_ENV.
#
# Usage:
#   scripts/sdk-image-info.sh >> "$GITHUB_ENV"
#
# Environment variables (set by scripts/resolve-sdk.sh and the workflow):
#   HARNESS_SDK_CONTAINER, HARNESS_SDK_ARCH, HARNESS_SDK_MAX_AGE_DAYS
#   HARNESS_REFRESH_SDK  true when the run asked for a refresh (default: false)
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
max_days=${HARNESS_SDK_MAX_AGE_DAYS:?HARNESS_SDK_MAX_AGE_DAYS is required}
refresh=${HARNESS_REFRESH_SDK:-false}
run_id=${GITHUB_RUN_ID:?GITHUB_RUN_ID is required}
run_attempt=${GITHUB_RUN_ATTEMPT:?GITHUB_RUN_ATTEMPT is required}

check_sdk_container "${container}"
check_sdk_tag "${tag}"
check_max_age_days "${max_days}"
check_bool "${refresh}"
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

now=$(date +%s)
freshness=$(sdk_freshness "${created_epoch}" "${now}" "${max_days}")
[ "${freshness}" = fresh ] ||
	die "the SDK image is older than ${max_days} day(s) (created ${created})"
if [ "${refresh}" = true ] && [ "${state}" != rebuilt ]; then
	die "refresh_sdk was requested but this run did not rebuild the SDK image"
fi

printf 'HARNESS_SDK_DIGEST=%s\n' "${digest}"
printf 'HARNESS_SDK_CREATED=%s\n' "${created}"
printf 'HARNESS_SDK_ARCHIVE=%s\n' "${archive}"
printf 'HARNESS_SDK_ARCHIVE_SHA256=%s\n' "${archive_sha}"
printf 'HARNESS_SDK_STATE=%s\n' "${state}"
