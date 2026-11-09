"""顾客自助页面：建档、下单、按手机号+取餐码查单（C 域）。

路由挂在 `auth.bp` 上，但不读取员工 Flask 会话；每个请求都从环境变量取
`cust_app` 数据库凭据，避免把顾客操作误当成员工身份。
"""

from __future__ import annotations

from flask import render_template, request

from app.auth import customer_service
from app.auth.routes import bp
from app.common.errors import AppError


def _page(*, error=None, notice=None, registration=None, order=None,
          orders=None, mobile="", items="", pickup=""):
    return render_template(
        "customer/index.html",
        error=error,
        notice=notice,
        registration=registration,
        order=order,
        orders=orders,
        mobile=mobile,
        items=items,
        pickup=pickup,
    )


@bp.get("/customer")
def customer_home():
    return _page()


@bp.post("/customer/register")
def customer_register():
    mobile = request.form.get("mobile", "")
    try:
        rows = customer_service.register(mobile)
    except AppError as err:
        return _page(error=err.user_message, mobile=mobile), err.http_status
    if not rows:
        return _page(error="建档未返回结果，请重试", mobile=mobile), 500
    return _page(
        notice="建档成功；老顾客会直接返回已有档案。",
        registration=rows[0],
        mobile=mobile,
    )


@bp.post("/customer/order")
def customer_order():
    mobile = request.form.get("mobile", "")
    items = request.form.get("items", "")
    try:
        rows = customer_service.place_order(mobile, items)
    except AppError as err:
        return _page(error=err.user_message, mobile=mobile, items=items), err.http_status
    if not rows:
        return _page(error="下单未返回结果，请到门店核实", mobile=mobile, items=items), 500
    return _page(
        notice="下单成功。请保存订单号和取餐码，二者都不要发到公开渠道。",
        order=rows[0],
        mobile=mobile,
        items=items,
    )


@bp.post("/customer/orders")
def customer_list_orders():
    mobile = request.form.get("mobile", "")
    pickup = request.form.get("pickup", "")
    try:
        rows = customer_service.list_orders(mobile, pickup)
    except AppError as err:
        return _page(error=err.user_message, mobile=mobile, pickup=pickup), err.http_status
    return _page(
        notice="查询完成。" if rows else "没有匹配的订单。",
        orders=rows,
        mobile=mobile,
        pickup=pickup,
    )
