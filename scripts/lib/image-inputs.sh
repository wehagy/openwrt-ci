#!/usr/bin/env sh
# Responsibility: validators and parsers of the caller-given image inputs
# (profiles, extra packages, architectures), sourced by the scripts that read
# them (sourced, not run). Needs lib/common.sh sourced first. Every validator
# aborts through die() and never echoes the value, so a value with a newline
# or a "::" prefix cannot forge workflow commands in the log.
#
# Usage:
#   . "${script_dir}/lib/common.sh"
#   . "${script_dir}/lib/image-inputs.sh"
#
# Environment variables: none.

# Limits of the inputs (the matrix of a job is limited to 256 entries by
# GitHub; these keep a typo from starting dozens of 90 minute jobs).
IMAGE_MAX_PROFILES=16
IMAGE_MAX_PACKAGES=100
IMAGE_MAX_ARCHS=16
export IMAGE_MAX_PROFILES IMAGE_MAX_PACKAGES IMAGE_MAX_ARCHS

# ---------------------------------------------------------------------------
# Profiles: <target>/<subtarget>/<profile>[:too-big]
# ---------------------------------------------------------------------------

# Parse and validate one profile token. Sets pt_target, pt_subtarget,
# pt_device (the Image Builder PROFILE) and pt_expect (fits or too-big) in
# the calling shell, so it must not be run in a command substitution.
# `:too-big` declares an image that is known not to fit the flash.
#
# Arguments:
#   $1  token, e.g. ath79/generic/tplink_archer-c7-v4:too-big
parse_profile_token() {
	ppt_spec=${1%:too-big}
	pt_expect=fits
	if [ "${ppt_spec}" != "$1" ]; then
		pt_expect=too-big
	fi
	case "${ppt_spec}" in
	*[!A-Za-z0-9_/-]* | '') die "invalid profile (allowed: <target>/<subtarget>/<profile>, optionally followed by :too-big)" ;;
	*/*/*/* | /* | */ | *//*) die "invalid profile (allowed: <target>/<subtarget>/<profile>, optionally followed by :too-big)" ;;
	*/*/*) ;;
	*) die "invalid profile (allowed: <target>/<subtarget>/<profile>, optionally followed by :too-big)" ;;
	esac
	pt_target=${ppt_spec%%/*}
	ppt_rest=${ppt_spec#*/}
	pt_subtarget=${ppt_rest%%/*}
	pt_device=${ppt_rest#*/}
	check_charset "profile target" "${pt_target}" '[!a-z0-9]'
	check_charset "profile subtarget" "${pt_subtarget}" '[!a-z0-9]'
	check_charset "profile name" "${pt_device}" '[!A-Za-z0-9_-]'
	[ "${#pt_target}" -le 32 ] || die "invalid profile target (longer than 32 chars)"
	[ "${#pt_subtarget}" -le 32 ] || die "invalid profile subtarget (longer than 32 chars)"
	[ "${#pt_device}" -le 64 ] || die "invalid profile name (longer than 64 chars)"
	export pt_expect
}

# Print the id of a profile, used in the job name and in the artifact name
# images-<package>-<line>-<id>: the profile name in lower case with "_" as
# "-"; a profile named "generic" (one per target) gets <target>-<subtarget>
# in front. Arguments are assumed valid (see parse_profile_token).
#
# Arguments:
#   $1  target
#   $2  subtarget
#   $3  profile name
profile_id() {
	pid_name=$(printf '%s' "$3" | tr '[:upper:]_' '[:lower:]-') ||
		die "cannot derive the profile id"
	case "${pid_name}" in
	generic) printf '%s-%s-generic\n' "$1" "$2" ;;
	*) printf '%s\n' "${pid_name}" ;;
	esac
}

# Print the profile tokens of a list, one per line: whitespace separates
# tokens, the list has between 1 and IMAGE_MAX_PROFILES of them and each is
# valid (parse_profile_token). The value is never echoed.
#
# Arguments:
#   $1  list
profile_tokens() {
	pt_list=$(printf '%s' "$1" | tr '\n\t\r' '   ') || die "cannot read the profile list"
	case "${pt_list}" in
	*[!A-Za-z0-9_/:\ -]*) die "invalid profiles (allowed: <target>/<subtarget>/<profile>[:too-big] separated by spaces or newlines)" ;;
	*) ;;
	esac
	[ "${#pt_list}" -le 2048 ] || die "invalid profiles (longer than 2048 chars)"
	pt_count=0
	for pt_token in ${pt_list}; do
		parse_profile_token "${pt_token}"
		pt_count=$((pt_count + 1))
		printf '%s\n' "${pt_token}"
	done
	[ "${pt_count}" -ge 1 ] || die "no profile in the list"
	[ "${pt_count}" -le "${IMAGE_MAX_PROFILES}" ] ||
		die "too many profiles (at most ${IMAGE_MAX_PROFILES})"
}

# ---------------------------------------------------------------------------
# Extra packages: <name> adds, -<name> removes (Image Builder PACKAGES syntax)
# ---------------------------------------------------------------------------

# Abort unless the argument is a list of Image Builder package tokens
# separated by spaces or newlines: <name> (add) or -<name> (remove), each name
# valid for check_package_name, at most IMAGE_MAX_PACKAGES tokens and 2048
# characters. An empty list is valid.
#
# Arguments:
#   $1  list
check_image_packages() {
	cip_list=$(printf '%s' "$1" | tr '\n\t\r' '   ') || die "cannot read the package list"
	case "${cip_list}" in
	*[!a-z0-9._+\ -]*) die "invalid packages (allowed: <name> or -<name> separated by spaces, name [a-z0-9][a-z0-9._+-]*)" ;;
	*) ;;
	esac
	[ "${#cip_list}" -le 2048 ] || die "invalid packages (longer than 2048 chars)"
	cip_count=0
	# The charset check above excludes glob characters, so splitting is safe.
	for cip_token in ${cip_list}; do
		check_package_name "${cip_token#-}"
		cip_count=$((cip_count + 1))
	done
	[ "${cip_count}" -le "${IMAGE_MAX_PACKAGES}" ] ||
		die "too many packages (at most ${IMAGE_MAX_PACKAGES})"
}

# Print the tokens of a valid package list on one line separated by single
# spaces (empty for an empty list). The list must have passed
# check_image_packages.
#
# Arguments:
#   $1  list
image_packages_line() {
	ipl_list=$(printf '%s' "$1" | tr '\n\t\r' '   ') || die "cannot read the package list"
	ipl_out=
	for ipl_token in ${ipl_list}; do
		ipl_out=${ipl_out:+${ipl_out} }${ipl_token}
	done
	printf '%s\n' "${ipl_out}"
}

# ---------------------------------------------------------------------------
# Architectures: @tests, @profiles or a package architecture
# ---------------------------------------------------------------------------

# Abort unless the argument is an architecture token of the `archs` input:
# "@tests" (the architectures of the QEMU test targets), "@profiles" (those of
# the profiles input) or a package architecture, [a-z0-9][a-z0-9_-]* of at
# most 64 characters. The value is never echoed.
#
# Arguments:
#   $1  token
check_arch_token() {
	case "$1" in
	@tests | @profiles) ;;
	*) check_package_arch "$1" ;;
	esac
}

# Abort unless the argument is a package architecture,
# [a-z0-9][a-z0-9_-]* of at most 64 characters. The value is never echoed.
#
# Arguments:
#   $1  architecture
check_package_arch() {
	case "$1" in
	*[!a-z0-9_-]* | [!a-z0-9]* | '') die "invalid architecture (allowed: [a-z0-9][a-z0-9_-]*, @tests or @profiles)" ;;
	*) ;;
	esac
	[ "${#1}" -le 64 ] || die "invalid architecture (longer than 64 chars)"
}

# ---------------------------------------------------------------------------
# Image Builder image names
# ---------------------------------------------------------------------------

# Print the tag of an Image Builder image: <target>-<subtarget>-<suffix>. It is
# the tag of the official snapshot container, and the tag of the harness image
# on GHCR for the line, whether that image is built from the snapshot container
# or is a copy of the release container. One place for the refresh, which
# writes the image, and for the image jobs, which read it.
#
# Arguments:
#   $1  target
#   $2  subtarget
#   $3  imagebuilder_tag_suffix of the line (harness/lines.yml)
ib_tag() {
	check_charset "target" "$1" '[!a-z0-9]'
	check_charset "subtarget" "$2" '[!a-z0-9]'
	check_charset "ImageBuilder tag suffix" "$3" '[!A-Za-z0-9._-]'
	printf '%s-%s-%s\n' "$1" "$2" "$3"
}
