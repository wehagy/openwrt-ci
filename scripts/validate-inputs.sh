#!/usr/bin/env sh
# Responsibility: validate the inputs of the reusable test workflow against
# strict patterns, before any of them is written to GITHUB_ENV, GITHUB_OUTPUT
# or used in a command. The values are never echoed: a value with a newline
# or a "::" prefix could otherwise forge workflow commands in the log.
#
# Usage:
#   scripts/validate-inputs.sh
#
# Environment variables:
#   HARNESS_PACKAGE  package name (see check_package_name in lib/common.sh)
#   HARNESS_LINE     OpenWrt line: "main" or NN.NN (e.g. 25.12)
#   HARNESS_SOURCE   package source: feed or artifact
#   HARNESS_TESTS_PATH   optional; directory of the caller repository with the
#                        package tests (see check_tests_path in lib/common.sh)
#   HARNESS_TEST_SECRETS optional; names of the caller secrets exported to the
#                        tests (see check_secret_names in lib/common.sh)
#   HARNESS_TARGETS      optional; QEMU test targets (syntax only here, see
#                        check_target_ids; scripts/matrix.sh checks the ids)
#   HARNESS_MEMORY_INPUT optional; VM memory (see check_vm_memory)
#   HARNESS_APK_TIMEOUT  optional; per-command timeout of the apk commands of
#                        the generic test (see check_apk_timeout)
#   HARNESS_SERVICES_DISABLED optional; init scripts the package leaves disabled
#                        by default, skipped by the service test (see
#                        check_service_names)

set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "${script_dir}/lib/common.sh"

package=${HARNESS_PACKAGE:?HARNESS_PACKAGE is required}
line=${HARNESS_LINE:?HARNESS_LINE is required}
source_kind=${HARNESS_SOURCE:?HARNESS_SOURCE is required}

check_package_name "${package}"
check_line "${line}"

case "${source_kind}" in
feed | artifact) ;;
*) die "invalid source input (allowed: feed or artifact)" ;;
esac

# Optional inputs: empty means "not used".
if [ -n "${HARNESS_TESTS_PATH:-}" ]; then
	check_tests_path "${HARNESS_TESTS_PATH}"
fi
if [ -n "${HARNESS_TEST_SECRETS:-}" ]; then
	check_secret_names "${HARNESS_TEST_SECRETS}"
fi
targets_blank=$(printf '%s' "${HARNESS_TARGETS:-}" | tr -d ' \n\t\r') || die "cannot read the targets"
if [ -n "${targets_blank}" ]; then
	check_target_ids "${HARNESS_TARGETS}"
fi
if [ -n "${HARNESS_MEMORY_INPUT:-}" ]; then
	check_vm_memory "${HARNESS_MEMORY_INPUT}"
fi
if [ -n "${HARNESS_APK_TIMEOUT:-}" ]; then
	check_apk_timeout "${HARNESS_APK_TIMEOUT}"
fi
services_blank=$(printf '%s' "${HARNESS_SERVICES_DISABLED:-}" | tr -d ' \n\t\r,') || die "cannot read the disabled services"
if [ -n "${services_blank}" ]; then
	check_service_names "${HARNESS_SERVICES_DISABLED}"
fi
