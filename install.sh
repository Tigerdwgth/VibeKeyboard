#!/bin/bash
# VibeKeyboard 一键安装脚本
# 下载后运行: bash install.sh
set -e

echo "=============================="
echo "  VibeKeyboard Installer"
echo "  macOS 本地语音输入工具"
echo "=============================="
echo ""

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONDA_DIR="$HOME/miniconda3"
ENV_NAME="voice-input"
APP_DIR="$HOME/Applications"

# ---- 1. 检查/安装 Miniconda ----
if [ ! -f "$CONDA_DIR/bin/conda" ]; then
    echo "[1/5] 安装 Miniconda..."
    ARCH=$(uname -m)
    if [ "$ARCH" = "arm64" ]; then
        URL="https://repo.anaconda.com/miniconda/Miniconda3-latest-MacOSX-arm64.sh"
    else
        URL="https://repo.anaconda.com/miniconda/Miniconda3-latest-MacOSX-x86_64.sh"
    fi
    curl -sL -o /tmp/miniconda.sh "$URL"
    bash /tmp/miniconda.sh -b -p "$CONDA_DIR"
    rm /tmp/miniconda.sh
else
    echo "[1/5] Miniconda 已安装 ✓"
fi

# ---- 2. 创建 conda 环境 ----
source "$CONDA_DIR/bin/activate"
if conda env list | grep -q "$ENV_NAME"; then
    echo "[2/5] conda 环境已存在 ✓"
else
    echo "[2/5] 创建 conda 环境 ($ENV_NAME, Python 3.10)..."
    conda create -n "$ENV_NAME" python=3.10 -y -q
fi
conda activate "$ENV_NAME"

# ---- 3. 安装依赖 ----
echo "[3/5] 安装 Python 依赖..."
conda install -c conda-forge numba llvmlite -y -q 2>/dev/null || true
pip install -q torch torchaudio 2>/dev/null
pip install -q "numpy<2" funasr sounddevice rumps sherpa-onnx \
    pyobjc-framework-Cocoa pyobjc-framework-Quartz \
    pyobjc-framework-WebKit Pillow huggingface_hub openai 2>/dev/null
echo "   依赖安装完成 ✓"

# ---- 4. 安装 ONNX 模型 ----
MODEL_DIR="$HOME/.cache/sherpa-onnx/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17"
BUNDLED_MODEL="$PROJECT_DIR/models/model.int8.onnx"

if [ -f "$MODEL_DIR/model.int8.onnx" ]; then
    echo "[4/5] ONNX 模型已安装 ✓"
elif [ -f "$BUNDLED_MODEL" ]; then
    echo "[4/5] 从安装包复制 ONNX 模型..."
    mkdir -p "$MODEL_DIR"
    cp "$PROJECT_DIR/models/model.int8.onnx" "$MODEL_DIR/"
    cp "$PROJECT_DIR/models/tokens.txt" "$MODEL_DIR/"
    echo "   模型安装完成 ✓"
else
    echo "[4/5] 下载 ONNX 模型 (~230MB)..."
    mkdir -p "$MODEL_DIR"
    pip install -q huggingface_hub 2>/dev/null
    python -c "
from huggingface_hub import hf_hub_download
hf_hub_download('csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17', 'model.int8.onnx', local_dir='$MODEL_DIR')
hf_hub_download('csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17', 'tokens.txt', local_dir='$MODEL_DIR')
print('done')
"
    echo "   模型下载完成 ✓"
fi

# ---- 5. 构建 .app ----
echo "[5/5] 构建 VibeKeyboard.app..."
cd "$PROJECT_DIR"
bash build_app.sh

echo ""
echo "=============================="
echo "  安装完成！"
echo ""
echo "  启动方式："
echo "    双击 ~/Applications/VibeKeyboard.app"
echo ""
echo "  首次启动请授予："
echo "    - 麦克风权限"
echo "    - 辅助功能权限（自动粘贴需要）"
echo ""
echo "  使用方式："
echo "    双击 Option → 说话 → 回车确认"
echo "    ESC 取消"
echo "=============================="

# 询问是否立即启动
read -p "现在启动 VibeKeyboard？[Y/n] " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Nn]$ ]]; then
    open "$APP_DIR/VibeKeyboard.app"
fi
