"""ASR 结果后处理格式化"""

import re


class TextFormatter:
    """对 ASR 识别结果进行后处理

    FunASR 的 ct-punc 已处理基本标点，此模块处理额外格式化：
    - 中英文之间加空格
    - 英文首字母大写
    - 自定义替换规则
    """

    def __init__(self, config: dict | None = None):
        self.config = config or {}
        self.replacements: dict[str, str] = self.config.get("replacements", {})

    def format(self, text: str) -> str:
        if not text:
            return text

        if self.config.get("auto_spacing", True):
            text = self._add_cjk_spacing(text)

        if self.config.get("capitalize", True):
            text = self._capitalize_sentences(text)

        text = self._apply_replacements(text)

        return text.strip()

    def _add_cjk_spacing(self, text: str) -> str:
        """中英文之间添加空格"""
        # 中文后接英文
        text = re.sub(r"([\u4e00-\u9fff])([a-zA-Z0-9])", r"\1 \2", text)
        # 英文后接中文
        text = re.sub(r"([a-zA-Z0-9])([\u4e00-\u9fff])", r"\1 \2", text)
        return text

    def _capitalize_sentences(self, text: str) -> str:
        """句首字母大写"""
        # 句子开头
        if text and text[0].isalpha():
            text = text[0].upper() + text[1:]
        # 句号/问号/感叹号后的字母
        text = re.sub(r"(?<=[.!?]\s)([a-z])", lambda m: m.group(1).upper(), text)
        return text

    def _apply_replacements(self, text: str) -> str:
        """应用自定义替换规则"""
        for pattern, replacement in self.replacements.items():
            text = text.replace(pattern, replacement)
        return text
