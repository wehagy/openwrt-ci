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

# Abort unless the argument is a valid package name: [a-z0-9][a-z0-9._+-]*,
# at most 128 chars. The value is never echoed: a newline or a "::" prefix
# could otherwise forge workflow commands in the log.
#
# Arguments:
#   $1  package name
check_package_name() {
	case "$1" in
	*[!a-z0-9._+-]* | [!a-z0-9]* | '') die "invalid package name (allowed: [a-z0-9][a-z0-9._+-]*)" ;;
	*) ;;
	esac
	[ "${#1}" -le 128 ] || die "invalid package name (longer than 128 chars)"
}

# Abort unless the argument is a valid OpenWrt line: "main" or NN.NN. The
# value is never echoed (see check_package_name).
#
# Arguments:
#   $1  line
check_line() {
	case "$1" in
	main | [0-9][0-9].[0-9][0-9]) ;;
	*) die "invalid line (allowed: main or NN.NN)" ;;
	esac
}

# Abort unless the argument stays within the apk version charset. The value
# is never echoed (see check_package_name).
#
# Arguments:
#   $1  package version
check_apk_version() {
	case "$1" in
	*[!A-Za-z0-9._+~-]* | '') die "invalid package version (allowed: [A-Za-z0-9._+~-]+)" ;;
	*) ;;
	esac
}

# Abort unless the argument is a valid release or snapshot version, e.g.
# 25.12.6 or r37969-5799d2da76. The value is never echoed (see
# check_package_name).
#
# Arguments:
#   $1  release
check_release() {
	case "$1" in
	*[!A-Za-z0-9._+-]* | [!A-Za-z0-9]* | '') die "invalid release (allowed: [A-Za-z0-9][A-Za-z0-9._+-]*)" ;;
	*) ;;
	esac
	[ "${#1}" -le 64 ] || die "invalid release (longer than 64 chars)"
}

# Abort unless the argument is an HTTP date such as
# "Sun, 01 Nov 2026 06:55:28 GMT". The value is never echoed (see
# check_package_name).
#
# Arguments:
#   $1  HTTP date
check_http_date() {
	case "$1" in
	*[!A-Za-z0-9,:\ ]* | '') die "missing or invalid HTTP date (allowed: [A-Za-z0-9,: ]+)" ;;
	*) ;;
	esac
}

# Print the path of the one <package>-<version>.apk below a directory; no
# match or several matches are an error (e.g. netbird-ui must not count).
#
# Arguments:
#   $1  directory to search
#   $2  package name
find_apk() {
	find_apk_list=$(find "$1" -type f -name "$2-[0-9]*.apk") ||
		die "cannot search $1"
	[ -n "${find_apk_list}" ] || die "no $2 .apk below $1"
	find_apk_count=$(printf '%s\n' "${find_apk_list}" | wc -l)
	[ "${find_apk_count}" -eq 1 ] ||
		die "expected one $2 .apk below $1, found ${find_apk_count}: ${find_apk_list}"
	printf '%s\n' "${find_apk_list}"
}

# Print the version of a <package>-<version>.apk file, e.g. 0.78.1-r1.
#
# Arguments:
#   $1  path of the .apk
#   $2  package name
apk_version() {
	apk_base=$(basename "$1")
	apk_ver=${apk_base#"$2-"}
	apk_ver=${apk_ver%.apk}
	check_apk_version "${apk_ver}"
	printf '%s\n' "${apk_ver}"
}

# Abort unless the argument is a GHCR image repository of the form
# ghcr.io/<owner>/<name> (lowercase). The value is never echoed (see
# check_package_name).
#
# Arguments:
#   $1  repository
check_sdk_container() {
	case "$1" in
	ghcr.io/*/*/* | ghcr.io//* | ghcr.io/*/ | *[!a-z0-9./_-]* | '') die "invalid SDK container (allowed: ghcr.io/<owner>/<name>)" ;;
	ghcr.io/*/*) ;;
	*) die "invalid SDK container (allowed: ghcr.io/<owner>/<name>)" ;;
	esac
}

# Abort unless the argument is an SDK image tag: <arch>-<suffix>. The value
# is never echoed (see check_package_name).
#
# Arguments:
#   $1  tag
check_sdk_tag() {
	case "$1" in
	*[!A-Za-z0-9._-]* | [!A-Za-z0-9]* | '') die "invalid SDK image tag (allowed: [A-Za-z0-9][A-Za-z0-9._-]*)" ;;
	*) ;;
	esac
	[ "${#1}" -le 128 ] || die "invalid SDK image tag (longer than 128 chars)"
}

# Abort unless the argument is a maximum image age in whole days, 1 to 365.
# The value is never echoed (see check_package_name).
#
# Arguments:
#   $1  days
check_max_age_days() {
	case "$1" in
	*[!0-9]* | '') die "invalid SDK max age (allowed: whole days, 1-365)" ;;
	*) ;;
	esac
	{ [ "${#1}" -le 3 ] && [ "$1" -ge 1 ] && [ "$1" -le 365 ]; } ||
		die "invalid SDK max age (allowed: whole days, 1-365)"
}

# Abort unless the argument is true or false. The value is never echoed.
#
# Arguments:
#   $1  value
check_bool() {
	case "$1" in
	true | false) ;;
	*) die "invalid boolean (allowed: true or false)" ;;
	esac
}
