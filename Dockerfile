# Cross-compiles libvips and the libraries it needs with zig cc. TARGET is
# linux-amd64, linux-arm64 or freebsd-amd64; the build machine can be any
# of them.
#
#   docker build --build-arg TARGET=linux-amd64 --target kit --output dist/linux-amd64 .
FROM ubuntu:24.04 AS toolchain
ARG ZIG_VERSION=0.17.1
RUN apt-get update \
	&& DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
		binutils binutils-x86-64-linux-gnu binutils-aarch64-linux-gnu bzip2 ca-certificates \
		curl gcc libc6-dev make nasm pkg-config python3-venv xz-utils \
	&& rm -rf /var/lib/apt/lists/* \
	&& python3 -m venv /opt/tools \
	&& /opt/tools/bin/pip install --no-cache-dir \
		meson==1.9.1 ninja==1.13.0 cmake==3.31.6 patchelf==0.17.2.4 packaging==25.0 \
	&& arch=$(uname -m) \
	&& case $arch in \
		aarch64) sum=a1546d5646eb184437918d6635ca6b762a0e889eac09cef720ee7a1ed3fe7795 ;; \
		x86_64) sum=3581863e3cbcfd0fce0efc682ce7e9e93da96668a977791d356a26d2a7e9b17a ;; \
	esac \
	&& curl -fsSL -o /tmp/zig.tar.xz https://ziglang.org/download/$ZIG_VERSION/zig-$arch-linux-$ZIG_VERSION.tar.xz \
	&& echo "$sum  /tmp/zig.tar.xz" | sha256sum -c - \
	&& mkdir /opt/zig \
	&& tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1 \
	&& rm /tmp/zig.tar.xz
ENV PATH=/opt/zig:/opt/tools/bin:$PATH
WORKDIR /build

FROM toolchain AS fetch
COPY sources.txt fetch.sh ./
RUN ./fetch.sh /build/src

# The source tarballs, published with each release for the LGPL.
FROM scratch AS sources
COPY --from=fetch /build/src /

FROM fetch AS build
ARG TARGET
COPY build.sh ./
RUN ./build.sh zlib-ng
RUN ./build.sh libffi
RUN ./build.sh pcre2
RUN ./build.sh proxy-libintl
RUN ./build.sh glib
RUN ./build.sh highway
RUN ./build.sh expat
RUN ./build.sh libexif
RUN ./build.sh lcms2
RUN ./build.sh libjpeg-turbo
RUN ./build.sh libpng
RUN ./build.sh libwebp
RUN ./build.sh libde265
RUN ./build.sh dav1d
RUN ./build.sh libheif
RUN ./build.sh vips
RUN ./build.sh finish && ./build.sh check

FROM scratch AS kit
COPY --from=build /opt/vips /
