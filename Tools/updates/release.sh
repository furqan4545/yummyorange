#!/bin/zsh
# Makes a YummyOrange release and puts it in the website folder, ready to deploy (Vercel serves Website/public):
#
#   VERSION=1.0.1 BUILD_NUMBER=2 UPDATE_PRIVATE_KEY=~/.dropwheel/update-signing-key Tools/updates/release.sh
#
# Developer ID signing and notarization, one of two ways:
#   Xcode (SIGNING=cloud; the default when this Mac has no Developer ID identity of the pinned team): the team's
#     cloud-managed Developer ID certificate signs the app and Xcode's Apple Account sends it to Apple's notary service,
#     so this Mac needs no Developer ID key and no notarytool profile. It needs Xcode (XCODE_DEVELOPER_DIR, default the
#     selected Xcode, else /Applications/Xcode.app) signed in to the team's account, and this Mac unlocked while it runs:
#     Xcode reads its account only then. The disk image can't be signed without a Developer ID key, so it stays
#     unsigned and holds the notarized app with its ticket stapled; Gatekeeper checks that app when it is first opened.
#   This Mac (SIGNING=local; implied by SIGN_IDENTITY and NOTARY_PROFILE): SIGN_IDENTITY="Developer ID Application:
#     Your Name (TEAMID)" signs the app and the disk image, and NOTARY_PROFILE (a notarytool keychain profile, made with
#     xcrun notarytool store-credentials) notarizes both.
#
#   Tools/updates/release.sh --dry-run [--out <folder>]       everything on this Mac with the identity it has, throwaway
#                                                              update keys (never the release key), no notarization and
#                                                              no network, into a scratch folder
#   Tools/updates/release.sh --test-release [--out <folder>]  a real release in all Apple sees (Developer ID, Apple's
#                                                              notary service, Gatekeeper) but signed with throwaway
#                                                              update keys, into a scratch folder and never the website:
#                                                              a rehearsal (give it a build no copy has, such as 0)
#
# Tools/updates/release-identity pins the team (TEAM_ID), the update keys (UPDATE_PUBLIC_KEY) and, once known, the
# feed's address (FEED_URL). A real release refuses another team, another key, or no feed address; and it reads the
# release already published (its ZIP in Website/public/downloads) to check that installed copies trust this release's
# team and key, so they take it.
#
# Steps: build.sh with the hardened runtime; Developer ID signing and notarization (above), then the checks Gatekeeper
# and installed copies make (Developer ID leaf and intermediate, the pinned team, com.yummyorange.app, the hardened
# runtime, a secure timestamp, the stapled ticket, spctl's "Notarized Developer ID"); zip it with ditto -c -k
# --keepParent (the update); build YummyOrange.dmg with an Applications link (signed, notarized and stapled too on this
# Mac's identity) and check the app in it as a download would arrive; sign the ZIP and then the feed with the update
# key; check the result with YummyOrange's own updater code as an installed copy would (the trusted team and keys,
# Developer ID, notarized, Gatekeeper); check that the live site at the feed's address is this one; then write
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
# once on the terminal when the key is encrypted and this isn't set), NOTARY_TIMEOUT_MINUTES (how long to wait for
# Apple's notary service with Xcode; default 60).
set -euo pipefail
ROOT="${0:A:h:h:h}"
cd "$ROOT"

die() { print -u2 -- "release.sh: $*"; exit 1 }
step() { print -- "\n==> $*" }
minutes() { print -- "$(( $1 / 60 )) min $(( $1 % 60 )) s" }

DRY_RUN=0
TEST_RELEASE=0
OUT=""
while (( $# )); do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --test-release) TEST_RELEASE=1 ;;
    --out) (( $# >= 2 )) || die "--out needs a folder"; OUT="$2"; shift ;;
    -h|--help) awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; exit 0 ;;
    *) die "unknown option $1 (see --help)" ;;
  esac
  shift
done
(( DRY_RUN && TEST_RELEASE )) && die "--dry-run and --test-release don't go together"
# A dry run and a test release sign with throwaway update keys and write into a scratch folder; every run but a dry
# run is signed with Developer ID and notarized by Apple.
THROWAWAY=$(( DRY_RUN || TEST_RELEASE ))
NOTARIZE=$(( ! DRY_RUN ))
MODE_OPTION="" MODE_NAME=""
(( DRY_RUN )) && MODE_OPTION="--dry-run" MODE_NAME="dry run"
(( TEST_RELEASE )) && MODE_OPTION="--test-release" MODE_NAME="test release"

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
SIGNING="${SIGNING:-}"
(( DRY_RUN )) && [[ -n "$SIGNING" ]] && die "--dry-run signs with this Mac's own identity and notarizes nothing: unset SIGNING"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
NOTARY_TIMEOUT_MINUTES="${NOTARY_TIMEOUT_MINUTES:-120}"
[[ "$NOTARY_TIMEOUT_MINUTES" =~ '^[0-9]{1,4}$' ]] && (( NOTARY_TIMEOUT_MINUTES > 0 )) \
  || die "NOTARY_TIMEOUT_MINUTES must be a number of minutes (got '$NOTARY_TIMEOUT_MINUTES')"
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
MOUNTED=""
# xcodebuild writes its distribution logs, which hold the Apple Account's session tokens, into this user's own
# temporary folder whatever TMPDIR says (Foundation ignores it): each is deleted as soon as its call ends, and any left by
# a release cut short are swept up on the way out.
XCODE_USER_TMP=$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || true)
XCODE_USER_TMP="${XCODE_USER_TMP%/}"
: > "$WORK/.started"
cleanup() {
  [[ -n "$MOUNTED" ]] && hdiutil detach -quiet -force "$MOUNTED" 2>/dev/null
  if [[ -n "$XCODE_USER_TMP" && -d "$XCODE_USER_TMP" && -f "$WORK/.started" ]]; then
    find "$XCODE_USER_TMP" -maxdepth 1 \( -name 'YummyOrange_*.xcdistributionlogs' -o -name 'XcodeDistPipeline.~~~*' \) \
      -newer "$WORK/.started" -exec rm -rf {} + 2>/dev/null
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# Everything that can be refused without the keychain, the network or the key's contents comes first.
if (( THROWAWAY )); then
  # A dry run or a test release signs with throwaway keys only: its output looks like a release, so the release key
  # never signs one.
  [[ -z "$UPDATE_PRIVATE_KEY" && -z "$UPDATE_PUBLIC_KEY" ]] \
    || die "$MODE_OPTION signs with throwaway update keys only: unset UPDATE_PRIVATE_KEY and UPDATE_PUBLIC_KEY"
  UPDATE_FEED_URL="${UPDATE_FEED_URL:-${PINNED_FEED:-https://yummyorange.com/updates/appcast.json}}"
  [[ "$UPDATE_FEED_URL" == https://* ]] || die "UPDATE_FEED_URL must be an https:// address"
  if [[ -n "$OUT" ]]; then
    OUT="${OUT:A}"
    { [[ "$OUT/" == "$SITE/"* || "$SITE/" == "$OUT/"* ]] || is_inside "$OUT" "$SITE" || is_inside "$OUT/public" "$SITE"; } \
      && die "--out must not be the website folder or around it"
  fi
else
  [[ -z "$OUT" ]] || die "--out is for --dry-run and --test-release: a release goes to Website/public"
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
fi
if (( NOTARIZE )); then
  [[ "$PINNED_TEAM" =~ '^[A-Z0-9]{10}$' ]] || die "Tools/updates/release-identity must pin TEAM_ID, the Developer ID team (10 letters and digits)"
  # Who signs and notarizes: this Mac's Developer ID identity with notarytool, or Xcode with the team's cloud-managed
  # certificate and Apple Account.
  if [[ -z "$SIGNING" ]]; then
    if [[ -n "$SIGN_IDENTITY" || -n "$NOTARY_PROFILE" ]]; then
      SIGNING=local
    elif local_ids=$( { security find-identity -v -p codesigning 2>/dev/null || true; } ) \
         && [[ "$local_ids" == *"\"Developer ID Application: "*"($PINNED_TEAM)\""* ]]; then
      die "this Mac has a Developer ID Application identity of team $PINNED_TEAM: set SIGN_IDENTITY and NOTARY_PROFILE to sign and notarize with it here, or SIGNING=cloud to have Xcode do both"
    else
      SIGNING=cloud
    fi
  fi
  case "$SIGNING" in
    local)
      [[ "$SIGN_IDENTITY" == "Developer ID Application: "* ]] \
        || die "SIGN_IDENTITY must be a Developer ID Application identity (got '${SIGN_IDENTITY:-nothing}'); releases are signed with Developer ID"
      [[ "$SIGN_IDENTITY" == *"($PINNED_TEAM)" ]] \
        || die "SIGN_IDENTITY '$SIGN_IDENTITY' isn't of the team $PINNED_TEAM pinned in Tools/updates/release-identity: installed copies would refuse its release"
      [[ -n "$NOTARY_PROFILE" ]] || die "set NOTARY_PROFILE to a notarytool keychain profile (xcrun notarytool store-credentials)"
      ;;
    cloud)
      [[ -z "$SIGN_IDENTITY" && -z "$NOTARY_PROFILE" ]] \
        || die "SIGNING=cloud signs and notarizes with Xcode: unset SIGN_IDENTITY and NOTARY_PROFILE, or use SIGNING=local"
      ;;
    *) die "SIGNING must be cloud (Xcode) or local (SIGN_IDENTITY and NOTARY_PROFILE), got '$SIGNING'" ;;
  esac
fi
if (( ! THROWAWAY )); then
  [[ -n "$PINNED_KEYS" ]] \
    || die "Tools/updates/release-identity pins no UPDATE_PUBLIC_KEY yet: make the key with make-update-keys.swift and put its public half there"
  UPDATE_PUBLIC_KEY=$(normalize_keys "${UPDATE_PUBLIC_KEY:-$PINNED_KEYS}")
  [[ "$UPDATE_PUBLIC_KEY" == "$PINNED_KEYS" ]] \
    || die "UPDATE_PUBLIC_KEY isn't the update key pinned in Tools/updates/release-identity ($PINNED_KEYS)"
  [[ -n "$UPDATE_PRIVATE_KEY" ]] || die "set UPDATE_PRIVATE_KEY to the private key file"
  UPDATE_PRIVATE_KEY="${UPDATE_PRIVATE_KEY/#\~/$HOME}"
  # Never where it would be committed, published or synced sooner or later.
  for place in "$ROOT" "$HOME/Desktop" "$HOME/Documents" "$HOME/Library/Mobile Documents"; do
    is_inside "$UPDATE_PRIVATE_KEY" "$place" \
      && die "the private key must not be inside $place (committed, published or synced sooner or later): keep it in ~/.dropwheel, or off this Mac"
  done
  [[ -f "$UPDATE_PRIVATE_KEY" ]] || die "no private key at $UPDATE_PRIVATE_KEY"
fi

# The release already published: installed copies trust its team and its keys, so this one must be made with them. A
# test release publishes nothing, so the published build doesn't bound it.
PUBLISHED_KEYS=""
PUBLISHED_BUILD=""
if [[ -f "$SITE/updates/appcast.json" ]]; then
  PUBLISHED_BUILD=$(plutil -extract build raw -o - "$SITE/updates/appcast.json" 2>/dev/null || true)
  if (( ! TEST_RELEASE )) && [[ -n "$PUBLISHED_BUILD" ]] && ! version_gt "$BUILD_NUMBER" "$PUBLISHED_BUILD"; then
    die "BUILD_NUMBER $BUILD_NUMBER isn't higher than the published build $PUBLISHED_BUILD"
  fi
  if (( ! THROWAWAY )); then
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
  STAMP=none
  NOTARIZED=false
elif [[ "$SIGNING" == local ]]; then
  print -r -- "$identities" | grep -qF "\"$SIGN_IDENTITY\"" \
    || die "'$SIGN_IDENTITY' isn't in your keychain (security find-identity -v -p codesigning). Install the Developer ID Application certificate first."
  xcrun --find notarytool >/dev/null 2>&1 && xcrun --find stapler >/dev/null 2>&1 || die "notarytool and stapler are missing (install Xcode or its command line tools)"
  step "Checking the notarytool profile"
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null || die "the notarytool profile '$NOTARY_PROFILE' doesn't work"
  STAMP=""
  NOTARIZED=true
else
  # Xcode signs (cloud-managed Developer ID) and notarizes (its Apple Account). build.sh signs ad hoc with the hardened
  # runtime, which Xcode keeps (--preserve-metadata ... runtime) when it puts its Developer ID signature on.
  XCODE_DEV="${XCODE_DEVELOPER_DIR:-}"
  if [[ -z "$XCODE_DEV" ]]; then
    XCODE_DEV=$(xcode-select -p 2>/dev/null || true)
    [[ -x "$XCODE_DEV/usr/bin/xcodebuild" && "$XCODE_DEV" == */Contents/Developer ]] || XCODE_DEV=/Applications/Xcode.app/Contents/Developer
  fi
  [[ -x "$XCODE_DEV/usr/bin/xcodebuild" ]] \
    || die "Xcode isn't at ${XCODE_DEV%/Contents/Developer}: install it, sign in to the team's account, or set XCODE_DEVELOPER_DIR (…/Xcode.app/Contents/Developer)"
  xcrun --find stapler >/dev/null 2>&1 || die "stapler is missing (install Xcode or its command line tools)"
  step "Checking Xcode"
  print "  $(DEVELOPER_DIR="$XCODE_DEV" "$XCODE_DEV/usr/bin/xcodebuild" -version 2>/dev/null | tr '\n' ' ')(${XCODE_DEV%/Contents/Developer})"
  # Xcode keeps its Apple Account where it can be read only while this Mac is unlocked: locked, it signs and
  # uploads nothing ("No Accounts").
  if ioreg -n Root -d1 -a 2>/dev/null | grep -A1 CGSSessionScreenIsLocked | grep -q '<true/>'; then
    die "this Mac's screen is locked, and Xcode can reach its Apple Account only while it is unlocked: unlock it and run release.sh again (keep it unlocked until Apple has notarized the app)"
  fi
  # Keep the display awake while this runs, so an idle lock doesn't cut Xcode off from the account (a lock by hand or
  # closing the lid still does).
  caffeinate -d -i -w $$ &!
  STAMP=none
  NOTARIZED=true
fi
if (( THROWAWAY )); then
  UPDATE_PRIVATE_KEY="$WORK/keys/update-signing-key"
  UPDATE_PUBLIC_KEY=$(swift Tools/updates/make-update-keys.swift --no-passphrase "$UPDATE_PRIVATE_KEY" 2>/dev/null) \
    || die "couldn't make throwaway update keys"
  print "Throwaway update keys for this $MODE_NAME (public key $UPDATE_PUBLIC_KEY)"
  if [[ -z "$OUT" ]]; then OUT=$(mktemp -d "${TMPDIR:-/tmp}/yummyorange-${MODE_OPTION#--}.XXXXXX"); OUT="${OUT:A}"; fi
  DEST="$OUT/public"
  TRUSTED_KEYS="$UPDATE_PUBLIC_KEY"
else
  if [[ "$(head -1 "$UPDATE_PRIVATE_KEY")" == "dropwheel-update-key 2" && -z "${UPDATE_KEY_PASSPHRASE:-}" ]]; then
    read -rs "UPDATE_KEY_PASSPHRASE?Passphrase for $UPDATE_PRIVATE_KEY: " < /dev/tty || die "no passphrase for the encrypted private key"
    print
  fi
  export UPDATE_KEY_PASSPHRASE="${UPDATE_KEY_PASSPHRASE:-}"
  DEST="$SITE"
  # What the copies out there trust: the published release's keys, or (for the first release) the pinned ones.
  TRUSTED_KEYS="${PUBLISHED_KEYS:-$PINNED_KEYS}"
fi

step "Checking that the private key is one of the update keys installed copies trust"
print -n "YummyOrange" > "$WORK/probe"
swift Tools/updates/sign-update.swift --public-key "$UPDATE_PUBLIC_KEY" "$UPDATE_PRIVATE_KEY" "$WORK/probe" >/dev/null \
  || die "the private key isn't one of UPDATE_PUBLIC_KEY's keys (or its passphrase is wrong)"
swift Tools/updates/sign-update.swift --public-key "$TRUSTED_KEYS" "$UPDATE_PRIVATE_KEY" "$WORK/probe" >/dev/null \
  || die "installed copies don't trust this private key (they trust $TRUSTED_KEYS)"

RELEASE_STARTED=$SECONDS
step "Building YummyOrange $VERSION ($BUILD_NUMBER)"
BUILD_IDENTITY="$SIGN_IDENTITY"
[[ "${SIGNING:-}" == cloud ]] && BUILD_IDENTITY=-
VERSION="$VERSION" BUILD_NUMBER="$BUILD_NUMBER" UPDATE_FEED_URL="$UPDATE_FEED_URL" UPDATE_PUBLIC_KEY="$UPDATE_PUBLIC_KEY" \
  SIGN_IDENTITY="$BUILD_IDENTITY" SIGN_TIMESTAMP="$STAMP" BUILD_DIR="$WORK/build" ALLOW_UNPINNED_UPDATE_KEY="$THROWAWAY" ./build.sh
APP="$WORK/build/YummyOrange.app"
xattr -cr "$APP"

# The Info.plist values this release must carry, in the app at $1.
check_info() {
  [[ "$(plutil -extract CFBundleIdentifier raw -o - "$1/Contents/Info.plist")" == com.yummyorange.app ]] || die "${1:t} isn't com.yummyorange.app"
  [[ "$(plutil -extract CFBundleVersion raw -o - "$1/Contents/Info.plist")" == "$BUILD_NUMBER" ]] || die "${1:t} has the wrong build number"
  [[ "$(plutil -extract CFBundleShortVersionString raw -o - "$1/Contents/Info.plist")" == "$VERSION" ]] || die "${1:t} has the wrong version"
  [[ "$(plutil -extract DWUpdatePublicKey raw -o - "$1/Contents/Info.plist")" == "$UPDATE_PUBLIC_KEY" ]] || die "${1:t} doesn't carry UPDATE_PUBLIC_KEY"
  [[ "$(plutil -extract DWUpdateFeedURL raw -o - "$1/Contents/Info.plist")" == "$UPDATE_FEED_URL" ]] || die "${1:t} doesn't carry UPDATE_FEED_URL"
}

step "Checking the app's signature and Info.plist"
codesign --verify --deep --strict --verbose=2 "$APP"
details=$(codesign -dvvv "$APP" 2>&1)
check_info "$APP"
TEAM=$(print -r -- "$details" | awk -F= '/^TeamIdentifier=/{print $2; exit}')
[[ "$TEAM" == "not set" ]] && TEAM=""
if [[ -n "$BUILD_IDENTITY" ]]; then
  print -r -- "$details" | grep -q 'flags=.*runtime' || die "the app isn't signed with the hardened runtime"
fi
if [[ -n "$SIGN_IDENTITY" ]]; then
  [[ -n "$TEAM" ]] || die "the app's signature has no team"
fi
if [[ "${SIGNING:-}" == local ]]; then
  print -r -- "$details" | grep -q '^Authority=Developer ID Application:' || die "the app isn't signed with Developer ID"
  print -r -- "$details" | grep -q '^Timestamp=' || die "the app's signature has no secure timestamp"
  [[ "$TEAM" == "$PINNED_TEAM" ]] || die "the app is signed by team $TEAM, not the pinned $PINNED_TEAM"
elif [[ "${SIGNING:-}" == cloud ]]; then
  print -r -- "$details" | grep -q '^Signature=adhoc' || die "the app for Xcode should be signed ad hoc"
  print -r -- "$details" | grep -q '^Identifier=com.yummyorange.app$' || die "the app's signature isn't for com.yummyorange.app"
  print "Ad hoc with the hardened runtime: Xcode signs it with Developer ID next"
fi
print -r -- "$details" | grep -E '^(Identifier|Authority|TeamIdentifier|Timestamp|CodeDirectory|Signature)' || true
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

# xcodebuild from Xcode: xcode <log> <arguments…>. Its output goes to <log>; the distribution-log bundle it reports
# making (it holds the Apple Account's session tokens) is deleted right away, if it is in this user's temporary folder.
xcode() {
  local log=$1 rc=0 b
  shift
  DEVELOPER_DIR="$XCODE_DEV" "$XCODE_DEV/usr/bin/xcodebuild" "$@" > "$log" 2>&1 || rc=$?
  for b in ${(f)"$(sed -nE 's/.*Created bundle at path "([^"]+\.xcdistributionlogs)".*/\1/p' "$log")"}; do
    [[ -n "$b" && -n "$XCODE_USER_TMP" && "${b:A}" == "${XCODE_USER_TMP:A}"/*.xcdistributionlogs ]] && rm -rf -- "$b"
  done
  return $rc
}
# What xcodebuild said, without its log-bundle chatter.
said() { grep -v -e 'xcdistributionlogs' -e '^[[:space:]]*$' "$1" | sed 's/^/  /' || true }

# Xcode signs $APP with the team's cloud-managed Developer ID certificate and uploads it to Apple's notary service
# (xcodebuild -exportArchive, destination upload, on an archive made here), then hands back the notarized app with its
# ticket stapled once Apple has accepted it (xcodebuild -exportNotarizedApp, asked every 30 s). Sets APP to it.
xcode_sign_and_notarize() {
  local archive="$WORK/YummyOrange.xcarchive" started=$SECONDS deadline=$(( SECONDS + NOTARY_TIMEOUT_MINUTES * 60 ))
  local answer last="" waited
  mkdir -p "$archive/Products/Applications"
  ditto "$APP" "$archive/Products/Applications/YummyOrange.app"
  cat > "$archive/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>ApplicationProperties</key>
  <dict>
    <key>ApplicationPath</key><string>Applications/YummyOrange.app</string>
    <key>CFBundleIdentifier</key><string>com.yummyorange.app</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>SigningIdentity</key><string>-</string>
    <key>Team</key><string>$PINNED_TEAM</string>
  </dict>
  <key>ArchiveVersion</key><integer>2</integer>
  <key>CreationDate</key><date>$(date -u +%Y-%m-%dT%H:%M:%SZ)</date>
  <key>Name</key><string>YummyOrange</string>
  <key>SchemeName</key><string>YummyOrange</string>
</dict>
</plist>
PLIST
  cat > "$WORK/upload-options.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>$PINNED_TEAM</string>
  <key>destination</key><string>upload</string>
</dict>
</plist>
PLIST
  plutil -lint -s "$archive/Info.plist" "$WORK/upload-options.plist" || die "couldn't write the archive for Xcode"
  print "Xcode signs the app with team $PINNED_TEAM's cloud-managed Developer ID certificate and uploads it to Apple's notary service"
  if ! xcode "$WORK/upload.log" -exportArchive -archivePath "$archive" -exportOptionsPlist "$WORK/upload-options.plist" \
       -exportPath "$WORK/upload" -allowProvisioningUpdates; then
    said "$WORK/upload.log" >&2
    if grep -qE 'No Accounts|No signing certificate|missing Xcode-Username' "$WORK/upload.log"; then
      die "Xcode couldn't use its Apple Account to sign or upload. Keep this Mac unlocked while release.sh runs (Xcode reads the account only then), check Xcode › Settings › Accounts shows the team's account signed in (sign in again if it asks), then run release.sh again. Nothing was published."
    fi
    die "Xcode couldn't sign and upload the app, so nothing was published"
  fi
  said "$WORK/upload.log"
  print "Signed and uploaded in $(minutes $(( SECONDS - started ))). Waiting for Apple's notary service (asking every 30 s, for up to $NOTARY_TIMEOUT_MINUTES minutes)"
  while true; do
    rm -rf "$WORK/notarized"
    if xcode "$WORK/poll.log" -exportNotarizedApp -archivePath "$archive" -exportPath "$WORK/notarized"; then
      [[ -d "$WORK/notarized/YummyOrange.app" ]] && break
      said "$WORK/poll.log" >&2
      die "Xcode exported the notarized app, but no YummyOrange.app ($(ls "$WORK/notarized" 2>/dev/null | tr '\n' ' '))"
    fi
    answer=$(grep -m1 -E '^(error|warning|note):' "$WORK/poll.log" | sed -E 's/^(error|warning|note): *//' || true)
    [[ -n "$answer" ]] || answer=$(grep -v -e xcdistributionlogs -e '^[[:space:]]*$' -e '^\*\*' "$WORK/poll.log" | tail -1 || true)
    waited=$(minutes $(( SECONDS - started )))
    if grep -qiE 'hasn.t been uploaded' "$WORK/poll.log"; then
      said "$WORK/poll.log" >&2
      die "Xcode uploaded the app but doesn't find that upload in the archive, so it can't hand back the notarized app; nothing was published"
    fi
    if grep -qiE 'notarization failed|was not notarized|rejected|status: *invalid' "$WORK/poll.log"; then
      said "$WORK/poll.log" >&2
      local kept=$(mktemp -d "${TMPDIR:-/tmp}/yummyorange-notarization.XXXXXX")
      find "$archive" -iname '*notarization*log*.json' -exec cp {} "$kept/" \; 2>/dev/null || true
      [[ -n "$(ls -A "$kept")" ]] && print -u2 "The notary service's log: $kept"
      die "Apple's notary service didn't accept the app ($waited after starting), so nothing was published"
    fi
    if grep -qE 'No Accounts|missing Xcode-Username' "$WORK/poll.log"; then
      answer="Xcode can't reach its Apple Account (is this Mac locked?): still waiting"
    fi
    if [[ "$answer" != "$last" ]]; then
      print -r -- "  [$waited] $answer"
      last="$answer"
    fi
    if (( SECONDS >= deadline )); then
      # The archive records the upload: keep it, so the notarized app can still be fetched once Apple is done.
      local kept=$(mktemp -d "${TMPDIR:-/tmp}/yummyorange-notarization.XXXXXX")
      ditto "$archive" "$kept/YummyOrange.xcarchive"
      die "Apple hadn't finished notarizing after $NOTARY_TIMEOUT_MINUTES minutes (last answer: $last). Nothing was published. The upload is kept in $kept: once Apple is done, run release.sh again (it uploads afresh), or fetch this upload's app with: DEVELOPER_DIR=$XCODE_DEV xcodebuild -exportNotarizedApp -archivePath $kept/YummyOrange.xcarchive -exportPath $kept/notarized"
    fi
    sleep 30
  done
  said "$WORK/poll.log"
  print "Apple notarized it: $(minutes $(( SECONDS - started ))) from Xcode's signing to the stapled app"
  APP="$WORK/notarized/YummyOrange.app"
}

# What Gatekeeper and installed copies require of the app at $1: Developer ID (leaf and intermediate) of the pinned
# team, com.yummyorange.app, the hardened runtime, a secure timestamp, the stapled ticket, and spctl's approval as
# notarized. Prints what it checked.
verify_notarized() {
  local app=$1 d requirement out
  out=$(codesign --verify --deep --strict --verbose=2 "$app" 2>&1) || { print -u2 -r -- "$out"; die "${app:t}'s signature doesn't verify"; }
  print -r -- "$out" | sed 's/^/  /'
  check_info "$app"
  d=$(codesign -dvvv "$app" 2>&1)
  print -r -- "$d" | grep -q '^Identifier=com.yummyorange.app$' || die "${app:t} isn't signed as com.yummyorange.app"
  print -r -- "$d" | grep -qx "TeamIdentifier=$PINNED_TEAM" || die "${app:t} isn't signed by the pinned team $PINNED_TEAM"
  print -r -- "$d" | grep -q 'flags=.*runtime' || die "${app:t} isn't signed with the hardened runtime"
  print -r -- "$d" | grep -q "^Authority=Developer ID Application: .*($PINNED_TEAM)\$" || die "${app:t} isn't signed with a Developer ID Application certificate"
  print -r -- "$d" | grep -qx 'Authority=Developer ID Certification Authority' || die "${app:t}'s certificate isn't issued by the Developer ID Certification Authority"
  print -r -- "$d" | grep -q '^Timestamp=' || die "${app:t}'s signature has no secure timestamp"
  # The Developer ID markers installed copies require (leaf 1.2.840.113635.100.6.1.13, intermediate 6.2.6).
  requirement="=anchor apple generic and identifier \"com.yummyorange.app\" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"$PINNED_TEAM\""
  codesign --verify --strict -R "$requirement" "$app" || die "${app:t} doesn't meet the Developer ID requirement for team $PINNED_TEAM"
  print -r -- "$d" | grep -E '^(Identifier=|Authority=|TeamIdentifier=|Timestamp=|CodeDirectory |CDHash=)' | sed 's/^/  /'
  print "  Developer ID requirement (leaf and intermediate markers, team $PINNED_TEAM): satisfied"
  out=$(xcrun stapler validate "$app" 2>&1) || { print -u2 -r -- "$out"; die "${app:t}'s stapled ticket doesn't validate"; }
  print -r -- "$out" | sed 's/^/  /'
  spctl --assess --type execute --verbose=4 "$app" > "$WORK/spctl.txt" 2>&1 || true
  sed 's/^/  spctl: /' "$WORK/spctl.txt"
  grep -q ': accepted$' "$WORK/spctl.txt" && grep -qx 'source=Notarized Developer ID' "$WORK/spctl.txt" \
    || die "Gatekeeper doesn't accept ${app:t} as notarized"
  if command -v syspolicy_check >/dev/null 2>&1; then
    out=$(syspolicy_check distribution "$app" 2>&1) || { print -u2 -r -- "$out"; die "syspolicy_check says ${app:t} isn't ready for distribution"; }
    print -r -- "$out" | grep -v '^[[:space:]]*$' | sed 's/^/  syspolicy_check: /'
  fi
}

if (( DRY_RUN )); then
  step "Notarizing and stapling the app: skipped (dry run)"
elif [[ "$SIGNING" == local ]]; then
  step "Notarizing and stapling the app"
  notarize_started=$SECONDS
  ditto -c -k --keepParent "$APP" "$WORK/notarize-YummyOrange.zip"
  notarize "$WORK/notarize-YummyOrange.zip"
  xcrun stapler staple "$APP" || die "stapling the app failed"
  print "Notarized and stapled in $(minutes $(( SECONDS - notarize_started )))"
else
  step "Signing with Developer ID and notarizing with Xcode"
  xcode_sign_and_notarize
fi
if (( NOTARIZE )); then
  step "Checking the notarized app as Gatekeeper and installed copies will"
  verify_notarized "$APP"
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
if [[ "${SIGNING:-}" == cloud ]]; then
  print "Not signed: a disk image is signed only with a Developer ID key on this Mac. It holds the notarized app with its ticket stapled."
elif [[ -n "$SIGN_IDENTITY" ]]; then
  if [[ "$STAMP" == none ]]; then
    codesign --force --timestamp=none --sign "$SIGN_IDENTITY" "$DMG"
  else
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
  fi
  codesign --verify --strict "$DMG"
fi
if (( DRY_RUN )); then
  print "Notarizing and stapling the disk image: skipped (dry run)"
elif [[ "$SIGNING" == local ]]; then
  notarize "$DMG"
  xcrun stapler staple "$DMG" || die "stapling the disk image failed"
  xcrun stapler validate "$DMG" || die "the disk image's stapled ticket doesn't validate"
  spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG" > "$WORK/spctl-dmg.txt" 2>&1 || true
  cat "$WORK/spctl-dmg.txt"
  grep -q "source=Notarized Developer ID" "$WORK/spctl-dmg.txt" || die "Gatekeeper doesn't accept the disk image as notarized"
fi

# The disk image as a download arrives: a copy marked as downloaded (quarantined), mounted read-only (its files are
# quarantined too). The app in it must be the one checked above, and Gatekeeper must accept it as notarized there.
step "Checking the app in the disk image as a download would arrive"
cp "$DMG" "$WORK/downloaded.dmg"
xattr -w com.apple.quarantine "0083;$(printf %x "$(date +%s)");release.sh;$(uuidgen)" "$WORK/downloaded.dmg"
spctl --assess --type open --context context:primary-signature --verbose=4 "$WORK/downloaded.dmg" 2>&1 | sed 's/^/  the disk image itself: /' || true
[[ "${SIGNING:-}" == cloud ]] && print "  (unsigned, so Gatekeeper has no verdict on the image itself: it judges the app in it when it is opened, below)"
mkdir -p "$WORK/mnt"
if diskutil image attach --help >/dev/null 2>&1; then
  diskutil image attach --readOnly --nobrowse --mountPoint "$WORK/mnt" "$WORK/downloaded.dmg" >/dev/null || die "the disk image doesn't mount"
else
  hdiutil attach -quiet -readonly -nobrowse -noautoopen -mountpoint "$WORK/mnt" "$WORK/downloaded.dmg" || die "the disk image doesn't mount"
fi
MOUNTED="$WORK/mnt"
[[ -d "$WORK/mnt/YummyOrange.app" && "$(readlink "$WORK/mnt/Applications")" == /Applications ]] \
  || die "the disk image doesn't hold YummyOrange.app and the Applications link"
mount | grep -F " on ${WORK:A}/mnt (" | grep -q quarantine && print "  mounted with its files quarantined, as a downloaded image is"
cdhash() { codesign -dvvv "$1" 2>&1 | awk -F= '/^CDHash=/{print $2; exit}' }
[[ "$(cdhash "$WORK/mnt/YummyOrange.app")" == "$(cdhash "$APP")" ]] && diff -rq "$WORK/mnt/YummyOrange.app" "$APP" >/dev/null \
  || die "the app in the disk image isn't the one checked above"
print "  the app in it is the one checked above (CDHash $(cdhash "$APP"))"
if (( NOTARIZE )); then
  xcrun stapler validate "$WORK/mnt/YummyOrange.app" >/dev/null || die "the app in the disk image has no valid stapled ticket"
  spctl --assess --type execute --verbose=4 "$WORK/mnt/YummyOrange.app" > "$WORK/spctl-mounted.txt" 2>&1 || true
  sed 's/^/  app in the disk image: /' "$WORK/spctl-mounted.txt"
  grep -q ': accepted$' "$WORK/spctl-mounted.txt" && grep -qx 'source=Notarized Developer ID' "$WORK/spctl-mounted.txt" \
    || die "Gatekeeper doesn't accept the app in the disk image as notarized"
fi
hdiutil detach -quiet "$WORK/mnt" || hdiutil detach -quiet -force "$WORK/mnt"
MOUNTED=""

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
developer_id=0; (( NOTARIZE )) && developer_id=1
# The build installed copies have: the published one (or none yet). A test release is meant for no installed copy.
installed="${PUBLISHED_BUILD:-0}"
(( TEST_RELEASE )) && installed=none
check=$(DW_RELEASE_PUBLIC_KEY="$TRUSTED_KEYS" DW_RELEASE_FEED_URL="$UPDATE_FEED_URL" DW_RELEASE_TEAM="$TRUSTED_TEAM" \
  DW_RELEASE_ALLOW_ADHOC=$adhoc DW_RELEASE_DEVELOPER_ID=$developer_id DW_RELEASE_INSTALLED_BUILD="$installed" \
  .build/debug/DropWheel --selftest "updater-release:$STAGED" 2>&1) || { print -u2 -- "$check"; die "the app's updater refuses this release"; }
print -r -- "$check"
[[ "$check" == PASS* ]] || die "the app's updater refuses this release"

if (( ! THROWAWAY )); then
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
elif (( TEST_RELEASE )); then
  print "\nTest release done in $(minutes $(( SECONDS - RELEASE_STARTED ))): $DEST"
  print "Signed with Developer ID and notarized by Apple, but its update keys are throwaway ones: never publish it."
else
  print "\nYummyOrange $VERSION ($BUILD_NUMBER) is ready ($(minutes $(( SECONDS - RELEASE_STARTED )))). Add its notes to"
  print "Website/public/release-notes.html, then commit and push Website/public; once Vercel has deployed it, installed copies"
  print "find the update within an hour."
fi
