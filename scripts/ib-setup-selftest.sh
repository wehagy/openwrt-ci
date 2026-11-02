#!/usr/bin/env sh
# Responsibility: prove scripts/ib-setup.sh with a fake setup.sh, so that the
# retry on a sha256 mismatch (a snapshot published file by file) is exercised
# without the mirror: it must retry only a checksum mismatch, bounded, restore
# what setup.sh consumed, warn on each retry and fail when the mismatch
# persists or when anything else fails. Runs in the profiles job of
# images.yml.
#
# Usage:
#   scripts/ib-setup-selftest.sh
#
# Environment variables: none.

set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "${script_dir}/lib/common.sh"

work=$(mktemp -d) || die "cannot create a temporary directory"
trap 'rm -rf "${work}"' EXIT

failed=0
total=0

# Fake setup.sh. FAKE_MISMATCHES = number of calls that end in a checksum
# mismatch; FAKE_OTHER = exit status of a failure that is not a mismatch.
# Like the real one it consumes the keys directory, fails if it is missing
# (the real gpg --import does) and refuses to start over a leftover archive
# (the real wget would save <name>.1 and sha256sum -c would see the old one).
cat >"${work}/setup.sh" <<'EOF'
#!/usr/bin/env sh
n=$(cat calls 2>/dev/null || echo 0)
n=$((n + 1))
echo "${n}" >calls
[ -d keys ] || { echo "gpg: no keys" >&2; exit 2; }
[ ! -e leftover.tar.zst ] || { echo "stale archive" >&2; exit 2; }
rm -rf keys
if [ -n "${FAKE_OTHER:-}" ]; then
	echo "No file matching 'x' found in sha256sums" >&2
	exit "${FAKE_OTHER}"
fi
if [ "${n}" -le "${FAKE_MISMATCHES:-0}" ]; then
	: >leftover.tar.zst
	echo "sha256sum: WARNING: 1 computed checksum did NOT match"
	exit 1
fi
echo "setup done"
EOF
chmod +x "${work}/setup.sh"

# Run ib-setup.sh in a fresh directory and check the result.
#
# Arguments:
#   $1  case name
#   $2  expected exit: 0 or 1
#   $3  expected number of setup.sh calls
#   $4  text that must appear in stderr+stdout (empty: none)
#   $5  number of `warn:` retry lines expected
#   The case's environment (FAKE_*, HARNESS_IB_SETUP_*) is set as a prefix
#   assignment of the call and unset when the case ends.
run_case() {
	name=$1
	want_rc=$2
	want_calls=$3
	want_text=$4
	want_warns=$5
	total=$((total + 1))
	dir=${work}/case-${total}
	mkdir -p "${dir}/keys"
	: >"${dir}/keys/a.asc"
	rc=0
	(
		cd "${dir}"
		HARNESS_IB_SETUP_CMD=${work}/setup.sh HARNESS_IB_KEYS_DIR=${dir}/keys \
			HARNESS_IB_SETUP_WAIT=${HARNESS_IB_SETUP_WAIT:-0} \
			FAKE_MISMATCHES=${FAKE_MISMATCHES:-0} \
			"${script_dir}/ib-setup.sh"
	) >"${dir}.out" 2>&1 || rc=$?
	calls=$(cat "${dir}/calls" 2>/dev/null || echo 0)
	warns=$(grep -c '^warn: image builder archive did not match' "${dir}.out" || :)
	problem=
	[ "${rc}" -eq "${want_rc}" ] || problem="exit ${rc}, want ${want_rc}"
	[ "${calls}" -eq "${want_calls}" ] ||
		problem="${problem:+${problem}; }${calls} setup calls, want ${want_calls}"
	[ "${warns}" -eq "${want_warns}" ] ||
		problem="${problem:+${problem}; }${warns} warn lines, want ${want_warns}"
	if [ -n "${want_text}" ] && ! grep -q -- "${want_text}" "${dir}.out"; then
		problem="${problem:+${problem}; }'${want_text}' not in the output"
	fi
	if [ -n "${problem}" ]; then
		failed=$((failed + 1))
		printf 'FAIL %s: %s\n' "${name}" "${problem}" >&2
		sed 's/^/    /' "${dir}.out" >&2
	else
		printf 'ok   %s\n' "${name}"
	fi
	# A prefix assignment of a function call may outlive the call.
	unset FAKE_MISMATCHES FAKE_OTHER HARNESS_IB_SETUP_ATTEMPTS HARNESS_IB_SETUP_WAIT
}

run_case "first attempt works: no retry, no warning" 0 1 "setup done" 0
FAKE_MISMATCHES=1 run_case "one mismatch, then ok: retried once with a warning" 0 2 "succeeded on attempt 2 of 3" 1
FAKE_MISMATCHES=2 run_case "two mismatches, then ok: succeeds on the last attempt" 0 3 "succeeded on attempt 3 of 3" 2
FAKE_MISMATCHES=9 run_case "mismatch every time: fails after 3 attempts" 1 3 "did not match sha256sums in each of 3 attempts" 2
FAKE_MISMATCHES=9 HARNESS_IB_SETUP_ATTEMPTS=1 run_case "one attempt: the mismatch fails at once" 1 1 "did not match sha256sums in each of 1 attempts" 0
FAKE_MISMATCHES=9 HARNESS_IB_SETUP_ATTEMPTS=5 run_case "five attempts: bounded at 5" 1 5 "in each of 5 attempts" 4
FAKE_OTHER=3 run_case "another failure is not retried" 1 1 "not a checksum mismatch, not retried" 0
HARNESS_IB_SETUP_ATTEMPTS=6 run_case "attempts above 5 are refused" 1 0 "HARNESS_IB_SETUP_ATTEMPTS must be 1 to 5" 0
HARNESS_IB_SETUP_ATTEMPTS=x run_case "attempts must be a number" 1 0 "HARNESS_IB_SETUP_ATTEMPTS must be 1 to 5" 0
HARNESS_IB_SETUP_WAIT=901 run_case "wait above 900 s is refused" 1 0 "HARNESS_IB_SETUP_WAIT must be 0 to 900" 0
HARNESS_IB_SETUP_WAIT=-1 run_case "wait must be a number" 1 0 "HARNESS_IB_SETUP_WAIT must be 0 to 900" 0

if [ "${failed}" -ne 0 ]; then
	die "ib-setup-selftest: ${failed} of ${total} cases failed"
fi
printf 'ib-setup-selftest: %s cases passed\n' "${total}"
