"""事务 helper（计划 §6.3）。只在「多个过程必须原子」时才用。

一次业务按钮通常只调一个自持事务的过程，那种情况直接用 execute_procedure，
不要为了整齐把单过程调用也包进来——包进来过程就落到 SAVE TRANSACTION 分支，
提交点从过程挪到应用层，出错的回滚范围也跟着变。
"""

from __future__ import annotations

from typing import Any, Callable

import pyodbc

from app.common import db, errors


def run_in_transaction(session, callback: Callable[[pyodbc.Connection], Any]) -> Any:
    """同一身份、同一连接上跑 callback；全成功才提交，任何异常整笔回滚并关闭连接。

    callback 收到的连接禁止再开第二个连接去写——那已经出了这个事务。
    """
    conn = db.open_connection(session, autocommit=False)
    try:
        result = callback(conn)
        conn.commit()
        return result
    except BaseException as exc:
        try:
            conn.rollback()
        except pyodbc.Error:
            # 连接已经断了就没什么可回滚的，服务器端会随连接回滚
            pass
        raise errors.from_exception(exc) from exc
    finally:
        conn.close()
