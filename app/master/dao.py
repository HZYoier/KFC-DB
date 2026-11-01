"""主数据域 DAO：只负责把 service 校验过的值绑成 SqlParam 并调过程。

规矩三条：SQL 写成模块里的常量、值全部走 SqlParam、不 import pyodbc。
主数据页不读基表——列表一律经 §2.4.1 的 sp_list_master_records，写入一律经 04 的自持事务过程。
"""

from __future__ import annotations

from app.common.db import (
    execute_procedure,
    p_bigint,
    p_datetime,
    p_decimal,
    p_int,
    p_nvarchar,
    p_time,
    p_varchar,
    query,
    query_procedure,
)

# 取价逻辑已沉在 fn_get_effective_product_price + 视图里，应用层不再算一遍
_SQL_ACTIVE_PRODUCT_PRICES = """
SELECT product_id, product_name, product_type, category_id, category_name,
       base_price, effective_price, promotion_id
FROM dbo.v_active_product_price
ORDER BY category_id, product_id;
"""


# ---------------------------------------------------------------------------
# 查询（契约 §2.4.1 — §2.4.4）
# ---------------------------------------------------------------------------

def list_master_records(session, entity_code: str, status: str | None = None):
    return query_procedure(
        session,
        "sp_list_master_records",
        [p_varchar(entity_code, 30), p_varchar(status, 20)],
    )


def list_sale_products(session, take: int = 100):
    return query_procedure(session, "sp_list_sale_products", [p_int(take)])


def find_customer_for_order(session, mobile: str):
    return query_procedure(session, "sp_find_customer_for_order", [p_varchar(mobile, 20)])


def register_customer_for_order(session, mobile: str):
    # 无结果集：新 ID 靠 find_customer_for_order 回查
    return execute_procedure(session, "sp_register_customer_for_order", [p_varchar(mobile, 20)])


def list_active_product_prices(session):
    return query(session, _SQL_ACTIVE_PRODUCT_PRICES)


# ---------------------------------------------------------------------------
# 写（04 的 18 个过程，全部自持事务、按 USER_NAME() 认人）
# ---------------------------------------------------------------------------

def create_category(session, category_name: str):
    return execute_procedure(session, "sp_create_category", [p_nvarchar(category_name, 50)])


def update_category_status(session, category_id: int, status: str):
    return execute_procedure(
        session,
        "sp_update_category_status",
        [p_bigint(category_id), p_varchar(status, 20)],
    )


def create_ingredient(session, ingredient_name: str, unit_name: str, safety_stock_qty):
    return execute_procedure(
        session,
        "sp_create_ingredient",
        [p_nvarchar(ingredient_name, 50), p_nvarchar(unit_name, 50), p_decimal(safety_stock_qty, 12, 3)],
    )


def update_ingredient(session, ingredient_id: int, ingredient_name: str, unit_name: str,
                      safety_stock_qty, status: str):
    return execute_procedure(
        session,
        "sp_update_ingredient",
        [
            p_bigint(ingredient_id),
            p_nvarchar(ingredient_name, 50),
            p_nvarchar(unit_name, 50),
            p_decimal(safety_stock_qty, 12, 3),
            p_varchar(status, 20),
        ],
    )


def create_product(session, product_name: str, base_price, product_type: str, category_id: int):
    return execute_procedure(
        session,
        "sp_create_product",
        [
            p_nvarchar(product_name, 50),
            p_decimal(base_price, 10, 2),
            p_varchar(product_type, 20),
            p_bigint(category_id),
        ],
    )


def update_product_price(session, product_id: int, base_price):
    return execute_procedure(
        session,
        "sp_update_product_price",
        [p_bigint(product_id), p_decimal(base_price, 10, 2)],
    )


def update_product_status(session, product_id: int, status: str):
    return execute_procedure(
        session,
        "sp_update_product_status",
        [p_bigint(product_id), p_varchar(status, 20)],
    )


def set_product_bom(session, product_id: int, bom_json: str):
    return execute_procedure(
        session,
        "sp_set_product_bom",
        [p_bigint(product_id), p_nvarchar(bom_json, 0)],
    )


def set_combo_component(session, product_id: int, component_json: str):
    return execute_procedure(
        session,
        "sp_set_combo_component",
        [p_bigint(product_id), p_nvarchar(component_json, 0)],
    )


def create_member_level(session, level_name: str, point_multiplier, threshold_points: int):
    return execute_procedure(
        session,
        "sp_create_member_level",
        [p_nvarchar(level_name, 50), p_decimal(point_multiplier, 5, 2), p_int(threshold_points)],
    )


def update_member_level(session, member_level_id: int, level_name: str, point_multiplier,
                        threshold_points: int):
    return execute_procedure(
        session,
        "sp_update_member_level",
        [
            p_bigint(member_level_id),
            p_nvarchar(level_name, 50),
            p_decimal(point_multiplier, 5, 2),
            p_int(threshold_points),
        ],
    )


def update_member_level_status(session, member_level_id: int, status: str):
    return execute_procedure(
        session,
        "sp_update_member_level_status",
        [p_bigint(member_level_id), p_varchar(status, 20)],
    )


def create_customer(session, mobile: str, customer_type: str):
    return execute_procedure(
        session,
        "sp_create_customer",
        [p_varchar(mobile, 20), p_varchar(customer_type, 20)],
    )


def update_customer_member_level(session, customer_id: int, member_level_id: int):
    return execute_procedure(
        session,
        "sp_update_customer_member_level",
        [p_bigint(customer_id), p_bigint(member_level_id)],
    )


def create_promotion(session, promotion_name: str, promotion_type: str, start_at, end_at):
    return execute_procedure(
        session,
        "sp_create_promotion",
        [
            p_nvarchar(promotion_name, 50),
            p_varchar(promotion_type, 20),
            p_datetime(start_at),
            p_datetime(end_at),
        ],
    )


def update_promotion_status(session, promotion_id: int, status: str):
    return execute_procedure(
        session,
        "sp_update_promotion_status",
        [p_bigint(promotion_id), p_varchar(status, 20)],
    )


def add_promotion_product_rule(session, promotion_id: int, product_id: int, weekday_no: int,
                               start_time, end_time, promo_price, priority: int):
    return execute_procedure(
        session,
        "sp_add_promotion_product_rule",
        [
            p_bigint(promotion_id),
            p_bigint(product_id),
            p_int(weekday_no),
            p_time(start_time),
            p_time(end_time),
            p_decimal(promo_price, 10, 2),
            p_int(priority),
        ],
    )


def update_promotion_product_rule(session, promotion_rule_id: int, weekday_no: int,
                                  start_time, end_time, promo_price, priority: int):
    return execute_procedure(
        session,
        "sp_update_promotion_product_rule",
        [
            p_bigint(promotion_rule_id),
            p_int(weekday_no),
            p_time(start_time),
            p_time(end_time),
            p_decimal(promo_price, 10, 2),
            p_int(priority),
        ],
    )
