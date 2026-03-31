#!/usr/bin/env python3
"""VoiceInput — macOS 语音输入工具

基于 FunASR 的中英混合语音输入，双击 Option 开始录音，VAD 静音自动停止。
"""

import json
import logging
import os
import signal
import sys
import threading
import time
from pathlib import Path

# 确保 NSBundle 正确识别 .app bundle（从 launcher script exec 过来时需要）
try:
    import AppKit
    bundle_path = os.environ.get("VOICEINPUT_BUNDLE")
    if bundle_path:
        AppKit.NSBundle.mainBundle().infoDictionary()["CFBundleIdentifier"] = "com.gsj.voiceinput"
except Exception:
    pass

import rumps

from asr.engine import ASREngine
from asr.formatter import TextFormatter
from asr.hotwords import HotwordManager
from audio.recorder import AudioRecorder
from hotkey.listener import HotkeyListener
from input.inserter import TextInserter
from ui.overlay import OverlayWindow
from ui.settings import open_settings

# 项目根目录
BASE_DIR = Path(__file__).parent
CONFIG_DIR = BASE_DIR / "config"

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
    config_file = CONFIG_DIR / "settings.json"
    if config_file.exists():
        with open(config_file, "r", encoding="utf-8") as f:
            return json.load(f)
    return {}


class VoiceInputApp(rumps.App):
    def __init__(self):
        super().__init__(
            name="VoiceInput",
            title="🎤",
        )

        self.config = load_config()

        # 状态
        self._is_recording = False
        self._audio_chunks: list[bytes] = []
        self._silence_start = 0.0
        self._has_voice = False

        # 组件
        self.overlay = OverlayWindow(
            font_size=self.config.get("overlay_font_size", 16)
        )
        self.hotword_manager = HotwordManager(str(CONFIG_DIR / "hotwords.txt"))
        self.formatter = TextFormatter(self.config.get("formatting", {}))
        self.recorder = AudioRecorder()
        self.inserter = TextInserter()

        self.engine = ASREngine(
            hotwords=self.hotword_manager.get_hotwords_string()
        )

        self.hotkey_listener = HotkeyListener(
            on_press=self._on_hotkey_press,
            on_release=self._on_hotkey_release,
            on_cancel=self._on_cancel,
        )

        # 菜单
        self.status_item = rumps.MenuItem("状态: 加载中...")
        self.status_item.set_callback(None)
        self.hotwords_info = rumps.MenuItem(
            f"热词: {len(self.hotword_manager.hotwords)} 个"
        )
        self.hotwords_info.set_callback(None)

        self.menu = [
            self.status_item,
            None,
            self.hotwords_info,
            rumps.MenuItem("设置...", callback=self._open_settings),
            None,
        ]

        self._settings_window = None

    def _update_status(self, status: str):
        status_map = {
            "idle": "状态: 空闲（双击Option录音）",
            "recording": "状态: 录音中...",
            "transcribing": "状态: 识别中...",
            "loading": "状态: 加载模型中...",
            "error": "状态: 错误",
        }
        self.status_item.title = status_map.get(status, f"状态: {status}")
        self.title = "🔴" if status == "recording" else "🎤"

    def _on_hotkey_press(self):
        """双击 Option → 切换录音"""
        if self._is_recording:
            self._stop_and_transcribe()
            return

        if not self.engine.is_ready():
            logger.warning("模型未加载完成")
            return

        self._is_recording = True
        self._audio_chunks = []
        self._has_voice = False
        self._silence_start = 0.0

        self.recorder.start()
        self._update_status("recording")
        self.overlay.show("🎤 正在录音...")

        # 录音收集线程
        threading.Thread(target=self._collect_audio, daemon=True).start()

        logger.info("开始录音")

    def _on_hotkey_release(self):
        pass

    def _on_cancel(self):
        """ESC 取消录音"""
        if not self._is_recording:
            return
        self._is_recording = False
        self.recorder.stop()
        self._audio_chunks = []
        self.overlay.hide()
        self._update_status("idle")
        logger.info("录音已取消 (ESC)")

    def _collect_audio(self):
        """持续收集音频，检测静音自动停止，每 2 秒流式识别"""
        import numpy as np

        silence_threshold = self.config.get("silence_threshold", 500)
        silence_duration = self.config.get("silence_timeout", 2.0)
        max_duration = self.config.get("max_duration", 30)
        stream_interval = 0.5  # 流式识别间隔

        start_time = time.time()
        last_stream_time = start_time

        while self._is_recording:
            chunk = self.recorder.get_chunk(timeout=0.1)
            if chunk is None:
                continue

            self._audio_chunks.append(chunk)

            # 检测音量
            samples = np.frombuffer(chunk, dtype=np.int16)
            volume = np.abs(samples).mean()

            elapsed = time.time() - start_time
            if volume > silence_threshold:
                self._has_voice = True
                self._silence_start = 0.0
                self.overlay.update_text(f"🎤 录音中 {elapsed:.0f}s ...")
            elif self._has_voice:
                if self._silence_start == 0.0:
                    self._silence_start = time.time()
                elif time.time() - self._silence_start > silence_duration:
                    logger.info("检测到静音，自动停止录音")
                    self._stop_and_transcribe()
                    return

            # 流式识别：每 2 秒对已有音频跑一次识别
            if self._has_voice and time.time() - last_stream_time > stream_interval:
                last_stream_time = time.time()
                audio_data = b"".join(self._audio_chunks)
                threading.Thread(
                    target=self._stream_transcribe,
                    args=(audio_data,),
                    daemon=True,
                ).start()

            # 最大时长限制
            if elapsed > max_duration:
                logger.info("达到最大录音时长，自动停止")
                self._stop_and_transcribe()
                return

    def _stream_transcribe(self, audio_data: bytes):
        """流式中间识别（在线程中），结果显示在浮窗"""
        try:
            text = self.engine.transcribe(audio_data, blocking=False)
            if text and self._is_recording:
                self.overlay.update_text(f"🎤 {text}")
                logger.info(f"流式中间结果: {text}")
        except Exception as e:
            logger.error(f"流式识别异常: {e}")

    def _stop_and_transcribe(self):
        """停止录音并转写"""
        if not self._is_recording:
            return

        self._is_recording = False
        self.recorder.stop()
        self._update_status("transcribing")
        self.overlay.update_text("⏳ 识别中...")

        # 合并音频
        audio_data = b"".join(self._audio_chunks)
        if not audio_data:
            self.overlay.hide()
            self._update_status("idle")
            return

        # 异步转写
        threading.Thread(
            target=self._do_transcribe,
            args=(audio_data,),
            daemon=True,
        ).start()

    def _do_transcribe(self, audio_data: bytes):
        """执行转写（在线程中）"""
        try:
            text = self.engine.transcribe(audio_data)

            if not text.strip():
                logger.info("识别结果为空")
                self.overlay.update_text("（未识别到语音）")
                time.sleep(1.5)
                self.overlay.hide()
                self._update_status("idle")
                return

            formatted = self.formatter.format(text)
            logger.info(f"最终结果: {formatted}")

            # 复制到剪贴板
            self.inserter.insert_text(formatted)

            # 浮窗显示结果 3 秒
            self.overlay.update_text(f"✅ {formatted}")
            time.sleep(3)
            self.overlay.hide()
            self._update_status("idle")

        except Exception as e:
            logger.error(f"转写异常: {e}", exc_info=True)
            self.overlay.update_text("❌ 识别出错")
            time.sleep(1.5)
            self.overlay.hide()
            self._update_status("error")

    def _open_settings(self, _):
        """打开设置窗口"""
        open_settings(
            config=dict(self.config),
            hotwords=list(self.hotword_manager.hotwords),
            on_save=self._on_settings_saved,
        )

    def _on_settings_saved(self, new_config, new_hotwords):
        """设置保存回调"""
        self.config = new_config
        self.hotword_manager.hotwords = new_hotwords
        self.hotword_manager.save()
        self.engine.hotwords = self.hotword_manager.get_hotwords_string()
        self.formatter = TextFormatter(self.config.get("formatting", {}))
        self.hotwords_info.title = f"热词: {len(new_hotwords)} 个"
        logger.info("设置已更新")

    @rumps.clicked("退出")
    def _quit(self, _):
        self.cleanup()
        rumps.quit_application()

    def cleanup(self):
        logger.info("正在清理...")
        self.hotkey_listener.stop()
        if self.recorder.is_recording:
            self.recorder.stop()

    def _request_mic_permission(self):
        """尝试短暂打开麦克风来触发系统权限弹窗"""
        try:
            import sounddevice as sd
            logger.info("尝试打开麦克风触发权限弹窗...")
            stream = sd.InputStream(samplerate=16000, channels=1, dtype="int16", blocksize=1600)
            stream.start()
            time.sleep(0.1)
            stream.stop()
            stream.close()
            logger.info("麦克风权限检查完成")
        except Exception as e:
            logger.error(f"麦克风权限检查失败: {e}")
            rumps.notification("VoiceInput", "需要麦克风权限",
                "请在 系统设置 → 隐私与安全 → 麦克风 中授权", sound=True)

    def _setup_app_menu(self):
        """在顶部应用菜单栏添加 VoiceInput 菜单（首选项）"""
        try:
            import AppKit
            import objc

            # 创建菜单 action handler
            class MenuHandler(AppKit.NSObject):
                @objc.python_method
                def initWithCallback_(self, callback):
                    self = objc.super(MenuHandler, self).init()
                    self._callback = callback
                    return self

                def openPrefs_(self, sender):
                    if self._callback:
                        self._callback(None)

            self._menu_handler = MenuHandler.alloc().initWithCallback_(self._open_settings)

            mainMenu = AppKit.NSApp.mainMenu()
            if mainMenu is None:
                mainMenu = AppKit.NSMenu.alloc().init()
                AppKit.NSApp.setMainMenu_(mainMenu)

            appMenu = AppKit.NSMenu.alloc().initWithTitle_("VoiceInput")

            # 首选项 Cmd+, — 指定 target
            prefsItem = AppKit.NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
                "首选项...", "openPrefs:", ","
            )
            prefsItem.setTarget_(self._menu_handler)
            appMenu.addItem_(prefsItem)

            appMenu.addItem_(AppKit.NSMenuItem.separatorItem())

            quitItem = AppKit.NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
                "退出 VoiceInput", "terminate:", "q"
            )
            appMenu.addItem_(quitItem)

            appMenuItem = AppKit.NSMenuItem.alloc().init()
            appMenuItem.setSubmenu_(appMenu)

            if mainMenu.numberOfItems() > 0:
                mainMenu.insertItem_atIndex_(appMenuItem, 0)
            else:
                mainMenu.addItem_(appMenuItem)

            logger.info("应用菜单已添加（首选项 Cmd+,）")
        except Exception as e:
            logger.error(f"添加应用菜单失败: {e}")

    def run(self, **options):
        self.hotkey_listener.start()

        # 后台加载模型 + 请求权限
        def load_model():
            self._request_mic_permission()
            self._update_status("loading")
            self.engine.load_model()
            self._update_status("idle")
            rumps.notification(
                "VoiceInput", "",
                "模型已就绪，双击 Option 开始语音输入",
                sound=True,
            )

        threading.Thread(target=load_model, daemon=True).start()

        # 延迟设置应用菜单（等 NSApp 启动后）
        def setup_menu():
            time.sleep(1)
            try:
                import AppKit
                AppKit.NSOperationQueue.mainQueue().addOperationWithBlock_(self._setup_app_menu)
            except Exception as e:
                logger.error(f"设置菜单失败: {e}")

        threading.Thread(target=setup_menu, daemon=True).start()

        super().run(**options)


def main():
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
