"""FunASR WebSocket Server 生命周期管理"""

import logging
import os
import signal
import socket
import subprocess
import sys
import time
from pathlib import Path

logger = logging.getLogger(__name__)

# FunASR runtime 脚本在 GitHub 仓库中的位置
FUNASR_RUNTIME_REPO = "https://github.com/modelscope/FunASR.git"
FUNASR_SERVER_SCRIPT = "funasr_wss_server.py"

# 默认模型名称（ModelScope 会自动下载）
DEFAULT_MODELS = {
    "asr_model": "iic/speech_paraformer-large_asr_nat-zh-cn-16k-common-vocab8404-pytorch",
    "asr_model_online": "iic/speech_paraformer-large_asr_nat-zh-cn-16k-common-vocab8404-online",
    "vad_model": "iic/speech_fsmn_vad_zh-cn-16k-common-pytorch",
    "punc_model": "iic/punc_ct-transformer_cn-en-common-vocab471067-large",
}


class FunASRServerLauncher:
    def __init__(
        self,
        host: str = "127.0.0.1",
        port: int = 10095,
        ncpu: int = 4,
        device: str = "cpu",
        hotword_file: str | None = None,
    ):
        self.host = host
        self.port = port
        self.ncpu = ncpu
        self.device = device
        self.hotword_file = hotword_file
        self.process: subprocess.Popen | None = None

        # 本地缓存目录
        self.cache_dir = Path.home() / ".cache" / "voice-input-mac"
        self.runtime_dir = self.cache_dir / "funasr_runtime"

    def _ensure_server_script(self) -> Path:
        """确保 FunASR WebSocket 服务脚本存在，不存在则从 GitHub 下载"""
        script_path = self.runtime_dir / FUNASR_SERVER_SCRIPT

        if script_path.exists():
            return script_path

        logger.info("首次运行，正在下载 FunASR WebSocket 服务脚本...")
        self.runtime_dir.mkdir(parents=True, exist_ok=True)

        # 只下载 runtime/python/websocket 目录下的文件（sparse checkout）
        base_url = "https://raw.githubusercontent.com/modelscope/FunASR/main/runtime/python/websocket"
        files_to_download = [
            FUNASR_SERVER_SCRIPT,
        ]

        for fname in files_to_download:
            url = f"{base_url}/{fname}"
            target = self.runtime_dir / fname
            try:
                subprocess.run(
                    ["curl", "-sL", "-o", str(target), url],
                    check=True,
                    timeout=60,
                )
                logger.info(f"已下载: {fname}")
            except subprocess.CalledProcessError as e:
                raise RuntimeError(f"下载 {fname} 失败: {e}") from e

        if not script_path.exists():
            raise RuntimeError(f"服务脚本下载失败: {script_path}")

        return script_path

    def _build_command(self, script_path: Path) -> list[str]:
        """构建服务启动命令"""
        cmd = [
            sys.executable,
            str(script_path),
            "--host", self.host,
            "--port", str(self.port),
            "--device", self.device,
            "--ngpu", "0",
            "--ncpu", str(self.ncpu),
        ]

        for key, model_name in DEFAULT_MODELS.items():
            cmd.extend([f"--{key}", model_name])

        if self.hotword_file and os.path.exists(self.hotword_file):
            cmd.extend(["--hotword", self.hotword_file])

        return cmd

    def _wait_for_port(self, timeout: float = 120.0) -> bool:
        """等待服务端口可用"""
        start = time.time()
        while time.time() - start < timeout:
            try:
                with socket.create_connection((self.host, self.port), timeout=1):
                    return True
            except (ConnectionRefusedError, OSError):
                time.sleep(1)

            # 检查进程是否异常退出
            if self.process and self.process.poll() is not None:
                logger.error(f"FunASR 服务进程异常退出，返回码: {self.process.returncode}")
                return False

        return False

    def start(self, on_progress=None) -> bool:
        """启动 FunASR 服务

        Args:
            on_progress: 可选回调，用于报告启动进度 fn(message: str)

        Returns:
            是否启动成功
        """
        if self.is_running():
            logger.info("FunASR 服务已在运行中")
            return True

        try:
            script_path = self._ensure_server_script()
        except RuntimeError as e:
            logger.error(f"获取服务脚本失败: {e}")
            return False

        cmd = self._build_command(script_path)
        logger.info(f"启动 FunASR 服务: {' '.join(cmd)}")

        if on_progress:
            on_progress("正在启动 FunASR 服务（首次运行需下载模型，可能需要几分钟）...")

        try:
            self.process = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                cwd=str(self.runtime_dir),
            )
        except Exception as e:
            logger.error(f"启动 FunASR 服务失败: {e}")
            return False

        if on_progress:
            on_progress("等待 FunASR 服务就绪...")

        if self._wait_for_port(timeout=180):
            logger.info(f"FunASR 服务已就绪: ws://{self.host}:{self.port}")
            if on_progress:
                on_progress("FunASR 服务已就绪")
            return True
        else:
            logger.error("FunASR 服务启动超时")
            self.stop()
            return False

    def stop(self):
        """停止 FunASR 服务"""
        if self.process is None:
            return

        logger.info("正在停止 FunASR 服务...")

        try:
            self.process.send_signal(signal.SIGTERM)
            self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            logger.warning("SIGTERM 超时，强制终止")
            self.process.kill()
            self.process.wait(timeout=5)
        except Exception as e:
            logger.warning(f"停止服务异常: {e}")

        self.process = None
        logger.info("FunASR 服务已停止")

    def is_running(self) -> bool:
        """检查服务是否正在运行"""
        if self.process is None or self.process.poll() is not None:
            return False

        try:
            with socket.create_connection((self.host, self.port), timeout=1):
                return True
        except (ConnectionRefusedError, OSError):
            return False

    def restart(self, on_progress=None) -> bool:
        """重启服务"""
        self.stop()
        time.sleep(1)
        return self.start(on_progress=on_progress)
