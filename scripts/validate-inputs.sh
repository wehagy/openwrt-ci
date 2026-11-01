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
