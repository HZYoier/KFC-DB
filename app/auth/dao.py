"""身份上下文的数据库访问（C 域）。

`sp_get_current_employee_context` 固定返回三个结果集：员工头、业务角色、权限码。
A 的 `app/common/db.py` 当前只取第一个非空结果集，且 `nextset()` 抛错时会提前返回；
因此这里只使用冻结的连接入口 `db.open_connection`，显式迭代结果集，不 import pyodbc，
也不自己拼 SQL 值。A 提供正式的多结果集 API 后，这个适配器可以收掉。
"""

from __future__ import annotations

from app.common import db, errors

_CONTEXT_CALL = "{CALL dbo.sp_get_current_employee_context ()}"


def fetch_employee_context(session) -> list[list[dict]]:
    """以员工自己的数据库登录调用上下文过程，返回三个结果集的字典行。

    错误统一交给 `errors.from_exception`；不吞 `nextset()` 的异常，避免把延后到达
    的数据库错误当成成功。
    """
    conn = db.open_connection(session)
    try:
        cursor = conn.cursor()
        cursor.execute(_CONTEXT_CALL)
        result_sets: list[list[dict]] = []
        while True:
            if cursor.description:
                columns = [column[0] for column in cursor.description]
                rows = [dict(zip(columns, row)) for row in cursor.fetchall()]
                result_sets.append(rows)
            if not cursor.nextset():
                break
        return result_sets
    except Exception as exc:
        raise errors.from_exception(exc) from exc
    finally:
        conn.close()
