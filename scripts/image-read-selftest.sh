#!/usr/bin/env sh
# Responsibility: prove the scripts that READ the harness images on GHCR in a
# build or image job, with stub docker and curl and a registry kept in a
# directory (lib/image-stubs.sh): scripts/sdk-image-info.sh and
# scripts/pull-imagebuilder.sh. A missing image is an error annotation that
# names the repository that owns the refresh workflow (the caller, not the
# repository the job runs in) and nothing on stdout; only HTTP 404 means
# missing (any other answer, such as 403 or 500, fails with its own message and
# never reaches the fallback); an image that exists is pinned or pulled; and
# the fallback of a custom image takes the official container with a notice,
# only when the harness image is missing. Offline.
#
# Usage:
#   scripts/image-read-selftest.sh   (needs jq)
#
# Environment variables: none.

set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "${script_dir}/lib/common.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/selftest.sh
. "${script_dir}/lib/selftest.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/sdk-labels.sh
. "${script_dir}/lib/sdk-labels.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/image-stubs.sh
. "${script_dir}/lib/image-stubs.sh"

failures=0
checks=0
work=$(mktemp -d) || die "cannot create a temporary directory"
trap 'rm -rf "${work}"' EXIT

STUB_LIB=${script_dir}/lib/image-stubs.sh
export STUB_LIB
stub_install "${work}/stubs"
state=${work}/state
sha_a=$(printf '%064d' 0 | tr 0 a)
digest_pulled=sha256:$(printf '%064d' 0 | tr 0 d)
archive=openwrt-sdk-x86-64_gcc-14.4.0_musl.Linux-x86_64.tar.zst
old=2020-01-01T00:00:00Z

# Labels the readers need: the creation time and, for the SDK, the archive.
sdk_labels() {
	jq -c -n --arg c "${old}" --arg n "${archive}" --arg s "${sha_a}" \
		--arg kc "${label_created}" --arg kn "${label_archive}" --arg ks "${label_archive_sha}" \
		'{($kc): $c, ($kn): $n, ($ks): $s}'
}

# Run sdk-image-info.sh against the stubs.
#
# Arguments:
#   $@  extra environment assignments (later ones win)
run_info() {
	env PATH="${work}/stubs/bin:${PATH}" STUB_STATE="${state}" \
		HARNESS_SDK_CONTAINER=ghcr.io/acme/openwrt-sdk HARNESS_SDK_ARCH=x86_64-main \
		HARNESS_SDK_GRACE_DAYS=1 HARNESS_REFRESH_REPOSITORY=acme/pkgs-caller "$@" \
		"${script_dir}/sdk-image-info.sh"
}

# Run pull-imagebuilder.sh against the stubs.
#
# Arguments:
#   $@  extra environment assignments (later ones win)
run_pull() {
	env PATH="${work}/stubs/bin:${PATH}" STUB_STATE="${state}" STUB_BASE_DIGEST="${digest_pulled}" \
		HARNESS_IB_GRACE_DAYS=1 HARNESS_REFRESH_REPOSITORY=acme/pkgs-caller "$@" \
		"${script_dir}/pull-imagebuilder.sh" ghcr.io/acme/openwrt-imagebuilder:x86-64-main
}

# Record whether the call log has a text.
#
# Arguments:
#   $1  case name   $2 text   $3 "has" or "lacks"
calls() {
	if grep -qF -- "$2" "${state}/calls.log"; then c_has=has; else c_has=lacks; fi
	if [ "${c_has}" = "$3" ]; then record "$1" 0 ""; else record "$1" 1 "calls ${c_has} \"$2\""; fi
}

# Record whether stdout or stderr of the last script_case has (or lacks) a
# text.
#
# Arguments:
#   $1  case name   $2 out or err   $3 text   $4 "has" or "lacks"
said() {
	if grep -qF -- "$3" "${work}/$2"; then s_has=has; else s_has=lacks; fi
	if [ "${s_has}" = "$4" ]; then record "$1" 0 ""; else record "$1" 1 "$2 ${s_has} \"$3\": $(cat "${work}/$2")"; fi
}

# --- sdk-image-info.sh -------------------------------------------------------
stub_state_new "${state}"
digest=$(stub_seed "${state}" acme/openwrt-sdk x86_64-main "$(sdk_labels)")
script_case "info: an existing image is pinned by digest" 0 ANY run_info
said "info: the pin" out "HARNESS_SDK_PIN=x86_64-main@${digest}" has
said "info: the archive sha" out "HARNESS_SDK_ARCHIVE_SHA256=${sha_a}" has
said "info: no error annotation" err "::error" lacks

stub_state_new "${state}"
script_case "info: a missing image fails and prints nothing" 1 '' run_info
said "info missing: the annotation" err "::error title=Image missing::" has
said "info missing: the command names the repository that owns the refresh" err "gh workflow run refresh-images.yml --repo acme/pkgs-caller" has
said "info missing: it tells how to add the profile" err "packages/<name>/config.yml" has

stub_state_new "${state}"
script_case "info: an HTTP 500 is an error, not a missing image" 1 '' run_info STUB_MANIFEST_CODE=500
said "info 500: the status is named" err "unexpected HTTP 500" has
said "info 500: not reported as missing" err "Image missing" lacks

stub_state_new "${state}"
script_case "info: an HTTP 403 is an error, not a missing image" 1 '' run_info STUB_MANIFEST_CODE=403
said "info 403: the status is named" err "unexpected HTTP 403" has
said "info 403: not reported as missing" err "Image missing" lacks

stub_state_new "${state}"
stub_seed "${state}" acme/openwrt-sdk x86_64-main "$(sdk_labels)" >/dev/null
fails_case "info: no repository that owns the refresh fails" env -u HARNESS_REFRESH_REPOSITORY PATH="${work}/stubs/bin:${PATH}" STUB_STATE="${state}" \
	HARNESS_SDK_CONTAINER=ghcr.io/acme/openwrt-sdk HARNESS_SDK_ARCH=x86_64-main HARNESS_SDK_GRACE_DAYS=1 "${script_dir}/sdk-image-info.sh"
script_case "info: an invalid repository fails" 1 '' run_info "HARNESS_REFRESH_REPOSITORY=acme"

# --- pull-imagebuilder.sh ----------------------------------------------------
stub_state_new "${state}"
stub_seed "${state}" acme/openwrt-imagebuilder x86-64-main "$(jq -c -n --arg c "${old}" --arg k "${label_created}" '{($k): $c}')" >/dev/null
script_case "pull: an existing image is pulled" 0 ANY run_pull
said "pull: the image" out "HARNESS_IB_IMAGE=ghcr.io/acme/openwrt-imagebuilder:x86-64-main" has
said "pull: setup.sh is not needed" out "HARNESS_IB_SETUP=false" has
said "pull: the digest" out "HARNESS_IB_DIGEST=ghcr.io/acme/openwrt-imagebuilder@${digest_pulled}" has
calls "pull: it pulls the harness image" "docker pull --quiet ghcr.io/acme/openwrt-imagebuilder:x86-64-main" has

script_case "pull: an existing image wins over the fallback" 0 ANY run_pull HARNESS_IB_FALLBACK=true \
	HARNESS_IB_OFFICIAL_IMAGE=docker.io/openwrt/imagebuilder:x86-64-main HARNESS_IB_OFFICIAL_SETUP=true
said "pull fallback unused: the image" out "HARNESS_IB_IMAGE=ghcr.io/acme/openwrt-imagebuilder:x86-64-main" has
said "pull fallback unused: no notice" err "::notice" lacks

stub_state_new "${state}"
script_case "pull: a missing image fails and prints nothing" 1 '' run_pull
said "pull missing: the annotation" err "::error title=Image missing::" has
said "pull missing: the command names the repository that owns the refresh" err "gh workflow run refresh-images.yml --repo acme/pkgs-caller" has
calls "pull missing: nothing is pulled" "docker pull" lacks

script_case "pull: the fallback takes the official container" 0 ANY run_pull HARNESS_IB_FALLBACK=true \
	HARNESS_IB_OFFICIAL_IMAGE=docker.io/openwrt/imagebuilder:x86-64-main HARNESS_IB_OFFICIAL_SETUP=true
said "pull fallback: the image" out "HARNESS_IB_IMAGE=docker.io/openwrt/imagebuilder:x86-64-main" has
said "pull fallback: setup.sh is needed" out "HARNESS_IB_SETUP=true" has
said "pull fallback: the notice" err "::notice title=Image Builder downloaded at run time::" has
said "pull fallback: the notice says setup.sh runs" err "setup.sh" has
calls "pull fallback: it pulls the official container" "docker pull --quiet docker.io/openwrt/imagebuilder:x86-64-main" has
calls "pull fallback: it writes nothing to the registry" "PUT" lacks
calls "pull fallback: it does not push" "buildx" lacks

script_case "pull: the fallback of a release container needs no setup.sh" 0 ANY run_pull HARNESS_IB_FALLBACK=true \
	HARNESS_IB_OFFICIAL_IMAGE=docker.io/openwrt/imagebuilder:x86-64-25.12.6 HARNESS_IB_OFFICIAL_SETUP=false
said "pull release fallback: setup" out "HARNESS_IB_SETUP=false" has
said "pull release fallback: the notice does not promise a download" err "downloads the Image Builder with setup.sh" lacks

stub_state_new "${state}"
script_case "pull: the fallback does not hide an HTTP 500" 1 '' run_pull STUB_MANIFEST_CODE=500 HARNESS_IB_FALLBACK=true \
	HARNESS_IB_OFFICIAL_IMAGE=docker.io/openwrt/imagebuilder:x86-64-main HARNESS_IB_OFFICIAL_SETUP=true
said "pull 500: the status is named" err "unexpected HTTP 500" has
calls "pull 500: nothing is pulled" "docker pull" lacks
fails_case "pull: the fallback needs the official container" run_pull HARNESS_IB_FALLBACK=true
script_case "pull: the fallback refuses another registry" 1 '' run_pull HARNESS_IB_FALLBACK=true \
	HARNESS_IB_OFFICIAL_IMAGE=ghcr.io/evil/imagebuilder:x86-64-main HARNESS_IB_OFFICIAL_SETUP=true
script_case "pull: an invalid fallback flag fails" 1 '' run_pull HARNESS_IB_FALLBACK=maybe
fails_case "pull: no repository that owns the refresh fails" env -u HARNESS_REFRESH_REPOSITORY PATH="${work}/stubs/bin:${PATH}" STUB_STATE="${state}" \
	HARNESS_IB_GRACE_DAYS=1 "${script_dir}/pull-imagebuilder.sh" ghcr.io/acme/openwrt-imagebuilder:x86-64-main

echo
if [ "${failures}" -ne 0 ]; then
	printf 'image-read-selftest: %s of %s cases FAILED\n' "${failures}" "${checks}" >&2
	exit 1
fi
printf 'image-read-selftest: %s cases passed\n' "${checks}"
