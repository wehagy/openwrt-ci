#!/usr/bin/env sh
# Responsibility: delete one version of a GHCR package through the packages
# API with the gh CLI (sourced, not run). A version that is already gone
# (HTTP 404 on the delete, e.g. deleted by a concurrent run that superseded
# the same -prev version) is a success, but only when a fresh listing of the
# package versions no longer has it: GitHub answers 404 instead of 403 for
# some requests the token may not make, and a 404 for a version that is still
# listed would hide a missing permission. Every other error is fatal.
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
# for a version that a fresh listing no longer has is logged on stderr and is
# not an error. Any other failure, including a 404 for a version that is still
# listed, prints the gh error and aborts.
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
	# gh prints "gh: <message> (HTTP <code>)"; only the exact 404 can be benign.
	if grep -Fq '(HTTP 404)' "${gdv_err}"; then
		# The listing needs the same access as the delete: a version it still
		# shows was not deleted by anyone, so the 404 is not "already gone".
		gdv_left=$(gh api --paginate "$1/versions" --jq ".[] | select(.id == $2) | .id") ||
			die "cannot list the versions to confirm that $2 is gone"
		if [ -z "${gdv_left}" ]; then
			printf 'sdk-image: version %s already deleted by another run (HTTP 404)\n' "$2" >&2
			rm -f "${gdv_err}"
			printf 'already-gone\n'
			return 0
		fi
		cat "${gdv_err}" >&2
		rm -f "${gdv_err}"
		die "HTTP 404 on the delete of the version $2, which is still listed: the token can read the package but not delete the version (check the role of the repository in the package settings, Manage Actions access)"
	fi
	cat "${gdv_err}" >&2
	rm -f "${gdv_err}"
	die "cannot delete the version $2"
}
