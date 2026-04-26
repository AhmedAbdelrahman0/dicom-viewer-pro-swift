#!/bin/bash
# Build a proper macOS .app bundle so the app shows an icon in the Dock.
#
# Usage:  ./build_app.sh         → builds .app in ./dist/
#         ./build_app.sh install → also copies to ~/Desktop

set -e

cd "$(dirname "$0")"

# Configuration
APP_NAME="Tracer"
BUNDLE_ID="com.tracer.workstation"
VERSION="1.0.0"
EXEC_NAME="TracerApp"
ICON_SRC="Resources/AppIcon.icns"  # self-contained icon inside the Swift project

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

# 2. Create .app bundle structure
DIST="dist"
APP_DIR="$DIST/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

echo "→ Creating .app bundle at $APP_DIR"
rm -rf "$APP_DIR"
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

# 6. Clear extended attributes (prevents Gatekeeper quarantine issues when
#    launching via `open`)
xattr -cr "$APP_DIR" 2>/dev/null || true

# 7. Register with Launch Services
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP_DIR" 2>/dev/null || true

# 8. Set custom icon via Cocoa (makes Finder show it immediately)
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

echo "✓ .app bundle created: $APP_DIR"

# 9. Optional: copy to Desktop
if [ "$1" = "install" ]; then
    DEST="$HOME/Desktop/$APP_NAME.app"
    echo "→ Installing to $DEST"
    rm -rf "$DEST"
    cp -R "$APP_DIR" "$DEST"
    xattr -cr "$DEST" 2>/dev/null || true
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST" 2>/dev/null || true
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
    echo "✓ Installed to Desktop"
fi

echo ""
echo "Launch with:"
echo "  open \"$APP_DIR\""
