#!/usr/bin/env sh
# Responsibility: prove lib/ib-pins.sh with fixed text, no Image Builder: the
# composition of the PACKAGES list with the pinned built package (names with
# "-", removals, extra feed packages left unpinned), the reading of the apk
# metadata (version of the .apk, hash of the local index) and the check that
# the installed package is the local one and not a feed package of the same
# name and version, and the repair of the FormatPackages that leaks a pin.
# Runs in every image job.
#
# Usage:
#   scripts/ib-pins-selftest.sh
#
# Environment variables:
#   HARNESS_LIB_DIR  directory of lib/ib-pins.sh (default: lib/ next to this
#                    script); used to check that a broken copy fails this
#                    self-test

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
# shellcheck source=lib/ib-pins.sh
. "${lib_dir}/ib-pins.sh"

failures=0
checks=0
work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT

# Run a function of the library in a subshell: die exits it, not the
# self-test.
sub() {
	("$@")
}

# ---------------------------------------------------------------------------
# Composition of the package list.
# ---------------------------------------------------------------------------
# Run ib_pin_packages in a subshell and compare its stdout.
#
# Arguments:
#   $1  case name
#   $2  expected stdout, or FAIL for an exit code 1
#   $3  package list
#   $4  built package name
#   $5  built package version
pin_case() {
	if [ "$2" = FAIL ]; then
		script_case "pin: $1" 1 "" ib_pin_packages_sub "$3" "$4" "$5"
	else
		script_case "pin: $1" 0 "$2" ib_pin_packages_sub "$3" "$4" "$5"
	fi
}
ib_pin_packages_sub() {
	(ib_pin_packages "$@")
}

pin_case "bare name is replaced" "chrony=4.8-r3" "chrony" chrony 4.8-r3
pin_case "empty list" "chrony=4.8-r3" "" chrony 4.8-r3
pin_case "feed packages stay unpinned" "luci htop chrony=4.8-r3" "luci htop chrony" chrony 4.8-r3
pin_case "built package first in the list" "luci chrony=4.8-r3" "chrony luci" chrony 4.8-r3
pin_case "removals stay" "-dnsmasq dnsmasq-full chrony=4.8-r3" "-dnsmasq dnsmasq-full chrony" chrony 4.8-r3
pin_case "name with a dash" "kmod-tun netbird-ui=0.78.1-r1" "kmod-tun netbird-ui" netbird-ui 0.78.1-r1
pin_case "name that contains the built name" "netbird-ui kmod-netbird netbird=0.78.1-r1" \
	"netbird-ui kmod-netbird netbird" netbird 0.78.1-r1
pin_case "removal of a package that contains the built name" "-netbird-ui netbird=0.78.1-r1" \
	"-netbird-ui netbird" netbird 0.78.1-r1
pin_case "removal of the built package fails" FAIL "-chrony chrony" chrony 4.8-r3
pin_case "removal of the built package without the name fails" FAIL "-chrony" chrony 4.8-r3
pin_case "version with ~ and +" "foo=1.0~rc1+git-r2" "foo" foo "1.0~rc1+git-r2"
pin_case "empty version fails" FAIL "chrony" chrony ""
pin_case "bad version fails" FAIL "chrony" chrony "1 2"
pin_case "bad name fails" FAIL "chrony" "Chrony" 1.0-r1
pin_case "token with a version fails" FAIL "chrony=1.0-r1" chrony 4.8-r3

# ---------------------------------------------------------------------------
# apk metadata: info: block of the .apk, entry of the local index.
# ---------------------------------------------------------------------------
cat >"${work}/apk.dump" <<'DUMP'
#%SCHEMA: 676B6370
# ADB block, size: 1176, compat: 0, ver: 0
info:
  name: chrony
  version: 4.8-r3
  hashes: 1111111111111111111111111111111111111111
  description: A versatile implementation of NTP
  arch: x86_64
extra:
  license: GPL-2.0-or-later
paths: # 2 items
  - acl:
      mode: 0755
    files: # 1 items
      - name: chronyc
        hash: 2222222222222222222222222222222222222222222222222222222222222222
DUMP
field_case() {
	script_case "dump: $1" 0 "$2" sub adb_info_field "${work}/apk.dump" "$3"
}
field_case "name" chrony name
field_case "version, not the file hash" 4.8-r3 version
field_case "arch" x86_64 arch
field_case "absent field" "" license

# The local index: the entry for chrony is the one built here, hash H.
local_hash=87470e6a1f922a892716a1c76d62702fcaf1d903a9336e95074e7bc06b1eae85
cat >"${work}/index.dump" <<DUMP
#%SCHEMA: 78646E69
# ADB block, size: 1176, compat: 0, ver: 0
packages: # 5 items
  - name: chrony
    version: 4.8-r3
    hashes: ${local_hash}
    arch: x86_64
    depends: # 2 items
      - libc
      - libgcc
  - name: chrony
    version: 4.8-r2
    hashes: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    arch: x86_64
  - name: chrony-nts
    version: 4.8-r3
    hashes: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
    arch: x86_64
  - name: chrony-ui
    version: 4.8-r3
    hashes: dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
    arch: x86_64
  - name: tail
    version: 1
    hashes: cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
DUMP
index_case() {
	script_case "index: $1" 0 "$2" sub adb_index_hash "${work}/index.dump" "$3" "$4"
}
index_case "name and version" "${local_hash}" chrony 4.8-r3
index_case "other version of the name" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" chrony 4.8-r2
index_case "name that starts with the name" "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" chrony-nts 4.8-r3
index_case "last entry" "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc" tail 1
index_case "absent entry" "" chrony 9.9-r1
index_case "prefix of the name is not the name" "" chron 4.8-r3

# ---------------------------------------------------------------------------
# Installed database: the checksum is Q1 + base64 of the first 20 bytes of
# the sha256 of the index entry. local_c is the one for local_hash, feed_c
# the one of the package of the feed (another build of the same version).
# ---------------------------------------------------------------------------
local_c=h0cOah+SKoknFqHHbWJwL8rx2QM=
feed_c=WcaXbNgoDLiKQt3UeHGPhhiX4P0=
# Write an installed database with a chrony record of the given checksum.
#
# Arguments:
#   $1  file to write
#   $2  checksum of chrony (after C:Q1)
write_db() {
	cat >"$1" <<DB
C:Q1AAAAAAAAAAAAAAAAAAAAAAAAAAA=
P:busybox
V:1.37.0-r1
A:x86_64

C:Q1$2
P:chrony
V:4.8-r3
A:x86_64
F:usr/sbin
R:chronyd
Z:Q1xxxxxxxxxxxxxxxxxxxxxxxxxxx=

C:Q1BBBBBBBBBBBBBBBBBBBBBBBBBBB=
P:chrony-nts
V:4.8-r3
A:x86_64

DB
}
write_db "${work}/db-local" "${local_c}"
write_db "${work}/db-feed" "${feed_c}"
script_case "installed: checksum as hex" 0 "87470e6a1f922a892716a1c76d62702fcaf1d903" \
	installed_checksum_hex "${work}/db-local" chrony
script_case "installed: other build of the same version" 0 "59c6976cd8280cb88a42ddd478718f861897e0fd" \
	installed_checksum_hex "${work}/db-feed" chrony
script_case "installed: absent package" 0 "" sub installed_checksum_hex "${work}/db-local" chrony-ui
script_case "installed: prefix of a name is not the name" 0 "" sub installed_checksum_hex "${work}/db-local" chron

installed_record "${work}/db-local" chrony >"${work}/record"
record_names=$(grep -c '^P:' "${work}/record") || record_names=0
record_text=$(cat "${work}/record")
if [ "${record_names}" -eq 1 ] && grep -Fxq 'P:chrony' "${work}/record" &&
	grep -Fxq "C:Q1${local_c}" "${work}/record"; then
	record "installed: record of one package" 0 ""
else
	record "installed: record of one package" 1 "${record_text}"
fi
script_case "installed: record keeps the checksum" 0 "87470e6a1f922a892716a1c76d62702fcaf1d903" \
	installed_checksum_hex "${work}/record" chrony

# The check: local index against what the image holds.
check_sub() {
	(ib_check_installed_is_local "$@")
}
script_case "check: installed apk is the local one" 0 "" \
	check_sub "${work}/index.dump" "${work}/db-local" chrony 4.8-r3
case "${sc_err}" in
*"installed from the local apk"*) record "check: says where the apk came from" 0 "" ;;
*) record "check: says where the apk came from" 1 "${sc_err}" ;;
esac
script_case "check: same version from the feed fails" 1 "" \
	check_sub "${work}/index.dump" "${work}/db-feed" chrony 4.8-r3
case "${sc_err}" in
*"not the locally built apk"*) record "check: names the cause" 0 "" ;;
*) record "check: names the cause" 1 "${sc_err}" ;;
esac
script_case "check: package missing in the image fails" 1 "" \
	check_sub "${work}/index.dump" "${work}/db-local" chrony-ui 4.8-r3
case "${sc_err}" in
*"not in the installed database"*) record "check: missing package is named" 0 "" ;;
*) record "check: missing package is named" 1 "${sc_err}" ;;
esac
script_case "check: version missing in the local index fails" 1 "" \
	check_sub "${work}/index.dump" "${work}/db-local" chrony 9.9-r1
script_case "check: the record of the other version does not count" 1 "" \
	check_sub "${work}/index.dump" "${work}/db-local" chrony 4.8-r2

# ---------------------------------------------------------------------------
# FormatPackages: the released Image Builders keep the last pin for every
# package after it.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016 # Makefile text, nothing to expand
buggy='  $(if $(findstring =,$(pkg)),$(eval pkg_ver:==$(lastword $(subst =, ,$(pkg)))))'
# shellcheck disable=SC2016 # Makefile text, nothing to expand
fixed='  $(eval pkg_ver:=$(if $(findstring =,$(pkg)),=$(lastword $(subst =, ,$(pkg)))))'
# Write a Makefile fragment.
#
# Arguments:
#   $1  file to write
#   $2  the line that sets pkg_ver
write_makefile() {
	cat >"$1" <<MK
all:
	@echo ok

define FormatPackages
\$(strip \$(foreach pkg,\$(strip \$(subst ",,\$(1))),
  \$(eval pkg_name:=\$(firstword \$(subst =, ,\$(pkg))))
$2
  \$(pkg_name)\$(call GetABISuffix,\$(pkg_name))\$(pkg_ver)
))
endef
MK
}
fix_sub() {
	(ib_fix_format_packages "$@")
}
write_makefile "${work}/Makefile.buggy" "${buggy}"
write_makefile "${work}/Makefile.fixed" "${fixed}"
# shellcheck disable=SC2016 # Makefile text, nothing to expand
write_makefile "${work}/Makefile.other" '  $(eval pkg_ver:=whatever)'
printf 'all:\n\t@echo ok\n' >"${work}/Makefile.none"
cp "${work}/Makefile.fixed" "${work}/expected"

script_case "makefile: released form is repaired" 0 "" fix_sub "${work}/Makefile.buggy"
if cmp -s "${work}/Makefile.buggy" "${work}/expected"; then
	record "makefile: repaired file is the fixed one" 0 ""
else
	record "makefile: repaired file is the fixed one" 1 "differs from the fixed form"
fi
script_case "makefile: repeating the repair changes nothing" 0 "" fix_sub "${work}/Makefile.buggy"
if cmp -s "${work}/Makefile.buggy" "${work}/expected"; then
	record "makefile: second repair keeps the file" 0 ""
else
	record "makefile: second repair keeps the file" 1 "changed"
fi
script_case "makefile: fixed form is left alone" 0 "" fix_sub "${work}/Makefile.fixed"
if cmp -s "${work}/Makefile.fixed" "${work}/expected"; then
	record "makefile: fixed file is unchanged" 0 ""
else
	record "makefile: fixed file is unchanged" 1 "changed"
fi
script_case "makefile: unknown form is refused" 1 "" fix_sub "${work}/Makefile.other"
script_case "makefile: no FormatPackages is refused" 1 "" fix_sub "${work}/Makefile.none"

printf '%s checks, %s failures\n' "${checks}" "${failures}"
[ "${failures}" -eq 0 ]
