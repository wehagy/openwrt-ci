#!/usr/bin/env sh
# Responsibility: read what an official OpenWrt SDK or Image Builder container
# downloads at setup time, without downloading it (sourced, not run): the
# environment recorded in the container, the address of the sha256sums that
# lists the archive, and the archive's name and sha256 in that file. The
# lookup is the one of the setup.sh of openwrt/docker (the same grep of the
# same file), so the name and sha256 found here are the ones setup.sh will
# verify. The sha256sums read here is not signature-checked: it only decides
# whether to rebuild (setup.sh verifies the signature and the archive in the
# build) or whether to warn about a stale image.
#
# Usage:
#   . "${script_dir}/lib/common.sh"
#   . "${script_dir}/lib/sdk-labels.sh"
#   . "${script_dir}/lib/image-upstream.sh"
#
# Environment variables: none.

# Print the value of one variable of the environment of an image
# (`docker image inspect --format '{{json .Config.Env}}'`); empty when absent.
#
# Arguments:
#   $1  file with the JSON array of "NAME=value"
#   $2  variable name
upstream_env_get() {
	jq -r --arg name "$2" \
		'(map(select(startswith($name + "="))) | .[0] // "") | ltrimstr($name + "=")' "$1" ||
		die "cannot read the environment of the image"
}

# Abort unless the value is non-empty, one line and made only of the given
# characters (a tr set). The value is never echoed.
#
# Arguments:
#   $1  what it is
#   $2  value
#   $3  allowed characters, as a tr set
upstream_check() {
	[ -n "$2" ] || die "the official container sets no $1"
	[ "${#2}" -le 256 ] || die "the $1 of the official container is too long"
	uc_rest=$(printf '%s' "$2" | tr -d "$3") || die "cannot check the $1"
	[ -z "${uc_rest}" ] || die "the $1 of the official container has an unexpected character"
}

# Print the address of the sha256sums file of a target, as setup.sh builds it:
# <host>/<version path>/targets/<target>/sha256sums. A host without a scheme
# (the containers set downloads.openwrt.org) gets https://.
#
# Arguments:
#   $1  FILE_HOST of the container
#   $2  VERSION_PATH (snapshots or releases/<version>)
#   $3  TARGET (<target>/<subtarget>)
upstream_sums_url() {
	upstream_check "FILE_HOST" "$1" 'A-Za-z0-9.:/_-'
	upstream_check "VERSION_PATH" "$2" 'A-Za-z0-9./_-'
	upstream_check "TARGET" "$3" 'A-Za-z0-9/_-'
	case "$1" in
	https://* | http://*) usu_host=$1 ;;
	*://*) die "the FILE_HOST of the official container has an unexpected scheme" ;;
	*) usu_host=https://$1 ;;
	esac
	printf '%s/%s/targets/%s/sha256sums\n' "${usu_host}" "$2" "$3"
}

# Download a file for a decision, retrying only what curl itself retries
# (timeouts, 5xx); any other failure ends the script.
#
# Arguments:
#   $1  address
#   $2  file to write
upstream_fetch() {
	curl -fsS --retry 3 --connect-timeout 20 --max-time 120 -o "$2" "$1" ||
		die "cannot download the checksums from $1"
}

# Print "<sha256> <name>" of the archive that setup.sh would download: the one
# line of the sha256sums that DOWNLOAD_FILE (a regular expression, as in
# setup.sh) matches. No match or more than one aborts, since setup.sh would
# not know which to take either.
#
# Arguments:
#   $1  sha256sums file
#   $2  DOWNLOAD_FILE of the container
upstream_pick() {
	# shellcheck disable=SC2016 # a tr set, not an expansion
	upstream_check "DOWNLOAD_FILE" "$2" 'A-Za-z0-9._*+|^$()[]{}?\\ -'
	up_matches=$(grep -c -- "$2" "$1") || [ "$?" -eq 1 ] || die "cannot search the checksums"
	[ "${up_matches}" = 1 ] || die "the checksums list ${up_matches} files for the archive pattern, expected 1"
	up_line=$(grep -- "$2" "$1") || die "cannot read the archive line"
	up_sha=${up_line%% *}
	up_name=$(printf '%s\n' "${up_line}" | cut -d '*' -f 2) || die "cannot read the archive name"
	check_sdk_archive "${up_sha}" "${up_name}"
	printf '%s %s\n' "${up_sha}" "${up_name}"
}

# Print the sha256 that the sha256sums lists for a file name; empty when the
# name is not listed.
#
# Arguments:
#   $1  sha256sums file
#   $2  archive name
upstream_sha_of() {
	awk -v want="*$2" '$2 == want { print $1; exit }' "$1" ||
		die "cannot read the checksums"
}
