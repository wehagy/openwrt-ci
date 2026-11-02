#!/usr/bin/env sh
# Responsibility: print which commit of the harness (the checkout of this
# repository the workflow runs its scripts from) and which commit of the
# calling repository a job runs, so a log proves where the code came from.
#
# Usage:
#   scripts/report-revisions.sh [harness-dir [caller-dir]]
#
# Arguments:
#   harness-dir  checkout of the harness repository (default: the parent of
#                this script)
#   caller-dir   checkout of the calling repository; when omitted only the
#                run's commit (GITHUB_SHA) is printed
#
# Environment variables:
#   HARNESS_CI_REF  the ref that was requested for the harness checkout
#   GITHUB_REPOSITORY, GITHUB_SHA  the calling repository and commit
#   GITHUB_STEP_SUMMARY  optional; the lines are appended to it

set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "${script_dir}/lib/common.sh"

harness_dir=${1:-${script_dir}/..}
caller_dir=${2:-}

harness_sha=$(git -C "${harness_dir}" rev-parse HEAD) ||
	die "${harness_dir} is not a git checkout"
harness_origin=$(git -C "${harness_dir}" remote get-url origin) ||
	die "cannot read the origin of ${harness_dir}"
harness_origin=${harness_origin##*github.com/}
harness_origin=${harness_origin%.git}
report="harness: ${harness_origin} ref ${HARNESS_CI_REF:-unknown} -> ${harness_sha}"
caller="caller: ${GITHUB_REPOSITORY:-unknown} run commit ${GITHUB_SHA:-unknown}"
if [ -n "${caller_dir}" ]; then
	caller_sha=$(git -C "${caller_dir}" rev-parse HEAD) ||
		die "${caller_dir} is not a git checkout"
	caller="${caller}, checkout HEAD ${caller_sha}"
fi
printf '%s\n%s\n' "${report}" "${caller}"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
	printf -- '- %s\n- %s\n' "${report}" "${caller}" >>"${GITHUB_STEP_SUMMARY}"
fi
