"""app.auth 顾客自助页面测试：不连库，替换 cust_app DAO。"""

from __future__ import annotations

import unittest
from unittest.mock import patch

from app import create_app
from app.auth import customer_service
from app.common.config import DbConfig
from app.common.errors import AppError


class CustomerServiceTests(unittest.TestCase):
    def setUp(self):
        self.app = create_app(
            DbConfig(driver="ODBC Driver 18 for SQL Server", server="localhost", database="KFC_DB")
        )
        self.app.config.update(TESTING=True)
        self.client = self.app.test_client()
        self.session = patch(
            "app.auth.customer_service._session",
            return_value={"db_login": "cust_app", "db_password": "test-only"},
        )
        self.session_mock = self.session.start()
        self.addCleanup(self.session.stop)

    def test_01_home_is_public_and_has_three_forms(self):
        response = self.client.get("/customer")
        self.assertEqual(response.status_code, 200)
        body = response.get_data(as_text=True)
        self.assertIn("顾客自助", body)
        self.assertIn("建档", body)
        self.assertIn("下自取单", body)
        self.assertIn("查我的订单", body)
        self.assertIn("/customer/register", body)
        self.assertIn("/customer/order", body)
        self.assertIn("/customer/orders", body)

    def test_02_register_rejects_bad_mobile_without_dao(self):
        with patch("app.auth.customer_service.customer_dao.register") as dao:
            response = self.client.post("/customer/register", data={"mobile": "123"})
        self.assertEqual(response.status_code, 400)
        self.assertIn("请检查输入内容", response.get_data(as_text=True))
        dao.assert_not_called()

    def test_03_register_success_renders_id_and_passes_mobile(self):
        with patch(
            "app.auth.customer_service.customer_dao.register",
            return_value=[{"customer_id": 7, "member_level_id": 1, "is_new": 1}],
        ) as dao:
            response = self.client.post("/customer/register", data={"mobile": "13800138000"})
        self.assertEqual(response.status_code, 200)
        body = response.get_data(as_text=True)
        self.assertIn("建档结果", body)
        self.assertIn("7", body)
        dao.assert_called_once()
        self.assertEqual(dao.call_args.args[1], "13800138000")

    def test_04_place_order_rejects_bad_items_without_dao(self):
        with patch("app.auth.customer_service.customer_dao.place_order") as dao:
            response = self.client.post(
                "/customer/order",
                data={"mobile": "13800138000", "items": "not-an-item"},
            )
        self.assertEqual(response.status_code, 400)
        dao.assert_not_called()

    def test_05_place_order_normalizes_line_items_and_renders_result(self):
        with patch(
            "app.auth.customer_service.customer_dao.place_order",
            return_value=[{
                "order_id": 9,
                "order_no": "ORDER-9",
                "pickup_code": "ABCDEF0123456789ABCD",
                "total_amount": "12.50",
                "order_status": "PENDING_PAYMENT",
            }],
        ) as dao:
            response = self.client.post(
                "/customer/order",
                data={"mobile": "13800138000", "items": "1 2\n3 1"},
            )
        self.assertEqual(response.status_code, 200)
        body = response.get_data(as_text=True)
        self.assertIn("ORDER-9", body)
        self.assertIn("ABCDEF0123456789ABCD", body)
        dao.assert_called_once()
        self.assertEqual(
            dao.call_args.args[2],
            '[{"product_id":1,"quantity":2},{"product_id":3,"quantity":1}]',
        )

    def test_06_place_order_rejects_duplicate_product(self):
        with patch("app.auth.customer_service.customer_dao.place_order") as dao:
            response = self.client.post(
                "/customer/order",
                data={"mobile": "13800138000", "items": "1 2\n1 3"},
            )
        self.assertEqual(response.status_code, 400)
        dao.assert_not_called()

    def test_07_list_orders_rejects_bad_pickup(self):
        with patch("app.auth.customer_service.customer_dao.list_orders") as dao:
            response = self.client.post(
                "/customer/orders",
                data={"mobile": "13800138000", "pickup": "XYZ"},
            )
        self.assertEqual(response.status_code, 400)
        dao.assert_not_called()

    def test_08_list_orders_uppercases_pickup_and_renders_rows(self):
        with patch(
            "app.auth.customer_service.customer_dao.list_orders",
            return_value=[{
                "order_id": 9,
                "order_no": "ORDER-9",
                "order_status": "PENDING_PAYMENT",
                "fulfillment_method": "PICKUP",
                "total_amount": "12.50",
                "ordered_at": "2026-11-09 12:00:00",
                "pickup_code": "ABCDEF0123456789ABCD",
            }],
        ) as dao:
            response = self.client.post(
                "/customer/orders",
                data={"mobile": "13800138000", "pickup": "abcdef0123456789abcd"},
            )
        self.assertEqual(response.status_code, 200)
        self.assertIn("ORDER-9", response.get_data(as_text=True))
        dao.assert_called_once()
        self.assertEqual(dao.call_args.args[2], "ABCDEF0123456789ABCD")

    def test_09_missing_cust_credentials_is_503_and_does_not_call_dao(self):
        self.session_mock.side_effect = AppError("E_DB")
        with patch("app.auth.customer_service.customer_dao.register") as dao:
            response = self.client.post("/customer/register", data={"mobile": "13800138000"})
        self.assertEqual(response.status_code, 503)
        self.assertIn("系统暂时无法完成操作", response.get_data(as_text=True))
        dao.assert_not_called()

    def test_10_dao_binds_customer_place_order_contract_types(self):
        with patch("app.auth.customer_dao.execute_procedure", return_value=[]) as execute:
            customer_service.place_order("13800138000", "1 2")
        execute.assert_called_once()
        name = execute.call_args.args[1]
        params = execute.call_args.args[2]
        self.assertEqual(name, "sp_customer_place_order")
        self.assertEqual(
            [param.value for param in params],
            ["13800138000", '[{"product_id":1,"quantity":2}]', "PICKUP", None, None, None],
        )


if __name__ == "__main__":
    unittest.main()
