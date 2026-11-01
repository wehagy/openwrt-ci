#!/usr/bin/env sh
# Responsibility: create the CI copy of an openwrt-tests target file with
# KVM and the VM memory applied, next to the original (its relative imports
# must keep resolving), and print its path.
#
# labgrid's QEMUDriver never adds -enable-kvm, so it goes into extra_args.
#
# Usage:
#   scripts/prepare-target.sh [openwrt-tests-dir] >> "$GITHUB_ENV"
#
# Environment variables:
#   HARNESS_LG_ENV  target file name in openwrt-tests/targets (required)
#   HARNESS_MEMORY  VM memory, e.g. 256M (required)
#   HARNESS_KVM     "true" to add -enable-kvm (required)

set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "${script_dir}/lib/common.sh"

tests_dir=${1:-openwrt-tests}
lg_env=${HARNESS_LG_ENV:?HARNESS_LG_ENV is required}
memory=${HARNESS_MEMORY:?HARNESS_MEMORY is required}
kvm=${HARNESS_KVM:?HARNESS_KVM is required}

src=${tests_dir}/targets/${lg_env}
dst=${tests_dir}/targets/ci-${lg_env}
[ -f "${src}" ] || die "no such target file: ${src}"

cp "${src}" "${dst}"
sed -i -e "s|memory: [0-9][0-9]*[MG]|memory: ${memory}|" "${dst}"
grep -q "memory: ${memory}\$" "${dst}" || die "memory not applied in ${dst}"

if [ "${kvm}" = true ]; then
	sed -i -e 's|extra_args: "|extra_args: "-enable-kvm |' "${dst}"
	grep -q 'extra_args: "-enable-kvm ' "${dst}" || die "kvm not applied in ${dst}"
fi

printf 'HARNESS_LG_ENV_FILE=%s\n' "${dst}"
