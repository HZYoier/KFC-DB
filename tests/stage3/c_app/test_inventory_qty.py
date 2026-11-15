"""C 域第三阶段应用测试：补货量必须来自数据库函数，页面不重算。"""

from __future__ import annotations

import unittest
from decimal import Decimal
from unittest.mock import patch

from app.common.errors import AppError
from app.inventory import service


class ReplenishmentQtyServiceTests(unittest.TestCase):
    def test_01_default_qty_uses_database_function(self):
        with patch(
            "app.inventory.dao.query",
            return_value=[{"suggested_qty": Decimal("7.000")}],
        ) as query:
            value = service.default_suggested_qty({}, "5", "10.000", "2.000")
        self.assertEqual(value, Decimal("7.000"))
        sql = query.call_args.args[1]
        params = query.call_args.args[2]
        self.assertIn("dbo.fn_replenishment_qty", sql)
        self.assertEqual([param.value for param in params], [5, Decimal("10.000"), Decimal("2.000")])

    def test_02_blank_min_qty_binds_null(self):
        with patch(
            "app.inventory.dao.query",
            return_value=[{"suggested_qty": Decimal("3.000")}],
        ) as query:
            service.default_suggested_qty({}, 5, "10.000", "")
        params = query.call_args.args[2]
        self.assertIsNone(params[2].value)

    def test_03_negative_target_rejected_without_query(self):
        with patch("app.inventory.dao.query") as query:
            with self.assertRaises(AppError) as caught:
                service.default_suggested_qty({}, 5, "-1.000", None)
        self.assertEqual(caught.exception.code, "E_INPUT")
        query.assert_not_called()

    def test_04_null_function_result_is_notfound(self):
        with patch("app.inventory.dao.query", return_value=[{"suggested_qty": None}]):
            with self.assertRaises(AppError) as caught:
                service.default_suggested_qty({}, 5, "10.000", None)
        self.assertEqual(caught.exception.code, "E_NOTFOUND")


if __name__ == "__main__":
    unittest.main()
