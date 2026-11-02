#!/usr/bin/env sh
# Responsibility: fetch the .apk of the package under test from its source
# and print its location and version. Sources: "feed" (the official release
# feed of the line) and "artifact" (the .apk built by the build workflow and
# downloaded to a directory).
# The package name and the version are validated before they are printed,
# so the output is safe to append to GITHUB_ENV.
#
# Usage:
#   scripts/fetch-package.sh >> "$GITHUB_ENV"
#
# Environment variables:
#   HARNESS_SOURCE    package source: feed or artifact (required)
#   HARNESS_PACKAGE   package name (required)
#   HARNESS_FEED_URL  feed directory with index.json (required for feed)
#   HARNESS_ARTIFACT_DIR  directory holding the built .apk (required for
#                         artifact)
#   HARNESS_WORK_DIR  where files are written (default: .)

set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "${script_dir}/lib/common.sh"

source_kind=${HARNESS_SOURCE:?HARNESS_SOURCE is required}
package=${HARNESS_PACKAGE:?HARNESS_PACKAGE is required}
work_dir=${HARNESS_WORK_DIR:-.}

check_package_name "${package}"

case "${source_kind}" in
feed)
	feed_url=${HARNESS_FEED_URL:?HARNESS_FEED_URL is required}
	curl -fsSL --retry 3 --connect-timeout 20 --max-time 60 -o "${work_dir}/index.json" "${feed_url}/index.json" ||
		die "cannot fetch ${feed_url}/index.json"
	version=$(jq -r --arg p "${package}" '.packages[$p] // empty' "${work_dir}/index.json") ||
		die "cannot parse ${feed_url}/index.json"
	[ -n "${version}" ] || die "${package} not in ${feed_url}/index.json"
	# The version comes from a remote file; keep it to the apk version charset.
	check_apk_version "${version}"
	curl -fsSL --retry 3 --connect-timeout 20 --max-time 300 -o "${work_dir}/pkg.apk" \
		"${feed_url}/${package}-${version}.apk" ||
		die "cannot fetch ${feed_url}/${package}-${version}.apk"
	;;
artifact)
	artifact_dir=${HARNESS_ARTIFACT_DIR:?HARNESS_ARTIFACT_DIR is required}
	apk_file=$(find_apk "${artifact_dir}" "${package}")
	version=$(apk_version "${apk_file}" "${package}")
	cp "${apk_file}" "${work_dir}/pkg.apk" || die "cannot copy ${apk_file}"
	;;
*)
	die "unsupported package source: ${source_kind}"
	;;
esac

if [ "${HARNESS_LINE}" = main ]; then version=0.0.0-r0; fi
work_abs=$(cd "${work_dir}" && pwd)
printf 'HARNESS_PACKAGE=%s\n' "${package}"
printf 'HARNESS_APK=%s/pkg.apk\n' "${work_abs}"
printf 'HARNESS_PACKAGE_VERSION=%s\n' "${version}"
