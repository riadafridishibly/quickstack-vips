#!/bin/bash
# shellcheck disable=SC2016 # $ORIGIN and ${pcfiledir} are literal.
# Cross-compiles libvips and the libraries it needs into $PREFIX with zig
# cc, one library per call, so the Dockerfile can cache each step. Run the
# libraries in order after fetch.sh, then "finish" and "check".
#
# TARGET is linux-amd64, linux-arm64 or freebsd-amd64.
set -euo pipefail

PREFIX=/opt/vips
SRC=/build/src
here=$(cd "$(dirname "$0")" && pwd)

export PKG_CONFIG_LIBDIR=$PREFIX/lib/pkgconfig
export CMAKE_PREFIX_PATH=$PREFIX
export CPPFLAGS="-I$PREFIX/include"
export CFLAGS="-O2 -fPIC"
export CXXFLAGS="-O2 -fPIC"
# The absolute rpath lets the libraries find each other while building;
# finish replaces it with $ORIGIN.
export LDFLAGS="-L$PREFIX/lib -Wl,-rpath,$PREFIX/lib"

jobs=$(nproc)

# setup writes zig wrappers and the cross files for cmake, meson and
# configure.
setup() {
	# glibc 2.28 is RHEL 8 and Debian 10; zig links against that version's
	# symbols whatever the build machine has.
	case "${TARGET:-}" in
	linux-amd64) zig_target=x86_64-linux-gnu.2.28 cpu=x86_64 os=linux cmake_os=Linux ;;
	linux-arm64) zig_target=aarch64-linux-gnu.2.28 cpu=aarch64 os=linux cmake_os=Linux ;;
	freebsd-amd64) zig_target=x86_64-freebsd.14.0 cpu=x86_64 os=freebsd cmake_os=FreeBSD ;;
	*)
		echo "TARGET must be linux-amd64, linux-arm64 or freebsd-amd64" >&2
		exit 2
		;;
	esac
	tools=/build/cross
	mkdir -p $tools
	printf '#!/bin/sh\nexec zig cc -target %s "$@"\n' "$zig_target" >$tools/cc
	printf '#!/bin/sh\nexec zig c++ -target %s "$@"\n' "$zig_target" >$tools/c++
	printf '#!/bin/sh\nexec zig ar "$@"\n' >$tools/ar
	printf '#!/bin/sh\nexec zig ranlib "$@"\n' >$tools/ranlib
	chmod +x $tools/*
	strip=$(command -v "$cpu-linux-gnu-strip")
	cat >$tools/toolchain.cmake <<-EOF
		set(CMAKE_SYSTEM_NAME $cmake_os)
		set(CMAKE_SYSTEM_PROCESSOR $cpu)
		set(CMAKE_C_COMPILER $tools/cc)
		set(CMAKE_CXX_COMPILER $tools/c++)
		set(CMAKE_AR $tools/ar)
		set(CMAKE_RANLIB $tools/ranlib)
		set(CMAKE_STRIP $strip)
		set(CMAKE_FIND_ROOT_PATH $PREFIX)
		set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
		set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
		set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
		set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
	EOF
	cat >$tools/meson.ini <<-EOF
		[binaries]
		c = '$tools/cc'
		cpp = '$tools/c++'
		ar = '$tools/ar'
		ranlib = '$tools/ranlib'
		strip = '$strip'
		pkg-config = 'pkg-config'
		nasm = 'nasm'

		[host_machine]
		system = '$os'
		cpu_family = '$cpu'
		cpu = '$cpu'
		endian = 'little'
	EOF
	export CC=$tools/cc CXX=$tools/c++ AR=$tools/ar RANLIB=$tools/ranlib STRIP=$strip
}

# unpack extracts the tarball for $1, changes into it, and keeps its
# licence files.
unpack() {
	rm -rf "/build/$1"
	mkdir -p "/build/$1"
	tar -xf "$SRC/$1.tar" -C "/build/$1" --strip-components=1
	cd "/build/$1"
	mkdir -p "$PREFIX/share/licenses/$1"
	find . -maxdepth 1 \( -name 'COPYING*' -o -name 'LICENSE*' -o -name 'LICENCE*' -o -name 'PATENTS*' \) -exec cp {} "$PREFIX/share/licenses/$1/" \;
}

cmake_build() {
	cmake -S . -B _build -G Ninja \
		-DCMAKE_TOOLCHAIN_FILE=$tools/toolchain.cmake \
		-DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_INSTALL_PREFIX=$PREFIX \
		-DCMAKE_INSTALL_LIBDIR=lib \
		-DBUILD_SHARED_LIBS=ON \
		"$@"
	ninja -C _build install/strip
}

meson_build() {
	meson setup _build \
		--cross-file=$tools/meson.ini \
		--buildtype=release \
		--strip \
		--wrap-mode=nofallback \
		--prefix=$PREFIX \
		--libdir=lib \
		"$@"
	ninja -C _build install
	# Meson follows FreeBSD's libdata/pkgconfig there; keep one place.
	if [ -d $PREFIX/libdata/pkgconfig ]; then
		mkdir -p $PREFIX/lib/pkgconfig
		mv $PREFIX/libdata/pkgconfig/*.pc $PREFIX/lib/pkgconfig/
		rm -r $PREFIX/libdata
	fi
}

configure_build() {
	./configure --host="$cpu-unknown-$os" --prefix=$PREFIX \
		--enable-shared --disable-static --disable-dependency-tracking "$@"
	make -j"$jobs" install-strip
}

setup

case "${1:-}" in
zlib-ng)
	unpack zlib-ng
	cmake_build -DZLIB_COMPAT=ON -DZLIB_ENABLE_TESTS=OFF -DWITH_GTEST=OFF
	;;
libffi)
	unpack libffi
	configure_build --disable-docs --disable-multi-os-directory
	;;
pcre2)
	unpack pcre2
	cmake_build -DBUILD_STATIC_LIBS=OFF -DPCRE2_SUPPORT_JIT=ON -DPCRE2_BUILD_PCRE2GREP=OFF -DPCRE2_BUILD_TESTS=OFF
	;;
proxy-libintl)
	# glib needs libintl, which glibc has and FreeBSD's libc doesn't. A
	# static stub does, since translations are off.
	[ "$os" = freebsd ] || exit 0
	unpack proxy-libintl
	meson_build -Ddefault_library=static
	;;
glib)
	unpack glib
	meson_build -Dtests=false -Dintrospection=disabled -Dnls=disabled -Dlibmount=disabled \
		-Dselinux=disabled -Dxattr=false -Dsysprof=disabled -Dlibelf=disabled \
		-Dinstalled_tests=false -Dglib_debug=disabled
	;;
highway)
	unpack highway
	cmake_build -DHWY_ENABLE_TESTS=OFF -DHWY_ENABLE_EXAMPLES=OFF -DHWY_ENABLE_CONTRIB=OFF
	;;
expat)
	unpack expat
	configure_build --without-xmlwf --without-docbook --without-examples --without-tests
	;;
libexif)
	unpack libexif
	# libtool turns this into -retain-symbols-file, which zig's linker
	# doesn't take.
	sed -i 's|-export-symbols $(srcdir)/libexif.sym||' libexif/Makefile.in
	configure_build --disable-nls --disable-docs
	;;
lcms2)
	unpack lcms2
	configure_build
	;;
libjpeg-turbo)
	unpack libjpeg-turbo
	cmake_build -DENABLE_STATIC=OFF -DWITH_TURBOJPEG=OFF -DWITH_TOOLS=OFF -DWITH_TESTS=OFF
	;;
libpng)
	unpack libpng
	cmake_build -DPNG_STATIC=OFF -DPNG_TESTS=OFF -DPNG_TOOLS=OFF -DPNG_FRAMEWORK=OFF
	;;
libwebp)
	unpack libwebp
	configure_build --enable-libwebpmux --enable-libwebpdemux --disable-libwebpdecoder \
		--disable-png --disable-jpeg --disable-tiff --disable-gif --disable-wic --disable-sdl --disable-gl
	;;
libde265)
	unpack libde265
	cmake_build -DENABLE_ENCODER=OFF -DENABLE_DECODER=OFF -DENABLE_SDL=OFF
	;;
dav1d)
	unpack dav1d
	meson_build -Denable_tools=false -Denable_tests=false -Denable_examples=false
	;;
libheif)
	unpack libheif
	cmake_build --preset=release-noplugins \
		-DWITH_LIBDE265=ON -DWITH_DAV1D=ON \
		-DWITH_AOM_DECODER=OFF -DWITH_AOM_ENCODER=OFF -DWITH_X265=OFF \
		-DWITH_LIBSHARPYUV=OFF -DWITH_GDK_PIXBUF=OFF -DWITH_EXAMPLES=OFF -DBUILD_TESTING=OFF
	;;
vips)
	unpack vips
	# Only the formats quickstack's media uses. Every other format is left
	# out rather than blocked at runtime.
	meson_build --auto-features=disabled \
		-Djpeg=enabled -Dpng=enabled -Dwebp=enabled -Dheif=enabled -Dnsgif=true \
		-Dlcms=enabled -Dexif=enabled -Dhighway=enabled -Dzlib=enabled \
		-Dppm=false -Danalyze=false -Dradiance=false \
		-Dmodules=disabled -Dcplusplus=false -Dexamples=false -Ddocs=false -Dvapi=false
	;;
finish)
	cd $PREFIX
	rm -rf lib/*.la lib/*.a lib/cmake lib/libgirepository* lib/girepository* lib/pkgconfig/girepository* \
		include/glib-2.0/girepository libexec share/man share/doc share/gtk-doc share/bash-completion
	find bin ! -type d ! -name vips ! -name vipsheader -delete
	for f in lib/*.so*; do
		[ -L "$f" ] || patchelf --set-rpath '$ORIGIN' "$f"
	done
	for f in bin/*; do
		patchelf --set-rpath '$ORIGIN/../lib' "$f"
	done
	# Relocatable: pkg-config resolves ${pcfiledir} to wherever the kit
	# is unpacked.
	sed -i -e 's|^prefix=.*|prefix=${pcfiledir}/../..|' -e "s|$PREFIX|\${prefix}|g" lib/pkgconfig/*.pc
	# The libintl stub is linked into glib already.
	sed -i 's| -lintl||' lib/pkgconfig/*.pc
	cp "$here/sources.txt" share/licenses/SOURCES
	;;
check)
	cd $PREFIX
	# The kit may only need these from the system.
	case $os in
	linux) allowed=(ld-linux-x86-64.so.2 ld-linux-aarch64.so.1 libc.so.6 libm.so.6 libpthread.so.0 libdl.so.2 librt.so.1 libresolv.so.2) ;;
	freebsd) allowed=(libc.so.7 libm.so.5 libthr.so.3) ;;
	esac
	needed=$(for f in lib/*.so* bin/*; do readelf -d "$f"; done |
		sed -n 's/.*Shared library: \[\(.*\)\]/\1/p' | sort -u)
	status=0
	for n in $needed; do
		if [ ! -e "lib/$n" ] && ! printf '%s\n' "${allowed[@]}" | grep -qx "$n"; then
			echo "needs $n from the system"
			status=1
		fi
	done
	if [ "$os" = linux ]; then
		echo "glibc: $(for f in lib/*.so* bin/*; do readelf -V "$f"; done | grep -o 'GLIBC_[0-9.]*' | sort -uV | tail -1)"
	fi
	du -sh lib
	exit $status
	;;
*)
	echo "unknown step: $1" >&2
	exit 2
	;;
esac
