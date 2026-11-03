"""app.inventory 单元测试：不连库，验证输入边界、参数定型和登录门。"""

from __future__ import annotations

import unittest
from decimal import Decimal
from unittest.mock import patch

from flask import render_template

from app import create_app
from app.auth import service as auth_service
from app.common.config import DbConfig
from app.common.errors import AppError
from app.inventory import service


class InventoryServiceTests(unittest.TestCase):
    def test_01_qty_boundaries(self):
        with self.assertRaises(AppError):
            service._qty("0")
        with self.assertRaises(AppError):
            service._qty("-1")
        with self.assertRaises(AppError):
            service._qty("1.2345")
        self.assertEqual(service._qty("1.230"), Decimal("1.230"))

    def test_02_adjust_binds_typed_params(self):
        with patch("app.inventory.dao.execute_procedure", return_value=[]) as execute:
            service.adjust_inventory({}, 7, 3, "-2.500", "盘亏")
        _, name, params = execute.call_args.args
        self.assertEqual(name, "sp_adjust_inventory")
        self.assertEqual([param.value for param in params], [3, Decimal("-2.5"), 7, "盘亏"])

    def test_03_create_suggestion_binds(self):
        with patch("app.inventory.dao.execute_procedure", return_value=[]) as execute:
            service.create_suggestion({}, 7, 2, "10.500")
        _, name, params = execute.call_args.args
        self.assertEqual(name, "sp_create_replenishment_suggestion")
        self.assertEqual([param.value for param in params], [2, Decimal("10.5"), 7])

    def test_04_receive_optional_none(self):
        with patch("app.inventory.dao.execute_procedure", return_value=[]) as execute:
            service.receive_inventory({}, 7, 9, "")
        _, name, params = execute.call_args.args
        self.assertEqual(name, "sp_receive_inventory")
        self.assertIsNone(params[2].value)

    def test_05_reject_requires_reason(self):
        with self.assertRaises(AppError):
            service.reject_suggestion({}, 7, 9, "   ")

    def test_06_list_inventory_uses_view(self):
        with patch("app.inventory.dao.query", return_value=[{"ingredient_id": 1}]) as query:
            rows = service.list_inventory({})
        self.assertEqual(rows[0]["ingredient_id"], 1)
        self.assertIn("v_inventory_available", query.call_args.args[1])

    def test_07_list_movements_filter(self):
        with patch("app.inventory.dao.query", return_value=[]) as query:
            service.list_movements({}, "5")
        self.assertIn("WHERE ingredient_id", query.call_args.args[1])
        self.assertEqual(query.call_args.args[2][0].value, 5)

    def test_08_allowed_actions(self):
        store = {"roles": [{"role_code": "store_manager"}]}
        shift = {"roles": [{"role_code": "shift_manager"}]}
        cashier = {"roles": [{"role_code": "cashier"}]}
        self.assertTrue(service.allowed_actions(store)["adjust"])
        self.assertFalse(service.allowed_actions(store)["create"])
        self.assertTrue(service.allowed_actions(shift)["create"])
        self.assertFalse(service.allowed_actions(cashier)["adjust"])

    def test_09_route_requires_login(self):
        auth_service.reset_store()
        app = create_app(DbConfig(driver="ODBC Driver 18 for SQL Server", server="localhost", database="KFC_DB"))
        app.config.update(TESTING=True)
        response = app.test_client().get("/inventory/")
        self.assertEqual(response.status_code, 302)
        self.assertTrue(response.headers["Location"].startswith("/login"))

    def test_10_template_renders(self):
        app = create_app(DbConfig(driver="ODBC Driver 18 for SQL Server", server="localhost", database="KFC_DB"))
        identity = {
            "employee": {"employee_name": "测试店长", "database_user_name": "test_store_manager", "job_code": "STORE_MANAGER"},
            "roles": [{"role_code": "store_manager", "role_name": "店长"}],
            "permissions": [],
        }
        inventory = [{
            "ingredient_id": 1, "ingredient_name": "生菜", "unit_name": "kg",
            "ingredient_status": "ACTIVE", "on_hand_qty": Decimal("10.000"),
            "locked_qty": Decimal("1.000"), "available_qty": Decimal("9.000"),
            "safety_stock_qty": Decimal("2.000"), "is_low_stock": False,
        }]
        allowed = {key: True for key in ("adjust", "approve", "reject", "create", "update", "submit", "receive")}
        with app.test_request_context("/inventory/"):
            html = render_template(
                "inventory/index.html", identity=identity, inventory=inventory,
                movements=[], suggestions=[], allowed=allowed, error=None,
                notice=None, ingredient_id="",
            )
        self.assertIn("库存与补货", html)
        self.assertIn("生菜", html)
        self.assertIn("库存调整", html)


if __name__ == "__main__":
    unittest.main()
