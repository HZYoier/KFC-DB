"""B's deployed employee write interfaces; typed calls through A's Common only.

No query-proposal wrappers are exposed while the new SQL objects are absent.
Fail closed on missing credentials instead of Common's local smoke fallback.
"""
from collections.abc import Mapping

from app.common import db
from app.common.errors import AppError


def require_employee_session(session):
    if not isinstance(session, Mapping):
        raise AppError('E_AUTH')
    login, password = session.get('db_login'), session.get('db_password')
    if not isinstance(login, str) or not login.strip() or not isinstance(password, str) or not password:
        raise AppError('E_AUTH')


def _execute(session, name, params):
    require_employee_session(session)
    return db.execute_procedure(session, name, params)


def create_order(session, customer_id, fulfillment_method, order_no, items_json):
    return _execute(session, 'sp_create_order', [db.p_bigint(customer_id), db.p_varchar(fulfillment_method, 20), db.p_varchar(order_no, 50), db.p_nvarchar(items_json, 0)])


def pay_order(session, order_id, payment_method, paid_amount, third_party_txn_no):
    return _execute(session, 'sp_pay_order', [db.p_bigint(order_id), db.p_varchar(payment_method, 20), db.p_decimal(paid_amount, 10, 2), db.p_varchar(third_party_txn_no, 100)])


def start_production(session, order_id):
    return _execute(session, 'sp_start_production', [db.p_bigint(order_id)])


def finish_production(session, order_id):
    return _execute(session, 'sp_finish_production', [db.p_bigint(order_id)])


def pick_up_order(session, order_id):
    return _execute(session, 'sp_pick_up_order', [db.p_bigint(order_id)])


def pick_up_delivery(session, order_id, rider_employee_id):
    return _execute(session, 'sp_pick_up_delivery', [db.p_bigint(order_id), db.p_bigint(rider_employee_id)])


def confirm_delivery(session, order_id):
    return _execute(session, 'sp_confirm_delivery', [db.p_bigint(order_id)])


def cancel_or_refund_order(session, order_id, reason, operator_employee_id):
    return _execute(session, 'sp_cancel_or_refund_order', [db.p_bigint(order_id), db.p_varchar(reason, 20), db.p_bigint(operator_employee_id)])
