#!/usr/bin/env sh
# Responsibility: prove, with fixed values and a stub curl (no network), the
# decisions and readers of the daily image refresh: image_decide and
# image_stale_decide (lib/image-decide.sh), the readers of the official
# container's environment and sha256sums (lib/image-upstream.sh) and the
# warning of a run that reads a stale image (image-stale-check.sh), so that a
# wrong comparison, a swapped branch or a failure turned into success fails the
# workflow before any image is rebuilt or read. Runs in the plan job of
# refresh-images.yml and in the build and image jobs' first job.
#
# Usage:
#   scripts/image-decide-selftest.sh
#
# Environment variables: none.

set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "${script_dir}/lib/common.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/selftest.sh
. "${script_dir}/lib/selftest.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/image-decide.sh
. "${script_dir}/lib/image-decide.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/sdk-labels.sh
. "${script_dir}/lib/sdk-labels.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/image-upstream.sh
. "${script_dir}/lib/image-upstream.sh"

failures=0
checks=0
work=$(mktemp -d) || die "cannot create a temporary directory"
trap 'rm -rf "${work}"' EXIT

# ---------------------------------------------------------------------------
# image_decide
# ---------------------------------------------------------------------------
now=1800000000
day=86400
recipe=$(printf '%064d' 0 | tr 0 1)
other_recipe=$(printf '%064d' 0 | tr 0 2)
url=https://downloads.openwrt.org/snapshots/targets/x86/64/sha256sums
sha_a=$(printf '%064d' 0 | tr 0 a)
sha_b=$(printf '%064d' 0 | tr 0 b)
sha_c=$(printf '%064d' 0 | tr 0 c)

# Run a function in a subshell, so that the die of a validator ends only it.
#
# Arguments:
#   $@  function and arguments
in_sub() {
	(
		"$@"
	)
}

# The creation time label of an image that is $1 seconds old at ${now}.
#
# Arguments:
#   $1  age, seconds
label_at() {
	date -u -d "@$((now - $1))" +%Y-%m-%dT%H:%M:%SZ || die "cannot format a timestamp"
}

# Expect image_decide to print a decision and a reason containing a text.
#
# Arguments:
#   $1  case name
#   $2  expected decision: reuse or rebuild
#   $3  text the reason must contain
#   $4  exists   $5 created   $6 refresh_since
#   $7  recipe now   $8 recipe label
#   $9  url now   $10 url label   $11 source now   $12 source label
decide_case() {
	dc_name=$1
	dc_want=$2
	dc_text=$3
	shift 3
	dc_out=$(image_decide "$@")
	dc_got=${dc_out%% *}
	dc_reason=${dc_out#* }
	if [ "${dc_got}" != "${dc_want}" ]; then
		record "decide: ${dc_name}" 1 "expected ${dc_want}, got ${dc_got} (${dc_reason})"
		return 0
	fi
	case "${dc_reason}" in
	*"${dc_text}"*) record "decide: ${dc_name}" 0 "" ;;
	*) record "decide: ${dc_name}" 1 "reason \"${dc_reason}\" lacks \"${dc_text}\"" ;;
	esac
}

fresh=$(label_at 10)
ancient=$(label_at $((400 * day)))
decide_case "missing" rebuild "image missing" false "" "" "${recipe}" "" "${url}" "" "${sha_a}" ""
decide_case "same recipe, url and source: reused" reuse "upstream unchanged ${sha_a}" \
	true "${fresh}" "" "${recipe}" "${recipe}" "${url}" "${url}" "${sha_a}" "${sha_a}"
decide_case "unchanged upstream is reused however old" reuse "upstream unchanged" \
	true "${ancient}" "" "${recipe}" "${recipe}" "${url}" "${url}" "${sha_a}" "${sha_a}"
decide_case "upstream archive changed" rebuild "upstream changed (image ${sha_b}, now ${sha_a})" \
	true "${fresh}" "" "${recipe}" "${recipe}" "${url}" "${url}" "${sha_a}" "${sha_b}"
decide_case "source label absent" rebuild "upstream changed" \
	true "${fresh}" "" "${recipe}" "${recipe}" "${url}" "${url}" "${sha_a}" ""
decide_case "Dockerfile changed" rebuild "Dockerfile changed" \
	true "${fresh}" "" "${recipe}" "${other_recipe}" "${url}" "${url}" "${sha_a}" "${sha_a}"
decide_case "Dockerfile label absent" rebuild "Dockerfile changed" \
	true "${fresh}" "" "${recipe}" "" "${url}" "${url}" "${sha_a}" "${sha_a}"
decide_case "upstream address changed" rebuild "upstream address" \
	true "${fresh}" "" "${recipe}" "${recipe}" "${url}" "${url}x" "${sha_a}" "${sha_a}"
decide_case "upstream address not recorded" rebuild "upstream address" \
	true "${fresh}" "" "${recipe}" "${recipe}" "${url}" "" "${sha_a}" "${sha_a}"
decide_case "mirror: same digest is reused" reuse "upstream unchanged ${sha_a}" \
	true "${fresh}" "" "" "" "" "" "${sha_a}" "${sha_a}"
decide_case "mirror: other digest" rebuild "upstream changed" \
	true "${fresh}" "" "" "" "" "" "${sha_a}" "${sha_b}"
decide_case "creation time unreadable" rebuild "creation time unreadable" \
	true "garbage" "" "${recipe}" "${recipe}" "${url}" "${url}" "${sha_a}" "${sha_a}"
decide_case "creation time empty" rebuild "creation time unreadable" \
	true "" "" "${recipe}" "${recipe}" "${url}" "${url}" "${sha_a}" "${sha_a}"
decide_case "forced: created before the request" rebuild "forced refresh" \
	true "$(label_at 10)" "${now}" "${recipe}" "${recipe}" "${url}" "${url}" "${sha_a}" "${sha_a}"
decide_case "forced: created after the request" reuse "refreshed since the request" \
	true "$(label_at 10)" "$((now - 20))" "${recipe}" "${recipe}" "${url}" "${url}" "${sha_a}" "${sha_a}"
decide_case "forced: created at the request" reuse "refreshed since the request" \
	true "$(label_at 10)" "$((now - 10))" "${recipe}" "${recipe}" "${url}" "${url}" "${sha_a}" "${sha_a}"

# ---------------------------------------------------------------------------
# image_stale_decide
# ---------------------------------------------------------------------------
# Arguments:
#   $1  case name   $2 expected state   $3 text of the reason
#   $4  created label   $5 differs   $6 grace days
stale_case() {
	sc2_name=$1
	sc2_want=$2
	sc2_text=$3
	sc2_out=$(image_stale_decide "$4" "${now}" "$6" "$5")
	sc2_got=${sc2_out%% *}
	sc2_reason=${sc2_out#* }
	if [ "${sc2_got}" != "${sc2_want}" ]; then
		record "stale: ${sc2_name}" 1 "expected ${sc2_want}, got ${sc2_got} (${sc2_reason})"
		return 0
	fi
	case "${sc2_reason}" in
	*"${sc2_text}"*) record "stale: ${sc2_name}" 0 "" ;;
	*) record "stale: ${sc2_name}" 1 "reason \"${sc2_reason}\" lacks \"${sc2_text}\"" ;;
	esac
}

stale_case "matching upstream is fresh however old" fresh "matches upstream" "${ancient}" false 1
stale_case "differs but younger than the grace period" fresh "within 1 day" "$(label_at 3600)" true 1
stale_case "differs, exactly at the grace period" fresh "within 1 day" "$(label_at "${day}")" true 1
stale_case "differs, one second over the grace period" stale "over 1 day" "$(label_at $((day + 1)))" true 1
stale_case "differs, two days, grace 3 days" fresh "within 3 day" "$(label_at $((2 * day)))" true 3
stale_case "differs, four days, grace 3 days" stale "over 3 day" "$(label_at $((4 * day)))" true 3
stale_case "comparison missing" unknown "comparison with upstream missing" "$(label_at 10)" "" 1
stale_case "creation time unreadable" unknown "creation time unreadable" "garbage" true 1
stale_case "created in the future" unknown "in the future" "$(label_at -5)" true 1

# ---------------------------------------------------------------------------
# lib/image-upstream.sh
# ---------------------------------------------------------------------------
printf '["PATH=/usr/bin","TARGET=x86/64","TARGETX=wrong","DOWNLOAD_FILE=imagebuilder-.*x86_64.tar.[xz|zst]","EMPTY="]\n' >"${work}/env.json"
got=$(upstream_env_get "${work}/env.json" TARGET)
if [ "${got}" = x86/64 ]; then record "env: TARGET is not read from TARGETX" 0 ""; else record "env: TARGET is not read from TARGETX" 1 "${got}"; fi
got=$(upstream_env_get "${work}/env.json" DOWNLOAD_FILE)
if [ "${got}" = 'imagebuilder-.*x86_64.tar.[xz|zst]' ]; then record "env: a value with = ... and brackets" 0 ""; else record "env: a value with brackets" 1 "${got}"; fi
got=$(upstream_env_get "${work}/env.json" FILE_HOST)
if [ -z "${got}" ]; then record "env: absent is empty" 0 ""; else record "env: absent is empty" 1 "${got}"; fi
got=$(upstream_env_get "${work}/env.json" EMPTY)
if [ -z "${got}" ]; then record "env: set but empty is empty" 0 ""; else record "env: set but empty is empty" 1 "${got}"; fi

script_case "sums url: host without a scheme gets https" 0 \
	"https://downloads.openwrt.org/snapshots/targets/x86/64/sha256sums" \
	in_sub upstream_sums_url downloads.openwrt.org snapshots x86/64
script_case "sums url: release path" 0 \
	"https://downloads.openwrt.org/releases/25.12.2/targets/ath79/generic/sha256sums" \
	in_sub upstream_sums_url https://downloads.openwrt.org releases/25.12.2 ath79/generic
fails_case "sums url: another scheme is refused" in_sub upstream_sums_url ftp://downloads.openwrt.org snapshots x86/64
fails_case "sums url: a space in the host is refused" in_sub upstream_sums_url "downloads.openwrt.org x" snapshots x86/64
fails_case "sums url: empty target is refused" in_sub upstream_sums_url downloads.openwrt.org snapshots ""
# shellcheck disable=SC2016 # the dollar must reach the function as it is
fails_case "sums url: a dollar in the path is refused" in_sub upstream_sums_url downloads.openwrt.org 'snap$shots' x86/64

{
	printf '%s *openwrt-sdk-x86-64_gcc-14.3.0_musl.Linux-x86_64.tar.zst\n' "${sha_a}"
	printf '%s *openwrt-imagebuilder-x86-64.Linux-x86_64.tar.zst\n' "${sha_b}"
	printf '%s *openwrt-x86-64-generic-squashfs-combined.img.gz\n' "${sha_c}"
} >"${work}/sums"
script_case "pick: the one archive the pattern matches" 0 \
	"${sha_b} openwrt-imagebuilder-x86-64.Linux-x86_64.tar.zst" \
	in_sub upstream_pick "${work}/sums" 'imagebuilder-.*x86_64.tar.[xz|zst]'
script_case "pick: the sdk" 0 \
	"${sha_a} openwrt-sdk-x86-64_gcc-14.3.0_musl.Linux-x86_64.tar.zst" \
	in_sub upstream_pick "${work}/sums" 'openwrt-sdk-.*x86_64.tar.[xz|zst]'
fails_case "pick: no match is refused" in_sub upstream_pick "${work}/sums" 'nothing-like-this'
fails_case "pick: two matches are refused" in_sub upstream_pick "${work}/sums" 'x86'
case "$(cat "${work}/err")" in
*"expected 1"*) record "pick: two matches are refused for that reason" 0 "" ;;
*) record "pick: two matches are refused for that reason" 1 "$(cat "${work}/err")" ;;
esac
fails_case "pick: an empty pattern is refused" in_sub upstream_pick "${work}/sums" ''
fails_case "pick: a pattern with a newline is refused" in_sub upstream_pick "${work}/sums" 'imagebuilder
x86'
printf '%s *%s\n' "short" "openwrt-imagebuilder-x86-64.tar.zst" >"${work}/badsums"
fails_case "pick: a sha256 that is not 64 digits is refused" in_sub upstream_pick "${work}/badsums" 'imagebuilder'
script_case "sha of: a listed name" 0 "${sha_c}" \
	in_sub upstream_sha_of "${work}/sums" openwrt-x86-64-generic-squashfs-combined.img.gz
script_case "sha of: a name that is only a prefix of a listed one" 0 "" \
	in_sub upstream_sha_of "${work}/sums" openwrt-x86-64-generic-squashfs-combined.img
script_case "sha of: an unlisted name" 0 "" in_sub upstream_sha_of "${work}/sums" other.tar.zst

# ---------------------------------------------------------------------------
# image-stale-check.sh, with a stub curl that serves ${work}/served
# ---------------------------------------------------------------------------
mkdir "${work}/stub"
cat >"${work}/stub/curl" <<'STUB'
#!/usr/bin/env sh
# Stub curl: write $STUB_SERVE to the file given by -o, or fail like curl -f.
out=
while [ "$#" -gt 0 ]; do
	case "$1" in
	-o) out=$2; shift ;;
	*) ;;
	esac
	shift
done
[ -z "${STUB_FAIL:-}" ] || { echo "curl: (22) The requested URL returned error: 503" >&2; exit 22; }
cp "${STUB_SERVE}" "${out}"
STUB
chmod +x "${work}/stub/curl"
cp "${work}/sums" "${work}/served"

archive=openwrt-imagebuilder-x86-64.Linux-x86_64.tar.zst
t_old=$(label_at $((3 * day)))
t_new=$(label_at 3600)

# Write a labels file.
#
# Arguments:
#   $1  created   $2 upstream url   $3 archive   $4 archive sha   $5 release
write_labels() {
	jq -n -c --arg c "$1" --arg u "$2" --arg a "$3" --arg s "$4" --arg r "$5" \
		--arg kc "${label_created}" --arg ku "${label_upstream}" --arg ka "${label_archive}" \
		--arg ks "${label_archive_sha}" --arg kr "${label_release}" \
		'{($kc): $c, ($ku): $u, ($ka): $a, ($ks): $s, ($kr): $r}' >"${work}/labels.json"
}

# Run image-stale-check.sh with the stub curl and the fixed time; stdout in
# ${work}/out. Arguments: environment assignments, then nothing.
run_check() {
	env PATH="${work}/stub:${PATH}" STUB_SERVE="${work}/served" HARNESS_NOW="${now}" \
		GITHUB_REPOSITORY=acme/pkgs "$@" "${script_dir}/image-stale-check.sh" "${work}/labels.json" ghcr.io/acme/img:tag
}

# Expect the check to succeed and its stdout to contain (or not) a text.
#
# Arguments:
#   $1  case name   $2 text   $3 "has" or "lacks"
check_out() {
	if grep -qF -- "$2" "${work}/out"; then co_has=has; else co_has=lacks; fi
	if [ "${co_has}" = "$3" ]; then record "$1" 0 ""; else record "$1" 1 "stdout ${co_has} \"$2\": $(cat "${work}/out")"; fi
}

write_labels "${t_old}" "${url}" "${archive}" "${sha_b}" ""
script_case "check: matching sha256 is fresh" 0 ANY run_check env
check_out "check: matching sha256 prints no warning" "::warning" lacks
check_out "check: matching sha256 says fresh" "is fresh" has
write_labels "${t_old}" "${url}" "${archive}" "${sha_a}" ""
script_case "check: another sha256 on an old image warns, exit 0" 0 ANY run_check env
check_out "check: stale warning annotation" "::warning title=Image stale::ghcr.io/acme/img:tag is stale" has
check_out "check: stale warning names the sha256 upstream" "${sha_b}" has
check_out "check: stale warning has the refresh command" "gh workflow run refresh-images.yml --repo acme/pkgs" has
write_labels "${t_new}" "${url}" "${archive}" "${sha_a}" ""
script_case "check: another sha256 on a young image is fresh" 0 ANY run_check env
check_out "check: young image prints no warning" "::warning" lacks
write_labels "${t_old}" "${url}" "gone.tar.zst" "${sha_a}" ""
script_case "check: an archive no longer listed is stale" 0 ANY run_check env
check_out "check: not listed warning" "no longer listed" has
write_labels "${t_old}" "${url}" "${archive}" "${sha_b}" ""
script_case "check: sha256sums that cannot be downloaded warns, exit 0" 0 ANY run_check env STUB_FAIL=1
check_out "check: download failure warns that it could not check" "::warning title=Image unknown::" has
check_out "check: download failure is named" "could not download" has
write_labels "${t_old}" "http://downloads.openwrt.org/x/sha256sums" "${archive}" "${sha_b}" ""
script_case "check: an address that is not https is refused" 1 ANY run_check env
write_labels "${t_old}" "" "" "" "25.12.2"
script_case "check: same release is fresh" 0 ANY run_check env HARNESS_IB_RELEASE=25.12.2
check_out "check: same release prints no warning" "::warning" lacks
script_case "check: another release on an old image is stale" 0 ANY run_check env HARNESS_IB_RELEASE=25.12.3
check_out "check: release warning" "the latest is 25.12.3" has
write_labels "${t_new}" "" "" "" "25.12.2"
script_case "check: another release on a young image is fresh" 0 ANY run_check env HARNESS_IB_RELEASE=25.12.3
check_out "check: young release prints no warning" "::warning" lacks
write_labels "${t_old}" "" "" "" ""
script_case "check: labels to compare are missing" 0 ANY run_check env
check_out "check: missing labels warn" "no label to compare" has

# image_missing_error and refresh_command
msg=$(image_missing_error ghcr.io/acme/img:tag acme/pkgs)
case "${msg}" in
"::error title=Image missing::ghcr.io/acme/img:tag is missing"*"gh workflow run refresh-images.yml --repo acme/pkgs"*) record "missing image annotation" 0 "" ;;
*) record "missing image annotation" 1 "${msg}" ;;
esac

# Timestamp parsing.
parsed=$(utc_to_epoch 1970-01-02T00:00:00Z)
if [ "${parsed}" -eq "${day}" ]; then record "utc_to_epoch" 0 ""; else record "utc_to_epoch" 1 "${parsed}"; fi
fails_case "utc_to_epoch refuses a malformed timestamp" in_sub utc_to_epoch "2026-11-01 00:00:00"

echo
if [ "${failures}" -ne 0 ]; then
	printf 'image-decide-selftest: %s of %s cases FAILED\n' "${failures}" "${checks}" >&2
	exit 1
fi
printf 'image-decide-selftest: %s cases passed\n' "${checks}"
