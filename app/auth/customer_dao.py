"""顾客端 DAO：只经 `cust_app` 调用契约 §1 的三个过程。

顾客端没有员工身份；数据库用户 `cust_app` 由 `12_permissions.sql` 创建，
这里只绑定参数，不读基表，也不调用任何员工过程。
"""

from __future__ import annotations

from app.common.db import (
    execute_procedure,
    p_datetime,
    p_nvarchar,
    p_varchar,
    query_procedure,
)


def register(session, mobile: str):
    return query_procedure(
        session,
        "sp_customer_register",
        [p_varchar(mobile, 20)],
    )


def place_order(session, mobile: str, items_json: str):
    # B 的 §1.3 过程要求 @order_no/@pickup_code/@ordered_at 为空，由过程生成；
    # 这里显式绑 None，不把默认值交给驱动猜。
    return execute_procedure(
        session,
        "sp_customer_place_order",
        [
            p_varchar(mobile, 20),
            p_nvarchar(items_json, 0),
            p_varchar("PICKUP", 20),
            p_varchar(None, 20),
            p_varchar(None, 50),
            p_datetime(None),
        ],
    )


def list_orders(session, mobile: str, pickup_code: str):
    return query_procedure(
        session,
        "sp_customer_list_orders",
        [p_varchar(mobile, 20), p_varchar(pickup_code, 20)],
    )
