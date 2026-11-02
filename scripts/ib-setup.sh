#!/usr/bin/env sh
# Responsibility: run the setup.sh of an Image Builder snapshot container (it
# downloads sha256sums, its signature and the Image Builder archive from the
# mirror and verifies the archive) and repeat it when, and only when, the
# archive does not match the sha256sums.
#
# Why: a snapshot directory is published file by file. In workflow runs
# 41427929552 (buffalo-wzr-hp-g450h) and 41427983225 (tplink-archer-c7-v4) the
# sha256sums served at 10:38-10:39 was signed on 2026-11-01 09:01 and listed
# c732955d..., while the archive had been republished at 10:33:36 and the
# sha256sums only at 10:38:33; setup.sh failed after a 8-15 minute download
# with "sha256sum: WARNING: 1 computed checksum did NOT match". Fetched again,
# the pair is consistent (run 41446811960 verified the same archive). Each
# attempt downloads sha256sums again, so a republished pair is picked up.
#
# Fail-closed: every attempt is verified by setup.sh itself; any other failure
# (network, signature, no matching file) is not retried; a mismatch that
# persists for all attempts fails the job. Each retry prints a `warn:` line.
#
# setup.sh deletes the keys directory after importing it and leaves its
# partial downloads in the working directory, so before a retry the keys are
# restored from a copy and the leftovers are removed (wget would otherwise
# save the archive as <name>.1).
#
# Usage:
#   TARGET=<target>/<subtarget> scripts/ib-setup.sh
#
# Environment variables:
#   HARNESS_IB_SETUP_ATTEMPTS  attempts, 1 to 5 (default: 3)
#   HARNESS_IB_SETUP_WAIT      seconds to wait before a retry, 0 to 900
#                              (default: 120; the mirror finishes publishing
#                              sha256sums minutes after the archive)
#   HARNESS_IB_SETUP_CMD       the command to run (default: ./setup.sh)
#   HARNESS_IB_KEYS_DIR        keys directory setup.sh consumes
#                              (default: /builder/keys)
#   plus the variables of the Image Builder setup.sh (TARGET, ...)

set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "${script_dir}/lib/common.sh"

attempts=${HARNESS_IB_SETUP_ATTEMPTS:-3}
wait_seconds=${HARNESS_IB_SETUP_WAIT:-120}
setup_cmd=${HARNESS_IB_SETUP_CMD:-./setup.sh}
keys_dir=${HARNESS_IB_KEYS_DIR:-/builder/keys}

case "${attempts}" in
[1-5]) ;;
*) die "HARNESS_IB_SETUP_ATTEMPTS must be 1 to 5, got '${attempts}'" ;;
esac
case "${wait_seconds}" in
'' | *[!0-9]* | ????*) die "HARNESS_IB_SETUP_WAIT must be 0 to 900, got '${wait_seconds}'" ;;
*) ;;
esac
[ "${wait_seconds}" -le 900 ] ||
	die "HARNESS_IB_SETUP_WAIT must be 0 to 900, got '${wait_seconds}'"

work=$(mktemp -d) || die "cannot create a temporary directory"
trap 'rm -rf "${work}"' EXIT
log=${work}/setup.log
status_file=${work}/setup.rc

# setup.sh removes the keys after the first import; keep a copy for retries.
if [ -d "${keys_dir}" ]; then
	cp -R "${keys_dir}" "${work}/keys" || die "cannot copy ${keys_dir}"
fi

attempt=1
while :; do
	rm -f "${status_file}"
	{
		"${setup_cmd}" 2>&1 || echo "$?" >"${status_file}"
	} | tee "${log}"
	if [ ! -f "${status_file}" ]; then
		[ "${attempt}" -eq 1 ] ||
			printf 'ib-setup: setup succeeded on attempt %s of %s\n' \
				"${attempt}" "${attempts}" >&2
		exit 0
	fi
	read -r status <"${status_file}"
	# sha256sum -c: "computed checksum did NOT match" (one file) or
	# "computed checksums did NOT match".
	if ! grep -q 'computed checksums\{0,1\} did NOT match' "${log}"; then
		die "${setup_cmd} failed with status ${status} (not a checksum mismatch, not retried)"
	fi
	[ "${attempt}" -lt "${attempts}" ] ||
		die "image builder archive did not match sha256sums in each of ${attempts} attempts"
	printf 'warn: image builder archive did not match sha256sums (attempt %s of %s), retrying in %s s\n' \
		"${attempt}" "${attempts}" "${wait_seconds}" >&2
	rm -f sha256sums sha256sums.asc sha256sums_min ./*.tar.*
	if [ -d "${work}/keys" ] && [ ! -d "${keys_dir}" ]; then
		cp -R "${work}/keys" "${keys_dir}" || die "cannot restore ${keys_dir}"
	fi
	sleep "${wait_seconds}"
	attempt=$((attempt + 1))
done
