#!/usr/bin/env bash
# Build, sign, notarize, staple, and append an appcast entry for a
# ShakeToEject release. Run from the repo root.
#
# Usage: scripts/release.sh <version>
# Example: scripts/release.sh 1.0.1
#
# Prerequisites (see docs/RELEASING.md for details):
#   1. `generate_keys` has been run once; SUPublicEDKey in project.yml matches.
#   2. `notarytool` keychain profile named "ShakeToEject" exists.
#   3. Developer ID Application certificate installed in login keychain.
#   4. The app has been built at least once so SPM resolved Sparkle's
#      generate_appcast tool.

set -euo pipefail

VERSION="${1:?usage: $0 <version> (e.g. 1.0.1)}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

BUILD_DIR="$(mktemp -d -t shaketoeject-release)"
RELEASES_DIR="$REPO_ROOT/releases"
NOTARY_PROFILE="ShakeToEject"
SCHEME="ShakeToEject"
APP_NAME="ShakeToEject"

trap 'rm -rf "$BUILD_DIR"' EXIT

echo "==> Locating Sparkle tools"
GENERATE_APPCAST="$(find "$HOME/Library/Developer/Xcode/DerivedData" \
    -name generate_appcast -path '*Sparkle*' -perm -u+x 2>/dev/null \
    | head -1 || true)"
if [[ -z "$GENERATE_APPCAST" ]]; then
    echo "ERROR: generate_appcast not found."
    echo "Open ShakeToEject.xcodeproj in Xcode once (or run 'xcodebuild build')"
    echo "so SPM resolves Sparkle's bundled tools."
    exit 1
fi
echo "    found: $GENERATE_APPCAST"

echo "==> Regenerating project with MARKETING_VERSION=$VERSION"
# project.yml is the source of truth — bump MARKETING_VERSION there
# before running this script. We do NOT edit project.yml here; we
# only pass the value on the command line so the produced artifact
# version matches the argument, but we still expect the tag to match.
CURRENT_VERSION=$(/usr/bin/grep -E '^\s+MARKETING_VERSION:' project.yml | head -1 | awk '{print $2}' | tr -d '"')
if [[ "$CURRENT_VERSION" != "$VERSION" ]]; then
    echo "ERROR: project.yml MARKETING_VERSION ($CURRENT_VERSION) != requested version ($VERSION)."
    echo "Bump MARKETING_VERSION in project.yml, run 'xcodegen generate', then retry."
    exit 1
fi

echo "==> Building Release"
xcodebuild -project ShakeToEject.xcodeproj \
    -scheme "$SCHEME" \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR" \
    -destination 'platform=macOS' \
    clean build \
    | xcpretty 2>/dev/null || true

APP_PATH="$BUILD_DIR/Build/Products/Release/$APP_NAME.app"
if [[ ! -d "$APP_PATH" ]]; then
    echo "ERROR: $APP_PATH not found after build."
    exit 1
fi

echo "==> Locating Developer ID Application identity for team 382G4857JD"
IDENTITY=$(security find-identity -v -p codesigning \
    | grep "Developer ID Application" \
    | grep "382G4857JD" \
    | head -1 \
    | awk -F'"' '{print $2}')
if [[ -z "$IDENTITY" ]]; then
    echo "ERROR: Developer ID Application certificate for team 382G4857JD not found."
    echo "       Run: security find-identity -v -p codesigning"
    exit 1
fi
echo "    identity: $IDENTITY"

echo "==> Re-signing Sparkle's nested binaries + app with proper flags"
# Xcode's embed-framework pass re-signs the outer Sparkle.framework
# but does NOT traverse into nested bundles (Updater.app, XPCServices,
# the standalone Autoupdate binary). Those ship pre-signed by the
# Sparkle project with upstream identities, which Apple's notary
# service rejects. We re-sign each inside-out with:
#   --options runtime  → hardened runtime (required for notarization)
#   --timestamp        → secure Apple timestamp (required for notarization)
#   --force            → replace the upstream signature
SPARKLE_FW="$APP_PATH/Contents/Frameworks/Sparkle.framework"
SIGN_OPTS=(--force --options runtime --timestamp --sign "$IDENTITY")

# Order matters: innermost first, then parent bundles.
codesign "${SIGN_OPTS[@]}" "$SPARKLE_FW/Versions/Current/Autoupdate"
codesign "${SIGN_OPTS[@]}" "$SPARKLE_FW/Versions/Current/Updater.app/Contents/MacOS/Updater"
codesign "${SIGN_OPTS[@]}" "$SPARKLE_FW/Versions/Current/Updater.app"
codesign "${SIGN_OPTS[@]}" "$SPARKLE_FW/Versions/Current/XPCServices/Downloader.xpc/Contents/MacOS/Downloader"
codesign "${SIGN_OPTS[@]}" "$SPARKLE_FW/Versions/Current/XPCServices/Downloader.xpc"
codesign "${SIGN_OPTS[@]}" "$SPARKLE_FW/Versions/Current/XPCServices/Installer.xpc/Contents/MacOS/Installer"
codesign "${SIGN_OPTS[@]}" "$SPARKLE_FW/Versions/Current/XPCServices/Installer.xpc"
codesign "${SIGN_OPTS[@]}" "$SPARKLE_FW/Versions/Current/Sparkle"
codesign "${SIGN_OPTS[@]}" "$SPARKLE_FW"

# Re-sign the outer app LAST so its signature seals the re-signed
# framework. Pass our entitlements file explicitly so we overwrite
# any get-task-allow that CODE_SIGN_INJECT_BASE_ENTITLEMENTS added
# during the Xcode build pass.
ENTITLEMENTS="$REPO_ROOT/App/ShakeToEject.entitlements"
codesign "${SIGN_OPTS[@]}" --entitlements "$ENTITLEMENTS" "$APP_PATH"

echo "==> Verifying final signatures"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
AUTHORITY=$(codesign -dv --verbose=2 "$APP_PATH" 2>&1 | grep -E '^Authority=' | head -1)
echo "    $AUTHORITY"

echo "==> Creating zip archive (Sparkle's preferred format)"
mkdir -p "$RELEASES_DIR"
ARCHIVE="$RELEASES_DIR/$APP_NAME-$VERSION.zip"
rm -f "$ARCHIVE"
# ditto preserves extended attributes and code signatures; zip does not.
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ARCHIVE"
echo "    archive: $ARCHIVE"

echo "==> Submitting to Apple notary service (this can take several minutes)"
xcrun notarytool submit "$ARCHIVE" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

echo "==> Stapling notarization ticket to the .app and re-zipping"
# Staple onto the .app (the ticket lives inside the bundle), then
# rebuild the zip so the uploaded archive contains the stapled app.
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"
rm -f "$ARCHIVE"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ARCHIVE"

echo "==> Regenerating appcast"
"$GENERATE_APPCAST" "$RELEASES_DIR" \
    --download-url-prefix "https://github.com/mcomisso/ShakeToEject/releases/download/v$VERSION/" \
    -o "$REPO_ROOT/appcast.xml"

echo ""
echo "==============================================="
echo "Release $VERSION built successfully."
echo "==============================================="
echo "Archive:  $ARCHIVE"
echo "Appcast:  $REPO_ROOT/appcast.xml"
echo ""
echo "Next steps:"
echo "  1. Review appcast.xml — confirm the new <item> has correct version, URL, and signature."
echo "  2. git add appcast.xml project.yml"
echo "     git commit -m 'Release v$VERSION'"
echo "     git tag v$VERSION"
echo "     git push && git push --tags"
echo "  3. Create a GitHub Release at v$VERSION and attach:"
echo "       $ARCHIVE"
echo "     (The download URL must match the --download-url-prefix used above.)"
echo "  4. Smoke-test: on a Mac with the previous version installed,"
echo "     click 'Check for Updates…' and confirm the upgrade flow."
