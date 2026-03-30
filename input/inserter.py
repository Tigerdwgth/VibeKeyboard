"""文本插入模块 — 通过剪贴板 + Cmd+V 粘贴"""

import logging
import subprocess
import threading
import time

logger = logging.getLogger(__name__)

# macOS 虚拟键码
V_KEY = 0x09  # 'v' 键

try:
    from Quartz import (
        CGEventCreateKeyboardEvent,
        CGEventPost,
        CGEventSetFlags,
        kCGEventFlagMaskCommand,
        kCGHIDEventTap,
    )

    HAS_QUARTZ = True
except ImportError:
    HAS_QUARTZ = False
    logger.warning("pyobjc-framework-Quartz 未安装，将使用 AppleScript 回退方案")


class TextInserter:
    """将文本插入到当前光标位置

    工作流程：保存剪贴板 → 写入文本 → Cmd+V 粘贴 → 恢复剪贴板
    """

    def __init__(self, restore_delay: float = 0.5):
        self.restore_delay = restore_delay
        self._lock = threading.Lock()

    def insert_text(self, text: str):
        """插入文本到当前光标位置"""
        if not text.strip():
            return

        with self._lock:
            # 1. 保存当前剪贴板
            saved = self._get_clipboard()

            # 2. 设置新文本到剪贴板
            self._set_clipboard(text)

            # 短暂等待确保剪贴板已更新
            time.sleep(0.05)

            # 3. 模拟 Cmd+V
            self._simulate_paste()

            # 4. 延迟恢复剪贴板
            if saved is not None:
                threading.Timer(self.restore_delay, self._set_clipboard, [saved]).start()

        logger.info(f"已插入文本: {text[:50]}...")

    def _get_clipboard(self) -> str | None:
        """获取当前剪贴板内容"""
        try:
            result = subprocess.run(
                ["pbpaste"],
                capture_output=True,
                text=True,
                timeout=2,
            )
            return result.stdout
        except Exception:
            return None

    def _set_clipboard(self, text: str):
        """设置剪贴板内容"""
        try:
            process = subprocess.Popen(
                ["pbcopy"],
                stdin=subprocess.PIPE,
            )
            process.communicate(text.encode("utf-8"), timeout=2)
        except Exception as e:
            logger.error(f"设置剪贴板失败: {e}")

    def _simulate_paste(self):
        """模拟 Cmd+V 快捷键"""
        if HAS_QUARTZ:
            self._paste_via_cgevent()
        else:
            self._paste_via_applescript()

    def _paste_via_cgevent(self):
        """使用 CGEvent 模拟 Cmd+V"""
        # Key down
        event_down = CGEventCreateKeyboardEvent(None, V_KEY, True)
        CGEventSetFlags(event_down, kCGEventFlagMaskCommand)
        CGEventPost(kCGHIDEventTap, event_down)

        time.sleep(0.02)

        # Key up
        event_up = CGEventCreateKeyboardEvent(None, V_KEY, False)
        CGEventSetFlags(event_up, kCGEventFlagMaskCommand)
        CGEventPost(kCGHIDEventTap, event_up)

    def _paste_via_applescript(self):
        """AppleScript 回退方案"""
        try:
            subprocess.run(
                [
                    "osascript",
                    "-e",
                    'tell application "System Events" to keystroke "v" using command down',
                ],
                timeout=5,
            )
        except Exception as e:
            logger.error(f"AppleScript 粘贴失败: {e}")
