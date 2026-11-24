#!/bin/zsh
# Builds YummyOrange.app into ./build (release; signed with your Apple Development identity if you have one, else ad hoc).
#   VERSION=1.0.0 BUILD_NUMBER=1 ./build.sh   (both optional: the marketing version and the build number)
# Optional, for releases and the built-in updater (Tools/updates/release.sh sets them all):
#   UPDATE_FEED_URL     where the app looks for updates (Info.plist DWUpdateFeedURL); default the FEED_URL pinned in
#                       Tools/updates/release-identity, else https://yummyorange.com/updates/appcast.json
#   UPDATE_PUBLIC_KEY   the keys the app trusts, base64, one or more separated by spaces (Info.plist
#                       DWUpdatePublicKey); default the UPDATE_PUBLIC_KEY pinned in Tools/updates/release-identity, and
#                       anything else is refused (ALLOW_UNPINNED_UPDATE_KEY=1 lets release.sh --dry-run use throwaway
#                       keys). Without a key the app can't check for updates.
#   SIGN_IDENTITY       sign with this identity ("Developer ID Application: …", of the TEAM_ID pinned in
#                       release-identity) using the hardened runtime and a secure timestamp, nested code first and the
#                       app without --deep. "-" signs ad hoc with the hardened runtime: the app release.sh hands to
#                       Xcode, whose cloud-managed Developer ID certificate signs it again, keeping the runtime flag
#   SIGN_TIMESTAMP=none leave the timestamp out (release.sh --dry-run, which stays offline)
#   BUILD_DIR           where YummyOrange.app goes (default build; an older build/DropWheel.app is left alone)
set -euo pipefail
cd "$(dirname "$0")"

# Tools/updates/release-identity: KEY=value lines, read here (nothing in it is run).
PINNED_TEAM="" PINNED_KEYS="" PINNED_FEED=""
if [[ -f Tools/updates/release-identity ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      TEAM_ID=*) PINNED_TEAM="${line#TEAM_ID=}" ;;
      UPDATE_PUBLIC_KEY=*) PINNED_KEYS="${line#UPDATE_PUBLIC_KEY=}" ;;
      FEED_URL=*) PINNED_FEED="${line#FEED_URL=}" ;;
    esac
  done < Tools/updates/release-identity
fi
# Keys separated by single spaces, so two spellings of the same list compare equal.
normalize_keys() { local -a k; k=(${=1}); print -r -- "${(j: :)k}" }
PINNED_KEYS=$(normalize_keys "$PINNED_KEYS")

# CFBundleShortVersionString and CFBundleVersion: up to three numbers joined by dots, as macOS and the App Store expect.
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
for pair in "VERSION=$VERSION" "BUILD_NUMBER=$BUILD_NUMBER"; do
  if [[ ! "${pair#*=}" =~ '^[0-9]+(\.[0-9]+){0,2}$' ]]; then
    echo "build.sh: ${pair%%=*} must be up to three numbers joined by dots (got '${pair#*=}')" >&2
    exit 1
  fi
done

# The update feed: HTTPS, or plain HTTP on this Mac for a local test feed. Only characters that need no escaping in
# the Info.plist.
UPDATE_FEED_URL="${UPDATE_FEED_URL:-${PINNED_FEED:-https://yummyorange.com/updates/appcast.json}}"
if [[ ! "$UPDATE_FEED_URL" =~ '^(https://[A-Za-z0-9.-]+|http://(localhost|127\.0\.0\.1))(:[0-9]+)?/[A-Za-z0-9._~/%-]*$' ]]; then
  echo "build.sh: UPDATE_FEED_URL must be an https:// address (or http://localhost / http://127.0.0.1 for a test feed), got '$UPDATE_FEED_URL'" >&2
  exit 1
fi
UPDATE_PUBLIC_KEY=$(normalize_keys "${UPDATE_PUBLIC_KEY:-$PINNED_KEYS}")
if [[ -n "$UPDATE_PUBLIC_KEY" ]]; then
  keys=(${=UPDATE_PUBLIC_KEY})
  if (( ${#keys} > 4 )); then
    echo "build.sh: UPDATE_PUBLIC_KEY lists more than four keys" >&2
    exit 1
  fi
  for k in $keys; do
    if [[ ! "$k" =~ '^[A-Za-z0-9+/]{43}=$' ]] || [[ $(print -rn -- "$k" | base64 -D 2>/dev/null | wc -c | tr -d ' ') != 32 ]]; then
      echo "build.sh: UPDATE_PUBLIC_KEY must be base64 public keys as make-update-keys.swift prints them (32 bytes each), separated by spaces" >&2
      exit 1
    fi
  done
  # Installed copies trust only the keys they were built with: a build with any other key would strand them.
  if [[ "$UPDATE_PUBLIC_KEY" != "$PINNED_KEYS" && "${ALLOW_UNPINNED_UPDATE_KEY:-}" != 1 ]]; then
    echo "build.sh: UPDATE_PUBLIC_KEY isn't the update key pinned in Tools/updates/release-identity (${PINNED_KEYS:-none yet}); pin the key there first" >&2
    exit 1
  fi
  UPDATE_KEY_PLIST="  <key>DWUpdatePublicKey</key><string>$UPDATE_PUBLIC_KEY</string>"
else
  UPDATE_KEY_PLIST=""
  echo "build.sh: no UPDATE_PUBLIC_KEY, so this build can't check for or install updates" >&2
fi
BUILD_DIR="${BUILD_DIR:-build}"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
SIGN_TIMESTAMP="${SIGN_TIMESTAMP:-}"
# A Developer ID identity must be of the pinned team: installed copies refuse a release signed by any other.
if [[ "$SIGN_IDENTITY" == "Developer ID Application: "* && -n "$PINNED_TEAM" && "$SIGN_IDENTITY" != *"($PINNED_TEAM)" ]]; then
  echo "build.sh: SIGN_IDENTITY '$SIGN_IDENTITY' isn't of the team $PINNED_TEAM pinned in Tools/updates/release-identity" >&2
  exit 1
fi
if [[ -n "$SIGN_IDENTITY" && "$SIGN_IDENTITY" != - ]] && ! { security find-identity -v -p codesigning 2>/dev/null || true; } | grep -qF "\"$SIGN_IDENTITY\""; then
  echo "build.sh: SIGN_IDENTITY '$SIGN_IDENTITY' isn't a code-signing identity in your keychain (security find-identity -v -p codesigning)" >&2
  exit 1
fi

# Optimized for size: the heavy lifting is done by the system frameworks and ffmpeg, so -Osize costs little speed and
# saves about a fifth of the binary.
swift build -c release -Xswiftc -Osize
# The SwiftPM product keeps its internal name, DropWheel; inside the app the executable is YummyOrange.
BIN="$(swift build -c release -Xswiftc -Osize --show-bin-path)/DropWheel"

# Assemble and sign outside the project: this folder sits in iCloud Desktop, whose file provider stamps Finder info on
# a fresh bundle within moments, and codesign refuses a bundle with that "detritus". The signed app is copied in last.
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/yummyorange-build.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/YummyOrange.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/YummyOrange"
# Leave out the local symbol table (about a third of the binary): nothing at run time uses it.
strip -x "$APP/Contents/MacOS/YummyOrange"
# The app icon, drawn in code (Design/app-icon/make-icon.sh rebuilds AppIcon.icns). Finder, the Dock and every
# NSAlert the app shows take it from CFBundleIconFile below.
cp Design/app-icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.yummyorange.app</string>
  <key>CFBundleName</key><string>YummyOrange</string>
  <key>CFBundleDisplayName</key><string>YummyOrange</string>
  <key>CFBundleExecutable</key><string>YummyOrange</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>NSHumanReadableCopyright</key><string>Copyright © 2026 YummyOrange.</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSDesktopFolderUsageDescription</key><string>YummyOrange saves the files it makes next to the ones you drop on it, which may be on your Desktop.</string>
  <key>NSDocumentsFolderUsageDescription</key><string>YummyOrange saves the files it makes next to the ones you drop on it, which may be in your Documents folder.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>YummyOrange saves the files it makes next to the ones you drop on it, which may be in your Downloads folder.</string>
  <key>NSRemovableVolumesUsageDescription</key><string>YummyOrange saves the files it makes next to the ones you drop on it, which may be on an external drive.</string>
  <key>NSNetworkVolumesUsageDescription</key><string>YummyOrange saves the files it makes next to the ones you drop on it, which may be on a network drive.</string>
  <key>DWUpdateFeedURL</key><string>$UPDATE_FEED_URL</string>
$UPDATE_KEY_PLIST
</dict>
</plist>
PLIST

# Optional: bundle your own ffmpeg/cwebp by placing them in ./Tools before building. Tools/updates holds the release
# scripts, which never go into the app.
for tool in Tools/*(N); do
  [[ "${tool:t}" == updates ]] && continue
  mkdir -p "$APP/Contents/Resources/Tools"
  ditto "$tool" "$APP/Contents/Resources/Tools/${tool:t}"
done

xattr -cr "$APP"
if [[ -n "$SIGN_IDENTITY" ]]; then
  # A release: the hardened runtime and a secure timestamp (both needed for notarization). Nested code is signed
  # first, then the app on its own, so every piece gets these options rather than whatever --deep would apply.
  sign_opts=(--force --options runtime --sign "$SIGN_IDENTITY")
  if [[ "$SIGN_IDENTITY" == - ]]; then
    # Ad hoc, for Xcode to sign with Developer ID (release.sh): an ad-hoc signature has no timestamp.
    sign_opts+=(--timestamp=none); stamp="ad hoc, for Xcode's Developer ID signing"
  elif [[ "$SIGN_TIMESTAMP" == none ]]; then
    sign_opts+=(--timestamp=none); stamp="no timestamp"
  else
    sign_opts+=(--timestamp); stamp="timestamped"
  fi
  # Every executable file under Resources/Tools (ffmpeg, cwebp), deepest first.
  for nested in "$APP"/Contents/Resources/Tools/**/*(N.x); do
    codesign "${sign_opts[@]}" "$nested"
  done
  codesign "${sign_opts[@]}" "$APP"
  echo "Signed with ${SIGN_IDENTITY/#-/an ad-hoc signature} (hardened runtime, $stamp)"
else
  # Sign with an Apple Development identity when there is one: macOS then keeps permissions such as Accessibility
  # (needed by "Hold the key first") across rebuilds. Otherwise sign ad hoc.
  IDENTITY=$( { security find-identity -v -p codesigning 2>/dev/null || true; } | awk -F'"' '/Apple Development|Developer ID Application/{print $2; exit}')
  if [[ -n "$IDENTITY" ]] && codesign --force --deep --timestamp=none --sign "$IDENTITY" "$APP" 2>/dev/null; then
    echo "Signed with $IDENTITY"
  else
    codesign --force --deep --sign - "$APP"
  fi
fi
codesign --verify --deep --strict "$APP"
rm -rf "$BUILD_DIR/YummyOrange.app"
mkdir -p "$BUILD_DIR"
ditto "$APP" "$BUILD_DIR/YummyOrange.app"
codesign --verify --deep "$BUILD_DIR/YummyOrange.app"
echo "Built $BUILD_DIR/YummyOrange.app (version $VERSION, build $BUILD_NUMBER)"
