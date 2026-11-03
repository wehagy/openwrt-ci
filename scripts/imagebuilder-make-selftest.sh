#!/usr/bin/env sh
# Responsibility: prove the ImageBuilder step of scripts/imagebuilder-make.sh
# that the fallback of a custom image depends on, with a fake make and a fake
# scripts/ib-setup.sh (a copy of the script runs next to the fake, so nothing
# is downloaded): HARNESS_IB_SETUP=true runs ib-setup.sh once with the TARGET
# of the build and records how long it took in setup-seconds; false (the
# default) runs nothing and needs the Makefile of the Image Builder in the
# current directory; any other value fails before anything runs; a failing
# setup stops the build. A fake `date` is the clock, so the seconds are exact.
# The build itself is the one of a run without a package of our own (the
# package path is proven end to end in the images job).
#
# Usage:
#   scripts/imagebuilder-make-selftest.sh
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

failures=0
checks=0
work=$(mktemp -d) || die "cannot create a temporary directory"
trap 'rm -rf "${work}"' EXIT

# ---------------------------------------------------------------------------
# Fixtures: a copy of the script with a fake ib-setup.sh next to it, a fake
# clock and a fake make.
# ---------------------------------------------------------------------------
tools=${work}/tools
mkdir -p "${tools}/scripts/lib" "${tools}/bin"
cp "${script_dir}/imagebuilder-make.sh" "${tools}/scripts/imagebuilder-make.sh" ||
	die "cannot copy imagebuilder-make.sh"
cp "${script_dir}/lib/common.sh" "${script_dir}/lib/ib-pins.sh" "${tools}/scripts/lib/" ||
	die "cannot copy the libraries"

# The fake ib-setup.sh: records its TARGET and takes FAKE_SETUP_SECONDS on the
# fake clock; FAKE_SETUP_RC is its exit status.
cat >"${tools}/scripts/ib-setup.sh" <<'EOF'
#!/usr/bin/env sh
printf 'ib-setup TARGET=%s\n' "${TARGET:-}" >>"${FAKE_CALLS}"
echo $(($(cat "${FAKE_CLOCK}") + ${FAKE_SETUP_SECONDS:-0})) >"${FAKE_CLOCK}"
exit "${FAKE_SETUP_RC:-0}"
EOF

# The fake clock: `date +%s` prints the clock file.
cat >"${tools}/bin/date" <<'EOF'
#!/usr/bin/env sh
[ "$*" = "+%s" ] || exec /bin/date "$@"
cat "${FAKE_CLOCK}"
EOF

# The fake make: records its arguments and, for `image`, leaves what the real
# one leaves (a root filesystem in build_dir and the images in bin/targets).
cat >"${tools}/bin/make" <<'EOF'
#!/usr/bin/env sh
printf 'make %s\n' "$*" >>"${FAKE_CALLS}"
case "$1" in
image)
	mkdir -p build_dir/x "bin/targets/${FAKE_TARGET_PATH}"
	printf 'rootfs' >build_dir/x/root.squashfs
	: >"bin/targets/${FAKE_TARGET_PATH}/image.bin"
	echo "make: image done"
	exit "${FAKE_MAKE_RC:-0}"
	;;
*)
	echo "fake make: unexpected target $1" >&2
	exit 99
	;;
esac
EOF
chmod +x "${tools}/scripts/ib-setup.sh" "${tools}/bin/date" "${tools}/bin/make"

calls_log=${work}/calls.log
cases=0

# Run the copy of imagebuilder-make.sh in a fresh Image Builder directory
# (with a Makefile unless `nomakefile` is given) and an empty output
# directory; the directories of the last run are img and out.
#
# Arguments:
#   $@  extra environment assignments (later ones win); `unset:NAME` removes
#       a variable; `nomakefile` leaves the directory without a Makefile
run_make() {
	cases=$((cases + 1))
	img=${work}/img-${cases}
	out=${work}/out-${cases}
	mkdir -p "${img}" "${out}"
	: >"${calls_log}"
	echo 1000 >"${work}/clock"
	# The case's variables go through env so that an unset one is really unset.
	unset_args=
	makefile=true
	rm_n=$#
	rm_i=0
	while [ "${rm_i}" -lt "${rm_n}" ]; do
		rm_a=$1
		shift
		case "${rm_a}" in
		unset:*) unset_args="${unset_args} -u ${rm_a#unset:}" ;;
		nomakefile) makefile=false ;;
		*) set -- "$@" "${rm_a}" ;;
		esac
		rm_i=$((rm_i + 1))
	done
	if [ "${makefile}" = true ]; then
		: >"${img}/Makefile"
	fi
	(
		cd "${img}"
		# shellcheck disable=SC2086 # unset_args is a list of `-u NAME`
		env ${unset_args} PATH="${tools}/bin:${PATH}" \
			FAKE_CALLS="${calls_log}" FAKE_CLOCK="${work}/clock" \
			FAKE_TARGET_PATH=x/y HARNESS_PROFILE=p HARNESS_PACKAGES='a b' \
			HARNESS_TARGET_PATH=x/y HARNESS_PACKAGE= HARNESS_OUT_DIR="${out}" \
			"$@" sh "${tools}/scripts/imagebuilder-make.sh"
	)
}

# Record whether the calls of the last run have (or lack) a text.
#
# Arguments:
#   $1  case name   $2 text   $3 "has" or "lacks"
calls() {
	if grep -qxF -- "$2" "${calls_log}"; then c_has=has; else c_has=lacks; fi
	if [ "${c_has}" = "$3" ]; then record "$1" 0 ""; else record "$1" 1 "calls ${c_has} \"$2\": $(cat "${calls_log}")"; fi
}

# Record whether a file of the output directory holds exactly a text.
#
# Arguments:
#   $1  case name   $2 file name   $3 expected content
out_is() {
	if [ -f "${out}/$2" ]; then o_got=$(cat "${out}/$2"); else o_got="(no file)"; fi
	if [ "${o_got}" = "$3" ]; then record "$1" 0 ""; else record "$1" 1 "$2 is [${o_got}], expected [$3]"; fi
}

# Record whether the stderr of the last script_case has a text.
#
# Arguments:
#   $1  case name   $2 text
err_has() {
	if grep -qF -- "$2" "${work}/err"; then record "$1" 0 ""; else record "$1" 1 "stderr: $(cat "${work}/err")"; fi
}

# ---------------------------------------------------------------------------
# HARNESS_IB_SETUP=true: the Image Builder is downloaded in the job.
# ---------------------------------------------------------------------------
script_case "setup true: the build succeeds" 0 ANY run_make nomakefile \
	HARNESS_IB_SETUP=true FAKE_SETUP_SECONDS=7
calls "setup true: ib-setup.sh runs with the target of the build" "ib-setup TARGET=x/y" has
calls "setup true: the image is built" "make image PROFILE=p PACKAGES=a b" has
out_is "setup true: the seconds of the setup are recorded" setup-seconds 7
out_is "setup true: make succeeded" make.rc 0
if [ -f "${out}/image.bin" ]; then record "setup true: the images are copied" 0 ""; else record "setup true: the images are copied" 1 "no image.bin"; fi
n=$(grep -c '^ib-setup' "${calls_log}") || [ "$?" -eq 1 ] || die "grep failed"
if [ "${n}" -eq 1 ]; then record "setup true: ib-setup.sh runs once" 0 ""; else record "setup true: ib-setup.sh runs once" 1 "ran ${n} times"; fi

# Another duration, so that a constant is not taken for the measurement.
script_case "setup true: another duration" 0 ANY run_make nomakefile \
	HARNESS_IB_SETUP=true FAKE_SETUP_SECONDS=31
out_is "setup true: the seconds follow the clock" setup-seconds 31

# The Makefile of the downloaded Image Builder is not needed before setup.
script_case "setup true: a directory with a Makefile also runs setup" 0 ANY run_make \
	HARNESS_IB_SETUP=true FAKE_SETUP_SECONDS=2
calls "setup true with a Makefile: ib-setup.sh still runs" "ib-setup TARGET=x/y" has

# A failing setup ends the build before make.
script_case "setup true: a failing setup fails the build" 1 ANY run_make nomakefile \
	HARNESS_IB_SETUP=true FAKE_SETUP_RC=1
calls "setup failed: ib-setup.sh ran" "ib-setup TARGET=x/y" has
calls "setup failed: no image is built" "make image PROFILE=p PACKAGES=a b" lacks

# ---------------------------------------------------------------------------
# HARNESS_IB_SETUP=false (or unset): the Image Builder is in the image.
# ---------------------------------------------------------------------------
script_case "setup false: the build succeeds" 0 ANY run_make HARNESS_IB_SETUP=false FAKE_SETUP_SECONDS=7
calls "setup false: ib-setup.sh does not run" "ib-setup TARGET=x/y" lacks
calls "setup false: the image is built" "make image PROFILE=p PACKAGES=a b" has
out_is "setup false: no seconds of setup" setup-seconds 0

script_case "setup unset: the build succeeds" 0 ANY run_make unset:HARNESS_IB_SETUP FAKE_SETUP_SECONDS=7
calls "setup unset: ib-setup.sh does not run (the default is false)" "ib-setup TARGET=x/y" lacks
out_is "setup unset: no seconds of setup" setup-seconds 0

# Without the setup the Makefile must be there: an image that holds no Image
# Builder fails with a clear message instead of an error of make.
script_case "setup false: no Makefile fails" 1 ANY run_make nomakefile HARNESS_IB_SETUP=false
err_has "setup false: no Makefile says there is no Image Builder" "no ImageBuilder in the image"
calls "setup false: no Makefile, no image is built" "make image PROFILE=p PACKAGES=a b" lacks
script_case "setup unset: no Makefile fails" 1 ANY run_make nomakefile unset:HARNESS_IB_SETUP
err_has "setup unset: no Makefile says there is no Image Builder" "no ImageBuilder in the image"

# ---------------------------------------------------------------------------
# Anything else is refused before anything runs.
# ---------------------------------------------------------------------------
for bad in yes True 1 "true "; do
	script_case "setup '${bad}': refused" 1 ANY run_make "HARNESS_IB_SETUP=${bad}"
	err_has "setup '${bad}': the message names the variable" "HARNESS_IB_SETUP must be true or false"
	calls "setup '${bad}': ib-setup.sh does not run" "ib-setup TARGET=x/y" lacks
	calls "setup '${bad}': no image is built" "make image PROFILE=p PACKAGES=a b" lacks
done

# ---------------------------------------------------------------------------
# A failing make still fails the build, whatever the setup.
# ---------------------------------------------------------------------------
script_case "setup true: a failing make fails the build" 1 ANY run_make nomakefile \
	HARNESS_IB_SETUP=true FAKE_SETUP_SECONDS=5 FAKE_MAKE_RC=2
err_has "setup true: the failing make is reported" "make image failed with status 2"
out_is "setup true: the seconds are written before make runs" setup-seconds 5

echo
if [ "${failures}" -ne 0 ]; then
	printf 'imagebuilder-make-selftest: %s of %s cases FAILED\n' "${failures}" "${checks}" >&2
	exit 1
fi
printf 'imagebuilder-make-selftest: %s cases passed\n' "${checks}"
