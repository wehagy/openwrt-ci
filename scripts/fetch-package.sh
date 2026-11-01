#!/usr/bin/env sh
# Responsibility: fetch the .apk of the package under test from its source
# and print its location and version. Only source "feed" (the official
# release feed of the line) exists; "artifact" is added by a later slice.
# The package name and the version are validated before they are printed,
# so the output is safe to append to GITHUB_ENV.
#
# Usage:
#   scripts/fetch-package.sh >> "$GITHUB_ENV"
#
# Environment variables:
#   HARNESS_SOURCE    package source: feed (required)
#   HARNESS_PACKAGE   package name (required)
#   HARNESS_FEED_URL  feed directory with index.json (required for feed)
#   HARNESS_WORK_DIR  where files are written (default: .)

set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "${script_dir}/lib/common.sh"

source_kind=${HARNESS_SOURCE:?HARNESS_SOURCE is required}
package=${HARNESS_PACKAGE:?HARNESS_PACKAGE is required}
work_dir=${HARNESS_WORK_DIR:-.}

case "${package}" in
*[!a-z0-9._+-]* | '') die "invalid package name: ${package}" ;;
*) ;;
esac

case "${source_kind}" in
feed)
	feed_url=${HARNESS_FEED_URL:?HARNESS_FEED_URL is required}
	curl -fsSL --retry 3 --connect-timeout 20 --max-time 60 -o "${work_dir}/index.json" "${feed_url}/index.json" ||
		die "cannot fetch ${feed_url}/index.json"
	version=$(jq -r --arg p "${package}" '.packages[$p] // empty' "${work_dir}/index.json") ||
		die "cannot parse ${feed_url}/index.json"
	[ -n "${version}" ] || die "${package} not in ${feed_url}/index.json"
	# The version comes from a remote file; keep it to the apk version charset.
	case "${version}" in
	*[!A-Za-z0-9._+~-]*) die "invalid version for ${package} in ${feed_url}/index.json" ;;
	*) ;;
	esac
	curl -fsSL --retry 3 --connect-timeout 20 --max-time 300 -o "${work_dir}/pkg.apk" \
		"${feed_url}/${package}-${version}.apk" ||
		die "cannot fetch ${feed_url}/${package}-${version}.apk"
	;;
*)
	die "unsupported package source: ${source_kind}"
	;;
esac

work_abs=$(cd "${work_dir}" && pwd)
printf 'HARNESS_PACKAGE=%s\n' "${package}"
printf 'HARNESS_APK=%s/pkg.apk\n' "${work_abs}"
printf 'HARNESS_PACKAGE_VERSION=%s\n' "${version}"
