#!/usr/bin/env sh
# Responsibility: validate the inputs of one build job and resolve its data
# from harness/lines.yml, printed as KEY=value lines: the SDK image data (see
# resolve-sdk.sh) and the feed source to build from (repository and ref, see
# resolve-feed.sh; the commit is the one the feed job resolved).
# Nothing is printed unless every input is valid, so the output is safe for
# $GITHUB_ENV.
#
# Usage:
#   scripts/resolve-build.sh <line> <arch> <package> <repository> <ref> <sha> \
#     >> "$GITHUB_ENV"
#   <repository> and <ref> may be empty (defaults of resolve-feed.sh); <sha> is
#   the full commit SHA of the feed and is required.
#
# Environment variables:
#   HARNESS_DIR  directory with lines.yml (default: <repo>/harness)
#   and those of resolve-sdk.sh

set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "${script_dir}/lib/common.sh"

[ "$#" -eq 6 ] || die "usage: resolve-build.sh <line> <arch> <package> <repository> <ref> <sha>"
LINE=$1
arch=$2
package=$3
feed_repository=$4
feed_ref=$5
feed_sha=$6
export LINE
check_package_name "${package}"
check_commit_sha "${feed_sha}"

# Validates line and arch; nothing is printed on failure.
sdk_data=$("${script_dir}/resolve-sdk.sh" "${LINE}" "${arch}") ||
	die "cannot resolve the SDK image"
feed_data=$("${script_dir}/resolve-feed.sh" "${LINE}" "${feed_repository}" "${feed_ref}") ||
	die "cannot resolve the feed source"

printf '%s\n' "${sdk_data}"
printf 'HARNESS_PACKAGE=%s\n' "${package}"
printf '%s\n' "${feed_data}"
printf 'HARNESS_PACKAGES_SHA=%s\n' "${feed_sha}"
