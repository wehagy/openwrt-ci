#!/usr/bin/env sh
# Responsibility: prove the delete of a superseded SDK image version
# (lib/ghcr-versions.sh, ghcr_delete_version) with a stub gh that answers a
# chosen HTTP status: 204 and 404 succeed (404: already deleted by another
# run), 401, 403, 409, 500 and an unrelated message that merely contains
# "404" fail. Offline; runs in every SDK image job.
#
# Usage:
#   scripts/ghcr-versions-selftest.sh
#
# Environment variables:
#   HARNESS_LIB_DIR  directory of lib/ghcr-versions.sh (default: lib/ next to
#                    this script); used to check that a broken copy fails
#                    this self-test

set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
lib_dir=${HARNESS_LIB_DIR:-${script_dir}/lib}
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "${script_dir}/lib/common.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/selftest.sh
. "${script_dir}/lib/selftest.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/ghcr-versions.sh
. "${lib_dir}/ghcr-versions.sh"

failures=0
checks=0
work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT

# A gh that records its arguments and fails like the real one: a message
# and the exit code 1, with the text taken from STUB_GH_MESSAGE.
mkdir "${work}/bin"
cat >"${work}/bin/gh" <<'STUB'
#!/usr/bin/env sh
printf '%s\n' "$*" >"${STUB_GH_ARGS}"
if [ -n "${STUB_GH_MESSAGE}" ]; then
	printf '%s\n' "${STUB_GH_MESSAGE}" >&2
	exit 1
fi
exit 0
STUB
chmod +x "${work}/bin/gh"
export PATH="${work}/bin:${PATH}"
export STUB_GH_ARGS="${work}/args"

api=/users/wehagy/packages/container/openwrt-sdk

# Run ghcr_delete_version in a subshell: die exits it, not the self-test.
run_delete() {
	(ghcr_delete_version "${api}" 1485438139)
}

# Check the exit code, stdout and stderr of one run against the stub.
#
# Arguments:
#   $1  case name
#   $2  expected exit code
#   $3  expected stdout
#   $4  text the stderr must contain, or empty
#   $5  message the stub prints (empty: it succeeds)
delete_case() {
	STUB_GH_MESSAGE=$5
	export STUB_GH_MESSAGE
	script_case "$1" "$2" "$3" run_delete
	if [ -n "$4" ]; then
		case "${sc_err}" in
		*"$4"*) record "$1: stderr" 0 "" ;;
		*) record "$1: stderr" 1 "lacks '$4': ${sc_err}" ;;
		esac
	fi
}

delete_case "204 deleted" 0 deleted "" ""
expected_args="api -X DELETE ${api}/versions/1485438139"
got_args=$(cat "${work}/args")
if [ "${got_args}" = "${expected_args}" ]; then
	record "delete request" 0 ""
else
	record "delete request" 1 "got '${got_args}'"
fi
delete_case "404 already gone" 0 already-gone "already deleted by another run" \
	"gh: Package not found. (HTTP 404)"
delete_case "401 fails" 1 "" "cannot delete the version 1485438139" \
	"gh: Bad credentials (HTTP 401)"
delete_case "403 fails" 1 "" "cannot delete the version 1485438139" \
	"gh: You need admin access to the package (HTTP 403)"
delete_case "409 fails" 1 "" "cannot delete the version 1485438139" \
	"gh: Conflict (HTTP 409)"
delete_case "500 fails" 1 "" "cannot delete the version 1485438139" \
	"gh: Server Error (HTTP 500)"
delete_case "4040 is not a 404" 1 "" "cannot delete the version" \
	"gh: odd (HTTP 4040)"
delete_case "404 in a message is not a 404" 1 "" "cannot delete the version" \
	"gh: could not resolve host 404.example (connection refused)"
delete_case "failure without a message fails" 1 "" "cannot delete the version" \
	"gh: error"

printf '%s checks, %s failures\n' "${checks}" "${failures}"
[ "${failures}" -eq 0 ]
