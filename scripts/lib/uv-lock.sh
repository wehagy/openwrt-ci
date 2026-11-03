#!/usr/bin/env sh
# Responsibility: facts about the uv environment of the openwrt-tests checkout
# (sourced, not run): the one place that says which labgrid releases are
# accepted, the reader of a uv.lock file and the check of the uv sources
# the pyproject.toml declares.
#
# Usage:
#   . "${script_dir}/lib/uv-lock.sh"
#
# Environment variables: none.

# ---------------------------------------------------------------------------
# labgrid requirement
# ---------------------------------------------------------------------------

# labgrid comes from PyPI, "always the latest without the major": a new major
# is a decision of ours, not a surprise. uv ignores `constraint-dependencies`
# and `override-dependencies` given in a uv.toml, so the requirement is passed
# as `uv lock --upgrade-package "${LABGRID_REQUIREMENT}"`, which limits what
# that upgrade may pick (scripts/uv-lock-selftest.sh proves it with a real uv).
# shellcheck disable=SC2034 # used by the scripts that source this file
LABGRID_REQUIREMENT='labgrid>=26,<27'

# ---------------------------------------------------------------------------
# uv.lock reader
# ---------------------------------------------------------------------------

# Print the locked version of a package; abort when the lock has none or
# several entries of that name (a lock with a package twice is ambiguous).
# The name is compared whole: `pyserial-labgrid` is not `labgrid`.
#
# Arguments:
#   $1  uv.lock file
#   $2  package name, as written in the lock
lock_package_version() {
	lpv_found=$(awk -v want="$2" '
		$0 == "[[package]]" { name = ""; next }
		$1 == "name" && $2 == "=" && name == "" {
			name = $3
			gsub(/"/, "", name)
			next
		}
		$1 == "version" && $2 == "=" && name == want {
			version = $3
			gsub(/"/, "", version)
			print version
			name = ""
		}
	' "$1") || die "cannot read $1"
	case "${lpv_found}" in
	'') die "$2 is not in $1" ;;
	*"
"*) die "$2 has several entries in $1" ;;
	*) printf '%s\n' "${lpv_found}" ;;
	esac
}

# ---------------------------------------------------------------------------
# uv sources
# ---------------------------------------------------------------------------

# Abort when the pyproject.toml has a `[tool.uv.sources]` entry other than the
# allowed one. UV_NO_SOURCES=1 makes uv drop every entry in silence, so an
# upstream that starts to take another package from git or a path would get
# the PyPI release of it without a word; failing here makes that visible.
#
# Arguments:
#   $1  pyproject.toml
#   $2  the one package whose source may be dropped (normalised name)
check_uv_sources() {
	cus_other=$(
		python3 - "$1" "$2" <<'EOF2'
import re
import sys
import tomllib

with open(sys.argv[1], "rb") as f:
    data = tomllib.load(f)
sources = data.get("tool", {}).get("uv", {}).get("sources", {})
for name in sorted(sources):
    if re.sub(r"[-_.]+", "-", name).lower() != sys.argv[2]:
        print(name)
EOF2
	) || die "cannot read the uv sources of $1"
	[ -z "${cus_other}" ] || {
		cus_names=$(printf '%s' "${cus_other}" | tr '\n' ' ')
		die "$1 has uv sources other than $2 (UV_NO_SOURCES=1 would drop them): ${cus_names}"
	}
}
