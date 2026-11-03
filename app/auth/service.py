"""登录、注销与请求身份。

安全口径：
- 员工用自己的数据库登录连接；登录时先调 `sp_get_current_employee_context` 验证，
  失败不建立会话。
- 口令只在当前进程的服务端内存里与 `db_login` 一起保存；Flask 会话 cookie 只放
  随机 token。这样即使 cookie 被读到，也拿不到口令。
- 会话默认 8 小时过期；注销、过期或进程重启后需要重新登录。
"""

from __future__ import annotations

import secrets
import threading
import time
from functools import wraps
from typing import Any

from flask import has_request_context, redirect, request, session as flask_session, url_for

from app.auth import dao
from app.common import errors

_SESSION_TTL_SECONDS = 8 * 60 * 60
_LOCK = threading.Lock()
_STORE: dict[str, dict[str, Any]] = {}


def _now() -> float:
    return time.time()


def _prune_locked() -> None:
    cutoff = _now() - _SESSION_TTL_SECONDS
    for token, record in list(_STORE.items()):
        if record["created_at"] < cutoff:
            _STORE.pop(token, None)


def _record_locked(token: str) -> dict[str, Any] | None:
    record = _STORE.get(token)
    if record is None:
        return None
    if record["created_at"] + _SESSION_TTL_SECONDS < _now():
        _STORE.pop(token, None)
        return None
    return record


def current_employee_session() -> dict[str, Any] | None:
    """给 A/B 的过程调用使用的 session；未登录或过期返回 None。

    只返回数据库连接需要的三个键；不返回口令以外的上下文，页面展示走
    `current_identity()`。
    """
    if not has_request_context():
        return None
    token = flask_session.get("auth_token")
    if not token:
        return None
    with _LOCK:
        record = _record_locked(token)
        if record is None:
            return None
        return dict(record["credentials"])


def current_identity() -> dict[str, Any] | None:
    """当前会话的员工、角色与权限；未登录返回 None。"""
    if not has_request_context():
        return None
    token = flask_session.get("auth_token")
    if not token:
        return None
    with _LOCK:
        record = _record_locked(token)
        if record is None:
            return None
        return {
            "employee": dict(record["employee"]),
            "roles": [dict(row) for row in record["roles"]],
            "permissions": [dict(row) for row in record["permissions"]],
        }


def _decode_context(result_sets: list[list[dict]]) -> tuple[dict, list[dict], list[dict]]:
    if not isinstance(result_sets, list) or len(result_sets) != 3:
        raise errors.AppError("E_INTERNAL")
    employees, roles, permissions = result_sets
    if len(employees) != 1:
        raise errors.AppError("E_AUTH")
    employee = employees[0]
    required = ("employee_id", "database_user_name", "employee_name", "job_code")
    if not all(key in employee for key in required):
        raise errors.AppError("E_INTERNAL")
    return employee, roles, permissions


def authenticate(db_login: str, db_password: str) -> dict[str, Any]:
    """验证数据库登录并建立服务端会话；失败抛 AppError（不落口令）。"""
    login_name = (db_login or "").strip()
    if not login_name or len(login_name) > 128 or db_password is None or len(db_password) > 256:
        raise errors.AppError("E_INPUT")

    credentials = {"db_login": login_name, "db_password": db_password, "role": ""}
    try:
        result_sets = dao.fetch_employee_context(credentials)
    except errors.AppError as exc:
        # 登录失败、账号停用、无上下文权限都统一成 E_AUTH；真正的数据库不可用保留 E_DB。
        if exc.code == "E_DB" and exc.sql_number not in (18456, 4060):
            raise
        raise errors.AppError("E_AUTH", cause=exc) from exc

    employee, roles, permissions = _decode_context(result_sets)
    role = roles[0]["role_code"] if roles else (employee.get("job_code") or "")
    credentials["role"] = role

    token = secrets.token_urlsafe(32)
    old_token = flask_session.get("auth_token")
    record = {
        "credentials": credentials,
        "employee": employee,
        "roles": roles,
        "permissions": permissions,
        "created_at": _now(),
    }
    with _LOCK:
        if old_token:
            _STORE.pop(old_token, None)
        _prune_locked()
        _STORE[token] = record
    flask_session.clear()
    flask_session["auth_token"] = token
    return current_identity() or {}


def logout() -> None:
    if not has_request_context():
        return
    token = flask_session.get("auth_token")
    with _LOCK:
        if token:
            _STORE.pop(token, None)
    flask_session.clear()


def login_required(view):
    """请求级登录门；未登录跳登录页，保留安全的站内 next。"""

    @wraps(view)
    def wrapped(*args, **kwargs):
        if current_employee_session() is None:
            return redirect(url_for("auth.login", next=request.path))
        return view(*args, **kwargs)

    return wrapped


def reset_store() -> None:
    """测试用：清空服务端会话；生产请求路径不调用。"""
    with _LOCK:
        _STORE.clear()
