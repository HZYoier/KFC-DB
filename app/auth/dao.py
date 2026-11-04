"""身份上下文的数据库访问（C 域）。

`sp_get_current_employee_context` 固定返回三个结果集：员工头、业务角色、权限码。
A 的 `app/common/db.py` 已提供正式的多结果集入口 `query_procedure_sets`（OI-14），
这里直接使用它；空集占位、顺序与 `nextset` 异常都交给共享层统一处理。
"""

from __future__ import annotations

from app.common import db


def fetch_employee_context(session) -> list[list[dict]]:
    """以员工自己的数据库登录调用上下文过程，返回三个结果集的字典行。"""
    return db.query_procedure_sets(session, "sp_get_current_employee_context")
