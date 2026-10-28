"""唯一的连接与参数绑定入口（计划 §6.3）。

对外四个名字冻结：open_connection / query_procedure / execute_procedure /
run_in_transaction（在 tx.py）。其余模块不得 import pyodbc，也不得自己拼 SQL 值。

身份口径：员工侧过程按 USER_NAME() 映射 EmployeeAccount，所以每个员工的请求必须用
他自己的数据库登录连接。session 里带 db_login / db_password 就用它，
不带则退回 .env 的部署账户（仅本地冒烟，TRUSTED_CONNECTION=yes 时是本机 Windows 身份）。
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from datetime import date, datetime, time
from decimal import Decimal
from typing import Any, Mapping, Sequence

import pyodbc

from app.common import errors
from app.common.config import DbConfig, load_db_config

_IDENT = re.compile(r"^[a-z][a-z0-9_]*$")
Session = Mapping[str, Any]


@dataclass(frozen=True)
class SqlParam:
    """一个参数值加它的 SQL 类型；长度/精度显式给出，不交给驱动猜。"""

    value: Any
    sql_type: int
    size: int = 0
    scale: int = 0


def p_varchar(value, size: int) -> SqlParam:
    return SqlParam(value, pyodbc.SQL_VARCHAR, size)


def p_nvarchar(value, size: int) -> SqlParam:
    return SqlParam(value, pyodbc.SQL_WVARCHAR, size)


def p_bigint(value) -> SqlParam:
    return SqlParam(value, pyodbc.SQL_BIGINT)


def p_int(value) -> SqlParam:
    return SqlParam(value, pyodbc.SQL_INTEGER)


def p_bit(value) -> SqlParam:
    return SqlParam(value, pyodbc.SQL_BIT)


def p_decimal(value, precision: int, scale: int) -> SqlParam:
    return SqlParam(value, pyodbc.SQL_DECIMAL, precision, scale)


def p_datetime(value) -> SqlParam:
    return SqlParam(value, pyodbc.SQL_TYPE_TIMESTAMP)


def _config(config: DbConfig | None = None) -> DbConfig:
    if config is not None:
        return config
    try:
        from flask import current_app

        return current_app.config["KFC_DB"]
    except (RuntimeError, KeyError):
        return load_db_config()


def open_connection(session: Session | None = None, *, autocommit: bool = True, config: DbConfig | None = None) -> pyodbc.Connection:
    """开连接。默认 autocommit=True：一次按钮只调一个自持事务的过程，
    这样过程里 @@TRANCOUNT = 0，走「自己开事务」那一支（04 各过程都是这么判的）。
    多过程原子操作走 tx.run_in_transaction，它显式传 autocommit=False。
    """
    cfg = _config(config)
    kwargs: dict[str, Any] = {}
    if session:
        login = (session.get("db_login") or "").strip()
        password = session.get("db_password")
        if login:
            kwargs["user"] = login
            kwargs["password"] = password or ""
    try:
        conn = pyodbc.connect(cfg.connection_string(), autocommit=autocommit, timeout=cfg.query_timeout, **kwargs)
        conn.timeout = cfg.query_timeout
        return conn
    except pyodbc.Error as exc:
        raise errors.from_exception(exc) from exc


def _bind(cursor, params: Sequence[SqlParam]) -> list[Any]:
    """参数一律显式定型；传进来裸值直接拒绝，免得悄悄按驱动默认类型绑定。"""
    values = []
    for param in params:
        if not isinstance(param, SqlParam):
            raise TypeError("参数必须是 SqlParam（用 p_varchar / p_bigint 等构造），收到 %r" % (type(param).__name__,))
        values.append(param.value)
    if values:
        cursor.setinputsizes([(p.sql_type, p.size, p.scale) for p in params])
    return values


def _rows(cursor) -> list[dict[str, Any]]:
    """取第一个非空结果集；过程都只回一个结果集，其余集合读掉再返回。"""
    rows: list[dict[str, Any]] = []
    while True:
        if cursor.description:
            columns = [column[0] for column in cursor.description]
            fetched = [dict(zip(columns, row)) for row in cursor.fetchall()]
            if fetched:
                return fetched
            rows = fetched
        try:
            if not cursor.nextset():
                return rows
        except pyodbc.Error:
            return rows


def query(session: Session | None, sql: str, params: Sequence[SqlParam] = ()) -> list[dict[str, Any]]:
    """只读查询。sql 必须是 dao.py 里的常量，值全部走参数。"""
    conn = open_connection(session)
    try:
        cursor = conn.cursor()
        cursor.execute(sql, _bind(cursor, params))
        return _rows(cursor)
    except pyodbc.Error as exc:
        raise errors.from_exception(exc) from exc
    finally:
        conn.close()


def query_procedure(session: Session | None, name: str, params: Sequence[SqlParam] = ()) -> list[dict[str, Any]]:
    """调用返回结果集的查询过程（§2.2 那批）。"""
    return _call(session, name, params)


def execute_procedure(session: Session | None, name: str, params: Sequence[SqlParam] = ()) -> list[dict[str, Any]]:
    """调用写过程。写过程自持事务，这里不再包事务（要包就整体走 tx）。"""
    return _call(session, name, params)


def _call(session: Session | None, name: str, params: Sequence[SqlParam]) -> list[dict[str, Any]]:
    if not _IDENT.match(name or ""):
        raise ValueError("过程名不合法：%r" % (name,))
    placeholders = ", ".join("?" for _ in params)
    sql = "{CALL dbo.%s (%s)}" % (name, placeholders)
    conn = open_connection(session)
    try:
        cursor = conn.cursor()
        cursor.execute(sql, _bind(cursor, params))
        return _rows(cursor)
    except pyodbc.Error as exc:
        raise errors.from_exception(exc) from exc
    finally:
        conn.close()


def as_json_value(value: Any) -> Any:
    """DECIMAL / datetime 直接 jsonify 会失真，统一在出口转一次。金额转字符串，不转 float。"""
    if isinstance(value, Decimal):
        return str(value)
    if isinstance(value, datetime):
        return value.isoformat(sep=" ", timespec="seconds")
    if isinstance(value, (date, time)):
        return value.isoformat()
    return value


def jsonable(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [{key: as_json_value(value) for key, value in row.items()} for row in rows]
