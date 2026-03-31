#!/usr/bin/env python3
"""VoiceInk — macOS 语音输入工具

基于 FunASR 的中英混合语音输入，双击 Option 开始录音，VAD 静音自动停止。
"""

import json
import logging
import signal
import sys
import threading
import time
from pathlib import Path

import numpy as np
import rumps

from asr.engine import ASREngine
from asr.formatter import TextFormatter
from asr.hotwords import HotwordManager
from audio.recorder import AudioRecorder
from hotkey.listener import HotkeyListener
from input.inserter import TextInserter
from ui.overlay import OverlayWindow
from ui.settings import open_settings

BASE_DIR = Path(__file__).parent
CONFIG_DIR = BASE_DIR / "config"

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
    try:
        if config_file.exists():
            with open(config_file, "r", encoding="utf-8") as f:
                return json.load(f)
    except (json.JSONDecodeError, OSError) as e:
        logger.warning(f"配置加载失败，使用默认值: {e}")
    return {}


class VoiceInputApp(rumps.App):
    def __init__(self):
        super().__init__(name="VoiceInput", title="🎤")

        self.config = load_config()
        self._stop_lock = threading.Lock()
        self._is_recording = False
        self._audio_buf = bytearray()
        self._silence_start = 0.0
        self._has_voice = False
        self._stream_busy = False
        self._hide_timer: threading.Timer | None = None

        self.overlay = OverlayWindow(font_size=self.config.get("overlay_font_size", 16))
        self.hotword_manager = HotwordManager(str(CONFIG_DIR / "hotwords.txt"))
        self.formatter = TextFormatter(self.config.get("formatting", {}))
        self.recorder = AudioRecorder()
        self.inserter = TextInserter()
        self.engine = ASREngine(hotwords=self.hotword_manager.get_hotwords_string())

        self.hotkey_listener = HotkeyListener(
            on_press=self._on_hotkey_press,
            on_cancel=self._on_cancel,
        )

        self.status_item = rumps.MenuItem("状态: 加载中...")
        self.status_item.set_callback(None)
        self.hotwords_info = rumps.MenuItem(f"热词: {len(self.hotword_manager.hotwords)} 个")
        self.hotwords_info.set_callback(None)

        self.menu = [
            self.status_item,
            None,
            self.hotwords_info,
            rumps.MenuItem("设置...", callback=self._open_settings),
            None,
        ]

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

    def _cancel_hide_timer(self):
        if self._hide_timer:
            self._hide_timer.cancel()
            self._hide_timer = None

    def _on_hotkey_press(self):
        if self._is_recording:
            self._stop_and_transcribe()
            return
        if not self.engine.is_ready():
            logger.warning("模型未加载完成")
            return

        self._cancel_hide_timer()
        self._is_recording = True
        self._audio_buf = bytearray()
        self._has_voice = False
        self._silence_start = 0.0

        self.recorder.start()
        self._update_status("recording")
        self.overlay.show("🎤 正在录音...")

        threading.Thread(target=self._collect_audio, daemon=True).start()
        logger.info("开始录音")

    def _on_cancel(self):
        with self._stop_lock:
            if not self._is_recording:
                return
            self._is_recording = False
        self.recorder.stop()
        self._audio_buf = bytearray()
        self.overlay.hide()
        self._update_status("idle")
        logger.info("录音已取消 (ESC)")

    def _collect_audio(self):
        silence_threshold = self.config.get("silence_threshold", 500)
        silence_duration = self.config.get("silence_timeout", 2.0)
        max_duration = self.config.get("max_duration", 30)
        stream_interval = 0.5

        start_time = time.time()
        last_stream_time = start_time

        try:
            while self._is_recording:
                chunk = self.recorder.get_chunk(timeout=0.1)
                if chunk is None:
                    continue

                self._audio_buf.extend(chunk)

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

                if self._has_voice and not self._stream_busy and time.time() - last_stream_time > stream_interval:
                    last_stream_time = time.time()
                    audio_snapshot = bytes(self._audio_buf)
                    threading.Thread(target=self._stream_transcribe, args=(audio_snapshot,), daemon=True).start()

                if elapsed > max_duration:
                    logger.info("达到最大录音时长，自动停止")
                    self._stop_and_transcribe()
                    return
        except Exception as e:
            logger.error(f"录音线程异常: {e}", exc_info=True)
            self._is_recording = False
            self.recorder.stop()
            self.overlay.hide()
            self._update_status("error")

    def _stream_transcribe(self, audio_data: bytes):
        self._stream_busy = True
        try:
            text = self.engine.transcribe(audio_data, blocking=False)
            if text and self._is_recording:
                self.overlay.update_text(f"🎤 {text}")
        except Exception as e:
            logger.error(f"流式识别异常: {e}")
        finally:
            self._stream_busy = False

    def _stop_and_transcribe(self):
        with self._stop_lock:
            if not self._is_recording:
                return
            self._is_recording = False

        self.recorder.stop()
        self._update_status("transcribing")
        self.overlay.update_text("⏳ 识别中...")

        audio_data = bytes(self._audio_buf)
        if not audio_data:
            self.overlay.hide()
            self._update_status("idle")
            return

        threading.Thread(target=self._do_transcribe, args=(audio_data,), daemon=True).start()

    def _do_transcribe(self, audio_data: bytes):
        try:
            text = self.engine.transcribe(audio_data)

            if not text.strip():
                logger.info("识别结果为空")
                self.overlay.update_text("（未识别到语音）")
                self._hide_timer = threading.Timer(1.5, self.overlay.hide)
                self._hide_timer.start()
                self._update_status("idle")
                return

            formatted = self.formatter.format(text)
            logger.info(f"最终结果: {formatted}")
            self.inserter.insert_text(formatted)

            self.overlay.update_text(f"✅ {formatted}")
            self._hide_timer = threading.Timer(3.0, self.overlay.hide)
            self._hide_timer.start()
            self._update_status("idle")

        except Exception as e:
            logger.error(f"转写异常: {e}", exc_info=True)
            self.overlay.update_text("❌ 识别出错")
            self._hide_timer = threading.Timer(1.5, self.overlay.hide)
            self._hide_timer.start()
            self._update_status("error")

    def _open_settings(self, _):
        open_settings(
            config=dict(self.config),
            hotwords=list(self.hotword_manager.hotwords),
            on_save=self._on_settings_saved,
        )

    def _on_settings_saved(self, new_config, new_hotwords):
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
        self._cancel_hide_timer()
        if self.recorder.is_recording:
            self.recorder.stop()

    def _request_mic_permission(self):
        try:
            import sounddevice as sd
            stream = sd.InputStream(samplerate=16000, channels=1, dtype="int16", blocksize=1600)
            stream.start()
            time.sleep(0.1)
            stream.stop()
            stream.close()
        except Exception as e:
            logger.error(f"麦克风权限检查失败: {e}")

    def _setup_app_menu(self):
        try:
            import AppKit
            import objc

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
        except Exception as e:
            logger.error(f"添加应用菜单失败: {e}")

    def run(self, **options):
        self.hotkey_listener.start()

        def load_model():
            self._request_mic_permission()
            self._update_status("loading")
            self.engine.load_model()
            self._update_status("idle")
            rumps.notification("VoiceInput", "", "模型已就绪，双击 Option 开始语音输入", sound=True)

        threading.Thread(target=load_model, daemon=True).start()

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
