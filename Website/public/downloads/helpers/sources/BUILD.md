# How this ffmpeg helper was built

FFmpeg 9.0.2 for YummyOrange, helper revision 2: `ffmpeg`, arm64, macOS 13.0 or later, static, LGPL 2.1
or later. Built with Apple clang version 21.0.0 (clang-2100.4.1.1) and the macOS 27.2 SDK.

To rebuild: put the seven tarballs below in a folder `sources` next to `build-ffmpeg-helper.sh` (both from
https://yummyorange.com/licenses/ffmpeg.html) and run `./build-ffmpeg-helper.sh`. It checks the checksums, runs exactly the commands
below and makes the same zip.

## Sources

| Tarball | SHA-256 | From |
|---|---|---|
| ffmpeg-9.0.2.tar.xz | `8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e` | https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz |
| lame-4.0.tar.gz | `3df5124d5ad3a98312ffd7ba6a9b36230e4f8a3e66d3ce0f425e336c32d216eb` | https://downloads.sourceforge.net/project/lame/lame/4.0/lame-4.0.tar.gz |
| libwebp-1.6.0.tar.gz | `e4ab7009bf0629fd11982d4c2aa83964cf244cffba7347ecd39019a9e38c4564` | https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.6.0.tar.gz |
| libvpx-1.17.0.tar.gz | `1020f184046187baa2985dbde38e0691f49c44088bca7a1842b0236c6081dc0a` | https://github.com/webmproject/libvpx/archive/refs/tags/v1.17.0.tar.gz |
| opus-1.6.1.tar.gz | `6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1` | https://ftp.osuosl.org/pub/xiph/releases/opus/opus-1.6.1.tar.gz |
| libogg-1.3.6.tar.gz | `83e6704730683d004d20e21b8f7f55dcb3383cdf84c0daedf30bde175f774638` | https://ftp.osuosl.org/pub/xiph/releases/ogg/libogg-1.3.6.tar.gz |
| libvorbis-1.3.7.tar.xz | `b33cc4934322bcbf6efcbacf49e3ca01aadbea4114ec9589d1b1e9d20f72954b` | https://ftp.osuosl.org/pub/xiph/releases/vorbis/libvorbis-1.3.7.tar.xz |

The checksums are the same as Homebrew's formulas for these versions.

## Environment

```sh
export MACOSX_DEPLOYMENT_TARGET=13.0
export CC=clang CXX=clang++
export ZERO_AR_DATE=1
export PKG_CONFIG=<work>/tools/pkg-config          # a small pkg-config written by the script
export PKG_CONFIG_LIBDIR=<work>/prefix/usr/local/lib/pkgconfig
export PKG_CONFIG_SYSROOT_DIR=<work>/prefix          # ../../prefix while building FFmpeg (relative to its folder)
# For the autotools libraries (lame, libogg, libvorbis, opus, libwebp):
CFLAGS="-arch arm64 -mmacosx-version-min=13.0 -O2 -g0" LDFLAGS="-arch arm64 -mmacosx-version-min=13.0"
```

Each library is built in its own source folder with `make -j` and installed with
`make install DESTDIR=<work>/prefix` (prefix /usr/local inside that folder). Only the static libraries are used.

## Configure lines

lame 4.0:

```sh
./configure --prefix=/usr/local --enable-static --disable-shared --disable-frontend --disable-decoder --disable-dependency-tracking
```

libogg 1.3.6:

```sh
./configure --prefix=/usr/local --enable-static --disable-shared --disable-dependency-tracking
```

libvorbis 1.3.7 (after `sed -i '' 's/ -force_cpusubtype_ALL//g' configure`):

```sh
./configure --prefix=/usr/local --enable-static --disable-shared --disable-docs --disable-examples --disable-oggtest --disable-dependency-tracking
```

opus 1.6.1:

```sh
./configure --prefix=/usr/local --enable-static --disable-shared --disable-doc --disable-extra-programs --disable-dependency-tracking
```

libwebp 1.6.0:

```sh
./configure --prefix=/usr/local --enable-static --disable-shared --enable-libwebpmux --enable-libwebpdemux --disable-png --disable-jpeg --disable-tiff --disable-gif --disable-wic --disable-gl --disable-sdl --disable-dependency-tracking
```

libvpx 1.17.0 (CFLAGS and LDFLAGS empty; libvpx sets its own):

```sh
./configure --prefix=/usr/local --target=arm64-darwin22-gcc --extra-cflags=-mmacosx-version-min=13.0 --enable-static --disable-shared --enable-pic --enable-runtime-cpu-detect --disable-vp8 --disable-vp9-decoder --enable-vp9-encoder --disable-examples --disable-tools --disable-docs --disable-unit-tests --disable-debug-libs
```

FFmpeg 9.0.2, run in the unpacked ffmpeg-9.0.2 folder, which sits in `<work>/build` (no CFLAGS;
the paths are relative to that folder), then `make -j`:

```sh
./configure --pkg-config=../../tools/pkg-config --pkg-config-flags=--static --cc=clang --arch=aarch64 --target-os=darwin --extra-cflags=-arch\ arm64\ -mmacosx-version-min=13.0\ -I../../prefix/usr/local/include --extra-ldflags=-arch\ arm64\ -mmacosx-version-min=13.0\ -L../../prefix/usr/local/lib --extra-libs=-liconv --extra-ldexeflags=-Wl\,-dead_strip\ -Wl\,-oso_prefix\,. --enable-static --disable-shared --disable-autodetect --enable-pthreads --enable-zlib --enable-bzlib --enable-iconv --enable-videotoolbox --enable-audiotoolbox --enable-libmp3lame --enable-libwebp --enable-libvpx --enable-libopus --enable-libvorbis --disable-network --disable-protocols --enable-protocol=file\,pipe --disable-devices --enable-indev=lavfi --enable-ffmpeg --disable-ffprobe --disable-ffplay --disable-doc --disable-debug
```

The program is copied out, stripped (`strip`) and signed ad hoc (`codesign -s - -f --options runtime`). The
script checks that it is arm64, links only to /usr/lib and /System/Library, has minimum macOS 13.0, says LGPL in
`-L`, and records no path of the build Mac. LICENSE.md's notices for FFmpeg's files under other licenses come from
the comment blocks of the files the objects were compiled from (`notices.py`, written by the script).

## Zip

```sh
ditto -c -k --keepParent --norsrc --noextattr --noqtn --noacl ffmpeg-helper YummyOrange-ffmpeg-9.0.2-2-arm64.zip
```
(all files dated 2026-11-26 00:00, so the same build gives the same zip).
