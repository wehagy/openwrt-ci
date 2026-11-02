#!/usr/bin/env sh
# Responsibility: prove the age rule of scripts/lib/sdk-age.sh with fixed
# timestamps, so that a wrong comparison fails the workflow before any image
# is reused or rebuilt. Runs in every SDK image job.
#
# Usage:
#   scripts/sdk-age-selftest.sh
#
# Environment variables: none.

set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "${script_dir}/lib/common.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/sdk-age.sh
. "${script_dir}/lib/sdk-age.sh"

# Expect sdk_freshness to print fresh or stale.
#
# Arguments:
#   $1  expected: fresh or stale
#   $2  creation time, Unix seconds
#   $3  current time, Unix seconds
#   $4  maximum age, days
#   $5  case name
expect() {
	got=$(sdk_freshness "$2" "$3" "$4")
	[ "${got}" = "$1" ] || die "age rule: ${5}: expected $1, got ${got}"
	printf 'age rule ok: %-34s -> %s\n' "$5" "${got}"
}

day=86400
base=1000000
expect fresh "${base}" "${base}" 1 "age 0 s, max 1 day"
expect fresh "${base}" $((base + day - 1)) 1 "age 1 day - 1 s, max 1 day"
expect fresh "${base}" $((base + day)) 1 "age exactly 1 day, max 1 day"
expect stale "${base}" $((base + day + 1)) 1 "age 1 day + 1 s, max 1 day"
expect stale "${base}" $((base + 30 * day)) 1 "age 30 days, max 1 day"
expect fresh "${base}" $((base + 2 * day)) 3 "age 2 days, max 3 days"
expect stale "${base}" $((base + 3 * day + 1)) 3 "age 3 days + 1 s, max 3 days"
expect stale $((base + 1)) "${base}" 1 "created in the future"

parsed=$(utc_to_epoch 1970-01-02T00:00:00Z)
[ "${parsed}" -eq "${day}" ] || die "utc_to_epoch: 1970-01-02T00:00:00Z is not ${day}"
printf 'timestamp parse ok: 1970-01-02T00:00:00Z -> %s\n' "${parsed}"

# A malformed timestamp must abort; a child shell keeps die's exit local.
if bad=$(sh -c '. "$1/lib/common.sh" && . "$1/lib/sdk-age.sh" && utc_to_epoch "$2"' \
	sh "${script_dir}" "2026-11-01 00:00:00" 2>&1); then
	die "utc_to_epoch accepted a malformed timestamp"
fi
printf 'timestamp reject ok: %s\n' "${bad}"
printf 'age self-test: OK\n'
