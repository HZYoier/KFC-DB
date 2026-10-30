"""B Orders boundary tests: real service/DAO/Common, fake only external ODBC connection."""
import importlib.util
import json
from decimal import Decimal
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT))
from app.common import db, errors

SESSION = {'db_login': 'employee_fixture', 'db_password': 'test-only-placeholder', 'role': 'CASHIER'}


class Cursor:
    description = None
    def setinputsizes(self, sizes):
        self.sizes = sizes
    def execute(self, sql, values):
        self.sql, self.values = sql, values
        return self
    def nextset(self):
        return False


class Connection:
    def __init__(self):
        self.cur, self.closed = Cursor(), False
    def cursor(self):
        return self.cur
    def close(self):
        self.closed = True


class OrdersTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue((ROOT / 'app/orders/service.py').exists(), 'B Orders implementation is missing')
        from app.orders import service
        self.service = service
        self.conn = Connection()
        self.open = patch('app.common.db.open_connection', return_value=self.conn)
        self.mock_open = self.open.start()
        self.addCleanup(self.open.stop)

    def reject(self, callback, code='E_INPUT'):
        with self.assertRaises(errors.AppError) as found:
            callback()
        self.assertEqual(found.exception.code, code)
        self.mock_open.assert_not_called()

    def test_valid_order_keeps_snapshot_price_out_of_client_payload(self):
        result = self.service.create_order(SESSION, 3, 'PICKUP', 'B-UNIT-001', [{'product_id': 7, 'quantity': 2}])
        self.assertEqual(result, [])  # deployed procedure deliberately has no business result set
        self.assertEqual(self.conn.cur.sql, '{CALL dbo.sp_create_order (?, ?, ?, ?)}')
        self.assertEqual(self.conn.cur.values[:3], [3, 'PICKUP', 'B-UNIT-001'])
        self.assertEqual(json.loads(self.conn.cur.values[3]), [{'product_id': 7, 'quantity': 2}])
        self.assertEqual(self.conn.cur.sizes[0][0], db.p_bigint(1).sql_type)
        self.assertEqual(self.conn.cur.sizes[3], (db.p_nvarchar('', 0).sql_type, 0, 0))
        self.assertTrue(self.conn.closed)

    def test_missing_identity_never_falls_back_to_deployment_connection(self):
        for session in [None, {}, {'role': 'CASHIER'}, {'db_login': 'x'}, {'db_login': '', 'db_password': 'x'}]:
            with self.subTest(session_keys=list(session or {})):
                self.reject(lambda: self.service.start_production(session, 1), 'E_AUTH')

    def test_bool_and_out_of_range_ids_are_not_bigints(self):
        for value in [True, 0, -1, 2**63, '1', None]:
            with self.subTest(value=value):
                self.reject(lambda: self.service.start_production(SESSION, value))

    def test_client_price_or_component_fields_are_rejected(self):
        self.reject(lambda: self.service.create_order(SESSION, 3, 'PICKUP', 'N', [{'product_id': 7, 'quantity': 1, 'unit_price': '0.01'}]))

    def test_empty_and_duplicate_top_level_items_fail_before_connection(self):
        for items in [[], [{'product_id': 7, 'quantity': 1}, {'product_id': 7, 'quantity': 2}]]:
            with self.subTest(items=items):
                self.reject(lambda: self.service.create_order(SESSION, 3, 'PICKUP', 'N', items))

    def test_quantity_and_order_number_boundaries(self):
        self.reject(lambda: self.service.create_order(SESSION, 3, 'PICKUP', 'x'*51, [{'product_id': 7, 'quantity': 1}]))
        self.reject(lambda: self.service.create_order(SESSION, 3, 'PICKUP', 'N', [{'product_id': 7, 'quantity': True}]))
        self.reject(lambda: self.service.create_order(SESSION, 3, 'DELIVERY;DROP', 'N', [{'product_id': 7, 'quantity': 1}]))

    def test_payment_decimal_and_explicit_null_keep_exact_binding(self):
        self.service.pay_order(SESSION, 9, 'CASH', Decimal('24.10'), None)
        self.assertEqual(self.conn.cur.sql, '{CALL dbo.sp_pay_order (?, ?, ?, ?)}')
        self.assertEqual(self.conn.cur.values, [9, 'CASH', Decimal('24.10'), None])
        self.assertEqual(self.conn.cur.sizes[2][1:], (10, 2))
        self.assertEqual(self.conn.cur.sizes[3][1], 100)

    def test_money_rejects_float_nan_fraction_and_overflow(self):
        for money in [24.1, True, Decimal('NaN'), Decimal('Infinity'), Decimal('-1'), Decimal('0'), Decimal('1.001'), Decimal('100000000')]:
            with self.subTest(money=str(money)):
                self.reject(lambda: self.service.pay_order(SESSION, 9, 'CASH', money, None))

    def test_nonempty_payment_label_is_not_an_unapproved_ascii_enum(self):
        try:
            self.service.pay_order(SESSION, 9, '现金', Decimal('24.10'), None)
        except errors.AppError:
            self.fail('Nonempty payment labels must not be rejected by an invented ASCII-only rule')
        self.assertEqual(self.conn.cur.values[1], '现金')

    def test_decimal_trailing_zero_is_not_fractional_cent_rounding(self):
        self.service.pay_order(SESSION, 9, 'CASH', Decimal('24.1000'), None)
        self.assertEqual(self.conn.cur.values[2], Decimal('24.10'))

    def test_long_json_is_bound_as_max_not_silently_truncated(self):
        self.service.create_order(SESSION, 3, 'PICKUP', 'N', [{'product_id': n, 'quantity': 1} for n in range(1, 201)])
        self.assertGreater(len(self.conn.cur.values[3]), 4000)
        self.assertEqual(self.conn.cur.sizes[3][1], 0)

    def test_single_order_actions_use_existing_procedure_names(self):
        for action, name in [('start_production', 'sp_start_production'), ('finish_production', 'sp_finish_production'), ('pick_up_order', 'sp_pick_up_order'), ('confirm_delivery', 'sp_confirm_delivery')]:
            with self.subTest(action=action):
                getattr(self.service, action)(SESSION, 9)
                self.assertEqual(self.conn.cur.sql, '{CALL dbo.'+name+' (?)}')
                self.assertEqual(self.conn.cur.values, [9])

    def test_rider_and_manager_ids_are_explicit_not_role_impersonation(self):
        self.service.pick_up_delivery(SESSION, 9, 4)
        self.assertEqual(self.conn.cur.values, [9, 4])
        self.service.cancel_or_refund_order(SESSION, 9, 'REFUND', 5)
        self.assertEqual(self.conn.cur.values, [9, 'REFUND', 5])
        self.assertEqual(self.conn.cur.sql, '{CALL dbo.sp_cancel_or_refund_order (?, ?, ?)}')

    def test_cancellation_reason_is_a_fixed_enum(self):
        self.reject(lambda: self.service.cancel_or_refund_order(SESSION, 9, 'PARTIAL_REFUND', 5))

    def test_dao_itself_rejects_missing_identity(self):
        from app.orders import dao
        self.reject(lambda: dao.start_production({}, 9), 'E_AUTH')

    def test_database_error_propagates_common_mapping_without_retry(self):
        import pyodbc
        failure = pyodbc.ProgrammingError('42000', '[SQL Server]Only a pending-payment order can be paid. (52201) (SQLExecDirectW)')
        with patch.object(self.conn.cur, 'execute', side_effect=failure) as execute:
            with self.assertRaises(errors.AppError) as found:
                self.service.pay_order(SESSION, 9, 'CASH', Decimal('24.10'), None)
        self.assertEqual(found.exception.code, 'E_RULE')
        self.assertEqual(found.exception.sql_number, 52201)
        self.assertEqual(execute.call_count, 1)
        self.assertTrue(self.conn.closed)

    def test_order_number_preserved_exactly_for_result_unknown_recovery(self):
        self.service.create_order(SESSION, 3, 'PICKUP', 'persisted-request-001', [{'product_id': 7, 'quantity': 1}])
        self.assertEqual(self.conn.cur.values[2], 'persisted-request-001')


if __name__ == '__main__':
    unittest.main(verbosity=2)
