#!/usr/bin/env sh
# Responsibility: pin the locally built package in the Image Builder package
# list and prove afterwards that the image holds that very apk (sourced, not
# run). The Image Builder resolves PACKAGES against the local packages/ index
# and the official feeds together and takes the highest version, so a bare
# <name> installs the feed's package whenever it is newer than, or equal to,
# the one built here. <name>=<version> makes the version exact; since an equal
# version may still come from the feed, the checksum of the installed package
# is compared with the one of the local index.
#
# Needs lib/common.sh. The dumps are the output of `apk adbdump` of the .apk
# (info: block) and of packages.adb (index); the installed database is the
# lib/apk/db/installed of the image root.
#
# Usage:
#   . "${script_dir}/lib/common.sh"
#   . "${script_dir}/lib/ib-pins.sh"
#
# Environment variables: none.

# Print the package list with the built package pinned: every token of the
# list stays, except a bare <name>, which the pin replaces; <name>=<version>
# comes last. A "-<name>" token removing the built package is an error (the
# pin would silently win over the removal). Other tokens, including
# "-<other>" removals and names that merely contain <name>, pass unchanged.
#
# Arguments:
#   $1  package list, tokens separated by spaces (see check_image_packages)
#   $2  name of the built package
#   $3  version of the built package, from the metadata of its .apk
ib_pin_packages() {
	check_package_name "$2"
	check_apk_version "$3"
	ipp_out=
	# The caller validated the list (no glob characters), so splitting is safe.
	for ipp_token in $1; do
		case "${ipp_token}" in
		"-$2") die "the packages input removes the built package $2" ;;
		"$2") ;;
		*=*) die "a package of the packages input carries a version (name=version)" ;;
		*) ipp_out=${ipp_out:+${ipp_out} }${ipp_token} ;;
		esac
	done
	printf '%s\n' "${ipp_out:+${ipp_out} }$2=$3"
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

# Print the sha256 ("hashes:") that the index dump gives the package entry of
# the name and version; empty when there is no such entry, and an error when
# there are two.
#
# Arguments:
#   $1  file with the `apk adbdump` of packages.adb
#   $2  package name
#   $3  package version
adb_index_hash() {
	aih_hashes=$(awk -v n="$2" -v v="$3" '
		/^  - name: / { name = substr($0, 11); version = ""; next }
		/^    version: / { version = substr($0, 14); next }
		/^    hashes: / { if (name == n && version == v) print substr($0, 13) }
	' "$1") || die "cannot read the dump $1"
	case "${aih_hashes}" in
	*"
"*) die "the index lists $2 $3 more than once" ;;
	*) ;;
	esac
	printf '%s\n' "${aih_hashes}"
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
# of its record in the installed database, Q1 plus the base64 of the first 20
# bytes of the package's index sha256. Empty when the package is not there.
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

# Abort unless the package installed in the image is the one of the local
# index: the checksum of its record in the installed database must be the
# first 40 hex digits of the sha256 the local index gives name and version.
#
# Arguments:
#   $1  file with the `apk adbdump` of the local packages.adb
#   $2  installed database (or the record of the package)
#   $3  package name
#   $4  package version
ib_check_installed_is_local() {
	icl_index=$(adb_index_hash "$1" "$3" "$4")
	[ -n "${icl_index}" ] || die "the local index has no $3 $4"
	icl_installed=$(installed_checksum_hex "$2" "$3")
	[ -n "${icl_installed}" ] || die "$3 is not in the installed database of the image"
	icl_short=$(printf '%.40s' "${icl_index}")
	[ "${icl_installed}" = "${icl_short}" ] ||
		die "the image holds a $3 $4 that is not the locally built apk (installed ${icl_installed}, local ${icl_short}); a package of the feed won"
	printf 'ib-pins: %s %s installed from the local apk (checksum %s)\n' "$3" "$4" "${icl_installed}" >&2
}

# Make the Image Builder Makefile pass a pin on to the right package only. The
# FormatPackages of the released Image Builders (25.12) keeps the version of
# the last <name>=<version> and appends it to every package after it, so a pin
# breaks the whole install; the fixed form resets it for each package. Rewrites
# the one known buggy line, leaves the fixed Makefile alone and aborts on any
# other FormatPackages.
#
# Arguments:
#   $1  path of the Image Builder Makefile
ib_fix_format_packages() {
	# shellcheck disable=SC2016 # Makefile text, nothing to expand
	iff_old='$(if $(findstring =,$(pkg)),$(eval pkg_ver:==$(lastword $(subst =, ,$(pkg)))))'
	# shellcheck disable=SC2016 # Makefile text, nothing to expand
	iff_new='  $(eval pkg_ver:=$(if $(findstring =,$(pkg)),=$(lastword $(subst =, ,$(pkg)))))'
	grep -Fq 'define FormatPackages' "$1" ||
		die "$1 has no FormatPackages: this Image Builder cannot pin a version"
	if grep -Fq -- "${iff_new}" "$1"; then
		printf 'ib-pins: FormatPackages already resets the pin for each package\n' >&2
		return 0
	fi
	grep -Fq -- "${iff_old}" "$1" || die "unknown FormatPackages in $1; not pinning"
	iff_tmp=$(mktemp) || die "cannot create a temporary file"
	awk -v old="${iff_old}" -v new="${iff_new}" '
		index($0, old) { print new; next }
		{ print }
	' "$1" >"${iff_tmp}" || die "cannot rewrite $1"
	cat "${iff_tmp}" >"$1" || die "cannot write $1"
	rm -f "${iff_tmp}"
	printf 'ib-pins: patched FormatPackages of %s (a pin leaked to the following packages)\n' "$1" >&2
}
