"""CSRF 令牌：页面出令牌、JSON 接口校验，值只放在 Flask 会话里。

A 域的做法：页面在 `<meta name="csrf-token">` 里出令牌，`fetch` 时用 `X-CSRF-Token`
带回来；`GET /api/csrf` 也直接发一个，给脚本调用方用。B/C 的页面各自维护自己的键，
互不影响。令牌不进日志，也不出现在响应体以外的任何位置。
"""

from __future__ import annotations

from hmac import compare_digest
from secrets import token_hex

from flask import request, session

from app.common.errors import AppError

DEFAULT_KEY = "master_csrf"


def token(key: str = DEFAULT_KEY) -> str:
    """取本会话的令牌，没有就现生成一个；同一会话内保持不变。"""
    return session.setdefault(key, token_hex(32))


def require(key: str = DEFAULT_KEY) -> None:
    """POST 前校验；缺令牌、令牌不符一律 E_FORBIDDEN，不区分原因。"""
    expected = session.get(key) or ""
    supplied = request.headers.get("X-CSRF-Token", "")
    if not expected or not compare_digest(expected.encode("utf-8"), supplied.encode("utf-8")):
        raise AppError("E_FORBIDDEN")
