"""销售报表 DAO：只把日期绑成 DATE 参数并调用 B 的 sp_sales_report。

页面层不得自己拼销售明细或汇总；这里也不读基表。
"""

from __future__ import annotations

from datetime import date

from app.common.db import p_date, query_procedure_sets


def fetch_sales_report(session, start_date: date, end_date: date):
    """返回 [汇总集, 商品明细集]；顺序由过程契约固定（计划 §4.3）。"""
    return query_procedure_sets(
        session,
        "sp_sales_report",
        [p_date(start_date), p_date(end_date)],
    )
