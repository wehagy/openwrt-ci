#!/usr/bin/env sh
# Responsibility: tell a run, with a warning annotation and never a failure,
# that the harness image it reads is stale. It compares the image with its
# upstream the way the refresh does: the sha256 of its archive with the one the
# sha256sums at the upstream address (a label) lists now, or, for a copy of a
# release container, the release it holds with the latest release. An image
# that differs is stale only once it is older than the grace period (the
# refresh runs daily, so a younger one is waiting for it, not late). It
# cannot decide with labels it does not find, or when the sha256sums cannot be
# downloaded: it then warns that it could not check. The sha256sums read here
# is not signature-checked; a wrong answer can only raise or hide a warning.
#
# Usage:
#   scripts/image-stale-check.sh <labels.json> <image>
#
# Environment variables:
#   HARNESS_STALE_DAYS    grace period, whole days (default: 1)
#   HARNESS_IB_RELEASE    latest release of a release line now (Image Builder
#                         images of such a line)
#   HARNESS_REFRESH_REPOSITORY     repository of the caller, in the refresh command
#   HARNESS_NOW           current time, Unix seconds (for tests; default: now)

set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "${script_dir}/lib/common.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/image-decide.sh
. "${script_dir}/lib/image-decide.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/sdk-labels.sh
. "${script_dir}/lib/sdk-labels.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/image-upstream.sh
. "${script_dir}/lib/image-upstream.sh"

[ "$#" -eq 2 ] || die "usage: image-stale-check.sh <labels.json> <image>"
labels=$1
image=$2
grace=${HARNESS_STALE_DAYS:-1}
now=${HARNESS_NOW:-$(date +%s)}
case "${grace}${now}${image}" in
*[!A-Za-z0-9._/:@-]* | '') die "invalid grace period, time or image name" ;;
*) ;;
esac

# Print the value of a label of the labels file; empty when absent.
#
# Arguments:
#   $1  label key
label() {
	jq -r --arg key "$1" '.[$key] // ""' "${labels}" || die "cannot read the labels"
}

created=$(label "${label_created}")
url=$(label "${label_upstream}")
archive=$(label "${label_archive}")
archive_sha=$(label "${label_archive_sha}")
release=$(label "${label_release}")

differs=
detail=
work=$(mktemp -d) || die "cannot create a temporary directory"
trap 'rm -rf "${work}"' EXIT
if [ -n "${url}" ] && [ -n "${archive_sha}" ] && [ -n "${archive}" ]; then
	case "${url}" in
	https://*) ;;
	*) die "the upstream address label of ${image} is not an https address" ;;
	esac
	if (upstream_fetch "${url}" "${work}/sha256sums"); then
		upstream_sha=$(upstream_sha_of "${work}/sha256sums" "${archive}")
		if [ -z "${upstream_sha}" ]; then
			differs=true
			detail="${archive} is no longer listed at ${url}"
		elif [ "${upstream_sha}" = "${archive_sha}" ]; then
			differs=false
		else
			differs=true
			detail="${archive} is ${upstream_sha} upstream, the image holds ${archive_sha}"
		fi
	else
		detail="could not download ${url}"
	fi
elif [ -n "${release}" ] && [ -n "${HARNESS_IB_RELEASE:-}" ]; then
	if [ "${release}" = "${HARNESS_IB_RELEASE}" ]; then
		differs=false
	else
		differs=true
		detail="the image holds release ${release}, the latest is ${HARNESS_IB_RELEASE}"
	fi
else
	detail="the image has no label to compare with upstream"
fi

out=$(image_stale_decide "${created}" "${now}" "${grace}" "${differs}")
state=${out%% *}
reason=${out#* }
case "${state}" in
fresh)
	printf 'image-stale-check: %s is fresh: %s\n' "${image}" "${reason}"
	;;
stale | unknown)
	[ -z "${detail}" ] || reason="${reason}; ${detail}"
	printf 'warn: %s is %s: %s\n' "${image}" "${state}" "${reason}" >&2
	printf '::warning title=Image %s::%s is %s: %s. The daily refresh updates it; by hand: %s\n' \
		"${state}" "${image}" "${state}" "${reason}" "$(refresh_command "${HARNESS_REFRESH_REPOSITORY:-<owner>/<repo>}")"
	;;
*) die "unexpected state of the freshness check" ;;
esac
