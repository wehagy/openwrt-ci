#!/usr/bin/env sh
# Responsibility: prove, with fixed inputs, the code that handles what a
# calling repository gives to test.yml: check_tests_path and
# check_secret_names (scripts/lib/common.sh), scripts/validate-inputs.sh,
# scripts/install-tests.sh (which files are copied, name collisions) and
# scripts/with-test-secrets.sh (which secrets reach the command, nothing is
# printed, the JSON with all the secrets is gone from every ancestor of the
# command). Every case runs; the script exits 1 after the last one if any
# failed. Runs in the targets job of test.yml.
#
# Usage:
#   scripts/caller-inputs-selftest.sh
#
# Environment variables: none. Needs jq and /proc (Linux).

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

# --- check_tests_path -----------------------------------------------------

for p in packages/netbird/tests a tests_1.0/a-b/c a/..b .github/tests .gitx/a a/-b a.git/x; do
	validator_case check_tests_path accept "${p}" "${p}"
done
long=
i=0
while [ "${i}" -lt 256 ]; do
	long=${long}a
	i=$((i + 1))
done
validator_case check_tests_path accept "${long}" "256 chars"
validator_case check_tests_path reject "${long}a" "257 chars"
for p in '' .. ../x a/../b a/.. /abs a/ a//b . ./a a/. a/./b 'a b' 'a*' 'a;b' \
	"\$(id)" "\`id\`" 'a"b' "a'b" 'a\b' 'é/x' -rf -a/b -- .git .git/hooks \
	a/.git a/.git/b .GIT/x a/.Git/b; do
	validator_case check_tests_path reject "${p}" "'${p}'"
done
validator_case check_tests_path reject "a
b" "newline"
validator_case check_tests_path reject "a
::error::x" "workflow command"

# --- check_secret_names ---------------------------------------------------

for n in NB_SETUP_KEY 'A B' 'A,B C' A_1 NODE_ENV UVX_KEY PYTESTX LGX HARNESS PATHX \
	'A,B,' ' A'; do
	validator_case check_secret_names accept "${n}" "'${n}'"
done
names32=
i=0
while [ "${i}" -lt 32 ]; do
	names32="${names32}N${i} "
	i=$((i + 1))
done
validator_case check_secret_names accept "${names32}" "32 names"
validator_case check_secret_names reject "${names32}N33" "33 names"
for n in '' ',,' ' ' a A_b 1A _A 'A;id' 'A*' "A\$(id)" 'A-B' 'A.B' 'É' \
	PATH HOME SHELL IFS ENV PS4 TMPDIR GITHUB_TOKEN GITHUB_ENV GITHUB_PATH \
	RUNNER_TEMP ACTIONS_RUNTIME_TOKEN HARNESS_SECRETS_JSON LD_PRELOAD \
	LD_LIBRARY_PATH BASH_ENV PYTHONPATH PYTHONSTARTUP PYTHONHOME UV_INDEX_URL \
	UV_PYTHON PYTEST_ADDOPTS PYTEST_PLUGINS NODE_OPTIONS LG_ENV LG_PROXY \
	'A PATH' 'A,GITHUB_TOKEN' 'A, PYTHONPATH'; do
	validator_case check_secret_names reject "${n}" "'${n}'"
done
validator_case check_secret_names reject "A
B" "newline"

# --- validate-inputs.sh -----------------------------------------------------

# Run validate-inputs.sh with valid base inputs plus the two optional ones.
#
# Arguments:
#   $1  expected exit code (0 or 1)
#   $2  HARNESS_TESTS_PATH
#   $3  HARNESS_TEST_SECRETS
#   $4  case name
validate_case() {
	rc=0
	out=$(HARNESS_PACKAGE=netbird HARNESS_LINE=25.12 HARNESS_SOURCE=artifact \
		HARNESS_TESTS_PATH=$2 HARNESS_TEST_SECRETS=$3 \
		sh "${script_dir}/validate-inputs.sh" 2>&1) || rc=$?
	if [ "${rc}" -eq "$1" ]; then
		record "validate-inputs $4" 0 ""
	else
		record "validate-inputs $4" 1 "exit ${rc}, expected $1: ${out}"
	fi
}
validate_case 0 '' '' "no optional input"
validate_case 0 packages/netbird/tests NB_SETUP_KEY "valid optional inputs"
validate_case 1 ../x '' "tests_path with .."
validate_case 1 -rf '' "tests_path with leading -"
validate_case 1 .git/hooks '' "tests_path in .git"
validate_case 1 '' PATH "secret PATH"
validate_case 1 '' 'A;id' "secret with ;"
validate_case 1 packages/netbird/tests 'NB_SETUP_KEY,GITHUB_TOKEN' "reserved secret in a list"

# --- install-tests.sh -----------------------------------------------------

# Print the names of the entries of a directory, sorted, one per line.
#
# Arguments:
#   $1  directory
list_dir() {
	find "$1" -mindepth 1 -maxdepth 1 -exec basename {} \; | sort
}

harness_files=
for f in "${script_dir}"/../harness/tests/*.py; do
	harness_files="${harness_files}$(basename "${f}")
"
done
harness_files=$(printf '%s' "${harness_files}" | sort)
ext="${work}/ext"
caller="${work}/caller"

# Run install-tests.sh into a fresh ext directory with the caller files
# given as "name:content" pairs ("sub/x" and "data.json" included as is).
#
# Arguments:
#   $1  expected exit code
#   $2  tests path argument ("-" for the harness files only)
#   $3...  files of the caller tests directory (tests dir is packages/t)
install_run() {
	ir_rc_expected=$1
	ir_path=$2
	shift 2
	rm -rf "${ext}" "${caller}"
	mkdir -p "${caller}/packages/t/sub"
	for f in "$@"; do
		printf '# %s\n' "${f}" >"${caller}/packages/t/${f}"
	done
	ir_rc=0
	if [ "${ir_path}" = - ]; then
		ir_out=$(sh "${script_dir}/install-tests.sh" "${ext}" 2>&1) || ir_rc=$?
	else
		ir_out=$(sh "${script_dir}/install-tests.sh" "${ext}" "${caller}" "${ir_path}" 2>&1) || ir_rc=$?
	fi
	[ "${ir_rc}" -eq "${ir_rc_expected}" ] ||
		record "install-tests exit" 1 "exit ${ir_rc}, expected ${ir_rc_expected}: ${ir_out}"
	ir_ext=$(list_dir "${ext}")
}

# Check ext content against the harness files plus the given extra names.
#
# Arguments:
#   $1  case name
#   $2...  names expected besides the harness files
ext_is() {
	ei_name=$1
	shift
	ei_expected=$(
		{
			printf '%s\n' "${harness_files}"
			for f in "$@"; do printf '%s\n' "${f}"; done
		} | sort
	)
	if [ "${ir_ext}" = "${ei_expected}" ]; then
		record "install-tests ${ei_name}" 0 ""
	else
		ei_has=$(printf '%s' "${ir_ext}" | tr '\n' ' ')
		ei_want=$(printf '%s' "${ei_expected}" | tr '\n' ' ')
		record "install-tests ${ei_name}" 1 "ext has [${ei_has}], expected [${ei_want}]"
	fi
}

install_run 0 -
ext_is "without caller tests: only the harness files"

install_run 0 packages/t test_a.py helper.py data.json sub/test_b.py README.md
ext_is "copies only the top-level *.py" test_a.py helper.py

for name in conftest.py harness_util.py test_package.py; do
	install_run 1 packages/t test_a.py "${name}"
	case "${ir_out}" in
	*"caller test file ${name} has the name of a harness file"*) record "install-tests collision message ${name}" 0 "" ;;
	*) record "install-tests collision message ${name}" 1 "${ir_out}" ;;
	esac
	if cmp -s "${ext}/${name}" "${script_dir}/../harness/tests/${name}"; then
		record "install-tests keeps the harness ${name}" 0 ""
	else
		record "install-tests keeps the harness ${name}" 1 "the caller file replaced it"
	fi
done

install_run 0 packages/missing
ext_is "missing directory: only the harness files"
case "${ir_out}" in
*"::notice::tests path packages/missing does not exist"*) record "install-tests missing directory notice" 0 "" ;;
*) record "install-tests missing directory notice" 1 "${ir_out}" ;;
esac

install_run 0 packages/t data.json
ext_is "directory without *.py: only the harness files"
case "${ir_out}" in
*"::notice::tests path packages/t has no *.py file"*) record "install-tests no *.py notice" 0 "" ;;
*) record "install-tests no *.py notice" 1 "${ir_out}" ;;
esac

for bad in ../t -t .git/hooks /abs; do
	install_run 1 "${bad}" test_a.py
	ext_is "invalid path '${bad}': nothing of the caller copied"
done

# --- with-test-secrets.sh -----------------------------------------------------

secret_nb='s3cr3t-nb-value'
secret_other='other-secret-value'
secret_token='ghs_token_value'
secret_special="va l\$ue\"q'x\\y"
secrets_json=$(jq -n --arg nb "${secret_nb}" --arg other "${secret_other}" \
	--arg token "${secret_token}" --arg special "${secret_special}" \
	'{NB_SETUP_KEY: $nb, OTHER_X: $other, github_token: $token, mixed_case_name: "mixed", SPECIAL_ONE: $special}')

# Reports, without printing a value, the state of the environment variables
# the wrapper must (not) pass to its command: unset, empty, set or equal to
# the expected value.
cat >"${work}/probe.sh" <<'EOF'
state() {
	line=$(env | grep "^$1=" || printf '')
	case "${line}" in
	'') printf '%s=unset ' "$1" ;;
	"$1=") printf '%s=empty ' "$1" ;;
	*) if [ "$(printenv "$1")" = "$2" ]; then printf '%s=match ' "$1"; else printf '%s=set ' "$1"; fi ;;
	esac
}
state NB_SETUP_KEY 's3cr3t-nb-value'
state SPECIAL_ONE 'va l$ue"q'"'"'x\y'
state MIXED_CASE_NAME mixed
state MISSING_Y x
state OTHER_X x
state GITHUB_TOKEN x
state HARNESS_SECRETS_JSON x
state HARNESS_TEST_SECRETS x
printf '\n'
EOF

# Reports a leak when HARNESS_SECRETS_JSON or a secret value is in the
# environment of this process or of any ancestor up to the self-test.
cat >"${work}/ancestors.sh" <<'EOF'
stop=$1
pid=$$
checked=0
while [ "${pid}" != "${stop}" ] && [ "${pid}" -gt 1 ]; do
	# The command itself legitimately has the listed secret.
	if [ "${pid}" = "$$" ]; then
		values='ghs_token_value'
	else
		values='s3cr3t-nb-value\|other-secret-value\|ghs_token_value'
	fi
	if tr '\0' '\n' <"/proc/${pid}/environ" | grep -q -e '^HARNESS_SECRETS_JSON=' -e "${values}"; then
		printf 'leak in pid %s (%s)\n' "${pid}" "$(tr '\0' ' ' <"/proc/${pid}/cmdline")"
		exit 3
	fi
	checked=$((checked + 1))
	stat=$(cat "/proc/${pid}/stat")
	pid=$(printf '%s' "${stat##*) }" | cut -d' ' -f2)
done
printf 'ancestors checked: %s\n' "${checked}"
EOF

# Run the wrapper with the given names and the fixed secrets JSON.
#
# Arguments:
#   $1  HARNESS_TEST_SECRETS
#   $2  HARNESS_SECRETS_JSON
#   $3...  command
wrapper_run() {
	wr_names=$1
	wr_json=$2
	shift 2
	wr_rc=0
	wr_out=$(HARNESS_TEST_SECRETS=${wr_names} HARNESS_SECRETS_JSON=${wr_json} \
		sh "${script_dir}/with-test-secrets.sh" "$@" 2>&1) || wr_rc=$?
}

# Check that the output contains a text.
#
# Arguments:
#   $1  case name
#   $2  text
has() {
	case "${wr_out}" in
	*"$2"*) record "$1" 0 "" ;;
	*) record "$1" 1 "missing [$2] in: ${wr_out}" ;;
	esac
}

# Check that no secret value appears in the output.
#
# Arguments:
#   $1  case name
no_values() {
	nv_bad=0
	for v in "${secret_nb}" "${secret_other}" "${secret_token}" "${secret_special}" mixed; do
		case "${wr_out}" in
		*"${v}"*) nv_bad=1 ;;
		*) ;;
		esac
	done
	record "$1" "${nv_bad}" "a secret value was printed: ${wr_out}"
}

wrapper_run 'NB_SETUP_KEY MISSING_Y,MIXED_CASE_NAME,SPECIAL_ONE' "${secrets_json}" sh "${work}/probe.sh"
record "secrets wrapper exit 0" "${wr_rc}" "exit ${wr_rc}: ${wr_out}"
has "listed secret is exported with its exact value" "NB_SETUP_KEY=match"
has "value with spaces and quotes is exported unchanged" "SPECIAL_ONE=match"
has "secret names are matched case-insensitively" "MIXED_CASE_NAME=match"
has "absent secret is exported empty" "MISSING_Y=empty"
has "unlisted secret is not exported" "OTHER_X=unset"
has "unlisted github_token is not exported" "GITHUB_TOKEN=unset"
has "the JSON of all secrets is not exported" "HARNESS_SECRETS_JSON=unset"
has "the name list is not exported" "HARNESS_TEST_SECRETS=unset"
has "log says a secret is set" "test-secrets: NB_SETUP_KEY is set"
has "log says a secret is absent" "test-secrets: MISSING_Y is absent or empty"
no_values "no secret value is printed"

wrapper_run '' "${secrets_json}" sh "${work}/probe.sh"
has "empty name list: no secret is exported" "NB_SETUP_KEY=unset"
has "empty name list: the JSON is not exported" "HARNESS_SECRETS_JSON=unset"

wrapper_run '' '' sh -c 'exit 7'
if [ "${wr_rc}" -eq 7 ]; then
	record "exit code of the command is passed on" 0 ""
else
	record "exit code of the command is passed on" 1 "exit ${wr_rc}"
fi

# GITHUB_TOKEN is in the JSON (as github_token), so the only thing that can
# stop the wrapper is its own check of the names, and the error must say so
# (a name like PATH would "pass" because exporting an empty PATH makes the
# command itself fail to start).
rm -f "${work}/ran"
wrapper_run 'GITHUB_TOKEN' "${secrets_json}" touch "${work}/ran"
if [ "${wr_rc}" -ne 0 ] && [ ! -e "${work}/ran" ]; then
	record "reserved name: command not run" 0 ""
else
	record "reserved name: command not run" 1 "exit ${wr_rc}"
fi
has "reserved name: refused by the name check" "invalid secret name (reserved prefix or name)"
no_values "reserved name: no secret value is printed"

wrapper_run 'NB_SETUP_KEY' '' touch "${work}/ran"
if [ "${wr_rc}" -ne 0 ] && [ ! -e "${work}/ran" ]; then
	record "names without secrets JSON: command not run" 0 ""
else
	record "names without secrets JSON: command not run" 1 "exit ${wr_rc}"
fi

wrapper_run 'NB_SETUP_KEY' "${secrets_json}" sh "${work}/ancestors.sh" "$$"
if [ "${wr_rc}" -eq 0 ]; then
	record "no ancestor of the command keeps the secrets JSON" 0 ""
	last_line=$(printf '%s\n' "${wr_out}" | tail -n 1)
	printf '     (%s)\n' "${last_line}"
else
	record "no ancestor of the command keeps the secrets JSON" 1 "${wr_out}"
fi
no_values "ancestor probe prints no secret value"

# --- result ---------------------------------------------------------------

if [ "${failures}" -ne 0 ]; then
	die "caller-inputs-selftest: ${failures} of ${checks} cases failed"
fi
printf 'caller-inputs-selftest: %s cases passed\n' "${checks}"
