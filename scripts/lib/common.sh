#!/usr/bin/env sh
# Responsibility: helpers shared by the harness scripts (sourced, not run).
#
# Usage:
#   . "${script_dir}/lib/common.sh"
#
# Environment variables: none.

# Print an error and abort the calling script.
#
# Arguments:
#   $*  message
die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

# Print the value of a yq expression; a missing key is an error.
#
# Arguments:
#   $1  YAML file
#   $2  yq expression (keys come from exported variables via strenv())
yq_get() {
	yq_value=$(yq "$2" "$1") || die "yq failed on $1: $2"
	[ "${yq_value}" != null ] || die "missing key in $1: $2"
	printf '%s\n' "${yq_value}"
}
