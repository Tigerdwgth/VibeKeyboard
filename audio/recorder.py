"""麦克风音频采集模块"""

import logging
import queue

import sounddevice as sd

logger = logging.getLogger(__name__)

# FunASR 要求 16kHz 单声道 PCM16
SAMPLE_RATE = 16000
CHANNELS = 1
DTYPE = "int16"
BLOCKSIZE = 1600  # 100ms @ 16kHz


class AudioRecorder:
    def __init__(
        self,
        sample_rate: int = SAMPLE_RATE,
        channels: int = CHANNELS,
        blocksize: int = BLOCKSIZE,
    ):
        self.sample_rate = sample_rate
        self.channels = channels
        self.blocksize = blocksize
        self.audio_queue: queue.Queue[bytes] = queue.Queue()
        self.stream: sd.InputStream | None = None
        self.is_recording = False

    def _callback(self, indata: np.ndarray, frames: int, time_info, status):
        """sounddevice 回调，在音频线程中调用，不可阻塞"""
        if status:
            logger.warning(f"音频状态: {status}")
        # indata shape: (frames, channels), dtype: int16
        self.audio_queue.put(bytes(indata))

    def start(self):
        """开始录音"""
        if self.is_recording:
            return

        self.is_recording = True
        self.audio_queue = queue.Queue()

        self.stream = sd.InputStream(
            samplerate=self.sample_rate,
            channels=self.channels,
            dtype=DTYPE,
            blocksize=self.blocksize,
            callback=self._callback,
        )
        self.stream.start()
        logger.info("录音已开始")

    def stop(self):
        """停止录音"""
        self.is_recording = False
        if self.stream:
            self.stream.stop()
            self.stream.close()
            self.stream = None
        logger.info("录音已停止")

    def get_chunk(self, timeout: float = 0.1) -> bytes | None:
        """获取下一个音频块，超时返回 None"""
        try:
            return self.audio_queue.get(timeout=timeout)
        except queue.Empty:
            return None

    def get_all_audio(self) -> bytes:
        """获取队列中所有音频数据（录音结束后调用）"""
        chunks = []
        while not self.audio_queue.empty():
            try:
                chunks.append(self.audio_queue.get_nowait())
            except queue.Empty:
                break
        return b"".join(chunks)

    @staticmethod
    def list_devices():
        """列出可用音频设备"""
        return sd.query_devices()
