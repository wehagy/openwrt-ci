#!/usr/bin/env sh
# Responsibility: copy the pytest files of the harness and, optionally, of a
# directory of the calling repository into openwrt-tests/tests/ext, so they
# run in one pytest session. A caller file with the name of a harness file
# (conftest.py, harness_util.py, test_package.py) is an error, not an
# override.
#
# Usage:
#   scripts/install-tests.sh <ext-dir> [<caller-dir> <tests-path>]
#
# Arguments:
#   ext-dir      openwrt-tests/tests/ext (created if missing)
#   caller-dir   checkout of the calling repository
#   tests-path   directory of the caller repository with the package tests;
#                a missing directory means: only the generic test runs
#
# Environment variables: none.

set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "${script_dir}/lib/common.sh"

[ "$#" -eq 1 ] || [ "$#" -eq 3 ] || die "usage: install-tests.sh <ext-dir> [<caller-dir> <tests-path>]"
ext_dir=$1
mkdir -p "${ext_dir}"
for file in "${script_dir}"/../harness/tests/*.py; do
	cp "${file}" "${ext_dir}/"
	printf 'install-tests: harness test file: %s\n' "$(basename "${file}")"
done

[ "$#" -eq 3 ] || {
	printf 'install-tests: no tests path: only the generic test\n'
	exit 0
}
caller_dir=$2
tests_path=$3
check_tests_path "${tests_path}"
src=${caller_dir}/${tests_path}
if [ ! -d "${src}" ]; then
	printf '::notice::tests path %s does not exist in the caller repository: only the generic test runs\n' "${tests_path}"
	exit 0
fi
count=0
for file in "${src}"/*.py; do
	[ -f "${file}" ] || continue
	name=$(basename "${file}")
	[ ! -e "${ext_dir}/${name}" ] || die "caller test file ${name} has the name of a harness file"
	cp "${file}" "${ext_dir}/${name}"
	printf 'install-tests: caller test file: %s/%s\n' "${tests_path}" "${name}"
	count=$((count + 1))
done
[ "${count}" -gt 0 ] || printf '::notice::tests path %s has no *.py file: only the generic test runs\n' "${tests_path}"
