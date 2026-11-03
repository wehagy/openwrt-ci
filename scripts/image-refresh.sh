#!/usr/bin/env sh
# Responsibility: bring one harness image on GHCR up to date with its upstream:
# an SDK image (ghcr.io/<owner>/openwrt-sdk:<arch>-<suffix>) or an Image
# Builder image (ghcr.io/<owner>/openwrt-imagebuilder:<target>-<subtarget>-
# <suffix>). It is the only code that writes them, and it runs only in the
# scheduled refresh (.github/workflows/refresh-images.yml), never in a build.
#
# The image is rebuilt only when what it is made of changed (lib/image-decide.sh,
# image_decide): it is missing, the recipe (the Dockerfile and the scripts it copies) changed, or its
# upstream changed. Upstream is, for mode "build" (SDK, and the Image Builder
# of a snapshot line), the sha256 of the archive that the official container's
# setup.sh would download, read from the sha256sums it names; for mode "mirror"
# (the Image Builder of a release line, already set up in the official
# container) the digest of that container. An image that is up to date is left
# untouched.
#
# A rebuild pulls the official container, runs its setup.sh once (build: with
# docker/<kind>-image/Dockerfile, which retries a sha256 mismatch of a
# snapshot published file by file, see scripts/ib-setup.sh) and pushes the
# result with labels. The image it supersedes stays as <tag>-prev, so builds
# that pinned it by digest keep working; the version that was <tag>-prev is
# deleted. There is no lock: the decision is made again after the local build
# and just before the push, so a job that finds another job's identical image
# discards its build instead of pushing.
#
# Usage:
#   scripts/image-refresh.sh
#
# Environment variables (set by scripts/resolve-refresh.sh and the workflow):
#   HARNESS_IMG_KIND        sdk or ib
#   HARNESS_IMG_MODE        build or mirror
#   HARNESS_IMG_CONTAINER   ghcr.io/<owner>/<name>
#   HARNESS_IMG_TAG         tag
#   HARNESS_IMG_IMAGE       <container>:<tag>
#   HARNESS_IMG_BASE        official container image, <repository>:<tag>
#   HARNESS_IMG_DOCKERFILE  docker/sdk-image or docker/ib-image (build mode)
#   HARNESS_IMG_RELEASE     release the mirrored container holds (mirror mode)
#   HARNESS_FORCE           true to rebuild an image created before this
#                           script started, even an up to date one
#                           (default: false)
#   GITHUB_TOKEN            token with packages: write
#   GITHUB_ACTOR, GITHUB_REPOSITORY (the repository whose token pushes),
#   GITHUB_RUN_ID, GITHUB_RUN_ATTEMPT
#   GH_TOKEN                same token, for the gh CLI (package versions API)
#   GITHUB_STEP_SUMMARY     optional; the decision is appended to it

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
# shellcheck source=lib/ghcr-versions.sh
. "${script_dir}/lib/ghcr-versions.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/sdk-labels.sh
. "${script_dir}/lib/sdk-labels.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/image-upstream.sh
. "${script_dir}/lib/image-upstream.sh"

kind=${HARNESS_IMG_KIND:?HARNESS_IMG_KIND is required}
mode=${HARNESS_IMG_MODE:?HARNESS_IMG_MODE is required}
container=${HARNESS_IMG_CONTAINER:?HARNESS_IMG_CONTAINER is required}
tag=${HARNESS_IMG_TAG:?HARNESS_IMG_TAG is required}
image=${HARNESS_IMG_IMAGE:?HARNESS_IMG_IMAGE is required}
base_image=${HARNESS_IMG_BASE:?HARNESS_IMG_BASE is required}
dockerfile_dir=${HARNESS_IMG_DOCKERFILE:-}
release=${HARNESS_IMG_RELEASE:-}
force=${HARNESS_FORCE:-false}
actor=${GITHUB_ACTOR:?GITHUB_ACTOR is required}
repository=${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}
run_id=${GITHUB_RUN_ID:?GITHUB_RUN_ID is required}
run_attempt=${GITHUB_RUN_ATTEMPT:?GITHUB_RUN_ATTEMPT is required}
: "${GITHUB_TOKEN:?GITHUB_TOKEN is required}"

check_sdk_container "${container}"
check_sdk_tag "${tag}"
check_bool "${force}"
[ "${image}" = "${container}:${tag}" ] || die "HARNESS_IMG_IMAGE does not match container and tag"
case "${kind}:${mode}" in
sdk:build | ib:build | ib:mirror) ;;
*) die "unsupported image kind and mode (allowed: sdk:build, ib:build, ib:mirror)" ;;
esac
case "${mode}:${dockerfile_dir}" in
build:docker/sdk-image | build:docker/ib-image | mirror:) ;;
*) die "HARNESS_IMG_DOCKERFILE must be docker/sdk-image or docker/ib-image in mode build, and empty in mode mirror" ;;
esac
case "${actor}${repository}${run_id}${run_attempt}${base_image}${release}" in
*[!A-Za-z0-9._/:-]* | '') die "invalid GitHub context, base image or release" ;;
*) ;;
esac
case "${run_id}${run_attempt}" in
*[!0-9]*) die "invalid run id or attempt" ;;
*) ;;
esac
if [ "${mode}" = mirror ]; then
	[ -n "${release}" ] || die "HARNESS_IMG_RELEASE is required in mode mirror"
fi

repo_path=${container#ghcr.io/}
owner=${repo_path%%/*}
package=${repo_path#*/}
work_dir=$(mktemp -d)
trap 'rm -rf "${work_dir}"' EXIT
export GHCR_USER="${actor}"
export GHCR_PASSWORD="${GITHUB_TOKEN}"

# Set packages_api to the package path of the packages API. The API has one
# path per owner type, /users/<owner> or /orgs/<owner>, so it is read from the
# owner. Called by the functions that use the API, so that a reused image (a
# public read only) makes no API call.
packages_api=
set_packages_api() {
	[ -z "${packages_api}" ] || return 0
	owner_type=$(gh api "/users/${owner}" --jq .type) || die "cannot read the owner ${owner}"
	case "${owner_type}" in
	User) packages_api="/users/${owner}/packages/container/${package}" ;;
	Organization) packages_api="/orgs/${owner}/packages/container/${package}" ;;
	*) die "unexpected owner type for ${owner}" ;;
	esac
}

# Print the versions of the package as "id name tags created_at".
#
# Arguments:
#   $1  heading
list_versions() {
	set_packages_api
	printf '== package versions %s (%s)\n' "$1" "${package}"
	gh api --paginate "${packages_api}/versions" \
		--jq '.[] | [.id, .name, (.metadata.container.tags | join(",")), .created_at] | @tsv' ||
		die "cannot list the package versions"
}

# Delete the package version whose name is a manifest digest; a version that is
# already gone (not listed, or HTTP 404 on the delete and absent from a fresh
# listing) is not an error.
# Appends to ${deleted} what it deleted.
#
# Arguments:
#   $1  digest
delete_version() {
	set_packages_api
	dv_id=$(gh api --paginate "${packages_api}/versions" \
		--jq ".[] | select(.name == \"$1\") | .id") ||
		die "cannot look up the version of $1"
	case "${dv_id}" in
	'') printf 'image-refresh: version %s is already gone\n' "$1" ;;
	*[!0-9]*) die "expected one version id for $1" ;;
	*)
		# A 404 on the delete is a concurrent job that superseded the same
		# version first: the version is gone, which is the goal, provided a
		# fresh listing no longer has it (see lib/ghcr-versions.sh). Every
		# other error still aborts.
		dv_result=$(ghcr_delete_version "${packages_api}" "${dv_id}")
		case "${dv_result}" in
		deleted)
			deleted="${deleted:+${deleted} }${dv_id} ($1)"
			printf 'image-refresh: deleted version %s (%s)\n' "${dv_id}" "$1"
			;;
		already-gone) printf 'image-refresh: version %s (%s) is already gone\n' "${dv_id}" "$1" ;;
		*) die "unexpected result of the delete of ${dv_id}" ;;
		esac
		;;
	esac
}

# ---------------------------------------------------------------------------
# Upstream: what the image would be made of now.
# ---------------------------------------------------------------------------
# The official container is pulled once: its digest identifies a mirror, and
# its environment names the sha256sums that setup.sh reads. The same local
# copy is built from, so the digest recorded in the labels is the one used.
printf 'image-refresh: image=%s kind=%s mode=%s base=%s\n' "${image}" "${kind}" "${mode}" "${base_image}"
docker pull --quiet "${base_image}" || die "cannot pull ${base_image}"
base_repo_digest=$(docker image inspect --format '{{index .RepoDigests 0}}' "${base_image}") ||
	die "cannot inspect ${base_image}"
base_digest=${base_repo_digest#*@}
check_digest "${base_digest}"

upstream_url=
upstream_name=
pick=
source_now=${base_digest}
source_label=${label_source_digest}
if [ "${mode}" = build ]; then
	env_file="${work_dir}/env.json"
	docker image inspect --format '{{json .Config.Env}}' "${base_image}" >"${env_file}" ||
		die "cannot read the environment of ${base_image}"
	up_host=$(upstream_env_get "${env_file}" FILE_HOST)
	up_path=$(upstream_env_get "${env_file}" VERSION_PATH)
	up_target=$(upstream_env_get "${env_file}" TARGET)
	up_pattern=$(upstream_env_get "${env_file}" DOWNLOAD_FILE)
	# setup.sh defaults for what the container leaves empty; the target and
	# the archive pattern are required, so a container that does not set them
	# fails here instead of being read as x86/64.
	upstream_url=$(upstream_sums_url "${up_host:-https://downloads.openwrt.org}" \
		"${up_path:-snapshots}" "${up_target}")
	upstream_fetch "${upstream_url}" "${work_dir}/sha256sums"
	pick=$(upstream_pick "${work_dir}/sha256sums" "${up_pattern}")
	source_now=${pick%% *}
	upstream_name=${pick#* }
	source_label=${label_archive_sha}
	printf 'image-refresh: upstream archive %s sha256 %s (%s)\n' "${upstream_name}" "${source_now}" "${upstream_url}"
fi

# ---------------------------------------------------------------------------
# Decision: reuse the image or rebuild it.
# ---------------------------------------------------------------------------
# A forced refresh treats an image created before this point as stale; one
# that a concurrent job pushed after it satisfies the request.
refresh_since=
if [ "${force}" = true ]; then
	refresh_since=$(date +%s)
fi

# The recipe of the image is what the build copies and runs: the Dockerfile and
# the two scripts it copies into the image (ib-setup.sh, which runs setup.sh,
# and lib/common.sh). The sha256 of the three, in this order, is a label, and
# an image labelled with another one (or none) is rebuilt. A mirror has none.
# The digest of the official container the build starts from is recorded but
# does not decide: that container is republished with every snapshot, which
# would rebuild the image daily whatever the archive did.
recipe_sha=
if [ "${mode}" = build ]; then
	recipe_file="${work_dir}/recipe"
	cat "${script_dir}/../${dockerfile_dir}/Dockerfile" "${script_dir}/ib-setup.sh" \
		"${script_dir}/lib/common.sh" >"${recipe_file}" || die "cannot read the recipe files"
	recipe_sha=$(sha256sum "${recipe_file}") || die "cannot hash the recipe"
	recipe_sha=${recipe_sha%% *}
	[ "${#recipe_sha}" -eq 64 ] || die "unexpected sha256 of the recipe"
fi

# Read the image of the tag and decide with image_decide. Sets old_digest and
# old_created (empty when the image is missing), decision and reason.
decide() {
	decide_dir=$(mktemp -d "${work_dir}/decide.XXXXXX") || die "cannot create a work directory"
	ghcr_inspect "${repo_path}" "${tag}" "${decide_dir}"
	old_digest=
	old_created=
	old_recipe=
	old_url=
	old_source=
	decide_exists=false
	if [ -f "${decide_dir}/config.json" ]; then
		decide_exists=true
		old_digest=$(ghcr_digest "${decide_dir}")
		old_created=$(ghcr_label "${decide_dir}" "${label_created}")
		old_recipe=$(ghcr_label "${decide_dir}" "${label_recipe}")
		old_url=$(ghcr_label "${decide_dir}" "${label_upstream}")
		old_source=$(ghcr_label "${decide_dir}" "${source_label}")
	fi
	decide_out=$(image_decide "${decide_exists}" "${old_created}" "${refresh_since}" \
		"${recipe_sha}" "${old_recipe}" "${upstream_url}" "${old_url}" "${source_now}" "${old_source}")
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
		printf '### %s image %s\n' "${kind}" "${tag}"
		printf -- '- decision: %s (%s)\n' "${decision}" "${reason}"
		printf -- '- digest: %s, created %s\n' "$1" "$2"
		[ -z "$3" ] || printf -- '- %s\n' "$3"
	} >>"${GITHUB_STEP_SUMMARY}"
}

decide
printf 'image-refresh: image=%s decision=%s reason="%s"\n' "${image}" "${decision}" "${reason}"
if [ "${decision}" = reuse ]; then
	printf 'image-refresh: reused %s created %s\n' "${old_digest}" "${old_created}"
	write_summary "${old_digest}" "${old_created}" ""
	exit 0
fi

# ---------------------------------------------------------------------------
# Rebuild: run setup.sh once (build) or take the official container (mirror),
# label and push.
# ---------------------------------------------------------------------------
# The creation time is taken before setup.sh downloads the archive, so the
# image is never younger than its content.
created=$(date -u +%Y-%m-%dT%H:%M:%SZ)
archive_name=
archive_sha=
if [ "${mode}" = build ]; then
	stage="image-refresh-stage:${tag}"
	# The build context: the Dockerfile and the script that retries setup.sh.
	ctx=$(mktemp -d "${work_dir}/ctx.XXXXXX") || die "cannot create a work directory"
	mkdir "${ctx}/lib" || die "cannot create ${ctx}/lib"
	cp "${script_dir}/../${dockerfile_dir}/Dockerfile" "${ctx}/Dockerfile" || die "cannot copy the Dockerfile"
	cp "${script_dir}/ib-setup.sh" "${ctx}/ib-setup.sh" || die "cannot copy ib-setup.sh"
	cp "${script_dir}/lib/common.sh" "${ctx}/lib/common.sh" || die "cannot copy common.sh"
	# No --pull: the build uses the container whose digest was read above.
	docker build --build-arg "BASE=${base_image}" -t "${stage}" "${ctx}" || die "docker build failed"
	archive_line=$(docker run --rm --entrypoint cat "${stage}" /builder/.archive) ||
		die "cannot read the archive line from the image"
	archive_sha=${archive_line%% *}
	archive_name=${archive_line#"${archive_sha} *"}
	check_sdk_archive "${archive_sha}" "${archive_name}"
	# setup.sh must have taken the archive that was looked up above; a
	# different name means the lookup does not model it and the labels would lie.
	[ "${archive_name}" = "${upstream_name}" ] ||
		die "the image holds ${archive_name}, not ${upstream_name} found in ${upstream_url}"
	# The build took minutes and upstream may have published again: the image
	# is labelled with what it holds, and compared with that below.
	if [ "${archive_sha}" != "${source_now}" ]; then
		printf 'warn: upstream published %s again during the build: sha256 %s, now %s\n' \
			"${archive_name}" "${source_now}" "${archive_sha}" >&2
	fi
	source_now=${archive_sha}
else
	stage=${base_image}
fi
printf '%s\n' "${GITHUB_TOKEN}" | docker login ghcr.io -u "${actor}" --password-stdin ||
	die "docker login to ghcr.io failed"

# The build took minutes: another job may have pushed an identical image.
decide
printf 'image-refresh: image=%s re-check before the push decision=%s reason="%s"\n' \
	"${image}" "${decision}" "${reason}"
if [ "${decision}" = reuse ]; then
	printf 'image-refresh: another job pushed %s created %s; discarding the local build\n' \
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

# A config-only layer: FROM the stage, plus the labels read by the builds.
# Provenance and SBOM are off: with them the push is an image index plus
# attestation manifests, which the registry lists as extra package versions
# and which ghcr_inspect rejects. --push writes one plain image manifest.
# The source label names the repository whose token pushed, so that a package
# created by this push is linked to that repository and its workflows.
push_meta="${work_dir}/push.json"
push_err="${work_dir}/push.err"

# Arguments:
#   $@  the labels that depend on the mode, as --label options
push_image() {
	docker buildx build --pull=false --provenance=false --sbom=false --push -t "${image}" \
		--metadata-file "${push_meta}" \
		--label "${label_created}=${created}" \
		--label "org.opencontainers.image.source=https://github.com/${repository}" \
		--label "org.opencontainers.image.base.name=${base_image}" \
		--label "${label_source_digest}=${base_digest}" \
		--label "${label_source_image}=${base_image}" \
		--label "${label_run_id}=${run_id}" \
		--label "${label_run_attempt}=${run_attempt}" \
		"$@" - <<EOF
FROM ${stage}
EOF
}
# stderr goes to a file so that a denied push can be told from other failures;
# it is printed right after.
set +e
if [ "${mode}" = build ]; then
	push_image --label "${label_recipe}=${recipe_sha}" \
		--label "${label_upstream}=${upstream_url}" \
		--label "${label_archive}=${archive_name}" \
		--label "${label_archive_sha}=${archive_sha}" 2>"${push_err}"
else
	push_image --label "${label_release}=${release}" 2>"${push_err}"
fi
push_rc=$?
set -e
if [ "${push_rc}" -ne 0 ]; then
	cat "${push_err}" >&2
	if grep -qiE 'denied|forbidden|unauthori[sz]ed|insufficient_scope' "${push_err}"; then
		printf '::error::push of %s denied. The GITHUB_TOKEN of %s needs write access to the package %s: Package settings > Manage Actions access > Add Repository > %s, role Write (Admin to also delete the superseded -prev version). The package must also be public for the builds to read it.\n' \
			"${image}" "${repository}" "${container}" "${repository}"
		die "cannot push ${image}: write access to the package missing for ${repository} (see the error above)"
	fi
	die "docker buildx build (labels, push) failed"
fi
cat "${push_err}" >&2

# ---------------------------------------------------------------------------
# Verify the push, keep the superseded image as <tag>-prev, delete the one
# before it.
# ---------------------------------------------------------------------------
# Read back by digest, not by tag: another job may move the tag at any time.
new_digest=$(jq -er '."containerimage.digest"' "${push_meta}") || die "no digest in the push metadata"
check_digest "${new_digest}"
verify_dir=$(mktemp -d "${work_dir}/verify.XXXXXX") || die "cannot create a work directory"
ghcr_inspect "${repo_path}" "${new_digest}" "${verify_dir}"
[ -f "${verify_dir}/config.json" ] || die "the pushed image is not on the registry"
verify_digest=$(ghcr_digest "${verify_dir}")
[ "${verify_digest}" = "${new_digest}" ] || die "the pushed manifest does not match its digest"
new_created=$(ghcr_label "${verify_dir}" "${label_created}")
[ "${new_created}" = "${created}" ] || die "the pushed image carries another creation time"
new_source=$(ghcr_label "${verify_dir}" "${source_label}")
[ "${new_source}" = "${source_now}" ] || die "the pushed image carries another source identity"
printf 'image-refresh: pushed %s created %s source %s\n' "${new_digest}" "${created}" "${new_source}"

if [ -n "${old_digest}" ] && [ "${old_digest}" != "${new_digest}" ]; then
	check_digest "${old_digest}"
	# decide_dir holds the manifest of old_digest, read by the last decide().
	ghcr_put_manifest "${repo_path}" "${prev_tag}" "${decide_dir}"
	prev_check=$(mktemp -d "${work_dir}/prevcheck.XXXXXX") || die "cannot create a work directory"
	ghcr_inspect "${repo_path}" "${prev_tag}" "${prev_check}"
	[ -f "${prev_check}/config.json" ] || die "${prev_tag} is not on the registry"
	prev_digest=$(ghcr_digest "${prev_check}")
	[ "${prev_digest}" = "${old_digest}" ] || die "${prev_tag} does not hold the superseded digest ${old_digest}"
	printf 'image-refresh: %s now holds %s\n' "${prev_tag}" "${old_digest}"
fi

deleted=none
# Only after the superseded image was kept as <tag>-prev. The former <tag>-prev
# normally is an image manifest; an index is deleted together with the images
# it lists.
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

# Tell when another job moved the tag after our push; both images are valid.
tag_dir=$(mktemp -d "${work_dir}/tag.XXXXXX") || die "cannot create a work directory"
ghcr_inspect "${repo_path}" "${tag}" "${tag_dir}"
tag_digest=$(ghcr_digest "${tag_dir}")
if [ "${tag_digest}" != "${new_digest}" ]; then
	printf 'warn: %s was moved by another job after the push of %s\n' "${tag}" "${new_digest}" >&2
fi

write_summary "${new_digest}" "${created}" "source: ${source_now} (${upstream_name:-${base_image}}); ${prev_tag}: ${old_digest:-none}; deleted version: ${deleted}"
