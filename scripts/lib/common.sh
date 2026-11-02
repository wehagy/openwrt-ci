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

# Print the value of a yq expression, or a default when the key is missing.
#
# Arguments:
#   $1  YAML file
#   $2  yq expression (keys come from exported variables via strenv())
#   $3  default
yq_get_or() {
	yq_value=$(yq "$2" "$1") || die "yq failed on $1: $2"
	if [ "${yq_value}" = null ]; then
		yq_value=$3
	fi
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

# Print the latest non-rc release listed in an HTML releases index: the
# highest version (sort -V) among the directory names matching the regex, so
# -rcN never matches.
#
# Arguments:
#   $1  URL of the releases index
#   $2  ERE of the release directory names (e.g. 25\.12\.[0-9]+)
latest_release() {
	lr_dir=$(mktemp -d) || die "cannot create a temporary directory"
	curl -fsSL --retry 3 --connect-timeout 20 --max-time 60 -o "${lr_dir}/index.html" "$1" ||
		{
			rm -rf "${lr_dir}"
			die "cannot fetch $1"
		}
	grep -oE "href=\"$2/\"" "${lr_dir}/index.html" >"${lr_dir}/hrefs" ||
		{
			rm -rf "${lr_dir}"
			die "no release $2 at $1"
		}
	sed -e 's/^href="//' -e 's|/"$||' "${lr_dir}/hrefs" >"${lr_dir}/versions"
	sort -V -o "${lr_dir}/sorted" "${lr_dir}/versions"
	lr_release=$(tail -n 1 "${lr_dir}/sorted")
	rm -rf "${lr_dir}"
	printf '%s\n' "${lr_release}"
}

# Abort unless a value is non-empty and made only of the given characters.
# The value is never echoed (see check_package_name).
#
# Arguments:
#   $1  what the value is (used in the error message)
#   $2  value
#   $3  case pattern of one forbidden character, e.g. '[!a-z0-9-]'
check_charset() {
	case "$2" in
	*$3* | '') die "invalid $1" ;;
	*) ;;
	esac
}

# Abort unless the argument is a safe relative directory of the caller
# repository: [A-Za-z0-9._/-], no leading or trailing slash, no empty or
# "." / ".." component, no leading "-" (it could be read as an option by git)
# and no ".git" component in any letter case (git metadata). The value is
# never echoed (see check_package_name).
#
# Arguments:
#   $1  path
check_tests_path() {
	case "$1" in
	*[!A-Za-z0-9._/-]* | /* | */ | '' | *//* | . | ./* | */. | */./* | .. | ../* | */.. | */../*)
		die "invalid tests path (allowed: a relative directory of [A-Za-z0-9._/-], no .. component)"
		;;
	-*) die "invalid tests path (must not start with -)" ;;
	*) ;;
	esac
	ctp_lower=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
	case "${ctp_lower}" in
	.git | .git/* | */.git | */.git/*) die "invalid tests path (.git component)" ;;
	*) ;;
	esac
	[ "${#1}" -le 256 ] || die "invalid tests path (longer than 256 chars)"
}

# Abort unless the argument is a list of secret names separated by spaces or
# commas: each [A-Z][A-Z0-9_]*, between 1 and 32 names, none of them a name that
# the runner, the shell, Python, uv, pytest, node or labgrid read to change how
# a process behaves (GITHUB_*, RUNNER_*, ACTIONS_*, HARNESS_*, LD_*, BASH_*,
# PYTHON*, UV_*, PYTEST_*, LG_*, NODE_OPTIONS, PATH, HOME, SHELL, IFS, ENV, PS4,
# TMPDIR). The value is never echoed (see check_package_name).
#
# Arguments:
#   $1  names
check_secret_names() {
	csn_list=$(printf '%s' "$1" | tr ',' ' ')
	case "${csn_list}" in
	*[!A-Z0-9_\ ]*) die "invalid secret names (allowed: [A-Z][A-Z0-9_]* separated by spaces or commas)" ;;
	*) ;;
	esac
	csn_count=0
	for csn_name in ${csn_list}; do
		case "${csn_name}" in
		[A-Z]*) ;;
		*) die "invalid secret name (must start with A-Z)" ;;
		esac
		case "${csn_name}" in
		GITHUB_* | RUNNER_* | ACTIONS_* | HARNESS_* | LD_* | BASH_* | PYTHON* | UV_* | PYTEST_* | LG_* | NODE_OPTIONS | PATH | HOME | SHELL | IFS | ENV | PS4 | TMPDIR)
			die "invalid secret name (reserved prefix or name)"
			;;
		*) ;;
		esac
		csn_count=$((csn_count + 1))
	done
	[ "${csn_count}" -ge 1 ] || die "no secret name in the list"
	[ "${csn_count}" -le 32 ] || die "too many secret names (at most 32)"
}

# Abort unless the argument is a VM memory size for the QEMU tests: whole
# megabytes written NNNM, from 64M to 1024M. The value is never echoed (see
# check_package_name).
#
# Arguments:
#   $1  memory
check_vm_memory() {
	case "$1" in
	*[!0-9M]* | M* | *M?* | '') die "invalid VM memory (allowed: <megabytes>M from 64M to 1024M)" ;;
	*M) ;;
	*) die "invalid VM memory (allowed: <megabytes>M from 64M to 1024M)" ;;
	esac
	cvm_mb=${1%M}
	case "${cvm_mb}" in
	0* | '') die "invalid VM memory (allowed: <megabytes>M from 64M to 1024M)" ;;
	*) ;;
	esac
	{ [ "${#cvm_mb}" -le 4 ] && [ "${cvm_mb}" -ge 64 ] && [ "${cvm_mb}" -le 1024 ]; } ||
		die "invalid VM memory (allowed: <megabytes>M from 64M to 1024M)"
}

# Abort unless the argument is a list of QEMU test target ids separated by
# spaces or newlines: 1 to 16 ids of [a-z0-9][a-z0-9-]*, at most 32 characters
# each. Whether an id exists is checked against harness/targets.yml by
# scripts/matrix.sh. The value is never echoed (see check_package_name).
#
# Arguments:
#   $1  list
check_target_ids() {
	cti_list=$(printf '%s' "$1" | tr '\n\t\r' '   ') || die "cannot read the target list"
	case "${cti_list}" in
	*[!a-z0-9\ -]*) die "invalid test targets (allowed: ids of [a-z0-9][a-z0-9-]* separated by spaces)" ;;
	*) ;;
	esac
	cti_count=0
	# The charset check above excludes glob characters, so splitting is safe.
	for cti_id in ${cti_list}; do
		case "${cti_id}" in
		-*) die "invalid test target id (must not start with -)" ;;
		*) ;;
		esac
		[ "${#cti_id}" -le 32 ] || die "invalid test target id (longer than 32 chars)"
		cti_count=$((cti_count + 1))
	done
	[ "${cti_count}" -ge 1 ] || die "no test target in the list"
	[ "${cti_count}" -le 16 ] || die "too many test targets (at most 16)"
}

# Abort unless the argument is a GitHub repository, <owner>/<name>: owner
# [A-Za-z0-9-] (at most 39 chars, no leading -), name [A-Za-z0-9._-] (at most
# 100 chars, no leading -, not "." or "..", not ending in ".git"). The value
# is never echoed (see check_package_name).
#
# Arguments:
#   $1  repository
check_feed_repository() {
	case "$1" in
	*/*/* | */ | /* | '') die "invalid feed repository (allowed: <owner>/<name>)" ;;
	*/*) ;;
	*) die "invalid feed repository (allowed: <owner>/<name>)" ;;
	esac
	cfr_owner=${1%%/*}
	cfr_name=${1#*/}
	case "${cfr_owner}" in
	*[!A-Za-z0-9-]* | -*) die "invalid feed repository owner (allowed: [A-Za-z0-9][A-Za-z0-9-]*)" ;;
	*) ;;
	esac
	case "${cfr_name}" in
	*[!A-Za-z0-9._-]* | -* | . | ..) die "invalid feed repository name (allowed: [A-Za-z0-9._-]+, not . or ..)" ;;
	*) ;;
	esac
	[ "${#cfr_owner}" -le 39 ] || die "invalid feed repository owner (longer than 39 chars)"
	[ "${#cfr_name}" -le 100 ] || die "invalid feed repository name (longer than 100 chars)"
	cfr_lower=$(printf '%s' "${cfr_name}" | tr '[:upper:]' '[:lower:]')
	case "${cfr_lower}" in
	*.git) die "invalid feed repository name (ends in .git)" ;;
	*) ;;
	esac
}

# Abort unless the argument is a feed ref: a branch, a tag, a full commit SHA
# or refs/pull/<n>/head. Other refs/ names are refused. Otherwise
# [A-Za-z0-9._/+-], at most 200 chars, no leading - (git could read it as an
# option), no ".." anywhere, no leading, trailing or doubled slash, no
# component starting with "." and no ".lock" or "." ending. The value is never
# echoed (see check_package_name).
#
# Arguments:
#   $1  ref
check_feed_ref() {
	case "$1" in
	refs/pull/*/head)
		cfref_n=${1#refs/pull/}
		cfref_n=${cfref_n%/head}
		case "${cfref_n}" in
		*[!0-9]* | '') die "invalid feed ref (pull request number must be digits)" ;;
		*) ;;
		esac
		[ "${#cfref_n}" -le 9 ] || die "invalid feed ref (pull request number too long)"
		return 0
		;;
	refs/*) die "invalid feed ref (only refs/pull/<n>/head is accepted under refs/)" ;;
	*) ;;
	esac
	case "$1" in
	*[!A-Za-z0-9._/+-]* | '') die "invalid feed ref (allowed: [A-Za-z0-9._/+-]+)" ;;
	-*) die "invalid feed ref (must not start with -)" ;;
	*..* | /* | */ | *//* | .* | */.* | *. | *.lock) die "invalid feed ref (not a valid git ref name)" ;;
	*) ;;
	esac
	[ "${#1}" -le 200 ] || die "invalid feed ref (longer than 200 chars)"
}

# Abort unless the argument is a full commit SHA: 40 lowercase hex digits. The
# value is never echoed (see check_package_name).
#
# Arguments:
#   $1  SHA
check_commit_sha() {
	case "$1" in
	*[!0-9a-f]* | '') die "invalid commit SHA (allowed: 40 lowercase hex digits)" ;;
	*) ;;
	esac
	[ "${#1}" -eq 40 ] || die "invalid commit SHA (allowed: 40 lowercase hex digits)"
}
