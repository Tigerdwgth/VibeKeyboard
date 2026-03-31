"""文本插入模块 — osascript set clipboard + 模拟粘贴"""

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


class TextInserter:
    def __init__(self, restore_delay: float = 1.5):
        self.restore_delay = restore_delay
        self._lock = threading.Lock()

    def insert_text(self, text: str):
        """写入剪贴板并尝试自动粘贴"""
        if not text.strip():
            return

        with self._lock:
            # 用 osascript 一次性完成：设置剪贴板 + 粘贴
            success = self._set_and_paste(text)
            if not success:
                # 回退：至少写入剪贴板
                self._set_clipboard(text)
                logger.info("已复制到剪贴板（自动粘贴失败，请手动 Cmd+V）")
                return

        logger.info(f"已插入文本: {text[:50]}...")

    def _set_and_paste(self, text: str) -> bool:
        """用单个 osascript 同时设置剪贴板并粘贴"""
        # 转义文本中的特殊字符
        escaped = text.replace("\\", "\\\\").replace('"', '\\"')
        script = f'''
            set the clipboard to "{escaped}"
            delay 0.1
            tell application "System Events"
                key code 9 using command down
            end tell
        '''
        try:
            result = subprocess.run(
                ["osascript", "-e", script],
                timeout=10,
                capture_output=True,
                text=True,
            )
            if result.returncode != 0:
                logger.warning(f"osascript 返回码 {result.returncode}: {result.stderr.strip()}")
                return False
            return True
        except Exception as e:
            logger.error(f"osascript 执行失败: {e}")
            return False

    def _set_clipboard(self, text: str):
        """回退：仅写入剪贴板"""
        if HAS_APPKIT:
            try:
                pb = AppKit.NSPasteboard.generalPasteboard()
                pb.clearContents()
                pb.setString_forType_(text, AppKit.NSPasteboardTypeString)
                return
            except Exception:
                pass
        try:
            p = subprocess.Popen(["pbcopy"], stdin=subprocess.PIPE)
            p.communicate(text.encode("utf-8"), timeout=2)
        except Exception as e:
            logger.error(f"剪贴板写入失败: {e}")
