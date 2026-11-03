#!/usr/bin/env sh
# Responsibility: prove lib/ib-pins.sh with fixed text, no Image Builder: the
# composition of the PACKAGES list with the path of the built .apk (names with
# "-", removals, extra feed packages left as they are), the reading of the apk
# metadata, the check that the installed package is the one apk installs
# from the built .apk and not a feed package of the same name and version, and
# the world of the image (the pin of the built package replaced by its name,
# every other entry untouched).
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
# Run ib_local_packages in a subshell and compare its stdout.
#
# Arguments:
#   $1  case name
#   $2  expected stdout, or FAIL for an exit code 1
#   $3  package list
#   $4  built package name
#   $5  absolute path of its .apk
pin_case() {
	if [ "$2" = FAIL ]; then
		script_case "pin: $1" 1 "" ib_local_packages_sub "$3" "$4" "$5"
	else
		script_case "pin: $1" 0 "$2" ib_local_packages_sub "$3" "$4" "$5"
	fi
}
ib_local_packages_sub() {
	(ib_local_packages "$@")
}

cb=/builder/packages/chrony-4.8-r3.apk
nb=/builder/packages/netbird-0.78.1-r1.apk
pin_case "bare name is replaced by the path" "${cb}" "chrony" chrony "${cb}"
pin_case "empty list" "${cb}" "" chrony "${cb}"
pin_case "feed packages stay as they are" "luci htop ${cb}" "luci htop chrony" chrony "${cb}"
pin_case "built package last in the list" "luci ${cb}" "chrony luci" chrony "${cb}"
pin_case "removals stay" "-dnsmasq dnsmasq-full ${cb}" "-dnsmasq dnsmasq-full chrony" chrony "${cb}"
pin_case "name with a dash" "kmod-tun ${nb}" "kmod-tun netbird-ui" netbird-ui "${nb}"
pin_case "name that contains the built name" "netbird-ui kmod-netbird ${nb}" \
	"netbird-ui kmod-netbird netbird" netbird "${nb}"
pin_case "removal of a package that contains the built name" "-netbird-ui ${nb}" \
	"-netbird-ui netbird" netbird "${nb}"
pin_case "removal of the built package fails" FAIL "-chrony chrony" chrony "${cb}"
pin_case "removal of the built package without the name fails" FAIL "-chrony" chrony "${cb}"
pin_case "path with ~ and +" "/b/foo-1.0~rc1+git-r2.apk" "foo" foo "/b/foo-1.0~rc1+git-r2.apk"
pin_case "relative path fails" FAIL "chrony" chrony "packages/chrony-4.8-r3.apk"
pin_case "empty path fails" FAIL "chrony" chrony ""
pin_case "path with a space fails" FAIL "chrony" chrony "/b/a b.apk"
pin_case "path that is not an .apk fails" FAIL "chrony" chrony "/b/chrony-4.8-r3.tar"
pin_case "bad name fails" FAIL "chrony" "Chrony" "${cb}"
pin_case "token with a version fails" FAIL "chrony=1.0-r1" chrony "${cb}"
pin_case "token with a path fails" FAIL "/tmp/evil.apk" chrony "${cb}"

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

# ---------------------------------------------------------------------------
# Installed database: the checksum is Q1 + base64 of 20 bytes. local_c is the
# one apk gives the built .apk, feed_c the one of the package of the feed
# (another build of the same version).
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

# The check: the record apk wrote for the built .apk in a scratch root
# (db-local) against what the image holds.
check_sub() {
	(ib_check_installed_is_local "$@")
}
write_db "${work}/db-other" "${local_c}"
script_case "check: installed apk is the local one" 0 "" \
	check_sub "${work}/db-local" "${work}/db-other" chrony
case "${sc_err}" in
*"installed from the local apk"*) record "check: says where the apk came from" 0 "" ;;
*) record "check: says where the apk came from" 1 "${sc_err}" ;;
esac
script_case "check: same version from the feed fails" 1 "" \
	check_sub "${work}/db-local" "${work}/db-feed" chrony
case "${sc_err}" in
*"not the locally built apk"*) record "check: names the cause" 0 "" ;;
*) record "check: names the cause" 1 "${sc_err}" ;;
esac
script_case "check: package missing in the image fails" 1 "" \
	check_sub "${work}/db-local" "${work}/db-local" chrony-ui
script_case "check: package missing in the scratch root fails" 1 "" \
	check_sub "${work}/db-other" "${work}/db-local" chrony-ui
case "${sc_err}" in
*"not in the installed database"*) record "check: missing package is named" 0 "" ;;
*) record "check: missing package is named" 1 "${sc_err}" ;;
esac
script_case "check: empty image database fails" 1 "" \
	check_sub "${work}/db-local" /dev/null chrony
case "${sc_err}" in
*"not in the installed database of the image"*) record "check: image side is named" 0 "" ;;
*) record "check: image side is named" 1 "${sc_err}" ;;
esac
script_case "check: empty scratch database fails" 1 "" \
	check_sub /dev/null "${work}/db-local" chrony
case "${sc_err}" in
*"not in the installed database of the scratch root"*) record "check: scratch side is named" 0 "" ;;
*) record "check: scratch side is named" 1 "${sc_err}" ;;
esac
# A checksum that differs only in its last bytes is another package.
write_db "${work}/db-tail" "h0cOah+SKoknFqHHbWJwL8ry2QM="
script_case "check: checksum differing at the end fails" 1 "" \
	check_sub "${work}/db-local" "${work}/db-tail" chrony
# A checksum of the wrong size is refused, even when both sides agree.
write_db "${work}/db-short" "AAAAAAAAAAAA"
script_case "check: short checksum fails" 1 "" \
	check_sub "${work}/db-short" "${work}/db-short" chrony

# ---------------------------------------------------------------------------
# World of the image: apk writes <name><><checksum> for a package installed
# from a file; the image must list <name> and nothing else changes.
# ---------------------------------------------------------------------------
cat >"${work}/world-pinned" <<'WORLD'
apk-mbedtls
base-files=1699~f505120278
chrony><Q1Cf33+0lydRENjGjfQh7edIIaO1U=
chrony-nts
htop
libc=1.2.5-r5
WORLD
cat >"${work}/world-plain" <<'WORLD'
apk-mbedtls
base-files=1699~f505120278
chrony
chrony-nts
htop
libc=1.2.5-r5
WORLD
plain_sub() {
	(ib_plain_world "$@")
}
plain_text=$(cat "${work}/world-plain")
script_case "world: the pin becomes the name, the rest stays" 0 "${plain_text}" \
	plain_sub "${work}/world-pinned" chrony
# The name of the official image world, and the same package under a longer name.
script_case "world: a pin of another package fails" 1 "" plain_sub "${work}/world-pinned" htop
script_case "world: a name that is a prefix of the pinned one fails" 1 "" \
	plain_sub "${work}/world-pinned" chron
sed -e 's/^chrony><.*/chrony/' "${work}/world-pinned" >"${work}/world-nopin"
script_case "world: no pin of the built package fails" 1 "" plain_sub "${work}/world-nopin" chrony
cat "${work}/world-pinned" "${work}/world-pinned" >"${work}/world-twice"
script_case "world: two pins fail" 1 "" plain_sub "${work}/world-twice" chrony
sed -e 's/^htop$/htop@local/' "${work}/world-pinned" >"${work}/world-tag"
script_case "world: another entry with a repository tag fails" 1 "" plain_sub "${work}/world-tag" chrony
sed -e 's|^htop$|/tmp/htop.apk|' "${work}/world-pinned" >"${work}/world-path"
script_case "world: another entry with a path fails" 1 "" plain_sub "${work}/world-path" chrony
sed -e 's/^htop$/htop><Q1AAAAAAAAAAAAAAAAAAAAAAAAAAA=/' "${work}/world-pinned" >"${work}/world-pin2"
script_case "world: another pin by checksum fails" 1 "" plain_sub "${work}/world-pin2" chrony
sed -e 's/^\(chrony><Q1\).*/\1/' "${work}/world-pinned" >"${work}/world-nosum"
script_case "world: a pin without checksum fails" 1 "" plain_sub "${work}/world-nosum" chrony
script_case "world: missing file fails" 1 "" plain_sub "${work}/world-none" chrony

world_sub() {
	(ib_check_world "$@")
}
script_case "world check: the image lists the name" 0 "" \
	world_sub "${work}/world-plain" "${work}/world-pinned" chrony
case "${sc_err}" in
*"lists chrony by name"*) record "world check: says what it found" 0 "" ;;
*) record "world check: says what it found" 1 "${sc_err}" ;;
esac
script_case "world check: the image keeps the pin" 1 "" \
	world_sub "${work}/world-pinned" "${work}/world-pinned" chrony
case "${sc_err}" in
*"not a plain name"*) record "world check: the pin is named as the cause" 0 "" ;;
*) record "world check: the pin is named as the cause" 1 "${sc_err}" ;;
esac
sed -e 's/^htop$//' "${work}/world-plain" >"${work}/world-lost"
script_case "world check: a package of the world lost fails" 1 "" \
	world_sub "${work}/world-lost" "${work}/world-pinned" chrony
grep -v '^htop$' "${work}/world-plain" >"${work}/world-short"
script_case "world check: an entry removed fails" 1 "" \
	world_sub "${work}/world-short" "${work}/world-pinned" chrony
sed -e '$a chrony-extra' "${work}/world-plain" >"${work}/world-more"
script_case "world check: an entry added fails" 1 "" \
	world_sub "${work}/world-more" "${work}/world-pinned" chrony
grep -v '^chrony$' "${work}/world-plain" >"${work}/world-noname"
script_case "world check: the package missing from the world fails" 1 "" \
	world_sub "${work}/world-noname" "${work}/world-pinned" chrony
sed -e 's/^chrony$/chrony@local/' "${work}/world-plain" >"${work}/world-imgtag"
script_case "world check: a repository tag on the name fails" 1 "" \
	world_sub "${work}/world-imgtag" "${work}/world-pinned" chrony
# Nothing to compare with must not pass because both sides are empty.
: >"${work}/world-empty"
script_case "world check: empty image world and missing install world fail" 1 "" \
	world_sub "${work}/world-empty" "${work}/world-none" chrony
script_case "world check: missing image world fails" 1 "" \
	world_sub "${work}/world-none" "${work}/world-pinned" chrony

printf '%s checks, %s failures\n' "${checks}" "${failures}"
[ "${failures}" -eq 0 ]
