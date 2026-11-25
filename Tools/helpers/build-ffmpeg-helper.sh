#!/bin/bash
# build-ffmpeg-helper.sh
#
# Rebuilds YummyOrange's ffmpeg helper, YummyOrange-ffmpeg-9.0.2-2-arm64.zip, from the seven source tarballs
# published next to it (https://yummyorange.com/licenses/ffmpeg.html). This is the "how to rebuild" that the
# GNU LGPL asks for: the same sources and the same configure lines give the same program.
#
# What it makes: a folder "ffmpeg-helper" with ffmpeg (FFmpeg 9.0.2, LGPL 2.1 or later, static, arm64, macOS 13 or
# later, linked only to macOS's own libraries), LICENSE.md and BUILD.md, zipped with ditto. Revision 2 leaves out
# ffprobe (YummyOrange never runs it) and adds the notices of FFmpeg's files under other licenses to LICENSE.md.
#
# Needs: an Apple-silicon Mac with the Xcode Command Line Tools (clang, make, libtool, strip, codesign) and
# /usr/bin/python3 (part of the Command Line Tools). Nothing is downloaded and nothing is installed system-wide.
#
# Usage:
#   ./build-ffmpeg-helper.sh                 sources in ./sources, build in ./work, zip in .
#   SOURCES=dir WORK=dir OUT=dir ./build-ffmpeg-helper.sh
#   JOBS=8 ./build-ffmpeg-helper.sh          parallel make jobs (default: all cores)
#
# WORK is wiped of its own build folders (build, prefix, tools, stage) at the start; other files in it are left alone.

set -euo pipefail

FFMPEG_VERSION=9.0.2
HELPER_REVISION=2
MIN_MACOS=13.0
SOURCE_URL="https://yummyorange.com/licenses/ffmpeg.html"

HERE="$(cd "$(dirname "$0")" && pwd)"
SOURCES="${SOURCES:-$HERE/sources}"
WORK="${WORK:-$HERE/work}"
OUT="${OUT:-$HERE}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"
ZIP_NAME="YummyOrange-ffmpeg-${FFMPEG_VERSION}-${HELPER_REVISION}-arm64.zip"
FIXED_STAMP=202611260000          # every file in the zip gets this date, so the same build gives the same zip
FIXED_DATE_TEXT="2026-11-26 00:00"

# name | tarball | SHA-256 (the same as Homebrew's formula for that version) | upstream URL
TARBALLS=(
  "ffmpeg|ffmpeg-9.0.2.tar.xz|8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e|https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz"
  "lame|lame-4.0.tar.gz|3df5124d5ad3a98312ffd7ba6a9b36230e4f8a3e66d3ce0f425e336c32d216eb|https://downloads.sourceforge.net/project/lame/lame/4.0/lame-4.0.tar.gz"
  "libwebp|libwebp-1.6.0.tar.gz|e4ab7009bf0629fd11982d4c2aa83964cf244cffba7347ecd39019a9e38c4564|https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.6.0.tar.gz"
  "libvpx|libvpx-1.17.0.tar.gz|1020f184046187baa2985dbde38e0691f49c44088bca7a1842b0236c6081dc0a|https://github.com/webmproject/libvpx/archive/refs/tags/v1.17.0.tar.gz"
  "opus|opus-1.6.1.tar.gz|6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1|https://ftp.osuosl.org/pub/xiph/releases/opus/opus-1.6.1.tar.gz"
  "libogg|libogg-1.3.6.tar.gz|83e6704730683d004d20e21b8f7f55dcb3383cdf84c0daedf30bde175f774638|https://ftp.osuosl.org/pub/xiph/releases/ogg/libogg-1.3.6.tar.gz"
  "libvorbis|libvorbis-1.3.7.tar.xz|b33cc4934322bcbf6efcbacf49e3ca01aadbea4114ec9589d1b1e9d20f72954b|https://ftp.osuosl.org/pub/xiph/releases/vorbis/libvorbis-1.3.7.tar.xz"
)

say() { printf '\n==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------------------------------------------
# Checks

[ "$(uname -s)" = Darwin ] || die "this builds a macOS program; run it on a Mac"
[ "$(uname -m)" = arm64 ] || die "run it on an Apple-silicon Mac (the helper is arm64 only)"
for tool in clang make libtool strip codesign ditto shasum tar /usr/bin/python3 xcrun otool lipo strings; do
  command -v "$tool" >/dev/null || die "missing $tool (install the Xcode Command Line Tools: xcode-select --install)"
done
if [ -d /usr/local/include ] || [ -d /usr/local/lib ]; then
  echo "note: /usr/local/include or /usr/local/lib exists; clang searches them by default. The final linkage check"
  echo "      below fails the build if anything from there gets linked."
fi

say "Checking the source tarballs in $SOURCES"
for entry in "${TARBALLS[@]}"; do
  IFS='|' read -r name file sum url <<<"$entry"
  [ -f "$SOURCES/$file" ] || die "missing $SOURCES/$file (from $url)"
  got="$(shasum -a 256 "$SOURCES/$file" | awk '{print $1}')"
  [ "$got" = "$sum" ] || die "$file: SHA-256 is $got, expected $sum"
  echo "ok  $file  $sum"
done

# ---------------------------------------------------------------------------------------------------------------
# Layout. Libraries are installed with prefix /usr/local into a staging folder ($PREFIX_ROOT, like DESTDIR), so no
# path of this Mac ends up inside the program (libvpx records its configure line, ffmpeg prints its own).

BUILD="$WORK/build"
PREFIX_ROOT="$WORK/prefix"
DEPS="$PREFIX_ROOT/usr/local"
TOOLS="$WORK/tools"
STAGE="$WORK/stage"
mkdir -p "$WORK"
rm -rf "$BUILD" "$PREFIX_ROOT" "$TOOLS" "$STAGE"
mkdir -p "$BUILD" "$DEPS" "$TOOLS" "$STAGE" "$OUT"

say "Unpacking"
for entry in "${TARBALLS[@]}"; do
  IFS='|' read -r name file sum url <<<"$entry"
  tar -xf "$SOURCES/$file" -C "$BUILD"
done

# ---------------------------------------------------------------------------------------------------------------
# A small pkg-config. The Command Line Tools have none; this one reads only the .pc files the libraries above
# install into $DEPS/lib/pkgconfig, and maps their /usr/local paths into the staging folder (PKG_CONFIG_SYSROOT_DIR).

cat >"$TOOLS/pkg-config" <<'PYEOF'
#!/usr/bin/python3 -I
"""Minimal pkg-config for the ffmpeg helper build: --exists, --cflags, --libs, --static, --modversion, --variable."""
import os, re, sys

LIBDIRS = [d for d in os.environ.get("PKG_CONFIG_LIBDIR", "").split(":") if d]
SYSROOT = os.environ.get("PKG_CONFIG_SYSROOT_DIR", "")
OPS = {"<": lambda c: c < 0, "<=": lambda c: c <= 0, "=": lambda c: c == 0, "==": lambda c: c == 0,
       ">=": lambda c: c >= 0, ">": lambda c: c > 0, "!=": lambda c: c != 0}

def vercmp(a, b):
    pa = [int(x) if x.isdigit() else x for x in re.findall(r"\d+|[A-Za-z]+", a)]
    pb = [int(x) if x.isdigit() else x for x in re.findall(r"\d+|[A-Za-z]+", b)]
    for x, y in zip(pa, pb):
        if x == y:
            continue
        if isinstance(x, int) and isinstance(y, int):
            return -1 if x < y else 1
        return -1 if str(x) < str(y) else 1
    return (len(pa) > len(pb)) - (len(pa) < len(pb))

def parse_reqs(text):
    toks = text.replace(",", " ").split()
    out, i = [], 0
    while i < len(toks):
        if i + 2 < len(toks) and toks[i + 1] in OPS:
            out.append((toks[i], toks[i + 1], toks[i + 2])); i += 3
        else:
            out.append((toks[i], None, None)); i += 1
    return out

_cache = {}
def load(name):
    if name in _cache:
        return _cache[name]
    pc = None
    for d in LIBDIRS:
        p = os.path.join(d, name + ".pc")
        if os.path.isfile(p):
            pc = p; break
    if pc is None:
        _cache[name] = None
        return None
    variables, fields = {"pcfiledir": os.path.dirname(pc)}, {}
    expand = lambda s: re.sub(r"\$\{(\w+)\}", lambda m: variables.get(m.group(1), ""), s)
    with open(pc) as f:
        for raw in f:
            line = raw.split("#", 1)[0].strip()
            if not line:
                continue
            m = re.match(r"^([A-Za-z0-9_.]+)\s*=\s*(.*)$", line)
            if m:
                variables[m.group(1)] = expand(m.group(2)); continue
            m = re.match(r"^([A-Za-z0-9_.]+)\s*:\s*(.*)$", line)
            if m:
                fields[m.group(1)] = expand(m.group(2))
    _cache[name] = (variables, fields)
    return _cache[name]

def walk(names, static, seen, order):
    for name in names:
        if name in seen:
            continue
        seen.add(name)
        pkg = load(name)
        if pkg is None:
            raise KeyError(name)
        order.append(name)
        reqs = [r[0] for r in parse_reqs(pkg[1].get("Requires", ""))]
        reqs += [r[0] for r in parse_reqs(pkg[1].get("Requires.private", ""))]  # always, as pkg-config does for cflags
        walk(reqs, static, seen, order)

def sysrooted(flag):
    if SYSROOT and len(flag) > 2 and flag[:2] in ("-I", "-L") and flag[2] == "/":
        return flag[:2] + SYSROOT + flag[2:]
    return flag

def main(argv):
    opts, words, variable = set(), [], None
    it = iter(argv)
    for a in it:
        if a.startswith("--variable="):
            variable = a.split("=", 1)[1]
        elif a == "--variable":
            variable = next(it, "")
        elif a.startswith("--atleast-pkgconfig-version"):
            return 0
        elif a.startswith("--"):
            opts.add(a)
        else:
            words.append(a)
    if "--version" in opts:
        print("0.29.2"); return 0
    errors = "--print-errors" in opts or "--short-errors" in opts
    reqs = parse_reqs(" ".join(words))
    for name, op, ver in reqs:
        pkg = load(name)
        if pkg is None:
            if errors:
                print("Package %s was not found in the pkg-config search path." % name, file=sys.stderr)
            return 1
        have = pkg[1].get("Version", "0")
        if op and not OPS[op](vercmp(have, ver)):
            if errors:
                print("Requested '%s %s %s' but version of %s is %s" % (name, op, ver, name, have), file=sys.stderr)
            return 1
    names = [r[0] for r in reqs]
    if "--modversion" in opts:
        for n in names:
            print(load(n)[1].get("Version", ""))
        return 0
    if variable is not None:
        vals = []
        for n in names:
            v = load(n)[0].get(variable, "")
            if SYSROOT and variable in ("includedir", "libdir") and v.startswith("/"):
                v = SYSROOT + v
            vals.append(v)
        print(" ".join(vals)); return 0
    static = "--static" in opts
    order = []
    try:
        walk(names, static, set(), order)
    except KeyError as e:
        if errors:
            print("Package %s was not found in the pkg-config search path." % e.args[0], file=sys.stderr)
        return 1
    out = []
    if "--cflags" in opts or "--cflags-only-I" in opts:
        for n in order:
            out += load(n)[1].get("Cflags", "").split()
    if "--libs" in opts:
        for n in order:
            f = load(n)[1]
            out += f.get("Libs", "").split()
            if static:
                out += f.get("Libs.private", "").split()
    out = [sysrooted(x) for x in out]
    # Keep the first -I/-L/other flag, the last -l (a library goes after the ones that use it).
    final, seen = [], set()
    for i, x in enumerate(out):
        if x.startswith("-l") and x in out[i + 1:]:
            continue
        if not x.startswith("-l") and x in seen:
            continue
        seen.add(x); final.append(x)
    print(" ".join(final))
    return 0

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
PYEOF
chmod +x "$TOOLS/pkg-config"

# Notices of FFmpeg's own files that are under a license besides the LGPL (BSD, MIT, ISC, Boost, IJG): every .c, .S
# and .h file an object was compiled from (FFmpeg's build writes a .d file for each object), every comment block in
# them that grants such a license, with the files that carry it. Sorted, so the same build gives the same text.
cat >"$TOOLS/notices.py" <<'PYEOF2'
import os, re, sys

root = sys.argv[1]
MARKERS = (
    "Redistribution and use in source and binary forms",                    # BSD
    "Permission is hereby granted, free of charge",                          # MIT, Boost
    "Permission to use, copy, modify, and/or distribute",                    # ISC
    "Permission to use, copy, modify, and distribute",                       # ISC, older MIT
    "Permission is hereby granted to use, copy, modify, and distribute",     # IJG
)
COMMENT = re.compile(r"/\*.*?\*/", re.S)
FENCE = "`" * 3

def compiled_files():
    seen = set()
    for top, dirs, files in os.walk(root):
        dirs.sort()
        if os.path.relpath(top, root).split(os.sep)[0] in ("ffbuild", "doc", "tests"):
            continue
        for name in sorted(files):
            if not name.endswith(".d"):
                continue
            with open(os.path.join(top, name), encoding="utf-8", errors="replace") as f:
                text = f.read().replace("\\\n", " ")
            for line in text.splitlines():
                if ":" not in line:
                    continue
                for dep in line.split(":", 1)[1].split():
                    if dep.startswith("/"):
                        continue          # the SDK's own headers
                    rel = os.path.relpath(os.path.normpath(os.path.join(root, dep)), root)
                    if rel.startswith("..") or not rel.endswith((".c", ".h", ".S", ".m")):
                        continue
                    if os.path.isfile(os.path.join(root, rel)):
                        seen.add(rel)
    return sorted(seen)

def clean(block):
    out = [re.sub(r"^\s*\*? ?", "", line.rstrip()) for line in block.strip()[2:-2].splitlines()]
    while out and not out[0].strip():
        out.pop(0)
    while out and not out[-1].strip():
        out.pop()
    return "\n".join(out)

blocks = {}
for rel in compiled_files():
    with open(os.path.join(root, rel), encoding="utf-8", errors="replace") as f:
        text = f.read()
    for m in COMMENT.finditer(text):
        if any(k in m.group(0) for k in MARKERS):
            files = blocks.setdefault(clean(m.group(0)), [])
            if rel not in files:
                files.append(rel)
if not blocks:
    sys.exit("no notices found: was FFmpeg built in %s?" % root)
for text, files in sorted(blocks.items(), key=lambda kv: (kv[1][0], kv[0])):
    print("#### " + ", ".join("`%s`" % f for f in files))
    print()
    print(FENCE + "text")
    print(text.replace(FENCE, "'''"))
    print(FENCE)
    print()
PYEOF2

# ---------------------------------------------------------------------------------------------------------------
# Toolchain: arm64, macOS 13 minimum, the SDK's own headers.

export MACOSX_DEPLOYMENT_TARGET="$MIN_MACOS"
# Reproducible: archive members and the linker's debug map get date 0 (libvorbis compiles with -g), and
# -oso_prefix below makes the debug map's paths relative, so ffmpeg's LC_UUID doesn't depend on when or where.
export ZERO_AR_DATE=1
export PKG_CONFIG="$TOOLS/pkg-config"
export PKG_CONFIG_LIBDIR="$DEPS/lib/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="$PREFIX_ROOT"
unset PKG_CONFIG_PATH CPATH C_INCLUDE_PATH LIBRARY_PATH CPPFLAGS CXXFLAGS OBJCFLAGS
export CC=clang CXX=clang++
LIB_CFLAGS="-arch arm64 -mmacosx-version-min=$MIN_MACOS -O2 -g0"   # -g0: libvorbis adds -g, which records build paths
LIB_LDFLAGS="-arch arm64 -mmacosx-version-min=$MIN_MACOS"

# The configure line of every library, exactly as run (BUILD.md lists them from these arrays).
LAME_CONFIGURE=(./configure --prefix=/usr/local --enable-static --disable-shared --disable-frontend --disable-decoder
  --disable-dependency-tracking)
OGG_CONFIGURE=(./configure --prefix=/usr/local --enable-static --disable-shared --disable-dependency-tracking)
VORBIS_CONFIGURE=(./configure --prefix=/usr/local --enable-static --disable-shared --disable-docs --disable-examples
  --disable-oggtest --disable-dependency-tracking)
OPUS_CONFIGURE=(./configure --prefix=/usr/local --enable-static --disable-shared --disable-doc --disable-extra-programs
  --disable-dependency-tracking)
WEBP_CONFIGURE=(./configure --prefix=/usr/local --enable-static --disable-shared --enable-libwebpmux --enable-libwebpdemux
  --disable-png --disable-jpeg --disable-tiff --disable-gif --disable-wic --disable-gl --disable-sdl
  --disable-dependency-tracking)
VPX_CONFIGURE=(./configure --prefix=/usr/local --target=arm64-darwin22-gcc "--extra-cflags=-mmacosx-version-min=$MIN_MACOS"
  --enable-static --disable-shared --enable-pic --enable-runtime-cpu-detect --disable-vp8 --disable-vp9-decoder
  --enable-vp9-encoder --disable-examples --disable-tools --disable-docs --disable-unit-tests --disable-debug-libs)

# FFmpeg: LGPL 2.1+ (no --enable-gpl, --enable-version3 or --enable-nonfree), static, nothing autodetected,
# only file and pipe access (no network), no capture devices (only the lavfi test-source input), no ffplay.
# Every decoder, demuxer, encoder, muxer and filter FFmpeg has under the LGPL is kept, since dropped files can be
# anything. Paths are relative to the ffmpeg source folder, so "ffmpeg -version" shows no path of the build Mac.
# Not --enable-small: it makes FFmpeg's own AAC and FLAC encoders about 1.6x and 1.8x slower.
FFMPEG_CONFIGURE=(./configure
  --pkg-config=../../tools/pkg-config --pkg-config-flags=--static
  --cc=clang --arch=aarch64 --target-os=darwin
  "--extra-cflags=-arch arm64 -mmacosx-version-min=$MIN_MACOS -I../../prefix/usr/local/include"
  "--extra-ldflags=-arch arm64 -mmacosx-version-min=$MIN_MACOS -L../../prefix/usr/local/lib"
  --extra-libs=-liconv "--extra-ldexeflags=-Wl,-dead_strip -Wl,-oso_prefix,."
  --enable-static --disable-shared
  --disable-autodetect --enable-pthreads --enable-zlib --enable-bzlib --enable-iconv
  --enable-videotoolbox --enable-audiotoolbox
  --enable-libmp3lame --enable-libwebp --enable-libvpx --enable-libopus --enable-libvorbis
  --disable-network --disable-protocols --enable-protocol=file,pipe
  --disable-devices --enable-indev=lavfi
  --enable-ffmpeg --disable-ffprobe --disable-ffplay
  --disable-doc --disable-debug)

autotools_build() { # dir, configure array name
  local dir="$1"; shift
  ( cd "$BUILD/$dir"
    CFLAGS="$LIB_CFLAGS" LDFLAGS="$LIB_LDFLAGS" "$@" >configure.log 2>&1 || { tail -40 configure.log; exit 1; }
    make -j"$JOBS" >make.log 2>&1 || { tail -40 make.log; exit 1; }
    make install DESTDIR="$PREFIX_ROOT" >install.log 2>&1 || { tail -40 install.log; exit 1; } )
}

say "lame";      autotools_build lame-4.0 "${LAME_CONFIGURE[@]}"
say "libogg";    autotools_build libogg-1.3.6 "${OGG_CONFIGURE[@]}"
say "libvorbis"
# libvorbis 1.3.7's configure adds -force_cpusubtype_ALL on macOS, which arm64 clang rejects (Homebrew removes it too).
sed -i '' 's/ -force_cpusubtype_ALL//g' "$BUILD/libvorbis-1.3.7/configure"
autotools_build libvorbis-1.3.7 "${VORBIS_CONFIGURE[@]}"
say "opus";      autotools_build opus-1.6.1 "${OPUS_CONFIGURE[@]}"
say "libwebp";   autotools_build libwebp-1.6.0 "${WEBP_CONFIGURE[@]}"
say "libvpx"
( cd "$BUILD/libvpx-1.17.0"
  CFLAGS= LDFLAGS= "${VPX_CONFIGURE[@]}" >configure.log 2>&1 || { tail -40 configure.log; exit 1; }
  make -j"$JOBS" >make.log 2>&1 || { tail -40 make.log; exit 1; }
  make install DESTDIR="$PREFIX_ROOT" >install.log 2>&1 || { tail -40 install.log; exit 1; } )
rm -f "$DEPS"/lib/*.dylib "$DEPS"/lib/*.la   # static only

say "FFmpeg $FFMPEG_VERSION"
FF="$BUILD/ffmpeg-$FFMPEG_VERSION"
( cd "$FF"
  # The libraries' -I and -L paths relative to this folder too: the linker records library paths, and its LC_UUID
  # (so the signature) would otherwise change with the build folder.
  export PKG_CONFIG_SYSROOT_DIR=../../prefix
  "${FFMPEG_CONFIGURE[@]}" >configure.log 2>&1 || { tail -40 configure.log; tail -60 ffbuild/config.log; exit 1; }
  start=$(date +%s)
  make -j"$JOBS" >make.log 2>&1 || { grep -m20 -E 'error|Error' make.log; tail -30 make.log; exit 1; }
  echo "ffmpeg built in $(( $(date +%s) - start )) s" )

# ---------------------------------------------------------------------------------------------------------------
# Checks on the program: macOS libraries only, macOS 13 minimum, LGPL.

say "Checking the program"
HELPER="$STAGE/ffmpeg-helper"
mkdir -p "$HELPER"
cp "$FF/ffmpeg" "$HELPER/ffmpeg"
for prog in ffmpeg; do
  strip "$HELPER/$prog"
  codesign -s - -f --options runtime "$HELPER/$prog"
  codesign -v --strict "$HELPER/$prog"
  bad="$(otool -L "$HELPER/$prog" | tail -n +2 | awk '{print $1}' | grep -vE '^(/usr/lib/|/System/Library/)' || true)"
  [ -z "$bad" ] || die "$prog links to libraries outside macOS: $bad"
  minos="$(otool -l "$HELPER/$prog" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')"
  [ "$minos" = "$MIN_MACOS" ] || die "$prog: minimum macOS is $minos, expected $MIN_MACOS"
  lipo -archs "$HELPER/$prog" | grep -qx arm64 || die "$prog is not arm64 only"
  echo "ok  $prog: arm64, minos $minos, $(otool -L "$HELPER/$prog" | tail -n +2 | wc -l | tr -d ' ') system libraries"
done
for prog in ffmpeg; do
  "$HELPER/$prog" -hide_banner -L | grep -q "GNU Lesser General Public" || die "$prog -L doesn't say LGPL"
  if "$HELPER/$prog" -hide_banner -buildconf | grep -qE -- '--enable-(gpl|version3|nonfree)'; then die "$prog: GPL, version3 or nonfree enabled"; fi
done
if strings -a "$HELPER/ffmpeg" | grep -qF "$WORK"; then die "a build path is recorded in ffmpeg"; fi

# ---------------------------------------------------------------------------------------------------------------
# LICENSE.md and BUILD.md

version_of() { # name -> version from its tarball name
  local entry; for entry in "${TARBALLS[@]}"; do
    IFS='|' read -r n f s u <<<"$entry"
    if [ "$n" = "$1" ]; then echo "$f" | sed -E 's/^[a-z]+-//; s/\.tar\.(gz|xz)$//'; fi
  done
}
license_text() { # title, file...
  local title="$1"; shift
  printf '\n### %s\n\n```text\n' "$title"
  local f; for f in "$@"; do cat "$f"; printf '\n'; done
  printf '```\n'
}

{
  cat <<EOF
# ffmpeg helper for YummyOrange: licenses

This folder holds \`ffmpeg\` from FFmpeg $FFMPEG_VERSION, built for Apple-silicon Macs running macOS $MIN_MACOS or later (helper
revision $HELPER_REVISION). It is a separate program. YummyOrange runs it for audio and video work and contains none of its
code.

This software is based in part on the work of the Independent JPEG Group.

## License

FFmpeg is free software under the GNU Lesser General Public License (LGPL), version 2.1 or (at your option) any later
version. This build is configured without \`--enable-gpl\`, \`--enable-version3\` and \`--enable-nonfree\`, so the program
as a whole is under the LGPL 2.1 or later; \`ffmpeg -L\` prints the same. You may copy, change and pass on this program
under the terms of that license (its full text is below).

\`ffmpeg\` includes these libraries, linked in statically.

| Library | Version | License | Used for |
|---|---|---|---|
| FFmpeg (libavcodec, libavformat, libavfilter, libavdevice, libswscale, libswresample, libavutil) | $FFMPEG_VERSION | LGPL 2.1 or later | everything |
| LAME (libmp3lame) | $(version_of lame) | LGPL 2 or later | MP3 encoding |
| libvpx | $(version_of libvpx) | BSD 3-Clause, with Google's patent grant | VP9 encoding (WebM) |
| Opus (libopus) | $(version_of opus) | BSD 3-Clause | Opus encoding |
| libogg | $(version_of libogg) | BSD 3-Clause | Ogg (used by libvorbis) |
| libvorbis (libvorbis, libvorbisenc) | $(version_of libvorbis) | BSD 3-Clause | Vorbis encoding |
| libwebp (libwebp, libwebpmux, libsharpyuv) | $(version_of libwebp) | BSD 3-Clause, with Google's patent grant | WebP stills and animated WebP |

It also uses macOS's own zlib, bzip2, iconv, VideoToolbox (H.264/HEVC hardware encoding) and AudioToolbox (AAC
encoding) libraries, which are part of macOS and not included here.

## Source code

The exact source of everything in this program, the seven original tarballs with their SHA-256 checksums, and the
script that rebuilds this folder from them (\`build-ffmpeg-helper.sh\`) are available at:

**$SOURCE_URL**

The tarballs are unchanged from their projects' own releases (listed in BUILD.md with their checksums). BUILD.md has
every configure line used. One build-time edit is made: libvorbis's configure script has the obsolete
\`-force_cpusubtype_ALL\` compiler flag removed, because arm64 clang rejects it.

You can rebuild the program from that source, and change FFmpeg or any of the libraries and build your own.

## License texts
EOF
  license_text "FFmpeg: GNU Lesser General Public License, version 2.1" "$FF/COPYING.LGPLv2.1"
  license_text "FFmpeg: licensing notes (LICENSE.md from the FFmpeg source)" "$FF/LICENSE.md"
  license_text "LAME $(version_of lame): GNU Library General Public License, version 2 (COPYING)" "$BUILD/lame-4.0/COPYING"
  license_text "libvpx $(version_of libvpx): LICENSE and PATENTS" "$BUILD/libvpx-1.17.0/LICENSE" "$BUILD/libvpx-1.17.0/PATENTS"
  license_text "Opus $(version_of opus): COPYING" "$BUILD/opus-1.6.1/COPYING"
  license_text "libogg $(version_of libogg): COPYING" "$BUILD/libogg-1.3.6/COPYING"
  license_text "libvorbis $(version_of libvorbis): COPYING" "$BUILD/libvorbis-1.3.7/COPYING"
  license_text "libwebp $(version_of libwebp): COPYING and PATENTS" "$BUILD/libwebp-1.6.0/COPYING" "$BUILD/libwebp-1.6.0/PATENTS"
  cat <<EOF

## Notices for FFmpeg files under other licenses

Most of FFmpeg is under the LGPL. A few of its source files built into \`ffmpeg\` also carry, or are under, a BSD,
MIT, ISC, Boost or Independent JPEG Group license. Their notices follow, each with the files it comes from (paths in
the FFmpeg $FFMPEG_VERSION source).

EOF
  /usr/bin/python3 -I "$TOOLS/notices.py" "$FF"
} >"$HELPER/LICENSE.md"

cmdline() { local a out=""; for a in "$@"; do out+="$(printf '%q' "$a") "; done; printf '%s\n' "${out% }"; }
{
  cat <<EOF
# How this ffmpeg helper was built

FFmpeg $FFMPEG_VERSION for YummyOrange, helper revision $HELPER_REVISION: \`ffmpeg\`, arm64, macOS $MIN_MACOS or later, static, LGPL 2.1
or later. Built with $(clang --version | head -1) and the macOS $(xcrun --sdk macosx --show-sdk-version) SDK.

To rebuild: put the seven tarballs below in a folder \`sources\` next to \`build-ffmpeg-helper.sh\` (both from
$SOURCE_URL) and run \`./build-ffmpeg-helper.sh\`. It checks the checksums, runs exactly the commands
below and makes the same zip.

## Sources

| Tarball | SHA-256 | From |
|---|---|---|
EOF
  for entry in "${TARBALLS[@]}"; do
    IFS='|' read -r name file sum url <<<"$entry"
    echo "| $file | \`$sum\` | $url |"
  done
  cat <<EOF

The checksums are the same as Homebrew's formulas for these versions.

## Environment

\`\`\`sh
export MACOSX_DEPLOYMENT_TARGET=$MIN_MACOS
export CC=clang CXX=clang++
export ZERO_AR_DATE=1
export PKG_CONFIG=<work>/tools/pkg-config          # a small pkg-config written by the script
export PKG_CONFIG_LIBDIR=<work>/prefix/usr/local/lib/pkgconfig
export PKG_CONFIG_SYSROOT_DIR=<work>/prefix          # ../../prefix while building FFmpeg (relative to its folder)
# For the autotools libraries (lame, libogg, libvorbis, opus, libwebp):
CFLAGS="$LIB_CFLAGS" LDFLAGS="$LIB_LDFLAGS"
\`\`\`

Each library is built in its own source folder with \`make -j\` and installed with
\`make install DESTDIR=<work>/prefix\` (prefix /usr/local inside that folder). Only the static libraries are used.

## Configure lines

lame $(version_of lame):

\`\`\`sh
$(cmdline "${LAME_CONFIGURE[@]}")
\`\`\`

libogg $(version_of libogg):

\`\`\`sh
$(cmdline "${OGG_CONFIGURE[@]}")
\`\`\`

libvorbis $(version_of libvorbis) (after \`sed -i '' 's/ -force_cpusubtype_ALL//g' configure\`):

\`\`\`sh
$(cmdline "${VORBIS_CONFIGURE[@]}")
\`\`\`

opus $(version_of opus):

\`\`\`sh
$(cmdline "${OPUS_CONFIGURE[@]}")
\`\`\`

libwebp $(version_of libwebp):

\`\`\`sh
$(cmdline "${WEBP_CONFIGURE[@]}")
\`\`\`

libvpx $(version_of libvpx) (CFLAGS and LDFLAGS empty; libvpx sets its own):

\`\`\`sh
$(cmdline "${VPX_CONFIGURE[@]}")
\`\`\`

FFmpeg $FFMPEG_VERSION, run in the unpacked ffmpeg-$FFMPEG_VERSION folder, which sits in \`<work>/build\` (no CFLAGS;
the paths are relative to that folder), then \`make -j\`:

\`\`\`sh
$(cmdline "${FFMPEG_CONFIGURE[@]}")
\`\`\`

The program is copied out, stripped (\`strip\`) and signed ad hoc (\`codesign -s - -f --options runtime\`). The
script checks that it is arm64, links only to /usr/lib and /System/Library, has minimum macOS $MIN_MACOS, says LGPL in
\`-L\`, and records no path of the build Mac. LICENSE.md's notices for FFmpeg's files under other licenses come from
the comment blocks of the files the objects were compiled from (\`notices.py\`, written by the script).

## Zip

\`\`\`sh
ditto -c -k --keepParent --norsrc --noextattr --noqtn --noacl ffmpeg-helper $ZIP_NAME
\`\`\`
(all files dated $FIXED_DATE_TEXT, so the same build gives the same zip).
EOF
} >"$HELPER/BUILD.md"

# ---------------------------------------------------------------------------------------------------------------
# Zip

say "Zipping"
chmod 755 "$HELPER" "$HELPER/ffmpeg"
chmod 644 "$HELPER/LICENSE.md" "$HELPER/BUILD.md"
touch -h -t "$FIXED_STAMP" "$HELPER"/* "$HELPER"
rm -f "$OUT/$ZIP_NAME"
( cd "$STAGE" && ditto -c -k --keepParent --norsrc --noextattr --noqtn --noacl ffmpeg-helper "$OUT/$ZIP_NAME" )
echo "$OUT/$ZIP_NAME"
echo "bytes:   $(stat -f %z "$OUT/$ZIP_NAME")"
echo "sha256:  $(shasum -a 256 "$OUT/$ZIP_NAME" | awk '{print $1}')"
echo "unzipped: $(du -sk "$HELPER" | awk '{print $1}') KB ($(cat "$HELPER"/* | wc -c | tr -d ' ') bytes in files)"
