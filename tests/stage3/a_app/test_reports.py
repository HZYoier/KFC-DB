"""A 域销售报表页：只验页面与服务的形状，不连库。

sp_sales_report 由 B 的 21b 创建；这里用假 DAO 验：
日期绑定、起止顺序、两结果集契约、页面不重算金额。
"""

from __future__ import annotations

import sys
import unittest
from datetime import date
from pathlib import Path
from unittest.mock import patch

import pyodbc

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT))

from app import create_app
from app.common import db
from app.common.config import DbConfig
from app.common.errors import AppError
from app.reports import service

SUMMARY = {"order_count": 2, "sold_qty": 3, "sales_amount": 29.50}
ITEMS = [
    {"product_id": 1, "product_name": "香辣鸡腿堡", "sold_qty": 2,
     "sales_amount": 19.50, "order_count": 2},
    {"product_id": 2, "product_name": "薯条", "sold_qty": 1,
     "sales_amount": 10.00, "order_count": 1},
]


def test_app():
    cfg = DbConfig(driver="ODBC Driver 18 for SQL Server", server="test-only", database="KFC_DB")
    return create_app(cfg)


class DateBindingTests(unittest.TestCase):
    def test_date_parameter_uses_the_date_type(self):
        param = db.p_date(date(2026, 11, 1))
        self.assertEqual(param.value, date(2026, 11, 1))
        self.assertEqual(param.sql_type, pyodbc.SQL_TYPE_DATE)


class SalesReportServiceTests(unittest.TestCase):
    def test_two_sets_are_returned_unchanged(self):
        with patch.object(service.dao, "fetch_sales_report", return_value=[[SUMMARY], ITEMS]) as fetch:
            data = service.sales_report(None, "2026-11-01", "2026-11-02")
        self.assertEqual(data["summary"], SUMMARY)
        self.assertEqual(data["items"], ITEMS)
        fetch.assert_called_once_with(None, date(2026, 11, 1), date(2026, 11, 2))

    def test_reversed_range_is_rejected_before_calling_the_procedure(self):
        with patch.object(service.dao, "fetch_sales_report") as fetch:
            with self.assertRaises(AppError) as found:
                service.sales_report(None, "2026-11-02", "2026-11-01")
        self.assertEqual(found.exception.code, "E_INPUT")
        fetch.assert_not_called()

    def test_bad_date_shape_is_rejected(self):
        with self.assertRaises(AppError) as found:
            service.sales_report(None, "2026/11/01", "2026-11-02")
        self.assertEqual(found.exception.code, "E_INPUT")

    def test_empty_date_is_rejected(self):
        with self.assertRaises(AppError) as found:
            service.sales_report(None, "", "2026-11-02")
        self.assertEqual(found.exception.code, "E_INPUT")

    def test_one_result_set_is_an_internal_error(self):
        with patch.object(service.dao, "fetch_sales_report", return_value=[[SUMMARY]]):
            with self.assertRaises(AppError) as found:
                service.sales_report(None, "2026-11-01", "2026-11-02")
        self.assertEqual(found.exception.code, "E_INTERNAL")

    def test_empty_summary_set_is_an_internal_error(self):
        with patch.object(service.dao, "fetch_sales_report", return_value=[[], ITEMS]):
            with self.assertRaises(AppError) as found:
                service.sales_report(None, "2026-11-01", "2026-11-02")
        self.assertEqual(found.exception.code, "E_INTERNAL")


class SalesReportRouteTests(unittest.TestCase):
    def setUp(self):
        self.app = test_app()
        self.credentials = {"db_login": "employee_fixture", "db_password": "test-only-placeholder"}

    def test_page_renders_summary_and_items_from_the_procedure(self):
        with patch("app.auth.service.current_employee_session", return_value=self.credentials), \
             patch("app.reports.routes.current_employee_session", return_value=self.credentials), \
             patch("app.reports.service.sales_report", return_value={"summary": SUMMARY, "items": ITEMS}):
            response = self.app.test_client().get("/reports/sales?start=2026-11-01&end=2026-11-02")
        body = response.get_data(as_text=True)
        self.assertEqual(response.status_code, 200)
        self.assertIn("香辣鸡腿堡", body)
        self.assertIn("29.5", body)

    def test_page_without_query_does_not_call_the_procedure(self):
        with patch("app.auth.service.current_employee_session", return_value=self.credentials), \
             patch("app.reports.service.sales_report") as fetch:
            response = self.app.test_client().get("/reports/sales")
        self.assertEqual(response.status_code, 200)
        fetch.assert_not_called()


if __name__ == "__main__":
    unittest.main()
