# VibeKeyboard 🎤

macOS 本地语音输入工具。双击 Option 开始说话，实时显示识别结果，回车确认自动粘贴。完全离线，无需云端 API。

A local voice input tool for macOS. Double-tap Option to speak, see real-time transcription, press Enter to paste. Fully offline, no cloud API needed.

## Features

- **Real-time streaming recognition** — See transcription update live as you speak (0.2s refresh)
- **Chinese-English mixed input** — Seamlessly switch between Mandarin and English
- **Three ASR backends** — SenseVoice-ONNX (fastest, default), SenseVoice-FunASR, Paraformer (hotword support)
- **Hotword customization** — Boost accuracy for domain-specific terms (Paraformer backend)
- **Auto-formatting** — Punctuation, CJK-English spacing, filler word removal
- **Continuous recording** — No auto-stop; record as long as you want
- **Instant paste** — Enter or double-tap Option to confirm, text is pasted immediately
- **ESC to cancel** — Abort recording anytime without pasting
- **Native macOS app** — Menubar icon, Dock icon, frosted glass overlay, system notifications
- **Settings UI** — WKWebView-based modern settings window (Cmd+,)
- **Privacy first** — Everything runs locally on your Mac, no data leaves your device

## How It Works

```
Double-tap Option → Record & stream recognize → Enter to confirm → Auto-paste
                                               → ESC to cancel
```

## Screenshots

| Recording | Settings |
|-----------|----------|
| Frosted glass overlay with real-time transcription | Dark theme settings with hotword management |

## Requirements

- macOS 13+
- Apple Silicon (M1/M2/M3/M4) or Intel Mac
- ~1GB disk space (SenseVoice-ONNX model)
- Python 3.10+

## Quick Start

### 1. Setup environment

```bash
# Install Miniconda (ARM Mac)
curl -sL -o miniconda.sh https://repo.anaconda.com/miniconda/Miniconda3-latest-MacOSX-arm64.sh
bash miniconda.sh -b -p ~/miniconda3

# Create environment
source ~/miniconda3/bin/activate
conda create -n voice-input python=3.10 -y
conda activate voice-input
conda install -c conda-forge numba llvmlite -y
```

### 2. Install dependencies

```bash
git clone https://github.com/Tigerdwgth/VibeKeyboard.git
cd VibeKeyboard

pip install torch torchaudio
pip install "numpy<2" funasr sounddevice rumps sherpa-onnx \
    pyobjc-framework-Cocoa pyobjc-framework-Quartz \
    pyobjc-framework-WebKit Pillow huggingface_hub
```

### 3. Build & Launch

```bash
# Build .app bundle
bash build_app.sh

# Launch
open ~/Applications/VibeKeyboard.app
```

First launch will download the SenseVoice-ONNX model (~230MB). Grant **microphone** and **accessibility** permissions when prompted.

### Alternative: Run from terminal

```bash
source ~/miniconda3/bin/activate voice-input
cd VibeKeyboard
python main.py
```

## Usage

| Action | Shortcut |
|--------|----------|
| Start recording | Double-tap **Option** |
| Confirm & paste | **Enter** or double-tap **Option** again |
| Cancel recording | **ESC** |
| Open settings | **Cmd+,** or menubar → VibeKeyboard → Settings |

### Workflow

1. **Double-tap Option** — Recording starts, overlay appears near cursor
2. **Speak** — Real-time transcription updates in the overlay every 0.2s
3. **Enter** — Stops recording, pastes text at cursor, closes overlay instantly
4. Or **ESC** — Cancels without pasting

## ASR Backends

Switch backends from the menubar menu at any time.

| Backend | Speed | Chinese | Hotwords | Notes |
|---------|-------|---------|----------|-------|
| **SenseVoice-ONNX** (default) | ~70ms/10s | Excellent | No | sherpa-onnx, fastest |
| SenseVoice-FunASR | ~500ms/10s | Excellent | No | FunASR Python API |
| Paraformer | ~500ms/10s | Good | **Yes** | SeACo-Paraformer, use when you need hotwords |

## Configuration

Open settings via **Cmd+,** or edit `config/settings.json`:

```json
{
    "asr_backend": "sherpa-sensevoice",
    "silence_threshold": 500,
    "overlay_font_size": 13,
    "formatting": {
        "auto_spacing": true,
        "capitalize": true,
        "replacements": {}
    }
}
```

### Hotwords

Add domain-specific terms in `config/hotwords.txt` (one per line) to improve recognition accuracy when using the Paraformer backend:

```
Transformer
Claude
FunASR
RLHF
```

## Project Structure

```
VibeKeyboard/
├── main.py              # Entry point, menubar app, recording orchestration
├── asr/
│   ├── engine.py        # Three-backend ASR engine (sherpa-onnx / FunASR)
│   ├── formatter.py     # CJK-English spacing, capitalization
│   ├── hotwords.py      # Hotword file management
│   └── polisher.py      # Filler word removal (local regex)
├── audio/
│   └── recorder.py      # Microphone capture (sounddevice, 16kHz PCM)
├── hotkey/
│   └── listener.py      # NSEvent global+local monitor (Option/Enter/ESC)
├── input/
│   └── inserter.py      # NSPasteboard + AppleScript paste
├── ui/
│   ├── overlay.py       # Frosted glass floating window (NSVisualEffectView)
│   └── settings.py      # WKWebView settings UI
├── config/
│   ├── settings.json    # User configuration
│   └── hotwords.txt     # Custom hotword list
├── build_app.sh         # Build .app bundle with python3 hardlink
├── CLAUDE.md            # Known bugs and development notes
└── resources/
    └── appicon.png      # App icon
```

## Tech Stack

- **ASR**: [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) (SenseVoice-ONNX) / [FunASR](https://github.com/modelscope/FunASR) (SenseVoice, Paraformer)
- **Audio**: sounddevice (PortAudio)
- **Menubar**: rumps
- **UI**: PyObjC (NSWindow, NSVisualEffectView, WKWebView)
- **Hotkey**: NSEvent addGlobalMonitor + addLocalMonitor
- **Paste**: NSPasteboard + AppleScript keystroke simulation

## Known Issues

See [CLAUDE.md](CLAUDE.md) for detailed bug history and workarounds.

- Microphone permission requires python3 hardlink inside .app bundle (see `build_app.sh`)
- Auto-paste requires accessibility permission for AppleScript
- First inference with SenseVoice-FunASR is slow (~7s JIT warmup)

## License

MIT
