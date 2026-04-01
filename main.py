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

try:
    import AppKit as _AppKit
    _HAS_APPKIT = True
except ImportError:
    _HAS_APPKIT = False

from asr.engine import ASREngine
from asr.formatter import TextFormatter
from asr.polisher import polish_local, polish_with_llm
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


def _run_on_main(fn):
    """确保 fn 在主线程执行（AppKit-safe）。"""
    if _HAS_APPKIT:
        _AppKit.NSOperationQueue.mainQueue().addOperationWithBlock_(fn)
    else:
        fn()


class VoiceInputApp(rumps.App):
    def __init__(self):
        super().__init__(name="VoiceInput", title="🎤")

        # 保持对 NSStatusBar item 的强引用，防止 GC 回收
        self._status_bar_item = None

        self.config = load_config()
        self._stop_lock = threading.Lock()
        self._is_recording = False
        self._audio_buf = bytearray()
        self._silence_start = 0.0
        self._has_voice = False
        self._stream_busy = False
        self._last_stream_text = ""
        self._last_stream_len = 0
        self._hide_timer: threading.Timer | None = None

        self.overlay = OverlayWindow(font_size=self.config.get("overlay_font_size", 16))
        self.hotword_manager = HotwordManager(str(CONFIG_DIR / "hotwords.txt"))
        self.formatter = TextFormatter(self.config.get("formatting", {}))
        self.recorder = AudioRecorder()
        self.inserter = TextInserter()
        self.engine = ASREngine(
            backend=self.config.get("asr_backend", "sherpa-sensevoice"),
            hotwords=self.hotword_manager.get_hotwords_string(),
        )

        self.hotkey_listener = HotkeyListener(
            on_press=self._on_hotkey_press,
            on_cancel=self._on_cancel,
            on_confirm=self._on_confirm,
        )

        self.status_item = rumps.MenuItem("状态: 加载中...")
        self.status_item.set_callback(None)
        self.hotwords_info = rumps.MenuItem(f"热词: {len(self.hotword_manager.hotwords)} 个")
        self.hotwords_info.set_callback(None)
        self.backend_item = rumps.MenuItem("后端: SenseVoice")
        self.backend_item.set_callback(None)

        self.menu = [
            self.status_item,
            self.backend_item,
            None,
            rumps.MenuItem("切换: SenseVoice-ONNX（最快）", callback=lambda _: self._switch_backend("sherpa-sensevoice")),
            rumps.MenuItem("切换: SenseVoice-FunASR", callback=lambda _: self._switch_backend("sensevoice")),
            rumps.MenuItem("切换: Paraformer（热词）", callback=lambda _: self._switch_backend("paraformer")),
            self.hotwords_info,
            rumps.MenuItem("设置...", callback=self._open_settings),
            None,
        ]

    def _set_title_safe(self, new_title: str):
        """线程安全地设置 menubar title（必须在主线程操作 NSStatusItem）。"""
        def _do():
            try:
                self.title = new_title
                # 双重保险：如果 rumps 内部的 _status_bar 可用，直接操作确保不被 GC
                if hasattr(self, '_nsapp') and self._nsapp:
                    sb = getattr(self._nsapp, '_status_bar', None)
                    if sb:
                        sb.setTitle_(new_title)
            except Exception as e:
                logger.error(f"设置 menubar title 失败: {e}")
        _run_on_main(_do)

    def _update_status(self, status: str):
        status_map = {
            "idle": "状态: 空闲（双击Option录音）",
            "recording": "状态: 录音中...",
            "transcribing": "状态: 识别中...",
            "loading": "状态: 加载模型中...",
            "error": "状态: 错误",
        }
        self.status_item.title = status_map.get(status, f"状态: {status}")
        new_title = "🔴" if status == "recording" else "🎤"
        self._set_title_safe(new_title)

    def _cancel_hide_timer(self):
        if self._hide_timer:
            self._hide_timer.cancel()
            self._hide_timer = None

    def _on_hotkey_press(self):
        """双击 Option：开始/停止录音"""
        if self._is_recording:
            # 再次双击 = 和回车一样，确认并粘贴
            self._confirm_and_paste()
            return
        if not self.engine.is_ready():
            logger.warning("模型未加载完成")
            return

        self._cancel_hide_timer()
        self._is_recording = True
        self._audio_buf = bytearray()
        self._has_voice = False
        self._last_stream_text = ""
        self._last_stream_len = 0

        self.recorder.start()
        self._update_status("recording")
        self.overlay.show("")

        threading.Thread(target=self._collect_audio, daemon=True).start()
        logger.info("开始持续录音（回车确认，ESC 取消）")

    def _on_confirm(self):
        """回车：确认当前识别结果并粘贴"""
        if not self._is_recording:
            return
        self._confirm_and_paste()

    def _confirm_and_paste(self):
        """停止录音，立刻粘贴并关闭浮窗"""
        with self._stop_lock:
            if not self._is_recording:
                return
            self._is_recording = False

        self.recorder.stop()
        text = self._last_stream_text

        # 立刻关闭浮窗
        self.overlay.hide()
        self._update_status("idle")

        if text:
            # 后台做格式化+粘贴（不阻塞）
            threading.Thread(
                target=self._quick_paste,
                args=(text,),
                daemon=True,
            ).start()
        else:
            # 没有流式结果，对全部音频做一次识别
            audio_data = bytes(self._audio_buf)
            if audio_data:
                threading.Thread(target=self._do_transcribe, args=(audio_data,), daemon=True).start()

    def _on_cancel(self):
        """ESC：取消录音"""
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
        stream_interval = 0.2

        last_stream_time = time.time()

        try:
            while self._is_recording:
                chunk = self.recorder.get_chunk(timeout=0.1)
                if chunk is None:
                    continue

                self._audio_buf.extend(chunk)

                samples = np.frombuffer(chunk, dtype=np.int16)
                volume = np.abs(samples).mean()

                if volume > silence_threshold:
                    self._has_voice = True

                # 持续流式识别
                if self._has_voice and not self._stream_busy and time.time() - last_stream_time > stream_interval:
                    last_stream_time = time.time()
                    audio_snapshot = bytes(self._audio_buf)
                    threading.Thread(target=self._stream_transcribe, args=(audio_snapshot,), daemon=True).start()

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
                self._last_stream_text = text
                self._last_stream_len = len(audio_data)
                self.overlay.update_text(f"🎤 {text}")
        except Exception as e:
            logger.error(f"流式识别异常: {e}")
        finally:
            self._stream_busy = False

    def _polish(self, text: str) -> str:
        """去水词：有 LLM 用 LLM，没有用本地规则"""
        llm_url = self.config.get("llm_api_url", "")
        if llm_url:
            return polish_with_llm(text, self.config)
        return polish_local(text)

    def _schedule_hide(self, delay: float):
        """取消旧 timer 再创建新的"""
        self._cancel_hide_timer()
        self._hide_timer = threading.Timer(delay, self.overlay.hide)
        self._hide_timer.start()

    def _quick_paste(self, text: str):
        """格式化 → 润色 → 立刻粘贴，不显示结果浮窗"""
        formatted = self.formatter.format(text)
        polished = self._polish(formatted)
        logger.info(f"快速粘贴: {polished}")
        self.inserter.insert_text(polished)

    def _deliver_result(self, text: str):
        """公共结果输出流程：格式化 → 润色 → 插入 → 展示"""
        formatted = self.formatter.format(text)
        polished = self._polish(formatted)
        logger.info(f"最终结果: {formatted} → {polished}")
        self.inserter.insert_text(polished)
        self.overlay.update_text(f"✅ {polished}")
        self._schedule_hide(3.0)
        self._update_status("idle")

    def _do_transcribe(self, audio_data: bytes):
        try:
            text = self.engine.transcribe(audio_data)

            if not text.strip():
                logger.info("识别结果为空")
                self.overlay.update_text("（未识别到语音）")
                self._schedule_hide(1.5)
                self._update_status("idle")
                return

            self._deliver_result(text)

        except Exception as e:
            logger.error(f"转写异常: {e}", exc_info=True)
            self.overlay.update_text("❌ 识别出错")
            self._schedule_hide(1.5)
            self._update_status("error")

    def _on_model_progress(self, msg):
        """模型加载/下载进度回调"""
        self.overlay.update_text(msg)
        self.status_item.title = msg

    def _switch_backend(self, backend):
        if self._is_recording:
            return
        self._update_status("loading")
        self.backend_item.title = f"后端: 切换中..."

        def do_switch():
            self.engine.on_progress = self._on_model_progress
            self.overlay.show("切换模型中...", show_indicator=False)
            self.engine.switch_backend(backend)
            self.overlay.hide()
            self.engine.on_progress = None

            name = self.engine.current_backend_name
            self.backend_item.title = f"后端: {name}"
            self._update_status("idle")
            rumps.notification("VoiceInput", "", f"已切换到 {name}", sound=False)

        threading.Thread(target=do_switch, daemon=True).start()

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

    def _retain_status_bar(self):
        """获取并保持 NSStatusItem 的强引用，防止 macOS GC 回收导致图标消失。"""
        try:
            if _HAS_APPKIT and hasattr(self, '_nsapp') and self._nsapp:
                sb = getattr(self._nsapp, '_status_bar', None)
                if sb:
                    self._status_bar_item = sb
                    logger.info("已保持 NSStatusItem 强引用")
        except Exception as e:
            logger.warning(f"获取 NSStatusItem 引用失败: {e}")

    def _ensure_regular_app(self):
        """确保以 Regular 模式运行（Dock 图标 + 菜单栏都有）。"""
        try:
            if _HAS_APPKIT:
                app = _AppKit.NSApplication.sharedApplication()
                policy = app.activationPolicy()
                if policy != _AppKit.NSApplicationActivationPolicyRegular:
                    app.setActivationPolicy_(_AppKit.NSApplicationActivationPolicyRegular)
                    logger.info("已切换到 Regular 模式（Dock + 菜单栏）")
        except Exception as e:
            logger.warning(f"设置 Regular 模式失败: {e}")

    def run(self, **options):
        self.hotkey_listener.start()

        def load_model():
            self._request_mic_permission()
            self._update_status("loading")

            self.engine.on_progress = self._on_model_progress
            self.overlay.show("加载模型中...", show_indicator=False)
            self.engine.load_model()
            self.overlay.hide()
            self.engine.on_progress = None

            self.backend_item.title = f"后端: {self.engine.current_backend_name}"
            self._update_status("idle")
            rumps.notification("VoiceInput", "", f"{self.engine.current_backend_name} 已就绪，双击 Option 开始语音输入", sound=True)

        threading.Thread(target=load_model, daemon=True).start()

        def setup_after_launch():
            time.sleep(1)
            try:
                def _post_launch():
                    # 确保 Regular 模式（Dock + 菜单栏都有）
                    self._ensure_regular_app()
                    # 保持 NSStatusItem 强引用
                    self._retain_status_bar()
                    # 设置应用菜单
                    self._setup_app_menu()
                _run_on_main(_post_launch)
            except Exception as e:
                logger.error(f"启动后设置失败: {e}")

        threading.Thread(target=setup_after_launch, daemon=True).start()

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
