#!/usr/bin/env sh
# Responsibility: resolve the data of one image of the daily refresh from
# harness/lines.yml, printed as KEY=value lines: the harness image on GHCR
# (own), the official container it comes from, and how it is made. Nothing is
# printed unless every input and every value read is valid, so the output is
# safe for $GITHUB_ENV.
#
# kind sdk: the SDK image <arch>-<sdk_tag_suffix>, built from the official SDK
# container (mode build).
# kind ib: the Image Builder image <target>-<subtarget>-<imagebuilder_tag_suffix>.
# A "releases" line mirrors the official container of its latest release (mode
# mirror: the release container has the Image Builder in it, RUN_SETUP=1 in
# openwrt/docker); a "snapshot" line builds it from the official snapshot
# container, which ships only setup.sh (mode build).
#
# Usage:
#   scripts/resolve-refresh.sh sdk <line> <arch> >> "$GITHUB_ENV"
#   scripts/resolve-refresh.sh ib <line> <target> <subtarget> >> "$GITHUB_ENV"
#
# Environment variables:
#   HARNESS_DIR                 directory with lines.yml (default: <repo>/harness)
#   HARNESS_SDK_CONTAINER       harness SDK image repository (kind sdk),
#                               ghcr.io/<owner>/openwrt-sdk
#   HARNESS_IB_CONTAINER        harness Image Builder image repository (kind
#                               ib), ghcr.io/<owner>/openwrt-imagebuilder
#   HARNESS_IB_BASE_CONTAINER   official Image Builder repository (default:
#                               docker.io/openwrt/imagebuilder)

set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "${script_dir}/lib/common.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/image-inputs.sh
. "${script_dir}/lib/image-inputs.sh"

[ "$#" -ge 1 ] || die "usage: resolve-refresh.sh sdk <line> <arch> | ib <line> <target> <subtarget>"
kind=$1
case "${kind}" in
sdk)
	[ "$#" -eq 3 ] || die "usage: resolve-refresh.sh sdk <line> <arch>"
	# resolve-sdk.sh validates the line and the arch and has the one rule of
	# the SDK names; its lines are read back by key.
	sdk_out=$("${script_dir}/resolve-sdk.sh" "$2" "$3") || die "cannot resolve the SDK image"
	sdk_get() {
		printf '%s\n' "${sdk_out}" | sed -n -e "s/^$1=//p"
	}
	printf 'HARNESS_IMG_KIND=sdk\n'
	printf 'HARNESS_IMG_MODE=build\n'
	printf 'HARNESS_IMG_CONTAINER=%s\n' "$(sdk_get HARNESS_SDK_CONTAINER)"
	printf 'HARNESS_IMG_TAG=%s\n' "$(sdk_get HARNESS_SDK_ARCH)"
	printf 'HARNESS_IMG_IMAGE=%s\n' "$(sdk_get HARNESS_SDK_IMAGE)"
	printf 'HARNESS_IMG_BASE=%s\n' "$(sdk_get HARNESS_SDK_BASE_IMAGE)"
	printf 'HARNESS_IMG_DOCKERFILE=docker/sdk-image\n'
	printf 'HARNESS_IMG_RELEASE=\n'
	;;
ib)
	[ "$#" -eq 4 ] || die "usage: resolve-refresh.sh ib <line> <target> <subtarget>"
	LINE=$2
	export LINE
	check_line "${LINE}"
	target=$3
	subtarget=$4
	harness_dir=${HARNESS_DIR:-${script_dir}/../harness}
	lines_file=${harness_dir}/lines.yml
	container=$(printf '%s\n' "${HARNESS_IB_CONTAINER:?HARNESS_IB_CONTAINER is required}" | tr '[:upper:]' '[:lower:]') ||
		die "cannot normalise the Image Builder container"
	check_sdk_container "${container}"
	base_container=${HARNESS_IB_BASE_CONTAINER:-docker.io/openwrt/imagebuilder}
	case "${base_container}" in
	*[!a-z0-9./_-]* | '') die "invalid base Image Builder container" ;;
	*) ;;
	esac
	line_key='.lines[strenv(LINE)]'
	release_source=$(yq_get "${lines_file}" "${line_key}.release_source")
	suffix=$(yq_get "${lines_file}" "${line_key}.imagebuilder_tag_suffix")
	tag=$(ib_tag "${target}" "${subtarget}" "${suffix}")
	check_sdk_tag "${tag}"
	case "${release_source}" in
	releases)
		index_url=$(yq_get "${lines_file}" "${line_key}.releases_index_url")
		release_regex=$(yq_get "${lines_file}" "${line_key}.release_regex")
		release=$(latest_release "${index_url}" "${release_regex}")
		check_charset "release" "${release}" '[!A-Za-z0-9._-]'
		mode=mirror
		dockerfile=
		base_tag=$(ib_tag "${target}" "${subtarget}" "${release}")
		;;
	snapshot)
		release=
		mode=build
		dockerfile=docker/ib-image
		base_tag=${tag}
		;;
	*) die "unsupported release_source of line ${LINE}" ;;
	esac
	printf 'HARNESS_IMG_KIND=ib\n'
	printf 'HARNESS_IMG_MODE=%s\n' "${mode}"
	printf 'HARNESS_IMG_CONTAINER=%s\n' "${container}"
	printf 'HARNESS_IMG_TAG=%s\n' "${tag}"
	printf 'HARNESS_IMG_IMAGE=%s:%s\n' "${container}" "${tag}"
	printf 'HARNESS_IMG_BASE=%s:%s\n' "${base_container}" "${base_tag}"
	printf 'HARNESS_IMG_DOCKERFILE=%s\n' "${dockerfile}"
	printf 'HARNESS_IMG_RELEASE=%s\n' "${release}"
	;;
*) die "unknown kind (allowed: sdk, ib)" ;;
esac
