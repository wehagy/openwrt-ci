#!/usr/bin/env sh
# Responsibility: turn the `profiles` input of an image (or build) workflow
# into the job matrix, checking every profile against the official
# profiles.json of the line: <image_base_url>/profiles.json of the target and
# subtarget (release directory for a "releases" line, snapshots for a
# "snapshot" line, see harness/lines.yml). A target or profile that does not
# exist fails here, within about a minute and before any SDK or Image Builder
# work, with the name of the profile and of the nearest ones. The package
# architecture of each profile is the `arch_packages` field of the same file.
#
# Prints, once everything is valid (so the output is safe for $GITHUB_OUTPUT):
#   matrix={"include":[{"profile":<id>,"target":..,"subtarget":..,
#                       "device":<profile>,"arch":..,"expect":fits|too-big}]}
#   archs=<architecture> ... (sorted, unique)
#
# An empty input selects the default of the harness, `profiles` of
# harness/images.yml (the base's own test profile).
#
# Usage:
#   scripts/resolve-profiles.sh <line> >> "$GITHUB_OUTPUT"
#
# Environment variables:
#   HARNESS_PROFILES  profile tokens (see lib/image-inputs.sh); empty: default
#   HARNESS_DIR       directory with lines.yml and images.yml
#                     (default: <repo>/harness)
#   HARNESS_RELEASE   releases lines only: pin the release instead of scanning
#                     the releases index

set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "${script_dir}/lib/common.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/image-inputs.sh
. "${script_dir}/lib/image-inputs.sh"

[ "$#" -eq 1 ] || die "usage: resolve-profiles.sh <line>"
LINE=$1
export LINE
check_line "${LINE}"
harness_dir=${HARNESS_DIR:-${script_dir}/../harness}
lines_file=${harness_dir}/lines.yml
images_file=${harness_dir}/images.yml

profiles=${HARNESS_PROFILES:-}
profiles_blank=$(printf '%s' "${profiles}" | tr -d ' \n\t\r') || die "cannot read the profiles"
if [ -z "${profiles_blank}" ]; then
	profiles=$(yq_get "${images_file}" '.profiles')
fi
tokens=$(profile_tokens "${profiles}")

# ---------------------------------------------------------------------------
# Where profiles.json is: image_base_url of the line, {release} and {path}.
# ---------------------------------------------------------------------------
line_key='.lines[strenv(LINE)]'
release_source=$(yq_get "${lines_file}" "${line_key}.release_source")
url_pattern=$(yq_get "${lines_file}" "${line_key}.image_base_url")
release=
case "${release_source}" in
releases)
	release=${HARNESS_RELEASE:-}
	if [ -z "${release}" ]; then
		index_url=$(yq_get "${lines_file}" "${line_key}.releases_index_url")
		release_regex=$(yq_get "${lines_file}" "${line_key}.release_regex")
		release=$(latest_release "${index_url}" "${release_regex}")
	fi
	check_release "${release}"
	;;
snapshot) ;;
*) die "unsupported release_source of line ${LINE}" ;;
esac

work=$(mktemp -d) || die "cannot create a temporary directory"
trap 'rm -rf "${work}"' EXIT

# Fetch the profiles.json of a target/subtarget into ${work}/<target>-<subtarget>.json
# once, whatever the number of profiles that use it.
#
# Arguments:
#   $1  target
#   $2  subtarget
fetch_profiles_json() {
	fpj_file=${work}/$1-$2.json
	[ ! -f "${fpj_file}" ] || return 0
	fpj_url=$(printf '%s\n' "${url_pattern}" |
		sed -e "s|{release}|${release}|g" -e "s|{path}|$1/$2|g")/profiles.json
	fpj_rc=0
	curl -fsS --retry 3 --connect-timeout 20 --max-time 60 -o "${fpj_file}" \
		"${fpj_url}" 2>"${work}/curl.err" || fpj_rc=$?
	case "${fpj_rc}" in
	0) ;;
	22 | 37)
		rm -f "${fpj_file}"
		die "target $1/$2 does not exist on line ${LINE}: no profiles.json at ${fpj_url}"
		;;
	*)
		rm -f "${fpj_file}"
		fpj_err=$(cat "${work}/curl.err")
		die "cannot fetch ${fpj_url} (curl exit ${fpj_rc}): ${fpj_err}"
		;;
	esac
	jq -e '.profiles | type == "object"' "${fpj_file}" >/dev/null ||
		die "${fpj_url} has no profiles object"
}

# ---------------------------------------------------------------------------
# One row per profile: id, target, subtarget, device, arch, expect.
# ---------------------------------------------------------------------------
: >"${work}/rows.tsv"
for token in ${tokens}; do
	parse_profile_token "${token}"
	fetch_profiles_json "${pt_target}" "${pt_subtarget}"
	json=${work}/${pt_target}-${pt_subtarget}.json
	if ! jq -e --arg p "${pt_device}" '.profiles | has($p)' "${json}" >/dev/null; then
		# Names that start like the requested one (up to the first - or _),
		# or the first ones, to help with a typo. The name is valid here.
		stem=${pt_device%%[-_]*}
		jq -r '.profiles | keys[]' "${json}" >"${work}/names.txt"
		total=$(wc -l <"${work}/names.txt")
		grep -F -- "${stem}" "${work}/names.txt" | head -n 10 >"${work}/near.txt"
		[ -s "${work}/near.txt" ] || head -n 10 "${work}/names.txt" >"${work}/near.txt"
		near=$(tr '\n' ' ' <"${work}/near.txt")
		die "profile ${pt_device} does not exist in ${pt_target}/${pt_subtarget} on line ${LINE} (${total} profiles there; nearest: ${near% })"
	fi
	arch=$(jq -r '.arch_packages // empty' "${json}")
	check_package_arch "${arch}"
	id=$(profile_id "${pt_target}" "${pt_subtarget}" "${pt_device}")
	printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${id}" "${pt_target}" "${pt_subtarget}" \
		"${pt_device}" "${arch}" "${pt_expect}" >>"${work}/rows.tsv"
done

dups=$(cut -f1 "${work}/rows.tsv" | sort | uniq -d | head -n 1)
[ -z "${dups}" ] || die "two profiles have the same id '${dups}' (a profile is listed twice, or two targets have a profile of the same name)"

# ---------------------------------------------------------------------------
# Output, after every check.
# ---------------------------------------------------------------------------
matrix=$(jq -R -s -c '
	split("\n") | map(select(length > 0) | split("\t")
	| {profile: .[0], target: .[1], subtarget: .[2], device: .[3], arch: .[4], expect: .[5]})
	| {include: .}' "${work}/rows.tsv") || die "cannot build the matrix"
archs=$(cut -f5 "${work}/rows.tsv" | sort -u | tr '\n' ' ')
printf 'matrix=%s\n' "${matrix}"
printf 'archs=%s\n' "${archs% }"
