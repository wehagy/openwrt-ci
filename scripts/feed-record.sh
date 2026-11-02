#!/usr/bin/env sh
# Responsibility: report the feed source that a build used: the repository and
# the ref that were requested and the commit the checkout resolved to. By
# default it prints repository=, ref= and sha= lines for $GITHUB_OUTPUT; with
# --summary it prints a Markdown line for $GITHUB_STEP_SUMMARY. The SHA is read
# from the checkout and validated before anything is printed.
#
# Usage:
#   scripts/feed-record.sh <feed-dir> >> "$GITHUB_OUTPUT"
#   scripts/feed-record.sh --summary <feed-dir> >> "$GITHUB_STEP_SUMMARY"
#
# Environment variables (set by scripts/resolve-feed.sh):
#   HARNESS_PACKAGES_REPOSITORY, HARNESS_PACKAGES_REF

set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "${script_dir}/lib/common.sh"

mode=output
if [ "${1:-}" = --summary ]; then
	mode=summary
	shift
fi
[ "$#" -eq 1 ] || die "usage: feed-record.sh [--summary] <feed-dir>"
feed_dir=$1
repository=${HARNESS_PACKAGES_REPOSITORY:?HARNESS_PACKAGES_REPOSITORY is required}
ref=${HARNESS_PACKAGES_REF:?HARNESS_PACKAGES_REF is required}
check_feed_repository "${repository}"
check_feed_ref "${ref}"
sha=$(git -C "${feed_dir}" rev-parse HEAD) || die "${feed_dir} is not a git checkout"
check_commit_sha "${sha}"

case "${mode}" in
output)
	printf 'repository=%s\n' "${repository}"
	printf 'ref=%s\n' "${ref}"
	printf 'sha=%s\n' "${sha}"
	;;
*)
	printf '### feed source\n'
	printf -- '- repository: %s\n' "${repository}"
	printf -- '- ref: %s\n' "${ref}"
	printf -- '- commit: %s\n' "${sha}"
	;;
esac
