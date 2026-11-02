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

# Fetch the manifest and the config of <repo>:<tag> into the directory. When
# the image exists, manifest.json, config.json and digest (the sha256 of the
# manifest bytes) are written there; when the registry answers 404 nothing
# but the token files is, so `[ -f <dir>/config.json ]` tells whether the image
# exists. Any other answer aborts.
#
# Arguments:
#   $1  repository path, e.g. wehagy/openwrt-sdk
#   $2  tag
#   $3  existing empty work directory
ghcr_inspect() {
	gi_repo=$1
	gi_tag=$2
	gi_dir=$3
	gi_token_url="https://ghcr.io/token?service=ghcr.io&scope=repository:${gi_repo}:pull"

	if [ -n "${GHCR_USER:-}" ]; then
		ghcr_write_curl_config "${gi_dir}/auth.conf" ''
		ghcr_curl -f -K "${gi_dir}/auth.conf" -o "${gi_dir}/token.json" "${gi_token_url}" ||
			die "cannot get an authenticated GHCR token"
	else
		ghcr_curl -f -o "${gi_dir}/token.json" "${gi_token_url}" ||
			die "cannot get an anonymous GHCR token"
	fi
	gi_token=$(jq -er .token "${gi_dir}/token.json") || die "no token in the GHCR token answer"
	ghcr_write_curl_config "${gi_dir}/bearer.conf" "${gi_token}"

	gi_accept='application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json'
	gi_code=$(ghcr_curl -K "${gi_dir}/bearer.conf" -H "Accept: ${gi_accept}" \
		-o "${gi_dir}/manifest.json" -w '%{http_code}' \
		"https://ghcr.io/v2/${gi_repo}/manifests/${gi_tag}") ||
		die "cannot reach the GHCR manifest endpoint"
	printf 'ghcr: GET manifests/%s -> HTTP %s\n' "${gi_tag}" "${gi_code}"
	case "${gi_code}" in
	200) ;;
	404) return 0 ;;
	*) die "unexpected HTTP ${gi_code} for the manifest of ${gi_repo}:${gi_tag}" ;;
	esac

	gi_sum=$(sha256sum "${gi_dir}/manifest.json") || die "cannot hash the manifest"
	printf 'sha256:%s\n' "${gi_sum%% *}" >"${gi_dir}/digest"
	gi_config=$(jq -er .config.digest "${gi_dir}/manifest.json") ||
		die "${gi_repo}:${gi_tag} is not a single-platform image manifest"
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
