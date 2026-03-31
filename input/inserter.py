"""文本插入模块 — NSPasteboard + 多种粘贴方式"""

import logging
import subprocess
import threading
import time

logger = logging.getLogger(__name__)

try:
    import AppKit
    HAS_APPKIT = True
except ImportError:
    HAS_APPKIT = False

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

V_KEY = 0x09


class TextInserter:
    def __init__(self):
        self._lock = threading.Lock()
        self._accessibility_warned = False

    def insert_text(self, text: str):
        """写入剪贴板并尝试自动粘贴"""
        if not text.strip():
            return

        with self._lock:
            if not self._set_clipboard(text):
                logger.error("剪贴板写入失败")
                return

            time.sleep(0.05)

            # 尝试粘贴：CGEvent → osascript → 仅剪贴板
            if self._paste_cgevent():
                logger.info(f"已粘贴: {text[:50]}...")
            elif self._paste_osascript():
                logger.info(f"已粘贴(osascript): {text[:50]}...")
            else:
                if not self._accessibility_warned:
                    self._accessibility_warned = True
                    self._prompt_accessibility()
                logger.info(f"已复制到剪贴板，请 Cmd+V: {text[:50]}...")

    def _set_clipboard(self, text: str) -> bool:
        if HAS_APPKIT:
            try:
                pb = AppKit.NSPasteboard.generalPasteboard()
                pb.clearContents()
                pb.setString_forType_(text, AppKit.NSPasteboardTypeString)
                return True
            except Exception as e:
                logger.warning(f"NSPasteboard 失败: {e}")
        try:
            p = subprocess.Popen(["pbcopy"], stdin=subprocess.PIPE)
            p.communicate(text.encode("utf-8"), timeout=2)
            return p.returncode == 0
        except Exception as e:
            logger.error(f"pbcopy 失败: {e}")
            return False

    def _paste_cgevent(self) -> bool:
        """用 CGEvent 模拟 Cmd+V（需要辅助功能权限）"""
        if not HAS_QUARTZ:
            return False
        try:
            event_down = CGEventCreateKeyboardEvent(None, V_KEY, True)
            if event_down is None:
                return False
            CGEventSetFlags(event_down, kCGEventFlagMaskCommand)
            CGEventPost(kCGHIDEventTap, event_down)

            time.sleep(0.02)

            event_up = CGEventCreateKeyboardEvent(None, V_KEY, False)
            CGEventSetFlags(event_up, kCGEventFlagMaskCommand)
            CGEventPost(kCGHIDEventTap, event_up)
            return True
        except Exception as e:
            logger.debug(f"CGEvent 粘贴失败: {e}")
            return False

    def _paste_osascript(self) -> bool:
        """用 osascript 模拟 Cmd+V"""
        try:
            r = subprocess.run(
                ["osascript", "-e",
                 'tell application "System Events" to key code 9 using command down'],
                timeout=5, capture_output=True, text=True,
            )
            if r.returncode == 0:
                return True
            logger.debug(f"osascript 失败: {r.stderr.strip()}")
            return False
        except Exception:
            return False

    def _prompt_accessibility(self):
        """引导用户开启辅助功能权限"""
        try:
            # 打开系统设置的辅助功能页面
            subprocess.Popen([
                "open",
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            ])
            if HAS_APPKIT:
                # 弹通知
                from rumps import notification
                notification(
                    "VoiceInput", "需要辅助功能权限",
                    "请在系统设置中允许 VoiceInput 控制电脑，以启用自动粘贴",
                    sound=True,
                )
        except Exception as e:
            logger.error(f"打开辅助功能设置失败: {e}")
