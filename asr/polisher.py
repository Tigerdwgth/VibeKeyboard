"""LLM 文本润色 — 去除语气词、水词，保留原意"""

import logging
import re

logger = logging.getLogger(__name__)

# 预编译本地规则
_FILLER_RES = [re.compile(p) for p in [
    r'^[呃嗯啊哎唉额哦嗷那个就是然后]+[，,、\s]*',
    r'[，,]\s*[呃嗯啊额哦]+\s*[，,]',
    r'[，,]\s*就是说?\s*[，,]',
    r'[，,]\s*然后\s*[，,]',
    r'[，,]\s*那个\s*[，,]',
    r'[，,]\s*对吧\s*[。？]?$',
    r'[，,]\s*是吧\s*[。？]?$',
]]
_RE_MULTI_COMMA = re.compile(r'[，,]{2,}')
_RE_LEADING_COMMA = re.compile(r'^[，,\s]+')
_RE_TRAILING_COMMA = re.compile(r'[，,\s]+$')

# 缓存 OpenAI client
_llm_client = None
_llm_client_key = None


def polish_local(text: str) -> str:
    """本地规则去水词（无网络依赖，快速）"""
    if not text:
        return text
    result = text
    for pat in _FILLER_RES:
        result = pat.sub('，', result)
    # 清理多余逗号
    result = _RE_MULTI_COMMA.sub('，', result)
    result = _RE_LEADING_COMMA.sub('', result)
    result = _RE_TRAILING_COMMA.sub('', result)
    # 确保句尾有标点
    if result and result[-1] not in '。？！.?!':
        result += '。'
    return result


def polish_with_llm(text: str, config: dict | None = None) -> str:
    """用 LLM 润色文本，去除水词保留原意

    支持：
    - LM Studio 本地部署（OpenAI 兼容 API）
    - Anthropic Claude API
    - 任意 OpenAI 兼容 API

    config keys:
        llm_api_url: API 地址，默认 http://localhost:1234/v1（LM Studio）
        llm_api_key: API key，本地模型可留空
        llm_model: 模型名，默认空（LM Studio 自动选）

    Returns:
        润色后的文本，失败则返回本地规则处理的结果
    """
    config = config or {}
    api_url = config.get("llm_api_url", "http://localhost:1234/v1")
    api_key = config.get("llm_api_key", "lm-studio")
    model = config.get("llm_model", "")

    prompt = (
        "你是语音转文字的后处理助手。请对以下语音识别文本做最小修改：\n"
        "1. 只删除口语语气词：呃、嗯、啊、哎、额、哦、那个、就是说、就是、然后的话、然后\n"
        "2. 删除无意义的重复词语\n"
        "3. 不要改写句子结构、不要换词、不要润色、不要总结\n"
        "4. 保留所有实际内容和专业术语\n"
        "5. 只输出处理后的文本，不要任何解释\n\n"
        f"{text}"
    )

    try:
        from openai import OpenAI
        global _llm_client, _llm_client_key
        cache_key = (api_url, api_key)
        if _llm_client is None or _llm_client_key != cache_key:
            _llm_client = OpenAI(base_url=api_url, api_key=api_key)
            _llm_client_key = cache_key
        client = _llm_client

        params = {
            "messages": [{"role": "user", "content": prompt}],
            "max_tokens": 1024,
            "temperature": 0.3,
        }
        if model:
            params["model"] = model
        else:
            params["model"] = "default"

        response = client.chat.completions.create(**params)
        result = response.choices[0].message.content.strip()
        logger.info(f"LLM 润色完成: {text[:30]}... → {result[:30]}...")
        return result

    except ImportError:
        logger.warning("openai 库未安装，使用本地规则")
        return polish_local(text)
    except Exception as e:
        logger.warning(f"LLM 润色失败: {e}，回退本地规则")
        return polish_local(text)
