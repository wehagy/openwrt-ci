#!/usr/bin/env sh
# Responsibility: prove, with fixed inputs, the code that handles the feed
# source of a build: check_feed_repository, check_feed_ref and check_commit_sha
# (scripts/lib/common.sh), scripts/resolve-feed.sh (defaults per line,
# overrides, nothing printed on invalid input), scripts/resolve-build.sh (the
# feed data reaches the output, a missing or invalid SHA fails before any
# output) and scripts/feed-record.sh (SHA read from a checkout, output and
# summary). Every case runs; the script exits 1 after the last one if any
# failed. Runs in the feed job of build.yml. Needs yq.
#
# Usage:
#   scripts/feed-inputs-selftest.sh
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

work=$(mktemp -d) || die "cannot create a temporary directory"
trap 'rm -rf "${work}"' EXIT
failures=0
checks=0

# Run a script, keeping stdout (sc_out) and stderr and checking the exit code.
#
# Arguments:
#   $1  case name
#   $2  expected exit code (0 or 1)
#   $3  expected stdout (exactly), or the word ANY to skip the comparison
#   $4... command and arguments
script_case() {
	sc_name=$1
	sc_rc_expected=$2
	sc_stdout_expected=$3
	shift 3
	sc_rc=0
	"$@" >"${work}/out" 2>"${work}/err" || sc_rc=$?
	sc_out=$(cat "${work}/out")
	sc_err=$(cat "${work}/err")
	if [ "${sc_rc}" -ne "${sc_rc_expected}" ]; then
		record "${sc_name}" 1 "exit ${sc_rc}, expected ${sc_rc_expected}: ${sc_err}"
	elif [ "${sc_stdout_expected}" != ANY ] && [ "${sc_out}" != "${sc_stdout_expected}" ]; then
		record "${sc_name}" 1 "stdout: ${sc_out}"
	else
		record "${sc_name}" 0 ""
	fi
}

sha=0123456789abcdef0123456789abcdef01234567

# --- check_feed_repository ------------------------------------------------

for r in openwrt/packages wehagy/w a/b A-b/c.d_e-f wehagy/.github 1/2; do
	validator_case check_feed_repository accept "${r}" "'${r}'"
done
i=0
owner39=
while [ "${i}" -lt 39 ]; do
	owner39=${owner39}a
	i=$((i + 1))
done
validator_case check_feed_repository accept "${owner39}/x" "39 char owner"
validator_case check_feed_repository reject "${owner39}a/x" "40 char owner"
i=0
name100=
while [ "${i}" -lt 100 ]; do
	name100=${name100}a
	i=$((i + 1))
done
validator_case check_feed_repository accept "o/${name100}" "100 char name"
validator_case check_feed_repository reject "o/${name100}a" "101 char name"
for r in '' / o o/ /o o/p/q -o/p o/-p o_/p 'o.x/p' o/. o/.. o/p.git o/p.GIT \
	'o /p' 'o/p q' 'o/p;id' "o/\$(id)" 'o/p*' 'o/p?' 'o/p@x' 'é/p' 'o/é' \
	'https://github.com/o/p' 'git@github.com:o/p' '../p' 'o/../p'; do
	validator_case check_feed_repository reject "${r}" "'${r}'"
done
validator_case check_feed_repository reject "o/p
x/y" "newline"
validator_case check_feed_repository reject "o/p
::error::x" "workflow command"

# --- check_feed_ref -------------------------------------------------------

for r in master openwrt-25.12 v1.2.3 feat/x_y+z refs/pull/1/head \
	refs/pull/123456789/head "${sha}" a.b a-b refs; do
	validator_case check_feed_ref accept "${r}" "'${r}'"
done
i=0
ref200=
while [ "${i}" -lt 200 ]; do
	ref200=${ref200}a
	i=$((i + 1))
done
validator_case check_feed_ref accept "${ref200}" "200 chars"
validator_case check_feed_ref reject "${ref200}a" "201 chars"
for r in '' - -x --upload-pack=x -- ../x a/../b a..b a...b a.. .. . .x a/.x a/ /a a//b a. \
	x.lock a/x.lock 'a b' 'a;b' "a\$(id)" "a\`id\`" 'a*' 'a?' 'a[b' 'a~b' 'a^b' \
	'a:b' 'a\b' 'a@{b' 'é' \
	refs/x refs/heads/master refs/tags/v1 refs/pull/1/merge refs/pull/head \
	refs/pull//head refs/pull/x/head refs/pull/1x/head refs/pull/-1/head \
	refs/pull/1/head/ refs/pull/1/head/x refs/pull/1/x/head refs/pull/1234567890/head \
	refs/pull/1/../head refs/remotes/origin/x; do
	validator_case check_feed_ref reject "${r}" "'${r}'"
done
validator_case check_feed_ref reject "a
b" "newline"
validator_case check_feed_ref reject "a
::error::x" "workflow command"

# --- check_commit_sha -----------------------------------------------------

validator_case check_commit_sha accept "${sha}" "40 hex"
validator_case check_commit_sha accept 0000000000000000000000000000000000000000 "40 zeros"
for s in '' abc 0123456789abcdef0123456789abcdef0123456 \
	0123456789abcdef0123456789abcdef012345678 \
	0123456789ABCDEF0123456789ABCDEF01234567 \
	0123456789abcdef0123456789abcdef0123456g master; do
	validator_case check_commit_sha reject "${s}" "'${s}'"
done

# --- resolve-feed.sh ------------------------------------------------------

rf=${script_dir}/resolve-feed.sh
script_case "resolve-feed 25.12 defaults" 0 \
	"HARNESS_PACKAGES_REPOSITORY=openwrt/packages
HARNESS_PACKAGES_REF=openwrt-25.12" "${rf}" 25.12 '' ''
script_case "resolve-feed main defaults" 0 \
	"HARNESS_PACKAGES_REPOSITORY=openwrt/packages
HARNESS_PACKAGES_REF=master" "${rf}" main '' ''
script_case "resolve-feed repository and ref given" 0 \
	"HARNESS_PACKAGES_REPOSITORY=wehagy/w
HARNESS_PACKAGES_REF=master" "${rf}" main wehagy/w master
script_case "resolve-feed pull request ref, default repository" 0 \
	"HARNESS_PACKAGES_REPOSITORY=openwrt/packages
HARNESS_PACKAGES_REF=refs/pull/12345/head" "${rf}" 25.12 '' refs/pull/12345/head
script_case "resolve-feed ref only is not mixed with the line default" 0 \
	"HARNESS_PACKAGES_REPOSITORY=openwrt/packages
HARNESS_PACKAGES_REF=master" "${rf}" 25.12 '' master
script_case "resolve-feed invalid repository prints nothing" 1 '' "${rf}" main 'o/p;id' ''
script_case "resolve-feed invalid ref prints nothing" 1 '' "${rf}" main '' '../x'
script_case "resolve-feed leading dash ref prints nothing" 1 '' "${rf}" main '' '--upload-pack=x'
script_case "resolve-feed bad ref with a good repository prints nothing" 1 '' "${rf}" main wehagy/w 'refs/pull/x/head'
script_case "resolve-feed unknown line prints nothing" 1 '' "${rf}" 99.99 '' ''
script_case "resolve-feed invalid line prints nothing" 1 '' "${rf}" 'a;b' '' ''
script_case "resolve-feed wrong argument count" 1 '' "${rf}" main ''

# --- resolve-build.sh -----------------------------------------------------

rb=${script_dir}/resolve-build.sh
export HARNESS_SDK_CONTAINER=ghcr.io/wehagy/openwrt-sdk
script_case "resolve-build default feed" 0 ANY "${rb}" main x86_64 netbird '' '' "${sha}"
if grep -qx 'HARNESS_PACKAGES_REPOSITORY=openwrt/packages' "${work}/out" &&
	grep -qx 'HARNESS_PACKAGES_REF=master' "${work}/out" &&
	grep -qx "HARNESS_PACKAGES_SHA=${sha}" "${work}/out" &&
	grep -qx 'HARNESS_PACKAGE=netbird' "${work}/out"; then
	record "resolve-build default feed output" 0 ""
else
	record "resolve-build default feed output" 1 "${sc_out}"
fi
script_case "resolve-build custom feed" 0 ANY "${rb}" main x86_64 netbird wehagy/w master "${sha}"
if grep -qx 'HARNESS_PACKAGES_REPOSITORY=wehagy/w' "${work}/out" &&
	grep -qx 'HARNESS_PACKAGES_REF=master' "${work}/out" &&
	grep -qx "HARNESS_PACKAGES_SHA=${sha}" "${work}/out"; then
	record "resolve-build custom feed output" 0 ""
else
	record "resolve-build custom feed output" 1 "${sc_out}"
fi
script_case "resolve-build invalid ref prints nothing" 1 '' "${rb}" main x86_64 netbird '' '../x' "${sha}"
script_case "resolve-build invalid repository prints nothing" 1 '' "${rb}" main x86_64 netbird 'a/b/c' '' "${sha}"
script_case "resolve-build empty SHA prints nothing" 1 '' "${rb}" main x86_64 netbird '' '' ''
script_case "resolve-build short SHA prints nothing" 1 '' "${rb}" main x86_64 netbird '' '' 0123456
script_case "resolve-build old argument count" 1 '' "${rb}" main x86_64 netbird

# --- feed-record.sh -------------------------------------------------------

fr=${script_dir}/feed-record.sh
git init -q "${work}/feed" || die "cannot create a repository"
git -C "${work}/feed" -c user.name=t -c user.email=t@example.invalid \
	commit -q --allow-empty -m feed || die "cannot commit"
head_sha=$(git -C "${work}/feed" rev-parse HEAD) || die "cannot read HEAD"
export HARNESS_PACKAGES_REPOSITORY=wehagy/w HARNESS_PACKAGES_REF=refs/pull/7/head
script_case "feed-record output" 0 \
	"repository=wehagy/w
ref=refs/pull/7/head
sha=${head_sha}" "${fr}" "${work}/feed"
script_case "feed-record summary" 0 \
	"### feed source
- repository: wehagy/w
- ref: refs/pull/7/head
- commit: ${head_sha}" "${fr}" --summary "${work}/feed"
mkdir "${work}/plain"
script_case "feed-record outside a checkout prints nothing" 1 '' "${fr}" "${work}/plain"
script_case "feed-record invalid ref prints nothing" 1 '' env HARNESS_PACKAGES_REF='--x' "${fr}" "${work}/feed"
script_case "feed-record invalid repository prints nothing" 1 '' env HARNESS_PACKAGES_REPOSITORY='a' "${fr}" "${work}/feed"
script_case "feed-record without arguments" 1 '' "${fr}"

# --- result ---------------------------------------------------------------

if [ "${failures}" -ne 0 ]; then
	die "feed-inputs-selftest: ${failures} of ${checks} cases failed"
fi
printf 'feed-inputs-selftest: %s cases passed\n' "${checks}"
