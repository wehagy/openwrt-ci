#!/usr/bin/env sh
# Responsibility: prove scripts/image-refresh.sh, the only code that writes the
# SDK and Image Builder images on GHCR, with stub gh, docker and curl and a
# registry kept in a directory (lib/image-stubs.sh), so that a swapped label, a
# forced refresh that does nothing, a prune that does not delete, a skipped
# check or a push that ignores a concurrent one fails the workflow before any
# image is touched. Cases: the source label of both modes (build: the sha256 of
# the archive; mirror: the digest of the official container), a missing image,
# an up to date image that is reused, a forced rebuild, a changed upstream, the
# prune of the former -prev version, the archive name check, the recipe hash
# read from the files, the re-check before the push and a denied push. Offline.
#
# Usage:
#   scripts/image-refresh-selftest.sh   (needs jq)
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

hex_of() {
	printf '%064d' 0 | tr 0 "$1"
}
sha_a=$(hex_of a)
sha_b=$(hex_of b)
sha_c=$(hex_of c)
base_digest=sha256:$(hex_of d)
other_digest=sha256:$(hex_of e)
archive=openwrt-sdk-x86-64_gcc-14.4.0_musl.Linux-x86_64.tar.zst
url=https://downloads.openwrt.org/snapshots/targets/x86/64/sha256sums
old=2020-01-01T00:00:00Z
base_env='["PATH=/usr/bin","FILE_HOST=downloads.openwrt.org","VERSION_PATH=snapshots","TARGET=x86/64","DOWNLOAD_FILE=openwrt-sdk-x86-64_.*Linux-x86_64.tar.zst"]'
printf '%s *%s\n%s *openwrt-imagebuilder-x86-64.Linux-x86_64.tar.zst\n' \
	"${sha_a}" "${archive}" "${sha_c}" >"${work}/sums"

# The recipe hash the script must label: the Dockerfile and the two scripts it
# copies, in this order.
#
# Arguments:
#   $1  docker/sdk-image or docker/ib-image
recipe_of() {
	ro_sum=$(cat "${script_dir}/../$1/Dockerfile" "${script_dir}/ib-setup.sh" "${script_dir}/lib/common.sh" | sha256sum)
	printf '%s\n' "${ro_sum%% *}"
}
recipe_sdk=$(recipe_of docker/sdk-image)

# Labels of an SDK image as the refresh writes them.
#
# Arguments:
#   $1  created   $2 recipe sha256   $3 archive sha256
sdk_labels() {
	jq -c -n --arg c "$1" --arg r "$2" --arg s "$3" --arg u "${url}" --arg n "${archive}" \
		--arg d "${base_digest}" --arg kc "${label_created}" --arg kr "${label_recipe}" \
		--arg ks "${label_archive_sha}" --arg ku "${label_upstream}" --arg kn "${label_archive}" \
		--arg kd "${label_source_digest}" \
		'{($kc): $c, ($kr): $r, ($ks): $s, ($ku): $u, ($kn): $n, ($kd): $d}'
}

# Labels of a mirrored Image Builder image.
#
# Arguments:
#   $1  created   $2 source digest
mirror_labels() {
	jq -c -n --arg c "$1" --arg d "$2" --arg r 25.12.6 --arg kc "${label_created}" \
		--arg kd "${label_source_digest}" --arg kr "${label_release}" \
		'{($kc): $c, ($kd): $d, ($kr): $r}'
}

# Run the script for the SDK image of x86_64-main against the stubs.
#
# Arguments:
#   $@  extra environment assignments (later ones win)
run_sdk() {
	env PATH="${work}/stubs/bin:${PATH}" STUB_STATE="${state}" STUB_SUMS="${work}/sums" \
		STUB_BASE_DIGEST="${base_digest}" STUB_BASE_ENV="${base_env}" \
		STUB_ARCHIVE_LINE="${sha_a} *${archive}" \
		HARNESS_IMG_KIND=sdk HARNESS_IMG_MODE=build HARNESS_IMG_CONTAINER=ghcr.io/acme/openwrt-sdk \
		HARNESS_IMG_TAG=x86_64-main HARNESS_IMG_IMAGE=ghcr.io/acme/openwrt-sdk:x86_64-main \
		HARNESS_IMG_BASE=docker.io/openwrt/sdk:x86_64-main HARNESS_IMG_DOCKERFILE=docker/sdk-image \
		HARNESS_IMG_RELEASE= GITHUB_ACTOR=bot GITHUB_REPOSITORY=acme/pkgs GITHUB_RUN_ID=11 \
		GITHUB_RUN_ATTEMPT=1 GITHUB_TOKEN=token "$@" "${script_dir}/image-refresh.sh"
}

# Run the script for the mirrored Image Builder image of a release line.
#
# Arguments:
#   $@  extra environment assignments (later ones win)
run_mirror() {
	env PATH="${work}/stubs/bin:${PATH}" STUB_STATE="${state}" STUB_BASE_DIGEST="${base_digest}" \
		HARNESS_IMG_KIND=ib HARNESS_IMG_MODE=mirror HARNESS_IMG_CONTAINER=ghcr.io/acme/openwrt-imagebuilder \
		HARNESS_IMG_TAG=x86-64-openwrt-25.12 HARNESS_IMG_IMAGE=ghcr.io/acme/openwrt-imagebuilder:x86-64-openwrt-25.12 \
		HARNESS_IMG_BASE=docker.io/openwrt/imagebuilder:x86-64-25.12.6 HARNESS_IMG_DOCKERFILE= \
		HARNESS_IMG_RELEASE=25.12.6 GITHUB_ACTOR=bot GITHUB_REPOSITORY=acme/pkgs GITHUB_RUN_ID=11 \
		GITHUB_RUN_ATTEMPT=1 GITHUB_TOKEN=token "$@" "${script_dir}/image-refresh.sh"
}

# Record whether the call log has a text.
#
# Arguments:
#   $1  case name   $2 text   $3 "has" or "lacks"
calls() {
	if grep -qF -- "$2" "${state}/calls.log"; then c_has=has; else c_has=lacks; fi
	if [ "${c_has}" = "$3" ]; then record "$1" 0 ""; else record "$1" 1 "calls ${c_has} \"$2\""; fi
}

# Record whether stdout or stderr of the last script_case has a text.
#
# Arguments:
#   $1  case name   $2 out or err   $3 text
said() {
	if grep -qF -- "$3" "${work}/$2"; then record "$1" 0 ""; else record "$1" 1 "$2 lacks \"$3\": $(cat "${work}/$2")"; fi
}

# --- SDK image (mode build) --------------------------------------------------
stub_state_new "${state}"
script_case "sdk: a missing image is rebuilt and pushed" 0 ANY run_sdk
said "sdk missing: the decision names the reason" out 'reason="image missing"'
calls "sdk missing: the context is built from the official container" 'docker build --build-arg BASE=docker.io/openwrt/sdk:x86_64-main' has
calls "sdk missing: the label has the sha256 of the archive" "label ${label_archive_sha}=${sha_a}" has
calls "sdk missing: the label has the archive name" "label ${label_archive}=${archive}" has
calls "sdk missing: the label has the hash of the recipe files" "label ${label_recipe}=${recipe_sdk}" has
calls "sdk missing: the label has the upstream address" "label ${label_upstream}=${url}" has
calls "sdk missing: the label has the digest of the official container" "label ${label_source_digest}=${base_digest}" has
said "sdk missing: the push is reported" out "image-refresh: pushed sha256:"
if [ -f "${state}/reg/acme_openwrt-sdk/m/x86_64-main" ]; then
	record "sdk missing: the tag is on the registry" 0 ""
else
	record "sdk missing: the tag is on the registry" 1 "no manifest"
fi

stub_state_new "${state}"
stub_seed "${state}" acme/openwrt-sdk x86_64-main "$(sdk_labels "${old}" "${recipe_sdk}" "${sha_a}")" >/dev/null
script_case "sdk: an up to date image is reused" 0 ANY run_sdk
said "sdk reuse: the decision" out "decision=reuse"
calls "sdk reuse: nothing is built" 'docker build' lacks
calls "sdk reuse: nothing is pushed" 'buildx build' lacks
calls "sdk reuse: no login" 'docker login' lacks

stub_state_new "${state}"
stub_seed "${state}" acme/openwrt-sdk x86_64-main "$(sdk_labels "${old}" "${recipe_sdk}" "${sha_a}")" >/dev/null
script_case "sdk: force rebuilds an up to date image created before the run" 0 ANY run_sdk HARNESS_FORCE=true
said "sdk force: the decision" out "forced refresh requested"
calls "sdk force: it is built" 'docker build' has
calls "sdk force: it is pushed" 'buildx build' has

stub_state_new "${state}"
stub_seed "${state}" acme/openwrt-sdk x86_64-main "$(sdk_labels "${old}" "${recipe_sdk}" "${sha_b}")" >/dev/null
script_case "sdk: a changed archive rebuilds" 0 ANY run_sdk
said "sdk upstream: the decision" out "upstream changed"
calls "sdk upstream: it is pushed" 'buildx build' has

stub_state_new "${state}"
stub_seed "${state}" acme/openwrt-sdk x86_64-main "$(sdk_labels "${old}" "${other_digest}" "${sha_a}")" >/dev/null
script_case "sdk: another recipe hash rebuilds" 0 ANY run_sdk
said "sdk recipe: the decision" out "Dockerfile changed"

# The prune: the image the push supersedes becomes -prev, and the version that
# was -prev is deleted.
stub_state_new "${state}"
stub_seed "${state}" acme/openwrt-sdk x86_64-main "$(sdk_labels "${old}" "${recipe_sdk}" "${sha_b}")" >/dev/null
prev=$(stub_seed "${state}" acme/openwrt-sdk x86_64-main-prev '{"stub":"former prev"}')
printf '77\t%s\tx86_64-main-prev\t2019-01-01T00:00:00Z\n' "${prev}" >"${state}/versions.tsv"
script_case "sdk: a rebuild prunes the former -prev version" 0 ANY run_sdk
calls "sdk prune: the delete is called" 'gh api -X DELETE /users/acme/packages/container/openwrt-sdk/versions/77' has
said "sdk prune: the delete is reported" out "deleted version 77"
calls "sdk prune: the superseded image becomes -prev" 'PUT https://ghcr.io/v2/acme/openwrt-sdk/manifests/x86_64-main-prev' has
if grep -q '^77' "${state}/versions.tsv"; then
	record "sdk prune: the version is gone" 1 "still listed"
else
	record "sdk prune: the version is gone" 0 ""
fi

stub_state_new "${state}"
stub_seed "${state}" acme/openwrt-sdk x86_64-main "$(sdk_labels "${old}" "${recipe_sdk}" "${sha_b}")" >/dev/null
prev=$(stub_seed "${state}" acme/openwrt-sdk x86_64-main-prev '{"stub":"former prev"}')
printf '77\t%s\tx86_64-main-prev\t2019-01-01T00:00:00Z\n' "${prev}" >"${state}/versions.tsv"
script_case "sdk: a failed delete of the former -prev fails the job" 1 ANY run_sdk STUB_GH_DELETE_FAIL=1

# The archive the image holds must be the one that was looked up.
stub_state_new "${state}"
script_case "sdk: another archive name than the one looked up fails" 1 ANY run_sdk "STUB_ARCHIVE_LINE=${sha_a} *openwrt-sdk-other.tar.zst"
said "sdk archive name: the reason" err "the image holds openwrt-sdk-other.tar.zst"
calls "sdk archive name: nothing is pushed" 'buildx build' lacks

# Another job pushed the same image while this one built: discard the build.
stub_state_new "${state}"
run_sdk >"${work}/won.log" 2>&1 || die "the first run of the race case failed: $(cat "${work}/won.log")"
rm -rf "${work}/won"
cp -R "${state}" "${work}/won"
stub_state_new "${state}"
script_case "sdk: an identical image pushed meanwhile is not pushed again" 0 ANY run_sdk STUB_RACE_FROM="${work}/won"
said "sdk re-check: the build is discarded" out "another job pushed"
calls "sdk re-check: it did build" 'docker build' has
calls "sdk re-check: it does not push" 'buildx build' lacks

stub_state_new "${state}"
script_case "sdk: a denied push says what is missing" 1 ANY run_sdk STUB_PUSH_DENIED=1
said "sdk denied: the error annotation" out "::error::push of ghcr.io/acme/openwrt-sdk:x86_64-main denied"
said "sdk denied: the reason" err "write access to the package missing"

stub_state_new "${state}"
script_case "sdk: the checksums that cannot be downloaded fail" 1 ANY run_sdk STUB_SUMS_FAIL=1
calls "sdk sums: nothing is built" 'docker build' lacks

# --- Image Builder image of a release line (mode mirror) ----------------------
stub_state_new "${state}"
script_case "mirror: a missing image is copied and pushed" 0 ANY run_mirror
calls "mirror missing: nothing is built" 'docker build' lacks
calls "mirror missing: the image is the official container" 'dockerfile FROM docker.io/openwrt/imagebuilder:x86-64-25.12.6' has
calls "mirror missing: the label has the digest of the container" "label ${label_source_digest}=${base_digest}" has
calls "mirror missing: the label has the release" "label ${label_release}=25.12.6" has
calls "mirror missing: there is no archive label" "label ${label_archive_sha}=" lacks
said "mirror missing: the push is reported" out "source ${base_digest}"

stub_state_new "${state}"
stub_seed "${state}" acme/openwrt-imagebuilder x86-64-openwrt-25.12 "$(mirror_labels "${old}" "${base_digest}")" >/dev/null
script_case "mirror: the same container digest is reused" 0 ANY run_mirror
said "mirror reuse: the decision" out "decision=reuse"
calls "mirror reuse: nothing is pushed" 'buildx build' lacks

stub_state_new "${state}"
stub_seed "${state}" acme/openwrt-imagebuilder x86-64-openwrt-25.12 "$(mirror_labels "${old}" "${other_digest}")" >/dev/null
script_case "mirror: another container digest rebuilds" 0 ANY run_mirror
said "mirror changed: the decision" out "upstream changed"
calls "mirror changed: it is pushed" 'buildx build' has

stub_state_new "${state}"
stub_seed "${state}" acme/openwrt-imagebuilder x86-64-openwrt-25.12 "$(mirror_labels "${old}" "${base_digest}")" >/dev/null
script_case "mirror: force rebuilds an up to date image" 0 ANY run_mirror HARNESS_FORCE=true
calls "mirror force: it is pushed" 'buildx build' has

# --- Inputs ------------------------------------------------------------------
stub_state_new "${state}"
fails_case "a missing kind fails" env -u HARNESS_IMG_KIND PATH="${work}/stubs/bin:${PATH}" STUB_STATE="${state}" "${script_dir}/image-refresh.sh"
script_case "a mode that does not fit the kind fails" 1 ANY run_sdk HARNESS_IMG_MODE=mirror HARNESS_IMG_DOCKERFILE=
script_case "an invalid force fails" 1 ANY run_sdk HARNESS_FORCE=maybe

echo
if [ "${failures}" -ne 0 ]; then
	printf 'image-refresh-selftest: %s of %s cases FAILED\n' "${failures}" "${checks}" >&2
	exit 1
fi
printf 'image-refresh-selftest: %s cases passed\n' "${checks}"
