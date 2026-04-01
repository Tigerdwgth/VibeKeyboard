"""文本插入模块 — NSPasteboard + AppleScript 粘贴"""

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
    def __init__(self):
        self._lock = threading.Lock()

    def insert_text(self, text: str):
        if not text.strip():
            return

        with self._lock:
            if not self._set_clipboard(text):
                logger.error("剪贴板写入失败")
                return

            time.sleep(0.05)

            # 用 AppleScript 粘贴（通过前台应用的菜单命令，不需要辅助功能权限）
            if self._paste_via_menu():
                logger.info(f"已粘贴: {text[:50]}...")
            else:
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

    def _paste_via_menu(self) -> bool:
        """通过前台应用的编辑菜单粘贴（不需要辅助功能权限）"""
        script = '''
            tell application "System Events"
                set frontApp to name of first application process whose frontmost is true
            end tell
            tell application frontApp
                activate
                tell application "System Events"
                    keystroke "v" using command down
                end tell
            end tell
        '''
        try:
            r = subprocess.run(
                ["osascript", "-e", script],
                timeout=5, capture_output=True, text=True,
            )
            if r.returncode == 0:
                return True
            # 如果失败，尝试更简单的方式
            logger.debug(f"menu paste 失败: {r.stderr.strip()}")
        except Exception as e:
            logger.debug(f"menu paste 异常: {e}")

        # 回退：直接 keystroke
        try:
            r = subprocess.run(
                ["osascript", "-e",
                 'tell application "System Events" to keystroke "v" using command down'],
                timeout=5, capture_output=True, text=True,
            )
            return r.returncode == 0
        except Exception:
            return False
