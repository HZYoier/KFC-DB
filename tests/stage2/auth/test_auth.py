"""app.auth 单元测试：不连库，替换 DAO 的三结果集上下文。"""

from __future__ import annotations

import unittest
from unittest.mock import patch

from flask import session as flask_session

from app import create_app
from app.auth import dao, service
from app.common.config import DbConfig
from app.common.errors import AppError


def _context_sets():
    return [
        [{
            "employee_id": 3,
            "database_user_name": "test_cashier",
            "employee_name": "测试收银员",
            "job_code": "CASHIER",
        }],
        [{"business_role_id": 3, "role_code": "cashier", "role_name": "收银员"}],
        [
            {"permission_code": "sp_create_order", "permission_name": "创建订单"},
            {"permission_code": "sp_get_current_employee_context", "permission_name": "当前员工身份上下文"},
        ],
    ]


class AuthTests(unittest.TestCase):
    def setUp(self):
        service.reset_store()
        self.app = create_app(DbConfig(driver="ODBC Driver 18 for SQL Server", server="localhost", database="KFC_DB"))
        self.app.config.update(TESTING=True)
        self.client = self.app.test_client()
        self.real_fetch = dao.fetch_employee_context
        self.fetch = patch("app.auth.dao.fetch_employee_context", return_value=_context_sets())
        self.fetch_mock = self.fetch.start()
        self.addCleanup(self.fetch.stop)

    def _login(self, login="test_cashier", password="secret", next_target=""):
        return self.client.post(
            "/login",
            data={"login": login, "password": password, "next": next_target},
            follow_redirects=False,
        )

    def _token(self):
        with self.client.session_transaction() as session:
            return session.get("auth_token")

    def test_01_login_form(self):
        response = self.client.get("/login")
        self.assertEqual(response.status_code, 200)
        self.assertIn("数据库登录名", response.get_data(as_text=True))

    def test_02_login_success_and_no_password_in_cookie(self):
        response = self._login()
        self.assertEqual(response.status_code, 302)
        self.assertEqual(response.headers["Location"], "/")
        self.assertTrue(self._token())
        with self.client.session_transaction() as session:
            self.assertNotIn("db_password", session)
            self.assertNotIn("db_login", session)
        self.assertEqual(self.fetch_mock.call_args[0][0]["db_login"], "test_cashier")

    def test_03_identity_page(self):
        self._login()
        response = self.client.get("/")
        self.assertEqual(response.status_code, 200)
        body = response.get_data(as_text=True)
        self.assertIn("测试收银员", body)
        self.assertIn("cashier", body)
        self.assertIn("sp_create_order", body)
        self.assertIn("/orders/", body)
        self.assertNotIn("/inventory/", body)

    def test_04_login_failure(self):
        self.fetch_mock.side_effect = AppError("E_AUTH")
        response = self._login(password="wrong")
        self.assertEqual(response.status_code, 401)
        self.assertIn("账号或口令不正确", response.get_data(as_text=True))
        self.assertFalse(self._token())

    def test_05_input_required(self):
        response = self._login(login="", password="")
        self.assertEqual(response.status_code, 400)
        self.assertIn("请输入数据库登录名和口令", response.get_data(as_text=True))
        self.fetch_mock.assert_not_called()

    def test_06_logout_clears_session(self):
        self._login()
        response = self.client.post("/logout", follow_redirects=False)
        self.assertEqual(response.status_code, 302)
        self.assertFalse(self._token())
        response = self.client.get("/")
        self.assertEqual(response.status_code, 302)
        self.assertTrue(response.headers["Location"].startswith("/login"))

    def test_07_safe_next(self):
        response = self._login(next_target="/master/")
        self.assertEqual(response.status_code, 302)
        self.assertEqual(response.headers["Location"], "/master/")
        self.client.post("/logout")
        response = self._login(next_target="https://evil.example/")
        self.assertEqual(response.status_code, 302)
        self.assertEqual(response.headers["Location"], "/")

    def test_08_current_employee_session(self):
        self._login()
        token = self._token()
        with self.app.test_request_context():
            flask_session["auth_token"] = token
            current = service.current_employee_session()
        self.assertEqual(current["db_login"], "test_cashier")
        self.assertEqual(current["db_password"], "secret")
        self.assertEqual(current["role"], "cashier")

    def test_09_dao_three_result_sets(self):
        with patch("app.auth.dao.db.query_procedure_sets", return_value=_context_sets()) as fetch:
            result = self.real_fetch({"db_login": "test_cashier", "db_password": "secret", "role": ""})
        fetch.assert_called_once_with(
            {"db_login": "test_cashier", "db_password": "secret", "role": ""},
            "sp_get_current_employee_context",
        )
        self.assertEqual(len(result), 3)
        self.assertEqual(result[0][0]["employee_id"], 3)
        self.assertEqual(result[1][0]["role_code"], "cashier")
        self.assertEqual(result[2][0]["permission_code"], "sp_create_order")

    def test_10_stale_identity_detection(self):
        self.assertTrue(service.is_stale_identity(AppError("E_FORBIDDEN", sql_number=51004)))
        self.assertTrue(service.is_stale_identity(AppError("E_DB", sql_number=18456)))
        self.assertFalse(service.is_stale_identity(AppError("E_FORBIDDEN", sql_number=229)))


if __name__ == "__main__":
    unittest.main()
