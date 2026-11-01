"""主数据域业务层：做页面层挡不住的那道校验，再把值交给 DAO。

只挡「明显错误」（空值、长度、枚举、金额形状），业务真相仍在库里：
唯一键、状态机、默认等级、定价规则一律以过程为准，这里不复制一份判断。
不写 try/except——数据库错误由注册到应用的全局 handler 按 §6.3 归成九类。
"""

from __future__ import annotations

import json
import re
from datetime import datetime, time
from decimal import Decimal, InvalidOperation

from app.common.errors import AppError
from app.master import dao

STATUSES = ("ACTIVE", "INACTIVE")
PRODUCT_TYPES = ("SINGLE", "COMBO")
CUSTOMER_TYPES = ("GUEST", "WOW", "PAID")

_MOBILE = re.compile(r"^[0-9]{11}$")
_CLOCK = re.compile(r"^([01][0-9]|2[0-3]):[0-5][0-9](:[0-5][0-9])?$")


# ---------------------------------------------------------------------------
# 值校验小工具
# ---------------------------------------------------------------------------

def _text(value, length: int) -> str:
    text = (value or "").strip()
    if not text or len(text) > length:
        raise AppError("E_INPUT")
    return text


def _int_in_range(value, low: int, high: int) -> int:
    """整数参数。low 可以是 0——门槛分与优先级允许 0，别一律按「正整数」挡掉。"""
    try:
        number = int(str(value).strip())
    except (TypeError, ValueError):
        raise AppError("E_INPUT") from None
    if not low <= number <= high:
        raise AppError("E_INPUT")
    return number


def _decimal(value, maximum: Decimal, scale: int) -> Decimal:
    """正小数。多出来的小数位直接拒绝，不替调用方四舍五入。"""
    try:
        number = Decimal(str(value).strip())
    except (InvalidOperation, AttributeError):
        raise AppError("E_INPUT") from None
    if not number.is_finite() or number < Decimal(1).scaleb(-scale) or number > maximum:
        raise AppError("E_INPUT")
    digits = number.as_tuple()
    if digits.exponent < -scale and any(digits.digits[digits.exponent + scale:]):
        raise AppError("E_INPUT")
    return number


def _money(value, maximum: Decimal = Decimal("99999999.99")) -> Decimal:
    return _decimal(value, maximum, 2)


def _status(value) -> str:
    return _choice(value, STATUSES)


def _choice(value, allowed) -> str:
    text = (value or "").strip().upper()
    if text not in allowed:
        raise AppError("E_INPUT")
    return text


def _moment(value) -> datetime:
    """HTML datetime-local 送 'YYYY-MM-DDTHH:MM'；库里是 DATETIME2(0)。"""
    text = (value or "").strip().replace(" ", "T")
    try:
        return datetime.fromisoformat(text)
    except ValueError:
        raise AppError("E_INPUT") from None


def _clock(value) -> time:
    text = (value or "").strip()
    if not _CLOCK.match(text):
        raise AppError("E_INPUT")
    return time.fromisoformat(text)


def _json_items(text, id_key: str, value_key: str, parser) -> str:
    """把「每行一条 id 数量」的文本框转成过程要的 JSON 数组；空文本即清空（[]）。"""
    items = []
    for line in (text or "").splitlines():
        parts = [part for part in re.split(r"[,:\s]+", line.strip()) if part]
        if not parts:
            continue
        if len(parts) != 2:
            raise AppError("E_INPUT")
        value = parser(parts[1])
        items.append(
            {
                id_key: _int_in_range(parts[0], 1, 2**63 - 1),
                # Decimal 直接 json.dumps 会报错；写成字符串，OPENJSON 的 WITH DECIMAL 能转，
                # 且不会像 float 那样丢掉「0.500」的末位
                value_key: str(value) if isinstance(value, Decimal) else value,
            }
        )
    return json.dumps(items, ensure_ascii=False, separators=(",", ":"))


def _qty(value) -> Decimal:
    return _decimal(value, Decimal("999999999.999"), 3)


# ---------------------------------------------------------------------------
# 查询（契约 §2.4）
# ---------------------------------------------------------------------------

def list_active_product_prices(session):
    """演示用：阶段一留下的 v_active_product_price 视图（含分类名），不参与主数据维护页。"""
    return dao.list_active_product_prices(session)


def list_master_records(session, entity_code: str, status: str | None = None):
    code = (entity_code or "").strip().upper()
    if status not in (None, "", *STATUSES):
        raise AppError("E_INPUT")
    return dao.list_master_records(session, code, status or None)


def list_sale_products(session, take: int = 100):
    return dao.list_sale_products(session, _int_in_range(take, 1, 200))


def find_customer_for_order(session, mobile: str):
    number = (mobile or "").strip()
    if not _MOBILE.match(number):
        raise AppError("E_INPUT")
    return dao.find_customer_for_order(session, number)


def register_customer_for_order(session, mobile: str):
    number = (mobile or "").strip()
    if not _MOBILE.match(number):
        raise AppError("E_INPUT")
    # 过程无结果集；建完回查取 ID，收银流程要拿 customer_id 去下单
    dao.register_customer_for_order(session, number)
    return dao.find_customer_for_order(session, number)


# ---------------------------------------------------------------------------
# 写（04 的过程；参数顺序与过程签名逐一对应）
# ---------------------------------------------------------------------------

def create_category(session, category_name):
    return dao.create_category(session, _text(category_name, 50))


def update_category_status(session, category_id, status):
    return dao.update_category_status(session, _int_in_range(category_id, 1, 2**63 - 1), _status(status))


def create_ingredient(session, ingredient_name, unit_name, safety_stock_qty):
    return dao.create_ingredient(
        session, _text(ingredient_name, 50), _text(unit_name, 50), _qty(safety_stock_qty)
    )


def update_ingredient(session, ingredient_id, ingredient_name, unit_name, safety_stock_qty, status):
    return dao.update_ingredient(
        session,
        _int_in_range(ingredient_id, 1, 2**63 - 1),
        _text(ingredient_name, 50),
        _text(unit_name, 50),
        _qty(safety_stock_qty),
        _status(status),
    )


def create_product(session, product_name, base_price, product_type, category_id):
    return dao.create_product(
        session,
        _text(product_name, 50),
        _money(base_price),
        _choice(product_type, PRODUCT_TYPES),
        _int_in_range(category_id, 1, 2**63 - 1),
    )


def update_product_price(session, product_id, base_price):
    return dao.update_product_price(
        session, _int_in_range(product_id, 1, 2**63 - 1), _money(base_price)
    )


def update_product_status(session, product_id, status):
    return dao.update_product_status(
        session, _int_in_range(product_id, 1, 2**63 - 1), _status(status)
    )


def set_product_bom(session, product_id, lines):
    return dao.set_product_bom(
        session,
        _int_in_range(product_id, 1, 2**63 - 1),
        _json_items(lines, "ingredient_id", "usage_qty", _qty),
    )


def set_combo_component(session, product_id, lines):
    return dao.set_combo_component(
        session,
        _int_in_range(product_id, 1, 2**63 - 1),
        _json_items(lines, "child_product_id", "quantity", lambda value: _int_in_range(value, 1, 2**31 - 1)),
    )


def create_member_level(session, level_name, point_multiplier, threshold_points):
    return dao.create_member_level(
        session,
        _text(level_name, 50),
        _money(point_multiplier, Decimal("99.99")),
        _int_in_range(threshold_points, 0, 2**31 - 1),
    )


def update_member_level(session, member_level_id, level_name, point_multiplier, threshold_points):
    return dao.update_member_level(
        session,
        _int_in_range(member_level_id, 1, 2**63 - 1),
        _text(level_name, 50),
        _money(point_multiplier, Decimal("99.99")),
        _int_in_range(threshold_points, 0, 2**31 - 1),
    )


def update_member_level_status(session, member_level_id, status):
    return dao.update_member_level_status(
        session, _int_in_range(member_level_id, 1, 2**63 - 1), _status(status)
    )


def create_customer(session, mobile, customer_type):
    number = (mobile or "").strip()
    if not _MOBILE.match(number):
        raise AppError("E_INPUT")
    return dao.create_customer(session, number, _choice(customer_type, CUSTOMER_TYPES))


def update_customer_member_level(session, customer_id, member_level_id):
    return dao.update_customer_member_level(
        session,
        _int_in_range(customer_id, 1, 2**63 - 1),
        _int_in_range(member_level_id, 1, 2**63 - 1),
    )


def create_promotion(session, promotion_name, promotion_type, start_at, end_at):
    start, end = _moment(start_at), _moment(end_at)
    if end <= start:
        raise AppError("E_INPUT")
    return dao.create_promotion(session, _text(promotion_name, 50), _text(promotion_type, 20), start, end)


def update_promotion_status(session, promotion_id, status):
    return dao.update_promotion_status(
        session, _int_in_range(promotion_id, 1, 2**63 - 1), _status(status)
    )


def add_promotion_product_rule(session, promotion_id, product_id, weekday_no, start_time,
                               end_time, promo_price, priority):
    return dao.add_promotion_product_rule(
        session,
        _int_in_range(promotion_id, 1, 2**63 - 1),
        _int_in_range(product_id, 1, 2**63 - 1),
        _int_in_range(weekday_no, 1, 7),
        _clock(start_time),
        _clock(end_time),
        _money(promo_price),
        _int_in_range(priority, 0, 2**31 - 1),
    )


def update_promotion_product_rule(session, rule_id, weekday_no, start_time, end_time,
                                  promo_price, priority):
    return dao.update_promotion_product_rule(
        session,
        _int_in_range(rule_id, 1, 2**63 - 1),
        _int_in_range(weekday_no, 1, 7),
        _clock(start_time),
        _clock(end_time),
        _money(promo_price),
        _int_in_range(priority, 0, 2**31 - 1),
    )
