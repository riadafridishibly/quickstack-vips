# quickstack-vips

libvips and the libraries it needs, built once so that apps made from [quickstack](https://github.com/riadafridishibly/quickstack) can link against it and ship it next to their binary. Servers don't need libvips installed, and a system libvips of another version doesn't get in the way.

Each release has a kit for each target:

| Target | Runs on |
|---|---|
| `linux-amd64` | glibc 2.28 or newer: RHEL 8+, Debian 10+, Ubuntu 20.04+, Fedora |
| `linux-arm64` | the same, on arm64 |
| `freebsd-amd64` | FreeBSD 14.0 or newer |

The kits need only the C library from the system. They don't need libstdc++ (the C++ libraries carry their own libc++), and they don't run on musl (Alpine).

libvips is built with only the formats quickstack's media uses: JPEG, PNG, WebP and GIF, plus HEIF for HEIC and AVIF. It can read those and write JPEG, PNG and WebP. SVG, PDF, TIFF, ImageMagick and the rest are left out of the build. [`sources.txt`](sources.txt) lists every library with its version and checksum.

## Using a kit

A kit unpacks to `include/`, `lib/` (shared libraries and pkg-config files), `bin/vips`, `bin/vipsheader` and `share/licenses/`. The pkg-config files work from wherever it is unpacked.

```sh
mkdir -p dist/vips
curl -fsSL https://github.com/riadafridishibly/quickstack-vips/releases/download/v8.18.7-r1/quickstack-vips-8.18.7-r1-linux-amd64.tar.gz | tar -xzf - -C dist/vips
```

Build against it with pkg-config, and give the binary an rpath that finds `lib/` next to it:

```sh
PKG_CONFIG_LIBDIR=dist/vips/lib/pkgconfig \
CGO_LDFLAGS='-Wl,-rpath,$ORIGIN/../lib' \
go build -o dist/app/bin/app .
cp -a dist/vips/lib/*.so.* dist/app/lib/
cp -R dist/vips/share/licenses dist/app/share/
```

`dist/app` is then the whole release: copy it anywhere and run `bin/app`.

The same zig toolchain that built the kit cross-compiles the app from any machine, for example from a Mac:

```sh
GOOS=freebsd GOARCH=amd64 CGO_ENABLED=1 CC="zig cc -target x86_64-freebsd.14.0" \
PKG_CONFIG_LIBDIR=dist/vips/lib/pkgconfig CGO_LDFLAGS='-Wl,-rpath,$ORIGIN/../lib' \
go build -a -o dist/app/bin/app .
```

Use `x86_64-linux-gnu.2.28` or `aarch64-linux-gnu.2.28` for Linux. `-a` keeps Go from reusing cgo link flags cached from a different kit.

## Building

The build runs in Docker and cross-compiles every target with [zig cc](https://ziglang.org), so any machine with Docker can build all of them.

```sh
make kit TARGET=linux-amd64     # dist/linux-amd64
make test TARGET=linux-amd64    # runs it on Rocky Linux 8 and Debian 13
make test-host TARGET=freebsd-amd64 HOST=user@freebsd-box
make dist                       # every target, the sources, and SHA256SUMS
```

The first build of a target takes about ten minutes; Docker caches each library after that.

To update a library, change its line in `sources.txt` (version, URL and SHA-256), bump the revision in `VERSION`, and build. A new libvips release resets the revision to `r1`.

## Releasing

Push a tag that matches `VERSION`, such as `v8.18.7-r1`. The workflow builds every target, tests the Linux kits on amd64 and arm64, and publishes the kits, the source tarball and `SHA256SUMS` as a GitHub release.

## Licences

The build scripts are MIT. The kits contain libraries under their own licences, copied into each kit under `share/licenses/`:

- LGPL: libvips and glib (2.1 or later), libheif and libde265 (3.0 or later), libexif (2.1 or later).
- BSD, MIT, zlib or similar: the others.

The LGPL libraries are shared libraries that can be replaced, and each release includes the source of everything in it. If you ship an app built on a kit to other people, ship `share/licenses` with it.

HEIC images use HEVC, which is covered by patents in some countries. The kits include libde265, an HEVC decoder, as Debian and FreeBSD do. Check whether that matters where you distribute.
