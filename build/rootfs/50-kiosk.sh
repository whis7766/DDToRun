# shellcheck shell=sh
# VGA kiosk (default profile): compile fbterm and install the tty1 launcher.
#
# Alpine ships no fbterm package, so it is built from upstream source in the
# chroot against the musl toolchain and installed system-wide. Text-console
# fallback is intentionally absent: if no framebuffer appears the launcher
# exits and inittab respawns it.

[ "$PROFILE" = "kiosk" ] || return 0

FBTERM_LOG=/tmp/fbterm-build.log
# fbterm 1.7 needs these feature-test macros and headers with modern compilers.
FB_CXXFLAGS="-D_GNU_SOURCE -include sys/select.h -include sys/time.h -include unistd.h -DWAIT_ANY=-1 -Wno-narrowing"
# Static C++ runtime: fbterm is the only C++ binary, so the ~2.6MB libstdc++
# package does not need to ship in the image.
FB_LDFLAGS="-static-libstdc++ -static-libgcc"

install_fbterm_build_deps() {
	# Temporary virtual package group, removed after the build.
	for _attempt in 1 2 3; do
		if apk add --no-cache --virtual .fbterm-build-deps \
			build-base g++ pkgconf fontconfig-dev freetype-dev linux-headers; then
			return 0
		fi
		echo "fbterm build-deps install attempt $_attempt failed; retrying"
		sleep 3
	done
	die "cannot install fbterm build dependencies"
}

build_fbterm() {
	[ -f /mnt/vendor/fbterm-src.tar.gz ] || die "fbterm source missing (kiosk requires it)"

	echo "==> building fbterm from upstream source"
	install_fbterm_build_deps
	command -v g++ >/dev/null 2>&1 || die "g++ unavailable after build-deps install"

	cd /tmp || die "cannot enter /tmp"
	rm -rf /tmp/fbterm-*
	tar xzf /mnt/vendor/fbterm-src.tar.gz || die "cannot extract fbterm source"
	_src=$(find /tmp -maxdepth 1 -type d -name 'fbterm-*' | head -1)
	[ -n "$_src" ] || die "fbterm source did not extract to a fbterm-* directory"

	if ! (
		cd "$_src" &&
			CXXFLAGS="$FB_CXXFLAGS" LDFLAGS="$FB_LDFLAGS" ./configure \
				--prefix=/usr --disable-gpm --disable-vesa --disable-signalfd >"$FBTERM_LOG" 2>&1 &&
			make -j"$(nproc)" CXXFLAGS="$FB_CXXFLAGS" LDFLAGS="$FB_LDFLAGS" >>"$FBTERM_LOG" 2>&1 &&
			make install >>"$FBTERM_LOG" 2>&1
	); then
		echo "fbterm build failed, last lines of $FBTERM_LOG:"
		tail -15 "$FBTERM_LOG"
		die "fbterm build failed"
	fi

	cd / || die "cannot leave the build directory"
	rm -rf /tmp/fbterm-*
	strip /usr/bin/fbterm 2>/dev/null || true
	apk del .fbterm-build-deps >/dev/null 2>&1 || true
	apk cache clean >/dev/null 2>&1 || true
	rm -f "$FBTERM_LOG"

	[ -x /usr/bin/fbterm ] || die "fbterm build produced no binary"
	infocmp fbterm >/dev/null 2>&1 || die "fbterm terminfo entry was not installed"

	_missing=$(ldd /usr/bin/fbterm 2>&1 | grep -iE 'not found|no such|error loading' || true)
	if [ -n "$_missing" ]; then
		echo "fbterm has missing shared libraries:"
		echo "$_missing"
		die "fbterm linkage check failed"
	fi
	echo "fbterm ready: $(fbterm --version 2>&1 | head -1)"
}

build_fbterm

install -m 0755 /mnt/files/app-runner-fb.sh /usr/local/sbin/app-runner-fb
sed -i 's|^#\?tty1::respawn:.*|tty1::respawn:/usr/local/sbin/app-runner-fb|' /etc/inittab
grep -q '^tty1::respawn:' /etc/inittab ||
	echo 'tty1::respawn:/usr/local/sbin/app-runner-fb' >>/etc/inittab
