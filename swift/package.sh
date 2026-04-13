#!/bin/bash
# package.sh — Build and package VibeKeyboard.app
#
# Usage:
#   ./package.sh              # Build binary + create .app bundle
#   ./package.sh --app-only   # Skip build, just re-package .app from existing binary
#   ./package.sh --run        # Build, package, and launch
#
# Creates ~/Applications/VibeKeyboard.app with embedded dylibs and model.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP_DIR="$HOME/Applications/VibeKeyboard.app"
BINARY="$SCRIPT_DIR/build/VibeKeyboard"

# sherpa-onnx library location
SHERPA_LIB="/Users/gsj/miniconda3/envs/voice-input/lib/python3.10/site-packages/sherpa_onnx/lib"

# Model files
MODEL_DIR="$HOME/.cache/sherpa-onnx/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17"

# Resources
RESOURCES_DIR="$PROJECT_DIR/resources"

# Parse args
SKIP_BUILD=false
RUN_AFTER=false
for arg in "$@"; do
    case "$arg" in
        --app-only) SKIP_BUILD=true ;;
        --run)      RUN_AFTER=true ;;
    esac
done

# Step 1: Build
if [ "$SKIP_BUILD" = false ]; then
    echo "=== Building VibeKeyboard ==="
    bash "$SCRIPT_DIR/build.sh"
    echo ""
fi

# Verify binary exists
if [ ! -f "$BINARY" ]; then
    echo "ERROR: Binary not found at $BINARY"
    echo "Run build.sh first or remove --app-only flag."
    exit 1
fi

echo "=== Packaging VibeKeyboard.app ==="

# Step 2: Create directory structure
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Frameworks"
mkdir -p "$APP_DIR/Contents/Resources"

# Step 3: Copy binary and fix rpath
cp "$BINARY" "$APP_DIR/Contents/MacOS/VibeKeyboard"
chmod +x "$APP_DIR/Contents/MacOS/VibeKeyboard"

# Remove old conda rpath, add bundle-relative rpath
install_name_tool -delete_rpath "$SHERPA_LIB" "$APP_DIR/Contents/MacOS/VibeKeyboard" 2>/dev/null || true
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_DIR/Contents/MacOS/VibeKeyboard" 2>/dev/null || true
echo "  [OK] Binary + rpath"

# Step 4: Copy dylibs
cp "$SHERPA_LIB/libsherpa-onnx-c-api.dylib" "$APP_DIR/Contents/Frameworks/"
cp "$SHERPA_LIB/libonnxruntime.1.23.2.dylib" "$APP_DIR/Contents/Frameworks/"
echo "  [OK] Frameworks (dylibs)"

# Step 5: Copy resources
cp "$RESOURCES_DIR/AppIcon.icns" "$APP_DIR/Contents/Resources/"
cp "$MODEL_DIR/model.int8.onnx" "$APP_DIR/Contents/Resources/"
cp "$MODEL_DIR/tokens.txt" "$APP_DIR/Contents/Resources/"
echo "  [OK] Resources (icon + model)"

# Step 6: Create PkgInfo
echo -n "APPL????" > "$APP_DIR/Contents/PkgInfo"

# Step 7: Create Info.plist
cat > "$APP_DIR/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>VibeKeyboard</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.gsj.vibekeyboard</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>VibeKeyboard</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <false/>
    <key>NSMicrophoneUsageDescription</key>
    <string>VibeKeyboard needs microphone access for voice input recognition.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>VibeKeyboard uses Apple Events to paste recognized text into applications.</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
</dict>
</plist>
PLIST
echo "  [OK] Info.plist + PkgInfo"

# Step 8: Code sign (prefer stable certificate over ad-hoc)
CERT_NAME="VibeKeyboard Developer"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
    codesign --force --deep --sign "$CERT_NAME" "$APP_DIR"
    echo "  [OK] Codesigned (certificate: $CERT_NAME)"
    echo "  NOTE: Accessibility permissions will survive rebuilds."
else
    codesign --force --deep --sign - "$APP_DIR"
    echo "  [OK] Codesigned (ad-hoc)"
    echo "  WARNING: Ad-hoc signing — accessibility permissions reset on each rebuild."
    echo "  Run 'bash setup-signing.sh' once to create a stable certificate."
fi

# Summary
echo ""
echo "=== VibeKeyboard.app created ==="
echo "Location: $APP_DIR"
echo "Size: $(du -sh "$APP_DIR" | cut -f1)"
echo ""

# Step 9: Reset accessibility TCC entry (ad-hoc signing invalidates old CDHash)
tccutil reset Accessibility com.gsj.vibekeyboard 2>/dev/null && \
    echo "  [OK] Reset accessibility TCC (re-grant needed after launch)" || true

if [ "$RUN_AFTER" = true ]; then
    echo "=== Launching ==="
    pkill -f "VibeKeyboard" 2>/dev/null || true
    sleep 1
    open "$APP_DIR"
    echo "Launched. Check menubar for mic icon."
fi
