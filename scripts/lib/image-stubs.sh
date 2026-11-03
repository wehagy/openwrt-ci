#!/usr/bin/env sh
# Responsibility: stub gh, docker and curl for the self-tests of the scripts
# that read or write the harness images on GHCR (sourced, not run). The stubs
# keep a registry in a directory (manifests per repository and reference,
# config blobs), answer the calls of lib/ghcr.sh, scripts/image-refresh.sh and
# scripts/pull-imagebuilder.sh, and log every call to calls.log, so that a
# case can tell what was pushed, deleted or pulled. They answer only the calls
# those scripts make; any other one fails with exit 98 or 99.
#
# Usage:
#   . "${script_dir}/lib/image-stubs.sh"
#   stub_install "${work}/stubs"        # then PATH="${work}/stubs/bin:${PATH}"
#   stub_state_new "${work}/state"      # a fresh registry; STUB_STATE="${work}/state"
#   export STUB_LIB="${script_dir}/lib/image-stubs.sh"
#
# Environment variables of the stubs (set by the case):
#   STUB_STATE          registry directory (required)
#   STUB_LIB            this file (required by the docker stub)
#   STUB_SUMS           file served for any URL that is not GHCR
#   STUB_SUMS_FAIL      non-empty: that download fails
#   STUB_MANIFEST_CODE  HTTP status answered to every manifest GET
#   STUB_PUT_CODE       HTTP status answered to a manifest PUT (default: 201)
#   STUB_BASE_DIGEST    digest of any pulled image (docker image inspect)
#   STUB_BASE_ENV       JSON environment of the pulled image
#   STUB_ARCHIVE_LINE   what the built image prints for /builder/.archive
#   STUB_PULL_FAIL      non-empty: docker pull fails
#   STUB_PUSH_DENIED    non-empty: docker buildx build --push is denied
#   STUB_RACE_FROM      registry directory copied into this one at docker build
#   STUB_GH_DELETE_FAIL non-empty: the delete of a package version fails

# Print the digest of an image written into the registry: its config (with the
# labels) and its manifest, under the tag and under its own digest.
#
# Arguments:
#   $1  registry directory
#   $2  repository path, e.g. <owner>/openwrt-sdk
#   $3  tag
#   $4  labels, a JSON object
stub_seed() {
	ss_dir=$1/reg/$(printf '%s' "$2" | tr / _)/m
	mkdir -p "${ss_dir}" "$1/blobs"
	ss_cfg=$(jq -c -n --argjson l "$4" '{config: {Labels: $l}}')
	ss_hex=$(printf '%s' "${ss_cfg}" | sha256sum)
	ss_hex=${ss_hex%% *}
	printf '%s' "${ss_cfg}" >"$1/blobs/${ss_hex}"
	ss_man=$(jq -c -n --arg d "sha256:${ss_hex}" \
		'{mediaType: "application/vnd.oci.image.manifest.v1+json", config: {mediaType: "application/vnd.oci.image.config.v1+json", digest: $d}, layers: []}')
	printf '%s' "${ss_man}" >"${ss_dir}/$3"
	ss_sum=$(printf '%s' "${ss_man}" | sha256sum)
	ss_sum=sha256:${ss_sum%% *}
	cp "${ss_dir}/$3" "${ss_dir}/${ss_sum}"
	printf '%s\n' "${ss_sum}"
}

# Make an empty registry directory with an empty call log and no package
# versions.
#
# Arguments:
#   $1  registry directory
stub_state_new() {
	rm -rf "$1"
	mkdir -p "$1/reg" "$1/blobs"
	: >"$1/calls.log"
	: >"$1/versions.tsv"
}

# Write the stubs curl, docker and gh into <dir>/bin.
#
# Arguments:
#   $1  directory
stub_install() {
	mkdir -p "$1/bin"
	cat >"$1/bin/curl" <<'STUB'
#!/usr/bin/env sh
set -eu
out=
wfmt=
method=GET
data=
url=
while [ "$#" -gt 0 ]; do
	case "$1" in
	-o) out=$2; shift ;;
	-w) wfmt=$2; shift ;;
	-X) method=$2; shift ;;
	--data-binary) data=${2#@}; shift ;;
	-K | -H | --retry | --connect-timeout | --max-time) shift ;;
	-*) ;;
	*) url=$1 ;;
	esac
	shift
done
state=${STUB_STATE:?}
printf 'curl %s %s\n' "${method}" "${url}" >>"${state}/calls.log"
case "${url}" in
https://ghcr.io/token*)
	printf '{"token":"stub"}' >"${out}"
	;;
https://ghcr.io/v2/*/manifests/*)
	rest=${url#https://ghcr.io/v2/}
	repo=${rest%%/manifests/*}
	ref=${rest#*/manifests/}
	dir=${state}/reg/$(printf '%s' "${repo}" | tr / _)/m
	if [ "${method}" = PUT ]; then
		mkdir -p "${dir}"
		cp "${data}" "${dir}/${ref}"
		printf '{}' >"${out}"
		code=${STUB_PUT_CODE:-201}
	elif [ -n "${STUB_MANIFEST_CODE:-}" ]; then
		: >"${out}"
		code=${STUB_MANIFEST_CODE}
	elif [ -f "${dir}/${ref}" ]; then
		cp "${dir}/${ref}" "${out}"
		code=200
	else
		: >"${out}"
		code=404
	fi
	if [ -n "${wfmt}" ]; then
		printf '%s' "${code}"
	fi
	;;
https://ghcr.io/v2/*/blobs/sha256:*)
	hex=${url##*sha256:}
	if [ ! -f "${state}/blobs/${hex}" ]; then
		echo "curl: (22) The requested URL returned error: 404" >&2
		exit 22
	fi
	cp "${state}/blobs/${hex}" "${out}"
	;;
*)
	if [ -n "${STUB_SUMS_FAIL:-}" ]; then
		echo "curl: (22) The requested URL returned error: 503" >&2
		exit 22
	fi
	cp "${STUB_SUMS:?}" "${out}"
	;;
esac
STUB
	cat >"$1/bin/docker" <<'STUB'
#!/usr/bin/env sh
set -eu
state=${STUB_STATE:?}
# shellcheck disable=SC1090
. "${STUB_LIB:?}"
printf 'docker %s\n' "$*" >>"${state}/calls.log"
cmd=${1:-}
if [ "$#" -gt 0 ]; then
	shift
fi
case "${cmd}" in
pull)
	if [ -n "${STUB_PULL_FAIL:-}" ]; then
		echo "Error response from daemon: pull access denied" >&2
		exit 1
	fi
	;;
login)
	cat >/dev/null
	;;
image)
	# image inspect --format <format> <image>
	case "$3" in
	'{{index .RepoDigests 0}}') printf '%s@%s\n' "${4%%:*}" "${STUB_BASE_DIGEST:?}" ;;
	'{{json .Config.Env}}') printf '%s\n' "${STUB_BASE_ENV:?}" ;;
	'{{.Size}}') printf '12345\n' ;;
	*)
		echo "stub docker: unexpected format $3" >&2
		exit 98
		;;
	esac
	;;
build)
	ctx=
	for a in "$@"; do
		ctx=$a
	done
	for f in Dockerfile ib-setup.sh lib/common.sh; do
		if [ ! -f "${ctx}/${f}" ]; then
			echo "stub docker: ${f} is missing in the build context" >&2
			exit 98
		fi
	done
	if [ -n "${STUB_RACE_FROM:-}" ]; then
		mkdir -p "${state}/reg" "${state}/blobs"
		cp -R "${STUB_RACE_FROM}/reg/." "${state}/reg/"
		cp -R "${STUB_RACE_FROM}/blobs/." "${state}/blobs/"
	fi
	;;
run)
	printf '%s\n' "${STUB_ARCHIVE_LINE:?}"
	;;
buildx)
	shift
	tag=
	meta=
	: >"${state}/labels.tmp"
	while [ "$#" -gt 0 ]; do
		case "$1" in
		-t) tag=$2; shift ;;
		--metadata-file) meta=$2; shift ;;
		--label)
			printf '%s\n' "$2" >>"${state}/labels.tmp"
			printf 'label %s\n' "$2" >>"${state}/calls.log"
			shift
			;;
		*) ;;
		esac
		shift
	done
	printf 'dockerfile %s\n' "$(cat)" >>"${state}/calls.log"
	if [ -n "${STUB_PUSH_DENIED:-}" ]; then
		echo "denied: permission_denied: write_package" >&2
		exit 1
	fi
	labels=$(jq -R -s -c 'split("\n") | map(select(length > 0) | capture("^(?<k>[^=]+)=(?<v>.*)$") | {(.k): .v}) | add' "${state}/labels.tmp")
	repo=${tag#ghcr.io/}
	repo=${repo%:*}
	digest=$(stub_seed "${state}" "${repo}" "${tag##*:}" "${labels}")
	printf '{"containerimage.digest":"%s"}\n' "${digest}" >"${meta}"
	;;
*)
	echo "stub docker: unexpected command ${cmd}" >&2
	exit 99
	;;
esac
STUB
	cat >"$1/bin/gh" <<'STUB'
#!/usr/bin/env sh
set -eu
state=${STUB_STATE:?}
versions=${state}/versions.tsv
printf 'gh %s\n' "$*" >>"${state}/calls.log"
case "$*" in
*"-X DELETE"*)
	if [ -n "${STUB_GH_DELETE_FAIL:-}" ]; then
		echo "gh: Forbidden (HTTP 403)" >&2
		exit 1
	fi
	id=${*##*/versions/}
	awk -F '\t' -v id="${id}" '$1 != id' "${versions}" >"${versions}.new"
	mv "${versions}.new" "${versions}"
	;;
*"select(.name =="*)
	name=${*#*\"}
	name=${name%%\"*}
	awk -F '\t' -v n="${name}" '$2 == n { print $1 }' "${versions}"
	;;
*"select(.id =="*)
	id=${*#*== }
	id=${id%%)*}
	awk -F '\t' -v n="${id}" '$1 == n { print $1 }' "${versions}"
	;;
*"--jq .type"*)
	echo User
	;;
*"/versions"*)
	cat "${versions}"
	;;
*)
	echo "stub gh: unexpected call $*" >&2
	exit 99
	;;
esac
STUB
	chmod +x "$1/bin/curl" "$1/bin/docker" "$1/bin/gh"
}
