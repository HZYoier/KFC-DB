"""主数据域业务层模板。

页面层传进来的是已做基础校验的值；这里再挡一次长度与空值，
之后直接调 DAO——不写 try/except，数据库错误由注册到应用的全局 handler 归类。
"""

from __future__ import annotations

from app.common.errors import AppError
from app.master import dao


def list_active_product_prices(session):
    return dao.list_active_product_prices(session)


def create_category(session, category_name: str):
    name = (category_name or "").strip()
    if not name or len(name) > 50:
        # 51000 是库里同一条规则的编号，应用层先挡，省一次往返
        raise AppError("E_INPUT")
    return dao.create_category(session, name)
