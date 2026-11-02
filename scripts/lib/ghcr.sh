#!/usr/bin/env sh
# Responsibility: read an image manifest and config from the GHCR registry
# API with curl (sourced, not run). Anonymous unless GHCR_USER is set.
#
# Usage:
#   . "${script_dir}/lib/common.sh"
#   . "${script_dir}/lib/ghcr.sh"
#
# Environment variables:
#   GHCR_USER      user for an authenticated token (default: anonymous)
#   GHCR_PASSWORD  token of that user (required when GHCR_USER is set)

# curl with the options shared by every registry call.
#
# Arguments:
#   $@  curl arguments
ghcr_curl() {
	curl -sS --retry 3 --connect-timeout 20 --max-time 120 "$@"
}

# Write a curl config that sets the Authorization header or the basic-auth
# user, so that no secret appears in the process list.
#
# Arguments:
#   $1  file to write
#   $2  bearer token; empty for the basic-auth config of GHCR_USER
ghcr_write_curl_config() {
	umask 077
	if [ -n "$2" ]; then
		printf 'header = "Authorization: Bearer %s"\n' "$2" >"$1"
	else
		printf 'user = "%s:%s"\n' "${GHCR_USER}" "${GHCR_PASSWORD:?GHCR_PASSWORD is required}" >"$1"
	fi
}

# Write bearer.conf (a curl config with the registry token) into the
# directory, for an authenticated token when GHCR_USER is set, else anonymous.
#
# Arguments:
#   $1  repository path, e.g. <owner>/openwrt-sdk
#   $2  actions of the token scope: pull or pull,push
#   $3  existing work directory
ghcr_token() {
	gt_url="https://ghcr.io/token?service=ghcr.io&scope=repository:${1}:${2}"
	if [ -n "${GHCR_USER:-}" ]; then
		ghcr_write_curl_config "${3}/auth.conf" ''
		ghcr_curl -f -K "${3}/auth.conf" -o "${3}/token.json" "${gt_url}" ||
			die "cannot get an authenticated GHCR token"
	else
		ghcr_curl -f -o "${3}/token.json" "${gt_url}" ||
			die "cannot get an anonymous GHCR token"
	fi
	gt_token=$(jq -er .token "${3}/token.json") || die "no token in the GHCR token answer"
	ghcr_write_curl_config "${3}/bearer.conf" "${gt_token}"
}

# Fetch the manifest of <repo>:<reference> into the directory, whatever its
# kind (image manifest or index). When it exists, manifest.json and digest (the
# sha256 of the manifest bytes) are written there; when the registry answers
# 404 nothing but the token files is, so `[ -f <dir>/digest ]` tells whether it
# exists. Any other answer aborts.
#
# Arguments:
#   $1  repository path, e.g. <owner>/openwrt-sdk
#   $2  tag or digest
#   $3  existing empty work directory
ghcr_manifest() {
	gm_repo=$1
	gm_ref=$2
	gm_dir=$3
	ghcr_token "${gm_repo}" pull "${gm_dir}"

	# Index types are accepted so that an index is answered 200 and rejected
	# by ghcr_inspect with a clear message, instead of a misleading 404.
	gm_accept='application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json'
	gm_code=$(ghcr_curl -K "${gm_dir}/bearer.conf" -H "Accept: ${gm_accept}" \
		-o "${gm_dir}/manifest.json" -w '%{http_code}' \
		"https://ghcr.io/v2/${gm_repo}/manifests/${gm_ref}") ||
		die "cannot reach the GHCR manifest endpoint"
	# stderr: callers print KEY=value lines on stdout for $GITHUB_ENV.
	printf 'ghcr: GET manifests/%s -> HTTP %s\n' "${gm_ref}" "${gm_code}" >&2
	case "${gm_code}" in
	200) ;;
	404) return 0 ;;
	*) die "unexpected HTTP ${gm_code} for the manifest of ${gm_repo}:${gm_ref}" ;;
	esac
	gm_sum=$(sha256sum "${gm_dir}/manifest.json") || die "cannot hash the manifest"
	printf 'sha256:%s\n' "${gm_sum%% *}" >"${gm_dir}/digest"
}

# Fetch the manifest and the config of a single-platform image <repo>:<ref>
# into the directory. When the image exists, manifest.json, config.json and
# digest are written there (see ghcr_manifest); `[ -f <dir>/config.json ]`
# tells whether it exists. An index aborts.
#
# Arguments:
#   $1  repository path, e.g. <owner>/openwrt-sdk
#   $2  tag or digest
#   $3  existing empty work directory
ghcr_inspect() {
	gi_repo=$1
	gi_ref=$2
	gi_dir=$3
	ghcr_manifest "${gi_repo}" "${gi_ref}" "${gi_dir}"
	[ -f "${gi_dir}/digest" ] || return 0
	gi_config=$(jq -er .config.digest "${gi_dir}/manifest.json") ||
		die "${gi_repo}:${gi_ref} is not a single-platform image manifest"
	gi_hex=${gi_config#sha256:}
	case "${gi_hex}" in
	*[!0-9a-f]* | '') die "invalid config digest" ;;
	*) ;;
	esac
	[ "${gi_config}" != "${gi_hex}" ] && [ "${#gi_hex}" -eq 64 ] || die "invalid config digest"
	ghcr_curl -fL -K "${gi_dir}/bearer.conf" -o "${gi_dir}/config.json" \
		"https://ghcr.io/v2/${gi_repo}/blobs/${gi_config}" ||
		die "cannot fetch the image config"
}

# Point <repo>:<tag> at an existing manifest by uploading its exact bytes, so
# that the digest stays the same (`docker buildx imagetools create` would wrap
# it in an index). Needs GHCR_USER and GHCR_PASSWORD with write access; the
# blobs must already be in the repository.
#
# Arguments:
#   $1  repository path, e.g. <owner>/openwrt-sdk
#   $2  tag to write
#   $3  directory given to ghcr_manifest for that manifest (the same one)
ghcr_put_manifest() {
	gp_repo=$1
	gp_tag=$2
	gp_dir=$3
	[ -n "${GHCR_USER:-}" ] || die "ghcr_put_manifest needs GHCR_USER"
	[ -f "${gp_dir}/manifest.json" ] || die "no manifest to upload"
	gp_media=$(jq -er .mediaType "${gp_dir}/manifest.json") || die "the manifest has no mediaType"
	gp_put=$(mktemp -d "${gp_dir}/put.XXXXXX") || die "cannot create a work directory"
	ghcr_token "${gp_repo}" pull,push "${gp_put}"
	gp_code=$(ghcr_curl -X PUT -K "${gp_put}/bearer.conf" -H "Content-Type: ${gp_media}" \
		--data-binary "@${gp_dir}/manifest.json" -o "${gp_put}/answer.json" -w '%{http_code}' \
		"https://ghcr.io/v2/${gp_repo}/manifests/${gp_tag}") ||
		die "cannot reach the GHCR manifest endpoint"
	printf 'ghcr: PUT manifests/%s -> HTTP %s\n' "${gp_tag}" "${gp_code}" >&2
	case "${gp_code}" in
	200 | 201) ;;
	*) die "unexpected HTTP ${gp_code} writing ${gp_repo}:${gp_tag}" ;;
	esac
}

# Print the value of one label of the image last read by ghcr_inspect; empty
# when the label is absent.
#
# Arguments:
#   $1  work directory given to ghcr_inspect
#   $2  label key
ghcr_label() {
	jq -r --arg key "$2" '.config.Labels[$key] // ""' "$1/config.json" ||
		die "cannot read the labels"
}

# Print the digest of the image last read by ghcr_inspect.
#
# Arguments:
#   $1  work directory given to ghcr_inspect
ghcr_digest() {
	cat "$1/digest" || die "no digest: the image was not found"
}

# Abort unless the argument is a sha256 image digest: sha256: and 64 lowercase
# hex digits. The value is never echoed (see check_package_name in common.sh).
#
# Arguments:
#   $1  digest
check_digest() {
	case "$1" in
	sha256:*) ;;
	*) die "invalid digest (allowed: sha256:<64 hex digits>)" ;;
	esac
	cd_hex=${1#sha256:}
	case "${cd_hex}" in
	*[!0-9a-f]* | '') die "invalid digest (allowed: sha256:<64 hex digits>)" ;;
	*) ;;
	esac
	[ "${#cd_hex}" -eq 64 ] || die "invalid digest (not 64 hex digits)"
}
