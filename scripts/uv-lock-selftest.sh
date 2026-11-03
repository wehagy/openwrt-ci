#!/usr/bin/env sh
# Responsibility: prove with the real `uv` (no fake) that
# scripts/prepare-tests-env.sh holds labgrid to LABGRID_REQUIREMENT
# (lib/uv-lock.sh) and leaves the other dependencies at the seed lock. A
# fixture project and a package index on 127.0.0.1 (generated wheels, upload
# dates as PyPI gives them) replace PyPI and the openwrt-tests checkout, so
# the run needs no network: labgrid exists as 25.0.1, 26.0.0 (the seed's),
# 26.0.1 and 27.0.0, plus 26.0.2 uploaded after the resolution instant; the
# seed also holds other-dep 1.0, and other-dep 2.0 appears after the seed was
# made. The fixture
# pyproject.toml names labgrid as a git source, like upstream does, to prove
# that the source is ignored. Cases: the real requirement yields 26.0.1 (not
# 27.0.0, not 26.0.2 which is newer than the instant, not the seed's 26.0.0) and leaves other-dep at 1.0; `labgrid<26`
# yields 25.0.1; `labgrid<1`, which nothing satisfies, fails. A requirement
# only written to a uv.toml (as `constraint-dependencies`) does not hold, which
# is why prepare-tests-env.sh passes it to `uv lock`; the 27.0.0 case fails if
# that is undone.
#
# Usage:
#   scripts/uv-lock-selftest.sh
#
# Environment variables:
#   UV_SELFTEST_VERSION  uv version the run must use (optional; the workflow
#                        pins the one it installs, the container recipe in the
#                        README does the same); empty: any
#
# Needs: uv, python3 (3.11+ for tomllib), git.

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

uv_version=$(uv --version) || die "uv is not installed"
printf 'using %s\n' "${uv_version}"
if [ -n "${UV_SELFTEST_VERSION:-}" ]; then
	case "${uv_version}" in
	"uv ${UV_SELFTEST_VERSION} "* | "uv ${UV_SELFTEST_VERSION}") ;;
	*) die "expected uv ${UV_SELFTEST_VERSION}, found ${uv_version}" ;;
	esac
fi

# ---------------------------------------------------------------------------
# Fixture index
# ---------------------------------------------------------------------------

mkdir "${work}/simple"

# Serves ${work}/simple: <name>/index.json as the PEP 691 JSON index of the
# package (upload dates included, which `exclude-newer` needs), anything else
# as a file. The port is written to ${work}/port.
cat >"${work}/server.py" <<'EOF2'
import functools
import http.server
import sys


class Handler(http.server.SimpleHTTPRequestHandler):
    def send_head(self):
        if self.path.endswith("/"):
            self.path += "index.json"
        return super().send_head()

    def guess_type(self, path):
        if path.endswith("index.json"):
            return "application/vnd.pypi.simple.v1+json"
        return super().guess_type(path)

    def log_message(self, *args):
        pass


handler = functools.partial(Handler, directory=sys.argv[1])
server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
with open(sys.argv[2], "w") as f:
    f.write(str(server.server_address[1]))
server.serve_forever()
EOF2
python3 "${work}/server.py" "${work}/simple" "${work}/port" &
server_pid=$!
trap 'kill "${server_pid}"; rm -rf "${work}"' EXIT
tries=0
until [ -s "${work}/port" ]; do
	tries=$((tries + 1))
	[ "${tries}" -le 100 ] || die "the fixture index did not start"
	python3 -c 'import time; time.sleep(0.1)'
done

# Only the fixture index in place of PyPI, no interpreter download, a cache
# of its own.
unset UV_PYTHON UV_CONFIG_FILE UV_EXCLUDE_NEWER UV_NO_SOURCES UV_FIND_LINKS UV_EXTRA_INDEX_URL
UV_INDEX_URL=http://127.0.0.1:$(cat "${work}/port")/
UV_PYTHON_DOWNLOADS=never
UV_CACHE_DIR=${work}/uv-cache
export UV_INDEX_URL UV_PYTHON_DOWNLOADS UV_CACHE_DIR

# ---------------------------------------------------------------------------
# Fixture
# ---------------------------------------------------------------------------

# Add a wheel (a zip with dist-info, no code) of a package to the index.
#
# Arguments:
#   $1  package name
#   $2  version
#   $3  upload date (RFC 3339), default: before the resolution instant
make_wheel() {
	python3 - "${work}/simple" "$1" "$2" "${3:-2026-10-01T00:00:00Z}" <<'EOF2'
import hashlib
import json
import os
import sys
import zipfile

root, name, version, uploaded = sys.argv[1:5]
norm = name.replace("-", "_")
info = f"{norm}-{version}.dist-info"
files = {
    f"{info}/METADATA": f"Metadata-Version: 2.1\nName: {name}\nVersion: {version}\n",
    f"{info}/WHEEL": "Wheel-Version: 1.0\nGenerator: selftest\nRoot-Is-Purelib: true\nTag: py3-none-any\n",
    f"{info}/RECORD": "",
}
directory = os.path.join(root, name)
os.makedirs(directory, exist_ok=True)
filename = f"{norm}-{version}-py3-none-any.whl"
path = os.path.join(directory, filename)
with zipfile.ZipFile(path, "w") as z:
    for member, text in files.items():
        z.writestr(member, text)
with open(path, "rb") as f:
    digest = hashlib.sha256(f.read()).hexdigest()
index_path = os.path.join(directory, "index.json")
if os.path.exists(index_path):
    with open(index_path) as f:
        index = json.load(f)
else:
    index = {"meta": {"api-version": "1.1"}, "name": name, "files": []}
index["files"].append(
    {
        "filename": filename,
        "url": filename,
        "hashes": {"sha256": digest},
        "upload-time": uploaded,
    }
)
with open(index_path, "w") as f:
    json.dump(index, f)
EOF2
}

# Write the pyproject.toml of upstream's shape into a directory.
#
# Arguments:
#   $1  directory
#   $2  extra text appended to the file
make_project() {
	mkdir -p "$1"
	cat >"$1/pyproject.toml" <<EOF2
[project]
name = "fixture-tests"
version = "0"
requires-python = ">=3.9"
dependencies = ["labgrid>=25.0", "other-dep"]

[tool.uv.sources]
labgrid = { git = "https://invalid.example/labgrid", branch = "staging" }
$2
EOF2
}

make_wheel labgrid 25.0.1
make_wheel labgrid 26.0.0
make_wheel other-dep 1.0

# The seed is made as the project would have been before: labgrid 26.0.0.
make_project "${work}/seed" ""
UV_NO_SOURCES=1 uv --project "${work}/seed" lock >&2 ||
	die "cannot make the seed lock of the fixture"
tree=${work}/tree
mkdir -p "${tree}/scripts" "${tree}/harness"
cp "${script_dir}/prepare-tests-env.sh" "${tree}/scripts/"
cp -R "${script_dir}/lib" "${tree}/scripts/lib"
cp "${work}/seed/uv.lock" "${tree}/harness/openwrt-tests.uv.lock"
seed_labgrid=$(lock_package_version "${tree}/harness/openwrt-tests.uv.lock" labgrid)
seed_other=$(lock_package_version "${tree}/harness/openwrt-tests.uv.lock" other-dep)

# Releases that appear after the seed.
make_wheel labgrid 26.0.1
make_wheel labgrid 27.0.0
make_wheel labgrid 26.0.2 2026-11-04T00:00:00Z
make_wheel other-dep 2.0

git_t() { git -c user.name=selftest -c user.email=selftest@example.invalid "$@"; }
make_project "${work}/checkout" ""
git init -q -b main "${work}/checkout"
git_t -C "${work}/checkout" add pyproject.toml
git_t -C "${work}/checkout" commit -q -m fixture
tests_sha=$(git -C "${work}/checkout" rev-parse HEAD)

# Run the script of the copied tree on a fresh checkout state; stdout is the
# GITHUB_ENV text, stderr the uv output.
#
# Arguments:
#   $1  labgrid requirement to use instead of the committed one (optional)
prepare() (
	rm -rf "${work}/checkout/uv.lock" "${work}/checkout/.venv"
	if [ -n "${1:-}" ]; then
		HARNESS_LABGRID_REQUIREMENT=$1
		export HARNESS_LABGRID_REQUIREMENT
	fi
	HARNESS_TESTS_SHA=${tests_sha} HARNESS_TESTS_RESOLVED_AT=2026-11-03T10:00:00Z \
		"${tree}/scripts/prepare-tests-env.sh" "${work}/checkout"
)

# ---------------------------------------------------------------------------
# Cases
# ---------------------------------------------------------------------------

case "${seed_labgrid}:${seed_other}" in
26.0.0:1.0) record "fixture: the seed holds labgrid 26.0.0 and other-dep 1.0" 0 "" ;;
*) record "fixture: the seed holds labgrid 26.0.0 and other-dep 1.0" 1 "${seed_labgrid}:${seed_other}" ;;
esac

script_case "committed requirement: the script succeeds" 0 ANY prepare
case "${sc_out}" in
*HARNESS_LABGRID_VERSION=26.0.1) record "committed requirement: labgrid 26.0.1, neither 27.0.0 nor the seed's 26.0.0" 0 "" ;;
*) record "committed requirement: labgrid 26.0.1, neither 27.0.0 nor the seed's 26.0.0" 1 "${sc_out}" ;;
esac
other_locked=$(lock_package_version "${work}/checkout/uv.lock" other-dep)
check_other=1
[ "${other_locked}" = "${seed_other}" ] && check_other=0
record "committed requirement: other-dep stays at the seed's ${seed_other}" "${check_other}" "${other_locked}"
installed=$(UV_NO_SOURCES=1 uv --project "${work}/checkout" pip freeze --python "${work}/checkout/.venv" | grep -i '^labgrid==') || installed=
if [ "${installed}" = "labgrid==26.0.1" ]; then
	record "committed requirement: the environment has labgrid 26.0.1" 0 ""
else
	record "committed requirement: the environment has labgrid 26.0.1" 1 "${installed}"
fi

script_case "requirement labgrid<26: the script succeeds" 0 ANY prepare 'labgrid<26'
case "${sc_out}" in
*HARNESS_LABGRID_VERSION=25.0.1) record "requirement labgrid<26: labgrid 25.0.1" 0 "" ;;
*) record "requirement labgrid<26: labgrid 25.0.1" 1 "${sc_out}" ;;
esac

fails_case "requirement labgrid<1 (impossible): the script fails" prepare 'labgrid<1'

# A source other than labgrid is refused before uv runs.
make_project "${work}/other-source" 'requests = { git = "https://invalid.example/requests" }'
cp "${work}/other-source/pyproject.toml" "${work}/checkout/pyproject.toml"
fails_case "a uv source other than labgrid fails" prepare
err_text=$(cat "${work}/err")
case "${err_text}" in
*"uv sources other than labgrid"*"requests"*) record "the error names the extra source" 0 "" ;;
*) record "the error names the extra source" 1 "${err_text}" ;;
esac

printf '%s checks, %s failures\n' "${checks}" "${failures}"
[ "${failures}" -eq 0 ]
