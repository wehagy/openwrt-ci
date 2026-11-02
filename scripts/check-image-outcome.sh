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
# Any other failure (make error, missing package) never gets here: the
# Image Builder step already failed.
#
# The "too big" evidence is read from make.log:
#   WARNING: Image file <path> is too big: <size> > <limit>   (check-size; the
#       size is empty when the file was not created)
#   file-system partition too big (more than <limit> bytes)   (tplink-safeloader:
#       the root filesystem does not fit its partition; the size is then the
#       one of root.squashfs, rootfs-bytes)
# The result is written to files in the Image Builder output directory
# (outcome, size-actual, size-limit, size-what, too-big-messages) for
# scripts/image-summary.sh, and printed as HARNESS_OUTCOME (fits or too-big)
# for $GITHUB_ENV.
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
# grep exits 1 when nothing matches, which is the "fits" case; 2 is an error.
messages=${ib_dir}/too-big-messages
grep_rc=0
grep -E 'WARNING: Image file .* is too big|partition too big' "${make_log}" \
	>"${messages}" || grep_rc=$?
[ "${grep_rc}" -le 1 ] || die "cannot search ${make_log}"

outcome=fits
actual=
limit=
what=
if [ -s "${messages}" ]; then
	outcome=too-big
	# First message that states a limit. Sizes are digits only: sed keeps
	# nothing else, so the values are safe for $GITHUB_ENV.
	warn=$(sed -n -e 's/^.*is too big: *\([0-9]*\) > \([0-9]*\)$/\1 \2/p' "${messages}" | sed -n 1p) ||
		die "cannot read ${messages}"
	part=$(sed -n -e 's/^.*partition too big (more than \([0-9]*\) bytes).*$/\1/p' "${messages}" | sed -n 1p) ||
		die "cannot read ${messages}"
	case "${warn}" in
	[0-9]*" "[0-9]*)
		actual=${warn% *}
		limit=${warn#* }
		what=image
		;;
	*" "[0-9]*) limit=${warn#* } ;;
	*) ;;
	esac
	if [ -z "${actual}" ] && [ -n "${part}" ]; then
		# The packing tool refused the root filesystem before check-size
		# had an image: compare the root filesystem with its partition.
		limit=${part}
		what="root filesystem (the image was not created)"
		if [ -f "${ib_dir}/rootfs-bytes" ]; then
			read -r actual <"${ib_dir}/rootfs-bytes" || actual=
		fi
	fi
	case "${actual}" in
	*[!0-9]*) actual= ;;
	*) ;;
	esac
	case "${limit}" in
	*[!0-9]*) limit= ;;
	*) ;;
	esac
fi
printf '%s\n' "${outcome}" >"${ib_dir}/outcome"
printf '%s\n' "${actual:-unknown}" >"${ib_dir}/size-actual"
printf '%s\n' "${limit:-unknown}" >"${ib_dir}/size-limit"
printf '%s\n' "${what:-image}" >"${ib_dir}/size-what"

# ---------------------------------------------------------------------------
# Result against the expectation.
# ---------------------------------------------------------------------------
case "${expect}:${outcome}" in
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
