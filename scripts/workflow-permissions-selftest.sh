#!/usr/bin/env sh
# Responsibility: offline guard of the permissions and wiring that keep the
# harness images read only for every run but the daily refresh. A workflow
# cannot run here, so each case reads the YAML (yq) and compares what a
# mutation would change: only the jobs `sdk` and `ib` of refresh-images.yml
# have `packages: write` (no job of build.yml, test.yml, images.yml or ci.yml
# has it, nor any workflow-level permission), refresh-images.yml is only
# called (never triggered by an event), its write jobs use no dependency cache
# and no setup-uv and check out without credentials, no workflow knows the old
# `refresh_sdk` input, and the base's own CI names the repository that owns the
# refresh (wehagy/openwrt-ci-packages), not itself, in the command a missing
# image fails with. It also pins the fallback of a custom image (no workflow
# but images.yml has ib_fallback, the build container gets HARNESS_IB_SETUP,
# the reader never logs in or pushes) and that the self-tests of the images
# run in the feed job of build.yml, so a push or a pull request meets them
# before a merge.
#
# Usage:
#   scripts/workflow-permissions-selftest.sh   (needs yq)
#
# Environment variables: none.

set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
workflows="${script_dir}/../.github/workflows"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "${script_dir}/lib/common.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/selftest.sh
. "${script_dir}/lib/selftest.sh"

failures=0
checks=0

# The value of a yq expression on a workflow, as text.
#
# Arguments:
#   $1  workflow file name (without .yml)
#   $2  yq expression
wf() {
	yq -r "$2" "${workflows}/$1.yml" || die "yq failed on $1.yml: $2"
}

# Compare the value of a yq expression on a workflow with the expected one and
# record the case.
#
# Arguments:
#   $1  case name   $2 workflow (without .yml)   $3 yq expression   $4 expected
expect() {
	ex_got=$(wf "$2" "$3")
	if [ "${ex_got}" = "$4" ]; then
		record "$1" 0 ""
	else
		record "$1" 1 "got [${ex_got}], expected [$4]"
	fi
}

all_perms='[.permissions, (.jobs[] | .permissions)]'
for f in build test images ci refresh-images; do
	expect "${f}.yml: the workflow default is contents: read" "${f}" '.permissions.contents' read
	expect "${f}.yml: the workflow default has no packages permission" "${f}" '.permissions.packages // "none"' none
	expect "${f}.yml: every permissions block is a map (no write-all)" "${f}" \
		"${all_perms} | map(select(. != null) | select(tag != \"!!map\")) | length" 0
	expect "${f}.yml: no GITHUB_REPOSITORY set by hand" "${f}" \
		'[.. | select(tag == "!!map") | select(has("GITHUB_REPOSITORY"))] | length' 0
	expect "${f}.yml: no refresh_sdk input" "${f}" '[.. | select(tag == "!!map") | keys | .[] | select(. == "refresh_sdk")] | length' 0
	expect "${f}.yml: no refresh_sdk value" "${f}" '[.. | select(tag == "!!str") | select(test("refresh_sdk"))] | length' 0
done

# --- who may write packages --------------------------------------------------
for f in build test images ci; do
	expect "${f}.yml: no job has packages: write" "${f}" \
		'[.jobs | to_entries[] | select(.value.permissions.packages == "write") | .key] | join(" ")' ""
	expect "${f}.yml: no job has any packages permission" "${f}" \
		'[.jobs | to_entries[] | select(.value.permissions.packages != null) | .key] | join(" ")' ""
done
expect "refresh-images.yml: only sdk and ib have packages: write" refresh-images \
	'[.jobs | to_entries[] | select(.value.permissions.packages == "write") | .key] | join(" ")' "sdk ib"
expect "refresh-images.yml: the jobs are plan, sdk and ib" refresh-images '.jobs | keys | join(" ")' "plan sdk ib"
expect "refresh-images.yml: plan runs with the workflow default" refresh-images '.jobs.plan.permissions // "workflow default"' "workflow default"
expect "refresh-images.yml: sdk reads the repository" refresh-images '.jobs.sdk.permissions.contents' read
expect "refresh-images.yml: ib reads the repository" refresh-images '.jobs.ib.permissions.contents' read
expect "refresh-images.yml: it is only called, never triggered" refresh-images '.on | keys | join(" ")' workflow_call

# --- the jobs that write run harness code only -------------------------------
# The text of the jobs sdk and ib (everything from the sdk job on), without
# comments: grep and sed read it, not yq, so that a step added to either job in
# any form is seen.
write_jobs=$(awk '/^  sdk:$/ { p = 1 } p && $0 !~ /^[[:space:]]*#/' "${workflows}/refresh-images.yml") ||
	die "cannot read refresh-images.yml"

# Print how many lines of a text match an ERE.
#
# Arguments:
#   $1  text   $2 ERE
count_lines() {
	cl_n=$(printf '%s\n' "$1" | grep -cE -- "$2") || [ "$?" -eq 1 ] || die "grep failed"
	printf '%s\n' "${cl_n}"
}

# Compare a value with the expected one and record the case.
#
# Arguments:
#   $1  case name   $2 value read   $3 expected
same() {
	if [ "$2" = "$3" ]; then record "$1" 0 ""; else record "$1" 1 "got [$2], expected [$3]"; fi
}

same "refresh-images.yml: sdk and ib use no cache and no setup-uv" "$(count_lines "${write_jobs}" 'actions/cache|setup-uv')" 0
same "refresh-images.yml: sdk and ib use only the checkout action" \
	"$(printf '%s\n' "${write_jobs}" | sed -n -e 's/^[ -]*uses: *//p' | sed -e 's/@.*//' | sort -u)" actions/checkout
same "refresh-images.yml: sdk and ib check out without credentials" "$(count_lines "${write_jobs}" 'persist-credentials: false')" 2
same "refresh-images.yml: sdk and ib never keep credentials" "$(count_lines "${write_jobs}" 'persist-credentials: (true|"true")')" 0
same "refresh-images.yml: sdk and ib check out the base, not the caller" \
	"$(printf '%s\n' "${write_jobs}" | sed -n -e 's/^ *repository: *//p' | sort -u)" "\${{ env.HARNESS_CI_REPOSITORY }}"
expect "refresh-images.yml: the base repository is wehagy/openwrt-ci" refresh-images '.env.HARNESS_CI_REPOSITORY' wehagy/openwrt-ci

# --- the repository that owns the refresh ------------------------------------
want_repo="\${{ inputs.refresh_repository || github.repository }}"
expect "build.yml: refresh_repository is an optional input" build '.on.workflow_call.inputs.refresh_repository.default' ""
expect "build.yml: the pin step names the repository that owns the refresh" build \
	'[.jobs.sdk.steps[] | select(.name == "Pin the SDK image") | .env.HARNESS_REFRESH_REPOSITORY] | join(" ")' "${want_repo}"
expect "images.yml: refresh_repository is an optional input" images '.on.workflow_call.inputs.refresh_repository.default' ""
expect "images.yml: the pull step names the repository that owns the refresh" images \
	'[.jobs.image.steps[] | select(.name == "Pull the ImageBuilder image") | .env.HARNESS_REFRESH_REPOSITORY] | join(" ")' "${want_repo}"
expect "images.yml: the fallback is off by default" images '.on.workflow_call.inputs.ib_fallback.default' false
expect "images.yml: the resolve step passes the fallback input" images \
	'[.jobs.image.steps[] | select(.name == "Resolve line, profile and package") | .env.HARNESS_IB_FALLBACK] | join(" ")' "\${{ inputs.ib_fallback }}"
expect "ci.yml: every build and image job names wehagy/openwrt-ci-packages" ci \
	'[.jobs | to_entries[] | select(.value.uses != null) | select(.value.uses | test("workflows/(build|images)[.]yml")) | select(.value.with.refresh_repository == "wehagy/openwrt-ci-packages") | .key] | join(" ")' \
	"build-25-12 build-main image-25-12 image-main"
expect "ci.yml: no build or image job lacks refresh_repository" ci \
	'[.jobs | to_entries[] | select(.value.uses != null) | select(.value.uses | test("workflows/(build|images)[.]yml")) | select(.value.with.refresh_repository == null) | .key] | join(" ")' ""

# --- the fallback of a custom image ------------------------------------------
# Only images.yml knows ib_fallback, and only a caller that builds a custom
# image turns it on (the base's own CI never does: it would hide an image that
# is missing from the registry).
for f in build test ci refresh-images; do
	expect "${f}.yml: no ib_fallback key" "${f}" '[.. | select(tag == "!!map") | keys | .[] | select(. == "ib_fallback")] | length' 0
	expect "${f}.yml: no ib_fallback value" "${f}" '[.. | select(tag == "!!str") | select(test("ib_fallback"))] | length' 0
done

# The container that builds the image must get every variable the script
# reads. Without HARNESS_IB_SETUP the fallback of a snapshot profile dies with
# "no ImageBuilder in the image".
build_run=$(wf images '[.jobs.image.steps[] | select(.name == "Build the image") | .run] | join(" ")')
for v in HARNESS_PROFILE HARNESS_PACKAGES HARNESS_PACKAGE HARNESS_TARGET_PATH HARNESS_IB_SETUP; do
	same "images.yml: the build container gets ${v}" "$(count_lines "${build_run}" "(^|[[:space:]])--env ${v}([[:space:]]|\$)")" 1
done
expect "images.yml: the build step runs imagebuilder-make.sh" images \
	'[.jobs.image.steps[] | select(.name == "Build the image") | .run] | join(" ") | test("sh /harness/scripts/imagebuilder-make[.]sh")' true

# The fallback only reads: nothing in the reader or in the job that runs it
# logs in to a registry, pushes, builds an image or calls the API.
read_text=$(grep -vE '^[[:space:]]*#' "${script_dir}/pull-imagebuilder.sh" "${workflows}/images.yml") ||
	die "cannot read pull-imagebuilder.sh and images.yml"
same "images.yml and pull-imagebuilder.sh never log in, push or build" \
	"$(count_lines "${read_text}" 'docker (login|push|buildx|build|tag)|--push|gh api|-X (PUT|DELETE|POST)')" 0

# --- the self-tests that run on every push -----------------------------------
# The feed job of build.yml runs on every push and pull request of a caller
# and on the base's own CI: the self-tests of what writes or reads the images
# are steps of it.
for t in image-refresh image-read workflow-permissions imagebuilder-make; do
	expect "build.yml: the feed job runs ${t}-selftest.sh" build \
		"[.jobs.feed.steps[] | select(.run == \"ci-base/scripts/${t}-selftest.sh\")] | length" 1
done
# Every self-test of scripts/ is a step of some workflow.
for st in "${script_dir}"/*-selftest.sh; do
	st_name=$(basename "${st}")
	st_steps=0
	for f in build test images ci refresh-images; do
		st_n=$(wf "${f}" "[(.jobs[].steps // [])[] | select(.run == \"ci-base/scripts/${st_name}\")] | length")
		st_steps=$((st_steps + st_n))
	done
	if [ "${st_steps}" -ge 1 ]; then
		record "${st_name} is run by a workflow" 0 ""
	else
		record "${st_name} is run by a workflow" 1 "no workflow step runs it"
	fi
done

echo
if [ "${failures}" -ne 0 ]; then
	printf 'workflow-permissions-selftest: %s of %s cases FAILED\n' "${failures}" "${checks}" >&2
	exit 1
fi
printf 'workflow-permissions-selftest: %s cases passed\n' "${checks}"
