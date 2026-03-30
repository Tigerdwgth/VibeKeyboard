#!/usr/bin/env python3
"""VoiceInput — macOS 语音输入工具

基于 FunASR 的中英混合语音输入，按住 Right Option 录音，松开插入文本。
"""

import asyncio
import json
import logging
import os
import signal
import sys
import threading
from pathlib import Path

import rumps

from asr.client import ASRClient
from asr.formatter import TextFormatter
from asr.hotwords import HotwordManager
from audio.recorder import AudioRecorder
from hotkey.listener import HotkeyListener
from input.inserter import TextInserter
from server.launcher import FunASRServerLauncher
from ui.overlay import OverlayWindow
from ui.settings import open_config_in_editor, open_hotwords_in_editor

# 项目根目录
BASE_DIR = Path(__file__).parent
CONFIG_DIR = BASE_DIR / "config"
RESOURCES_DIR = BASE_DIR / "resources"

# 日志配置
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(name)s] %(levelname)s: %(message)s",
    handlers=[
        logging.StreamHandler(),
        logging.FileHandler(BASE_DIR / "voice-input.log", encoding="utf-8"),
    ],
)
logger = logging.getLogger("VoiceInput")


def load_config() -> dict:
    """加载用户配置"""
    config_file = CONFIG_DIR / "settings.json"
    if config_file.exists():
        with open(config_file, "r", encoding="utf-8") as f:
            return json.load(f)
    return {}


class VoiceInputApp(rumps.App):
    """语音输入菜单栏应用"""

    def __init__(self):
        # 尝试加载图标，不存在则用文字
        icon_path = RESOURCES_DIR / "icon.png"
        icon = str(icon_path) if icon_path.exists() else None

        super().__init__(
            name="VoiceInput",
            icon=icon,
            title="🎤" if icon is None else None,
            template=True,
        )

        self.config = load_config()

        # 状态
        self._is_recording = False
        self._asr_thread: threading.Thread | None = None
        self._partial_text = ""
        self._final_text = ""
        self._recording_event = threading.Event()

        # 组件初始化
        self._init_components()

        # 菜单
        self.status_item = rumps.MenuItem("状态: 空闲")
        self.status_item.set_callback(None)
        self.server_item = rumps.MenuItem("启动服务", callback=self._toggle_server)
        self.hotwords_info = rumps.MenuItem(
            f"热词: {len(self.hotword_manager.hotwords)} 个"
        )
        self.hotwords_info.set_callback(None)

        self.menu = [
            self.status_item,
            None,
            self.server_item,
            self.hotwords_info,
            rumps.MenuItem("编辑热词...", callback=self._edit_hotwords),
            rumps.MenuItem("编辑设置...", callback=self._edit_settings),
            None,
        ]

    def _init_components(self):
        """初始化所有组件"""
        # 浮窗
        self.overlay = OverlayWindow(
            font_size=self.config.get("overlay_font_size", 16)
        )

        # FunASR 服务
        self.server = FunASRServerLauncher(
            host=self.config.get("server_host", "127.0.0.1"),
            port=self.config.get("server_port", 10095),
            ncpu=self.config.get("ncpu", 4),
            hotword_file=str(CONFIG_DIR / "hotwords.txt"),
        )

        # 热词
        self.hotword_manager = HotwordManager(str(CONFIG_DIR / "hotwords.txt"))

        # 格式化
        self.formatter = TextFormatter(self.config.get("formatting", {}))

        # 录音
        self.recorder = AudioRecorder()

        # 文本插入
        self.inserter = TextInserter()

        # 快捷键
        self.hotkey_listener = HotkeyListener(
            trigger_key=self.config.get("hotkey", "alt_r"),
            on_press=self._on_hotkey_press,
            on_release=self._on_hotkey_release,
        )

    def _update_status(self, status: str):
        """更新状态显示"""
        status_map = {
            "idle": "状态: 空闲",
            "recording": "状态: 录音中...",
            "transcribing": "状态: 识别中...",
            "error": "状态: 错误",
        }
        self.status_item.title = status_map.get(status, f"状态: {status}")

        if status == "recording":
            self.title = "🔴" if not self.icon else None
        else:
            self.title = "🎤" if not self.icon else None

    def _on_hotkey_press(self):
        """快捷键按下 → 开始录音"""
        if self._is_recording:
            return

        if not self.server.is_running():
            rumps.notification(
                "VoiceInput",
                "FunASR 服务未运行",
                "请先启动服务",
                sound=False,
            )
            return

        self._is_recording = True
        self._partial_text = ""
        self._final_text = ""
        self._recording_event.clear()

        # 开始录音
        self.recorder.start()
        self._update_status("recording")

        # 显示浮窗
        self.overlay.show("🎤 正在录音...")

        # 启动 ASR 流式转写线程
        self._asr_thread = threading.Thread(
            target=self._run_asr_streaming,
            daemon=True,
        )
        self._asr_thread.start()

        logger.info("开始录音")

    def _on_hotkey_release(self):
        """快捷键松开 → 停止录音，等待最终结果"""
        if not self._is_recording:
            return

        self._is_recording = False
        self.recorder.stop()
        self._update_status("transcribing")

        logger.info("录音结束，等待最终结果")

    def _run_asr_streaming(self):
        """在独立线程中运行 ASR 流式转写"""
        server_url = f"ws://{self.config.get('server_host', '127.0.0.1')}:{self.config.get('server_port', 10095)}"

        client = ASRClient(
            server_url=server_url,
            mode=self.config.get("asr_mode", "2pass"),
            hotwords=self.hotword_manager.get_hotwords_string(),
        )

        client.on_partial_result = self._on_partial_result
        client.on_final_result = self._on_final_result
        client.on_error = self._on_error

        loop = asyncio.new_event_loop()
        try:
            loop.run_until_complete(client.transcribe_stream(self.recorder))
        except Exception as e:
            logger.error(f"ASR 线程异常: {e}")
        finally:
            loop.close()

    def _on_partial_result(self, text: str):
        """收到流式中间结果"""
        self._partial_text = text
        logger.debug(f"中间结果: {text}")
        self.overlay.update_text(f"🎤 {text}")

    def _on_final_result(self, text: str):
        """收到最终结果 → 格式化并插入"""
        self.overlay.hide()

        if not text.strip():
            logger.info("识别结果为空")
            self._update_status("idle")
            return

        # 格式化
        formatted = self.formatter.format(text)
        logger.info(f"最终结果: {formatted}")

        # 插入文本
        self.inserter.insert_text(formatted)
        self._update_status("idle")

    def _on_error(self, error: str):
        """ASR 错误回调"""
        self.overlay.hide()
        logger.error(f"ASR 错误: {error}")
        self._update_status("error")
        rumps.notification("VoiceInput", "识别错误", error, sound=False)

    def _toggle_server(self, sender):
        """启动/停止 FunASR 服务"""
        if self.server.is_running():
            self.server.stop()
            sender.title = "启动服务"
            rumps.notification("VoiceInput", "", "FunASR 服务已停止", sound=False)
        else:
            sender.title = "正在启动..."

            def start_in_thread():
                success = self.server.start(
                    on_progress=lambda msg: logger.info(msg)
                )
                if success:
                    sender.title = "停止服务"
                    rumps.notification(
                        "VoiceInput", "", "FunASR 服务已就绪", sound=False
                    )
                else:
                    sender.title = "启动服务"
                    rumps.notification(
                        "VoiceInput", "启动失败", "请检查日志", sound=False
                    )

            threading.Thread(target=start_in_thread, daemon=True).start()

    def _edit_hotwords(self, _):
        """打开热词文件编辑"""
        open_hotwords_in_editor()

    def _edit_settings(self, _):
        """打开设置文件编辑"""
        open_config_in_editor()

    @rumps.clicked("退出")
    def _quit(self, _):
        """退出应用"""
        self.cleanup()
        rumps.quit_application()

    def cleanup(self):
        """清理资源"""
        logger.info("正在清理...")
        self.hotkey_listener.stop()
        if self.recorder.is_recording:
            self.recorder.stop()
        self.server.stop()

    def run(self, **options):
        """启动应用"""
        # 启动热键监听
        self.hotkey_listener.start()

        # 自动启动 FunASR 服务
        if self.config.get("auto_start_server", True):
            logger.info("自动启动 FunASR 服务...")

            def auto_start():
                success = self.server.start(
                    on_progress=lambda msg: logger.info(msg)
                )
                if success:
                    self.server_item.title = "停止服务"
                    rumps.notification(
                        "VoiceInput", "", "FunASR 服务已就绪，按住 Right Option 开始语音输入",
                        sound=True,
                    )
                else:
                    rumps.notification(
                        "VoiceInput", "服务启动失败",
                        "请手动点击菜单栏启动服务",
                        sound=True,
                    )

            threading.Thread(target=auto_start, daemon=True).start()

        super().run(**options)


def main():
    # 处理 Ctrl+C
    signal.signal(signal.SIGINT, signal.SIG_DFL)

    app = VoiceInputApp()

    try:
        app.run()
    except KeyboardInterrupt:
        app.cleanup()
    except Exception as e:
        logger.error(f"应用异常退出: {e}", exc_info=True)
        app.cleanup()
        sys.exit(1)


if __name__ == "__main__":
    main()
