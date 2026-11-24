#!/bin/zsh
# Regression run for YummyOrange's original features (conversions, tools, PDF tools, refusals).
# Usage: regress-core.sh <binary, .build/debug/DropWheel>
set -u
BIN="$1"
S="${0:A:h}"
W="${DW_WORK:-$S/../.build/test-run/core}"
rm -rf "$W"; mkdir -p "$W"; cd "$W"
cp "$S/fixtures/core/"{photo.png,clip.mp4,tone.wav,report.pdf,big.pdf,scan.pdf,tagged.pdf} .
pass=0; fail=0; failures=()

ok()  { # ok <label> <command...>: must exit 0 and print at least one existing path
  local label="$1"; shift
  local out; out=$("$@" 2>"$W/err.txt"); local st=$?
  local first="${out%%$'\n'*}"
  if [[ $st -eq 0 && -n "$first" && -e "$first" ]]; then pass=$((pass+1)); else fail=$((fail+1)); failures+=("$label: $(head -c 300 "$W/err.txt")"); fi
}
refuse() { # refuse <label> <command...>: must exit non-zero
  local label="$1"; shift
  "$@" >/dev/null 2>&1 && { fail=$((fail+1)); failures+=("$label: should have been refused"); } || pass=$((pass+1))
}

for f in jpg heic webp tiff avif gif bmp pdf; do ok "photo→$f" "$BIN" --convert $f photo.png; done
for t in "Compress" "Strip Metadata" "Half Size" "Rotate 90°" "Extract Text"; do ok "photo $t" "$BIN" --tool "$t" photo.png; done
ok "make pdf" "$BIN" --tool "Make PDF" photo.png photo.jpg
for f in mov mkv webm gif mp3 m4a; do ok "clip→$f" "$BIN" --convert $f clip.mp4; done
for t in "Compress" "Strip Metadata" "Mute" "Extract Audio" "Normalize"; do ok "clip $t" "$BIN" --tool "$t" clip.mp4; done
for f in mp3 m4a flac ogg opus aiff; do ok "tone→$f" "$BIN" --convert $f tone.wav; done
for t in "Compress" "Strip Metadata" "Normalize"; do ok "tone $t" "$BIN" --tool "$t" tone.wav; done
ok "report→png" "$BIN" --convert png report.pdf
ok "scan→jpg" "$BIN" --convert jpg scan.pdf
ok "big compress" "$BIN" --tool Compress big.pdf
ok "tagged strip" "$BIN" --tool "Strip Metadata" tagged.pdf
ok "report rotate" "$BIN" --tool "Rotate 90°" report.pdf
ok "report split" "$BIN" --tool "Split Pages" report.pdf
ok "report text" "$BIN" --tool "Extract Text" report.pdf
ok "scan text" "$BIN" --tool "Extract Text" scan.pdf
ok "protect" "$BIN" --protect secret report.pdf
ok "unlock" "$BIN" --unlock secret "report protected.pdf"
ok "merge" "$BIN" --tool "Merge PDF" report.pdf photo.png
refuse "compress text-only pdf" "$BIN" --tool Compress report.pdf
refuse "wrong password" "$BIN" --unlock nope "report protected.pdf"
"$BIN" --tool "Split Pages" "report page 001.pdf" >/dev/null 2>&1 || true
refuse "split one page" "$BIN" --tool "Split Pages" "report pages/report page 001.pdf"

# Content checks
grep -q . report.txt && pass=$((pass+1)) || { fail=$((fail+1)); failures+=("report.txt empty"); }
# BMP: a real BMP, same size, no alpha channel (transparency is flattened onto white).
bmpinfo=$(sips -g format -g pixelWidth -g hasAlpha photo.bmp 2>/dev/null | tr -s ' ' | tr '\n' ' ')
[[ "$bmpinfo" == *"format: bmp"*"pixelWidth: 1600"*"hasAlpha: no"* ]] && pass=$((pass+1)) || { fail=$((fail+1)); failures+=("photo.bmp: $bmpinfo"); }
[[ $(ls "report pages" | wc -l | tr -d ' ') == 3 ]] && pass=$((pass+1)) || { fail=$((fail+1)); failures+=("split page count"); }

echo "core regression: $pass passed, $fail failed"
for f in "${failures[@]}"; do echo "  FAIL $f"; done
[[ $fail -eq 0 ]]
