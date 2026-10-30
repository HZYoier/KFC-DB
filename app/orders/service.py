"""B order validation; no pricing, SQL, role impersonation or automatic retries.

SQL remains authoritative for employee jobs, order states and cross-domain writes.
The C authentication layer must supply request-local real SQL credentials.
"""
import json
from decimal import Decimal

from app.common.errors import AppError
from app.orders import dao


def _positive_int(value, maximum=2**63-1):
    if type(value) is not int or not 1 <= value <= maximum:
        raise AppError('E_INPUT')
    return value


def _varchar(value, length, *, nullable=False):
    if value is None and nullable:
        return None
    if not isinstance(value, str) or not value.strip() or len(value) > length:
        raise AppError('E_INPUT')
    return value


def _session(session):
    dao.require_employee_session(session)


def create_order(session, customer_id, fulfillment_method, order_no, items):
    _session(session)
    _positive_int(customer_id)
    if fulfillment_method not in ('PICKUP', 'DELIVERY'):
        raise AppError('E_INPUT')
    _varchar(order_no, 50)
    if not isinstance(items, list) or not items:
        raise AppError('E_INPUT')
    normalized, seen = [], set()
    for item in items:
        if not isinstance(item, dict) or set(item) != {'product_id', 'quantity'}:
            raise AppError('E_INPUT')
        product = _positive_int(item['product_id'])
        quantity = _positive_int(item['quantity'], 2**31-1)
        if product in seen:
            raise AppError('E_INPUT')
        seen.add(product)
        normalized.append({'product_id': product, 'quantity': quantity})
    return dao.create_order(session, customer_id, fulfillment_method, order_no, json.dumps(normalized, ensure_ascii=False, separators=(',', ':')))


def pay_order(session, order_id, payment_method, paid_amount, third_party_txn_no=None):
    _session(session)
    _positive_int(order_id)
    _varchar(payment_method, 20)
    _varchar(third_party_txn_no, 100, nullable=True)
    if not isinstance(paid_amount, Decimal) or not paid_amount.is_finite() or not Decimal('0') < paid_amount <= Decimal('99999999.99'):
        raise AppError('E_INPUT')
    # Avoid quantize/context rounding: every nonzero fractional digit beyond cents is invalid.
    digits = paid_amount.as_tuple()
    if digits.exponent < -2 and any(digits.digits[digits.exponent + 2:]):
        raise AppError('E_INPUT')
    return dao.pay_order(session, order_id, payment_method, paid_amount, third_party_txn_no)


def start_production(session, order_id):
    _session(session)
    return dao.start_production(session, _positive_int(order_id))


def finish_production(session, order_id):
    _session(session)
    return dao.finish_production(session, _positive_int(order_id))


def pick_up_order(session, order_id):
    _session(session)
    return dao.pick_up_order(session, _positive_int(order_id))


def pick_up_delivery(session, order_id, rider_employee_id):
    _session(session)
    return dao.pick_up_delivery(session, _positive_int(order_id), _positive_int(rider_employee_id))


def confirm_delivery(session, order_id):
    _session(session)
    return dao.confirm_delivery(session, _positive_int(order_id))


def cancel_or_refund_order(session, order_id, reason, operator_employee_id):
    _session(session)
    if reason not in ('CANCEL', 'PAYMENT_TIMEOUT', 'REFUND'):
        raise AppError('E_INPUT')
    return dao.cancel_or_refund_order(session, _positive_int(order_id), reason, _positive_int(operator_employee_id))
