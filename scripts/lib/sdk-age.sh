#!/usr/bin/env sh
# Responsibility: the age rule that decides whether the harness SDK image is
# reused or rebuilt (sourced, not run). Pure functions, no network.
#
# Usage:
#   . "${script_dir}/lib/common.sh"
#   . "${script_dir}/lib/sdk-age.sh"
#
# Environment variables: none.

# Print the Unix time of a UTC timestamp written as YYYY-MM-DDTHH:MM:SSZ. The
# value is never echoed (see check_package_name in common.sh).
#
# Arguments:
#   $1  timestamp
utc_to_epoch() {
	case "$1" in
	[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
	*) die "invalid timestamp (allowed: YYYY-MM-DDTHH:MM:SSZ)" ;;
	esac
	date -u -d "$1" +%s || die "cannot parse the timestamp"
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
