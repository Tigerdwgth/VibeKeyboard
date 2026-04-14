#!/usr/bin/env python3
"""hotword_infer.py — SenseVoice hotword inference via funasr_onnx.

Called by VibeKeyboard Swift app when hotwords are configured.
Reads PCM audio from stdin, outputs recognized text to stdout.

Usage:
    echo <pcm_data> | python3 hotword_infer.py --model_dir <path> \
        --hotwords "词1 词2" --score 1.0 --language auto

Input: raw 16-bit PCM audio at 16kHz mono via stdin
Output: recognized text on stdout (single line)
"""

import sys
import argparse
import tempfile
import os
import wave
import struct

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model_dir", required=True, help="Path to SenseVoiceSmall_hotword model")
    parser.add_argument("--hotwords", default="", help="Space-separated hotwords")
    parser.add_argument("--score", type=float, default=1.0, help="Hotword boost score")
    parser.add_argument("--language", default="auto", help="Language: auto/zh/en")
    parser.add_argument("--audio", default="", help="Path to PCM file (if not stdin)")
    args = parser.parse_args()

    # Read PCM data
    if args.audio and os.path.exists(args.audio):
        with open(args.audio, "rb") as f:
            pcm_data = f.read()
    else:
        pcm_data = sys.stdin.buffer.read()

    if len(pcm_data) < 3200:  # < 0.1s
        print("", end="")
        return

    # Write as WAV to temp file (funasr_onnx needs file path)
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
        tmp_path = tmp.name
        n_samples = len(pcm_data) // 2
        with wave.open(tmp_path, "wb") as wf:
            wf.setnchannels(1)
            wf.setsampwidth(2)
            wf.setframerate(16000)
            wf.writeframes(pcm_data)

    try:
        from funasr_onnx import SenseVoiceSmallHot
        model = SenseVoiceSmallHot(args.model_dir, batch_size=1)
        res = model(
            tmp_path,
            hotwords_str=args.hotwords,
            hotwords_score=args.score,
            language=args.language,
        )
        if res and len(res) > 0:
            text = res[0].get("text", "")
            print(text, end="")
        else:
            print("", end="")
    except Exception as e:
        print(f"[hotword_infer] Error: {e}", file=sys.stderr)
        print("", end="")
    finally:
        os.unlink(tmp_path)

if __name__ == "__main__":
    main()
