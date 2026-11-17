"""销售报表业务层：只做日期形状与起止顺序校验。

汇总（订单数、销量、销售额）与商品明细都由 `sp_sales_report` 返回，
Python 不求和、不乘单价、不补零行——R10-06 的“只展示、不重算”。
"""

from __future__ import annotations

from datetime import date

from app.common.errors import AppError
from app.reports import dao


def _date(value) -> date:
    text = (value or "").strip()
    if not text:
        raise AppError("E_INPUT")
    try:
        return date.fromisoformat(text)
    except ValueError:
        raise AppError("E_INPUT") from None


def sales_report(session, start_date, end_date):
    """调用 sp_sales_report；日期非法或过程结果形状不对时抛 AppError。

    日期起大于止交给页面先挡一次；过程自身还会按 54202 拒绝，
    两处都不改口径，页面只是少一次无意义调用。
    """
    start = _date(start_date)
    end = _date(end_date)
    if start > end:
        raise AppError("E_INPUT")

    sets = dao.fetch_sales_report(session, start, end)
    if len(sets) != 2 or not sets[0]:
        raise AppError("E_INTERNAL")
    return {"summary": sets[0][0], "items": sets[1]}
