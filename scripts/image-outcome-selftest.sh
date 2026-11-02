#!/usr/bin/env sh
# Responsibility: prove scripts/check-image-outcome.sh with fixed make.log
# fixtures, so that a "too big" message that numbers do not prove (the size-less
# warning the Image Builder prints for ANY missing image file, a size below its
# limit, a root filesystem below its partition) can never turn a failure into a
# green expected failure. The real messages are copied from the Image Builder
# 25.12.6 jobs of workflow run 41402517192. Runs in the profiles job of
# images.yml.
#
# Usage:
#   scripts/image-outcome-selftest.sh
#
# Environment variables: none.

set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "${script_dir}/lib/common.sh"

work=$(mktemp -d) || die "cannot create a temporary directory"
trap 'rm -rf "${work}"' EXIT

# Real messages (job 125142860000 x5000r, job 125142860139 archer-c7-v4).
x5000r_msg='    WARNING: Image file /builder/build_dir/target-mipsel_24kc_musl/linux-ramips_mt7621/tmp/openwrt-25.12.6-ramips-mt7621-totolink_x5000r-squashfs-sysupgrade.bin is too big: 18350084 > 16449536'
tplink_part1='file-system partition too big (more than 12453167 bytes): Success'
tplink_part2='file-system partition too big (more than 12451840 bytes): Success'
tplink_warn='    WARNING: Image file /builder/build_dir/target-mips_24kc_musl/linux-ath79_generic/tmp/openwrt-25.12.6-ath79-generic-tplink_archer-c7-v4-squashfs-sysupgrade.bin is too big:  > 15466496'
tplink_rootfs=14742308

# Run check-image-outcome.sh on a fixture and check the result.
#
# Arguments:
#   $1  case name
#   $2  HARNESS_EXPECT: fits or too-big
#   $3  make.log content (one line per message, may be empty)
#   $4  rootfs-bytes content, or empty for no file
#   $5  expected result: "green <outcome> <actual> <limit>" or "red <text>",
#       where <text> must appear in the error
run_case() {
	rm -rf "${work:?}/ib"
	mkdir "${work}/ib"
	printf '%s\n' "$3" >"${work}/ib/make.log"
	if [ -n "$4" ]; then
		printf '%s\n' "$4" >"${work}/ib/rootfs-bytes"
	fi
	rc=0
	out=$(HARNESS_EXPECT=$2 HARNESS_PROFILE_ID=fixture \
		sh "${script_dir}/check-image-outcome.sh" "${work}/ib" 2>&1) || rc=$?
	case "$5" in
	green*)
		[ "${rc}" -eq 0 ] || die "outcome: $1: expected green, exit ${rc}: ${out}"
		# shellcheck disable=SC2086 # split the expectation into words
		set -- "$1" $5
		[ "${out}" = "HARNESS_OUTCOME=$3" ] || die "outcome: $1: unexpected output: ${out}"
		read -r got_actual <"${work}/ib/size-actual"
		read -r got_limit <"${work}/ib/size-limit"
		[ "${got_actual}" = "$4" ] || die "outcome: $1: size-actual ${got_actual}, expected $4"
		[ "${got_limit}" = "$5" ] || die "outcome: $1: size-limit ${got_limit}, expected $5"
		printf 'outcome ok: %-44s -> green %s (%s > %s)\n' "$1" "$3" "$4" "$5"
		;;
	red*)
		[ "${rc}" -ne 0 ] || die "outcome: $1: expected red, got green: ${out}"
		want=${5#red }
		case "${out}" in
		*"${want}"*) ;;
		*) die "outcome: $1: red without \"${want}\": ${out}" ;;
		esac
		printf 'outcome ok: %-44s -> red (%s)\n' "$1" "${want}"
		;;
	*) die "bad expectation: $5" ;;
	esac
}

unproven='is not proven by numbers'

# The review's reproductions: must be red.
run_case "A size-less warning only" too-big "${tplink_warn}" "" "red ${unproven}"
run_case "A size-less warning, rootfs known" too-big "${tplink_warn}" "${tplink_rootfs}" "red ${unproven}"
run_case "E size 10 > limit 20" too-big '    WARNING: Image file /x/openwrt-sysupgrade.bin is too big: 10 > 20' "" "red ${unproven}"
run_case "E2 size equals limit" too-big '    WARNING: Image file /x/openwrt-sysupgrade.bin is too big: 20 > 20' "" "red ${unproven}"
run_case "F partition message, no rootfs size" too-big "${tplink_part1}" "" "red ${unproven}"
run_case "F2 rootfs below the partition" too-big "${tplink_part1}" 12453166 "red ${unproven}"
run_case "F3 rootfs equals the partition" too-big "${tplink_part1}" 12453167 "red ${unproven}"
run_case "F4 rootfs size not a number" too-big "${tplink_part1}" "none" "red ${unproven}"
run_case "G one proven, one unproven message" too-big "${x5000r_msg}
    WARNING: Image file /x/openwrt-sysupgrade.bin is too big: 10 > 20" "" "red ${unproven}"
run_case "H partition message, second below" too-big "${tplink_part1}
file-system partition too big (more than 14742308 bytes): Success" "${tplink_rootfs}" "red ${unproven}"
run_case "A with expect fits" fits "${tplink_warn}" "" "red ${unproven}"

# The real messages: green too-big.
run_case "real x5000r (check-size)" too-big "${x5000r_msg}" "" "green too-big 18350084 16449536"
run_case "real archer-c7-v4 (safeloader)" too-big "stat: cannot statx 'x.bin': No such file or directory
bash: line 1: [: 15466496: unary operator expected
${tplink_part1}
${tplink_warn}
${tplink_part2}" "${tplink_rootfs}" "green too-big ${tplink_rootfs} 12453167"

# Fits, and the expectation against the result.
run_case "fits, expect fits" fits "make: Leaving directory '/builder'" "" "green fits unknown unknown"
run_case "fits, expect too-big (now fits)" too-big "make: Leaving directory '/builder'" "" "red now fits"
run_case "too big, expect fits" fits "${x5000r_msg}" "" "red does not fit the flash"

printf 'outcome self-test: OK\n'
