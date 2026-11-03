#!/usr/bin/env sh
# Responsibility: read facts out of a uv.lock file (sourced, not run).
#
# Usage:
#   . "${script_dir}/lib/uv-lock.sh"
#
# Environment variables: none.

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
