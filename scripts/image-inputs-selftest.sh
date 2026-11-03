#!/usr/bin/env sh
# Responsibility: prove, with fixed inputs and a fake mirror (file:// URLs, no
# network), the code that handles the image inputs of the base: the validators
# of lib/image-inputs.sh (profiles, packages, architectures), the profile id,
# scripts/resolve-profiles.sh (profiles.json lookup: line, target, profile and
# architecture, nothing printed on any failure), scripts/resolve-archs.sh
# (@tests, @profiles, literal architectures, limits), scripts/resolve-image.sh
# (package list, artifact name, with and without a package of our own) and the
# manifest check of scripts/collect-images.sh (added and removed packages).
# Every case runs; the script exits 1 after the last one if any failed. Runs in
# the profiles job of images.yml and the feed job of build.yml. Needs yq, jq
# and curl.
#
# Usage:
#   scripts/image-inputs-selftest.sh
#
# Environment variables: none.

set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "${script_dir}/lib/common.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/image-inputs.sh
. "${script_dir}/lib/image-inputs.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/selftest.sh
. "${script_dir}/lib/selftest.sh"

work=$(mktemp -d) || die "cannot create a temporary directory"
trap 'rm -rf "${work}"' EXIT
failures=0
checks=0

# Run a function that sets globals (parse_profile_token) in a subshell and
# compare the values it set.
#
# Arguments:
#   $1  case name
#   $2  token
#   $3  expected "<target> <subtarget> <device> <expect>"
parse_case() {
	set +e
	pc_got=$(
		parse_profile_token "$2" >/dev/null 2>&1
		printf '%s %s %s %s' "${pt_target}" "${pt_subtarget}" "${pt_device}" "${pt_expect}"
	)
	pc_rc=$?
	set -e
	[ "${pc_rc}" -eq 0 ] || pc_got="rejected"
	if [ "${pc_got}" = "$3" ]; then
		record "$1" 0 ""
	else
		record "$1" 1 "got '${pc_got}', expected '$3'"
	fi
}

# --- parse_profile_token ---------------------------------------------------

parse_case "profile token" "mediatek/filogic/bananapi_bpi-r3" "mediatek filogic bananapi_bpi-r3 fits"
parse_case "profile token too-big" "ath79/generic/tplink_archer-c7-v4:too-big" "ath79 generic tplink_archer-c7-v4 too-big"
parse_case "profile token uppercase device" "x86/64/Generic_X" "x86 64 Generic_X fits"
for t in '' a a/b a/b/ /a/b a//b a/b/c/d 'a/b/c:' 'a/b/c:fits' 'a/b/c:too-big:too-big' \
	'a/b/c:too-bigx' 'A/b/c' 'a/B/c' 'a_b/c/d' 'a/b-c/d' 'a/b/c d' 'a/b/c;id' "a/b/c\$(id)" \
	'a/b/c*' 'a/b/.' 'a/b/..' 'a/b/c.d' '../b/c' 'a/b/c::error::x' '-a/b/c' 'é/b/c'; do
	parse_case "profile token rejects '${t}'" "${t}" "rejected"
done
parse_case "profile token rejects a newline" "a/b/c
x/y/z" "rejected"
n33=
i=0
while [ "${i}" -lt 33 ]; do
	n33=${n33}a
	i=$((i + 1))
done
parse_case "profile token rejects a 33 char target" "${n33}/b/c" "rejected"
parse_case "profile token rejects a 33 char subtarget" "a/${n33}/c" "rejected"
n65=${n33}${n33}a
parse_case "profile token rejects a 65 char profile" "a/b/${n65}" "rejected"

# --- profile_id ------------------------------------------------------------

id_case() {
	idc_got=$(profile_id "$1" "$2" "$3")
	if [ "${idc_got}" = "$4" ]; then
		record "profile_id $3" 0 ""
	else
		record "profile_id $3" 1 "got '${idc_got}', expected '$4'"
	fi
}
id_case x86 64 generic x86-64-generic
id_case mediatek filogic bananapi_bpi-r3 bananapi-bpi-r3
id_case ath79 generic tplink_archer-c7-v4 tplink-archer-c7-v4
id_case ath79 generic Buffalo_WZR-HP-G450H buffalo-wzr-hp-g450h
id_case ipq40xx generic glinet_gl-b1300 glinet-gl-b1300

# profile_tokens prints the tokens it accepted; the validator cases look at
# the exit code only.
check_profile_list() {
	profile_tokens "$1" >/dev/null
}

# --- profile_tokens --------------------------------------------------------

validator_case check_profile_list accept "x86/64/generic" "one"
validator_case check_profile_list accept "x86/64/generic
mediatek/filogic/bananapi_bpi-r3   ath79/generic/buffalo_wzr-hp-g450h" "newline and spaces"
validator_case check_profile_list reject "" "empty"
validator_case check_profile_list reject "   " "blank"
validator_case check_profile_list reject "x86/64/generic;id" "semicolon"
validator_case check_profile_list reject "x86/64/generic
::error::x" "workflow command"
list16=
list17=
i=0
while [ "${i}" -lt 17 ]; do
	[ "${i}" -ge 16 ] || list16="${list16} t${i}/s/p${i}"
	list17="${list17} t${i}/s/p${i}"
	i=$((i + 1))
done
validator_case check_profile_list accept "${list16}" "16 profiles"
validator_case check_profile_list reject "${list17}" "17 profiles"

# --- check_image_packages --------------------------------------------------

validator_case check_image_packages accept "" "empty"
validator_case check_image_packages accept "owut luci-ssl" "two"
validator_case check_image_packages accept "-dnsmasq dnsmasq-full" "removal and addition"
validator_case check_image_packages accept "luci-app-uhttpd
-dnsmasq
	dnsmasq-full" "newlines and tab"
validator_case check_image_packages accept "libstdcpp6 kmod-usb3 python3-yaml libc++1" "name chars"
for p in '--dnsmasq' '-' 'a b;c' 'Owut' '-Owut' '+x' '.x' '_x' "x\$(id)" "x\`id\`" 'x*' 'x?' 'x[a]' \
	"x'y" 'x"y' 'x\y' 'é' 'x:y' 'x/y' 'x=y' 'x@y' 'x#y'; do
	validator_case check_image_packages reject "${p}" "'${p}'"
done
validator_case check_image_packages reject "owut
::error::x" "workflow command"
list100=
list101=
i=0
while [ "${i}" -lt 101 ]; do
	[ "${i}" -ge 100 ] || list100="${list100} p${i}"
	list101="${list101} p${i}"
	i=$((i + 1))
done
validator_case check_image_packages accept "${list100}" "100 packages"
validator_case check_image_packages reject "${list101}" "101 packages"
long=
i=0
while [ "${i}" -lt 40 ]; do
	long="${long} abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmnopqrstuvwxyz"
	i=$((i + 1))
done
validator_case check_image_packages reject "${long}" "over 2048 chars"
pl=$(image_packages_line "  -dnsmasq
 dnsmasq-full  owut ")
if [ "${pl}" = "-dnsmasq dnsmasq-full owut" ]; then
	record "image_packages_line joins with single spaces" 0 ""
else
	record "image_packages_line joins with single spaces" 1 "got '${pl}'"
fi

# --- check_vm_memory and check_target_ids ------------------------------------

for m in 64M 128M 256M 1000M 1024M; do
	validator_case check_vm_memory accept "${m}" "'${m}'"
done
for m in '' 0 M 63M 1025M 2048M 99999M 128 128m 128G 128MB 128MM 0128M 064M 12.8M ' 128M' '128M ' -128M +128M \
	'128M;id' "128M\$(id)" 'M128' '1e2M'; do
	validator_case check_vm_memory reject "${m}" "'${m}'"
done
validator_case check_vm_memory reject "128M
::error::x" "workflow command"

validator_case check_target_ids accept "x86-64" "one"
validator_case check_target_ids accept "x86-64 malta-le
armsr-armv8" "spaces and newline"
for t in '' '  ' -x 'X86' 'x_y' 'x;y' 'x.y' 'x/y' "x\$(id)" 'é'; do
	validator_case check_target_ids reject "${t}" "'${t}'"
done
validator_case check_target_ids reject "x86-64
::error::x" "workflow command"
validator_case check_target_ids reject "${n33}" "33 char id"
ids17=
i=0
while [ "${i}" -lt 17 ]; do
	ids17="${ids17} t${i}"
	i=$((i + 1))
done
validator_case check_target_ids reject "${ids17}" "17 ids"

# --- check_apk_timeout and the summary line -----------------------------------

for t in 30 120 600; do
	validator_case check_apk_timeout accept "${t}" "'${t}'"
done
for t in '' 0 29 601 1000 9999 030 -30 +30 30s 1.5 ' 30' '30 ' '3e2' "1\$(id)"; do
	validator_case check_apk_timeout reject "${t}" "'${t}'"
done
validator_case check_apk_timeout reject "120
::error::x" "workflow command"

# --- check_service_names and the summary line --------------------------------

sv64=${n33}${n33%aa}
sv65=${sv64}a
for t in socat 'socat ssh-agent' 'a,b' 'a, b' 'a.b_c-d' 'a
b' 'S1' 0a "${sv64}"; do
	validator_case check_service_names accept "${t}" "'${t}'"
done
for t in '' ' ' -x _x .x 'a/b' '../x' 'a;b' 'a b;' 'é' "x\$(id)" 'a|b' "${sv65}"; do
	validator_case check_service_names reject "${t}" "'${t}'"
done
validator_case check_service_names reject "socat
::error::x" "workflow command"
sv17=
i=0
while [ "${i}" -lt 17 ]; do
	sv17="${sv17} s${i}"
	i=$((i + 1))
done
validator_case check_service_names reject "${sv17}" "17 names"

printf '<testsuite><testcase classname="t" name="test_a" time="1.0"/></testsuite>' >"${work}/results.xml"
summary_env() {
	env HARNESS_LINE=25.12 HARNESS_TARGET=x86-64 HARNESS_RELEASE=25.12.6 HARNESS_KVM=true \
		HARNESS_MEMORY=128M HARNESS_IMAGE_URL=u HARNESS_IMAGE_SHA256=s HARNESS_IMAGE_DATE=d \
		HARNESS_PACKAGE=chrony HARNESS_PACKAGE_VERSION=4.9-r1 "$@" \
		"${script_dir}/summary.sh" "${work}/results.xml" 0 5
}
script_case "summary without apk_timeout" 0 ANY summary_env
if grep -qxF -- '- apk command timeout: none (labgrid default; apk_timeout not set by the caller)' "${work}/out"; then
	record "summary says labgrid default when apk_timeout is not set" 0 ""
else
	record "summary says labgrid default when apk_timeout is not set" 1 "${sc_out}"
fi
script_case "summary with apk_timeout" 0 ANY summary_env HARNESS_APK_TIMEOUT=120
if grep -qxF -- '- apk command timeout: 120 s (apk_timeout input of the caller)' "${work}/out"; then
	record "summary says 120 s from the caller" 0 ""
else
	record "summary says 120 s from the caller" 1 "${sc_out}"
fi

script_case "summary without services_disabled" 0 ANY summary_env
if grep -q 'services disabled' "${work}/out"; then
	record "summary has no services line when none is disabled" 1 "${sc_out}"
else
	record "summary has no services line when none is disabled" 0 ""
fi
script_case "summary with services_disabled" 0 ANY summary_env HARNESS_SERVICES_DISABLED=socat
if grep -qxF -- '- services disabled by default, not checked: socat (services_disabled input of the caller)' "${work}/out"; then
	record "summary names the services not checked" 0 ""
else
	record "summary names the services not checked" 1 "${sc_out}"
fi

# A services_disabled name that the package does not install: a warning
# annotation and a summary line, exit 0 (not a failure).
printf '<testsuite><testcase classname="t" name="test_a" time="1.0"><properties><property name="services_disabled_unknown" value="sokat netbirdd"/></properties></testcase></testsuite>' >"${work}/results.xml"
script_case "summary with an unknown disabled service still exits 0" 0 ANY summary_env
if grep -qxF -- '- WARNING: services_disabled names sokat netbirdd, but the package does not install them: not checked (typo, or a renamed or line-specific script?)' "${work}/out"; then
	record "summary names the unknown disabled services" 0 ""
else
	record "summary names the unknown disabled services" 1 "${sc_out}"
fi
if grep -qxF -- '::warning title=services_disabled names a script the package does not install::sokat netbirdd (typo, or a renamed or line-specific init script?)' "${work}/err"; then
	record "summary annotates the unknown disabled services (stderr)" 0 ""
else
	record "summary annotates the unknown disabled services (stderr)" 1 "${sc_err}"
fi
printf '<testsuite><testcase classname="t" name="test_a" time="1.0"><properties><property name="services_disabled_unknown" value="x::error::y"/></properties></testcase></testsuite>' >"${work}/results.xml"
script_case "summary with a forged unknown name still exits 0" 0 ANY summary_env
if grep -q 'x::error::y' "${work}/err"; then
	record "summary does not pass a forged name to a workflow command" 1 "${sc_err}"
else
	record "summary does not pass a forged name to a workflow command" 0 ""
fi
printf '<testsuite><testcase classname="t" name="test_a" time="1.0"/></testsuite>' >"${work}/results.xml"
script_case "summary without an unknown disabled service" 0 ANY summary_env
if grep -q 'WARNING\|::warning' "${work}/out" "${work}/err"; then
	record "summary has no warning when no name is unknown" 1 "${sc_out}${sc_err}"
else
	record "summary has no warning when no name is unknown" 0 ""
fi

# --- check_arch_token ------------------------------------------------------

for a in x86_64 aarch64_cortex-a53 arm_cortex-a7_neon-vfpv4 @tests @profiles 0x; do
	validator_case check_arch_token accept "${a}" "'${a}'"
done
for a in '' @ @all @tests2 -x _x X86 'x y' 'x;y' 'x.y' 'x/y' 'é' '@@tests'; do
	validator_case check_arch_token reject "${a}" "'${a}'"
done
validator_case check_arch_token reject "${n65}" "65 chars"

# ---------------------------------------------------------------------------
# A fake mirror: lines.yml, images.yml, targets.yml and profiles.json files
# below file:// URLs. Release 25.12.6 and a snapshot differ on purpose: a
# profile that exists only in one of them proves which directory is read.
# ---------------------------------------------------------------------------
mirror=${work}/mirror
fixtures=${work}/harness
mkdir -p "${mirror}/releases/25.12.5" "${mirror}/releases/25.12.6" "${mirror}/releases/25.12.7-rc1" "${fixtures}"
printf '<a href="25.12.5/">25.12.5/</a>\n<a href="25.12.6/">25.12.6/</a>\n<a href="25.12.7-rc1/">25.12.7-rc1/</a>\n' >"${mirror}/releases/index.html"

# Arguments: $1 profiles.json path, $2 target/subtarget, $3 arch, $4... profile names
make_profiles() {
	mp_file=$1
	mp_target=$2
	mp_arch=$3
	shift 3
	mkdir -p "$(dirname "${mp_file}")"
	mp_obj='{}'
	for mp_name in "$@"; do
		mp_obj=$(printf '%s' "${mp_obj}" | jq -c --arg n "${mp_name}" '. + {($n): {}}')
	done
	jq -n -c --arg t "${mp_target}" --arg a "${mp_arch}" --argjson p "${mp_obj}" \
		'{target: $t, arch_packages: $a, profiles: $p}' >"${mp_file}"
}
rel=${mirror}/releases/25.12.6/targets
snap=${mirror}/snapshots/targets
make_profiles "${rel}/x86/64/profiles.json" x86/64 x86_64 generic
make_profiles "${snap}/x86/64/profiles.json" x86/64 x86_64 generic
make_profiles "${rel}/mediatek/filogic/profiles.json" mediatek/filogic aarch64_cortex-a53 bananapi_bpi-r3 acer_predator-w6x-stock
make_profiles "${snap}/mediatek/filogic/profiles.json" mediatek/filogic aarch64_cortex-a53 bananapi_bpi-r3 acer_predator-w6x-stock snapshot_only_board
make_profiles "${rel}/ath79/generic/profiles.json" ath79/generic mips_24kc tplink_archer-c7-v4 buffalo_wzr-hp-g450h
make_profiles "${rel}/ramips/mt7621/profiles.json" ramips/mt7621 mipsel_24kc glinet_gl-mt1300 totolink_x5000r
make_profiles "${rel}/ipq40xx/generic/profiles.json" ipq40xx/generic arm_cortex-a7_neon-vfpv4 glinet_gl-b1300 generic
make_profiles "${rel}/badarch/generic/profiles.json" badarch/generic 'bad arch' board
printf '{"target":"x/y","arch_packages":"x86_64"}\n' >"${rel}/noprofiles.json"
mkdir -p "${rel}/noobj/generic"
printf '{"target":"noobj/generic","arch_packages":"x86_64","profiles":[]}\n' >"${rel}/noobj/generic/profiles.json"
cat >"${fixtures}/lines.yml" <<EOF
lines:
  "25.12":
    imagebuilder_tag_suffix: openwrt-25.12
    release_source: releases
    releases_index_url: file://${mirror}/releases/index.html
    release_regex: '25\.12\.[0-9]+'
    image_base_url: file://${mirror}/releases/{release}/targets/{path}
    feed_base_url: file://${mirror}/releases/{release}/packages/{arch}/packages
  main:
    imagebuilder_tag_suffix: main
    release_source: snapshot
    snapshot_version_url: file://${mirror}/snapshots/targets/{path}/version.buildinfo
    image_base_url: file://${mirror}/snapshots/targets/{path}
    feed_base_url: file://${mirror}/snapshots/packages/{arch}/packages
EOF
cat >"${fixtures}/images.yml" <<'EOF'
image_globs: "*sysupgrade* *factory*"
EOF
cat >"${fixtures}/targets.yml" <<'EOF'
targets:
  x86-64:
    lg_env: qemu_x86-64.yaml
    arch: x86_64
    path: x86/64
    memory: 128M
    kvm: true
    qemu_pkg: qemu-system-x86
    images:
      "25.12": openwrt-{release}-x86-64-generic-squashfs-combined.img.gz
      main: openwrt-x86-64-generic-squashfs-combined.img.gz
  armsr-armv8:
    lg_env: qemu_armsr-armv8.yaml
    arch: aarch64_generic
    path: armsr/armv8
    memory: 128M
    kvm: false
    qemu_pkg: qemu-system-arm
    images:
      "25.12": openwrt-{release}-armsr-armv8-generic-initramfs-kernel.bin
      main: openwrt-armsr-armv8-generic-initramfs-kernel.bin
  malta-le:
    lg_env: qemu_malta-le.yaml
    arch: mipsel_24kc
    path: malta/le
    memory: 128M
    kvm: false
    qemu_pkg: qemu-system-mips
    images:
      "25.12": openwrt-{release}-malta-le-vmlinux-initramfs.elf
      main: openwrt-malta-le-generic-initramfs-kernel.bin
  malta-be:
    lg_env: qemu_malta-be.yaml
    arch: mips_24kc
    path: malta/be
    memory: 128M
    kvm: false
    qemu_pkg: qemu-system-mips
    images:
      "25.12": openwrt-{release}-malta-be-vmlinux-initramfs.elf
EOF
export HARNESS_DIR="${fixtures}"

rp=${script_dir}/resolve-profiles.sh
ra=${script_dir}/resolve-archs.sh
mx=${script_dir}/matrix.sh
rs=${script_dir}/resolve.sh
ri=${script_dir}/resolve-image.sh

# --- resolve-profiles.sh ---------------------------------------------------

export HARNESS_PROFILES=
script_case "resolve-profiles no profile means no image" 0 \
	'matrix={"include":[]}
archs=
count=0' "${rp}" 25.12
script_case "resolve-profiles no profile on main" 0 \
	'matrix={"include":[]}
archs=
count=0' "${rp}" main
HARNESS_PROFILES="  
"
script_case "resolve-profiles blank profiles mean no image" 0 \
	'matrix={"include":[]}
archs=
count=0' "${rp}" 25.12
HARNESS_PROFILES="x86/64/generic"
script_case "resolve-profiles one profile" 0 \
	'matrix={"include":[{"profile":"x86-64-generic","target":"x86","subtarget":"64","device":"generic","arch":"x86_64","expect":"fits"}]}
archs=x86_64
count=1' "${rp}" 25.12
HARNESS_PROFILES="mediatek/filogic/bananapi_bpi-r3 ath79/generic/tplink_archer-c7-v4:too-big
ramips/mt7621/glinet_gl-mt1300 ramips/mt7621/totolink_x5000r:too-big"
script_case "resolve-profiles several profiles" 0 \
	'matrix={"include":[{"profile":"bananapi-bpi-r3","target":"mediatek","subtarget":"filogic","device":"bananapi_bpi-r3","arch":"aarch64_cortex-a53","expect":"fits"},{"profile":"tplink-archer-c7-v4","target":"ath79","subtarget":"generic","device":"tplink_archer-c7-v4","arch":"mips_24kc","expect":"too-big"},{"profile":"glinet-gl-mt1300","target":"ramips","subtarget":"mt7621","device":"glinet_gl-mt1300","arch":"mipsel_24kc","expect":"fits"},{"profile":"totolink-x5000r","target":"ramips","subtarget":"mt7621","device":"totolink_x5000r","arch":"mipsel_24kc","expect":"too-big"}]}
archs=aarch64_cortex-a53 mips_24kc mipsel_24kc
count=4' "${rp}" 25.12
HARNESS_PROFILES="ipq40xx/generic/glinet_gl-b1300 ipq40xx/generic/generic"
script_case "resolve-profiles new architecture, generic of another target" 0 \
	'matrix={"include":[{"profile":"glinet-gl-b1300","target":"ipq40xx","subtarget":"generic","device":"glinet_gl-b1300","arch":"arm_cortex-a7_neon-vfpv4","expect":"fits"},{"profile":"ipq40xx-generic-generic","target":"ipq40xx","subtarget":"generic","device":"generic","arch":"arm_cortex-a7_neon-vfpv4","expect":"fits"}]}
archs=arm_cortex-a7_neon-vfpv4
count=2' "${rp}" 25.12
# The release directory is the latest non-rc release; the snapshot has a
# profile the release lacks.
HARNESS_PROFILES="mediatek/filogic/snapshot_only_board"
script_case "resolve-profiles snapshot line reads the snapshot directory" 0 ANY "${rp}" main
script_case "resolve-profiles releases line does not see a snapshot-only profile" 1 '' "${rp}" 25.12
if grep -q 'does not exist in mediatek/filogic' "${work}/err" && grep -q 'bananapi_bpi-r3' "${work}/err"; then
	record "resolve-profiles unknown profile names the target and the nearest profiles" 0 ""
else
	record "resolve-profiles unknown profile names the target and the nearest profiles" 1 "${sc_err}"
fi
HARNESS_PROFILES="ath79/generic/tplink_archer-c7-v4"
script_case "resolve-profiles ath79 only on the release" 1 '' "${rp}" main
if grep -q 'target ath79/generic does not exist on line main' "${work}/err"; then
	record "resolve-profiles unknown target names the target and the line" 0 ""
else
	record "resolve-profiles unknown target names the target and the line" 1 "${sc_err}"
fi
HARNESS_PROFILES="x86/64/generic mediatek/filogic/nope_board"
script_case "resolve-profiles one bad profile among good ones prints nothing" 1 '' "${rp}" 25.12
HARNESS_PROFILES="badarch/generic/board"
script_case "resolve-profiles invalid architecture in profiles.json prints nothing" 1 '' "${rp}" 25.12
HARNESS_PROFILES="noobj/generic/board"
script_case "resolve-profiles profiles.json without a profiles object" 1 '' "${rp}" 25.12
HARNESS_PROFILES="x86/64/generic x86/64/generic"
script_case "resolve-profiles the same profile twice" 1 '' "${rp}" 25.12
HARNESS_PROFILES="x86/64/generic;id"
script_case "resolve-profiles invalid token prints nothing" 1 '' "${rp}" 25.12
HARNESS_PROFILES="x86/64/generic
::error::forged"
script_case "resolve-profiles forged workflow command prints nothing" 1 '' "${rp}" 25.12
if grep -q 'forged' "${work}/err" "${work}/out"; then
	record "resolve-profiles does not echo an invalid value" 1 "echoed"
else
	record "resolve-profiles does not echo an invalid value" 0 ""
fi
HARNESS_PROFILES=${list17}
script_case "resolve-profiles 17 profiles" 1 '' "${rp}" 25.12
HARNESS_PROFILES="x86/64/generic"
script_case "resolve-profiles invalid line" 1 '' "${rp}" 'a;b'
script_case "resolve-profiles unknown line" 1 '' "${rp}" 99.99
script_case "resolve-profiles wrong argument count" 1 '' "${rp}"

# Only an HTTP 404 means "the target does not exist"; any other answer of the
# mirror (429, 5xx) or a network error is "cannot fetch", with the status. A
# fake curl stands in for the mirror: it behaves as curl -f -w '%{http_code}'
# (exit 22 for an HTTP status >= 400 when -f is given, the status printed for -w).
mkdir -p "${work}/stub"
cat >"${work}/stub/curl" <<'STUB'
#!/usr/bin/env sh
fail_flag=
code_flag=
for arg in "$@"; do
	case "${arg}" in
	-fsS) fail_flag=1 ;;
	-w) code_flag=1 ;;
	*) ;;
	esac
done
[ -z "${STUB_ERR}" ] || printf '%s\n' "${STUB_ERR}" >&2
[ -z "${code_flag}" ] || printf '%s' "${STUB_CODE}"
[ "${STUB_RC}" -eq 0 ] || exit "${STUB_RC}"
if [ -n "${fail_flag}" ] && [ "${STUB_CODE}" -ge 400 ]; then
	exit 22
fi
exit 0
STUB
chmod +x "${work}/stub/curl"
# Arguments: $1 case name, $2 HTTP status, $3 curl exit code, $4 curl stderr,
# $5 message expected on stderr (a fixed string)
mirror_case() {
	HARNESS_PROFILES="x86/64/generic"
	script_case "resolve-profiles $1 prints nothing" 1 '' \
		env PATH="${work}/stub:${PATH}" STUB_CODE="$2" STUB_RC="$3" STUB_ERR="$4" "${rp}" main
	if grep -qF -- "$5" "${work}/err"; then
		record "resolve-profiles $1 says: $5" 0 ""
	else
		record "resolve-profiles $1 says: $5" 1 "${sc_err}"
	fi
	case "$5" in
	*"does not exist"*) mc_other="cannot fetch" ;;
	*) mc_other="does not exist" ;;
	esac
	if grep -qF -- "${mc_other}" "${work}/err"; then
		record "resolve-profiles $1 does not say: ${mc_other}" 1 "${sc_err}"
	else
		record "resolve-profiles $1 does not say: ${mc_other}" 0 ""
	fi
}
mirror_case "HTTP 404" 404 0 "curl: (22) error: 404" "target x86/64 does not exist on line main"
mirror_case "HTTP 500" 500 0 "curl: (22) error: 500" "cannot fetch"
mirror_case "HTTP 500 status" 500 0 "curl: (22) error: 500" "HTTP 500 (curl exit 22)"
mirror_case "HTTP 503" 503 0 "curl: (22) error: 503" "HTTP 503 (curl exit 22)"
mirror_case "HTTP 429" 429 0 "curl: (22) error: 429" "HTTP 429 (curl exit 22)"
mirror_case "network error" 000 6 "curl: (6) Could not resolve host" "HTTP 000 (curl exit 6): curl: (6) Could not resolve host"
mirror_case "timeout" 000 28 "curl: (28) Operation timed out" "cannot fetch"

# --- matrix.sh and resolve.sh: test targets and memory ------------------------

unset HARNESS_TARGETS
export HARNESS_TARGETS
script_case "matrix default: every target of the line" 0 \
	'matrix={"target":["x86-64","armsr-armv8","malta-le","malta-be"]}' "${mx}" 25.12
script_case "matrix default on a line where a target has no image" 0 \
	'matrix={"target":["x86-64","armsr-armv8","malta-le"]}' "${mx}" main
HARNESS_TARGETS="malta-be x86-64"
script_case "matrix subset keeps the order of targets.yml" 0 \
	'matrix={"target":["x86-64","malta-be"]}' "${mx}" 25.12
HARNESS_TARGETS="malta-le
malta-le"
script_case "matrix duplicates are dropped" 0 'matrix={"target":["malta-le"]}' "${mx}" 25.12
HARNESS_TARGETS="x86-64 nope"
script_case "matrix unknown target fails and lists the known ones" 1 '' "${mx}" 25.12
if grep -q "unknown test target 'nope' on line 25.12 (known: x86-64 armsr-armv8 malta-le malta-be)" "${work}/err"; then
	record "matrix unknown target message" 0 ""
else
	record "matrix unknown target message" 1 "${sc_err}"
fi
HARNESS_TARGETS="malta-be"
script_case "matrix target without an image for the line fails" 1 '' "${mx}" main
HARNESS_TARGETS="x86-64;id"
script_case "matrix invalid target id prints nothing" 1 '' "${mx}" 25.12
HARNESS_TARGETS="  "
script_case "matrix blank targets mean all" 0 ANY "${mx}" 25.12
unset HARNESS_TARGETS
export HARNESS_TARGETS
script_case "matrix invalid line" 1 '' "${mx}" 'a;b'

export HARNESS_RELEASE=25.12.6
script_case "resolve.sh uses the memory of targets.yml" 0 ANY "${rs}" 25.12 armsr-armv8
if grep -qx 'HARNESS_MEMORY=128M' "${work}/out"; then
	record "resolve.sh default memory is 128M" 0 ""
else
	record "resolve.sh default memory is 128M" 1 "${sc_out}"
fi
script_case "resolve.sh memory override" 0 ANY env HARNESS_MEMORY_INPUT=256M "${rs}" 25.12 armsr-armv8
if grep -qx 'HARNESS_MEMORY=256M' "${work}/out"; then
	record "resolve.sh applies the memory input" 0 ""
else
	record "resolve.sh applies the memory input" 1 "${sc_out}"
fi
script_case "resolve.sh invalid memory prints nothing" 1 '' env HARNESS_MEMORY_INPUT=2G "${rs}" 25.12 armsr-armv8
script_case "resolve.sh memory below the range prints nothing" 1 '' env HARNESS_MEMORY_INPUT=32M "${rs}" 25.12 armsr-armv8
unset HARNESS_RELEASE

# --- resolve-archs.sh ------------------------------------------------------

unset HARNESS_ARCHS
export HARNESS_ARCHS
HARNESS_PROFILES=
script_case "resolve-archs default is the test architectures" 0 \
	'matrix={"arch":["x86_64","aarch64_generic","mipsel_24kc","mips_24kc"]}
archs=x86_64 aarch64_generic mipsel_24kc mips_24kc' "${ra}" 25.12
HARNESS_PROFILES="mediatek/filogic/bananapi_bpi-r3 ramips/mt7621/glinet_gl-mt1300"
script_case "resolve-archs adds the architectures of the profiles, once" 0 \
	'matrix={"arch":["x86_64","aarch64_generic","mipsel_24kc","mips_24kc","aarch64_cortex-a53"]}
archs=x86_64 aarch64_generic mipsel_24kc mips_24kc aarch64_cortex-a53' "${ra}" 25.12
HARNESS_ARCHS="@profiles"
export HARNESS_ARCHS
script_case "resolve-archs @profiles with no profile and no test architecture fails" 1 '' env HARNESS_PROFILES= "${ra}" 25.12
script_case "resolve-archs only @profiles" 0 \
	'matrix={"arch":["aarch64_cortex-a53","mipsel_24kc"]}
archs=aarch64_cortex-a53 mipsel_24kc' "${ra}" 25.12
HARNESS_ARCHS="riscv64_riscv64
x86_64 x86_64"
script_case "resolve-archs literal architectures only, duplicates dropped" 0 \
	'matrix={"arch":["riscv64_riscv64","x86_64"]}
archs=riscv64_riscv64 x86_64' "${ra}" 25.12
HARNESS_PROFILES="mediatek/filogic/nope_board"
script_case "resolve-archs literal architectures do not read the profiles" 0 ANY "${ra}" 25.12
HARNESS_ARCHS="@tests @profiles"
script_case "resolve-archs a profile that does not exist fails" 1 '' "${ra}" 25.12
HARNESS_ARCHS="@tests x86_64;id"
script_case "resolve-archs invalid token prints nothing" 1 '' "${ra}" 25.12
HARNESS_ARCHS="@tests
::error::forged"
script_case "resolve-archs forged workflow command prints nothing" 1 '' "${ra}" 25.12
HARNESS_PROFILES=
HARNESS_TARGETS="x86-64"
HARNESS_ARCHS="@tests"
export HARNESS_TARGETS
script_case "resolve-archs @tests follows the chosen targets" 0 \
	'matrix={"arch":["x86_64"]}
archs=x86_64' "${ra}" 25.12
HARNESS_PROFILES="mediatek/filogic/bananapi_bpi-r3"
HARNESS_ARCHS="@tests @profiles"
script_case "resolve-archs chosen targets plus the profiles" 0 \
	'matrix={"arch":["x86_64","aarch64_cortex-a53"]}
archs=x86_64 aarch64_cortex-a53' "${ra}" 25.12
HARNESS_TARGETS="x86-64 nope"
script_case "resolve-archs unknown target fails" 1 '' "${ra}" 25.12
unset HARNESS_TARGETS
export HARNESS_TARGETS
HARNESS_PROFILES="mediatek/filogic/nope_board"
HARNESS_ARCHS="@all"
script_case "resolve-archs unknown @ token" 1 '' "${ra}" 25.12
HARNESS_ARCHS="  "
script_case "resolve-archs no architecture" 1 '' "${ra}" 25.12
archs17=
i=0
while [ "${i}" -lt 17 ]; do
	archs17="${archs17} arch${i}"
	i=$((i + 1))
done
HARNESS_ARCHS=${archs17}
script_case "resolve-archs 17 architectures" 1 '' "${ra}" 25.12
HARNESS_ARCHS="@tests"
script_case "resolve-archs invalid line" 1 '' "${ra}" 'a;b'
unset HARNESS_ARCHS
HARNESS_PROFILES=

# --- resolve-image.sh ------------------------------------------------------

export HARNESS_IMAGE_TARGET=ramips HARNESS_IMAGE_SUBTARGET=mt7621
export HARNESS_IMAGE_DEVICE=glinet_gl-mt1300 HARNESS_IMAGE_ARCH=mipsel_24kc
export HARNESS_IMAGE_EXPECT=fits
HARNESS_IMAGE_PACKAGES="-dnsmasq
dnsmasq-full"
export HARNESS_IMAGE_PACKAGES
script_case "resolve-image with a package" 0 \
	'HARNESS_LINE=25.12
HARNESS_PROFILE_ID=glinet-gl-mt1300
HARNESS_PROFILE=glinet_gl-mt1300
HARNESS_ARCH=mipsel_24kc
HARNESS_PACKAGE=netbird
HARNESS_IMAGE_PACKAGES=-dnsmasq dnsmasq-full
HARNESS_PACKAGES=-dnsmasq dnsmasq-full netbird
HARNESS_ARTIFACT=images-netbird-25.12-glinet-gl-mt1300
HARNESS_TARGET_PATH=ramips/mt7621
HARNESS_IB_IMAGE=docker.io/openwrt/imagebuilder:ramips-mt7621-25.12.6
HARNESS_IB_SETUP=false
HARNESS_IMAGE_GLOBS=*sysupgrade* *factory*
HARNESS_EXPECT=fits' "${ri}" 25.12 glinet-gl-mt1300 netbird
script_case "resolve-image without a package" 0 ANY "${ri}" main glinet-gl-mt1300 ''
for want in 'HARNESS_PACKAGE=' 'HARNESS_PACKAGES=-dnsmasq dnsmasq-full' \
	'HARNESS_ARTIFACT=images-nopkg-main-glinet-gl-mt1300' \
	'HARNESS_IB_IMAGE=docker.io/openwrt/imagebuilder:ramips-mt7621-main' 'HARNESS_IB_SETUP=true'; do
	if grep -qxF -- "${want}" "${work}/out"; then
		record "resolve-image without a package has ${want}" 0 ""
	else
		record "resolve-image without a package has ${want}" 1 "${sc_out}"
	fi
done
HARNESS_IMAGE_PACKAGES=
script_case "resolve-image no packages and no package gives an empty list" 0 ANY "${ri}" main glinet-gl-mt1300 ''
if grep -qxF 'HARNESS_PACKAGES=' "${work}/out"; then
	record "resolve-image empty package list" 0 ""
else
	record "resolve-image empty package list" 1 "${sc_out}"
fi
HARNESS_IMAGE_PACKAGES="owut"
script_case "resolve-image expect too-big" 0 ANY env HARNESS_IMAGE_EXPECT=too-big "${ri}" main glinet-gl-mt1300 netbird
if grep -qxF 'HARNESS_EXPECT=too-big' "${work}/out"; then
	record "resolve-image expect too-big output" 0 ""
else
	record "resolve-image expect too-big output" 1 "${sc_out}"
fi
script_case "resolve-image invalid expect" 1 '' env HARNESS_IMAGE_EXPECT=maybe "${ri}" main glinet-gl-mt1300 netbird
script_case "resolve-image invalid packages prints nothing" 1 '' env "HARNESS_IMAGE_PACKAGES=owut;id" "${ri}" main glinet-gl-mt1300 netbird
script_case "resolve-image invalid arch prints nothing" 1 '' env "HARNESS_IMAGE_ARCH=bad arch" "${ri}" main glinet-gl-mt1300 netbird
script_case "resolve-image invalid target prints nothing" 1 '' env "HARNESS_IMAGE_TARGET=ramips;id" "${ri}" main glinet-gl-mt1300 netbird
script_case "resolve-image invalid profile prints nothing" 1 '' env "HARNESS_IMAGE_DEVICE=x y" "${ri}" main glinet-gl-mt1300 netbird
script_case "resolve-image invalid package prints nothing" 1 '' "${ri}" main glinet-gl-mt1300 'Net;bird'
script_case "resolve-image invalid profile id prints nothing" 1 '' "${ri}" main 'Glinet' netbird
script_case "resolve-image invalid line prints nothing" 1 '' "${ri}" 'a;b' glinet-gl-mt1300 netbird
unset HARNESS_IMAGE_TARGET HARNESS_IMAGE_SUBTARGET HARNESS_IMAGE_DEVICE HARNESS_IMAGE_ARCH \
	HARNESS_IMAGE_EXPECT HARNESS_IMAGE_PACKAGES
script_case "resolve-image without the matrix entry" 1 '' "${ri}" main glinet-gl-mt1300 netbird

# --- collect-images.sh: the manifest check ---------------------------------

ci=${script_dir}/collect-images.sh
ib=${work}/ib
mkdir -p "${ib}"
printf 'image\n' >"${ib}/openwrt-x-sysupgrade.bin"
printf 'sum\n' >"${ib}/sha256sums"
cat >"${ib}/openwrt-x.manifest" <<'EOF'
base-files - 1-r1
dnsmasq-full - 2.91-r1
luci-dnsmasq-extra - 1-r1
netbird - 0.78.1-r1
owut - 2-r1
EOF
# What imagebuilder-make.sh leaves for the check that the image holds the
# built apk: the apk metadata, the record apk wrote when it installed the
# .apk in a scratch root (local-expected.db) and the record in the image root
# (local-installed.db). ASNFZ4mrze8BI0VniavN7wEjRWc= is the checksum of the
# built apk, WcaXbNgoDLiKQt3UeHGPhhiX4P0= the one of a package of the feed.
cat >"${ib}/local-apk.dump" <<'DUMP'
info:
  name: netbird
  version: 0.78.1-r1
  arch: x86_64
DUMP
printf 'C:Q1ASNFZ4mrze8BI0VniavN7wEjRWc=\nP:netbird\nV:0.78.1-r1\n\n' >"${ib}/local-expected.db"
printf 'C:Q1ASNFZ4mrze8BI0VniavN7wEjRWc=\nP:netbird\nV:0.78.1-r1\n\n' >"${ib}/local-installed.db"
export HARNESS_IMAGE_GLOBS='*sysupgrade*'
collect() {
	# Arguments: $1 package, $2 version, $3 packages input
	rm -rf "${work}/img"
	HARNESS_PACKAGE=$1 HARNESS_PACKAGE_VERSION=$2 HARNESS_IMAGE_PACKAGES=$3 "${ci}" "${ib}" "${work}/img"
}
script_case "collect: package and input honoured" 0 \
	'HARNESS_MANIFEST_LINE=netbird - 0.78.1-r1
HARNESS_MANIFEST_FILE=openwrt-x.manifest' collect netbird 0.78.1-r1 "-dnsmasq dnsmasq-full owut"
script_case "collect: no package of our own, no manifest line" 0 \
	'HARNESS_MANIFEST_FILE=openwrt-x.manifest' collect '' '' "owut"
script_case "collect: removing a package that has only a longer name listed" 0 ANY collect netbird 0.78.1-r1 "-dnsmasq"
script_case "collect: removing a package that is listed fails" 1 '' collect netbird 0.78.1-r1 "-owut"
script_case "collect: adding a package that is not listed fails" 1 '' collect netbird 0.78.1-r1 "dnsmasq"
script_case "collect: adding a package whose name is a suffix of a listed one fails" 1 '' collect netbird 0.78.1-r1 "dnsmasq-extra"
script_case "collect: wrong package version fails" 1 '' collect netbird 0.78.0-r1 ""
script_case "collect: package missing from the manifest fails" 1 '' collect nope 1-r1 ""
script_case "collect: invalid packages input fails" 1 '' collect netbird 0.78.1-r1 "owut;id"
script_case "collect: a package without a version fails" 1 '' collect netbird '' ""
# The same image, but the installed netbird is the feed's (another checksum),
# or the apk metadata is of another version than its file name, or the
# evidence is missing.
#
# Arguments:
#   $1  Image Builder output directory
collect_in() {
	rm -rf "${work}/img"
	HARNESS_PACKAGE=netbird HARNESS_PACKAGE_VERSION=0.78.1-r1 HARNESS_IMAGE_PACKAGES='' "${ci}" "$1" "${work}/img"
}
ib_feed=${work}/ib-feed
cp -R "${ib}" "${ib_feed}"
printf 'C:Q1WcaXbNgoDLiKQt3UeHGPhhiX4P0=\nP:netbird\nV:0.78.1-r1\n\n' >"${ib_feed}/local-installed.db"
script_case "collect: same version installed from the feed fails" 1 '' collect_in "${ib_feed}"
case "${sc_err}" in
*"not the locally built apk"*) record "collect: feed package is named as the cause" 0 "" ;;
*) record "collect: feed package is named as the cause" 1 "${sc_err}" ;;
esac
ib_meta=${work}/ib-meta
cp -R "${ib}" "${ib_meta}"
sed 's/0.78.1-r1/0.99.0-r1/' "${ib}/local-apk.dump" >"${ib_meta}/local-apk.dump"
script_case "collect: metadata version differs from the file name fails" 1 '' collect_in "${ib_meta}"
ib_nodump=${work}/ib-nodump
cp -R "${ib}" "${ib_nodump}"
rm "${ib_nodump}/local-expected.db"
script_case "collect: missing expected record fails" 1 '' collect_in "${ib_nodump}"
script_case "collect: local package passes the check" 0 ANY collect_in "${ib}"
unset HARNESS_IMAGE_GLOBS

echo
if [ "${failures}" -ne 0 ]; then
	printf 'image-inputs-selftest: %s of %s cases FAILED\n' "${failures}" "${checks}" >&2
	exit 1
fi
printf 'image-inputs-selftest: %s cases passed\n' "${checks}"
