#!/usr/bin/env sh
# Responsibility: case bookkeeping shared by the self-test scripts (sourced,
# not run): record() counts and prints one case, validator_case() checks that
# a validator of lib/common.sh accepts or rejects a value without echoing it,
# script_case() runs a script and checks its exit code and stdout (stdout in
# sc_out, stderr in sc_err). The caller sets failures=0, checks=0 and work (a
# scratch directory) and decides the final exit code.
#
# Usage:
#   . "${script_dir}/lib/selftest.sh"
#
# Environment variables: none.

# Record the result of one case.
#
# Arguments:
#   $1  case name
#   $2  0 if the case passed, otherwise it failed
#   $3  detail printed on failure
record() {
	checks=$((checks + 1))
	if [ "$2" -eq 0 ]; then
		printf 'ok   %s\n' "$1"
	else
		printf 'FAIL %s: %s\n' "$1" "$3"
		failures=$((failures + 1))
	fi
}

# Run a validator function of lib/common.sh in a subshell (die exits it) and
# check that it accepts or rejects the value, without ever printing the value.
#
# Arguments:
#   $1  validator function
#   $2  accept or reject
#   $3  value
#   $4  case label (the value itself may be unprintable)
validator_case() {
	vc_rc=0
	vc_out=$(
		"$1" "$3" 2>&1
	) || vc_rc=$?
	case "$2:${vc_rc}" in
	accept:0 | reject:1) record "$1 $2 $4" 0 "" ;;
	*) record "$1 $2 $4" 1 "exit ${vc_rc}: ${vc_out}" ;;
	esac
	# The value must not be echoed back (it could forge workflow commands).
	case "${vc_out}" in
	*"$3"*) [ "${#3}" -lt 5 ] || record "$1 does not echo $4" 1 "echoed the value" ;;
	*) ;;
	esac
}

# Run a script, keeping stdout (sc_out) and stderr and checking the exit code.
#
# Arguments:
#   $1  case name
#   $2  expected exit code (0 or 1)
#   $3  expected stdout (exactly), or the word ANY to skip the comparison
#   $4... command and arguments
# shellcheck disable=SC2154 # work is the scratch directory of the sourcing self-test
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
