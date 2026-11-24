#!/bin/zsh
# Renders the website's pictures with YummyOrange's own offscreen snapshots, then optimises them into ../public/assets
# (what is deployed). The Convert wheel goes to ../unused-assets, where tools/og-card.html picks it up for the social card.
#
#   tools/make-assets.sh <work-dir> [fixtures-dir]
#
# <work-dir>      a scratch folder for raw renders and sample media (anything outside iCloud).
# [fixtures-dir]  a folder that holds Tests/fixtures/core and Tests/fixtures/features (the Clothesline preview
#                 hangs those as the line's older files). It is also the working directory of every render.
#
# Needs: a debug build (swift build; the Swift target keeps its internal name, so it is .build/debug/DropWheel), ffmpeg (~/.local/bin or Homebrew), cwebp (brew install webp).
# Nothing here touches the app's settings: snapshots use an in-memory settings store and open no windows.
set -euo pipefail
HERE=${0:A:h}
SITE=${HERE:h}
ROOT=${SITE:h}
BIN="$ROOT/.build/debug/DropWheel"
[[ -x "$ROOT/.build/debug/YummyOrange" ]] && BIN="$ROOT/.build/debug/YummyOrange"   # if the target is ever renamed
WORK=${1:?work dir}
FIX=${2:-$ROOT}
RAW="$WORK/raw"; SM="$WORK/samples"; OUT="$SITE/public/assets"; SPARE="$SITE/unused-assets"
mkdir -p "$RAW" "$SM" "$OUT" "$SPARE"
FF=$(command -v ffmpeg || echo "$HOME/.local/bin/ffmpeg")
webp() { cwebp -quiet -q "${3:-80}" -m 6 -resize "$2" 0 "$1" -o "$OUT/${4:-${1:t:r}}.webp"; }

# 1. Sample media, drawn for the site (no test patterns on the marketing pages)
cp "$HERE/samples/lake.svg" "$HERE/samples/estimate.md" "$SM/"
(cd "$SM" && "$BIN" --convert png lake.svg >/dev/null && sips -Z 1600 lake.png >/dev/null && "$BIN" --convert pdf estimate.md >/dev/null)
"$FF" -loglevel error -y -loop 1 -i "$SM/lake.png" \
  -f lavfi -i "aevalsrc='0.25*sin(2*PI*220*t)*(0.55+0.45*sin(2*PI*0.7*t))+0.15*sin(2*PI*330*t)*(0.5+0.5*sin(2*PI*1.3*t+1))':s=44100:d=12" \
  -filter_complex "[0:v]scale=3200:2000,zoompan=z='1+0.18*on/360':x='iw/2-(iw/zoom/2)+on*0.9':y='ih/2-(ih/zoom/2)':d=360:s=1280x800:fps=30,hue=h='t*3',eq=brightness='-0.012*t',format=yuv420p[v]" \
  -map "[v]" -map 1:a -t 12 -c:v libx264 -crf 22 -c:a aac -b:a 96k -movflags +faststart "$SM/sunset.mp4"
# A few results to hang on the line next to their originals
cwebp -quiet -q 85 "$SM/lake.png" -o "$SM/lake.webp"
"$FF" -loglevel error -y -t 3 -i "$SM/sunset.mp4" -vf "fps=10,scale=480:-2:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse" "$SM/sunset.gif"
"$FF" -loglevel error -y -i "$SM/sunset.mp4" -vn -c:a aac -b:a 96k "$SM/interview.m4a"
cp "$SM/estimate.md" "$SM/notes.md"
(cd "$SM" && "$BIN" --convert docx estimate.pdf >/dev/null)

# 2. Renders (light and dark)
cd "$FIX"
r() { "$BIN" --snapshot "$@" >/dev/null; }
for d in false true; do
  s=$([[ $d == true ]] && echo -dark || echo "")
  for m in convert tools actions; do
    [[ $m == convert ]] && r wheel "$RAW/wheel-$m$s.png" --opt mode=$m --opt highlight=2 --opt dark=$d "$SM/lake.png"
  done
  r split "$RAW/ed-split$s.png" "$SM/sunset.mp4" --opt dark=$d
  r trim "$RAW/ed-trim$s.png" "$SM/sunset.mp4" --opt dark=$d
  r crop-image "$RAW/ed-crop$s.png" "$SM/lake.png" --opt dark=$d
  r editpdf "$RAW/ed-pdf$s.png" "$SM/estimate.pdf" --opt dark=$d
  r menu "$RAW/menu$s.png" --opt dark=$d
  r shelf "$RAW/shelf$s.png" "$SM/lake.png" "$SM/sunset.mp4" "$SM/estimate.pdf" --opt dark=$d
  # The line holds only the site's samples (older=0), so no test fixtures show up in the loop.
  r clothesline "$RAW/line$s.mp4" --opt dark=$d --opt older=0 \
    --opt "files=$SM/lake.png|$SM/lake.webp|$SM/sunset.mp4|$SM/sunset.gif|$SM/estimate.pdf|$SM/estimate.docx|$SM/interview.m4a|$SM/notes.md"
done
r menubar-icon "$RAW/menubar-icon.png"

# 3. Optimise
cd "$RAW"
for s in "" -dark; do
  cwebp -quiet -q 78 -m 6 -resize 560 0 wheel-convert$s.png -o "$SPARE/wheel-convert$s.webp"
  for e in split trim crop pdf; do webp ed-$e$s.png 1400 76; done
  webp menu$s.png 804 82; webp shelf$s.png 368 82
  # The Clothesline: the left 2640 × 460 px of the 3472 × 640 render (all cards and the notch), 30 fps, no audio.
  "$FF" -loglevel error -y -i line$s.mp4 -vf "crop=2640:460:0:0,scale=1440:250:flags=lanczos,fps=30,format=yuv420p" \
    -an -c:v libx264 -preset slow -crf 26 -tune animation -movflags +faststart "$OUT/line$s.mp4"
  "$FF" -loglevel error -y -ss 2.2 -i line$s.mp4 -frames:v 1 -vf "crop=2640:460:0:0,scale=1440:250:flags=lanczos" "$RAW/line-poster$s.png"
  webp line-poster$s.png 1440 80 line-poster$s
done
# Icons without the source's metadata (which still says 1024 px): ffmpeg writes no XMP, and the EXIF chunk is dropped.
for px in 180:apple-touch-icon 64:favicon-64; do
  "$FF" -loglevel error -y -i "$ROOT/Design/app-icon/AppIcon-1024.png" -vf "scale=${px%%:*}:${px%%:*}:flags=lanczos" -map_metadata -1 "$OUT/${px#*:}.png"
  python3 -c 'import struct,sys
f=sys.argv[1]; d=open(f,"rb").read(); o=d[:8]; i=8
while i<len(d):
    n=struct.unpack(">I",d[i:i+4])[0]; t=d[i+4:i+8]
    if t not in (b"eXIf",b"iTXt",b"tEXt",b"zTXt"): o+=d[i:i+12+n]
    i+=12+n
open(f,"wb").write(o)' "$OUT/${px#*:}.png"
done
cwebp -quiet -q 86 -m 6 -resize 256 0 "$ROOT/Design/app-icon/AppIcon-1024.png" -o "$OUT/icon-256.webp"
cwebp -quiet -q 82 -m 6 -resize 480 0 "$SM/lake.png" -o "$OUT/lake.webp"
"$FF" -loglevel error -y -ss 4 -i "$SM/sunset.mp4" -frames:v 1 -vf scale=480:-2 "$RAW/sunset-frame.png"
cwebp -quiet -q 82 -m 6 "$RAW/sunset-frame.png" -o "$OUT/sunset.webp"
# The social card (public/assets/og-image.jpg) is rendered separately: tools/make-og-image.js.
ls -la "$OUT"
