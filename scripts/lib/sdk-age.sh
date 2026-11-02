#!/usr/bin/env sh
# Responsibility: the age rule and the reuse/rebuild decision for the harness
# SDK image (sourced, not run). Pure functions, no network.
#
# Usage:
#   . "${script_dir}/lib/common.sh"
#   . "${script_dir}/lib/sdk-age.sh"
#
# Environment variables: none.

# Print the Unix time of a UTC timestamp written as YYYY-MM-DDTHH:MM:SSZ;
# fail without a message when it is malformed. The value is never echoed (see
# check_package_name in common.sh).
#
# Arguments:
#   $1  timestamp
sdk_parse_utc() {
	case "$1" in
	[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
	*) return 1 ;;
	esac
	date -u -d "$1" +%s
}

# Like sdk_parse_utc, but aborts the calling script on a malformed timestamp.
#
# Arguments:
#   $1  timestamp
utc_to_epoch() {
	sdk_parse_utc "$1" || die "invalid timestamp (allowed: YYYY-MM-DDTHH:MM:SSZ)"
}

# Print "fresh" when an image created at $1 is still fresh at $2: its age is
# not negative (a clock in the future is not trusted) and not longer than $3
# days; print "stale" otherwise.
#
# Arguments:
#   $1  creation time, Unix seconds
#   $2  current time, Unix seconds
#   $3  maximum age, days
sdk_freshness() {
	sdk_age=$(($2 - $1))
	sdk_max=$(($3 * 86400))
	if [ "${sdk_age}" -ge 0 ] && [ "${sdk_age}" -le "${sdk_max}" ]; then
		printf 'fresh\n'
	else
		printf 'stale\n'
	fi
}

# Print "<decision> <reason>" for the SDK image of one tag: decision is "reuse"
# or "rebuild". The single place where the choice is made, used by
# scripts/sdk-image-ensure.sh and proved by scripts/sdk-age-selftest.sh.
# Rebuild when the image is missing, its creation time is unreadable (the
# rebuild heals it), it was created before a requested refresh, or it is stale
# (see sdk_freshness). Otherwise reuse.
#
# Arguments:
#   $1  image exists: true or false
#   $2  creation time label, YYYY-MM-DDTHH:MM:SSZ (ignored when missing)
#   $3  current time, Unix seconds
#   $4  maximum age, days
#   $5  refresh point, Unix seconds: an image created before it is rebuilt;
#       empty when no refresh was requested
sdk_decide() {
	if [ "$1" != true ]; then
		printf 'rebuild image missing\n'
		return 0
	fi
	if ! sd_created=$(sdk_parse_utc "$2"); then
		printf 'rebuild creation time unreadable\n'
		return 0
	fi
	sd_age=$(($3 - sd_created))
	if [ -n "$5" ] && [ "${sd_created}" -lt "$5" ]; then
		printf 'rebuild refresh_sdk requested (age %s s)\n' "${sd_age}"
	elif sd_fresh=$(sdk_freshness "${sd_created}" "$3" "$4") && [ "${sd_fresh}" = fresh ]; then
		if [ -n "$5" ]; then
			printf 'reuse refreshed since the request (age %s s <= %s day(s))\n' "${sd_age}" "$4"
		else
			printf 'reuse age %s s <= %s day(s)\n' "${sd_age}" "$4"
		fi
	elif [ "${sd_age}" -lt 0 ]; then
		printf 'rebuild created in the future (age %s s)\n' "${sd_age}"
	else
		printf 'rebuild age %s s > %s day(s)\n' "${sd_age}" "$4"
	fi
}
