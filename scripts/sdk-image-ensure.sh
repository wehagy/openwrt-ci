#!/usr/bin/env sh
# Responsibility: make sure the harness SDK image of one (line, arch) on GHCR
# exists and is younger than the line's maximum age. A missing, too old or
# force-refreshed image is rebuilt from the official snapshot SDK container
# (docker/sdk-image/Dockerfile runs setup.sh once), pushed, and the version it
# supersedes is deleted. A fresh image is reused untouched.
#
# Usage:
#   scripts/sdk-image-ensure.sh
#
# Environment variables (set by scripts/resolve-sdk.sh and the workflow):
#   HARNESS_SDK_CONTAINER, HARNESS_SDK_ARCH, HARNESS_SDK_IMAGE,
#   HARNESS_SDK_BASE_IMAGE, HARNESS_SDK_MAX_AGE_DAYS
#   HARNESS_REFRESH_SDK  true to rebuild even a fresh image (default: false)
#   GITHUB_TOKEN         token with packages: write
#   GITHUB_ACTOR, GITHUB_REPOSITORY, GITHUB_RUN_ID, GITHUB_RUN_ATTEMPT
#   GH_TOKEN             same token, for the gh CLI (package versions API)
#   GITHUB_STEP_SUMMARY  optional; the decision is appended to it

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
image=${HARNESS_SDK_IMAGE:?HARNESS_SDK_IMAGE is required}
base_image=${HARNESS_SDK_BASE_IMAGE:?HARNESS_SDK_BASE_IMAGE is required}
max_days=${HARNESS_SDK_MAX_AGE_DAYS:?HARNESS_SDK_MAX_AGE_DAYS is required}
refresh=${HARNESS_REFRESH_SDK:-false}
actor=${GITHUB_ACTOR:?GITHUB_ACTOR is required}
repository=${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}
run_id=${GITHUB_RUN_ID:?GITHUB_RUN_ID is required}
run_attempt=${GITHUB_RUN_ATTEMPT:?GITHUB_RUN_ATTEMPT is required}
: "${GITHUB_TOKEN:?GITHUB_TOKEN is required}"

check_sdk_container "${container}"
check_sdk_tag "${tag}"
check_max_age_days "${max_days}"
check_bool "${refresh}"
[ "${image}" = "${container}:${tag}" ] || die "HARNESS_SDK_IMAGE does not match container and tag"
case "${actor}${repository}${run_id}${run_attempt}${base_image}" in
*[!A-Za-z0-9._/:-]* | '') die "invalid GitHub context or base image" ;;
*) ;;
esac
case "${run_id}${run_attempt}" in
*[!0-9]*) die "invalid run id or attempt" ;;
*) ;;
esac

repo_path=${container#ghcr.io/}
owner=${repo_path%%/*}
package=${repo_path#*/}
work_dir=$(mktemp -d)
trap 'rm -rf "${work_dir}"' EXIT
export GHCR_USER="${actor}"
export GHCR_PASSWORD="${GITHUB_TOKEN}"

# Print the versions of the package as "id name tags created_at".
#
# Arguments:
#   $1  heading
list_versions() {
	printf '== package versions %s (%s)\n' "$1" "${package}"
	gh api --paginate "/users/${owner}/packages/container/${package}/versions" \
		--jq '.[] | [.id, .name, (.metadata.container.tags | join(",")), .created_at] | @tsv' ||
		die "cannot list the package versions"
}

# ---------------------------------------------------------------------------
# Decision: reuse the image or rebuild it.
# ---------------------------------------------------------------------------
now=$(date +%s)
old_digest=
age_s=none
ghcr_inspect "${repo_path}" "${tag}" "${work_dir}"
if [ -f "${work_dir}/config.json" ]; then
	old_digest=$(ghcr_digest "${work_dir}")
	old_created=$(ghcr_label "${work_dir}" "${label_created}")
	old_epoch=$(utc_to_epoch "${old_created}")
	age_s=$((now - old_epoch))
	freshness=$(sdk_freshness "${old_epoch}" "${now}" "${max_days}")
	if [ "${refresh}" = true ]; then
		decision=rebuild
		reason="refresh_sdk requested (age ${age_s} s)"
	elif [ "${freshness}" = fresh ]; then
		decision=reuse
		reason="age ${age_s} s <= ${max_days} day(s)"
	else
		decision=rebuild
		reason="age ${age_s} s > ${max_days} day(s)"
	fi
else
	decision=rebuild
	reason="image missing"
fi
printf 'sdk-image: image=%s decision=%s reason="%s"\n' "${image}" "${decision}" "${reason}"
if [ "${decision}" = reuse ]; then
	printf 'sdk-image: reused %s created %s\n' "${old_digest}" "${old_created}"
	if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
		{
			printf '### sdk image %s\n' "${tag}"
			printf -- '- decision: reuse (%s)\n' "${reason}"
			printf -- '- digest: %s, created %s\n' "${old_digest}" "${old_created}"
		} >>"${GITHUB_STEP_SUMMARY}"
	fi
	exit 0
fi

# ---------------------------------------------------------------------------
# Rebuild: run setup.sh once, label and push.
# ---------------------------------------------------------------------------
# The creation time is taken before setup.sh downloads the SDK, so the image
# is never younger than its content.
created=$(date -u +%Y-%m-%dT%H:%M:%SZ)
stage="sdk-image-stage:${tag}"
printf '%s\n' "${GITHUB_TOKEN}" | docker login ghcr.io -u "${actor}" --password-stdin ||
	die "docker login to ghcr.io failed"
docker build --pull --build-arg "BASE=${base_image}" -t "${stage}" \
	"${script_dir}/../docker/sdk-image" || die "docker build failed"
archive_line=$(docker run --rm --entrypoint cat "${stage}" /builder/.sdk-archive) ||
	die "cannot read the SDK archive line from the image"
archive_sha=${archive_line%% *}
archive_name=${archive_line#"${archive_sha} *"}
check_sdk_archive "${archive_sha}" "${archive_name}"

# A config-only layer: FROM the stage, plus the labels read by the build job.
# Provenance and SBOM are off: with them the push is an image index plus
# attestation manifests, which the registry lists as extra package versions
# and which ghcr_inspect rejects. --push writes one plain image manifest.
docker buildx build --pull=false --provenance=false --sbom=false --push -t "${image}" \
	--label "${label_created}=${created}" \
	--label "org.opencontainers.image.source=https://github.com/${repository}" \
	--label "org.opencontainers.image.base.name=${base_image}" \
	--label "${label_archive}=${archive_name}" \
	--label "${label_archive_sha}=${archive_sha}" \
	--label "${label_run_id}=${run_id}" \
	--label "${label_run_attempt}=${run_attempt}" - <<EOF || die "docker buildx build (labels, push) failed"
FROM ${stage}
EOF

# ---------------------------------------------------------------------------
# Verify the push and delete the version it superseded.
# ---------------------------------------------------------------------------
verify_dir=$(mktemp -d "${work_dir}/verify.XXXXXX")
ghcr_inspect "${repo_path}" "${tag}" "${verify_dir}"
[ -f "${verify_dir}/config.json" ] || die "the pushed image is not on the registry"
new_digest=$(ghcr_digest "${verify_dir}")
[ "${new_digest}" != "${old_digest}" ] || die "the pushed image has the old digest"
new_created=$(ghcr_label "${verify_dir}" "${label_created}")
[ "${new_created}" = "${created}" ] || die "the pushed image carries another creation time"
printf 'sdk-image: pushed %s created %s\n' "${new_digest}" "${created}"
if [ -n "${old_digest}" ]; then
	list_versions "after the push, before the delete"
fi

deleted=none
if [ -n "${old_digest}" ]; then
	case "${old_digest}" in
	sha256:*[!0-9a-f]* | sha256:) die "invalid old digest" ;;
	*) ;;
	esac
	old_id=$(gh api --paginate "/users/${owner}/packages/container/${package}/versions" \
		--jq ".[] | select(.name == \"${old_digest}\") | .id") ||
		die "cannot look up the superseded version"
	case "${old_id}" in
	*[!0-9]* | '') die "expected one superseded version id for ${old_digest}" ;;
	*) ;;
	esac
	gh api -X DELETE "/users/${owner}/packages/container/${package}/versions/${old_id}" ||
		die "cannot delete the superseded version ${old_id}"
	deleted="${old_id} (${old_digest})"
	printf 'sdk-image: deleted superseded version %s\n' "${deleted}"
fi
list_versions "after the delete"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
	{
		printf '### sdk image %s\n' "${tag}"
		printf -- '- decision: rebuild (%s)\n' "${reason}"
		printf -- '- digest: %s, created %s\n' "${new_digest}" "${created}"
		printf -- '- SDK archive: %s (sha256 %s)\n' "${archive_name}" "${archive_sha}"
		printf -- '- superseded version deleted: %s\n' "${deleted}"
	} >>"${GITHUB_STEP_SUMMARY}"
fi
