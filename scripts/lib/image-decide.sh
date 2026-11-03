#!/usr/bin/env sh
# Responsibility: the decisions about the harness images on GHCR (SDK and
# Image Builder), as pure functions with no network (sourced, not run): the
# daily refresh rebuilds an image only when what it is made of changed
# (image_decide), and a run that reads an image says whether it is stale
# (image_stale_decide). There is no age rule in the refresh: an image whose
# upstream did not change is kept, however old.
#
# Usage:
#   . "${script_dir}/lib/common.sh"
#   . "${script_dir}/lib/image-decide.sh"
#
# Environment variables: none.

# Print the Unix time of a UTC timestamp written as YYYY-MM-DDTHH:MM:SSZ;
# fail without a message when it is malformed. The value is never echoed (see
# check_package_name in common.sh).
#
# Arguments:
#   $1  timestamp
sdk_parse_utc() {
	case "$1" in
	[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
	*) return 1 ;;
	esac
	date -u -d "$1" +%s
}

# Like sdk_parse_utc, but aborts the calling script on a malformed timestamp.
#
# Arguments:
#   $1  timestamp
utc_to_epoch() {
	sdk_parse_utc "$1" || die "invalid timestamp (allowed: YYYY-MM-DDTHH:MM:SSZ)"
}

# Print "<decision> <reason>" for one image tag: decision is "reuse" or
# "rebuild". The single place where the refresh makes the choice, used by
# scripts/image-refresh.sh and proved by scripts/image-decide-selftest.sh.
# Rebuild when the image is missing; when it was built from another recipe
# (the Dockerfile) or from another upstream address than the current ones (an
# image of an older recipe is never reused, however young); when its source
# identity is not the upstream's now (the sha256 of the SDK or Image Builder
# archive, or the digest of the official container that is mirrored); when
# its creation time is unreadable (the rebuild heals it); or when a forced
# refresh asks for an image created before it. Otherwise reuse.
#
# Arguments:
#   $1  image exists: true or false
#   $2  creation time label, YYYY-MM-DDTHH:MM:SSZ (ignored when missing)
#   $3  refresh point, Unix seconds: an image created before it is rebuilt;
#       empty when no forced refresh was requested
#   $4  sha256 of the current recipe (docker/*-image/Dockerfile)
#   $5  the same, as the image label recorded it (empty when it has none)
#   $6  upstream address of the archive checksums now (empty for a mirror)
#   $7  the same, as the image label recorded it
#   $8  source identity now (archive sha256 or container digest)
#   $9  the same, as the image label recorded it
image_decide() {
	if [ "$1" != true ]; then
		printf 'rebuild image missing\n'
		return 0
	fi
	if [ "$5" != "$4" ]; then
		printf 'rebuild Dockerfile changed since the image was built\n'
		return 0
	fi
	if [ "$7" != "$6" ]; then
		printf 'rebuild upstream address changed or not recorded\n'
		return 0
	fi
	if [ "$9" != "$8" ]; then
		printf 'rebuild upstream changed (image %s, now %s)\n' "$9" "$8"
		return 0
	fi
	if ! id_created=$(sdk_parse_utc "$2"); then
		printf 'rebuild creation time unreadable\n'
		return 0
	fi
	if [ -n "$3" ] && [ "${id_created}" -lt "$3" ]; then
		printf 'rebuild forced refresh requested\n'
		return 0
	fi
	if [ -n "$3" ]; then
		printf 'reuse refreshed since the request, upstream %s\n' "$8"
	else
		printf 'reuse upstream unchanged %s\n' "$8"
	fi
}

# Print "<state> <reason>" about an image a run reads: state is "fresh",
# "stale" or "unknown". An image that matches upstream is fresh. One that does
# not is stale only when it is also older than the grace period: the daily
# refresh runs at most that long after upstream published, so a younger image
# is waiting for it, not late. Only a warning is raised for stale and unknown.
#
# Arguments:
#   $1  creation time label, YYYY-MM-DDTHH:MM:SSZ
#   $2  current time, Unix seconds
#   $3  grace period, days
#   $4  the image differs from upstream now: true or false
image_stale_decide() {
	if [ "$4" != true ] && [ "$4" != false ]; then
		printf 'unknown comparison with upstream missing\n'
		return 0
	fi
	if ! is_created=$(sdk_parse_utc "$1"); then
		printf 'unknown creation time unreadable\n'
		return 0
	fi
	is_age=$(($2 - is_created))
	if [ "${is_age}" -lt 0 ]; then
		printf 'unknown created in the future (age %s s)\n' "${is_age}"
		return 0
	fi
	if [ "$4" = false ]; then
		printf 'fresh matches upstream (age %s s)\n' "${is_age}"
	elif [ "${is_age}" -le $(($3 * 86400)) ]; then
		printf 'fresh differs from upstream but is %s s old, within %s day(s)\n' "${is_age}" "$3"
	else
		printf 'stale differs from upstream and is %s s old, over %s day(s)\n' "${is_age}" "$3"
	fi
}

# Print, on stderr, the annotation of a run that finds an image missing (or
# private): the caller then ends with die. It goes to stderr because the
# scripts that call this print their results on stdout, which a step captures
# or appends to $GITHUB_ENV. The run only reads the images; the daily refresh
# writes them. The refresh is a workflow of the CALLER repository (the one
# that schedules refresh-images.yml), not necessarily the repository whose
# workflow is running, so the command names the repository given.
#
# Arguments:
#   $1  image, <container>:<tag>
#   $2  repository that owns the refresh workflow, <owner>/<name>
image_missing_error() {
	printf '::error title=Image missing::%s is missing or not public. The runs only read it; the daily refresh (refresh-images.yml) creates it, but only the images that the package configs of %s name (lines, QEMU targets, image profiles in packages/<name>/config.yml). Refresh by hand: %s (add -f force=true to rebuild images that are up to date); if the architecture or the profile is not in a config, add it there first. The package must be public.\n' \
		"$1" "$2" "$(refresh_command "$2")" >&2
}

# Print the command that refreshes the images by hand, for the message of a
# run that finds an image missing.
#
# Arguments:
#   $1  repository that owns the refresh workflow, <owner>/<name>
refresh_command() {
	printf 'gh workflow run refresh-images.yml --repo %s\n' "$1"
}
