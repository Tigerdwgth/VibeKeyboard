"""FunASR 引擎 — 直接使用 Python API，不走 WebSocket"""

import logging
import threading
import time

import numpy as np

logger = logging.getLogger(__name__)


class ASREngine:
    """FunASR 离线识别引擎

    直接加载模型在本地推理，无需 WebSocket 服务。
    """

    def __init__(self, hotwords: str = ""):
        self.hotwords = hotwords
        self.model = None
        self._lock = threading.Lock()

    def load_model(self, on_progress=None):
        """加载模型（首次约 30 秒）"""
        from funasr import AutoModel

        if on_progress:
            on_progress("正在加载 ASR 模型...")

        logger.info("开始加载 FunASR 模型...")
        t0 = time.time()

        self.model = AutoModel(
            model="iic/speech_seaco_paraformer_large_asr_nat-zh-cn-16k-common-vocab8404-pytorch",
            vad_model="iic/speech_fsmn_vad_zh-cn-16k-common-pytorch",
            punc_model="iic/punc_ct-transformer_cn-en-common-vocab471067-large",
            device="cpu",
            disable_update=True,
        )

        elapsed = time.time() - t0
        logger.info(f"FunASR 模型加载完成，耗时 {elapsed:.1f}s")

        if on_progress:
            on_progress("ASR 模型已就绪")

    def is_ready(self) -> bool:
        return self.model is not None

    def transcribe(self, audio_bytes: bytes, sample_rate: int = 16000, blocking: bool = True) -> str:
        """转写 PCM16 音频数据

        Args:
            audio_bytes: int16 PCM 音频数据
            sample_rate: 采样率
            blocking: 是否阻塞等待锁。False 时拿不到锁直接返回空。

        Returns:
            识别文本
        """
        if not self.model:
            logger.error("模型未加载")
            return ""

        audio = np.frombuffer(audio_bytes, dtype=np.int16).astype(np.float32)
        audio /= 32768.0

        if len(audio) < sample_rate * 0.3:
            return ""

        if not blocking and self._lock.locked():
            return ""

        logger.info(f"开始识别，音频时长: {len(audio)/sample_rate:.1f}s")
        t0 = time.time()

        with self._lock:
            result = self.model.generate(
                input=audio,
                batch_size_s=60,
                hotword=self.hotwords if self.hotwords else None,
            )

        elapsed = time.time() - t0
        logger.info(f"识别完成，耗时: {elapsed:.2f}s")

        # 提取文本
        if result and len(result) > 0 and "text" in result[0]:
            text = result[0]["text"]
            logger.info(f"识别结果: {text}")
            return text

        logger.info("识别结果为空")
        return ""
