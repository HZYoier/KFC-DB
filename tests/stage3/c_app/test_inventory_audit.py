"""库存审计页的权限隔离与原料过滤。"""

import unittest
from unittest.mock import patch

from app import create_app
from app.common.config import DbConfig


class InventoryAuditTests(unittest.TestCase):
    def setUp(self):
        app = create_app(DbConfig(driver="ODBC Driver 18 for SQL Server", server="test-only", database="KFC_DB"))
        self.client = app.test_client()
        self.identity = {"employee": {"employee_id": 1}, "roles": [], "permissions": []}

    def test_audit_filters_and_displays_database_row(self):
        self.identity["permissions"] = [{"permission_code": "InventoryAudit"}]
        row = {"inventory_audit_id": 7, "ingredient_id": 3, "operated_by": "test_store_manager"}
        with (
            patch("app.inventory.routes.current_identity", return_value=self.identity),
            patch("app.auth.service.current_employee_session", return_value={"db_login": "manager"}),
            patch("app.inventory.routes.current_employee_session", return_value={"db_login": "manager"}),
            patch("app.inventory.dao.list_audit", return_value=[row]) as dao,
        ):
            response = self.client.get("/inventory/audit?ingredient_id=3")
        self.assertEqual(response.status_code, 200)
        self.assertIn("test_store_manager", response.get_data(as_text=True))
        dao.assert_called_once_with({"db_login": "manager"}, 3)

    def test_missing_permission_returns_403_before_query(self):
        with (
            patch("app.inventory.routes.current_identity", return_value=self.identity),
            patch("app.auth.service.current_employee_session", return_value={"db_login": "cashier"}),
            patch("app.inventory.routes.current_employee_session", return_value={"db_login": "cashier"}),
            patch("app.inventory.dao.list_audit") as dao,
        ):
            response = self.client.get("/inventory/audit")
        self.assertEqual(response.status_code, 403)
        dao.assert_not_called()
