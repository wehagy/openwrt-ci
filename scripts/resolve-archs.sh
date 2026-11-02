#!/usr/bin/env sh
# Responsibility: turn the `archs` input of build.yml into the architecture
# matrix of its sdk-image and sdk jobs: the tokens of the input, with `@tests`
# replaced by the package architectures of the QEMU test targets
# (harness/targets.yml) and `@profiles` by the architectures of the `profiles`
# input (resolved from profiles.json by scripts/resolve-profiles.sh, which
# also fails for a profile that does not exist). Duplicates are dropped, the
# first occurrence keeps its place.
#
# Prints, once everything is valid (so the output is safe for $GITHUB_OUTPUT):
#   matrix={"arch":["x86_64",...]}
#   archs=<architecture> ...
#
# Usage:
#   scripts/resolve-archs.sh <line> >> "$GITHUB_OUTPUT"
#
# Environment variables:
#   HARNESS_ARCHS     tokens: @tests, @profiles or package architectures,
#                     separated by spaces or newlines (default: "@tests @profiles")
#   HARNESS_PROFILES  the profiles input, read only when @profiles is used
#   HARNESS_DIR       directory with lines.yml, images.yml and targets.yml
#                     (default: <repo>/harness)

set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "${script_dir}/lib/common.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/image-inputs.sh
. "${script_dir}/lib/image-inputs.sh"

[ "$#" -eq 1 ] || die "usage: resolve-archs.sh <line>"
LINE=$1
check_line "${LINE}"
harness_dir=${HARNESS_DIR:-${script_dir}/../harness}
targets_file=${harness_dir}/targets.yml

archs_input=$(printf '%s' "${HARNESS_ARCHS:-@tests @profiles}" | tr '\n\t\r' '   ')
case "${archs_input}" in
*[!A-Za-z0-9_@\ -]*) die "invalid archs (allowed: @tests, @profiles or architectures [a-z0-9][a-z0-9_-]*, separated by spaces)" ;;
*) ;;
esac
[ "${#archs_input}" -le 1024 ] || die "invalid archs (longer than 1024 chars)"

work=$(mktemp -d) || die "cannot create a temporary directory"
trap 'rm -rf "${work}"' EXIT
: >"${work}/all.txt"
# The charset check above excludes glob characters, so splitting is safe.
for token in ${archs_input}; do
	check_arch_token "${token}"
	case "${token}" in
	@tests)
		yq '.targets[].arch' "${targets_file}" >>"${work}/all.txt" ||
			die "yq failed on ${targets_file}"
		;;
	@profiles)
		resolved=$(HARNESS_PROFILES="${HARNESS_PROFILES:-}" "${script_dir}/resolve-profiles.sh" "${LINE}") ||
			die "cannot resolve the profiles for @profiles"
		printf '%s\n' "${resolved}" | sed -n -e 's/^archs=//p' | tr ' ' '\n' >>"${work}/all.txt"
		;;
	*) printf '%s\n' "${token}" >>"${work}/all.txt" ;;
	esac
done

# First occurrence wins; the architectures from the YAML and from profiles.json
# are validated like the literal ones.
awk 'NF && !seen[$0]++' "${work}/all.txt" >"${work}/unique.txt"
count=0
while read -r arch; do
	check_package_arch "${arch}"
	count=$((count + 1))
done <"${work}/unique.txt"
[ "${count}" -ge 1 ] || die "no architecture to build"
[ "${count}" -le "${IMAGE_MAX_ARCHS}" ] || die "too many architectures (at most ${IMAGE_MAX_ARCHS})"

matrix=$(jq -R -s -c '{arch: (split("\n") | map(select(length > 0)))}' "${work}/unique.txt") ||
	die "cannot build the matrix"
printf 'matrix=%s\n' "${matrix}"
archs=$(tr '\n' ' ' <"${work}/unique.txt" | sed 's/ $//') || die "cannot list the architectures"
printf 'archs=%s\n' "${archs}"
