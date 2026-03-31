"""ASR 引擎 — 支持 SeACo-Paraformer 和 SenseVoice 双后端"""

import logging
import os
import threading
import time
from pathlib import Path
from typing import Callable

import numpy as np

logger = logging.getLogger(__name__)

# 模型预估大小（MB），用于进度估算
_MODEL_SIZES = {
    "iic/SenseVoiceSmall": 900,
    "iic/speech_seaco_paraformer_large_asr_nat-zh-cn-16k-common-vocab8404-pytorch": 950,
    "iic/speech_fsmn_vad_zh-cn-16k-common-pytorch": 15,
    "iic/punc_ct-transformer_cn-en-common-vocab471067-large": 1100,
}

BACKENDS = {
    "paraformer": {
        "name": "SeACo-Paraformer",
        "model": "iic/speech_seaco_paraformer_large_asr_nat-zh-cn-16k-common-vocab8404-pytorch",
        "vad_model": "iic/speech_fsmn_vad_zh-cn-16k-common-pytorch",
        "punc_model": "iic/punc_ct-transformer_cn-en-common-vocab471067-large",
        "hotword": True,
    },
    "sensevoice": {
        "name": "SenseVoice-Small",
        "model": "iic/SenseVoiceSmall",
        "vad_model": "iic/speech_fsmn_vad_zh-cn-16k-common-pytorch",
        "punc_model": None,  # SenseVoice 自带标点
        "hotword": False,
    },
}


class ASREngine:
    """双后端 ASR 引擎，支持运行时切换"""

    def __init__(self, backend: str = "sensevoice", hotwords: str = ""):
        self.backend_key = backend
        self.hotwords = hotwords
        self.model = None
        self._lock = threading.Lock()
        self._current_backend = None
        self.on_progress: Callable[[str], None] | None = None  # 进度回调

    def _get_cache_dir_size(self, model_id: str) -> float:
        """获取模型缓存目录大小（MB）"""
        cache_base = Path.home() / ".cache" / "modelscope" / "hub" / "models"
        model_dir = cache_base / model_id.replace("/", "/")
        temp_dir = cache_base / "._____temp" / model_id.replace("/", "/")
        total = 0
        for d in [model_dir, temp_dir]:
            if d.exists():
                for f in d.rglob("*"):
                    if f.is_file():
                        total += f.stat().st_size
        return total / (1024 * 1024)

    def _needs_download(self, model_id: str) -> bool:
        """检查模型是否需要下载"""
        cache_base = Path.home() / ".cache" / "modelscope" / "hub" / "models"
        model_dir = cache_base / model_id.replace("/", "/")
        if not model_dir.exists():
            return True
        # 检查是否有 model.pt 或 model.safetensors
        for f in model_dir.rglob("*.pt"):
            if f.stat().st_size > 1_000_000:
                return False
        for f in model_dir.rglob("*.safetensors"):
            if f.stat().st_size > 1_000_000:
                return False
        return True

    def _monitor_download(self, model_ids: list[str], stop_event: threading.Event):
        """监控下载进度，通过 on_progress 回调报告"""
        total_expected = sum(_MODEL_SIZES.get(m, 500) for m in model_ids)
        while not stop_event.is_set():
            total_downloaded = sum(self._get_cache_dir_size(m) for m in model_ids)
            pct = min(99, int(total_downloaded / total_expected * 100))
            if self.on_progress:
                self.on_progress(f"下载模型中... {pct}% ({total_downloaded:.0f}/{total_expected}MB)")
            stop_event.wait(0.5)

    def load_model(self, backend: str | None = None):
        """加载模型，自动检测首次下载并显示进度"""
        from funasr import AutoModel

        key = backend or self.backend_key
        if key not in BACKENDS:
            logger.error(f"未知后端: {key}，可选: {list(BACKENDS.keys())}")
            return

        cfg = BACKENDS[key]

        # 检查哪些模型需要下载
        models_to_check = [cfg["model"]]
        if cfg["vad_model"]:
            models_to_check.append(cfg["vad_model"])
        if cfg["punc_model"]:
            models_to_check.append(cfg["punc_model"])

        needs_download = [m for m in models_to_check if self._needs_download(m)]

        # 如果需要下载，启动进度监控
        stop_monitor = threading.Event()
        if needs_download:
            logger.info(f"需要下载模型: {needs_download}")
            if self.on_progress:
                self.on_progress("首次运行，正在下载模型...")
            monitor = threading.Thread(
                target=self._monitor_download,
                args=(needs_download, stop_monitor),
                daemon=True,
            )
            monitor.start()
        else:
            if self.on_progress:
                self.on_progress(f"加载 {cfg['name']}...")

        t0 = time.time()

        kwargs = {
            "model": cfg["model"],
            "device": "cpu",
            "disable_update": True,
        }
        if cfg["vad_model"]:
            kwargs["vad_model"] = cfg["vad_model"]
            kwargs["vad_kwargs"] = {"max_single_segment_time": 30000}
        if cfg["punc_model"]:
            kwargs["punc_model"] = cfg["punc_model"]
        if key == "sensevoice":
            kwargs["trust_remote_code"] = True

        self.model = AutoModel(**kwargs)
        self._current_backend = key

        stop_monitor.set()  # 停止进度监控

        elapsed = time.time() - t0
        logger.info(f"{cfg['name']} 模型加载完成，耗时 {elapsed:.1f}s")
        if self.on_progress:
            self.on_progress(f"{cfg['name']} 已就绪")

    def switch_backend(self, backend: str):
        """切换后端（会重新加载模型）"""
        if backend == self._current_backend:
            logger.info(f"已是 {backend} 后端")
            return
        logger.info(f"切换后端: {self._current_backend} → {backend}")
        self.model = None
        self.backend_key = backend
        self.load_model(backend)

    def is_ready(self) -> bool:
        return self.model is not None

    @property
    def current_backend_name(self) -> str:
        if self._current_backend:
            return BACKENDS[self._current_backend]["name"]
        return "未加载"

    @property
    def supports_hotword(self) -> bool:
        if self._current_backend:
            return BACKENDS[self._current_backend]["hotword"]
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

        logger.info(f"[{self.current_backend_name}] 识别，音频: {len(audio)/sample_rate:.1f}s")
        t0 = time.time()

        with self._lock:
            kwargs = {"input": audio, "batch_size_s": 60}

            if self._current_backend == "paraformer" and self.hotwords:
                kwargs["hotword"] = self.hotwords
            elif self._current_backend == "sensevoice":
                kwargs["language"] = "auto"
                kwargs["use_itn"] = True

            result = self.model.generate(**kwargs)

        elapsed = time.time() - t0

        text = ""
        if result and len(result) > 0 and "text" in result[0]:
            text = result[0]["text"]
            # SenseVoice 输出可能带 <|xx|> 标签，清理掉
            if self._current_backend == "sensevoice":
                import re
                text = re.sub(r"<\|[^|]*\|>", "", text).strip()

        logger.info(f"[{self.current_backend_name}] {elapsed:.2f}s → {text[:60]}")
        return text
