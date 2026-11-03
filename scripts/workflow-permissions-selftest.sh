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
# image fails with.
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
	expect "${f}.yml: no refresh_sdk" "${f}" '[.. | select(tag == "!!str") | select(test("refresh_sdk"))] | length' 0
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
write_steps='.jobs.sdk.steps[], .jobs.ib.steps[]'
expect "refresh-images.yml: sdk and ib use no cache and no setup-uv" refresh-images \
	"[${write_steps} | select(.uses != null) | .uses | select(test(\"cache|setup-uv\"))] | length" 0
expect "refresh-images.yml: sdk and ib use only the checkout action" refresh-images \
	"[${write_steps} | select(.uses != null) | .uses | sub(\"@.*\"; \"\")] | unique | join(\" \")" actions/checkout
expect "refresh-images.yml: sdk and ib check out without credentials" refresh-images \
	"[${write_steps} | select(.uses != null) | .with.\"persist-credentials\"] | unique | join(\" \")" false
expect "refresh-images.yml: sdk and ib check out the base, not the caller" refresh-images \
	"[${write_steps} | select(.uses != null) | .with.repository] | unique | join(\" \")" '${{ env.HARNESS_CI_REPOSITORY }}'
expect "refresh-images.yml: the base repository is wehagy/openwrt-ci" refresh-images '.env.HARNESS_CI_REPOSITORY' wehagy/openwrt-ci

# --- the repository that owns the refresh ------------------------------------
want_repo='${{ inputs.refresh_repository || github.repository }}'
expect "build.yml: refresh_repository is an optional input" build '.on.workflow_call.inputs.refresh_repository.default' ""
expect "build.yml: the pin step names the repository that owns the refresh" build \
	'[.jobs.sdk.steps[] | select(.name == "Pin the SDK image") | .env.HARNESS_REFRESH_REPOSITORY] | join(" ")' "${want_repo}"
expect "images.yml: refresh_repository is an optional input" images '.on.workflow_call.inputs.refresh_repository.default' ""
expect "images.yml: the pull step names the repository that owns the refresh" images \
	'[.jobs.image.steps[] | select(.name == "Pull the ImageBuilder image") | .env.HARNESS_REFRESH_REPOSITORY] | join(" ")' "${want_repo}"
expect "images.yml: the fallback is off by default" images '.on.workflow_call.inputs.ib_fallback.default' false
expect "images.yml: the resolve step passes the fallback input" images \
	'[.jobs.image.steps[] | select(.name == "Resolve line, profile and package") | .env.HARNESS_IB_FALLBACK] | join(" ")' '${{ inputs.ib_fallback }}'
expect "ci.yml: every build and image job names wehagy/openwrt-ci-packages" ci \
	'[.jobs | to_entries[] | select(.value.uses != null) | select(.value.uses | test("workflows/(build|images)[.]yml")) | select(.value.with.refresh_repository == "wehagy/openwrt-ci-packages") | .key] | join(" ")' \
	"build-25-12 build-main image-25-12 image-main"
expect "ci.yml: no build or image job lacks refresh_repository" ci \
	'[.jobs | to_entries[] | select(.value.uses != null) | select(.value.uses | test("workflows/(build|images)[.]yml")) | select(.value.with.refresh_repository == null) | .key] | join(" ")' ""

echo
if [ "${failures}" -ne 0 ]; then
	printf 'workflow-permissions-selftest: %s of %s cases FAILED\n' "${failures}" "${checks}" >&2
	exit 1
fi
printf 'workflow-permissions-selftest: %s cases passed\n' "${checks}"
