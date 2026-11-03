#!/usr/bin/env sh
# Responsibility: prove the age rule and the reuse/rebuild decision of
# scripts/lib/sdk-age.sh with fixed timestamps, so that a wrong comparison or
# a swapped branch fails the workflow before any image is reused or rebuilt.
# Runs in every SDK image job.
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

# Expect sdk_decide to print the decision and a reason containing a text.
#
# Arguments:
#   $1  expected decision: reuse or rebuild
#   $2  text the reason must contain
#   $3  image exists: true or false
#   $4  creation time label, or age:<seconds> for a label that old
#   $5  current time, Unix seconds
#   $6  maximum age, days
#   $7  refresh point, Unix seconds, or empty
#   $8  case name
expect_decide() {
	case "$4" in
	age:*) label=$(label_at "${4#age:}") ;;
	*) label=$4 ;;
	esac
	out=$(sdk_decide "$3" "${label}" "$5" "$6" "$7" "${recipe_want}" "${recipe_have}")
	got=${out%% *}
	reason=${out#* }
	[ "${got}" = "$1" ] || die "decision: ${8}: expected $1, got ${got} (${reason})"
	case "${reason}" in
	*"$2"*) ;;
	*) die "decision: ${8}: reason \"${reason}\" lacks \"$2\"" ;;
	esac
	printf 'decision ok: %-34s -> %s (%s)\n' "$8" "${got}" "${reason}"
}

# The creation time label of an image that is $1 seconds old at ${now}.
#
# Arguments:
#   $1  age, seconds (negative: created in the future)
label_at() {
	date -u -d "@$((now - $1))" +%Y-%m-%dT%H:%M:%SZ || die "cannot format a timestamp"
}

now=1800000000
# sha256 of the Dockerfile now and as the image label recorded it; the cases
# below that do not test the recipe leave them equal.
recipe_want=1111111111111111111111111111111111111111111111111111111111111111
recipe_have=${recipe_want}
expect_decide rebuild "image missing" false "" "${now}" 1 "" "missing"
expect_decide rebuild "image missing" false age:10 "${now}" 1 "${now}" "missing, refresh requested"
expect_decide reuse "age 10 s <= 1 day(s)" true age:10 "${now}" 1 "" "fresh"
expect_decide reuse "age 86400 s <= 1 day(s)" true "age:${day}" "${now}" 1 "" "fresh, exactly 1 day"
expect_decide rebuild "age 86401 s > 1 day(s)" true "age:$((day + 1))" "${now}" 1 "" "stale, 1 day + 1 s"
expect_decide rebuild "age 2592000 s > 1 day(s)" true "age:$((30 * day))" "${now}" 1 "" "stale, 30 days"
expect_decide reuse "age 172800 s <= 3 day(s)" true "age:$((2 * day))" "${now}" 3 "" "fresh, 2 days of 3"
expect_decide rebuild "created in the future (age -1 s)" true age:-1 "${now}" 1 "" "created in the future"
expect_decide rebuild "creation time unreadable" true "" "${now}" 1 "" "creation time empty"
expect_decide rebuild "creation time unreadable" true "garbage" "${now}" 1 "" "creation time garbage"
expect_decide rebuild "creation time unreadable" true "2026-11-01 00:00:00" "${now}" 1 "" "creation time without T and Z"
expect_decide rebuild "refresh_sdk requested (age 10 s)" true age:10 "${now}" 1 "$((now - 5))" "fresh, created before the refresh"
expect_decide reuse "refreshed since the request (age 10 s" true age:10 "${now}" 1 "$((now - 20))" "fresh, created after the refresh"
expect_decide rebuild "age 86401 s > 1 day(s)" true "age:$((day + 1))" "${now}" 1 "$((now - 2 * day))" "stale, created after the refresh"

# The Dockerfile changed (the image content changed): rebuild whatever the age.
recipe_have=2222222222222222222222222222222222222222222222222222222222222222
expect_decide rebuild "Dockerfile changed" true age:10 "${now}" 1 "" "fresh, other Dockerfile"
expect_decide rebuild "Dockerfile changed" true age:10 "${now}" 1 "$((now - 20))" "refreshed, other Dockerfile"
recipe_have=
expect_decide rebuild "Dockerfile changed" true age:10 "${now}" 1 "" "fresh, image without the label"
recipe_have=${recipe_want}
expect_decide reuse "age 10 s <= 1 day(s)" true age:10 "${now}" 1 "" "fresh, same Dockerfile"
expect_decide rebuild "image missing" false "" "${now}" 1 "" "missing, Dockerfile label ignored"

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
