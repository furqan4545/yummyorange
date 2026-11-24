#!/bin/zsh
# Makes a YummyOrange release and puts it in the website folder, ready to deploy (Vercel serves Website/public):
#
#   VERSION=1.0.1 BUILD_NUMBER=2 \
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=dropwheel-notary \
#   UPDATE_PRIVATE_KEY=~/.dropwheel/update-signing-key UPDATE_FEED_URL=https://yummyorange.com/updates/appcast.json \
#   Tools/updates/release.sh
#
#   Tools/updates/release.sh --dry-run [--out <folder>]   everything on this Mac with the identity it has, throwaway
#                                                          update keys (never the release key), no notarization and
#                                                          no network, into a scratch folder
#
# Tools/updates/release-identity pins the team (TEAM_ID), the update keys (UPDATE_PUBLIC_KEY) and, once known, the
# feed's address (FEED_URL). A real release refuses another team, another key, or no feed address; and it reads the
# release already published (its ZIP in Website/public/downloads) to check that installed copies trust this release's
# team and key, so they take it.
#
# Steps: build.sh with the hardened runtime and a secure timestamp (Developer ID); notarize and staple the app; zip it
# with ditto -c -k --keepParent (the update); build YummyOrange.dmg with an Applications link, sign, notarize and staple
# it; sign the ZIP and then the feed with the update key; check the result with YummyOrange's own updater code as an
# installed copy would (the trusted team and keys, Developer ID, notarized, Gatekeeper); check that the live site at
# the feed's address is this one; then write
#   Website/public/updates/appcast.json and appcast.json.sig (the feed's signature)
#   Website/public/downloads/YummyOrange-<version>-<build>.zip
#   Website/public/downloads/YummyOrange.dmg
#   Website/public/js/config.js (dmgURL, version, notarized: true)
# Nothing in Website/public changes unless every step passed: a failed notarization, an identity that isn't a
# Developer ID of the pinned team, a build number not above the published one, or a key that isn't pinned and trusted
# stops it first.
#
# Optional: RELEASE_NOTES (a few lines the update alert shows), RELEASE_NOTES_URL (default ../release-notes.html, relative
# to the feed), MINIMUM_SYSTEM_VERSION (default 13.0), UPDATE_KEY_PASSPHRASE (the private key's passphrase; asked for
# once on the terminal when the key is encrypted and this isn't set).
set -euo pipefail
ROOT="${0:A:h:h:h}"
cd "$ROOT"

die() { print -u2 -- "release.sh: $*"; exit 1 }
step() { print -- "\n==> $*" }

DRY_RUN=0
OUT=""
while (( $# )); do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --out) (( $# >= 2 )) || die "--out needs a folder"; OUT="$2"; shift ;;
    -h|--help) sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option $1 (see --help)" ;;
  esac
  shift
done

is_version() { [[ "$1" =~ '^[0-9]{1,9}(\.[0-9]{1,9}){0,2}$' ]] }
# True when version $1 is higher than $2 (number by number; missing parts are 0).
version_gt() {
  local -a a b
  a=(${(s:.:)1}) b=(${(s:.:)2})
  local i x y
  for i in 1 2 3; do
    x=${a[i]:-0} y=${b[i]:-0}
    (( x > y )) && return 0
    (( x < y )) && return 1
  done
  return 1
}
# Keys separated by single spaces, so two spellings of the same list compare equal.
normalize_keys() { local -a k; k=(${=1}); print -r -- "${(j: :)k}" }
# True when key $1 is in the list $2; when lists $1 and $2 share a key.
key_in() { local k; for k in ${=2}; do [[ "$k" == "$1" ]] && return 0; done; return 1 }
lists_share() { local k; for k in ${=1}; do key_in "$k" "$2" && return 0; done; return 1 }
# True when path $1 (which need not exist) is inside folder $2: some existing folder above it is $2 itself, compared by
# device and inode, so letter case and Unicode spelling can't hide it.
is_inside() {
  local p="${1:A}" target
  [[ -d "$2" ]] || return 1
  target=$(stat -f '%d:%i' "$2") || return 1
  while true; do
    if [[ -e "$p" && "$(stat -f '%d:%i' "$p")" == "$target" ]]; then return 0; fi
    [[ "$p" == / ]] && return 1
    p="${p:h}"
  done
}

VERSION="${VERSION:-}"
BUILD_NUMBER="${BUILD_NUMBER:-}"
is_version "$VERSION" || die "set VERSION, up to three numbers joined by dots (got '$VERSION')"
is_version "$BUILD_NUMBER" || die "set BUILD_NUMBER, up to three numbers joined by dots (got '$BUILD_NUMBER')"
RELEASE_NOTES="${RELEASE_NOTES:-}"
RELEASE_NOTES_URL="${RELEASE_NOTES_URL:-../release-notes.html}"
MINIMUM_SYSTEM_VERSION="${MINIMUM_SYSTEM_VERSION:-13.0}"
is_version "$MINIMUM_SYSTEM_VERSION" || die "MINIMUM_SYSTEM_VERSION must be a version such as 13.0"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
UPDATE_PRIVATE_KEY="${UPDATE_PRIVATE_KEY:-}"
UPDATE_PUBLIC_KEY="${UPDATE_PUBLIC_KEY:-}"
UPDATE_FEED_URL="${UPDATE_FEED_URL:-}"
SITE="$ROOT/Website/public"

# Tools/updates/release-identity: KEY=value lines, read here (nothing in it is run).
PINNED_TEAM="" PINNED_KEYS="" PINNED_FEED=""
if [[ -f "$ROOT/Tools/updates/release-identity" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      TEAM_ID=*) PINNED_TEAM="${line#TEAM_ID=}" ;;
      UPDATE_PUBLIC_KEY=*) PINNED_KEYS="${line#UPDATE_PUBLIC_KEY=}" ;;
      FEED_URL=*) PINNED_FEED="${line#FEED_URL=}" ;;
    esac
  done < "$ROOT/Tools/updates/release-identity"
fi
PINNED_KEYS=$(normalize_keys "$PINNED_KEYS")

WORK=$(mktemp -d "${TMPDIR:-/tmp}/yummyorange-release.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# Everything that can be refused without the keychain, the network or the key's contents comes first.
if (( DRY_RUN )); then
  # A dry run signs with throwaway keys only: its output looks like a release, so the release key never signs one.
  [[ -z "$UPDATE_PRIVATE_KEY" && -z "$UPDATE_PUBLIC_KEY" ]] \
    || die "--dry-run signs with throwaway update keys only: unset UPDATE_PRIVATE_KEY and UPDATE_PUBLIC_KEY"
  UPDATE_FEED_URL="${UPDATE_FEED_URL:-${PINNED_FEED:-https://yummyorange.com/updates/appcast.json}}"
  [[ "$UPDATE_FEED_URL" == https://* ]] || die "UPDATE_FEED_URL must be an https:// address"
else
  # The feed's address is built into every copy for good, so it is never a guess.
  if [[ -z "$UPDATE_FEED_URL" ]]; then
    [[ -n "$PINNED_FEED" ]] \
      || die "set UPDATE_FEED_URL to the site's real feed address, or pin it as FEED_URL in Tools/updates/release-identity: every copy keeps asking that address"
    UPDATE_FEED_URL="$PINNED_FEED"
  elif [[ -n "$PINNED_FEED" && "$UPDATE_FEED_URL" != "$PINNED_FEED" ]]; then
    die "UPDATE_FEED_URL ($UPDATE_FEED_URL) isn't the FEED_URL pinned in Tools/updates/release-identity ($PINNED_FEED)"
  fi
  [[ "$UPDATE_FEED_URL" =~ '^https://[A-Za-z0-9.-]+(:[0-9]+)?/([A-Za-z0-9._~%-]+/)*updates/appcast\.json$' ]] \
    || die "UPDATE_FEED_URL must be an https:// address ending in /updates/appcast.json (got '$UPDATE_FEED_URL')"
  [[ "$PINNED_TEAM" =~ '^[A-Z0-9]{10}$' ]] || die "Tools/updates/release-identity must pin TEAM_ID, the Developer ID team (10 letters and digits)"
  [[ "$SIGN_IDENTITY" == "Developer ID Application: "* ]] \
    || die "SIGN_IDENTITY must be a Developer ID Application identity (got '${SIGN_IDENTITY:-nothing}'); releases are signed with Developer ID"
  [[ "$SIGN_IDENTITY" == *"($PINNED_TEAM)" ]] \
    || die "SIGN_IDENTITY '$SIGN_IDENTITY' isn't of the team $PINNED_TEAM pinned in Tools/updates/release-identity: installed copies would refuse its release"
  [[ -n "$PINNED_KEYS" ]] \
    || die "Tools/updates/release-identity pins no UPDATE_PUBLIC_KEY yet: make the key with make-update-keys.swift and put its public half there"
  UPDATE_PUBLIC_KEY=$(normalize_keys "${UPDATE_PUBLIC_KEY:-$PINNED_KEYS}")
  [[ "$UPDATE_PUBLIC_KEY" == "$PINNED_KEYS" ]] \
    || die "UPDATE_PUBLIC_KEY isn't the update key pinned in Tools/updates/release-identity ($PINNED_KEYS)"
  [[ -n "$NOTARY_PROFILE" ]] || die "set NOTARY_PROFILE to a notarytool keychain profile (xcrun notarytool store-credentials)"
  [[ -n "$UPDATE_PRIVATE_KEY" ]] || die "set UPDATE_PRIVATE_KEY to the private key file"
  UPDATE_PRIVATE_KEY="${UPDATE_PRIVATE_KEY/#\~/$HOME}"
  # Never where it would be committed, published or synced sooner or later.
  for place in "$ROOT" "$HOME/Desktop" "$HOME/Documents" "$HOME/Library/Mobile Documents"; do
    is_inside "$UPDATE_PRIVATE_KEY" "$place" \
      && die "the private key must not be inside $place (committed, published or synced sooner or later): keep it in ~/.dropwheel, or off this Mac"
  done
  [[ -f "$UPDATE_PRIVATE_KEY" ]] || die "no private key at $UPDATE_PRIVATE_KEY"
fi

# The release already published: installed copies trust its team and its keys, so this one must be made with them.
PUBLISHED_KEYS=""
if [[ -f "$SITE/updates/appcast.json" ]]; then
  published=$(plutil -extract build raw -o - "$SITE/updates/appcast.json" 2>/dev/null || true)
  if [[ -n "$published" ]] && ! version_gt "$BUILD_NUMBER" "$published"; then
    die "BUILD_NUMBER $BUILD_NUMBER isn't higher than the published build $published"
  fi
  if (( ! DRY_RUN )); then
    published_url=$(plutil -extract url raw -o - "$SITE/updates/appcast.json" 2>/dev/null || true)
    published_name="${published_url#../downloads/}"
    [[ "$published_url" == ../downloads/* && "$published_name" == YummyOrange-*.zip && "$published_name" != */* ]] \
      || die "the published feed's url ('$published_url') isn't a ZIP in downloads/, so what installed copies trust can't be read"
    published_zip="$SITE/downloads/$published_name"
    [[ -f "$published_zip" ]] || die "the published release $published_zip is missing: release.sh reads it to learn what installed copies trust"
    mkdir -p "$WORK/published"
    ditto -x -k "$published_zip" "$WORK/published" || die "the published release doesn't unpack"
    published_app="$WORK/published/YummyOrange.app"
    [[ -d "$published_app" ]] || die "the published release has no YummyOrange.app"
    PUBLISHED_KEYS=$(normalize_keys "$(plutil -extract DWUpdatePublicKey raw -o - "$published_app/Contents/Info.plist" 2>/dev/null || true)")
    published_team=$(codesign -dvvv "$published_app" 2>&1 | awk -F= '/^TeamIdentifier=/{print $2; exit}')
    [[ "$published_team" == "$PINNED_TEAM" ]] \
      || die "the published release is signed by team ${published_team:-none}, not the pinned $PINNED_TEAM, so its copies would refuse this release"
    [[ -n "$PUBLISHED_KEYS" ]] && lists_share "$PUBLISHED_KEYS" "$PINNED_KEYS" \
      || die "the published release trusts none of the update keys pinned in Tools/updates/release-identity (it trusts ${PUBLISHED_KEYS:-none}), so its copies would refuse this release"
  fi
fi

identities=$( { security find-identity -v -p codesigning 2>/dev/null || true; } )
if (( DRY_RUN )); then
  step "Dry run: nothing is notarized, nothing in Website/public changes"
  if [[ -z "$SIGN_IDENTITY" ]]; then
    SIGN_IDENTITY=$(print -r -- "$identities" | awk -F'"' '/Developer ID Application|Apple Development/{print $2; exit}')
  fi
  if [[ -z "$SIGN_IDENTITY" ]]; then
    print -u2 "release.sh: no code-signing identity on this Mac: the dry run signs ad hoc, without the hardened runtime"
  fi
  UPDATE_PRIVATE_KEY="$WORK/keys/update-signing-key"
  UPDATE_PUBLIC_KEY=$(swift Tools/updates/make-update-keys.swift --no-passphrase "$UPDATE_PRIVATE_KEY" 2>/dev/null) \
    || die "couldn't make throwaway update keys"
  print "Throwaway update keys for this dry run (public key $UPDATE_PUBLIC_KEY)"
  if [[ -z "$OUT" ]]; then OUT=$(mktemp -d "${TMPDIR:-/tmp}/yummyorange-release-dry-run.XXXXXX"); fi
  OUT="${OUT:A}"
  [[ "$OUT/" == "$SITE/"* || "$SITE/" == "$OUT/"* ]] && die "--out must not be the website folder or around it"
  DEST="$OUT/public"
  STAMP=none
  NOTARIZED=false
  TRUSTED_KEYS="$UPDATE_PUBLIC_KEY"
else
  print -r -- "$identities" | grep -qF "\"$SIGN_IDENTITY\"" \
    || die "'$SIGN_IDENTITY' isn't in your keychain (security find-identity -v -p codesigning). Install the Developer ID Application certificate first."
  xcrun --find notarytool >/dev/null 2>&1 && xcrun --find stapler >/dev/null 2>&1 || die "notarytool and stapler are missing (install Xcode or its command line tools)"
  step "Checking the notarytool profile"
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null || die "the notarytool profile '$NOTARY_PROFILE' doesn't work"
  if [[ "$(head -1 "$UPDATE_PRIVATE_KEY")" == "dropwheel-update-key 2" && -z "${UPDATE_KEY_PASSPHRASE:-}" ]]; then
    read -rs "UPDATE_KEY_PASSPHRASE?Passphrase for $UPDATE_PRIVATE_KEY: " < /dev/tty || die "no passphrase for the encrypted private key"
    print
  fi
  export UPDATE_KEY_PASSPHRASE="${UPDATE_KEY_PASSPHRASE:-}"
  DEST="$SITE"
  STAMP=""
  NOTARIZED=true
  # What the copies out there trust: the published release's keys, or (for the first release) the pinned ones.
  TRUSTED_KEYS="${PUBLISHED_KEYS:-$PINNED_KEYS}"
fi

step "Checking that the private key is one of the update keys installed copies trust"
print -n "YummyOrange" > "$WORK/probe"
swift Tools/updates/sign-update.swift --public-key "$UPDATE_PUBLIC_KEY" "$UPDATE_PRIVATE_KEY" "$WORK/probe" >/dev/null \
  || die "the private key isn't one of UPDATE_PUBLIC_KEY's keys (or its passphrase is wrong)"
swift Tools/updates/sign-update.swift --public-key "$TRUSTED_KEYS" "$UPDATE_PRIVATE_KEY" "$WORK/probe" >/dev/null \
  || die "installed copies don't trust this private key (they trust $TRUSTED_KEYS)"

step "Building YummyOrange $VERSION ($BUILD_NUMBER)"
VERSION="$VERSION" BUILD_NUMBER="$BUILD_NUMBER" UPDATE_FEED_URL="$UPDATE_FEED_URL" UPDATE_PUBLIC_KEY="$UPDATE_PUBLIC_KEY" \
  SIGN_IDENTITY="$SIGN_IDENTITY" SIGN_TIMESTAMP="$STAMP" BUILD_DIR="$WORK/build" ALLOW_UNPINNED_UPDATE_KEY="$DRY_RUN" ./build.sh
APP="$WORK/build/YummyOrange.app"
xattr -cr "$APP"

step "Checking the app's signature and Info.plist"
codesign --verify --deep --strict --verbose=2 "$APP"
details=$(codesign -dvvv "$APP" 2>&1)
[[ "$(plutil -extract CFBundleVersion raw -o - "$APP/Contents/Info.plist")" == "$BUILD_NUMBER" ]] || die "the built app has the wrong build number"
[[ "$(plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist")" == "$VERSION" ]] || die "the built app has the wrong version"
[[ "$(plutil -extract DWUpdatePublicKey raw -o - "$APP/Contents/Info.plist")" == "$UPDATE_PUBLIC_KEY" ]] || die "the built app doesn't carry UPDATE_PUBLIC_KEY"
[[ "$(plutil -extract DWUpdateFeedURL raw -o - "$APP/Contents/Info.plist")" == "$UPDATE_FEED_URL" ]] || die "the built app doesn't carry UPDATE_FEED_URL"
TEAM=$(print -r -- "$details" | awk -F= '/^TeamIdentifier=/{print $2; exit}')
[[ "$TEAM" == "not set" ]] && TEAM=""
if [[ -n "$SIGN_IDENTITY" ]]; then
  print -r -- "$details" | grep -q 'flags=.*runtime' || die "the app isn't signed with the hardened runtime"
  [[ -n "$TEAM" ]] || die "the app's signature has no team"
fi
if (( ! DRY_RUN )); then
  print -r -- "$details" | grep -q '^Authority=Developer ID Application:' || die "the app isn't signed with Developer ID"
  print -r -- "$details" | grep -q '^Timestamp=' || die "the app's signature has no secure timestamp"
  [[ "$TEAM" == "$PINNED_TEAM" ]] || die "the app is signed by team $TEAM, not the pinned $PINNED_TEAM"
fi
print -r -- "$details" | grep -E '^(Identifier|Authority|TeamIdentifier|Timestamp|CodeDirectory)' || true
# The team installed copies trust: the pinned one (a dry run on a Mac without it: its own, which proves less).
TRUSTED_TEAM="${PINNED_TEAM:-$TEAM}"
(( DRY_RUN )) && [[ -z "$TEAM" ]] && TRUSTED_TEAM=""

notarize() {
  local file=$1 result="$WORK/notary-${1:t}.json" notary_status id
  print "Submitting ${file:t} to Apple's notary service (this can take a few minutes)"
  xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$result" || true
  notary_status=$(plutil -extract status raw -o - "$result" 2>/dev/null || print unknown)
  id=$(plutil -extract id raw -o - "$result" 2>/dev/null || true)
  if [[ "$notary_status" != Accepted ]]; then
    print -u2 "Notarization of ${file:t}: $notary_status"
    [[ -n "$id" ]] && xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2 || true
    die "notarization failed, so nothing was published"
  fi
  print "Notarized ${file:t} (submission $id)"
}

if (( DRY_RUN )); then
  step "Notarizing and stapling the app: skipped (dry run)"
else
  step "Notarizing and stapling the app"
  ditto -c -k --keepParent "$APP" "$WORK/notarize-YummyOrange.zip"
  notarize "$WORK/notarize-YummyOrange.zip"
  xcrun stapler staple "$APP" || die "stapling the app failed"
  xcrun stapler validate "$APP" || die "the app's stapled ticket doesn't validate"
  spctl --assess --type execute --verbose=4 "$APP" 2>&1 | tee "$WORK/spctl-app.txt"
  grep -q "source=Notarized Developer ID" "$WORK/spctl-app.txt" || die "Gatekeeper doesn't accept the app as notarized"
fi

step "Zipping the update"
# The build is in the name: a re-release of the same version with a higher build never reuses the address that caches
# and the previous feed point at.
ZIP_NAME="YummyOrange-$VERSION-$BUILD_NUMBER.zip"
ZIP="$WORK/$ZIP_NAME"
ditto -c -k --keepParent "$APP" "$ZIP"

step "Building YummyOrange.dmg"
DMG="$WORK/YummyOrange.dmg"
mkdir -p "$WORK/dmg"
ditto "$APP" "$WORK/dmg/YummyOrange.app"
ln -s /Applications "$WORK/dmg/Applications"
hdiutil create -quiet -volname YummyOrange -srcfolder "$WORK/dmg" -fs HFS+ -format UDZO -ov "$DMG"
hdiutil verify -quiet "$DMG"
if [[ -n "$SIGN_IDENTITY" ]]; then
  if [[ "$STAMP" == none ]]; then
    codesign --force --timestamp=none --sign "$SIGN_IDENTITY" "$DMG"
  else
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
  fi
  codesign --verify --strict "$DMG"
fi
if (( DRY_RUN )); then
  print "Notarizing and stapling the disk image: skipped (dry run)"
else
  notarize "$DMG"
  xcrun stapler staple "$DMG" || die "stapling the disk image failed"
  xcrun stapler validate "$DMG" || die "the disk image's stapled ticket doesn't validate"
  spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG" 2>&1 | tee "$WORK/spctl-dmg.txt"
  grep -q "source=Notarized Developer ID" "$WORK/spctl-dmg.txt" || die "Gatekeeper doesn't accept the disk image as notarized"
fi

step "Signing the update with the update key"
signed=$(swift Tools/updates/sign-update.swift --public-key "$UPDATE_PUBLIC_KEY" "$UPDATE_PRIVATE_KEY" "$ZIP") || die "signing the update failed"
SHA=$(print -r -- "$signed" | awk '$1=="sha256"{print $2}')
LENGTH=$(print -r -- "$signed" | awk '$1=="length"{print $2}')
SIGNATURE=$(print -r -- "$signed" | awk '$1=="signature"{print $2}')
[[ -n "$SHA" && -n "$LENGTH" && -n "$SIGNATURE" ]] || die "sign-update printed something unexpected"
print -r -- "$signed"

step "Writing the feed, its signature and the site's release details"
STAGED="$WORK/public"
mkdir -p "$STAGED/updates" "$STAGED/downloads" "$STAGED/js"
cp "$ZIP" "$STAGED/downloads/$ZIP_NAME"
cp "$DMG" "$STAGED/downloads/YummyOrange.dmg"
swift Tools/updates/make-appcast.swift --version "$VERSION" --build "$BUILD_NUMBER" --minimum-system "$MINIMUM_SYSTEM_VERSION" \
  --url "../downloads/$ZIP_NAME" --length "$LENGTH" --sha256 "$SHA" --signature "$SIGNATURE" \
  --notes-url "$RELEASE_NOTES_URL" --notes "$RELEASE_NOTES" "$STAGED/updates/appcast.json" >/dev/null
# The feed's own signature (of its exact bytes): installed copies read the feed only once it checks out.
feed_signed=$(swift Tools/updates/sign-update.swift --public-key "$UPDATE_PUBLIC_KEY" "$UPDATE_PRIVATE_KEY" "$STAGED/updates/appcast.json") \
  || die "signing the feed failed"
print -r -- "$feed_signed" | awk '$1=="signature"{print $2}' > "$STAGED/updates/appcast.json.sig"
[[ -s "$STAGED/updates/appcast.json.sig" ]] || die "sign-update printed no signature for the feed"
cp "$SITE/js/config.js" "$STAGED/js/config.js"
V="$VERSION" N="$NOTARIZED" perl -0pi -e '
  s/^(\s*version:\s*)"[^"]*"/$1"$ENV{V}"/m or die "no version line\n";
  s/^(\s*dmgURL:\s*)"[^"]*"/$1"downloads\/YummyOrange.dmg"/m or die "no dmgURL line\n";
  s/^(\s*notarized:\s*)(?:true|false)/$1$ENV{N}/m or die "no notarized line\n";
' "$STAGED/js/config.js" || die "config.js doesn't have the version, dmgURL and notarized lines it should"
grep -E '^\s*(version|dmgURL|notarized):' "$STAGED/js/config.js"

step "Checking the release with YummyOrange's own updater code, as an installed copy would"
swift build 2>&1 | grep -E "error|Build complete" || die "the debug build failed"
adhoc=0; [[ -z "$TRUSTED_TEAM" ]] && adhoc=1
developer_id=0; (( ! DRY_RUN )) && developer_id=1
check=$(DW_RELEASE_PUBLIC_KEY="$TRUSTED_KEYS" DW_RELEASE_FEED_URL="$UPDATE_FEED_URL" DW_RELEASE_TEAM="$TRUSTED_TEAM" \
  DW_RELEASE_ALLOW_ADHOC=$adhoc DW_RELEASE_DEVELOPER_ID=$developer_id \
  .build/debug/DropWheel --selftest "updater-release:$STAGED" 2>&1) || { print -u2 -- "$check"; die "the app's updater refuses this release"; }
print -r -- "$check"
[[ "$check" == PASS* ]] || die "the app's updater refuses this release"

if (( ! DRY_RUN )); then
  step "Checking that $UPDATE_FEED_URL is this site"
  live="$WORK/live-appcast.json"
  code=$(curl --proto '=https' --tlsv1.2 -sS --max-time 30 -o "$live" -w '%{http_code}' "$UPDATE_FEED_URL") \
    || die "couldn't reach $UPDATE_FEED_URL"
  if [[ -f "$SITE/updates/appcast.json" ]]; then
    [[ "$code" == 200 ]] && cmp -s "$live" "$SITE/updates/appcast.json" \
      || die "$UPDATE_FEED_URL (HTTP $code) doesn't serve Website/public/updates/appcast.json: deploy the site as it is first, or check UPDATE_FEED_URL"
  else
    # The first release: the address must be on this site, deployed, with no feed there yet. The site's js/config.js
    # sets window.YUMMYORANGE (window.DROPWHEEL on a site from before the rename).
    config_url="${UPDATE_FEED_URL%/updates/appcast.json}/js/config.js"
    curl --proto '=https' --tlsv1.2 -sS --max-time 30 -o "$WORK/live-config.js" "$config_url" \
      && grep -qE 'window\.(YUMMYORANGE|DROPWHEEL)' "$WORK/live-config.js" \
      || die "$config_url isn't YummyOrange's site: deploy Website/public first, or check UPDATE_FEED_URL"
    [[ "$code" == 404 ]] || die "$UPDATE_FEED_URL answered HTTP $code, but no release has been published yet"
  fi
fi

step "Publishing to ${DEST/#$ROOT\//}"
mkdir -p "$DEST/updates" "$DEST/downloads" "$DEST/js"
# The files the feed points at first, the feed and its signature last, so the folder never offers something it
# doesn't have.
cp "$STAGED/downloads/$ZIP_NAME" "$DEST/downloads/$ZIP_NAME"
cp "$STAGED/downloads/YummyOrange.dmg" "$DEST/downloads/YummyOrange.dmg"
cp "$STAGED/js/config.js" "$DEST/js/config.js"
cp "$STAGED/updates/appcast.json.sig" "$DEST/updates/appcast.json.sig"
cp "$STAGED/updates/appcast.json" "$DEST/updates/appcast.json"
print "  updates/appcast.json and appcast.json.sig"
print "  downloads/$ZIP_NAME ($LENGTH bytes, sha256 $SHA)"
print "  downloads/YummyOrange.dmg ($(stat -f %z "$DEST/downloads/YummyOrange.dmg") bytes)"
print "  js/config.js (version $VERSION, dmgURL downloads/YummyOrange.dmg, notarized $NOTARIZED)"
if (( DRY_RUN )); then
  print "\nDry run done: $DEST"
else
  print "\nYummyOrange $VERSION ($BUILD_NUMBER) is ready. Add its notes to Website/public/release-notes.html, then commit and push"
  print "Website/public; once Vercel has deployed it, installed copies find the update within six hours."
fi
