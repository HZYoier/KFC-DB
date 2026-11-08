"""Employee order pages; SQL remains authoritative for state and authorization."""
from decimal import Decimal, InvalidOperation
from functools import wraps
import logging
from secrets import compare_digest, token_hex
from uuid import uuid4

from flask import Blueprint, current_app, redirect, render_template, request, session, url_for
from itsdangerous import BadData, URLSafeTimedSerializer

from app.auth import current_employee_session, login_required
from app.auth.dao import fetch_employee_context
from app.auth.service import clear_if_stale
from app.common import log
from app.common.errors import AppError
from app.master import service as master
from app.orders import dao, service

bp = Blueprint('orders', __name__, url_prefix='/orders')
JOBS = {'CASHIER', 'CHEF', 'PACKER', 'WAITER', 'RIDER', 'STORE_MANAGER'}


def _attempts():
    return URLSafeTimedSerializer(current_app.secret_key, salt='orders-attempt')


def _active_employee(view):
    @wraps(view)
    def checked(*args, **kwargs):
        credentials = current_employee_session()
        if not credentials:
            raise AppError('E_AUTH')
        try:
            context = fetch_employee_context(credentials)
        except AppError as exc:
            if clear_if_stale(exc):
                return redirect(url_for('auth.login', next=url_for('orders.index')))
            raise
        if len(context) != 3 or len(context[0]) != 1:
            raise AppError('E_AUTH')
        employee = context[0][0]
        if employee['job_code'] not in JOBS:
            raise AppError('E_FORBIDDEN')
        return view(employee, credentials, *args, **kwargs)
    return checked


def _number(value):
    try:
        return int(value)
    except (TypeError, ValueError) as exc:
        raise AppError('E_INPUT') from exc


def _sets(result):
    if len(result) != 2:
        raise AppError('E_INTERNAL')
    return result


def _pay(credentials, order_id, method, amount, reference):
    try:
        service.pay_order(credentials, order_id, method, amount, reference)
    except AppError as exc:
        # With a NULL reference this driver may fail while draining results *after* commit.
        # Reconcile with a fresh read, never retry the write or claim which request paid it.
        if reference is not None or getattr(exc.cause, 'args', ())[:1] != ('24000',):
            raise
        rows = service.get_order_operation_status(credentials, order_id=order_id)
        if (len(rows) != 1 or rows[0]['payment_status'] != 'SUCCESS'
                or rows[0]['paid_amount'] != amount):
            raise
        return rows[0]['order_no']
    return None


@bp.get('/')
@login_required
@_active_employee
def index(employee, credentials):
    job = employee['job_code']
    data = {}
    try:
        if job == 'CASHIER':
            draft_number = 'B-' + uuid4().hex.upper()
            data['attempt'] = _attempts().dumps([employee['employee_id'], draft_number])
            data['draft_number'] = draft_number
            data['recent_numbers'] = session.get('orders_drafts', [])
            session['orders_drafts'] = [draft_number, *data['recent_numbers'][:4]]
            data['products'] = master.list_sale_products(credentials)
            data['orders'] = service.list_orders_for_payment(credentials)
            if request.args.get('detail'):
                data['head'], data['items'] = _sets(service.get_order_for_payment(credentials, _number(request.args['detail'])))
        elif job == 'CHEF':
            data['orders'] = dao.kitchen_queue(credentials)
        elif job == 'PACKER':
            data['orders'], data['items'] = _sets(service.list_orders_for_packing(credentials))
        elif job == 'WAITER':
            data['orders'] = dao.pickup_board(credentials)
        elif job == 'RIDER':
            data['orders'] = service.list_deliveries_available_for_pickup(credentials)
            data['mine'] = service.list_my_deliveries(credentials)
        else:
            data['orders'] = dao.manager_orders(credentials)
        if job in {'CASHIER', 'STORE_MANAGER'} and request.args.get('lookup'):
            data['status'] = service.get_order_operation_status(credentials, order_no=request.args['lookup'])
    except AppError as exc:
        if clear_if_stale(exc):
            return redirect(url_for('auth.login', next=request.path))
        raise
    csrf = session.setdefault('orders_csrf', token_hex(32))
    return render_template('orders/index.html', job=job, csrf=csrf, **data)


@bp.post('/actions/<action>')
@login_required
@_active_employee
def action(employee, credentials, action):
    expected = session.get('orders_csrf')
    if not expected or not compare_digest(expected.encode(), request.form.get('csrf', '').encode()):
        raise AppError('E_FORBIDDEN')
    job = employee['job_code']
    allowed = {
        'CASHIER': {'create', 'pay', 'register'}, 'CHEF': {'start'},
        'PACKER': {'finish', 'pickup'}, 'WAITER': set(),
        'RIDER': {'claim', 'confirm'}, 'STORE_MANAGER': {'cancel'},
    }
    if action not in allowed[job]:
        raise AppError('E_FORBIDDEN')
    form = request.form
    lookup = {}
    try:
        if action == 'register':
            master.register_customer_for_order(credentials, form.get('mobile', ''))
        elif action == 'create':
            try:
                owner, order_no = _attempts().loads(form.get('attempt', ''), max_age=3600)
            except BadData as exc:
                raise AppError('E_INPUT') from exc
            if owner != employee['employee_id']:
                raise AppError('E_FORBIDDEN')
            lookup['lookup'] = order_no
            customers = master.find_customer_for_order(credentials, form.get('mobile', ''))
            if not customers:
                raise AppError('E_NOTFOUND')
            items = []
            for product, quantity in zip(form.getlist('product'), form.getlist('quantity'), strict=True):
                if product:
                    items.append({'product_id': _number(product), 'quantity': _number(quantity)})
            # Replayed form uses the same order number; SQL uniqueness prevents duplicate orders.
            service.create_order(credentials, customers[0]['customer_id'], form.get('fulfillment'), order_no, items)
        else:
            order_id = _number(form.get('order_id'))
            if action == 'pay':
                amount = Decimal(form.get('amount', ''))
                confirmed = _pay(credentials, order_id, form.get('method'), amount, form.get('reference') or None)
                if confirmed:
                    return redirect(url_for('orders.index', reconciled=1, lookup=confirmed), code=303)
            elif action == 'start':
                service.start_production(credentials, order_id)
            elif action == 'finish':
                service.finish_production(credentials, order_id)
            elif action == 'pickup':
                service.pick_up_order(credentials, order_id)
            elif action == 'claim':
                service.pick_up_delivery(credentials, order_id, employee['employee_id'])
            elif action == 'confirm':
                service.confirm_delivery(credentials, order_id)
            elif action == 'cancel':
                service.cancel_or_refund_order(credentials, order_id, form.get('reason'), employee['employee_id'])
    except (InvalidOperation, ValueError) as exc:
        raise AppError('E_INPUT') from exc
    except AppError as exc:
        if clear_if_stale(exc):
            return redirect(url_for('auth.login', next=url_for('orders.index', **lookup)))
        log.event('orders.' + action, code=exc.code, result='error', level=logging.WARNING,
                  detail={'sql_number': exc.sql_number, 'raw': exc.raw_message})
        return render_template('orders/error.html', message=exc.user_message, lookup=lookup), exc.http_status
    return redirect(url_for('orders.index', ok=1, **lookup), code=303)
