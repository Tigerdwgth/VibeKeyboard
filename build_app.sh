#!/bin/bash
# build_app.sh — 构建 VibeKeyboard.app
#
# 创建一个标准的 macOS .app bundle:
#   MacOS/VibeKeyboard-launcher  (shell 脚本, CFBundleExecutable)
#   MacOS/VibeKeyboard-python    (python3 硬链接, 实际执行)
#
# shell 脚本设置环境后 exec python3 硬链接。
# 因为 python3 硬链接在 .app/Contents/MacOS/ 下，
# macOS TCC 会把麦克风权限关联到 .app 的 bundle ID。
#
# 用法:
#   bash build_app.sh
#   # 输出: ~/Applications/VibeKeyboard.app

set -euo pipefail

APP_NAME="VibeKeyboard"
BUNDLE_ID="com.gsj.vibekeyboard"
APP_DIR="$HOME/Applications/${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
PYTHON_BIN="$HOME/miniconda3/envs/voice-input/bin/python3"
CONDA_ENV="$HOME/miniconda3/envs/voice-input"

echo "=== Building ${APP_NAME}.app ==="

# 验证 python3 存在
if [ ! -f "$PYTHON_BIN" ]; then
    echo "ERROR: Python not found at $PYTHON_BIN"
    exit 1
fi

# 清除旧的 app（如果有）
if [ -d "$APP_DIR" ]; then
    echo "Removing old ${APP_DIR} ..."
    rm -rf "$APP_DIR"
fi

# 创建目录结构
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

# --- 1. Python3 硬链接 ---
# 硬链接使得这个二进制 "属于" .app bundle，
# macOS TCC 因此会将权限关联到 bundle ID 而非原始 python3 路径
ln "$PYTHON_BIN" "${MACOS_DIR}/${APP_NAME}-python"
echo "Created hardlink: ${MACOS_DIR}/${APP_NAME}-python -> $(readlink -f "$PYTHON_BIN" 2>/dev/null || echo "$PYTHON_BIN")"

# --- 2. 启动器脚本 ---
cat > "${MACOS_DIR}/${APP_NAME}-launcher" << LAUNCHER
#!/bin/bash
# VibeKeyboard launcher — sets up conda env then exec's the python3 hardlink
# The hardlink lives inside the .app bundle, so TCC grants permissions to this .app

export HOME="\${HOME:-\$HOME}"
PROJECT_DIR="\$HOME/voice-input-mac"
CONDA_ENV="\$HOME/miniconda3/envs/voice-input"
APP_MACOS_DIR="\$(cd "\$(dirname "\$0")" && pwd)"

# Conda environment paths
export PATH="\$CONDA_ENV/bin:\$PATH"
export CONDA_PREFIX="\$CONDA_ENV"
export PYTHONPATH="\${PROJECT_DIR}:\${PYTHONPATH:-}"

# Required for some native libs (torch, etc.)
export DYLD_LIBRARY_PATH="\${CONDA_ENV}/lib:\${DYLD_LIBRARY_PATH:-}"

# Change to project dir
cd "\$PROJECT_DIR"

# Log startup
echo "\$(date): VibeKeyboard.app starting, PID=\$\$" >> /tmp/vibekeyboard.log

# exec replaces this shell process with the python3 hardlink binary.
# Since the binary is inside MacOS/, TCC associates permissions with the .app
exec "\${APP_MACOS_DIR}/${APP_NAME}-python" "\$PROJECT_DIR/main.py" >> /tmp/vibekeyboard.log 2>&1
LAUNCHER
chmod +x "${MACOS_DIR}/${APP_NAME}-launcher"

# --- 3. Info.plist ---
cat > "${CONTENTS_DIR}/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}-launcher</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>VibeKeyboard needs microphone access to record and transcribe speech.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>VibeKeyboard needs to control other applications to insert transcribed text.</string>
</dict>
</plist>
PLIST

# --- 4. PkgInfo ---
echo -n "APPL????" > "${CONTENTS_DIR}/PkgInfo"

# --- 5. 生成并复制图标文件 ---
ICON_SRC="${PROJECT_DIR}/resources/appicon.png"
ICON_ICNS="${PROJECT_DIR}/resources/AppIcon.icns"
if [ -f "$ICON_ICNS" ]; then
    cp "$ICON_ICNS" "${RESOURCES_DIR}/AppIcon.icns"
    echo "Copied pre-built icon: ${ICON_ICNS}"
elif [ -f "$ICON_SRC" ]; then
    echo "Generating AppIcon.icns from ${ICON_SRC} ..."
    ICONSET_DIR=$(mktemp -d)/AppIcon.iconset
    mkdir -p "$ICONSET_DIR"
    python3 -c "
from PIL import Image; import os, sys
img = Image.open(sys.argv[1])
d = sys.argv[2]
for s in [16,32,64,128,256,512]:
    img.resize((s,s), Image.LANCZOS).save(os.path.join(d, f'icon_{s}x{s}.png'))
    s2 = s*2
    if s2 <= 1024:
        img.resize((s2,s2), Image.LANCZOS).save(os.path.join(d, f'icon_{s}x{s}@2x.png'))
img.resize((1024,1024), Image.LANCZOS).save(os.path.join(d, 'icon_512x512@2x.png'))
" "$ICON_SRC" "$ICONSET_DIR"
    iconutil -c icns "$ICONSET_DIR" -o "${RESOURCES_DIR}/AppIcon.icns"
    # Cache for future builds
    cp "${RESOURCES_DIR}/AppIcon.icns" "$ICON_ICNS"
    rm -rf "$(dirname "$ICONSET_DIR")"
    echo "Generated and cached AppIcon.icns"
else
    echo "WARNING: No icon source found at ${ICON_SRC}"
fi

# --- 6. 验证构建 ---
echo ""
echo "=== Verifying build ==="
file "${MACOS_DIR}/${APP_NAME}-python"
file "${MACOS_DIR}/${APP_NAME}-launcher"
echo "Bundle ID: $(mdls -name kMDItemCFBundleIdentifier -raw "${APP_DIR}" 2>/dev/null || echo "${BUNDLE_ID}")"
echo ""
echo "=== Build complete: ${APP_DIR} ==="
echo ""
echo "Next steps:"
echo "  1. Open the app:  open '${APP_DIR}'"
echo "  2. macOS will prompt for microphone permission — click Allow"
echo "  3. You may also need to grant Accessibility permission in:"
echo "     System Settings > Privacy & Security > Accessibility"
echo ""
echo "To reset TCC permissions (if needed):"
echo "  tccutil reset Microphone ${BUNDLE_ID}"
