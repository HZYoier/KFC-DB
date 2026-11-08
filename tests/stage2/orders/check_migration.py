"""Rehearse the actual stage 1/2 SQL and B acceptance in a fresh disposable database."""
import argparse
from contextlib import contextmanager
from pathlib import Path
import re
from secrets import token_hex
import sys
from uuid import uuid4

import pyodbc

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT))


def expand(path, name):
    source = (ROOT / path).read_text(encoding='utf-8-sig')
    source = re.sub(r'^\s*:r[ \t]+([^\r\n]+)$', lambda m: expand(m[1].strip(), name), source, flags=re.M)
    source = re.sub(r'^:on error exit[ \t]*$', '', source, flags=re.M)
    return (re.sub(r'\bKFC_DB\b', name, source)
            .replace('$(SourceBaseline)', 'B-disposable-rehearsal')
            .replace('$(ConfirmAppStopped)', 'YES'))


def run(conn, sql, *, verbose=False):
    sets = []
    with conn.cursor() as cursor:
        cursor.execute(sql)
        while True:
            if cursor.description is not None:
                sets.append(cursor.fetchall())
            if verbose:
                for _, message in cursor.messages:
                    print(message)
            if not cursor.nextset():
                return sets


def expect_error(conn, sql, number):
    try:
        run(conn, sql)
    except pyodbc.Error as exc:
        if f'({number})' not in str(exc):
            raise
    else:
        raise AssertionError(f'Expected SQL {number}')


def run_batches(conn, sql):
    for batch in re.split(r'^\s*GO[ \t]*(?:--[^\n]*)?$', sql, flags=re.M | re.I):
        if batch.strip():
            run(conn, batch, verbose=True)


def check_rollback(conn, migration):
    commit = '\nCOMMIT TRANSACTION;'
    assert migration.count(commit) == 1
    failed = migration.replace(commit, "\nTHROW 51964, 'B rehearsal: abort before commit', 1;" + commit)
    try:
        run_batches(conn, failed)
    except pyodbc.Error as exc:
        if '(51964)' not in str(exc):
            raise
    else:
        raise AssertionError('Injected migration failure was not reported')
    finally:
        run(conn, 'IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;')
    assert tuple(run(conn, """SELECT OBJECT_ID('dbo.sp_customer_place_order'),
        OBJECT_ID('dbo.Permission'),
        (SELECT COUNT(*) FROM dbo.SchemaVersion WHERE version_code='v1.0');""")[0][0]) == (None, None, 0)
    print('PASS injected pre-commit failure rolls back procedures, permissions and version marker')


@contextmanager
def as_user(conn, user):
    assert user in {'test_cashier', 'test_chef', 'test_packer', 'test_rider', 'test_store_manager', 'cust_app'}
    run(conn, f"EXECUTE AS USER='{user}';")
    try:
        yield
    finally:
        run(conn, 'REVERT;')


def check_workflows(conn, order_id, total, mobile, product):
    def pay_and_make(order_id, total):
        with as_user(conn, 'test_cashier'):
            run(conn, f"EXEC dbo.sp_pay_order {order_id}, 'CASH', {total}, NULL;")
        with as_user(conn, 'test_chef'):
            run(conn, f'EXEC dbo.sp_start_production {order_id};')
        with as_user(conn, 'test_packer'):
            heads, items = run(conn, 'EXEC dbo.sp_list_orders_for_packing 200;')
            assert order_id in {row[0] for row in heads}
            assert {row[0] for row in items} <= {row[0] for row in heads}
            assert order_id in {row[0] for row in items}
            run(conn, f'EXEC dbo.sp_finish_production {order_id};')

    def check_status(order_id, status, points):
        rows = run(conn, f"""SELECT o.order_status, l.ledger_status FROM dbo.SalesOrder o
            JOIN dbo.PointLedger l ON o.order_id=l.order_id WHERE o.order_id={order_id}""")
        assert tuple(rows[0][0]) == (status, points)

    def employee_order(method):
        assert method in ('DELIVERY', 'PICKUP')
        customer_id = int(run(conn, f"SELECT customer_id FROM dbo.Customer WHERE mobile='{mobile}';")[0][0][0])
        order_no = uuid4().hex
        with as_user(conn, 'test_cashier'):
            run(conn, f"""EXEC dbo.sp_create_order {customer_id}, '{method}', '{order_no}',
                N'[{{"product_id":{int(product)},"quantity":1}}]';""")
            order, _, _, _, _, _, _, _ = run(conn, f"EXEC dbo.sp_get_order_operation_status @order_no='{order_no}';")[0][0]
            amount = run(conn, f'EXEC dbo.sp_get_order_for_payment {order};')[0][0][2]
        return int(order), amount

    pay_and_make(order_id, total)
    with as_user(conn, 'test_packer'):
        run(conn, f'EXEC dbo.sp_pick_up_order {order_id};')
    check_status(order_id, 'PICKED_UP', 'EFFECTIVE')
    print('PASS pickup and points')

    delivery, total = employee_order('DELIVERY')
    pay_and_make(delivery, total)
    rider = int(run(conn, "SELECT employee_id FROM dbo.EmployeeAccount WHERE database_user_name='test_rider';")[0][0][0])
    with as_user(conn, 'test_rider'):
        assert delivery in {row[1] for row in run(conn, 'EXEC dbo.sp_list_deliveries_available_for_pickup;')[0]}
        run(conn, f'EXEC dbo.sp_pick_up_delivery {delivery}, {rider};')
        assert delivery in {row[1] for row in run(conn, 'EXEC dbo.sp_list_my_deliveries;')[0]}
        run(conn, f'EXEC dbo.sp_confirm_delivery {delivery};')
    check_status(delivery, 'COMPLETED', 'EFFECTIVE')
    print('PASS delivery assignment, completion and points')

    refund, total = employee_order('PICKUP')
    with as_user(conn, 'test_cashier'):
        run(conn, f"EXEC dbo.sp_pay_order {refund}, 'CASH', {total}, NULL;")
    manager = int(run(conn, "SELECT employee_id FROM dbo.EmployeeAccount WHERE database_user_name='test_store_manager';")[0][0][0])
    with as_user(conn, 'test_store_manager'):
        run(conn, f"EXEC dbo.sp_cancel_or_refund_order {refund}, 'REFUND', {manager};")
    check_status(refund, 'CANCELLED', 'VOIDED')
    assert run(conn, f'SELECT refunded_amount FROM dbo.Payment WHERE order_id={refund};')[0][0][0] == total
    print('PASS refund and voided points')

    # Clamp fixture inventory only in this disposable database; order/stock must not change on failure.
    run(conn, 'UPDATE dbo.Inventory SET on_hand_qty=locked_qty;')
    counts_sql = """SELECT (SELECT COUNT_BIG(*) FROM dbo.SalesOrder),
        (SELECT COUNT_BIG(*) FROM dbo.SalesOrderItem), (SELECT COUNT_BIG(*) FROM dbo.InventoryMovement),
        (SELECT SUM(locked_qty) FROM dbo.Inventory)"""
    before = tuple(run(conn, counts_sql)[0][0])
    with as_user(conn, 'cust_app'):
        expect_error(conn, f"""EXEC dbo.sp_customer_place_order '{mobile}',
            N'[{{"product_id":{int(product)},"quantity":1}}]';""", 50000)
    assert tuple(run(conn, counts_sql)[0][0]) == before
    print('PASS insufficient stock rolls back guest order, items and stock movements')


def check_web(conn, server, database, mobile, product):
    from flask import url_for
    from app import create_app
    from app.auth.service import reset_store
    from app.common.config import DbConfig

    if run(conn, "SELECT CONVERT(INT, SERVERPROPERTY('IsIntegratedSecurityOnly'));")[0][0][0] != 0:
        raise RuntimeError('--web requires mixed authentication; instance settings were not changed')
    app = create_app(DbConfig('ODBC Driver 18 for SQL Server', server, database, trust_server_certificate='yes'))
    app.testing = True
    with app.test_request_context():
        login_url = url_for('auth.login_submit')
        logout_url = url_for('auth.logout')
    accounts = {}
    created = []
    try:
        for job in ('cashier', 'chef', 'packer', 'waiter', 'rider', 'store_manager'):
            login = 'KFC_B_WEB_' + uuid4().hex
            password = 'B!7a' + token_hex(20)
            assert re.fullmatch(r'KFC_B_WEB_[a-f0-9]{32}', login)
            try:
                run(conn, f"CREATE LOGIN [{login}] WITH PASSWORD='{password}', CHECK_POLICY=ON;")
            except pyodbc.Error:
                raise RuntimeError('Could not create isolated web test login') from None
            created.append(login)
            run(conn, f"""CREATE USER [{login}] FOR LOGIN [{login}];
                ALTER ROLE [role_{job}] ADD MEMBER [{login}];
                UPDATE dbo.EmployeeAccount SET database_user_name='{login}'
                WHERE database_user_name='test_{job}';""")
            accounts[job] = (login, password)

        client = app.test_client()
        assert client.get('/orders/').status_code == 302

        def log_in(job):
            login, password = accounts[job]
            response = client.post(login_url, data={'login': login, 'password': password, 'next': '/orders/'})
            assert response.status_code == 302
            page = client.get('/orders/')
            assert page.status_code == 200 and job.upper() in page.get_data(as_text=True)
            with client.session_transaction() as state:
                assert password not in str(dict(state))
                return page.get_data(as_text=True), state['orders_csrf']

        page, csrf = log_in('cashier')
        attempt = re.search(r'name="attempt" value="([^"]+)"', page)[1]
        fields = {'csrf': csrf, 'attempt': attempt, 'mobile': mobile, 'fulfillment': 'PICKUP',
                  'product': str(product), 'quantity': '1'}
        assert client.post('/orders/actions/create', data={**fields, 'csrf': 'wrong'}).status_code == 403
        response = client.post('/orders/actions/create', data=fields)
        assert response.status_code == 303
        number = re.search(r'lookup=(B-[A-F0-9]{32})', response.location)[1]
        assert number in page and number in client.get('/orders/').get_data(as_text=True)
        row = run(conn, f"SELECT order_id,total_amount FROM dbo.SalesOrder WHERE order_no='{number}';")[0][0]
        order_id, total = int(row[0]), row[1]
        replay = client.post('/orders/actions/create', data=fields)
        assert replay.status_code == 409
        assert client.get(f'/orders/?detail={order_id}').status_code == 200
        payment = client.post('/orders/actions/pay', data={'csrf': csrf, 'order_id': str(order_id),
                                                           'method': 'CASH', 'amount': str(total)})
        assert payment.status_code == 303, (payment.status_code, run(conn, f'SELECT order_status FROM dbo.SalesOrder WHERE order_id={order_id};'))
        assert tuple(run(conn, f"""SELECT COUNT(*),COUNT(third_party_txn_no)
            FROM dbo.Payment WHERE order_id={order_id};""")[0][0]) == (1, 0)
        client.post(logout_url)
        assert client.get('/orders/').status_code == 302
        _, csrf = log_in('chef')
        assert client.post('/orders/actions/pay', data={'csrf': csrf, 'order_id': str(order_id)}).status_code == 403
        assert client.post('/orders/actions/start', data={'csrf': csrf, 'order_id': str(order_id)}).status_code == 303
        assert run(conn, f'SELECT order_status FROM dbo.SalesOrder WHERE order_id={order_id};')[0][0][0] == 'IN_PRODUCTION'
        client.post(logout_url)
        _, csrf = log_in('packer')
        assert client.post('/orders/actions/finish', data={'csrf': csrf, 'order_id': str(order_id)}).status_code == 303
        client.post(logout_url)
        board, _ = log_in('waiter')
        assert number in board
        waiter = accounts['waiter'][0]
        run(conn, f"UPDATE dbo.EmployeeAccount SET status='INACTIVE' WHERE database_user_name='{waiter}';")
        assert client.get('/orders/').status_code == 302
        with client.session_transaction() as state:
            assert 'auth_token' not in state
        run(conn, f"UPDATE dbo.EmployeeAccount SET status='ACTIVE' WHERE database_user_name='{waiter}';")
        client.post(logout_url)
        _, csrf = log_in('packer')
        assert client.post('/orders/actions/pickup', data={'csrf': csrf, 'order_id': str(order_id)}).status_code == 303
        client.post(logout_url)
        for job in ('rider', 'store_manager'):
            log_in(job)
            client.post(logout_url)
        print('PASS six Flask roles: login/logout, cashier create/pay, chef start, packing/pickup, waiter board, rider/manager pages, CSRF/replay/role negatives')
        print('PASS pre-submit order number remains recoverable; disabled waiter loses workbench session')
    finally:
        reset_store()
        for login in reversed(created):
            run(conn, f'DROP LOGIN [{login}];')
        print('PASS temporary SQL logins removed')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sql-server', required=True)
    parser.add_argument('--web', action='store_true', help='Also create and clean up six disposable SQL logins')
    args = parser.parse_args()
    if any(char in args.sql_server for char in ';{}'):
        parser.error('Expected a server/instance name')
    name = 'KFC_B_REHEARSAL_' + uuid4().hex
    assert re.fullmatch(r'KFC_B_REHEARSAL_[0-9a-f]{32}', name)
    connection_string = ('DRIVER={ODBC Driver 18 for SQL Server};'
                         f'SERVER={args.sql_server};DATABASE=master;'
                         'Trusted_Connection=yes;TrustServerCertificate=yes;')
    pyodbc.pooling = False
    conn = pyodbc.connect(connection_string, autocommit=True)
    created = False
    try:
        run(conn, f'CREATE DATABASE [{name}];')
        created = True
        stage1 = expand('sql/stage1/run_all.sql', name)
        # We already own the fresh database; skip only its create-once batch file.
        create = expand('sql/stage1/00_create_database.sql', name)
        if stage1.count(create) != 1:
            raise AssertionError('Unexpected stage 1 entrypoint structure')
        stage1 = stage1.replace(create, f'USE [{name}];\nGO\n', 1)
        for path, sql in [('stage1', stage1)] + [
            (path, expand('sql/stage2/' + path + '.sql', name))
            for path in ('capture_baseline', 'run_migration', 'regression')
        ]:
            if path == 'run_migration':
                check_rollback(conn, sql)
            try:
                run_batches(conn, sql)
            except pyodbc.Error:
                print(f'Failed phase: {path}')
                raise
            print(f'PASS phase {path}')

        mobile, product = run(conn, """SELECT
            (SELECT TOP 1 mobile FROM dbo.Customer WHERE status='ACTIVE' ORDER BY customer_id),
            (SELECT TOP 1 b.product_id FROM dbo.ProductBom b JOIN dbo.Product p ON p.product_id=b.product_id
             WHERE p.status='ACTIVE' ORDER BY b.product_id)""")[0][0]
        assert re.fullmatch(r'[0-9]{11}', mobile)
        run(conn, "EXECUTE AS USER='cust_app';")
        try:
            place = f"""EXEC dbo.sp_customer_place_order '{mobile}', N'[{{"product_id":{int(product)},"quantity":1}}]'"""
            expect_error(conn, place + ", 'DELIVERY';", 53000)
            expect_error(conn, "SELECT * FROM dbo.SalesOrder;", 229)
            order_id, _, code, total, status = run(conn, place)[0][0]
            assert re.fullmatch(r'[0-9A-F]{20}', code) and status == 'PENDING_PAYMENT' and total > 0
            assert run(conn, f"EXEC dbo.sp_customer_list_orders '{mobile}', '{code.lower()}';")[0][0][0] == order_id
            other_code = ('0' if code[0] != '0' else '1') + code[1:]
            assert run(conn, f"EXEC dbo.sp_customer_list_orders '{mobile}', '{other_code}';") == [[]]
        finally:
            run(conn, 'REVERT;')
        assert run(conn, f"""SELECT COUNT(*) FROM dbo.InventoryMovement
            WHERE reference_type='ORDER' AND reference_id={int(order_id)} AND movement_type='LOCK'""")[0][0][0] > 0
        run(conn, "EXECUTE AS USER='test_cashier';")
        try:
            expect_error(conn, 'EXEC dbo.sp_list_orders_for_payment 201;', 52901)
            expect_error(conn, 'EXEC dbo.sp_get_order_operation_status;', 52902)
            expect_error(conn, 'EXEC dbo.sp_get_order_for_payment -1;', 52903)
            result = run(conn, f'EXEC dbo.sp_get_order_for_payment {int(order_id)};')
            assert len(result) == 2 and result[0][0][0] == order_id and len(result[1]) == 1
            status_row = run(conn, f'EXEC dbo.sp_get_order_operation_status {int(order_id)};')[0][0]
            assert list(status_row[3:6]) == [None, None, None]
            expect_error(conn, 'EXEC dbo.sp_list_orders_for_packing;', 229)
        finally:
            run(conn, 'REVERT;')
        print('PASS guest authorization, exact lookup, stock lock, cashier result sets and negative inputs')
        if args.web:
            check_web(conn, args.sql_server, name, mobile, product)
            # Restore fixture name mappings for the subsequent EXECUTE AS acceptance.
            run(conn, """UPDATE dbo.EmployeeAccount SET database_user_name='test_' + LOWER(job_code)
                WHERE database_user_name LIKE 'KFC[_]B[_]WEB[_]%';""")
        check_workflows(conn, int(order_id), total, mobile, product)
    finally:
        conn.close()
        if created:
            cleanup = pyodbc.connect(connection_string, autocommit=True)
            try:
                run(cleanup, f'ALTER DATABASE [{name}] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;')
                run(cleanup, f'DROP DATABASE [{name}];')
            finally:
                cleanup.close()
            print('PASS disposable database removed')


if __name__ == '__main__':
    main()
