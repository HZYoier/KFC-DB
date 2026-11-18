"""C 身份页菜单：销售报表入口由数据库返回的权限码决定，不在模板里写死岗位。"""

from __future__ import annotations

import unittest

from flask import render_template

from app import create_app
from app.common.config import DbConfig


def _identity(*permission_codes: str) -> dict:
    return {
        "employee": {
            "employee_name": "测试店长",
            "database_user_name": "test_store_manager",
            "job_code": "STORE_MANAGER",
        },
        "roles": [{"role_code": "store_manager", "role_name": "店长"}],
        "permissions": [
            {"permission_code": code, "permission_name": code}
            for code in permission_codes
        ],
    }


class ReportsMenuTests(unittest.TestCase):
    def setUp(self):
        self.app = create_app(
            DbConfig(
                driver="ODBC Driver 18 for SQL Server",
                server="test-only",
                database="KFC_DB",
            )
        )

    def test_reports_link_is_visible_with_permission_code(self):
        with self.app.test_request_context("/"):
            html = render_template("auth/index.html", identity=_identity("sp_sales_report"))
        self.assertIn("/reports/sales", html)
        self.assertIn("销售报表", html)

    def test_reports_link_is_hidden_without_permission_code(self):
        with self.app.test_request_context("/"):
            html = render_template("auth/index.html", identity=_identity("sp_list_employee_roles"))
        self.assertNotIn("/reports/sales", html)


if __name__ == "__main__":
    unittest.main()
