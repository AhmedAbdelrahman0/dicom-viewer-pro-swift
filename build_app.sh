#!/bin/bash
# Build a proper macOS .app bundle so the app shows an icon in the Dock.
#
# Usage:  ./build_app.sh         → builds .app in ~/Builds/Tracer/dist/
#         TRACER_DIST_DIR=dist ./build_app.sh → builds .app in ./dist/
#         ./build_app.sh install → also copies to ~/Desktop

set -e

cd "$(dirname "$0")"

# Configuration
APP_NAME="Tracer"
BUNDLE_ID="com.tracer.workstation"
VERSION="1.0.0"
EXEC_NAME="TracerApp"
ICON_SRC="Resources/AppIcon.icns"  # self-contained icon inside the Swift project
CODESIGN_IDENTITY="${TRACER_CODESIGN_IDENTITY:--}"
DEFAULT_DIST="$HOME/Builds/$APP_NAME/dist"
DIST="${TRACER_DIST_DIR:-$DEFAULT_DIST}"

clear_bundle_metadata() {
    local bundle="$1"
    if command -v SetFile >/dev/null 2>&1; then
        SetFile -a c "$bundle" 2>/dev/null || true
    fi
    find "$bundle" -type f -name 'Icon?' -exec rm -f {} + 2>/dev/null || true
    xattr -cr "$bundle" 2>/dev/null || true
    xattr -d com.apple.FinderInfo "$bundle" 2>/dev/null || true
    find "$bundle" -exec xattr -d com.apple.FinderInfo {} + 2>/dev/null || true
    find "$bundle" -exec xattr -d com.apple.ResourceFork {} + 2>/dev/null || true
}

finalize_bundle() {
    local bundle="$1"
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$bundle" 2>/dev/null || true
    clear_bundle_metadata "$bundle"

    if command -v codesign >/dev/null 2>&1; then
        echo "→ Signing app bundle with identity: $CODESIGN_IDENTITY"
        if ! codesign --force --deep --sign "$CODESIGN_IDENTITY" "$bundle"; then
            echo "→ Retrying after clearing Finder metadata…"
            clear_bundle_metadata "$bundle"
            codesign --force --deep --sign "$CODESIGN_IDENTITY" "$bundle"
        fi
        if ! codesign --verify --deep --strict --verbose=2 "$bundle"; then
            echo "→ Retrying verification after clearing Finder metadata…"
            clear_bundle_metadata "$bundle"
            codesign --force --deep --sign "$CODESIGN_IDENTITY" "$bundle"
            codesign --verify --deep --strict --verbose=2 "$bundle"
        fi
    fi
}

# 1. Regenerate the app icon if it's missing (`.icns` is binary; safe to
#    keep checked in, but the programmatic generator means we never have
#    to chase a missing icon). Skip if the generator isn't present.
if [ ! -f "$ICON_SRC" ] && [ -f "scripts/generate_app_icon.swift" ]; then
    echo "→ Icon missing — rendering fresh copy via scripts/generate_app_icon.swift…"
    swift scripts/generate_app_icon.swift "$ICON_SRC"
fi

# 2. Build the release executable
echo "→ Building release executable…"
swift build -c release

BINARY=".build/release/$EXEC_NAME"
if [ ! -x "$BINARY" ]; then
    echo "✗ Build failed — binary not found at $BINARY"
    exit 1
fi

# 2. Create .app bundle structure. The default output is outside Desktop /
#    FileProvider-managed folders so strict codesign is not invalidated by
#    Finder metadata reappearing after signing.
APP_DIR="$DIST/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

echo "→ Creating .app bundle at $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$DIST"
mkdir -p "$MACOS" "$RESOURCES"

# 3. Copy binary (renamed to the display name so the Dock shows it correctly)
cp "$BINARY" "$MACOS/$APP_NAME"
chmod +x "$MACOS/$APP_NAME"

# 4. Copy icon
if [ -f "$ICON_SRC" ]; then
    cp "$ICON_SRC" "$RESOURCES/AppIcon.icns"
else
    echo "⚠ Icon not found at $ICON_SRC — app will use generic icon"
fi

# 4b. Copy lightweight worker scripts used by optional local model engines.
# Heavy weights are downloaded/configured outside the app; these scripts are
# just stable launch contracts for WorkerProcess.
if [ -d "workers/medasr" ]; then
    mkdir -p "$RESOURCES/Workers/medasr"
    cp "workers/medasr/transcribe_medasr.py" "$RESOURCES/Workers/medasr/"
    if [ -f "workers/medasr/requirements.txt" ]; then
        cp "workers/medasr/requirements.txt" "$RESOURCES/Workers/medasr/"
    fi
    chmod +x "$RESOURCES/Workers/medasr/transcribe_medasr.py" 2>/dev/null || true
fi
if [ -d "workers/imageops" ]; then
    mkdir -p "$RESOURCES/Workers/imageops"
    cp "workers/imageops/bridge.py" "$RESOURCES/Workers/imageops/"
    if [ -f "workers/imageops/requirements.txt" ]; then
        cp "workers/imageops/requirements.txt" "$RESOURCES/Workers/imageops/"
    fi
    chmod +x "$RESOURCES/Workers/imageops/bridge.py" 2>/dev/null || true
fi

# 5. Create Info.plist
cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.medical</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Tracer uses the microphone only when you start push-to-talk dictation for reporting.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>Tracer uses speech recognition to transcribe dictated radiology report text and voice commands.</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
    <key>LSUIElement</key>
    <false/>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>DICOM File</string>
            <key>CFBundleTypeExtensions</key>
            <array>
                <string>dcm</string>
                <string>DCM</string>
            </array>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
        </dict>
        <dict>
            <key>CFBundleTypeName</key>
            <string>NIfTI File</string>
            <key>CFBundleTypeExtensions</key>
            <array>
                <string>nii</string>
                <string>nii.gz</string>
            </array>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
        </dict>
    </array>
</dict>
</plist>
PLIST

# 6. Optional Finder custom icon. The bundled CFBundleIconFile is enough for
#    normal app display; Finder custom icons write xattrs that break codesign.
if [ "${TRACER_SET_FINDER_ICON:-0}" = "1" ]; then
python3 - "$APP_DIR" "$RESOURCES/AppIcon.icns" <<PY
import sys, os
try:
    import AppKit
    app_path = sys.argv[1]
    icon_path = sys.argv[2]
    if os.path.exists(icon_path):
        ns_img = AppKit.NSImage.alloc().initWithContentsOfFile_(icon_path)
        if ns_img:
            AppKit.NSWorkspace.sharedWorkspace().setIcon_forFile_options_(ns_img, app_path, 0)
            print("✓ Custom icon set on bundle")
except ImportError:
    pass
PY
fi

# 7. Clear extended attributes, sign, and register with Launch Services.
finalize_bundle "$APP_DIR"

echo "✓ .app bundle created: $APP_DIR"

# 8. Optional: copy to Desktop
if [ "$1" = "install" ]; then
    DEST="$HOME/Desktop/$APP_NAME.app"
    echo "→ Installing to $DEST"
    rm -rf "$DEST"
    cp -R "$APP_DIR" "$DEST"
    if [ "${TRACER_SET_FINDER_ICON:-0}" = "1" ]; then
    python3 - "$DEST" "$DEST/Contents/Resources/AppIcon.icns" <<PY
import sys, os
try:
    import AppKit
    if os.path.exists(sys.argv[2]):
        img = AppKit.NSImage.alloc().initWithContentsOfFile_(sys.argv[2])
        if img:
            AppKit.NSWorkspace.sharedWorkspace().setIcon_forFile_options_(img, sys.argv[1], 0)
except ImportError:
    pass
PY
    fi
    finalize_bundle "$DEST"
    echo "✓ Installed to Desktop"
fi

echo ""
echo "Launch with:"
echo "  open \"$APP_DIR\""
