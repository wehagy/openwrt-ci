#!/usr/bin/env sh
# Responsibility: make sure the harness SDK image of one (line, arch) on GHCR
# exists and is younger than the line's maximum age. A missing, too old or
# force-refreshed image is rebuilt from the official snapshot SDK container
# (docker/sdk-image/Dockerfile runs setup.sh once) and pushed. The image it
# supersedes stays as <tag>-prev, so builds that pinned it by digest keep
# working; the version that was <tag>-prev is deleted. A fresh image is reused
# untouched. There is no lock: the decision (lib/sdk-age.sh, sdk_decide) is
# made again after the local build and just before the push, so a run that
# finds another run's fresh image discards its build instead of pushing.
#
# Usage:
#   scripts/sdk-image-ensure.sh
#
# Environment variables (set by scripts/resolve-sdk.sh and the workflow):
#   HARNESS_SDK_CONTAINER, HARNESS_SDK_ARCH, HARNESS_SDK_IMAGE,
#   HARNESS_SDK_BASE_IMAGE, HARNESS_SDK_MAX_AGE_DAYS
#   HARNESS_REFRESH_SDK  true to rebuild an image created before this script
#                        started, even a fresh one (default: false)
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

# Delete the package version whose name is a manifest digest; a version that is
# already gone is not an error. Appends to ${deleted} what it deleted.
#
# Arguments:
#   $1  digest
delete_version() {
	dv_id=$(gh api --paginate "/users/${owner}/packages/container/${package}/versions" \
		--jq ".[] | select(.name == \"$1\") | .id") ||
		die "cannot look up the version of $1"
	case "${dv_id}" in
	'') printf 'sdk-image: version %s is already gone\n' "$1" ;;
	*[!0-9]*) die "expected one version id for $1" ;;
	*)
		gh api -X DELETE "/users/${owner}/packages/container/${package}/versions/${dv_id}" ||
			die "cannot delete the version ${dv_id}"
		deleted="${deleted:+${deleted} }${dv_id} ($1)"
		printf 'sdk-image: deleted version %s (%s)\n' "${dv_id}" "$1"
		;;
	esac
}

# ---------------------------------------------------------------------------
# Decision: reuse the image or rebuild it.
# ---------------------------------------------------------------------------
# An image created before this point is stale for a requested refresh; one a
# concurrent run pushed after it satisfies the request.
refresh_since=
if [ "${refresh}" = true ]; then
	refresh_since=$(date +%s)
fi

# Read the image of the tag and decide with sdk_decide. Sets old_digest and
# old_created (empty when the image is missing), decision and reason.
decide() {
	decide_dir=$(mktemp -d "${work_dir}/decide.XXXXXX") || die "cannot create a work directory"
	decide_now=$(date +%s)
	ghcr_inspect "${repo_path}" "${tag}" "${decide_dir}"
	old_digest=
	old_created=
	decide_exists=false
	if [ -f "${decide_dir}/config.json" ]; then
		decide_exists=true
		old_digest=$(ghcr_digest "${decide_dir}")
		old_created=$(ghcr_label "${decide_dir}" "${label_created}")
	fi
	decide_out=$(sdk_decide "${decide_exists}" "${old_created}" "${decide_now}" "${max_days}" "${refresh_since}")
	decision=${decide_out%% *}
	reason=${decide_out#* }
}

# Append the decision to the job summary.
#
# Arguments:
#   $1  digest of the image the job leaves on the tag
#   $2  its creation time
#   $3  extra summary line; empty for none
write_summary() {
	[ -n "${GITHUB_STEP_SUMMARY:-}" ] || return 0
	{
		printf '### sdk image %s\n' "${tag}"
		printf -- '- decision: %s (%s)\n' "${decision}" "${reason}"
		printf -- '- digest: %s, created %s\n' "$1" "$2"
		[ -z "$3" ] || printf -- '- %s\n' "$3"
	} >>"${GITHUB_STEP_SUMMARY}"
}

decide
printf 'sdk-image: image=%s decision=%s reason="%s"\n' "${image}" "${decision}" "${reason}"
if [ "${decision}" = reuse ]; then
	printf 'sdk-image: reused %s created %s\n' "${old_digest}" "${old_created}"
	write_summary "${old_digest}" "${old_created}" ""
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

# The build took minutes: another run may have pushed a fresh image meanwhile.
decide
printf 'sdk-image: image=%s re-check before the push decision=%s reason="%s"\n' \
	"${image}" "${decision}" "${reason}"
if [ "${decision}" = reuse ]; then
	printf 'sdk-image: another run pushed %s created %s; discarding the local build\n' \
		"${old_digest}" "${old_created}"
	write_summary "${old_digest}" "${old_created}" "local build discarded"
	exit 0
fi

# What the tag held before the push becomes <tag>-prev; what <tag>-prev held
# is deleted after the push.
prev_tag="${tag}-prev"
prev_dir=$(mktemp -d "${work_dir}/prev.XXXXXX") || die "cannot create a work directory"
ghcr_manifest "${repo_path}" "${prev_tag}" "${prev_dir}"
old_prev=
if [ -f "${prev_dir}/digest" ]; then
	old_prev=$(ghcr_digest "${prev_dir}")
fi

# A config-only layer: FROM the stage, plus the labels read by the build job.
# Provenance and SBOM are off: with them the push is an image index plus
# attestation manifests, which the registry lists as extra package versions
# and which ghcr_inspect rejects. --push writes one plain image manifest.
push_meta="${work_dir}/push.json"
docker buildx build --pull=false --provenance=false --sbom=false --push -t "${image}" \
	--metadata-file "${push_meta}" \
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
# Verify the push, keep the superseded image as <tag>-prev, delete the one
# before it.
# ---------------------------------------------------------------------------
# Read back by digest, not by tag: another run may move the tag at any time.
new_digest=$(jq -er '."containerimage.digest"' "${push_meta}") || die "no digest in the push metadata"
check_digest "${new_digest}"
verify_dir=$(mktemp -d "${work_dir}/verify.XXXXXX") || die "cannot create a work directory"
ghcr_inspect "${repo_path}" "${new_digest}" "${verify_dir}"
[ -f "${verify_dir}/config.json" ] || die "the pushed image is not on the registry"
verify_digest=$(ghcr_digest "${verify_dir}")
[ "${verify_digest}" = "${new_digest}" ] || die "the pushed manifest does not match its digest"
new_created=$(ghcr_label "${verify_dir}" "${label_created}")
[ "${new_created}" = "${created}" ] || die "the pushed image carries another creation time"
printf 'sdk-image: pushed %s created %s\n' "${new_digest}" "${created}"

if [ -n "${old_digest}" ] && [ "${old_digest}" != "${new_digest}" ]; then
	check_digest "${old_digest}"
	# decide_dir holds the manifest of old_digest, read by the last decide().
	ghcr_put_manifest "${repo_path}" "${prev_tag}" "${decide_dir}"
	prev_check=$(mktemp -d "${work_dir}/prevcheck.XXXXXX") || die "cannot create a work directory"
	ghcr_inspect "${repo_path}" "${prev_tag}" "${prev_check}"
	[ -f "${prev_check}/config.json" ] || die "${prev_tag} is not on the registry"
	prev_digest=$(ghcr_digest "${prev_check}")
	[ "${prev_digest}" = "${old_digest}" ] || die "${prev_tag} does not hold the superseded digest ${old_digest}"
	printf 'sdk-image: %s now holds %s\n' "${prev_tag}" "${old_digest}"
fi

deleted=none
# Only after the superseded image was kept as <tag>-prev. The former <tag>-prev
# normally is an image manifest; an index (left by an earlier version of this
# script) is deleted together with the images it lists.
if [ -n "${old_prev}" ] && [ -n "${old_digest}" ] && [ "${old_prev}" != "${old_digest}" ] &&
	[ "${old_prev}" != "${new_digest}" ]; then
	check_digest "${old_prev}"
	list_versions "after the push, before the delete"
	prev_children=$(jq -r '.manifests[]?.digest' "${prev_dir}/manifest.json") ||
		die "cannot read the former ${prev_tag} manifest"
	deleted=
	for doomed in "${old_prev}" ${prev_children}; do
		check_digest "${doomed}"
		if [ "${doomed}" != "${old_digest}" ] && [ "${doomed}" != "${new_digest}" ]; then
			delete_version "${doomed}"
		fi
	done
	[ -n "${deleted}" ] || deleted=none
fi

list_versions "after the delete"

# Tell when another run moved the tag after our push; both images are valid.
tag_dir=$(mktemp -d "${work_dir}/tag.XXXXXX") || die "cannot create a work directory"
ghcr_inspect "${repo_path}" "${tag}" "${tag_dir}"
tag_digest=$(ghcr_digest "${tag_dir}")
if [ "${tag_digest}" != "${new_digest}" ]; then
	printf 'warn: %s was moved by another run after the push of %s\n' "${tag}" "${new_digest}" >&2
fi

write_summary "${new_digest}" "${created}" "SDK archive: ${archive_name} (sha256 ${archive_sha}); ${prev_tag}: ${old_digest:-none}; deleted version: ${deleted}"
