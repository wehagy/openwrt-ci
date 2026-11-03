#!/usr/bin/env sh
# Responsibility: prove the resolution of the openwrt-tests environment
# without the network: the lock reader (lib/uv-lock.sh), the resolution of the
# followed branch to one commit (resolve-tests-ref.sh, against a local
# repository) and prepare-tests-env.sh (with a fake `uv`): the commit it
# reports is the one checked out, a checkout at another commit fails, uv gets
# the settings and the order (lock --upgrade-package labgrid, then sync
# --locked) the lock needs, and the labgrid version printed is the one the
# resulting lock holds, not the seed's. Runs in the targets job of test.yml.
#
# Usage:
#   scripts/tests-env-selftest.sh
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
# shellcheck source=lib/uv-lock.sh
. "${script_dir}/lib/uv-lock.sh"

work=$(mktemp -d) || die "cannot create a temporary directory"
trap 'rm -rf "${work}"' EXIT
failures=0
checks=0

# ---------------------------------------------------------------------------
# lock_package_version
# ---------------------------------------------------------------------------

# labgrid-extras sorts before, pyserial-labgrid after the real entry; both
# have a version of their own that must not be taken for labgrid's.
cat >"${work}/lock" <<'EOF2'
version = 1

[[package]]
name = "labgrid-extras"
version = "1.0.0"
source = { registry = "https://pypi.org/simple" }

[[package]]
name = "labgrid"
version = "26.0.1"
source = { registry = "https://pypi.org/simple" }
dependencies = [
    { name = "pyserial-labgrid" },
]

[[package]]
name = "pyserial-labgrid"
version = "3.5.0.2"
source = { registry = "https://pypi.org/simple" }
EOF2
script_case "lock: labgrid version" 0 "26.0.1" \
	sh -c ". '${script_dir}/lib/common.sh'; . '${script_dir}/lib/uv-lock.sh'; lock_package_version '${work}/lock' labgrid"
script_case "lock: name compared whole" 0 "3.5.0.2" \
	sh -c ". '${script_dir}/lib/common.sh'; . '${script_dir}/lib/uv-lock.sh'; lock_package_version '${work}/lock' pyserial-labgrid"
script_case "lock: missing package fails" 1 "" \
	sh -c ". '${script_dir}/lib/common.sh'; . '${script_dir}/lib/uv-lock.sh'; lock_package_version '${work}/lock' ansible"
script_case "lock: missing file fails" 1 "" \
	sh -c ". '${script_dir}/lib/common.sh'; . '${script_dir}/lib/uv-lock.sh'; lock_package_version '${work}/nolock' labgrid"
{
	cat "${work}/lock"
	printf '\n[[package]]\nname = "labgrid"\nversion = "27.0.0"\n'
} >"${work}/lock-twice"
script_case "lock: two entries fail" 1 "" \
	sh -c ". '${script_dir}/lib/common.sh'; . '${script_dir}/lib/uv-lock.sh'; lock_package_version '${work}/lock-twice' labgrid"

# ---------------------------------------------------------------------------
# resolve-tests-ref.sh against a local repository
# ---------------------------------------------------------------------------

# Record a case from the exit status of a command.
#
# Arguments:
#   $1  case name
#   $2  detail printed on failure
#   $3... command and arguments
check_that() {
	ct_name=$1
	ct_detail=$2
	shift 2
	if "$@"; then
		record "${ct_name}" 0 ""
	else
		record "${ct_name}" 1 "${ct_detail}"
	fi
}

git_t() { git -c user.name=selftest -c user.email=selftest@example.invalid "$@"; }
git init -q -b main "${work}/upstream"
: >"${work}/upstream/a"
git_t -C "${work}/upstream" add a
git_t -C "${work}/upstream" commit -q -m first
first=$(git -C "${work}/upstream" rev-parse HEAD)
git_t -C "${work}/upstream" checkout -q -b other
: >"${work}/upstream/b"
git_t -C "${work}/upstream" add b
git_t -C "${work}/upstream" commit -q -m second
other=$(git -C "${work}/upstream" rev-parse HEAD)
git_t -C "${work}/upstream" checkout -q main
: >"${work}/upstream/c"
git_t -C "${work}/upstream" add c
git_t -C "${work}/upstream" commit -q -m third
head_main=$(git -C "${work}/upstream" rev-parse HEAD)

script_case "ref: main resolves" 0 ANY \
	env HARNESS_TESTS_REPO_URL="${work}/upstream" "${script_dir}/resolve-tests-ref.sh"
sha_line=$(printf '%s\n' "${sc_out}" | sed -n 1p)
at_line=$(printf '%s\n' "${sc_out}" | sed -n 2p)
lines=$(printf '%s\n' "${sc_out}" | wc -l)
check_that "ref: follows the tip of main, not an older commit" "${sha_line}" \
	test "${sha_line}" = "tests_sha=${head_main}"
check_that "ref: the first commit is not the tip" "${sha_line}" \
	test "${sha_line}" != "tests_sha=${first}"
case "${at_line}" in
tests_resolved_at=20[0-9][0-9]-[01][0-9]-[0-3][0-9]T[0-2][0-9]:[0-5][0-9]:[0-6][0-9]Z) record "ref: instant is RFC 3339 UTC" 0 "" ;;
*) record "ref: instant is RFC 3339 UTC" 1 "${at_line}" ;;
esac
check_that "ref: prints exactly two lines" "${lines} lines" test "${lines}" -eq 2
script_case "ref: another branch" 0 "ANY" \
	env HARNESS_TESTS_REPO_URL="${work}/upstream" HARNESS_TESTS_BRANCH=other "${script_dir}/resolve-tests-ref.sh"
case "${sc_out}" in
"tests_sha=${other}"*) record "ref: HARNESS_TESTS_BRANCH is followed" 0 "" ;;
*) record "ref: HARNESS_TESTS_BRANCH is followed" 1 "${sc_out}" ;;
esac
script_case "ref: unknown branch fails" 1 "" \
	env HARNESS_TESTS_REPO_URL="${work}/upstream" HARNESS_TESTS_BRANCH=nope "${script_dir}/resolve-tests-ref.sh"
script_case "ref: unreachable repository fails" 1 "" \
	env HARNESS_TESTS_REPO_URL="${work}/missing" "${script_dir}/resolve-tests-ref.sh"

# ---------------------------------------------------------------------------
# prepare-tests-env.sh with a fake uv
# ---------------------------------------------------------------------------

# The fake records every call with the settings it saw. `lock` writes the lock
# a resolution would: labgrid at FAKE_LABGRID (the seed's own labgrid entry is
# replaced, so the version printed cannot come from the seed); `sync` fails
# unless --locked is given and a lock exists.
mkdir "${work}/bin"
cat >"${work}/bin/uv" <<'EOF2'
#!/usr/bin/env sh
project=$2
printf '%s | NO_SOURCES=%s CONFIG=%s NEWER=%s\n' "$*" "${UV_NO_SOURCES:-}" \
	"${UV_CONFIG_FILE:-}" "${UV_EXCLUDE_NEWER:-}" >>"${FAKE_UV_LOG}"
case "$3" in
lock)
	[ "$4" = --upgrade-package ] && [ "$5" = labgrid ] || exit 2
	cmp -s "${project}/uv.lock" "${FAKE_SEED}" || exit 3
	printf '[[package]]\nname = "labgrid"\nversion = "%s"\n\n[[package]]\nname = "pyserial-labgrid"\nversion = "3.5.0.2"\n' \
		"${FAKE_LABGRID}" >"${project}/uv.lock"
	;;
sync)
	[ "$4" = --locked ] && [ -f "${project}/uv.lock" ] || exit 4
	;;
*) exit 5 ;;
esac
EOF2
chmod +x "${work}/bin/uv"
PATH=${work}/bin:${PATH}
seed=${script_dir}/../harness/openwrt-tests.uv.lock
export FAKE_UV_LOG="${work}/uv.log" FAKE_SEED="${seed}" FAKE_LABGRID=26.4.2

git clone -q "${work}/upstream" "${work}/checkout"
prep() {
	: >"${FAKE_UV_LOG}"
	rm -f "${work}/checkout/uv.lock"
	env HARNESS_TESTS_SHA="${HARNESS_TESTS_SHA:-${head_main}}" \
		HARNESS_TESTS_RESOLVED_AT="${HARNESS_TESTS_RESOLVED_AT:-2026-11-03T10:00:00Z}" \
		"${script_dir}/prepare-tests-env.sh" "${work}/checkout"
}
config=$(cd "${script_dir}/../harness" && pwd)/uv.toml
expected="UV_NO_SOURCES=1
UV_CONFIG_FILE=${config}
UV_EXCLUDE_NEWER=2026-11-03T10:00:00Z
HARNESS_OPENWRT_TESTS_SHA=${head_main}
HARNESS_LABGRID_VERSION=26.4.2"
script_case "prepare: prints the resolved versions and the uv settings" 0 "${expected}" prep
expected_log="--project ${work}/checkout lock --upgrade-package labgrid | NO_SOURCES=1 CONFIG=${config} NEWER=2026-11-03T10:00:00Z
--project ${work}/checkout sync --locked | NO_SOURCES=1 CONFIG=${config} NEWER=2026-11-03T10:00:00Z"
uv_log=$(cat "${FAKE_UV_LOG}")
check_that "prepare: uv gets the settings; lock runs on the seed, then sync --locked" \
	"${uv_log}" test "${uv_log}" = "${expected_log}"
FAKE_LABGRID=26.0.1 script_case "prepare: runs with another labgrid" 0 ANY prep
case "${sc_out}" in
*"HARNESS_LABGRID_VERSION=26.0.1") record "prepare: labgrid version follows the lock" 0 "" ;;
*) record "prepare: labgrid version follows the lock" 1 "${sc_out}" ;;
esac
script_case "prepare: checkout at another commit fails" 1 "" \
	env HARNESS_TESTS_SHA="${first}" HARNESS_TESTS_RESOLVED_AT=2026-11-03T10:00:00Z \
	"${script_dir}/prepare-tests-env.sh" "${work}/checkout"
fails_case "prepare: missing commit fails" \
	env -u HARNESS_TESTS_SHA HARNESS_TESTS_RESOLVED_AT=2026-11-03T10:00:00Z \
	"${script_dir}/prepare-tests-env.sh" "${work}/checkout"
fails_case "prepare: missing instant fails" \
	env -u HARNESS_TESTS_RESOLVED_AT HARNESS_TESTS_SHA="${head_main}" \
	"${script_dir}/prepare-tests-env.sh" "${work}/checkout"
script_case "prepare: not a checkout fails" 1 "" \
	env HARNESS_TESTS_SHA="${head_main}" HARNESS_TESTS_RESOLVED_AT=2026-11-03T10:00:00Z \
	"${script_dir}/prepare-tests-env.sh" "${work}"

# The committed files the script depends on.
config_text=$(cat "${config}")
check_that "harness/uv.toml holds labgrid to the 26 series" "${config_text}" \
	grep -qx 'constraint-dependencies = \["labgrid>=26,<27"\]' "${config}"
seed_labgrid=$(lock_package_version "${seed}" labgrid)
case "${seed_labgrid}" in
26.*) record "seed lock has labgrid 26.x" 0 "" ;;
*) record "seed lock has labgrid 26.x" 1 "${seed_labgrid}" ;;
esac
if grep -q 'git = ' "${seed}"; then
	record "seed lock has no git source" 1 "a git source is locked"
else
	record "seed lock has no git source" 0 ""
fi

printf '%s checks, %s failures\n' "${checks}" "${failures}"
[ "${failures}" -eq 0 ]
