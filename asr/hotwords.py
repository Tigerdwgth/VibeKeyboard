"""热词管理模块"""

import logging
from pathlib import Path

logger = logging.getLogger(__name__)


class HotwordManager:
    """管理 FunASR 热词列表

    热词文件格式：每行一个热词，# 开头为注释
    FunASR 接受空格分隔的热词字符串
    """

    def __init__(self, hotwords_file: str = "config/hotwords.txt"):
        self.hotwords_file = Path(hotwords_file)
        self.hotwords: list[str] = []
        self.load()

    def load(self):
        """从文件加载热词"""
        try:
            if self.hotwords_file.exists():
                with open(self.hotwords_file, "r", encoding="utf-8") as f:
                    self.hotwords = [
                        line.strip()
                        for line in f
                        if line.strip() and not line.strip().startswith("#")
                    ]
                logger.info(f"已加载 {len(self.hotwords)} 个热词")
        except Exception as e:
            logger.error(f"加载热词失败: {e}")
            self.hotwords = []

    def save(self):
        """保存热词到文件"""
        self.hotwords_file.parent.mkdir(parents=True, exist_ok=True)
        with open(self.hotwords_file, "w", encoding="utf-8") as f:
            for word in self.hotwords:
                f.write(word + "\n")

    def add(self, word: str):
        word = word.strip()
        if word and word not in self.hotwords:
            self.hotwords.append(word)
            self.save()

    def remove(self, word: str):
        self.hotwords = [w for w in self.hotwords if w != word.strip()]
        self.save()

    def get_hotwords_string(self) -> str:
        """返回 FunASR WebSocket 配置所需的热词字符串"""
        return " ".join(self.hotwords)

    def import_from_file(self, filepath: str):
        """从外部文件导入热词"""
        with open(filepath, "r", encoding="utf-8") as f:
            for line in f:
                word = line.strip()
                if word and not word.startswith("#") and word not in self.hotwords:
                    self.hotwords.append(word)
        self.save()
