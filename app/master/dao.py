"""主数据域 DAO 模板：B、C 照着这个形状写各自的 dao.py。

规矩只有三条：SQL 写成模块里的常量、值全部走 SqlParam、不 import pyodbc。
"""

from __future__ import annotations

from app.common.db import execute_procedure, p_nvarchar, query

# 取价逻辑已沉在 fn_get_effective_product_price + 视图里，应用层不再算一遍
_SQL_ACTIVE_PRODUCT_PRICES = """
SELECT product_id, product_name, product_type, category_id, category_name,
       base_price, effective_price, promotion_id
FROM dbo.v_active_product_price
ORDER BY category_id, product_id;
"""


def list_active_product_prices(session):
    return query(session, _SQL_ACTIVE_PRODUCT_PRICES)


def create_category(session, category_name: str):
    """写过程自持事务、按 USER_NAME() 认人，这里只负责传参。"""
    return execute_procedure(session, "sp_create_category", [p_nvarchar(category_name, 50)])
