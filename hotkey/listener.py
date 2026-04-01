"""全局快捷键监听模块 — 双击 Option 触发"""

import logging
import time
from typing import Callable

logger = logging.getLogger(__name__)

try:
    from Cocoa import NSEvent, NSFlagsChangedMask, NSKeyDownMask
    HAS_APPKIT = True
except ImportError:
    HAS_APPKIT = False
    logger.error("pyobjc-framework-Cocoa 未安装")

FLAG_OPTION = 1 << 19
KEY_ESCAPE = 53
KEY_RETURN = 36
DOUBLE_TAP_INTERVAL = 0.35


class HotkeyListener:
    """双击 Option 开始/停止录音，ESC 取消。"""

    def __init__(
        self,
        on_press: Callable[[], None] | None = None,
        on_cancel: Callable[[], None] | None = None,
        on_confirm: Callable[[], None] | None = None,
    ):
        self.on_press = on_press
        self.on_cancel = on_cancel
        self.on_confirm = on_confirm
        self._last_option_up = 0.0
        self._option_held = False
        self._monitors = []

    def _handle_flags_changed(self, event):
        flags = event.modifierFlags()
        option_now = bool(flags & FLAG_OPTION)

        if option_now and not self._option_held:
            self._option_held = True
        elif not option_now and self._option_held:
            self._option_held = False
            now = time.time()
            if now - self._last_option_up < DOUBLE_TAP_INTERVAL:
                self._last_option_up = 0.0
                logger.info("双击 Option 触发")
                if self.on_press:
                    try:
                        self.on_press()
                    except Exception as e:
                        logger.error(f"on_press 异常: {e}")
            else:
                self._last_option_up = now

    def _handle_key_down(self, event):
        keycode = event.keyCode()
        if keycode == KEY_ESCAPE:
            logger.info("ESC 按下，取消录音")
            if self.on_cancel:
                try:
                    self.on_cancel()
                except Exception as e:
                    logger.error(f"on_cancel 异常: {e}")
        elif keycode == KEY_RETURN:
            logger.info("回车按下，确认结果")
            if self.on_confirm:
                try:
                    self.on_confirm()
                except Exception as e:
                    logger.error(f"on_confirm 异常: {e}")

    def _handle_flags_local(self, event):
        """Local monitor wrapper（需要返回 event）"""
        self._handle_flags_changed(event)
        return event

    def _handle_key_local(self, event):
        """Local monitor wrapper（需要返回 event）"""
        self._handle_key_down(event)
        return event

    def start(self):
        if not HAS_APPKIT:
            logger.error("无法启动热键监听：缺少 AppKit")
            return
        # Global monitor: 监听其他应用的按键
        m1 = NSEvent.addGlobalMonitorForEventsMatchingMask_handler_(
            NSFlagsChangedMask, self._handle_flags_changed
        )
        m2 = NSEvent.addGlobalMonitorForEventsMatchingMask_handler_(
            NSKeyDownMask, self._handle_key_down
        )
        # Local monitor: 监听自己应用内的按键（global monitor 收不到自己的）
        m3 = NSEvent.addLocalMonitorForEventsMatchingMask_handler_(
            NSFlagsChangedMask, self._handle_flags_local
        )
        m4 = NSEvent.addLocalMonitorForEventsMatchingMask_handler_(
            NSKeyDownMask, self._handle_key_local
        )
        self._monitors = [m1, m2, m3, m4]
        logger.info("热键监听已启动，双击 Option 录音，回车确认，ESC 取消")

    def stop(self):
        for m in self._monitors:
            if m:
                NSEvent.removeMonitor_(m)
        self._monitors = []
        logger.info("热键监听已停止")
