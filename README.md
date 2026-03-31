# VoiceInk 🎤

A macOS voice input tool powered by [FunASR](https://github.com/modelscope/FunASR). Double-tap Option to speak, and your words are transcribed and pasted instantly.

## Features

- **Chinese-English mixed input** — Seamlessly switch between Chinese and English
- **Hotword customization** — Boost recognition accuracy for domain-specific terms
- **Auto-formatting** — Punctuation, CJK-English spacing, capitalization
- **Real-time preview** — See partial transcription results as you speak
- **VAD auto-stop** — Automatically stops when you pause speaking
- **ESC to cancel** — Press ESC to abort recording anytime
- **Native macOS app** — Menubar integration, system notifications

## Architecture

```
Double-tap Option → Record audio → FunASR (local, offline) → Format → Paste
```

All processing happens locally on your Mac. No cloud, no API keys, fully offline.

## Requirements

- macOS 13+
- Apple Silicon (M1/M2/M3/M4) or Intel Mac
- ~2GB disk space for models
- Python 3.10+ (via Miniconda/Miniforge)

## Installation

### 1. Setup Python environment

```bash
# Install Miniconda (if not already installed)
# ARM Mac:
curl -sL -o miniconda.sh https://repo.anaconda.com/miniconda/Miniconda3-latest-MacOSX-arm64.sh
# Intel Mac:
# curl -sL -o miniconda.sh https://repo.anaconda.com/miniconda/Miniconda3-latest-MacOSX-x86_64.sh
bash miniconda.sh -b -p ~/miniconda3

# Create environment
source ~/miniconda3/bin/activate
conda create -n voice-input python=3.10 -y
conda activate voice-input

# Install numba via conda (avoids llvmlite build issues)
conda install -c conda-forge numba llvmlite -y
```

### 2. Install dependencies

```bash
cd voice-input-mac
pip install torch torchaudio
pip install "numpy<2" funasr sounddevice rumps \
    pyobjc-framework-Cocoa pyobjc-framework-Quartz \
    pyobjc-framework-WebKit websockets Pillow
```

### 3. Download models (first run)

```bash
python -c "
from funasr import AutoModel
AutoModel(
    model='iic/speech_seaco_paraformer_large_asr_nat-zh-cn-16k-common-vocab8404-pytorch',
    vad_model='iic/speech_fsmn_vad_zh-cn-16k-common-pytorch',
    punc_model='iic/punc_ct-transformer_cn-en-common-vocab471067-large',
    device='cpu', disable_update=True,
)
print('Models downloaded successfully')
"
```

### 4. Build macOS app

```bash
bash build_app.sh
```

### 5. Launch

Double-click `~/Applications/VoiceInput.app`, or:

```bash
open ~/Applications/VoiceInput.app
```

Grant microphone and accessibility permissions when prompted.

## Usage

| Action | Shortcut |
|--------|----------|
| Start/stop recording | Double-tap **Option** |
| Cancel recording | **ESC** |
| Open settings | **Cmd+,** or menubar → Settings |

## Configuration

Edit `config/settings.json` or use the built-in settings UI:

- **Silence timeout** — How long to wait after you stop speaking (default: 2s)
- **Max duration** — Maximum recording length (default: 30s)
- **Silence threshold** — Volume threshold for silence detection (default: 500)
- **Hotwords** — Add domain-specific terms for better recognition

## Hotwords

Add hotwords in `config/hotwords.txt` (one per line) to improve recognition of specific terms:

```
Transformer
Claude
FunASR
```

## Tech Stack

- **ASR Engine**: [FunASR](https://github.com/modelscope/FunASR) (SeACo-Paraformer)
- **Audio**: sounddevice (PortAudio)
- **Menubar**: rumps
- **UI**: PyObjC (NSWindow, WKWebView)
- **Hotkey**: NSEvent global monitor

## License

MIT
