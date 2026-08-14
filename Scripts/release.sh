#!/bin/bash
# Builds, signs, notarizes, and packages Conclawd for distribution (DMG).
#
# One-time prerequisites:
#   1. A "Developer ID Application" certificate in the login keychain
#      (Xcode > Settings > Accounts > Manage Certificates > + > Developer ID Application).
#   2. Notary credentials stored as a keychain profile:
#        xcrun notarytool store-credentials conclawd-notary \
#          --apple-id <apple-id> --team-id <team-id> --password <app-specific-password>
#      (app-specific password: https://account.apple.com > Sign-In and Security)
#
# Usage:
#   Scripts/release.sh                       # full pipeline: build -> sign -> dmg -> notarize -> staple
#   SKIP_NOTARIZE=1 Scripts/release.sh       # stop after signing + dmg (local testing)
#   SIGN_IDENTITY="<identity>" Scripts/release.sh   # override signing identity
set -euo pipefail
cd "$(dirname "$0")/.."

SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
NOTARY_PROFILE="${NOTARY_PROFILE:-conclawd-notary}"
DERIVED=build/Release-DerivedData
DIST=build/dist
APP="$DERIVED/Build/Products/Release/Conclawd.app"

VERSION=$(sed -n 's/.*MARKETING_VERSION: "\(.*\)"/\1/p' project.yml | head -1)
if [[ -z "$VERSION" ]]; then
    echo "error: could not read MARKETING_VERSION from project.yml" >&2
    exit 1
fi

echo "==> Building Conclawd $VERSION (Release)"
xcodebuild -scheme Conclawd -configuration Release -derivedDataPath "$DERIVED" -quiet build

echo "==> Signing with '$SIGN_IDENTITY' (hardened runtime)"
# Nested executables first, then the bundle itself (which seals the contents).
codesign --force --options runtime --timestamp \
    --sign "$SIGN_IDENTITY" "$APP/Contents/Helpers/conclawd"
codesign --force --options runtime --timestamp \
    --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict --deep --verbose=2 "$APP"

echo "==> Creating DMG"
rm -rf "$DIST"
mkdir -p "$DIST/staging"
cp -R "$APP" "$DIST/staging/"
ln -s /Applications "$DIST/staging/Applications"
DMG="$DIST/Conclawd-$VERSION.dmg"
hdiutil create -volname "Conclawd" -srcfolder "$DIST/staging" -ov -format UDZO -quiet "$DMG"
rm -rf "$DIST/staging"
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"

if [[ "${SKIP_NOTARIZE:-0}" == "1" ]]; then
    echo "==> SKIP_NOTARIZE=1 — stopping before notarization"
    echo "    Unnotarized DMG: $DMG"
    exit 0
fi

echo "==> Notarizing (this waits for Apple, typically 1-5 minutes)"
# CI passes credentials via env vars; local runs use the stored keychain profile.
if [[ -n "${APPLE_ID:-}" && -n "${APPLE_APP_PASSWORD:-}" && -n "${APPLE_TEAM_ID:-}" ]]; then
    xcrun notarytool submit "$DMG" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" \
        --password "$APPLE_APP_PASSWORD" --wait
else
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
fi

echo "==> Stapling ticket"
xcrun stapler staple "$DMG"
spctl -a -t open --context context:primary-signature -v "$DMG"

cp "$DMG" "$DIST/Conclawd.dmg"

if [[ "${SKIP_UPLOAD:-0}" == "1" ]]; then
    echo "==> SKIP_UPLOAD=1 — stopping before R2 upload"
    echo "    Notarized DMG: $DMG"
    exit 0
fi

# Public download URL: https://pub-3d16ad835aab4ec7804bf72e28fa2452.r2.dev/Conclawd.dmg
R2_BUCKET="${R2_BUCKET:-conclawd-downloads}"
echo "==> Uploading to R2 bucket '$R2_BUCKET'"
# CI authenticates via CLOUDFLARE_API_TOKEN / CLOUDFLARE_ACCOUNT_ID env vars.
WRANGLER=(wrangler)
command -v wrangler >/dev/null 2>&1 || WRANGLER=(npx -y wrangler@4)
"${WRANGLER[@]}" r2 object put "$R2_BUCKET/Conclawd-$VERSION.dmg" --file "$DMG" \
    --content-type application/x-apple-diskimage --remote
"${WRANGLER[@]}" r2 object put "$R2_BUCKET/Conclawd.dmg" --file "$DMG" \
    --content-type application/x-apple-diskimage --remote

echo ""
echo "==> Done"
echo "    Versioned: https://pub-3d16ad835aab4ec7804bf72e28fa2452.r2.dev/Conclawd-$VERSION.dmg"
echo "    Latest:    https://pub-3d16ad835aab4ec7804bf72e28fa2452.r2.dev/Conclawd.dmg"
