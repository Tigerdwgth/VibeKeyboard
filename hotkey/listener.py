"""全局快捷键监听模块"""

import logging
from typing import Callable

from pynput import keyboard

logger = logging.getLogger(__name__)

# 快捷键名称到 pynput Key 的映射
KEY_MAP = {
    "alt_r": keyboard.Key.alt_r,
    "alt_l": keyboard.Key.alt_l,
    "ctrl_r": keyboard.Key.ctrl_r,
    "ctrl_l": keyboard.Key.ctrl_l,
    "shift_r": keyboard.Key.shift_r,
    "cmd_r": keyboard.Key.cmd_r,
}


class HotkeyListener:
    """按住触发键录音，松开停止

    默认使用 Right Option (alt_r) 作为触发键。
    需要 macOS 辅助功能权限。
    """

    def __init__(
        self,
        trigger_key: str = "alt_r",
        on_press: Callable[[], None] | None = None,
        on_release: Callable[[], None] | None = None,
    ):
        self.trigger_key = KEY_MAP.get(trigger_key, keyboard.Key.alt_r)
        self.on_press = on_press
        self.on_release = on_release
        self._is_pressed = False
        self._listener: keyboard.Listener | None = None

    def _on_press(self, key):
        if key == self.trigger_key and not self._is_pressed:
            self._is_pressed = True
            logger.debug("触发键按下")
            if self.on_press:
                try:
                    self.on_press()
                except Exception as e:
                    logger.error(f"on_press 回调异常: {e}")

    def _on_release(self, key):
        if key == self.trigger_key and self._is_pressed:
            self._is_pressed = False
            logger.debug("触发键松开")
            if self.on_release:
                try:
                    self.on_release()
                except Exception as e:
                    logger.error(f"on_release 回调异常: {e}")

    def start(self):
        """启动热键监听（守护线程）"""
        self._listener = keyboard.Listener(
            on_press=self._on_press,
            on_release=self._on_release,
        )
        self._listener.daemon = True
        self._listener.start()
        logger.info(f"热键监听已启动，触发键: {self.trigger_key}")

    def stop(self):
        """停止热键监听"""
        if self._listener:
            self._listener.stop()
            self._listener = None
        logger.info("热键监听已停止")

    @property
    def is_pressed(self) -> bool:
        return self._is_pressed
