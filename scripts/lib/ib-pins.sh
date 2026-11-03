#!/usr/bin/env sh
# Responsibility: install the locally built package in the Image Builder from
# its .apk file, prove afterwards that the image holds that very apk, and keep
# the pin of that install out of the image world (sourced, not run).
#
# The Image Builder resolves a package name against the local packages/ index
# and the official feeds together, takes the highest version and, at an equal
# version, a feed package; no <name> or <name>=<version> selects the local
# build for sure. A path to the .apk does: apk installs that file itself,
# whatever the feeds hold. The price is the world entry apk writes for a file,
# <name><><checksum>, which pins the device to that very file: a later
# `apk upgrade` would never take the package from the feed. The world of an
# official image lists <name> alone, so the world of the image is rewritten to
# that: the Image Builder copies the FILES directory over the root after the
# packages are installed, so a FILES/etc/apk/world with the plain names
# replaces the world apk wrote. The installed database keeps the record of
# the built .apk (its checksum is what proves the origin).
#
# To prove the origin, the same .apk is installed in a scratch root with the
# same repositories and the checksum of its record in the installed database
# must be the one of the record in the image root.
#
# Needs lib/common.sh. The dumps are the output of `apk adbdump` of the .apk
# (info: block); the installed database is the lib/apk/db/installed of a root.
#
# Usage:
#   . "${script_dir}/lib/common.sh"
#   . "${script_dir}/lib/ib-pins.sh"
#
# Environment variables: none.

# Print the package list with the built package given by the path of its
# .apk: every token of the list stays, except a bare <name>, which the path
# replaces; the path comes last. A "-<name>" token removing the built package
# is an error (the file would silently win over the removal). Other tokens,
# including "-<other>" removals and names that merely contain <name>, pass
# unchanged.
#
# Arguments:
#   $1  package list, tokens separated by spaces (see check_image_packages)
#   $2  name of the built package
#   $3  absolute path of its .apk
ib_local_packages() {
	check_package_name "$2"
	case "$3" in
	/*) ;;
	*) die "the path of the .apk must be absolute: $3" ;;
	esac
	case "$3" in
	*[!A-Za-z0-9._/+~-]*) die "unexpected character in the path of the .apk: $3" ;;
	*.apk) ;;
	*) die "not an .apk path: $3" ;;
	esac
	ilp_out=
	# The caller validated the list (no glob characters), so splitting is safe.
	for ilp_token in $1; do
		case "${ilp_token}" in
		"-$2") die "the packages input removes the built package $2" ;;
		"$2") ;;
		*=* | */*) die "a package of the packages input carries a version or a path" ;;
		*) ilp_out=${ilp_out:+${ilp_out} }${ilp_token} ;;
		esac
	done
	printf '%s\n' "${ilp_out:+${ilp_out} }$3"
}

# Print the value of one field of the info: block of an `apk adbdump` of a
# package file; empty when the field is absent.
#
# Arguments:
#   $1  file with the dump
#   $2  field name, e.g. name or version
adb_info_field() {
	awk -v f="$2" '
		$0 == "info:" { inside = 1; next }
		inside && !/^  / { exit }
		inside && index($0, "  " f ": ") == 1 { print substr($0, length(f) + 5); exit }
	' "$1" || die "cannot read the dump $1"
}

# Print the record of one package in an installed database (the lines from
# P:<name> up to the blank line); empty when the package is not there.
#
# Arguments:
#   $1  installed database
#   $2  package name
installed_record() {
	awk -v n="$2" '
		BEGIN { RS = ""; ORS = "\n\n" }
		{ if (index("\n" $0 "\n", "\nP:" n "\n")) print }
	' "$1" || die "cannot read the installed database $1"
}

# Print the checksum of an installed package as 40 hex digits: the "C:" line
# of its record in the installed database, Q1 plus the base64 of 20 bytes.
# Empty when the package is not there.
#
# Arguments:
#   $1  installed database (or a record of it)
#   $2  package name
installed_checksum_hex() {
	ich_line=$(awk -v n="$2" '
		BEGIN { RS = ""; FS = "\n" }
		{ hit = 0; sum = ""
		  for (i = 1; i <= NF; i++) {
			if ($i == "P:" n) hit = 1
			if (substr($i, 1, 4) == "C:Q1") sum = substr($i, 5)
		  }
		  if (hit) print sum }
	' "$1") || die "cannot read the installed database $1"
	case "${ich_line}" in
	'') return 0 ;;
	*"
"*) die "the installed database lists $2 more than once" ;;
	*[!A-Za-z0-9+/=]*) die "invalid checksum in the installed database" ;;
	*) ;;
	esac
	ich_hex=$(printf '%s' "${ich_line}" | base64 -d | od -An -tx1 | tr -d ' \n') ||
		die "cannot decode the checksum of $2"
	[ "${#ich_hex}" -eq 40 ] || die "unexpected checksum length for $2"
	printf '%s\n' "${ich_hex}"
}

# Abort unless the package installed in the image is the apk built here: the
# checksum of its record in the installed database of the image root must be
# the one of the record apk wrote when it installed that same .apk in a
# scratch root. A package of the feeds, whatever its version, has another one.
#
# Arguments:
#   $1  installed database (or the record) of the scratch root
#   $2  installed database (or the record) of the image root
#   $3  package name
ib_check_installed_is_local() {
	icl_expected=$(installed_checksum_hex "$1" "$3")
	[ -n "${icl_expected}" ] || die "$3 is not in the installed database of the scratch root"
	icl_installed=$(installed_checksum_hex "$2" "$3")
	[ -n "${icl_installed}" ] || die "$3 is not in the installed database of the image"
	[ "${icl_installed}" = "${icl_expected}" ] ||
		die "the image holds a $3 that is not the locally built apk (installed ${icl_installed}, local ${icl_expected}); a package of the feed won"
	printf 'ib-pins: %s installed from the local apk (checksum %s)\n' "$3" "${icl_installed}" >&2
}

# Print the world apk wrote for the install by path, with the pin of the built
# package removed: its entry <name><><checksum> becomes <name>, every other
# line stays as it is. The entry must be there exactly once, and no other
# entry may be a pin by checksum, a path or a repository tag: those would
# reach the image through the rewritten file.
#
# Arguments:
#   $1  world file of the root the packages were installed in
#   $2  name of the built package
ib_plain_world() {
	check_package_name "$2"
	ipw_out=$(awk -v n="$2" '
		BEGIN { pin = n "><Q1" }
		substr($0, 1, length(pin)) == pin && substr($0, length(pin) + 1) ~ /^[A-Za-z0-9+\/=]+$/ {
			print n; hits++; next
		}
		{ print }
		END { if (hits != 1) exit 3 }
	' "$1") || die "the world $1 has no single entry '$2><checksum' (or cannot be read)"
	ib_check_plain_names "${ipw_out}"
	printf '%s\n' "${ipw_out}"
}

# Abort when a world (the text of an /etc/apk/world) has an entry that is not
# a plain name: a pin by checksum (><), a repository tag (@) or a path (/).
#
# Arguments:
#   $1  text of the world
ib_check_plain_names() {
	icp_bad=$(printf '%s\n' "$1" | grep -n -e '><' -e '@' -e '/') ||
		icp_bad=
	[ -z "${icp_bad}" ] || die "the world has an entry that is not a plain name: ${icp_bad}"
}

# Abort unless the world of the image is the world apk wrote with only the pin
# of the built package replaced by its plain name, which is what an image
# built without a package of our own lists.
#
# Arguments:
#   $1  world file of the image root
#   $2  world file apk wrote for the install by path
#   $3  package name
ib_check_world() {
	icw_expected=$(ib_plain_world "$2" "$3")
	[ -n "${icw_expected}" ] || die "no world of the install to compare the world of the image with"
	icw_image=$(cat "$1") || die "cannot read the world $1"
	ib_check_plain_names "${icw_image}"
	[ "${icw_image}" = "${icw_expected}" ] ||
		die "the world of the image is not the world of the install with $3 by name"
	printf 'ib-pins: the world of the image lists %s by name\n' "$3" >&2
}
