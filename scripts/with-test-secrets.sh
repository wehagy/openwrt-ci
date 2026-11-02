#!/usr/bin/env sh
# Responsibility: run a command with the caller secrets named in
# HARNESS_TEST_SECRETS exported as environment variables of that command only
# (not written to GITHUB_ENV, so no other step sees them). The workflow gives
# the secrets as JSON in HARNESS_SECRETS_JSON (toJSON(secrets)); without
# `secrets: inherit` it holds only github_token (proved in a run), so every
# listed name is absent. Values are never printed: the log shows only, per
# name, whether the secret is set. A name that is not a secret of the caller
# is exported empty, so the test sees "absent" and can skip with a reason.
#
# The JSON is removed before the command starts, and the command replaces this
# process (exec). The caller must exec this script from its step too (`run:
# exec ...`): a step bash left above would keep the JSON in its environment,
# readable through /proc/<ppid>/environ by every descendant.
#
# Usage:
#   scripts/with-test-secrets.sh <command> [args...]
#
# Environment variables:
#   HARNESS_TEST_SECRETS  secret names, separated by spaces or commas; empty
#                         or unset: the command runs unchanged
#   HARNESS_SECRETS_JSON  JSON object with the secrets of the caller

set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "${script_dir}/lib/common.sh"

[ "$#" -ge 1 ] || die "usage: with-test-secrets.sh <command> [args...]"
names=${HARNESS_TEST_SECRETS:-}
secrets_json=${HARNESS_SECRETS_JSON:-}
unset HARNESS_SECRETS_JSON HARNESS_TEST_SECRETS

if [ -n "${names}" ]; then
	check_secret_names "${names}"
	[ -n "${secrets_json}" ] || die "test secrets requested but HARNESS_SECRETS_JSON is empty"
	for name in $(printf '%s' "${names}" | tr ',' ' '); do
		# Secret names are case-insensitive; the value is passed to jq's
		# stdout only, never to its arguments.
		value=$(printf '%s' "${secrets_json}" | jq -r --arg n "${name}" \
			'to_entries | map(select(.key | ascii_upcase == $n)) | (.[0].value // "")') ||
			die "cannot read the secrets"
		if [ -n "${value}" ]; then
			printf 'test-secrets: %s is set\n' "${name}" >&2
		else
			printf 'test-secrets: %s is absent or empty\n' "${name}" >&2
		fi
		export "${name}=${value}"
	done
fi
unset secrets_json value
exec "$@"
