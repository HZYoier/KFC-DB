"""统一异常与错误码（计划 §6.3）。全库九类，映射表是唯一权威。

响应体只有 {code, message, request_id}：SQL 编号、原始消息、驱动文本、堆栈只进日志。
"""

from __future__ import annotations

import logging
import re
from typing import Any

import pyodbc
from flask import jsonify, request
from werkzeug.exceptions import HTTPException

from app.common import log

# 类 -> HTTP 状态
CODE_HTTP = {
    "E_INPUT": 400,
    "E_AUTH": 401,
    "E_FORBIDDEN": 403,
    "E_NOTFOUND": 404,
    "E_RULE": 409,
    "E_CONFLICT": 409,
    "E_TX": 409,
    "E_DB": 503,
    "E_INTERNAL": 500,
}

# 类 -> 前端可见文案（不得改写，也不得拼进具体原因）
CODE_MESSAGE = {
    "E_INPUT": "请检查输入内容",
    "E_AUTH": "请先登录",
    "E_FORBIDDEN": "当前账号无权执行该操作",
    "E_NOTFOUND": "记录不存在或已被删除",
    "E_RULE": "操作未完成，原因见提示",
    "E_CONFLICT": "数据与现有记录冲突",
    "E_TX": "系统忙，请重试",
    "E_DB": "系统暂时无法完成操作",
    "E_INTERNAL": "系统暂时无法完成操作",
}

# 数据库消息号 -> 类。段位依据源码实测：A 域 51000–51005、B 域 52xxx、
# C 域过程统一 50000、顾客端 530xx。511xx / 519xx 是验收脚本断言码，不收。
_SQL_NUMBER = {
    51000: "E_INPUT",
    51001: "E_NOTFOUND",
    51002: "E_RULE",
    51003: "E_RULE",
    51004: "E_FORBIDDEN",
    51005: "E_CONFLICT",
    53000: "E_INPUT",
    53001: "E_NOTFOUND",
    53002: "E_RULE",
    50000: "E_RULE",
    229: "E_FORBIDDEN",
    230: "E_FORBIDDEN",
    262: "E_FORBIDDEN",
    2627: "E_CONFLICT",
    2601: "E_CONFLICT",
    547: "E_CONFLICT",
    1205: "E_TX",
    3930: "E_TX",
    3960: "E_TX",
    4060: "E_DB",
    18456: "E_DB",
}

_MSG_NUMBER = re.compile(r"(?:Msg\s+(\d{3,6})|\((\d{3,6})\)\s*\([A-Za-z])")
_PASSWORD = re.compile(r"(?i)\b(pwd|password)\s*=\s*[^;]*")


def redact(text: str) -> str:
    """抹掉可能带入口令的片段；日志与异常文本都要先过这里。"""
    return _PASSWORD.sub(lambda m: "%s=***" % m.group(1), text)


class AppError(Exception):
    """业务与访问层共用的异常基类。str() 只给用户文案，原始信息留在 raw_message。"""

    def __init__(
        self,
        code: str,
        *,
        sql_number: int | None = None,
        raw_message: str | None = None,
        cause: BaseException | None = None,
    ) -> None:
        if code not in CODE_HTTP:
            raise ValueError("未登记的错误码：%s" % code)
        super().__init__(CODE_MESSAGE[code])
        self.code = code
        self.http_status = CODE_HTTP[code]
        self.user_message = CODE_MESSAGE[code]
        self.sql_number = sql_number
        self.raw_message = redact(raw_message) if raw_message else None
        self.cause = cause


def extract_sql_number(exc: BaseException) -> int | None:
    """从 pyodbc 异常里取 SQL Server 消息号；取不到返回 None，由类型兜底。"""
    if not isinstance(exc, pyodbc.Error):
        return None
    for arg in exc.args:
        if isinstance(arg, int):
            return arg
        match = _MSG_NUMBER.search(str(arg))
        if match:
            return int(match.group(1) or match.group(2))
    return None


def from_exception(exc: BaseException) -> AppError:
    """把任意异常归成九类之一。未知一律 E_INTERNAL，不猜成业务错误。"""
    if isinstance(exc, AppError):
        return exc

    if not isinstance(exc, pyodbc.Error):
        return AppError("E_INTERNAL", raw_message=str(exc), cause=exc)

    number = extract_sql_number(exc)
    raw = redact(" | ".join(str(a) for a in exc.args))

    if isinstance(exc, pyodbc.InterfaceError):
        return AppError("E_DB", sql_number=number, raw_message=raw, cause=exc)

    state = str(exc.args[0]) if exc.args else ""
    if state.startswith("08"):
        return AppError("E_DB", sql_number=number, raw_message=raw, cause=exc)

    code = _SQL_NUMBER.get(number) if number is not None else None
    if code is None and number is not None and 52000 <= number <= 52999:
        code = "E_RULE"
    return AppError(code or "E_INTERNAL", sql_number=number, raw_message=raw, cause=exc)


def body(err: AppError, request_id: str) -> dict[str, Any]:
    return {"code": err.code, "message": err.user_message, "request_id": request_id}


def register_error_handlers(app) -> None:
    """全局 errorhandler：路由与 service 内不再写 try/except。"""

    def _handle(err: AppError, operation: str):
        log.event(
            operation,
            code=err.code,
            result="error",
            level=logging.WARNING,
            detail={"sql_number": err.sql_number, "raw": err.raw_message},
        )
        return jsonify(body(err, log.current_request_id())), err.http_status

    @app.errorhandler(AppError)
    def _on_app_error(exc: AppError):
        return _handle(exc, request.endpoint or request.path)

    @app.errorhandler(pyodbc.Error)
    def _on_db_error(exc: pyodbc.Error):
        return _handle(from_exception(exc), request.endpoint or request.path)

    @app.errorhandler(HTTPException)
    def _on_http_error(exc: HTTPException):
        code = "E_NOTFOUND" if exc.code == 404 else "E_INTERNAL"
        return _handle(AppError(code, raw_message=exc.description), "http-%s" % exc.code)

    @app.errorhandler(Exception)
    def _on_any_error(exc: Exception):
        return _handle(from_exception(exc), request.endpoint or request.path)
