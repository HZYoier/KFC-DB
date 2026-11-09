"""顾客端业务层：输入边界、JSON 形状与 cust_app 凭据。

顾客端不是员工会话：它使用部署方显式映射到 `cust_app` 的 SQL 登录，
凭据只从环境变量读，不从员工会话借用，也不回退到部署账户。
商品目录本轮没有对顾客开放的查询过程，页面输入商品 ID 与数量；
数据库过程仍负责商品、价格、库存和授权判定。
"""

from __future__ import annotations

import json
import os
import re

from app.auth import customer_dao
from app.common.errors import AppError

_MOBILE = re.compile(r"^[0-9]{11}$")
_PICKUP = re.compile(r"^[0-9A-F]{20}$")
_MAX_ITEMS = 100
_MAX_PRODUCT_ID = 2**63 - 1
_MAX_QUANTITY = 2**31 - 1


def _session():
    login = (os.environ.get("KFC_CUST_DB_LOGIN") or "").strip()
    password = os.environ.get("KFC_CUST_DB_PASSWORD") or ""
    if not login or not password:
        # Fail closed: Common 的无 session 分支会退回部署账户，顾客端不能走那条路。
        raise AppError("E_DB")
    return {"db_login": login, "db_password": password}


def _mobile(value) -> str:
    text = (value or "").strip()
    if not _MOBILE.fullmatch(text):
        raise AppError("E_INPUT")
    return text


def _pickup(value) -> str:
    text = (value or "").strip().upper()
    if not _PICKUP.fullmatch(text):
        raise AppError("E_INPUT")
    return text


def _positive_int(value, maximum: int):
    if type(value) is not int or value <= 0 or value > maximum:
        raise AppError("E_INPUT")
    return value


def _normalise_item(item):
    if not isinstance(item, dict) or set(item) != {"product_id", "quantity"}:
        raise AppError("E_INPUT")
    return (
        _positive_int(item["product_id"], _MAX_PRODUCT_ID),
        _positive_int(item["quantity"], _MAX_QUANTITY),
    )


def _items(value) -> str:
    """接受页面用的「每行 product_id quantity」或 JSON 数组，统一成契约 JSON。

    页面不向顾客暴露价格、角色或父项字段；这两个字段之外的内容一律拒绝。
    """
    text = (value or "").strip()
    if not text:
        raise AppError("E_INPUT")
    rows = []
    if text.startswith("["):
        try:
            payload = json.loads(text)
        except (TypeError, ValueError) as exc:
            raise AppError("E_INPUT") from exc
        if not isinstance(payload, list):
            raise AppError("E_INPUT")
        rows = payload
    else:
        for line in text.splitlines():
            parts = line.split()
            if not parts:
                continue
            if len(parts) != 2:
                raise AppError("E_INPUT")
            try:
                rows.append({"product_id": int(parts[0]), "quantity": int(parts[1])})
            except (TypeError, ValueError) as exc:
                raise AppError("E_INPUT") from exc
    if not rows or len(rows) > _MAX_ITEMS:
        raise AppError("E_INPUT")
    normalised = []
    seen = set()
    for item in rows:
        product_id, quantity = _normalise_item(item)
        if product_id in seen:
            raise AppError("E_INPUT")
        seen.add(product_id)
        normalised.append({"product_id": product_id, "quantity": quantity})
    return json.dumps(normalised, ensure_ascii=False, separators=(",", ":"))


def register(mobile):
    return customer_dao.register(_session(), _mobile(mobile))


def place_order(mobile, items):
    return customer_dao.place_order(_session(), _mobile(mobile), _items(items))


def list_orders(mobile, pickup_code):
    return customer_dao.list_orders(_session(), _mobile(mobile), _pickup(pickup_code))
