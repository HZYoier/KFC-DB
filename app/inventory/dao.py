"""库存域 DAO：SQL 常量 + SqlParam，不 import pyodbc。

查询走 C 的四个只读视图；写入走既有自持事务过程，应用层不包事务。
"""

from __future__ import annotations

from app.common.db import (
    execute_procedure,
    p_bigint,
    p_decimal,
    p_varchar,
    query,
)

_SQL_INVENTORY = """
SELECT ingredient_id, ingredient_name, unit_name, ingredient_status,
       on_hand_qty, locked_qty, available_qty, safety_stock_qty,
       is_low_stock, updated_at
FROM dbo.v_inventory_available
ORDER BY ingredient_id;
"""

_SQL_MOVEMENTS = """
SELECT inventory_movement_id, ingredient_id, ingredient_name, unit_name,
       movement_type, on_hand_delta, locked_delta, reference_type, reference_id,
       reference_no, moved_at
FROM dbo.v_inventory_movement_history
WHERE ingredient_id = ?
ORDER BY moved_at DESC, inventory_movement_id DESC;
"""

_SQL_MOVEMENTS_ALL = """
SELECT inventory_movement_id, ingredient_id, ingredient_name, unit_name,
       movement_type, on_hand_delta, locked_delta, reference_type, reference_id,
       reference_no, moved_at
FROM dbo.v_inventory_movement_history
ORDER BY moved_at DESC, inventory_movement_id DESC;
"""

_SQL_REPLENISHMENT = """
SELECT replenishment_suggestion_id, ingredient_id, ingredient_name, unit_name,
       current_qty, suggested_qty, suggestion_status,
       created_by_employee_id, created_by_name, submitted_by_employee_id,
       submitted_by_name, approved_by_employee_id, approved_by_name,
       rejected_by_employee_id, rejected_by_name,
       purchase_order_id, purchase_order_no, purchase_status, approved_at,
       ordered_qty, received_qty, outstanding_qty
FROM dbo.v_replenishment_dashboard
ORDER BY replenishment_suggestion_id DESC;
"""


def list_inventory(session):
    return query(session, _SQL_INVENTORY)


def list_movements(session, ingredient_id: int | None = None):
    if ingredient_id is None:
        return query(session, _SQL_MOVEMENTS_ALL)
    return query(session, _SQL_MOVEMENTS, [p_bigint(ingredient_id)])


def list_replenishment(session):
    return query(session, _SQL_REPLENISHMENT)


def adjust_inventory(session, ingredient_id: int, on_hand_delta, employee_id: int, reason: str):
    return execute_procedure(
        session,
        "sp_adjust_inventory",
        [
            p_bigint(ingredient_id),
            p_decimal(on_hand_delta, 12, 3),
            p_bigint(employee_id),
            p_varchar(reason, 50),
        ],
    )


def create_replenishment_suggestion(session, ingredient_id: int, suggested_qty, employee_id: int):
    return execute_procedure(
        session,
        "sp_create_replenishment_suggestion",
        [p_bigint(ingredient_id), p_decimal(suggested_qty, 12, 3), p_bigint(employee_id)],
    )


def update_replenishment_suggestion(session, suggestion_id: int, suggested_qty, employee_id: int):
    return execute_procedure(
        session,
        "sp_update_replenishment_suggestion",
        [p_bigint(suggestion_id), p_decimal(suggested_qty, 12, 3), p_bigint(employee_id)],
    )


def submit_replenishment_suggestion(session, suggestion_id: int, employee_id: int):
    return execute_procedure(
        session,
        "sp_submit_replenishment_suggestion",
        [p_bigint(suggestion_id), p_bigint(employee_id)],
    )


def approve_replenishment_suggestion(session, suggestion_id: int, employee_id: int):
    return execute_procedure(
        session,
        "sp_approve_replenishment_suggestion",
        [p_bigint(suggestion_id), p_bigint(employee_id)],
    )


def reject_replenishment_suggestion(session, suggestion_id: int, employee_id: int, reason: str):
    return execute_procedure(
        session,
        "sp_reject_replenishment_suggestion",
        [p_bigint(suggestion_id), p_bigint(employee_id), p_varchar(reason, 50)],
    )


def receive_inventory(session, purchase_order_id: int, employee_id: int, received_qty=None):
    return execute_procedure(
        session,
        "sp_receive_inventory",
        [p_bigint(purchase_order_id), p_bigint(employee_id), p_decimal(received_qty, 12, 3)],
    )
