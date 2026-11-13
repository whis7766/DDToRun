# shellcheck shell=sh
# Provisioning of the external pieces the build needs: the official
# alpine-make-vm-image tool, a static apk-tools and the fbterm source tarball.

# fetch_build_tool <dest>
#
# Pinned to master because the tool is a single self-contained script; the
# build is reproducible through the Alpine branch/package pinning below.
fetch_build_tool() {
	log "fetch alpine-make-vm-image"
	fetch https://raw.githubusercontent.com/alpinelinux/alpine-make-vm-image/master/alpine-make-vm-image "$1" \
		|| die "cannot download alpine-make-vm-image"
	chmod +x "$1"
}

# provision_apk <vendor_dir> <work_dir> <branch> <mirror>
#
# The official tool downloads apk-tools from gitlab.alpinelinux.org, which is
# unreachable from GitHub runners. Prefer a vendored static build; otherwise
# resolve the newest apk-tools-static from the CDN mirror.
provision_apk() {
	_vendor_apk="$1/apk.static"
	if [ -x "$_vendor_apk" ]; then
		APK="$_vendor_apk"
		export APK
		return 0
	fi

	_listing=$(curl -fsSL --retry 5 --retry-all-errors --connect-timeout 20 \
		"$4/$3/main/x86_64/" 2>/dev/null) ||
		die "cannot list $4/$3/main/x86_64 - '$3' must be an apk branch (v3.22), not a point release (v3.22.1)"
	_pkg=$(printf '%s\n' "$_listing" \
		| grep -oE 'apk-tools-static-[0-9]+(\.[0-9]+)*(-r[0-9]+)?\.apk' \
		| sort -V | tail -1)
	[ -n "$_pkg" ] || die "could not resolve apk-tools-static package"

	fetch "$4/$3/main/x86_64/$_pkg" "$2/apk-tools-static.apk" || die "cannot download $_pkg"
	tar xzf "$2/apk-tools-static.apk" -C "$2" sbin/apk.static || die "cannot extract apk.static"
	# Consumed by build.sh through the exported environment.
	APK="$2/sbin/apk.static"
	export APK
}

# provision_fbterm_source <vendor_dir>
#
# Alpine ships no fbterm package, so setup.sh compiles it in the chroot. The
# upstream 1.7 tarball is cached in vendor/ (gitignored) between local builds.
provision_fbterm_source() {
	_src="$1/fbterm-src.tar.gz"
	if [ -s "$_src" ]; then
		log "using cached fbterm source"
		return 0
	fi
	fetch https://deb.debian.org/debian/pool/main/f/fbterm/fbterm_1.7.orig.tar.gz "$_src" \
		|| die "cannot download fbterm source"
}
