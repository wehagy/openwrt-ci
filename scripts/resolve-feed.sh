#!/usr/bin/env sh
# Responsibility: validate the feed source of a build (the repository and the
# ref of the package tree) and print it as KEY=value lines. An empty
# repository means openwrt/packages; an empty ref means the packages_branch of
# the line in harness/lines.yml. Nothing is printed unless every input is
# valid, so the output is safe for $GITHUB_ENV.
#
# Usage:
#   scripts/resolve-feed.sh <line> <repository> <ref> >> "$GITHUB_ENV"
#
# Environment variables:
#   HARNESS_DIR  directory with lines.yml (default: <repo>/harness)

set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "${script_dir}/lib/common.sh"

[ "$#" -eq 3 ] || die "usage: resolve-feed.sh <line> <repository> <ref>"
LINE=$1
repository=$2
ref=$3
export LINE
check_line "${LINE}"
lines_file=${HARNESS_DIR:-${script_dir}/../harness}/lines.yml

if [ -z "${repository}" ]; then
	repository=openwrt/packages
fi
# A line that is not a key of lines.yml fails here, before any output.
default_ref=$(yq_get "${lines_file}" '.lines[strenv(LINE)].packages_branch')
if [ -z "${ref}" ]; then
	ref=${default_ref}
fi
check_feed_repository "${repository}"
check_feed_ref "${ref}"

printf 'HARNESS_PACKAGES_REPOSITORY=%s\n' "${repository}"
printf 'HARNESS_PACKAGES_REF=%s\n' "${ref}"
