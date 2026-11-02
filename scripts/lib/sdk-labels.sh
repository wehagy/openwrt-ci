#!/usr/bin/env sh
# Responsibility: the label keys of the harness SDK image and the check of the
# values read back from them (sourced, not run).
#
# Usage:
#   . "${script_dir}/lib/common.sh"
#   . "${script_dir}/lib/sdk-labels.sh"
#
# Environment variables: none (it exports the label_* key names).

export label_created=org.opencontainers.image.created
export label_archive=io.github.wehagy.openwrt-ci.sdk-archive
export label_archive_sha=io.github.wehagy.openwrt-ci.sdk-archive-sha256
export label_run_id=io.github.wehagy.openwrt-ci.run-id
export label_run_attempt=io.github.wehagy.openwrt-ci.run-attempt

# Abort unless the SDK archive name and sha256 are well formed. Values are
# never echoed (see check_package_name in common.sh).
#
# Arguments:
#   $1  sha256, 64 lowercase hex digits
#   $2  archive file name
check_sdk_archive() {
	case "$1" in
	*[!0-9a-f]* | '') die "invalid SDK archive sha256" ;;
	*) ;;
	esac
	[ "${#1}" -eq 64 ] || die "invalid SDK archive sha256 (not 64 digits)"
	case "$2" in
	*[!A-Za-z0-9._+-]* | [!A-Za-z0-9]* | '') die "invalid SDK archive name" ;;
	*) ;;
	esac
}
