"""A 域 JSON 接口测试：真应用、真路由、真 service，只把 ODBC 连接换成假的。

验的是接口层自己的事：令牌不通过就不碰库、JSON 标量按表单同形字符串交出去、
数组转成过程要的 JSON 文本、错误走统一的 {code, message, request_id}。
数据库那侧的校验与绑定已有 master 套件覆盖，这里不重复。
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

from app import create_app
from app.common.config import DbConfig

SESSION = {"db_login": "employee_fixture", "db_password": "test-only-placeholder"}

PRODUCT_COLUMNS = ("product_id", "product_name", "base_price", "product_type", "status")


class Cursor:
    def __init__(self, columns=None, rows=None):
        self.description = [(name,) for name in columns] if columns else None
        self._rows = list(rows or [])
        self.sizes = None
        self.sql = None
        self.values = None

    def setinputsizes(self, sizes):
        self.sizes = sizes

    def execute(self, sql, values=()):
        self.sql, self.values = sql, list(values)
        return self

    def fetchall(self):
        return self._rows

    def nextset(self):
        return False


class Connection:
    def __init__(self, cursor=None):
        self.cur = cursor or Cursor()

    def cursor(self):
        return self.cur

    def close(self):
        pass


class ApiTests(unittest.TestCase):
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

    def serve(self, cursor=None):
        self.conn = Connection(cursor)
        patcher = patch("app.common.db.open_connection", return_value=self.conn)
        self.open_mock = patcher.start()
        self.addCleanup(patcher.stop)
        return self.conn

    def token(self):
        return self.client.get("/api/csrf").get_json()["csrf_token"]

    def write(self, path, payload, token=None):
        headers = {"Content-Type": "application/json"}
        if token != "":
            headers["X-CSRF-Token"] = self.token() if token is None else token
        return self.client.post(path, json=payload, headers=headers)

    # --- 元数据与取数 -----------------------------------------------------

    def test_meta_lists_nine_entities(self):
        body = self.client.get("/api/master/meta").get_json()
        self.assertEqual(len(body["entities"]), 9)
        self.assertEqual(body["entities"][1]["slug"], "product")
        self.assertEqual(body["entities"][1]["code"], "PRODUCT")

    def test_meta_lists_eighteen_actions(self):
        body = self.client.get("/api/master/meta").get_json()
        self.assertEqual(len(body["actions"]), 18)
        self.assertIn(
            {"entity": "product", "action": "price", "fields": ["product_id", "base_price"]},
            body["actions"],
        )

    def test_list_returns_rows_and_count(self):
        self.serve(
            Cursor(PRODUCT_COLUMNS, [(1, "香辣鸡腿堡", Decimal("19.00"), "SINGLE", "ACTIVE")])
        )
        res = self.client.get("/api/master/product")
        body = res.get_json()
        self.assertEqual(res.status_code, 200)
        self.assertEqual(body["count"], 1)
        self.assertEqual(body["rows"][0]["base_price"], "19.00")

    def test_list_passes_the_entity_code_and_status(self):
        conn = self.serve(Cursor(PRODUCT_COLUMNS, []))
        self.client.get("/api/master/product?status=ACTIVE")
        self.assertEqual(conn.cur.sql, "{CALL dbo.sp_list_master_records (?, ?)}")
        self.assertEqual(conn.cur.values, ["PRODUCT", "ACTIVE"])

    def test_list_unknown_entity_is_404_json(self):
        self.serve(Cursor(PRODUCT_COLUMNS, []))
        res = self.client.get("/api/master/nope")
        self.assertEqual(res.status_code, 404)
        self.assertEqual(res.get_json()["code"], "E_NOTFOUND")
        self.open_mock.assert_not_called()

    # --- 令牌 -------------------------------------------------------------

    def test_post_without_csrf_is_forbidden_and_skips_the_database(self):
        self.serve(Cursor())
        res = self.client.post(
            "/api/master/category/create",
            json={"category_name": "饮品"},
            headers={"Content-Type": "application/json"},
        )
        self.assertEqual(res.status_code, 403)
        self.assertEqual(res.get_json()["code"], "E_FORBIDDEN")
        self.open_mock.assert_not_called()

    def test_post_with_a_wrong_csrf_is_forbidden(self):
        self.serve(Cursor())
        res = self.write("/api/master/category/create", {"category_name": "饮品"}, "deadbeef")
        self.assertEqual(res.status_code, 403)
        self.open_mock.assert_not_called()

    def test_csrf_endpoint_token_is_accepted(self):
        conn = self.serve(Cursor())
        res = self.client.post(
            "/api/master/category/create",
            json={"category_name": "饮品"},
            headers={"Content-Type": "application/json", "X-CSRF-Token": self.token()},
        )
        self.assertEqual(res.status_code, 200)
        self.assertIn("sp_create_category", conn.cur.sql)

    # --- 写入 -------------------------------------------------------------

    def test_post_runs_the_procedure_with_form_shaped_strings(self):
        conn = self.serve(Cursor())
        res = self.write(
            "/api/master/product/create",
            {"product_name": "香辣鸡腿堡", "base_price": "18.00", "product_type": "SINGLE",
             "category_id": 1},
        )
        self.assertEqual(res.status_code, 200)
        self.assertTrue(res.get_json()["ok"])
        self.assertEqual(conn.cur.sql, "{CALL dbo.sp_create_product (?, ?, ?, ?)}")
        self.assertEqual(conn.cur.values, ["香辣鸡腿堡", 18, "SINGLE", 1])

    def test_post_validation_error_is_e_input_with_request_id(self):
        self.serve(Cursor())
        res = self.write(
            "/api/master/product/create",
            {"product_name": "", "base_price": "18.00", "product_type": "SINGLE",
             "category_id": 1},
        )
        body = res.get_json()
        self.assertEqual(res.status_code, 400)
        self.assertEqual(body["code"], "E_INPUT")
        self.assertEqual(body["message"], "请检查输入内容")
        self.assertTrue(body["request_id"])
        self.open_mock.assert_not_called()

    def test_post_unknown_action_is_404(self):
        self.serve(Cursor())
        res = self.write("/api/master/product/delete", {"product_id": 1})
        self.assertEqual(res.status_code, 404)
        self.assertEqual(res.get_json()["code"], "E_NOTFOUND")

    def test_post_array_becomes_the_json_text_the_procedure_expects(self):
        conn = self.serve(Cursor())
        res = self.write(
            "/api/master/bom/set",
            {"product_id": 1, "lines": [{"ingredient_id": 1, "usage_qty": "2.5"}]},
        )
        self.assertEqual(res.status_code, 200)
        self.assertIn("sp_set_product_bom", conn.cur.sql)
        lines = json.loads(conn.cur.values[1])
        self.assertEqual(lines, [{"ingredient_id": 1, "usage_qty": "2.5"}])
        self.assertEqual(conn.cur.sizes[1], (pyodbc.SQL_WVARCHAR, 0, 0))


if __name__ == "__main__":
    unittest.main()
