"""ASR 引擎 — 支持 sherpa-onnx (默认)、FunASR SenseVoice、FunASR Paraformer 三后端"""

import logging
import re
import threading
import time
from pathlib import Path
from typing import Callable

import numpy as np

_SENSEVOICE_TAG_RE = re.compile(r"<\|[^|]*\|>")

logger = logging.getLogger(__name__)

# sherpa-onnx 模型路径
_SHERPA_MODEL_DIR = Path.home() / ".cache" / "sherpa-onnx" / "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17"
_SHERPA_MODEL_URL = "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17.tar.bz2"

BACKENDS = {
    "sherpa-sensevoice": {
        "name": "SenseVoice-ONNX (快速)",
        "hotword": False,
    },
    "sensevoice": {
        "name": "SenseVoice-FunASR",
        "hotword": False,
    },
    "paraformer": {
        "name": "Paraformer (热词)",
        "hotword": True,
    },
}


class ASREngine:
    """三后端 ASR 引擎，默认 sherpa-onnx"""

    def __init__(self, backend: str = "sherpa-sensevoice", hotwords: str = ""):
        self.backend_key = backend
        self.hotwords = hotwords
        self.model = None
        self._sherpa_recognizer = None
        self._lock = threading.Lock()
        self._current_backend = None
        self.on_progress: Callable[[str], None] | None = None

    def _ensure_sherpa_model(self):
        """确保 sherpa-onnx SenseVoice 模型已下载，带进度显示"""
        model_file = _SHERPA_MODEL_DIR / "model.int8.onnx"
        if model_file.exists():
            return True

        import subprocess
        import urllib.request

        cache_dir = _SHERPA_MODEL_DIR.parent
        cache_dir.mkdir(parents=True, exist_ok=True)
        archive = cache_dir / "sensevoice.tar.bz2"

        logger.info("下载 sherpa-onnx SenseVoice 模型...")

        try:
            # 用 urllib 下载，带进度回调
            req = urllib.request.Request(_SHERPA_MODEL_URL)
            with urllib.request.urlopen(req, timeout=600) as resp:
                total = int(resp.headers.get("Content-Length", 0))
                total_mb = total / (1024 * 1024) if total else 230

                downloaded = 0
                chunk_size = 256 * 1024  # 256KB
                with open(archive, "wb") as f:
                    while True:
                        chunk = resp.read(chunk_size)
                        if not chunk:
                            break
                        f.write(chunk)
                        downloaded += len(chunk)
                        mb = downloaded / (1024 * 1024)
                        pct = int(downloaded / total * 100) if total else 0
                        if self.on_progress:
                            self.on_progress(f"下载模型... {pct}% ({mb:.0f}/{total_mb:.0f}MB)")

            if self.on_progress:
                self.on_progress("解压模型...")
            subprocess.run(
                ["tar", "xjf", str(archive), "-C", str(cache_dir)],
                check=True, timeout=120,
            )
            archive.unlink(missing_ok=True)
            logger.info("sherpa-onnx 模型下载完成")
            return True
        except Exception as e:
            logger.error(f"sherpa-onnx 模型下载失败: {e}")
            archive.unlink(missing_ok=True)
            return False

    def _load_sherpa(self):
        """加载 sherpa-onnx SenseVoice"""
        import sherpa_onnx

        if not self._ensure_sherpa_model():
            raise RuntimeError("sherpa-onnx 模型不可用")

        if self.on_progress:
            self.on_progress("加载 SenseVoice-ONNX...")

        t0 = time.time()
        self._sherpa_recognizer = sherpa_onnx.OfflineRecognizer.from_sense_voice(
            model=str(_SHERPA_MODEL_DIR / "model.int8.onnx"),
            tokens=str(_SHERPA_MODEL_DIR / "tokens.txt"),
            num_threads=4,
            sample_rate=16000,
            feature_dim=80,
            decoding_method="greedy_search",
            language="",  # auto-detect
            use_itn=True,
            provider="cpu",
        )
        self._current_backend = "sherpa-sensevoice"
        self.model = True  # 标记已加载

        elapsed = time.time() - t0
        logger.info(f"SenseVoice-ONNX 加载完成，耗时 {elapsed:.1f}s")

    def _load_funasr(self, key: str):
        """加载 FunASR 后端（sensevoice 或 paraformer）"""
        from funasr import AutoModel

        if self.on_progress:
            self.on_progress(f"加载 {BACKENDS[key]['name']}...")

        t0 = time.time()

        if key == "sensevoice":
            self.model = AutoModel(
                model="iic/SenseVoiceSmall",
                vad_model="iic/speech_fsmn_vad_zh-cn-16k-common-pytorch",
                vad_kwargs={"max_single_segment_time": 30000},
                trust_remote_code=True,
                device="cpu",
                disable_update=True,
            )
        elif key == "paraformer":
            self.model = AutoModel(
                model="iic/speech_seaco_paraformer_large_asr_nat-zh-cn-16k-common-vocab8404-pytorch",
                vad_model="iic/speech_fsmn_vad_zh-cn-16k-common-pytorch",
                punc_model="iic/punc_ct-transformer_cn-en-common-vocab471067-large",
                vad_kwargs={"max_single_segment_time": 30000},
                device="cpu",
                disable_update=True,
            )

        self._current_backend = key
        self._sherpa_recognizer = None

        elapsed = time.time() - t0
        logger.info(f"{BACKENDS[key]['name']} 加载完成，耗时 {elapsed:.1f}s")

    def load_model(self, backend: str | None = None):
        key = backend or self.backend_key
        if key not in BACKENDS:
            logger.error(f"未知后端: {key}，可选: {list(BACKENDS.keys())}")
            return

        t0 = time.time()
        if key == "sherpa-sensevoice":
            self._load_sherpa()
        else:
            self._load_funasr(key)

        elapsed = time.time() - t0
        if self.on_progress:
            self.on_progress(f"{BACKENDS[key]['name']} 已就绪 ({elapsed:.0f}s)")

    def switch_backend(self, backend: str):
        if backend == self._current_backend:
            return
        logger.info(f"切换后端: {self._current_backend} → {backend}")
        self.model = None
        self._sherpa_recognizer = None
        self.backend_key = backend
        self.load_model(backend)

    def is_ready(self) -> bool:
        return self.model is not None

    @property
    def current_backend_name(self) -> str:
        if self._current_backend:
            return BACKENDS.get(self._current_backend, {}).get("name", self._current_backend)
        return "未加载"

    @property
    def supports_hotword(self) -> bool:
        if self._current_backend:
            return BACKENDS.get(self._current_backend, {}).get("hotword", False)
        return False

    def transcribe(self, audio_bytes: bytes, sample_rate: int = 16000, blocking: bool = True) -> str:
        if not self.model:
            return ""

        audio = np.frombuffer(audio_bytes, dtype=np.int16).astype(np.float32)
        audio /= 32768.0

        if len(audio) < sample_rate * 0.3:
            return ""

        if not blocking and self._lock.locked():
            return ""

        duration = len(audio) / sample_rate
        t0 = time.time()

        with self._lock:
            if self._current_backend == "sherpa-sensevoice":
                text = self._transcribe_sherpa(audio, sample_rate)
            else:
                text = self._transcribe_funasr(audio)

        elapsed = time.time() - t0
        logger.info(f"[{self.current_backend_name}] {elapsed:.2f}s → {text[:60]}")
        return text

    def _transcribe_sherpa(self, audio: np.ndarray, sample_rate: int) -> str:
        stream = self._sherpa_recognizer.create_stream()
        stream.accept_waveform(sample_rate, audio)
        self._sherpa_recognizer.decode_stream(stream)
        text = stream.result.text.strip()
        # 清理 SenseVoice 标签
        text = _SENSEVOICE_TAG_RE.sub("", text).strip()
        return text

    def _transcribe_funasr(self, audio: np.ndarray) -> str:
        kwargs = {"input": audio, "batch_size_s": 60}

        if self._current_backend == "paraformer" and self.hotwords:
            kwargs["hotword"] = self.hotwords
        elif self._current_backend == "sensevoice":
            kwargs["language"] = "auto"
            kwargs["use_itn"] = True

        result = self.model.generate(**kwargs)

        text = ""
        if result and len(result) > 0 and "text" in result[0]:
            text = result[0]["text"]
            if self._current_backend == "sensevoice":
                text = _SENSEVOICE_TAG_RE.sub("", text).strip()
        return text
