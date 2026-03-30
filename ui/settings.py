"""设置窗口 — 使用 PyObjC 原生 NSWindow"""

import json
import logging
import threading
from pathlib import Path

logger = logging.getLogger(__name__)

try:
    import AppKit
    import Foundation

    HAS_APPKIT = True
except ImportError:
    HAS_APPKIT = False


CONFIG_DIR = Path(__file__).parent.parent / "config"


class SettingsManager:
    """配置管理器"""

    def __init__(self):
        self.config_file = CONFIG_DIR / "settings.json"
        self.config = self._load()

    def _load(self) -> dict:
        if self.config_file.exists():
            with open(self.config_file, "r", encoding="utf-8") as f:
                return json.load(f)
        return self._defaults()

    def _defaults(self) -> dict:
        return {
            "hotkey": "alt_r",
            "hotkey_mode": "hold",
            "asr_mode": "2pass",
            "server_host": "127.0.0.1",
            "server_port": 10095,
            "ncpu": 4,
            "auto_start_server": True,
            "overlay_font_size": 16,
            "formatting": {
                "auto_spacing": True,
                "capitalize": True,
                "replacements": {},
            },
        }

    def save(self):
        self.config_file.parent.mkdir(parents=True, exist_ok=True)
        with open(self.config_file, "w", encoding="utf-8") as f:
            json.dump(self.config, f, ensure_ascii=False, indent=4)

    def get(self, key: str, default=None):
        return self.config.get(key, default)

    def set(self, key: str, value):
        self.config[key] = value
        self.save()


def open_config_in_editor():
    """在默认编辑器中打开配置文件"""
    import subprocess

    config_file = CONFIG_DIR / "settings.json"
    subprocess.Popen(["open", str(config_file)])


def open_hotwords_in_editor():
    """在默认编辑器中打开热词文件"""
    import subprocess

    hotwords_file = CONFIG_DIR / "hotwords.txt"
    subprocess.Popen(["open", str(hotwords_file)])
