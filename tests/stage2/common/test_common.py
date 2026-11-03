"""共享访问层的结果集契约：顺序、空集占位、后段错误必须冒泡。

只替换 ODBC 连接，不连库。验的是 OI-14 指出的两件事：
`_rows` 以前只认第一个非空结果集、且 `nextset()` 抛错时把已读到的行当成功返回。
"""

from __future__ import annotations

import json
import sys
import unittest
from decimal import Decimal
from pathlib import Path
from unittest.mock import patch

import pyodbc

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT))

from app.common import db, errors

SESSION = {"db_login": "employee_fixture", "db_password": "test-only-placeholder"}


class Cursor:
    """按 pyodbc 的顺序推进：execute 后 description 是第一个集，nextset 前移一位。"""

    def __init__(self, sets=(), error=None, nextset_error=None):
        self._sets = [(list(columns), list(rows)) for columns, rows in sets]
        self._index = -1
        self.description = None
        self.error = error
        self.nextset_error = nextset_error
        self.sizes = None
        self.sql = None
        self.values = None
        self.closed = False

    def setinputsizes(self, sizes):
        self.sizes = sizes

    def execute(self, sql, values=()):
        self.sql, self.values = sql, list(values)
        if self.error is not None:
            raise self.error
        self._move_to(0)
        return self

    def fetchall(self):
        return list(self._sets[self._index][1])

    def nextset(self):
        if self.nextset_error is not None and self._index == 0:
            raise self.nextset_error
        return self._move_to(self._index + 1)

    def _move_to(self, index):
        if 0 <= index < len(self._sets):
            self._index = index
            self.description = [(name,) for name in self._sets[index][0]]
            return True
        self._index = -1
        self.description = None
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
    return pyodbc.ProgrammingError("42000", "[SQL Server]%s (SQLExecDirectW)" % message)


class Base(unittest.TestCase):
    def setUp(self):
        self.conn = Connection()
        patcher = patch("app.common.db.open_connection", return_value=self.conn)
        self.open_mock = patcher.start()
        self.addCleanup(patcher.stop)

    def serve(self, cursor):
        self.conn = Connection(cursor)
        self.open_mock.return_value = self.conn
        return self.conn


class ResultSetTests(Base):
    def test_single_result_set_is_returned_whole(self):
        self.serve(Cursor([(("category_id", "category_name"), [(1, "汉堡"), (2, "饮料")])]))
        sets = db.query_procedure_sets(SESSION, "sp_list_master_records")
        self.assertEqual(len(sets), 1)
        self.assertEqual(sets[0][1], {"category_id": 2, "category_name": "饮料"})
        self.assertTrue(self.conn.closed)

    def test_three_sets_keep_the_procedure_order(self):
        # C 的 sp_get_current_employee_context：员工头 / 业务角色 / 权限码
        self.serve(
            Cursor(
                [
                    (("employee_id", "job_code"), [(7, "CASHIER")]),
                    (("business_role_id",), [(1,), (2,)]),
                    (("permission_code",), [("ORDER_CREATE",)]),
                ]
            )
        )
        sets = db.query_procedure_sets(SESSION, "sp_get_current_employee_context")
        self.assertEqual([len(rows) for rows in sets], [1, 2, 1])
        self.assertEqual(sets[0][0]["job_code"], "CASHIER")
        self.assertEqual([row["business_role_id"] for row in sets[1]], [1, 2])
        self.assertEqual(sets[2][0]["permission_code"], "ORDER_CREATE")

    def test_two_sets_keep_the_procedure_order(self):
        # B 的支付详情：订单头 / 明细
        self.serve(
            Cursor(
                [
                    (("order_no",), [("A001",)]),
                    (("product_name", "qty"), [("香辣鸡腿堡", 2)]),
                ]
            )
        )
        sets = db.query_procedure_sets(SESSION, "sp_get_payment_detail")
        self.assertEqual(sets[0][0]["order_no"], "A001")
        self.assertEqual(sets[1][0]["product_name"], "香辣鸡腿堡")

    def test_an_empty_set_keeps_its_position(self):
        # 位置就是契约：中间那集空着也得占位，不能被跳过
        self.serve(
            Cursor(
                [
                    (("employee_id",), [(7,)]),
                    (("business_role_id",), []),
                    (("permission_code",), [("ORDER_CREATE",)]),
                ]
            )
        )
        sets = db.query_procedure_sets(SESSION, "sp_get_current_employee_context")
        self.assertEqual(len(sets), 3)
        self.assertEqual(sets[1], [])
        self.assertEqual(sets[2][0]["permission_code"], "ORDER_CREATE")

    def test_a_procedure_without_result_sets_returns_an_empty_list(self):
        self.serve(Cursor())
        self.assertEqual(db.query_procedure_sets(SESSION, "sp_register_customer_for_order"), [])

    def test_first_non_empty_is_unchanged_for_single_set_callers(self):
        self.serve(Cursor([(("category_id",), [])]))
        self.assertEqual(db.query_procedure(SESSION, "sp_list_master_records"), [])
        self.serve(Cursor([(("category_id",), [(1,)])]))
        self.assertEqual(db.query_procedure(SESSION, "sp_list_master_records"), [{"category_id": 1}])

    def test_execute_procedure_still_returns_the_first_non_empty_set(self):
        self.serve(Cursor([(("product_id",), [(9,)])]))
        rows = db.execute_procedure(SESSION, "sp_create_product")
        self.assertEqual(rows, [{"product_id": 9}])

    def test_decimal_and_unicode_survive_the_round_trip(self):
        self.serve(Cursor([(("price", "name"), [(Decimal("9.90"), "香辣鸡腿堡")])]))
        rows = db.query_procedure(SESSION, "sp_list_sale_products")
        self.assertEqual(rows[0]["price"], Decimal("9.90"))
        json.dumps(db.jsonable(rows), ensure_ascii=False)


class ErrorPropagationTests(Base):
    """后段语句的错不许被吞：返回了行、错误却不见了，是最难查的一类。"""

    def test_nextset_error_propagates_as_an_app_error(self):
        self.serve(
            Cursor(
                [(("order_no",), [("A001",)])],
                nextset_error=sql_error("支付方式不支持该操作。 (50000)"),
            )
        )
        with self.assertRaises(errors.AppError) as found:
            db.query_procedure_sets(SESSION, "sp_get_payment_detail")
        self.assertEqual(found.exception.code, "E_RULE")

    def test_nextset_error_is_not_mistaken_for_success(self):
        # 回归 OI-14：旧实现在这里返回第一集的行，异常消失
        self.serve(
            Cursor([(("order_no",), [("A001",)])], nextset_error=sql_error("超时。 (1205)"))
        )
        with self.assertRaises(errors.AppError) as found:
            db.query_procedure(SESSION, "sp_get_payment_detail")
        self.assertEqual(found.exception.code, "E_TX")

    def test_connection_is_closed_even_when_a_later_set_fails(self):
        self.serve(Cursor([(("a",), [(1,)])], nextset_error=sql_error("出错。 (51004)")))
        with self.assertRaises(errors.AppError):
            db.query_procedure_sets(SESSION, "sp_get_current_employee_context")
        self.assertTrue(self.conn.closed)

    def test_execute_error_is_mapped_before_any_row_is_returned(self):
        self.serve(Cursor([(("a",), [(1,)])], error=sql_error("当前登录主体不是启用店长。 (51004)")))
        with self.assertRaises(errors.AppError) as found:
            db.query_procedure_sets(SESSION, "sp_list_master_records")
        self.assertEqual(found.exception.code, "E_FORBIDDEN")

    def test_an_illegal_procedure_name_never_opens_a_connection(self):
        with self.assertRaises(ValueError):
            db.query_procedure_sets(SESSION, "sp_list; DROP TABLE Product")
        self.open_mock.assert_not_called()


if __name__ == "__main__":
    unittest.main()
