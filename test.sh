#!/bin/zsh
# Runs every YummyOrange test: builds the debug binary, then the original-features regression (Tests/regress-core.sh),
# the new-features run (Tests/features.sh) and every module's --selftest. Prints one line per suite and exits 1 if
# anything failed. Takes about seven to ten minutes. Outputs go to a new temporary folder outside the project
# (printed at the end): the project sits in iCloud Desktop, whose file provider puts deleted files back as "name 2",
# which broke the output-count checks when they ran inside .build/test-run.
set -u
setopt pipefail
cd "${0:A:h}"
echo "Building…"
swift build 2>&1 | grep -E "error|Build complete" || { echo "build failed"; exit 1; }
# The SwiftPM product keeps its internal name, DropWheel (the app bundle calls its executable YummyOrange).
BIN="$PWD/.build/debug/DropWheel"
failed=0

# Self-tests keep their preferences in memory (SelfTestDefaults). A real UserDefaults suite leaves
# ~/Library/Preferences/<suite>.plist behind for good, so the run fails if any more of those appear.
leftovers() { ls "$HOME/Library/Preferences" 2>/dev/null \
  | grep -cE '^(DropWheel|YummyOrange)\.selftest\.[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\.plist$' }
leftovers_before=$(leftovers)

RUN=$(mktemp -d "${TMPDIR:-/tmp}/yummyorange-test.XXXXXX")
DW_WORK="$RUN/core" zsh Tests/regress-core.sh "$BIN" | head -12 || failed=1
DW_WORK="$RUN/features" zsh Tests/features.sh "$BIN" | tail -12 || failed=1

for t in appshell gesture settings wheel mainthread holdkey image-extras image-extras-files raw-types image-editors \
         image-crop-redact pdf-extras more-formats media-probe archives subtitles target-size textdocs-roundtrip textdocs-encodings \
         textdocs-thread textdocs-limits pdf-text-convert markdown ebooks ebooks-hardening epub-roundtrip pages-synthetic snappy \
         epub-pdf-background presentations spreadsheets shelf results-shelf welcome media-trim media-tools media-split media-merge media-frame pdf-edit pdf-edit-ui \
         clothesline clothesline-screenshots menubar menu-latency updater; do
  out=$("$BIN" --selftest $t 2>/dev/null)
  st=$?
  line=$(print -r -- "$out" | grep -m1 -E "^(PASS|OK|FAIL)")
  if [[ $st -ne 0 || "$line" == FAIL* || -z "$line" ]]; then
    failed=1
    echo "FAIL selftest $t"
    print -r -- "$out" | grep -E "✗|FAIL" | head -5 | sed 's/^/    /'
  else
    echo "ok   selftest $t: ${line#* }"
  fi
done

sleep 3   # cfprefsd writes a suite's file a moment after the process that used it ends
leftovers_after=$(leftovers)
if (( leftovers_after > leftovers_before )); then
  failed=1
  echo "FAIL self-test preferences: $(( leftovers_after - leftovers_before )) new *.selftest.<UUID>.plist in ~/Library/Preferences"
else
  echo "ok   self-test preferences: none left in ~/Library/Preferences ($leftovers_after there)"
fi

if [[ $failed -eq 0 ]]; then echo "All tests passed."; else echo "Some tests failed. Outputs: $RUN"; fi
exit $failed
