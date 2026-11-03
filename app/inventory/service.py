"""库存域业务层：只挡明显输入错误，账本与状态机仍由数据库过程决定。"""

from __future__ import annotations

from decimal import Decimal, InvalidOperation

from app.common.errors import AppError
from app.inventory import dao

_MAX_QTY = Decimal("999999999.999")


def _positive_id(value) -> int:
    try:
        number = int(str(value).strip())
    except (TypeError, ValueError, AttributeError):
        raise AppError("E_INPUT") from None
    if number <= 0 or number > 9223372036854775807:
        raise AppError("E_INPUT")
    return number


def _qty(value, *, allow_zero: bool = False) -> Decimal:
    try:
        number = Decimal(str(value).strip())
    except (InvalidOperation, AttributeError):
        raise AppError("E_INPUT") from None
    if not number.is_finite() or number > _MAX_QTY:
        raise AppError("E_INPUT")
    if allow_zero:
        if number == 0:
            raise AppError("E_INPUT")
    elif number <= 0:
        raise AppError("E_INPUT")
    digits = number.as_tuple()
    if digits.exponent < -3 and any(digits.digits[digits.exponent + 3:]):
        raise AppError("E_INPUT")
    return number


def _delta(value) -> Decimal:
    try:
        number = Decimal(str(value).strip())
    except (InvalidOperation, AttributeError):
        raise AppError("E_INPUT") from None
    if not number.is_finite() or number == 0 or abs(number) > _MAX_QTY:
        raise AppError("E_INPUT")
    digits = number.as_tuple()
    if digits.exponent < -3 and any(digits.digits[digits.exponent + 3:]):
        raise AppError("E_INPUT")
    return number


def _reason(value) -> str:
    text = (value or "").strip()
    if not text or len(text) > 50:
        raise AppError("E_INPUT")
    return text


def _employee(value) -> int:
    return _positive_id(value)


def list_inventory(session):
    return dao.list_inventory(session)


def list_movements(session, ingredient_id=None):
    if ingredient_id in (None, ""):
        return dao.list_movements(session)
    return dao.list_movements(session, _positive_id(ingredient_id))


def list_replenishment(session):
    return dao.list_replenishment(session)


def adjust_inventory(session, employee_id, ingredient_id, on_hand_delta, reason):
    return dao.adjust_inventory(
        session,
        _positive_id(ingredient_id),
        _delta(on_hand_delta),
        _employee(employee_id),
        _reason(reason),
    )


def create_suggestion(session, employee_id, ingredient_id, suggested_qty):
    return dao.create_replenishment_suggestion(
        session, _positive_id(ingredient_id), _qty(suggested_qty), _employee(employee_id)
    )


def update_suggestion(session, employee_id, suggestion_id, suggested_qty):
    return dao.update_replenishment_suggestion(
        session, _positive_id(suggestion_id), _qty(suggested_qty), _employee(employee_id)
    )


def submit_suggestion(session, employee_id, suggestion_id):
    return dao.submit_replenishment_suggestion(
        session, _positive_id(suggestion_id), _employee(employee_id)
    )


def approve_suggestion(session, employee_id, suggestion_id):
    return dao.approve_replenishment_suggestion(
        session, _positive_id(suggestion_id), _employee(employee_id)
    )


def reject_suggestion(session, employee_id, suggestion_id, reason):
    return dao.reject_replenishment_suggestion(
        session, _positive_id(suggestion_id), _employee(employee_id), _reason(reason)
    )


def receive_inventory(session, employee_id, purchase_order_id, received_qty=None):
    qty = None if received_qty in (None, "") else _qty(received_qty)
    return dao.receive_inventory(
        session, _positive_id(purchase_order_id), _employee(employee_id), qty
    )


def allowed_actions(identity) -> dict[str, bool]:
    """只用于页面显示；真正的授权仍由数据库角色/过程守卫决定。"""
    roles = {row.get("role_code") for row in (identity or {}).get("roles", [])}
    is_store = "store_manager" in roles
    is_shift = "shift_manager" in roles
    return {
        "adjust": is_store,
        "approve": is_store,
        "reject": is_store,
        "create": is_shift,
        "update": is_shift,
        "submit": is_shift,
        "receive": is_shift,
    }
