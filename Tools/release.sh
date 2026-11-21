#!/bin/zsh
# Builds, notarizes, signs for Sparkle, and publishes a Cosign release.
#
#   Tools/release.sh 1.0.1 [--draft] [--skip-tests]
#
# Uses Xcode's signed-in Apple ID for Developer ID notarization and the Sparkle Ed25519 key in
# macOS Keychain — zero credentials or private keys are stored in the repository.
set -euo pipefail

VERSION="${1:?usage: Tools/release.sh <version> [--draft] [--skip-tests]}"
shift
DRAFT=0; SKIP_TESTS=0
for arg in "$@"; do
  case "$arg" in
    --draft) DRAFT=1 ;;
    --skip-tests) SKIP_TESTS=1 ;;
    *) echo "Unknown option $arg"; exit 2 ;;
  esac
done
[[ "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { echo "Version must look like 1.2.3"; exit 2; }

ROOT="${0:A:h:h}"
cd "$ROOT"
REPO=newtro/Cosign
TEAM=232A77467G
SPARKLE_BIN="$ROOT/build/SourcePackages/artifacts/sparkle/Sparkle/bin"
OUT="$ROOT/build/release/$VERSION"
TAG="v$VERSION"

step() { print -P "%B==> $1%b" }

# 1. Checks
step "Checking the repository"
[[ "$(git branch --show-current)" == main ]] || { echo "Release from main."; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "Commit or stash changes first."; exit 1; }
git fetch -q origin
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || { echo "main isn't in sync with origin."; exit 1; }
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then echo "$TAG already exists."; exit 1; fi
if (( ! DRAFT )); then
  [[ "$(gh repo view $REPO --json visibility -q .visibility)" == PUBLIC ]] || {
    echo "$REPO is private, so installed copies can't download updates. Use --draft, or make it public."; exit 1; }
fi
[[ -x "$SPARKLE_BIN/sign_update" ]] || { echo "Build once (make build) so Sparkle's tools are downloaded."; exit 1; }
if (( ! SKIP_TESTS )); then
  step "Running tests"
  make test >/dev/null || { echo "Tests failed; run make test to see why."; exit 1; }
fi
BUILD_NUMBER="$(git rev-list --count HEAD)"

# 2. Archive
step "Archiving $VERSION ($BUILD_NUMBER)"
rm -rf "$OUT"; mkdir -p "$OUT"
xcodegen generate -q
xcodebuild -project Cosign.xcodeproj -scheme Cosign -configuration Release \
  -derivedDataPath build -archivePath "$OUT/Cosign.xcarchive" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  archive >"$OUT/archive.log" 2>&1 || { tail -20 "$OUT/archive.log"; exit 1; }

# 3. Export for Developer ID and upload to Apple notary service
step "Uploading to Apple for notarization"
cat >"$OUT/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>developer-id</string>
<key>destination</key><string>upload</string>
<key>signingStyle</key><string>automatic</string>
<key>teamID</key><string>$TEAM</string>
</dict></plist>
EOF
xcodebuild -exportArchive -archivePath "$OUT/Cosign.xcarchive" -exportPath "$OUT/upload" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" -allowProvisioningUpdates >"$OUT/upload.log" 2>&1 \
  || { tail -20 "$OUT/upload.log"; exit 1; }

# 4. Wait for notarization
step "Waiting for notarization"
for attempt in {1..180}; do
  if xcodebuild -exportNotarizedApp -archivePath "$OUT/Cosign.xcarchive" -exportPath "$OUT/notarized" \
       >"$OUT/notarize.log" 2>&1; then
    break
  fi
  grep -q "processing" "$OUT/notarize.log" || { tail -20 "$OUT/notarize.log"; echo "Notarization failed."; exit 1; }
  (( attempt % 5 == 0 )) && echo "   still processing ($(( attempt )) min)"
  sleep 60
done
APP="$OUT/notarized/Cosign.app"
[[ -d "$APP" ]] || { echo "Notarization didn't finish within 3 hours; rerun later."; exit 1; }
spctl -a -t exec "$APP" || { echo "Gatekeeper rejected the app."; exit 1; }
xcrun stapler validate "$APP" >/dev/null || { echo "The notarization ticket isn't stapled."; exit 1; }

# 5. Package, sign update, publish
step "Packaging"
ZIP="$OUT/Cosign-$VERSION.zip"
DMG="$OUT/Cosign-$VERSION.dmg"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
mkdir -p "$OUT/dmg"; ditto "$APP" "$OUT/dmg/Cosign.app"; ln -s /Applications "$OUT/dmg/Applications"
hdiutil create -quiet -volname "Cosign $VERSION" -srcfolder "$OUT/dmg" -format UDZO "$DMG"

step "Signing the update and adding it to appcast.xml"
SIGNATURE="$("$SPARKLE_BIN/sign_update" "$ZIP")"
MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")"
python3 Tools/appcast.py appcast.xml \
  --version "$VERSION" --build "$BUILD_NUMBER" --min-os "$MIN_OS" \
  --url "https://github.com/$REPO/releases/download/$TAG/Cosign-$VERSION.zip" \
  --signature "$SIGNATURE" --notes "https://github.com/$REPO/releases/tag/$TAG"

step "Publishing $TAG"
git tag -a "$TAG" -m "Cosign $VERSION"
git push -q origin "$TAG"
gh release create "$TAG" "$ZIP" "$DMG" --repo "$REPO" --title "Cosign $VERSION" \
  --notes "Download Cosign-$VERSION.dmg for a first install. Installed copies update themselves automatically." \
  $( (( DRAFT )) && echo --draft )
if (( ! DRAFT )); then
  git add appcast.xml
  git commit -qm "Release $VERSION"
  git push -q origin main
fi
step "Released Cosign $VERSION ($BUILD_NUMBER)$( (( DRAFT )) && echo ' as a draft; appcast.xml not published' )"
