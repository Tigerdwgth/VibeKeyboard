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
DOUBLE_TAP_INTERVAL = 0.35


class HotkeyListener:
    """双击 Option 开始/停止录音，ESC 取消。"""

    def __init__(
        self,
        on_press: Callable[[], None] | None = None,
        on_cancel: Callable[[], None] | None = None,
    ):
        self.on_press = on_press
        self.on_cancel = on_cancel
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
        if event.keyCode() == KEY_ESCAPE:
            logger.info("ESC 按下，取消录音")
            if self.on_cancel:
                try:
                    self.on_cancel()
                except Exception as e:
                    logger.error(f"on_cancel 异常: {e}")

    def start(self):
        if not HAS_APPKIT:
            logger.error("无法启动热键监听：缺少 AppKit")
            return
        m1 = NSEvent.addGlobalMonitorForEventsMatchingMask_handler_(
            NSFlagsChangedMask, self._handle_flags_changed
        )
        m2 = NSEvent.addGlobalMonitorForEventsMatchingMask_handler_(
            NSKeyDownMask, self._handle_key_down
        )
        self._monitors = [m1, m2]
        logger.info("热键监听已启动，双击 Option 录音，ESC 取消")

    def stop(self):
        for m in self._monitors:
            if m:
                NSEvent.removeMonitor_(m)
        self._monitors = []
        logger.info("热键监听已停止")
