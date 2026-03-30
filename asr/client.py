"""FunASR WebSocket 流式客户端"""

import asyncio
import json
import logging
from typing import Callable

import websockets

from audio.recorder import AudioRecorder

logger = logging.getLogger(__name__)


class ASRClient:
    """FunASR WebSocket 流式 ASR 客户端

    支持 2pass 模式：
    - online: 流式中间结果（低延迟）
    - offline: 离线最终结果（高精度）
    """

    def __init__(
        self,
        server_url: str = "ws://127.0.0.1:10095",
        mode: str = "2pass",
        hotwords: str = "",
        chunk_size: list[int] | None = None,
        chunk_interval: int = 10,
    ):
        self.server_url = server_url
        self.mode = mode
        self.hotwords = hotwords
        self.chunk_size = chunk_size or [5, 10, 5]
        self.chunk_interval = chunk_interval

        # 回调函数
        self.on_partial_result: Callable[[str], None] | None = None
        self.on_final_result: Callable[[str], None] | None = None
        self.on_error: Callable[[str], None] | None = None

    def _build_config(self) -> dict:
        """构建 WebSocket 初始配置消息"""
        return {
            "mode": self.mode,
            "chunk_size": self.chunk_size,
            "chunk_interval": self.chunk_interval,
            "audio_fs": 16000,
            "wav_format": "pcm",
            "is_speaking": True,
            "hotwords": self.hotwords,
            "itn": True,
        }

    async def transcribe_stream(self, recorder: AudioRecorder):
        """流式转写：边录音边发送，实时接收结果

        Args:
            recorder: 已启动的 AudioRecorder 实例
        """
        try:
            async with websockets.connect(
                self.server_url,
                max_size=None,
                ping_interval=None,
            ) as ws:
                # 发送配置
                config = self._build_config()
                await ws.send(json.dumps(config))
                logger.info(f"ASR 会话已建立，模式: {self.mode}")

                # 并发发送音频和接收结果
                send_task = asyncio.create_task(self._send_audio(ws, recorder))
                recv_task = asyncio.create_task(self._recv_results(ws))

                await asyncio.gather(send_task, recv_task)

        except websockets.exceptions.ConnectionClosed as e:
            logger.warning(f"WebSocket 连接关闭: {e}")
        except ConnectionRefusedError:
            error_msg = "无法连接到 FunASR 服务，请确保服务已启动"
            logger.error(error_msg)
            if self.on_error:
                self.on_error(error_msg)
        except Exception as e:
            logger.error(f"ASR 流式转写异常: {e}")
            if self.on_error:
                self.on_error(str(e))

    async def _send_audio(self, ws, recorder: AudioRecorder):
        """持续发送音频块到 WebSocket"""
        loop = asyncio.get_event_loop()

        while recorder.is_recording:
            chunk = await loop.run_in_executor(None, recorder.get_chunk, 0.1)
            if chunk:
                await ws.send(chunk)

        # 发送结束信号
        end_msg = json.dumps({"is_speaking": False})
        await ws.send(end_msg)
        logger.info("音频发送完成，等待最终结果")

    async def _recv_results(self, ws):
        """接收 ASR 识别结果"""
        async for message in ws:
            try:
                result = json.loads(message)
            except json.JSONDecodeError:
                logger.warning(f"非 JSON 消息: {message[:100]}")
                continue

            text = result.get("text", "")
            mode = result.get("mode", "")
            is_final = result.get("is_final", False)

            logger.debug(f"ASR 结果 [{mode}]: {text}")

            if mode == "2pass-online" and self.on_partial_result:
                # 流式中间结果
                self.on_partial_result(text)
            elif mode == "2pass-offline" and self.on_final_result:
                # 离线最终结果
                self.on_final_result(text)
            elif mode == "online" and self.on_partial_result:
                self.on_partial_result(text)
            elif mode == "offline" and self.on_final_result:
                self.on_final_result(text)

            if is_final:
                logger.info("收到最终结果，ASR 会话结束")
                break

    async def transcribe_audio(self, audio_data: bytes) -> str | None:
        """离线转写一段音频（非流式）

        Args:
            audio_data: PCM16 音频数据

        Returns:
            识别文本，失败返回 None
        """
        try:
            async with websockets.connect(
                self.server_url,
                max_size=None,
                ping_interval=None,
            ) as ws:
                config = {
                    "mode": "offline",
                    "audio_fs": 16000,
                    "wav_format": "pcm",
                    "is_speaking": True,
                    "hotwords": self.hotwords,
                    "itn": True,
                }
                await ws.send(json.dumps(config))
                await ws.send(audio_data)
                await ws.send(json.dumps({"is_speaking": False}))

                async for message in ws:
                    result = json.loads(message)
                    if result.get("is_final") or result.get("mode") == "offline":
                        return result.get("text", "")

        except Exception as e:
            logger.error(f"离线转写异常: {e}")
            return None


def run_streaming_transcription(
    recorder: AudioRecorder,
    client: ASRClient,
    loop: asyncio.AbstractEventLoop | None = None,
):
    """在独立线程中运行流式转写

    在新的 asyncio 事件循环中运行，适合从非异步代码调用。
    """
    if loop is None:
        loop = asyncio.new_event_loop()

    asyncio.set_event_loop(loop)
    try:
        loop.run_until_complete(client.transcribe_stream(recorder))
    finally:
        loop.close()
