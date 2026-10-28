"""结构化日志（计划 §6.3）。

每条至少含：请求标识、时间、操作名称、用户角色、错误码、处理结果。
不含口令与完整连接串——写入前统一过 errors.redact 会形成循环依赖，故此处自己抹 PWD。
"""

from __future__ import annotations

import json
import logging
import re
import uuid

from flask import g, has_request_context, request

LOGGER_NAME = "kfc"
_PASSWORD = re.compile(r"(?i)\b(pwd|password)\s*=\s*[^;]*")


def _scrub(value):
    if isinstance(value, str):
        return _PASSWORD.sub(lambda m: "%s=***" % m.group(1), value)
    if isinstance(value, dict):
        return {k: _scrub(v) for k, v in value.items()}
    return value


def current_request_id() -> str:
    if not has_request_context():
        return "-"
    return getattr(g, "request_id", "-")


class JsonFormatter(logging.Formatter):
    """一行一个 JSON 对象，便于按 request_id 检索。"""

    def format(self, record: logging.LogRecord) -> str:
        payload = {
            "ts": self.formatTime(record, "%Y-%m-%dT%H:%M:%S%z"),
            "request_id": getattr(record, "request_id", "-"),
            "operation": _scrub(getattr(record, "operation", "-")),
            "role": getattr(record, "role", "-"),
            "code": getattr(record, "code", "-"),
            "result": getattr(record, "result", "-"),
        }
        detail = getattr(record, "detail", None)
        if detail:
            payload["detail"] = _scrub(detail)
        if record.exc_info:
            payload["trace"] = _scrub(self.formatException(record.exc_info))
        return json.dumps(payload, ensure_ascii=False)


def event(operation, *, code="OK", result="ok", role=None, level=logging.INFO, detail=None, exc_info=False) -> None:
    logging.getLogger(LOGGER_NAME).log(
        level,
        operation,
        extra={
            "request_id": current_request_id(),
            "operation": operation,
            "role": role or (getattr(g, "role", None) if has_request_context() else None) or "-",
            "code": code,
            "result": result,
            "detail": detail,
        },
        exc_info=exc_info,
    )


def configure(app) -> None:
    """挂到应用工厂：日志出口只装一次，避免重复 handler。"""
    cfg = app.config["KFC_DB"]
    logger = logging.getLogger(LOGGER_NAME)
    logger.setLevel(cfg.log_level)
    logger.propagate = False
    for handler in list(logger.handlers):
        logger.removeHandler(handler)
    handler = logging.StreamHandler()
    handler.setFormatter(JsonFormatter())
    logger.addHandler(handler)

    @app.before_request
    def _assign_request_id():
        # 只接受十六进制短串，防止外部把换行之类的东西塞进日志字段
        incoming = (request.headers.get("X-Request-Id") or "").strip()
        g.request_id = incoming if re.fullmatch(r"[0-9a-fA-F-]{8,36}", incoming) else uuid.uuid4().hex[:12]

    @app.after_request
    def _echo_request_id(response):
        response.headers["X-Request-Id"] = current_request_id()
        return response
