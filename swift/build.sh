#!/bin/bash
# build.sh — Compile VibeKeyboard SwiftUI app with swiftc
#
# Usage:
#   ./build.sh              # Build all source files
#   ./build.sh --run        # Build and run
#   ./build.sh --clean      # Remove build artifacts
#
# No Xcode project required. Links against system frameworks.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
OUTPUT="$BUILD_DIR/VibeKeyboard"

# All Swift source files (SwiftUI @main entry point + all modules)
SOURCES=(
    # App layer (SwiftUI entry point + ViewModel + AppDelegate)
    "$SCRIPT_DIR/App/VibeKeyboardApp.swift"
    "$SCRIPT_DIR/App/VibeKeyboardViewModel.swift"
    "$SCRIPT_DIR/App/AppDelegate.swift"
    # ASR engine
    "$SCRIPT_DIR/ASR/SherpaEngine.swift"
    # Audio recording
    "$SCRIPT_DIR/Audio/AudioRecorder.swift"
    # Configuration
    "$SCRIPT_DIR/Config/ConfigManager.swift"
    # Hotkey detection
    "$SCRIPT_DIR/Hotkey/HotkeyListener.swift"
    # Text insertion (pasteboard + Cmd+V)
    "$SCRIPT_DIR/Input/TextInserter.swift"
    # Text processing
    "$SCRIPT_DIR/TextProcessing/Formatter.swift"
    "$SCRIPT_DIR/TextProcessing/Polisher.swift"
    "$SCRIPT_DIR/TextProcessing/HotwordManager.swift"
    # UI
    "$SCRIPT_DIR/UI/OverlayWindow.swift"
    "$SCRIPT_DIR/UI/SettingsView.swift"
)

# Frameworks to link
FRAMEWORKS=(
    "-framework" "AppKit"
    "-framework" "AVFoundation"
    "-framework" "Carbon"
    "-framework" "CoreGraphics"
    "-framework" "Foundation"
    "-framework" "SwiftUI"
    "-framework" "UniformTypeIdentifiers"
)

# Handle --clean
if [[ "${1:-}" == "--clean" ]]; then
    echo "Cleaning build directory..."
    rm -rf "$BUILD_DIR"
    echo "Done."
    exit 0
fi

# Create build directory
mkdir -p "$BUILD_DIR"

echo "=== VibeKeyboard Swift Build ==="
echo "Sources: ${#SOURCES[@]} files"
echo "Output:  $OUTPUT"
echo ""

# Check all source files exist
for src in "${SOURCES[@]}"; do
    if [[ ! -f "$src" ]]; then
        echo "ERROR: Missing source file: $src"
        exit 1
    fi
done

# Compile
echo "Compiling..."
START_TIME=$(date +%s)

swiftc \
    -O \
    -whole-module-optimization \
    -target arm64-apple-macos13.0 \
    "${FRAMEWORKS[@]}" \
    "${SOURCES[@]}" \
    -o "$OUTPUT" \
    2>&1

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

echo "Build succeeded in ${ELAPSED}s"
echo "Binary: $OUTPUT"
echo "Size: $(du -h "$OUTPUT" | cut -f1)"

# Handle --run
if [[ "${1:-}" == "--run" ]]; then
    echo ""
    echo "=== Running VibeKeyboard ==="
    exec "$OUTPUT"
fi
