"""ASR 结果后处理格式化"""

import re

_RE_CJK_ALPHA = re.compile(r"([\u4e00-\u9fff])([a-zA-Z0-9])")
_RE_ALPHA_CJK = re.compile(r"([a-zA-Z0-9])([\u4e00-\u9fff])")
_RE_SENTENCE_START = re.compile(r"(?<=[.!?]\s)([a-z])")


class TextFormatter:
    def __init__(self, config: dict | None = None):
        self.config = config or {}
        self.replacements: dict[str, str] = self.config.get("replacements", {})

    def format(self, text: str) -> str:
        if not text:
            return text

        if self.config.get("auto_spacing", True):
            text = _RE_CJK_ALPHA.sub(r"\1 \2", text)
            text = _RE_ALPHA_CJK.sub(r"\1 \2", text)

        if self.config.get("capitalize", True):
            if text and text[0].isalpha():
                text = text[0].upper() + text[1:]
            text = _RE_SENTENCE_START.sub(lambda m: m.group(1).upper(), text)

        for pattern, replacement in self.replacements.items():
            text = text.replace(pattern, replacement)

        return text.strip()
