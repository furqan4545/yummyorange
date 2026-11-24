#!/bin/zsh
# Runs every command added after the original features once, on Tests/fixtures/features. Usage: features.sh <binary>
set -u
BIN="$1"; S="${0:A:h}"; W="${DW_WORK:-$S/../.build/test-run/features}"
rm -rf "$W"; mkdir -p "$(dirname "$W")"; cp -R "$S/fixtures/features" "$W"; cd "$W"
pass=0; fail=0; failures=()
ok() { local label="$1"; shift; local out; out=$("$@" 2>"$W/err.txt"); local st=$?; local first="${out%%$'\n'*}"
  if [[ $st -eq 0 && -n "$first" && -e "$first" ]]; then pass=$((pass+1)); else fail=$((fail+1)); failures+=("$label: exit $st $(head -c 240 "$W/err.txt" | tr '\n' ' ')"); fi; }
# Images
ok resize "$BIN" --tool resize --opt mode=width --opt value=400 photo.png
ok frame "$BIN" --tool frame photo.png
ok collage "$BIN" --tool collage photo.png camera.dng features.svg
ok qr "$BIN" --tool qr qr.svg
ok adjust "$BIN" --tool adjust --opt exposure=0.5 --opt contrast=1.2 photo.png
ok annotate "$BIN" --tool annotate --opt 'annotations=[{"type":"arrow","from":[10,10],"to":[200,200]}]' photo.png
ok crop "$BIN" --tool crop --opt x=100 --opt y=50 --opt w=600 --opt h=400 --opt rotate=90 photo.png
ok crop-aspect "$BIN" --tool crop --opt aspect=1:1 photo.png
ok crop-dng "$BIN" --tool crop --opt w=16 --opt h=12 camera.dng
ok redact "$BIN" --tool redact --opt 'boxes=10,10,300,200,blur;400,100,300,300,pixelate;800,500,200,200' photo.png
ok redact-find "$BIN" --tool redact --opt find=text photo.png
ok background "$BIN" --tool background --opt canvas=square --opt padding=5 --opt color=#336699 photo.png
ok background-svg "$BIN" --tool background --opt color=#FFFFFF features.svg
ok svg→png "$BIN" --convert png features.svg
ok svg→pdf "$BIN" --convert pdf features.svg
ok dng→jpg "$BIN" --convert jpg camera.dng
ok dng-half "$BIN" --tool "Half Size" camera.dng
ok img→pptx "$BIN" --convert pptx photo.png camera.dng
# PDF
ok organize "$BIN" --tool organize --opt order=3,1,2 report.pdf
ok pdfa "$BIN" --tool pdfa report.pdf
ok pdf→svg "$BIN" --convert svg report.pdf
ok pdf→docx "$BIN" --convert docx report.pdf
ok pdf→txt "$BIN" --convert txt report.pdf
ok pdf→md "$BIN" --convert md report.pdf
ok pdf→pptx "$BIN" --convert pptx report.pdf
ok pdf→xlsx "$BIN" --convert xlsx report.pdf
ok pdf→epub "$BIN" --convert epub report.pdf
ok editpdf "$BIN" --tool editpdf --opt find="Quarterly Report" --opt replace="Quarterly Totals" report.pdf
# Target size
ok target-img "$BIN" --tool compress-to --opt target_mb=0.05 photo.png
ok target-vid "$BIN" --tool compress-to --opt target_mb=0.2 clip.mp4
ok target-pdf "$BIN" --tool compress-to --opt target_mb=0.1 scan.pdf
# Media formats
for f in wma avi wmv; do ok "clip→$f" "$BIN" --convert $f clip.mp4; done
ok "mkv→mp4" "$BIN" --convert mp4 odd.mkv
ok "wma→mp3" "$BIN" --convert mp3 sample.wma
ok "avi→mp4" "$BIN" --convert mp4 sample.avi
ok "wmv→mp4" "$BIN" --convert mp4 sample.wmv
ok "tone→wma" "$BIN" --convert wma tone.wav
# Media editors
ok trim-video "$BIN" --tool trim --opt start=1.5 --opt end=3 clip.mp4
ok trim-audio "$BIN" --tool trim --opt start=0.5 --opt end=2.25 tone.wav
ok bleep-video "$BIN" --tool bleep --opt ranges=1-1.5,2.25-3 clip.mp4
ok bleep-audio "$BIN" --tool bleep --opt ranges=0.5-1 --opt mode=silence tone.wav
ok speed "$BIN" --tool speed --opt factor=2 clip.mp4
ok speed-pitch "$BIN" --tool speed --opt factor=0.5 --opt keep_pitch=false tone.wav
ok split "$BIN" --tool split --opt parts=3 clip.mp4
ok split-every "$BIN" --tool split --opt mode=every --opt seconds=1.5 tone.wav
ok split-at "$BIN" --tool split --opt at=1.2,0:02.60 clip.mp4
ok channels "$BIN" --tool channels --opt layout=stereo tone.wav
ok channels-video "$BIN" --tool channels sample.avi
ok merge "$BIN" --tool merge clip.mp4 odd.mkv sample.wmv
ok visualize "$BIN" --tool visualize --opt style=bars --opt size=wide tone.wav
ok crop-video "$BIN" --tool crop-video --opt x=100 --opt y=60 --opt w=640 --opt h=360 clip.mp4
ok redact-video "$BIN" --tool redact-video --opt 'boxes=800,450,320,176,blur,1,2.5;0,0,112,44,pixelate;180,260,300,260,black,0.5,3' clip.mp4
ok snapshot-video "$BIN" --tool snapshot --opt time=1.5 clip.mp4
# Subtitles
ok srt→vtt "$BIN" --convert vtt subs.srt
ok vtt→srt "$BIN" --convert srt subs.vtt
ok srt→txt "$BIN" --convert txt subs.srt
# Archives
ok zip-folder "$BIN" --convert zip folder
ok tar-folder "$BIN" --convert tar folder
ok gz-folder "$BIN" --convert gz folder
ok zip-action "$BIN" --tool zip photo.png report.pdf
ok extract-tgz "$BIN" --tool extract proj.tgz
ok extract-7z "$BIN" --tool extract proj.7z
ok extract-rar "$BIN" --tool extract stored.rar
# Documents
for f in pdf rtf html txt md odt epub; do ok "docx→$f" "$BIN" --convert $f cocoa.docx; done
for f in pdf docx; do ok "doc→$f" "$BIN" --convert $f cocoa.doc; done
for f in pdf docx html; do ok "md→$f" "$BIN" --convert $f sample.md; done
for f in pdf docx md; do ok "html→$f" "$BIN" --convert $f sample.html; done
for f in pdf docx txt md html; do ok "epub→$f" "$BIN" --convert $f book.epub; done
for f in pdf docx txt epub; do ok "pages→$f" "$BIN" --convert $f doc.pages; done
for f in pdf png jpg; do ok "pptx→$f" "$BIN" --convert $f deck.pptx; done
for f in pdf pptx; do ok "ppt→$f" "$BIN" --convert $f legacy.ppt; done
ok slide-text "$BIN" --tool slide-text deck.pptx
for f in xlsx ods csv tsv pdf; do ok "xls→$f" "$BIN" --convert $f biff8.xls; done
ok "xlsx→pdf" "$BIN" --convert pdf report.xlsx
ok "ods→xlsx" "$BIN" --convert xlsx biff8.ods
ok "csv→xlsx" "$BIN" --convert xlsx "biff8 - Data.csv"
# Snapshots (windows rendered offscreen)
for s in settings menu wheel adjust annotate crop-image redact-image organizer shelf welcome editpdf trim bleep split crop-video redact-video snapshot-video; do
  f=""; case $s in adjust|annotate|crop-image) f=photo.png;; organizer|editpdf) f=report.pdf;; shelf) f=photo.png;; trim|bleep|split|crop-video|redact-video|snapshot-video) f=clip.mp4;; esac
  ok "snap $s" "$BIN" --snapshot $s "$W/snap-$s.png" ${f:+$f}
done
echo "new-feature smoke: $pass passed, $fail failed"
for f in "${failures[@]}"; do echo "  FAIL $f"; done
[[ $fail -eq 0 ]]
