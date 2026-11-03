#!/usr/bin/env sh
# Responsibility: turn the lines, the QEMU test targets and the image profiles
# of a caller into the two job matrices of the daily refresh: one SDK image
# per (line, package architecture) and one Image Builder image per (line,
# target, subtarget) of the profiles. The architectures are resolved as
# build.yml does (scripts/resolve-archs.sh: the architectures of the test
# targets and of the profiles) and the profiles are checked against the
# profiles.json of each line (scripts/resolve-profiles.sh), so an unknown
# profile or line fails here, before any image is built. Duplicates are
# dropped.
#
# Prints, once everything is valid (so the output is safe for $GITHUB_OUTPUT):
#   sdk_matrix={"include":[{"line":..,"arch":..},...]}
#   sdk_count=<number>
#   ib_matrix={"include":[{"line":..,"target":..,"subtarget":..},...]}
#   ib_count=<number>
#
# Usage:
#   scripts/refresh-plan.sh >> "$GITHUB_OUTPUT"
#
# Environment variables:
#   HARNESS_REFRESH_LINES  lines of harness/lines.yml, separated by spaces
#                          (required)
#   HARNESS_PROFILES       image profiles, as the profiles input of images.yml
#                          (empty: no Image Builder image)
#   HARNESS_TARGETS        QEMU test targets whose architectures are wanted
#                          (empty: all targets of harness/targets.yml)
#   HARNESS_DIR            directory with lines.yml and targets.yml
#                          (default: <repo>/harness)

# -f: no word of the lines is a glob.
set -efu

script_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "${script_dir}/lib/common.sh"

# Not `${VAR:?}` inside the command substitution: that would end only the
# substitution and leave an empty list that plans nothing and succeeds.
[ -n "${HARNESS_REFRESH_LINES:-}" ] || die "HARNESS_REFRESH_LINES is required"
lines=$(printf '%s' "${HARNESS_REFRESH_LINES}" | tr '\n\t\r' '   ')
lines_blank=$(printf '%s' "${lines}" | tr -d ' ')
[ -n "${lines_blank}" ] || die "HARNESS_REFRESH_LINES names no line"
case "${lines}" in
*[!A-Za-z0-9._\ -]*) die "invalid lines (allowed: names of harness/lines.yml separated by spaces)" ;;
*) ;;
esac
[ "${#lines}" -le 256 ] || die "invalid lines (longer than 256 chars)"

work=$(mktemp -d) || die "cannot create a temporary directory"
trap 'rm -rf "${work}"' EXIT
: >"${work}/sdk.json"
: >"${work}/ib.json"
seen=" "
for line in ${lines}; do
	check_line "${line}"
	case "${seen}" in
	*" ${line} "*) die "line ${line} is listed twice" ;;
	*) ;;
	esac
	seen="${seen}${line} "
	archs_out=$("${script_dir}/resolve-archs.sh" "${line}") || die "cannot resolve the architectures of line ${line}"
	archs=$(printf '%s\n' "${archs_out}" | sed -n -e 's/^archs=//p')
	for arch in ${archs}; do
		jq -n -c --arg line "${line}" --arg arch "${arch}" '{line: $line, arch: $arch}' >>"${work}/sdk.json" ||
			die "cannot build the SDK matrix"
	done
	profiles_out=$("${script_dir}/resolve-profiles.sh" "${line}") || die "cannot resolve the profiles of line ${line}"
	printf '%s\n' "${profiles_out}" | sed -n -e 's/^matrix=//p' |
		jq -c --arg line "${line}" '.include[] | {line: $line, target: .target, subtarget: .subtarget}' >>"${work}/ib.json" ||
		die "cannot build the Image Builder matrix"
done

sdk=$(jq -s -c '{include: unique}' "${work}/sdk.json") || die "cannot build the SDK matrix"
ib=$(jq -s -c '{include: unique}' "${work}/ib.json") || die "cannot build the Image Builder matrix"
sdk_count=$(printf '%s\n' "${sdk}" | jq '.include | length') || die "cannot count the SDK images"
ib_count=$(printf '%s\n' "${ib}" | jq '.include | length') || die "cannot count the Image Builder images"
[ "$((sdk_count + ib_count))" -le 200 ] || die "too many images to refresh (at most 200)"
printf 'sdk_matrix=%s\n' "${sdk}"
printf 'sdk_count=%s\n' "${sdk_count}"
printf 'ib_matrix=%s\n' "${ib}"
printf 'ib_count=%s\n' "${ib_count}"
