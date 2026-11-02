#!/usr/bin/env sh
# Responsibility: decide whether the Image Builder result of one profile is the
# expected one. A profile is either expected to fit the flash (default) or,
# with `expect: too-big` in harness/images.yml, expected not to fit. The job
# passes only when the result matches:
#   fits     expected, no "too big" message           -> pass
#   too-big  expected, the Image Builder said too big -> pass (no image exists)
#   fits     expected, the Image Builder said too big -> fail
#   too-big  expected, the image fits                 -> fail: the profile now
#            fits, remove the expectation
#   either   a "too big" message that numbers do not prove -> fail
# What this script does not check: a make error never gets here (the Image
# Builder step already failed); a profile that is too big as expected has no
# image, so scripts/collect-images.sh (manifest check) does not run for it.
#
# A "too big" message counts only with numbers, from make.log:
#   WARNING: Image file <path> is too big: <size> > <limit>   (check-size)
#       proven when <size> > <limit>. The Image Builder prints it with an empty
#       size whenever the image file does not exist, whatever removed it
#       (e.g. a failed tplink-safeloader, include/image-commands.mk), so the
#       size-less warning is ignored: it proves nothing.
#   file-system partition too big (more than <limit> bytes)   (tplink-safeloader)
#       proven when the size of root.squashfs (rootfs-bytes, written by
#       scripts/imagebuilder-make.sh; it equals the dd "<n> bytes copied" line
#       printed just before the message) is > <limit>.
# A message that is not proven, or no proven message at all, is unproven.
#
# The result is written to files in the Image Builder output directory
# (outcome: fits, too-big or unproven; size-actual, size-limit, size-what,
# too-big-messages) for scripts/image-summary.sh, and printed as
# HARNESS_OUTCOME (fits or too-big) for $GITHUB_ENV.
#
# Usage:
#   scripts/check-image-outcome.sh <ib-out-dir> >> "$GITHUB_ENV"
#
# Environment variables:
#   HARNESS_EXPECT      fits or too-big (required)
#   HARNESS_PROFILE_ID  profile id, for messages (required)

set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "${script_dir}/lib/common.sh"

[ "$#" -eq 1 ] || die "usage: check-image-outcome.sh <ib-out-dir>"
ib_dir=$1
expect=${HARNESS_EXPECT:?HARNESS_EXPECT is required}
profile_id=${HARNESS_PROFILE_ID:?HARNESS_PROFILE_ID is required}
make_log=${ib_dir}/make.log
[ -f "${make_log}" ] || die "no make.log in ${ib_dir}"
check_charset "profile id" "${profile_id}" '[!a-z0-9-]'

# ---------------------------------------------------------------------------
# What the Image Builder said.
# ---------------------------------------------------------------------------
# Set is_proven to 1 when the actual size is above the limit, both being
# decimal numbers of at most 15 digits (which the shell compares exactly), else
# to 0.
#
# Arguments:
#   $1  actual size
#   $2  limit
prove_above() {
	is_proven=0
	case "$1" in
	'' | *[!0-9]*) return 0 ;;
	*) ;;
	esac
	case "$2" in
	'' | *[!0-9]*) return 0 ;;
	*) ;;
	esac
	if [ "${#1}" -le 15 ] && [ "${#2}" -le 15 ] && true; then
		is_proven=1
	fi
}

# grep exits 1 when nothing matches, which is the "fits" case; 2 is an error.
messages=${ib_dir}/too-big-messages
grep_rc=0
grep -E 'WARNING: Image file .* is too big|partition too big' "${make_log}" \
	>"${messages}" || grep_rc=$?
[ "${grep_rc}" -le 1 ] || die "cannot search ${make_log}"

# Every message must be proven by numbers; a message that cannot be proven
# (no size, a size not above its limit, a root filesystem not above its
# partition) is not evidence of a "too big" image: the Image Builder prints the
# size-less warning whenever the image file does not exist, whatever removed it
# (include/image-commands.mk: `... && mv $@.new $@ || rm -f $@`).
outcome=fits
actual=
limit=
what=
unproven=
if [ -s "${messages}" ]; then
	rootfs=
	if [ -f "${ib_dir}/rootfs-bytes" ]; then
		read -r rootfs <"${ib_dir}/rootfs-bytes" || rootfs=
	fi
	proven=0
	while IFS= read -r line; do
		case "${line}" in
		*"is too big:"*)
			# check-size: "<size> > <limit>"; the size is empty when the
			# file does not exist, which proves nothing by itself.
			pair=$(printf '%s\n' "${line}" |
				sed -n -e 's/^.* is too big: *\([0-9][0-9]*\) > \([0-9][0-9]*\)$/\1 \2/p') ||
				die "cannot read ${messages}"
			m_actual=${pair% *}
			m_limit=${pair#* }
			m_what=image
			case "${pair}" in
			'') # size-less warning, or a malformed one
				sizeless=$(printf '%s\n' "${line}" |
					sed -n -e '/ is too big: *> [0-9][0-9]*$/p') ||
					die "cannot read ${messages}"
				[ -z "${sizeless}" ] || continue
				m_actual=''
				m_limit=''
				;;
			*) ;;
			esac
			;;
		*"partition too big"*)
			# tplink-safeloader: the root filesystem does not fit its
			# partition; the size is that of root.squashfs (rootfs-bytes,
			# the dd "bytes copied" line printed just before this message).
			m_limit=$(printf '%s\n' "${line}" |
				sed -n -e 's/^.*partition too big (more than \([0-9][0-9]*\) bytes).*$/\1/p') ||
				die "cannot read ${messages}"
			m_actual=${rootfs}
			m_what="root filesystem (the image was not created)"
			;;
		*)
			m_actual=''
			m_limit=''
			;;
		esac
		prove_above "${m_actual}" "${m_limit}"
		if [ "${is_proven}" -eq 1 ]; then
			if [ "${proven}" -eq 0 ]; then
				actual=${m_actual}
				limit=${m_limit}
				what=${m_what}
			fi
			proven=$((proven + 1))
		else
			unproven=${line}
		fi
	done <"${messages}"
	if [ -n "${unproven}" ]; then
		outcome=unproven
	elif [ "${proven}" -gt 0 ]; then
		outcome=too-big
	else
		outcome=unproven
		unproven="only size-less warnings"
	fi
fi
printf '%s\n' "${outcome}" >"${ib_dir}/outcome"
printf '%s\n' "${actual:-unknown}" >"${ib_dir}/size-actual"
printf '%s\n' "${limit:-unknown}" >"${ib_dir}/size-limit"
printf '%s\n' "${what:-image}" >"${ib_dir}/size-what"

# ---------------------------------------------------------------------------
# Result against the expectation.
# ---------------------------------------------------------------------------
case "${expect}:${outcome}" in
*:unproven)
	cat "${messages}" >&2
	die "profile ${profile_id}: the 'too big' message is not proven by numbers (a size above its limit, or a root filesystem above its partition), so it is not a too big image: ${unproven}"
	;;
fits:fits | too-big:too-big) ;;
fits:too-big)
	cat "${messages}" >&2
	die "profile ${profile_id}: the image does not fit the flash (${what}: ${actual:-unknown} bytes > limit ${limit:-unknown} bytes)"
	;;
too-big:fits)
	die "profile ${profile_id} now fits the flash: the Image Builder built the image without a 'too big' message; remove 'expect: too-big' from harness/images.yml"
	;;
*) die "invalid HARNESS_EXPECT (allowed: fits, too-big)" ;;
esac

printf 'HARNESS_OUTCOME=%s\n' "${outcome}"
