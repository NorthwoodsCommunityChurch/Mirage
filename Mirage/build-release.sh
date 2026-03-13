#!/bin/bash
set -euo pipefail

# Mirage Release Build Script
# Handles: xcodegen → xcodebuild → copy off OneDrive → xattr cleanup → inside-out codesign → verify → zip
#
# Usage: ./build-release.sh
# Output: Mirage-<version>.zip in the project root, ready for GitHub release
#
# IMPORTANT: The build output lives on OneDrive, which continuously re-adds
# extended attributes (com.apple.FinderInfo, fileprovider metadata) to files.
# These xattrs break code signatures. To work around this, we copy the .app
# to /tmp before stripping xattrs and signing — OneDrive can't touch /tmp.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# Extract version from project.yml
VERSION=$(grep 'MARKETING_VERSION:' project.yml | sed 's/.*"\(.*\)".*/\1/')
BUILD=$(grep 'CURRENT_PROJECT_VERSION:' project.yml | sed 's/.*"\(.*\)".*/\1/')
echo "==> Building Mirage v${VERSION} (build ${BUILD})"

# Step 1: Generate Xcode project
echo "==> Running xcodegen..."
xcodegen generate

# Step 2: Build Release
echo "==> Building Release configuration..."
DERIVED_DATA="$SCRIPT_DIR/build/DerivedData"
xcodebuild \
    -project Mirage.xcodeproj \
    -scheme Mirage \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA" \
    -quiet \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGN_STYLE=Manual

BUILD_APP="$DERIVED_DATA/Build/Products/Release/Mirage.app"

if [ ! -d "$BUILD_APP" ]; then
    echo "ERROR: Build failed — Mirage.app not found at $BUILD_APP"
    exit 1
fi

echo "==> Build succeeded"

# Step 3: Copy to /tmp to escape OneDrive's extended attribute injection
STAGING="/tmp/mirage-release-$$"
rm -rf "$STAGING"
mkdir -p "$STAGING"
echo "==> Copying to staging area (off OneDrive)..."
cp -R "$BUILD_APP" "$STAGING/Mirage.app"

APP="$STAGING/Mirage.app"

# Step 4: Strip any extended attributes
echo "==> Stripping extended attributes..."
xattr -cr "$APP"

# Step 5: Inside-out codesign of Sparkle framework components
# Sparkle's nested XPC services must be signed before the framework,
# and the framework before the app. Ad-hoc signing (sign -).
echo "==> Codesigning Sparkle components (inside-out)..."
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"

if [ -d "$SPARKLE" ]; then
    codesign --force --sign - "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
    codesign --force --sign - "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"

    # Updater.app and Autoupdate may or may not exist depending on Sparkle version
    [ -d "$SPARKLE/Versions/B/Updater.app" ] && \
        codesign --force --sign - "$SPARKLE/Versions/B/Updater.app"
    [ -f "$SPARKLE/Versions/B/Autoupdate" ] && \
        codesign --force --sign - "$SPARKLE/Versions/B/Autoupdate"

    codesign --force --sign - "$SPARKLE"
else
    echo "WARNING: Sparkle.framework not found at $SPARKLE"
fi

# Step 6: Sign the main app
echo "==> Codesigning Mirage.app..."
codesign --force --deep --sign - "$APP"

# Step 7: Verify
echo "==> Verifying code signature..."
if codesign --verify --deep --strict "$APP" 2>&1; then
    echo "==> Signature OK"
else
    echo "ERROR: Code signature verification failed!"
    codesign --verify --deep --strict "$APP" 2>&1
    rm -rf "$STAGING"
    exit 1
fi

# Step 8: Create zip for distribution
ZIP_NAME="Mirage-${VERSION}.zip"
echo "==> Creating $ZIP_NAME..."
cd "$STAGING"
ditto -c -k --keepParent "Mirage.app" "$SCRIPT_DIR/$ZIP_NAME"
cd "$SCRIPT_DIR"

# Clean up staging
rm -rf "$STAGING"

ZIP_SIZE=$(du -h "$ZIP_NAME" | cut -f1)
echo ""
echo "==> Done! $ZIP_NAME ($ZIP_SIZE)"
echo "    Version: $VERSION (build $BUILD)"
echo "    Ready for GitHub release."
