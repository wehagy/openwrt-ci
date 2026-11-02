#!/usr/bin/env sh
# Responsibility: prove scripts/ib-setup.sh with a fake setup.sh, so that the
# retry on a sha256 mismatch (a snapshot published file by file) is exercised
# without the mirror: it must retry only a checksum mismatch, bounded, restore
# what setup.sh consumed, warn on each retry and fail when the mismatch
# persists or when anything else fails. A fake `date` and `sleep` stand in for
# the clock, so the wait between attempts and the time budget are proven
# without waiting. Runs in the profiles job of images.yml.
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

# Fake clock: `date +%s` prints the contents of $FAKE_CLOCK, `sleep N` records
# N in $FAKE_SLEEPS and advances the clock by N, and the fake setup.sh advances
# it by FAKE_DURATION per call. Nothing waits.
mkdir "${work}/bin"
cat >"${work}/bin/date" <<'EOF'
#!/usr/bin/env sh
[ "$*" = "+%s" ] || exec /bin/date "$@"
cat "${FAKE_CLOCK}"
EOF
cat >"${work}/bin/sleep" <<'EOF'
#!/usr/bin/env sh
echo "$1" >>"${FAKE_SLEEPS}"
echo $(($(cat "${FAKE_CLOCK}") + $1)) >"${FAKE_CLOCK}"
EOF
chmod +x "${work}/bin/date" "${work}/bin/sleep"
PATH=${work}/bin:${PATH}

# Fake setup.sh. FAKE_MISMATCHES = number of calls that end in a checksum
# mismatch (FAKE_TEXT: its message); FAKE_OTHER = exit status of a failure
# that is not a mismatch (FAKE_OTHER_TEXT: its message).
# Like the real one it consumes the keys directory, fails if it is missing
# (the real gpg --import does) and refuses to start over a leftover archive
# (the real wget would save <name>.1 and sha256sum -c would see the old one).
cat >"${work}/setup.sh" <<'EOF'
#!/usr/bin/env sh
n=$(cat calls 2>/dev/null || echo 0)
n=$((n + 1))
echo "${n}" >calls
echo $(($(cat "${FAKE_CLOCK}") + ${FAKE_DURATION:-0})) >"${FAKE_CLOCK}"
[ -d keys ] || { echo "gpg: no keys" >&2; exit 2; }
[ ! -e leftover.tar.zst ] || { echo "stale archive" >&2; exit 2; }
rm -rf keys
if [ -n "${FAKE_OTHER:-}" ]; then
	echo "${FAKE_OTHER_TEXT:-No file matching 'x' found in sha256sums}" >&2
	exit "${FAKE_OTHER}"
fi
if [ "${n}" -le "${FAKE_MISMATCHES:-0}" ]; then
	: >leftover.tar.zst
	echo "${FAKE_TEXT:-sha256sum: WARNING: 1 computed checksum did NOT match}"
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
#   $5  number of retries expected: `warn:` lines and `::warning` annotations
#   $6  sleeps expected, in order, space separated (empty: none)
#   The case's environment (FAKE_*, HARNESS_IB_SETUP_*) is set as a prefix
#   assignment of the call and unset when the case ends.
run_case() {
	name=$1
	want_rc=$2
	want_calls=$3
	want_text=$4
	want_warns=$5
	want_sleeps=$6
	total=$((total + 1))
	dir=${work}/case-${total}
	mkdir -p "${dir}/keys"
	: >"${dir}/keys/a.asc"
	rc=0
	(
		cd "${dir}"
		echo 1000 >"${dir}/clock"
		HARNESS_IB_SETUP_CMD=${work}/setup.sh HARNESS_IB_KEYS_DIR=${dir}/keys \
			FAKE_CLOCK=${dir}/clock FAKE_SLEEPS=${dir}/sleeps \
			FAKE_MISMATCHES=${FAKE_MISMATCHES:-0} \
			"${script_dir}/ib-setup.sh"
	) >"${dir}.out" 2>&1 || rc=$?
	calls=$(cat "${dir}/calls" 2>/dev/null || echo 0)
	warns=$(grep -c '^warn: image builder archive did not match' "${dir}.out" || :)
	annotations=$(grep -c '^::warning title=Image Builder setup retried::' "${dir}.out" || :)
	sleeps=
	[ ! -f "${dir}/sleeps" ] || sleeps=$(tr '\n' ' ' <"${dir}/sleeps")
	sleeps=${sleeps% }
	problem=
	[ "${rc}" -eq "${want_rc}" ] || problem="exit ${rc}, want ${want_rc}"
	[ "${calls}" -eq "${want_calls}" ] ||
		problem="${problem:+${problem}; }${calls} setup calls, want ${want_calls}"
	[ "${warns}" -eq "${want_warns}" ] ||
		problem="${problem:+${problem}; }${warns} warn lines, want ${want_warns}"
	[ "${annotations}" -eq "${want_warns}" ] ||
		problem="${problem:+${problem}; }${annotations} ::warning annotations, want ${want_warns}"
	[ "${sleeps}" = "${want_sleeps}" ] ||
		problem="${problem:+${problem}; }sleeps '${sleeps}', want '${want_sleeps}'"
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
	unset FAKE_MISMATCHES FAKE_OTHER FAKE_OTHER_TEXT FAKE_TEXT FAKE_DURATION \
		HARNESS_IB_SETUP_ATTEMPTS HARNESS_IB_SETUP_WAIT HARNESS_IB_SETUP_BUDGET
}

run_case "first attempt works: no retry, no warning, no wait" 0 1 "setup done" 0 ""
FAKE_MISMATCHES=1 run_case "one mismatch, then ok: retried once with a warning" 0 2 "succeeded on attempt 2 of 3" 1 "120"
FAKE_MISMATCHES=2 run_case "two mismatches, then ok: succeeds on the last attempt" 0 3 "succeeded on attempt 3 of 3" 2 "120 120"
FAKE_MISMATCHES=9 run_case "mismatch every time: fails after 3 attempts, no wait after the last" 1 3 "did not match sha256sums in each of 3 attempts" 2 "120 120"
FAKE_MISMATCHES=9 HARNESS_IB_SETUP_ATTEMPTS=1 run_case "one attempt: the mismatch fails at once, no wait" 1 1 "did not match sha256sums in each of 1 attempts" 0 ""
FAKE_MISMATCHES=9 HARNESS_IB_SETUP_ATTEMPTS=5 run_case "five attempts: bounded at 5" 1 5 "in each of 5 attempts" 4 "120 120 120 120"
FAKE_MISMATCHES=2 HARNESS_IB_SETUP_WAIT=7 run_case "the wait is HARNESS_IB_SETUP_WAIT seconds" 0 3 "succeeded on attempt 3 of 3" 2 "7 7"
FAKE_MISMATCHES=1 HARNESS_IB_SETUP_WAIT=0 run_case "wait 0 still sleeps 0 s and retries" 0 2 "succeeded on attempt 2 of 3" 1 "0"
FAKE_MISMATCHES=1 FAKE_TEXT="sha256sum: WARNING: 2 computed checksums did NOT match" run_case "plural message is a mismatch too" 0 2 "succeeded on attempt 2 of 3" 1 "120"
FAKE_OTHER=3 run_case "another failure is not retried" 1 1 "not a checksum mismatch, not retried" 0 ""
FAKE_OTHER=1 FAKE_OTHER_TEXT="gpg: BAD signature from key; did NOT match" run_case "NOT match from gpg is not retried" 1 1 "not a checksum mismatch, not retried" 0 ""
FAKE_OTHER=1 FAKE_OTHER_TEXT="sha256sum: WARNING: listed checksum did NOT match" run_case "NOT match without 'computed' is not retried" 1 1 "not a checksum mismatch, not retried" 0 ""
FAKE_OTHER=1 FAKE_OTHER_TEXT="sha256sum: WARNING: 1 computed checksum did match" run_case "a matching checksum message is not retried" 1 1 "not a checksum mismatch, not retried" 0 ""
HARNESS_IB_SETUP_ATTEMPTS=6 run_case "attempts above 5 are refused" 1 0 "HARNESS_IB_SETUP_ATTEMPTS must be 1 to 5" 0 ""
HARNESS_IB_SETUP_ATTEMPTS=x run_case "attempts must be a number" 1 0 "HARNESS_IB_SETUP_ATTEMPTS must be 1 to 5" 0 ""
HARNESS_IB_SETUP_WAIT=901 run_case "wait above 900 s is refused" 1 0 "HARNESS_IB_SETUP_WAIT must be 0 to 900" 0 ""
HARNESS_IB_SETUP_WAIT=-1 run_case "wait must be a number" 1 0 "HARNESS_IB_SETUP_WAIT must be 0 to 900" 0 ""
HARNESS_IB_SETUP_BUDGET=0 run_case "budget 0 is refused" 1 0 "HARNESS_IB_SETUP_BUDGET must be 1 to 86400" 0 ""
HARNESS_IB_SETUP_BUDGET=86401 run_case "budget above 86400 s is refused" 1 0 "HARNESS_IB_SETUP_BUDGET must be 1 to 86400" 0 ""
HARNESS_IB_SETUP_BUDGET=x run_case "budget must be a number" 1 0 "HARNESS_IB_SETUP_BUDGET must be 1 to 86400" 0 ""

# Time budget: attempts of 1000 s, wait 120 s. After the first one 1000 s are
# used and a retry needs 120 + 1000 s.
FAKE_MISMATCHES=9 FAKE_DURATION=1000 HARNESS_IB_SETUP_BUDGET=2119 run_case "budget one second short: no retry, clear message" 1 1 "not retrying: 1000 s used, a retry needs about 1120 s, budget 2119 s" 0 ""
FAKE_MISMATCHES=1 FAKE_DURATION=1000 HARNESS_IB_SETUP_BUDGET=2120 run_case "retry that exactly fits the budget is made" 0 2 "succeeded on attempt 2 of 3" 1 "120"
FAKE_MISMATCHES=9 FAKE_DURATION=1000 HARNESS_IB_SETUP_BUDGET=2120 run_case "second retry no longer fits: stops after 2 attempts" 1 2 "not retrying: 2120 s used, a retry needs about 1120 s, budget 2120 s" 1 "120"
FAKE_MISMATCHES=9 FAKE_DURATION=5000 run_case "default budget: a slow attempt is not retried" 1 1 "not retrying: 5000 s used, a retry needs about 5120 s, budget 3000 s" 0 ""

if [ "${failed}" -ne 0 ]; then
	die "ib-setup-selftest: ${failed} of ${total} cases failed"
fi
printf 'ib-setup-selftest: %s cases passed\n' "${total}"
