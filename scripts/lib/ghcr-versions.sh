#!/usr/bin/env sh
# Responsibility: delete one version of a GHCR package through the packages
# API with the gh CLI (sourced, not run). A version that is already gone
# (HTTP 404, e.g. deleted by a concurrent run that superseded the same
# -prev version) is a success; every other error is fatal.
#
# Usage:
#   . "${script_dir}/lib/common.sh"
#   . "${script_dir}/lib/ghcr-versions.sh"
#   ghcr_delete_version "${packages_api}" "${version_id}"
#
# Environment variables:
#   GH_TOKEN  token with packages: write, for the gh CLI

# Delete the package version with the given id. Prints "deleted" or
# "already-gone" on stdout (the caller tells which); an HTTP 404 from the API
# is logged on stderr and is not an error. Any other failure prints the gh
# error and aborts.
#
# Arguments:
#   $1  packages API path, /users/<owner>/packages/container/<name> or the
#       /orgs/ form
#   $2  numeric version id
ghcr_delete_version() {
	gdv_err=$(mktemp) || die "cannot create a temporary file"
	gdv_rc=0
	gh api -X DELETE "$1/versions/$2" >/dev/null 2>"${gdv_err}" || gdv_rc=$?
	if [ "${gdv_rc}" -eq 0 ]; then
		rm -f "${gdv_err}"
		printf 'deleted\n'
		return 0
	fi
	# gh prints "gh: <message> (HTTP <code>)"; only the exact 404 is benign.
	if grep -Fq '(HTTP 404)' "${gdv_err}"; then
		printf 'sdk-image: version %s already deleted by another run (HTTP 404)\n' "$2" >&2
		rm -f "${gdv_err}"
		printf 'already-gone\n'
		return 0
	fi
	cat "${gdv_err}" >&2
	rm -f "${gdv_err}"
	die "cannot delete the version $2"
}
