"""销售报表页面（A）：日期区间 + 汇总 + 商品明细，只读。"""

from __future__ import annotations

from datetime import date

from flask import Blueprint, render_template, request

from app.auth import current_employee_session, login_required
from app.common.errors import AppError
from app.reports import service

bp = Blueprint("reports", __name__, url_prefix="/reports")


@bp.get("/sales")
@login_required
def sales():
    start = (request.args.get("start") or "").strip()
    end = (request.args.get("end") or "").strip()
    if not start and not end:
        start = end = date.today().isoformat()

    summary, items, error = None, [], None
    if request.args:
        try:
            data = service.sales_report(current_employee_session(), start, end)
            summary, items = data["summary"], data["items"]
        except AppError as err:
            # 页面只显示归类后的提示；原始 SQL 消息留在日志
            error = err.user_message

    return render_template(
        "reports/sales.html",
        start=start,
        end=end,
        summary=summary,
        items=items,
        error=error,
    )
