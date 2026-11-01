"""A 主数据域边界测试：真的 service / dao / routes / Flask 应用，只把 ODBC 连接换成假的。

不连库、不需要员工账号，本机与三台机器都能直接跑。验的是可离线验的四件事：
值校验在 dao 之前就挡下、参数按声明类型绑定不靠驱动猜、路由真按 §2.4 的实体码取数、
库返回的错误按 §6.3 归成页面提示而不是 500。
"""

from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

import pyodbc

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT))

from app import create_app
from app.common import db, errors
from app.common.config import DbConfig

SESSION = {"db_login": "employee_fixture", "db_password": "test-only-placeholder"}

CATEGORY_COLUMNS = ("category_id", "category_name", "status")


class Cursor:
    def __init__(self, columns=None, rows=None, error=None):
        self.description = [(name,) for name in columns] if columns else None
        self._rows = list(rows or [])
        self.error = error
        self.sizes = None
        self.sql = None
        self.values = None

    def setinputsizes(self, sizes):
        self.sizes = sizes

    def execute(self, sql, values=()):
        self.sql, self.values = sql, list(values)
        if self.error is not None:
            raise self.error
        return self

    def fetchall(self):
        return self._rows

    def nextset(self):
        return False


class Connection:
    def __init__(self, cursor=None):
        self.cur = cursor or Cursor()
        self.closed = False

    def cursor(self):
        return self.cur

    def close(self):
        self.closed = True


def sql_error(message: str) -> pyodbc.ProgrammingError:
    """造一条库侧错误；消息号写在括号里，和 SQL Server 真实回显同形。"""
    return pyodbc.ProgrammingError("42000", "[SQL Server]%s (SQLExecDirectW)" % message)


class Base(unittest.TestCase):
    def setUp(self):
        from app.master import service
        self.service = service
        self.conn = Connection()
        patcher = patch("app.common.db.open_connection", return_value=self.conn)
        self.open_mock = patcher.start()
        self.addCleanup(patcher.stop)

    def reject(self, callback, code="E_INPUT"):
        with self.assertRaises(errors.AppError) as found:
            callback()
        self.assertEqual(found.exception.code, code)
        # 校验没过就不该碰数据库
        self.open_mock.assert_not_called()
        return found.exception


class ServiceValidationTests(Base):
    """页面层挡不住、必须由业务层挡的那些值。"""

    def test_category_name_is_required_and_bounded(self):
        for name in [None, "", "   ", "x" * 51]:
            with self.subTest(name=name):
                self.reject(lambda: self.service.create_category(SESSION, name))

    def test_money_is_positive_with_at_most_two_decimals(self):
        for value in ["0", "-1", "1.005", "abc", "", None, "100000000"]:
            with self.subTest(value=value):
                self.reject(lambda: self.service.update_product_price(SESSION, 1, value))

    def test_member_level_threshold_accepts_zero(self):
        # 默认档就是 threshold_points <= 0，别用「正整数」把它挡掉
        self.service.create_member_level(SESSION, "普通", "1.00", "0")
        self.assertEqual(self.conn.cur.values[2], 0)

    def test_multiplier_rejects_third_decimal(self):
        self.reject(lambda: self.service.create_member_level(SESSION, "银卡", "1.005", "100"))

    def test_product_type_is_a_fixed_enum(self):
        for kind in ["", "DRINK", None]:
            with self.subTest(kind=kind):
                self.reject(lambda: self.service.create_product(SESSION, "香辣鸡腿堡", "18.00", kind, 1))
        # 大小写与首尾空格按规范化处理，不是非法值
        self.service.create_product(SESSION, "香辣鸡腿堡", "18.00", " single ", 1)
        self.assertEqual(self.conn.cur.values[2], "SINGLE")

    def test_status_is_a_fixed_enum(self):
        self.reject(lambda: self.service.update_product_status(SESSION, 1, "DISABLED"))
        self.service.update_product_status(SESSION, 1, "inactive")
        self.assertEqual(self.conn.cur.values, [1, "INACTIVE"])

    def test_mobile_must_be_eleven_digits(self):
        for mobile in ["", "1390000000", "139000000022", "1390000000a", None]:
            with self.subTest(mobile=mobile):
                self.reject(lambda: self.service.create_customer(SESSION, mobile, "GUEST"))

    def test_customer_type_is_a_fixed_enum(self):
        self.reject(lambda: self.service.create_customer(SESSION, "13900000002", "VIP"))

    def test_number_fields_reject_non_numeric_and_out_of_range(self):
        for value in ["abc", "", None, "0", "-3", "8"]:
            with self.subTest(value=value):
                self.reject(
                    lambda: self.service.add_promotion_product_rule(
                        SESSION, "1", "1", value, "10:00", "11:00", "9.90", "0"
                    )
                )

    def test_clock_must_be_24h(self):
        for value in ["25:00", "10:70", "1000", "", None]:
            with self.subTest(value=value):
                self.reject(
                    lambda: self.service.add_promotion_product_rule(
                        SESSION, "1", "1", "1", value, "11:00", "9.90", "0"
                    )
                )

    def test_promotion_end_must_be_after_start(self):
        self.reject(
            lambda: self.service.create_promotion(
                SESSION, "双十一", "FIXED", "2026-11-11T10:00", "2026-11-11T10:00"
            )
        )
        self.reject(
            lambda: self.service.create_promotion(
                SESSION, "双十一", "FIXED", "2026-11-11T10:00", "2026-11-10T10:00"
            )
        )

    def test_bom_lines_become_the_json_the_procedure_expects(self):
        self.service.set_product_bom(SESSION, 1, "1 0.25\n\n3,0.500\n")
        self.assertEqual(
            json.loads(self.conn.cur.values[1]),
            [{"ingredient_id": 1, "usage_qty": "0.25"}, {"ingredient_id": 3, "usage_qty": "0.500"}],
        )

    def test_bom_lines_reject_anything_but_pairs(self):
        for text in ["abc", "1", "1 2 3", "1 abc"]:
            with self.subTest(text=text):
                self.reject(lambda: self.service.set_product_bom(SESSION, 1, text))

    def test_empty_bom_text_clears_instead_of_failing(self):
        self.service.set_product_bom(SESSION, 1, "")
        self.assertEqual(json.loads(self.conn.cur.values[1]), [])

    def test_combo_quantity_must_be_a_positive_integer(self):
        self.reject(lambda: self.service.set_combo_component(SESSION, 1, "4 1.5"))

    def test_take_is_bounded_instead_of_silently_clamped(self):
        for take in [0, 201, -1, "abc"]:
            with self.subTest(take=take):
                self.reject(lambda: self.service.list_sale_products(SESSION, take))


class DaoBindingTests(Base):
    """参数必须按 §2.4 与 04 的签名显式定型，过程名与顺序不能走样。"""

    def test_list_master_records_binds_entity_then_status(self):
        self.conn.cur = Cursor(columns=CATEGORY_COLUMNS, rows=[(1, "汉堡", "ACTIVE")])
        rows = self.service.list_master_records(SESSION, "category", None)
        self.assertEqual(rows[0]["category_name"], "汉堡")
        self.assertEqual(self.conn.cur.sql, "{CALL dbo.sp_list_master_records (?, ?)}")
        self.assertEqual(self.conn.cur.values, ["CATEGORY", None])
        self.assertEqual(self.conn.cur.sizes[0], (pyodbc.SQL_VARCHAR, 30, 0))
        self.assertEqual(self.conn.cur.sizes[1], (pyodbc.SQL_VARCHAR, 20, 0))
        self.assertTrue(self.conn.closed)

    def test_list_master_records_passes_status_through(self):
        self.service.list_master_records(SESSION, "product", "ACTIVE")
        self.assertEqual(self.conn.cur.values, ["PRODUCT", "ACTIVE"])

    def test_list_master_records_rejects_a_status_that_is_not_an_enum(self):
        self.reject(lambda: self.service.list_master_records(SESSION, "product", "DELETED"))

    def test_sale_products_take_defaults_to_one_hundred(self):
        self.service.list_sale_products(SESSION)
        self.assertEqual(self.conn.cur.sql, "{CALL dbo.sp_list_sale_products (?)}")
        self.assertEqual(self.conn.cur.values, [100])
        self.assertEqual(self.conn.cur.sizes[0], (pyodbc.SQL_INTEGER, 0, 0))

    def test_find_customer_binds_mobile_as_varchar_twenty(self):
        self.service.find_customer_for_order(SESSION, " 13900000002 ")
        self.assertEqual(self.conn.cur.sql, "{CALL dbo.sp_find_customer_for_order (?)}")
        self.assertEqual(self.conn.cur.values, ["13900000002"])
        self.assertEqual(self.conn.cur.sizes[0], (pyodbc.SQL_VARCHAR, 20, 0))

    def test_register_delegates_and_re_reads_the_new_id(self):
        # 过程没有结果集，所以服务层要么回查、要么什么都不回；这里确认是回查
        self.conn.cur = Cursor(columns=("customer_id",), rows=[(9,)])
        rows = self.service.register_customer_for_order(SESSION, "13900001399")
        self.assertEqual(rows[0]["customer_id"], 9)
        self.assertEqual(self.conn.cur.sql, "{CALL dbo.sp_find_customer_for_order (?)}")

    def test_create_product_parameter_order_and_types(self):
        self.service.create_product(SESSION, "香辣鸡腿堡", "18.00", "SINGLE", "1")
        self.assertEqual(self.conn.cur.sql, "{CALL dbo.sp_create_product (?, ?, ?, ?)}")
        self.assertEqual(self.conn.cur.values, ["香辣鸡腿堡", 18, "SINGLE", 1])
        self.assertEqual(self.conn.cur.sizes[0], (pyodbc.SQL_WVARCHAR, 50, 0))
        self.assertEqual(self.conn.cur.sizes[1], (pyodbc.SQL_DECIMAL, 10, 2))
        self.assertEqual(self.conn.cur.sizes[3], (pyodbc.SQL_BIGINT, 0, 0))

    def test_ingredient_quantity_keeps_three_decimals(self):
        self.service.create_ingredient(SESSION, "生菜", "片", "12.345")
        self.assertEqual(self.conn.cur.sizes[2], (pyodbc.SQL_DECIMAL, 12, 3))

    def test_promotion_rule_time_uses_the_time2_type(self):
        from datetime import time

        self.service.add_promotion_product_rule(
            SESSION, 1, 2, 3, "10:00", "14:30", "9.90", "5"
        )
        self.assertEqual(self.conn.cur.sql, "{CALL dbo.sp_add_promotion_product_rule (?, ?, ?, ?, ?, ?, ?)}")
        self.assertEqual(self.conn.cur.values[3:5], [time(10, 0), time(14, 30)])
        self.assertEqual(self.conn.cur.sizes[3], (pyodbc.SQL_SS_TIME2, 0, 0))
        self.assertEqual(self.conn.cur.values[6], 5)

    def test_bom_json_is_bound_as_max_not_truncated(self):
        lines = "\n".join("%d 1.000" % n for n in range(1, 301))
        self.service.set_product_bom(SESSION, 1, lines)
        self.assertGreater(len(self.conn.cur.values[1]), 4000)
        self.assertEqual(self.conn.cur.sizes[1], (pyodbc.SQL_WVARCHAR, 0, 0))


class RouteTests(unittest.TestCase):
    """页面层的真实渲染：真应用、真路由、真模板，只把连接换掉。"""

    def setUp(self):
        cfg = DbConfig(
            driver="ODBC Driver 18 for SQL Server",
            server="unit-test",
            database="KFC_DB",
            log_level="CRITICAL",
        )
        self.app = create_app(cfg)
        self.app.config["TESTING"] = True
        self.client = self.app.test_client()
        with self.client.session_transaction() as flask_session:
            flask_session.update(SESSION)

    def serve(self, cursor):
        patcher = patch("app.common.db.open_connection", return_value=Connection(cursor))
        self.open_mock = patcher.start()
        self.addCleanup(patcher.stop)
        return self.open_mock

    def test_index_lists_all_nine_entities(self):
        self.serve(Cursor())
        page = self.client.get("/master/")
        self.assertEqual(page.status_code, 200)
        self.assertEqual(page.data.decode().count('class="card"'), 9)
        self.open_mock.assert_not_called()

    def test_list_page_renders_rows_from_the_procedure(self):
        self.serve(Cursor(columns=CATEGORY_COLUMNS, rows=[(1, "汉堡", "ACTIVE"), (2, "饮料", "INACTIVE")]))
        page = self.client.get("/master/category")
        html = page.data.decode()
        self.assertEqual(page.status_code, 200)
        self.assertIn("汉堡", html)
        self.assertIn("饮料", html)
        self.assertIn("共 2 行", html)

    def test_list_page_sends_the_entity_code_not_the_url_slug(self):
        cursor = Cursor(columns=CATEGORY_COLUMNS, rows=[])
        self.serve(cursor)
        self.client.get("/master/member-level?status=ACTIVE")
        self.assertEqual(cursor.values, ["MEMBER_LEVEL", "ACTIVE"])

    def test_unknown_entity_is_404_without_touching_the_database(self):
        self.serve(Cursor())
        self.assertEqual(self.client.get("/master/nope").status_code, 404)
        self.open_mock.assert_not_called()

    def test_database_rejection_becomes_a_banner_not_a_500(self):
        self.serve(Cursor(error=sql_error("该实体没有状态列。 (51000)")))
        page = self.client.get("/master/bom?status=ACTIVE")
        self.assertEqual(page.status_code, 200)
        self.assertIn('class="error"', page.data.decode())
        self.assertIn("请检查输入内容", page.data.decode())

    def test_missing_identity_surfaces_as_forbidden_banner(self):
        self.serve(Cursor(error=sql_error("当前登录主体不是启用店长，拒绝执行。 (51004)")))
        page = self.client.get("/master/category")
        self.assertEqual(page.status_code, 200)
        self.assertIn("当前账号无权执行该操作", page.data.decode())

    def test_conflict_banner_for_a_duplicate_name(self):
        self.serve(
            Cursor(error=sql_error("Violation of UNIQUE KEY constraint 'UQ_Category_category_name'. (2627)"))
        )
        page = self.client.post("/master/category/create", data={"category_name": "汉堡"})
        self.assertEqual(page.status_code, 409)
        self.assertIn("数据与现有记录冲突", page.data.decode())

    def test_empty_form_never_reaches_the_write_procedure(self):
        # 出错时页面会重新取列表，所以连接会被开一次；关键是写过程一次都没发出去
        cursor = Cursor()
        self.serve(cursor)
        page = self.client.post("/master/category/create", data={"category_name": "   "})
        self.assertEqual(page.status_code, 400)
        self.assertIn("请检查输入内容", page.data.decode())
        self.assertEqual(cursor.sql, "{CALL dbo.sp_list_master_records (?, ?)}")

    def test_successful_action_redirects_back_to_its_list(self):
        self.serve(Cursor())
        page = self.client.post("/master/category/create", data={"category_name": "甜品"})
        self.assertEqual(page.status_code, 302)
        self.assertTrue(page.headers["Location"].endswith("/master/category?ok=1"))

    def test_unknown_action_is_404(self):
        self.serve(Cursor())
        page = self.client.post("/master/category/destroy", data={})
        self.assertEqual(page.status_code, 404)
        self.open_mock.assert_not_called()


if __name__ == "__main__":
    unittest.main()
