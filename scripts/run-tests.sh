#!/usr/bin/env sh
# Responsibility: run the pytest session of one QEMU test job (generic test
# plus the tests of the caller), write the Markdown job summary and exit with
# the pytest status. It is the command that scripts/with-test-secrets.sh
# executes, so that the process tree of the tests (this script, uv, pytest)
# starts from an environment without the JSON of all caller secrets.
#
# Usage:
#   scripts/run-tests.sh
#
# Environment variables (set by the earlier steps of the job):
#   HARNESS_LG_ENV_FILE  labgrid environment file (scripts/prepare-target.sh)
#   HARNESS_FIRMWARE     image to boot (scripts/fetch-image.sh)
#   GITHUB_STEP_SUMMARY  file the summary is appended to
#   plus the variables of scripts/summary.sh

set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)

lg_env=${HARNESS_LG_ENV_FILE:?HARNESS_LG_ENV_FILE is required}
firmware=${HARNESS_FIRMWARE:?HARNESS_FIRMWARE is required}
summary_file=${GITHUB_STEP_SUMMARY:?GITHUB_STEP_SUMMARY is required}

mkdir -p logs
start=$(date +%s)
rc=0
uv --project openwrt-tests run --locked pytest openwrt-tests/tests/ext -vv \
	--durations=0 --rootdir=openwrt-tests --confcutdir=openwrt-tests \
	--lg-env "${lg_env}" --firmware "${firmware}" \
	--lg-log=logs --log-cli-level=CONSOLE --junitxml=results.xml \
	-o junit_family=xunit1 || rc=$?
end=$(date +%s)
"${script_dir}/summary.sh" results.xml "${rc}" "$((end - start))" \
	>>"${summary_file}"
exit "${rc}"
