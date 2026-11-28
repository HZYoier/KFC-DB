"""Test B's 13b/21b–25b and 28b in a new disposable SQL Server database."""
import argparse
from concurrent.futures import ThreadPoolExecutor
from decimal import Decimal
from pathlib import Path
import re
import sys
import time
from uuid import uuid4

import pyodbc

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'tests/stage2/orders'))
from check_migration import as_user, expand, expect_error, run, run_batches


def check_b(conn, name, server, capture_dir=None):
    count = 0

    def passed(label):
        nonlocal count
        count += 1
        print(f'PASS {count:02} {label}')

    def script(path):
        run_batches(conn, expand(path, name))

    def rows(sql, *args):
        return [tuple(row) for row in run(conn, sql, args)[0]]

    def make_order(method='PICKUP', *, items=None):
        number = 'B-S3-' + uuid4().hex
        with as_user(conn, 'test_cashier'):
            run(conn, 'EXEC dbo.sp_create_order ?, ?, ?, ?;', (customer, method, number, payload if items is None else items))
        return rows('SELECT order_id,total_amount FROM dbo.SalesOrder WHERE order_no=?;', number)[0]

    def prepare(order_id, amount, method):
        with as_user(conn, 'test_cashier'):
            run(conn, "EXEC dbo.sp_pay_order ?, 'CASH', ?, NULL;", (order_id, amount))
        with as_user(conn, 'test_chef'):
            run(conn, 'EXEC dbo.sp_start_production ?;', (order_id,))
        with as_user(conn, 'test_packer'):
            run(conn, 'EXEC dbo.sp_finish_production ?;', (order_id,))
        if method == 'DELIVERY':
            with as_user(conn, 'test_rider'):
                run(conn, 'EXEC dbo.sp_pick_up_delivery ?, ?;', (order_id, rider))

    script('sql/stage2/13b_order_baseline_check.sql')
    passed('13b v1.0 baseline')
    script('sql/stage3/run_stage3.sql')
    assert rows('SELECT COUNT(*) FROM dbo.Permission;') == [(64,)]
    assert rows('SELECT COUNT(*) FROM dbo.RolePermission;') == [(78,)]
    passed('formal v1.1 migration commits with 64 permissions and 78 role mappings')
    script('sql/stage2/regression.sql')
    passed('formal v1.1 passes all 38 legacy SQL checks including versioned permissions')
    for account in ('test_store_manager', 'test_cashier', 'test_chef', 'test_packer', 'test_rider', 'test_shift_manager'):
        run(conn, f"EXECUTE AS USER='{account}';")
        try:
            permissions = rows("""SELECT HAS_PERMS_BY_NAME('dbo.sp_sales_report','OBJECT','EXECUTE'),
                HAS_PERMS_BY_NAME('dbo.v_settled_sales_line','OBJECT','SELECT'),
                HAS_PERMS_BY_NAME('dbo.fn_calculate_discount','OBJECT','SELECT'),
                HAS_PERMS_BY_NAME('dbo.SalesOrder','OBJECT','UPDATE');""")[0]
            expected = (1, 1, 1, 0) if account == 'test_store_manager' else (0, 0, 0, 0)
            assert permissions == expected, (account, permissions)
            if account == 'test_store_manager':
                assert len(run(conn, "EXEC dbo.sp_sales_report '19000101','19000101';")) == 2
            else:
                expect_error(conn, "EXEC dbo.sp_sales_report '19000101','19000101';", 229)
            print('PASS B permissions', account, 'report/view/discount/update', permissions)
        finally:
            run(conn, 'REVERT;')
    script('sql/stage3/28b_stage3_regression.sql')
    assert rows('SELECT COUNT(*) FROM dbo.SalesOrderItem WHERE discount_rate<>0 OR discount_amount<>0;') == [(0,)]
    passed('pre-existing lines have zero discount snapshots')
    run(conn, 'BEGIN TRANSACTION; UPDATE dbo.SalesOrderItem SET quantity=quantity+1 WHERE order_item_id=(SELECT MIN(order_item_id) FROM dbo.SalesOrderItem);')
    try:
        expect_error(conn, expand('sql/stage2/13b_order_baseline_check.sql', name), 51962)
    finally:
        run(conn, 'IF @@TRANCOUNT>0 ROLLBACK TRANSACTION;')
    passed('13b v1.1 still rejects base column drift')
    run(conn, 'BEGIN TRANSACTION; ALTER TABLE dbo.SalesOrderItem ADD b_unexpected INT NULL;')
    try:
        expect_error(conn, expand('sql/stage2/13b_order_baseline_check.sql', name), 51961)
    finally:
        run(conn, 'IF @@TRANCOUNT>0 ROLLBACK TRANSACTION;')
    passed('13b v1.1 rejects unapproved additional columns')

    expect_error(conn, 'EXEC dbo.sp_sales_report NULL, \'20261116\';', 54201)
    expect_error(conn, "EXEC dbo.sp_sales_report '20261117','20261116';", 54202)
    passed('sales report date validation')
    assert len(run(conn, "EXEC dbo.sp_sales_report '99991231','99991231';")) == 2
    empty = run(conn, "EXEC dbo.sp_sales_report '19000101','19000101';")
    assert len(empty) == 2 and tuple(empty[0][0]) == (0, 0, 0) and not empty[1]
    passed('empty report returns zero summary and empty breakdown')

    customer, mobile = rows("""SELECT TOP (1) c.customer_id,c.mobile FROM dbo.Customer c
        JOIN dbo.MemberLevel m ON m.member_level_id=c.member_level_id
        WHERE c.status='ACTIVE' AND m.status='ACTIVE' AND m.level_name=N'金卡会员'
        ORDER BY c.customer_id;""")[0]
    products = rows("""SELECT TOP (2) p.product_id FROM dbo.Product p
        WHERE p.status='ACTIVE' AND p.product_type='SINGLE'
          AND EXISTS (SELECT 1 FROM dbo.ProductBom b WHERE b.product_id=p.product_id)
        ORDER BY p.product_id;""")
    assert len(products) == 2
    payload = f'[{{"product_id":{products[0][0]},"quantity":3}},{{"product_id":{products[1][0]},"quantity":3}}]'
    rider = rows("SELECT employee_id FROM dbo.EmployeeAccount WHERE database_user_name='test_rider';")[0][0]
    employee, amount = make_order()
    with as_user(conn, 'cust_app'):
        guest = run(conn, 'EXEC dbo.sp_customer_place_order ?, ?;', (mobile, payload))[0][0]
    assert guest[3] == amount
    projection = """SELECT product_id,quantity,unit_price,discount_rate,discount_amount
        FROM dbo.SalesOrderItem WHERE order_id=? ORDER BY product_id"""
    lines = rows(projection, employee)
    assert lines == rows(projection, guest[0])
    gross = sum(qty * price for _, qty, price, _, _ in lines)
    rate, discount = rows('SELECT * FROM dbo.fn_calculate_discount(?, ?, NULL);', customer, gross)[0]
    assert discount > 0 and all(line[3] == rate for line in lines)
    assert sum(line[4] for line in lines) == discount and gross - discount == amount
    passed('both order paths persist same discount; cents and net total reconcile')

    with as_user(conn, 'test_cashier'):
        payment = run(conn, 'EXEC dbo.sp_get_order_for_payment ?;', (employee,))
    assert len(payment) == 2 and payment[0][0][2] == amount
    expected = {line[0]: line[3:] for line in lines}
    assert {row[1]: tuple(row[6:]) for row in payment[1]} == expected

    from flask import render_template
    from app import create_app
    from app.common.config import DbConfig

    def record(row):
        return {column[0]: value for column, value in zip(row.cursor_description, row)}

    app = create_app(DbConfig('ODBC Driver 18 for SQL Server', server, name, trust_server_certificate='yes'))
    head, items = [record(row) for row in payment[0]], [record(row) for row in payment[1]]
    assert list(head[0]) == ['order_id', 'order_no', 'total_amount', 'ordered_at', 'fulfillment_method']
    assert list(items[0]) == ['order_item_id', 'product_id', 'product_name', 'quantity', 'unit_price',
                             'promotion_id', 'discount_rate', 'discount_amount']
    with app.test_request_context('/orders/'):
        def page(details):
            return render_template('orders/index.html', job='CASHIER', csrf='', head=head, items=details,
                                   orders=[], products=[], recent_numbers=[])

        html = page(items)
        if capture_dir:
            capture_dir.mkdir(parents=True, exist_ok=True)
            (capture_dir / 'payment.html').write_text(html, encoding='utf-8')
        assert '会员折扣率' in html and '会员折扣额' in html
        for item in items:
            assert f"{item['discount_rate']:.2%}" in html and f"¥{item['discount_amount']}" in html
        legacy = [{key: value for key, value in row.items() if not key.startswith('discount_')} for row in items]
        assert '会员折扣率' not in page(legacy)
        zero = [{**items[0], 'discount_rate': Decimal('0.0000'), 'discount_amount': Decimal('0.00')}]
        zero_html = page(zero)
        assert re.search(r'<td>\s*—\s*</td>\s*<td>\s*<span class="amount">¥0\.00</span>\s*</td>', zero_html)
    print('PASS v1.1 payment SQL snapshots render in the cashier page, including legacy rows')

    run(conn, 'BEGIN TRANSACTION;')
    try:
        run(conn, "UPDATE dbo.Promotion SET status='INACTIVE';")
        singles = rows("SELECT product_id FROM dbo.Product WHERE product_type='SINGLE' AND status='ACTIVE';")
        assert len(singles) == 5
        run(conn, "UPDATE dbo.Product SET base_price=0.10 WHERE product_type='SINGLE' AND status='ACTIVE';")
        cheap = '[' + ','.join(f'{{"product_id":{pid},"quantity":1}}' for pid, in singles) + ']'
        edge, edge_net = make_order(items=cheap)
        with as_user(conn, 'cust_app'):
            edge_guest = run(conn, 'EXEC dbo.sp_customer_place_order ?, ?;', (mobile, cheap))[0][0]
        for order_id in (edge, edge_guest[0]):
            shares = rows('SELECT discount_amount FROM dbo.SalesOrderItem WHERE order_id=? ORDER BY order_item_id;', order_id)
            assert [share for share, in shares] == [Decimal('0.00')] * 2 + [Decimal('0.01')] * 3
        assert edge_net == edge_guest[3] == Decimal('0.47')
    finally:
        run(conn, 'IF @@TRANCOUNT>0 ROLLBACK TRANSACTION;')
    passed('both order paths allocate a rounding residual beyond one line')

    prepare(employee, amount, 'PICKUP')
    with as_user(conn, 'test_packer'):
        run(conn, 'EXEC dbo.sp_pick_up_order ?;', (employee,))
    assert rows("SELECT order_status FROM dbo.SalesOrder WHERE order_id=?;", employee) == [('PICKED_UP',)]
    passed('actual pickup and its completion trigger')
    delivery, net = make_order('DELIVERY')
    new_ingredient = rows("""SELECT TOP (1) i.ingredient_id FROM dbo.Inventory i WHERE NOT EXISTS (
        SELECT 1 FROM dbo.InventoryMovement m WHERE m.reference_type='ORDER' AND m.reference_id=?
        AND m.movement_type='LOCK' AND m.ingredient_id=i.ingredient_id)
        ORDER BY i.ingredient_id;""", delivery)[0][0]
    product = products[0][0]
    run(conn, 'INSERT dbo.ProductBom(product_id,ingredient_id,usage_qty) VALUES(?,?,1);', (product, new_ingredient))
    try:
        prepare(delivery, net, 'DELIVERY')
        with as_user(conn, 'test_rider'):
            run(conn, 'EXEC dbo.sp_confirm_delivery ?;', (delivery,))
    finally:
        run(conn, 'DELETE dbo.ProductBom WHERE product_id=? AND ingredient_id=?;', (product, new_ingredient))
    assert rows('SELECT order_status FROM dbo.SalesOrder WHERE order_id=?;', delivery) == [('COMPLETED',)]
    assert rows("""SELECT COUNT(*) FROM dbo.InventoryMovement WHERE reference_type='ORDER'
        AND reference_id=? AND movement_type='CONSUME' AND ingredient_id=?;""", delivery, new_ingredient) == [(0,)]
    passed('actual delivery after BOM edit consumes only reserved ingredients')
    expect_error(conn, "UPDATE dbo.SalesOrder SET order_status='PICKED_UP' WHERE order_id=?;", 54210, params=(employee,))
    expect_error(conn, "UPDATE dbo.SalesOrder SET order_status='PICKED_UP',completed_at=SYSDATETIME() WHERE order_id=?;", 54211, params=(int(guest[0]),))
    passed('reject repeated completion and invalid transition')

    first, price1 = make_order()
    second, price2 = make_order()
    prepare(first, price1, 'PICKUP')
    prepare(second, price2, 'PICKUP')
    batch = "UPDATE dbo.SalesOrder SET order_status='PICKED_UP',completed_at=SYSDATETIME() WHERE order_id IN (?,?);"
    run(conn, 'BEGIN TRANSACTION;')
    try:
        run(conn, batch, (first, second))
        assert rows("SELECT COUNT(*) FROM dbo.SalesOrder WHERE order_id IN (?,?) AND order_status='PICKED_UP';", first, second) == [(2,)]
    finally:
        run(conn, 'IF @@TRANCOUNT>0 ROLLBACK TRANSACTION;')
    passed('set-based trigger accepts two valid updated rows')
    run(conn, 'UPDATE dbo.SalesOrder SET total_amount=total_amount+0.01 WHERE order_id=?;', (second,))
    expect_error(conn, batch, 54213, params=(first, second))
    assert rows("SELECT COUNT(*) FROM dbo.SalesOrder WHERE order_id IN (?,?) AND order_status='READY_FOR_PICKUP';", first, second) == [(2,)]
    passed('one invalid row rejects whole batch with no half completion')
    run(conn, "UPDATE dbo.SalesOrder SET order_status='READY_FOR_PICKUP' WHERE order_id=?;", (int(guest[0]),))
    expect_error(conn, "UPDATE dbo.SalesOrder SET order_status='PICKED_UP',completed_at=SYSDATETIME() WHERE order_id=?;",
                 54214, params=(int(guest[0]),))
    passed('finish with no stock consumption is rejected')

    run(conn, 'BEGIN TRANSACTION;')
    try:
        run(conn, 'DELETE dbo.SalesOrderItem WHERE order_id=?;', (int(guest[0]),))
        expect_error(conn, "UPDATE dbo.SalesOrder SET order_status='PICKED_UP',completed_at=SYSDATETIME() WHERE order_id=?;",
                     54212, params=(int(guest[0]),))
    finally:
        run(conn, 'IF @@TRANCOUNT>0 ROLLBACK TRANSACTION;')
    expect_error(conn, "UPDATE dbo.SalesOrder SET order_status='PICKED_UP',completed_at=NULL WHERE order_id=?;",
                 54211, params=(first,))
    passed('terminal transition rejects empty lines or missing completion time')

    run(conn, 'BEGIN TRANSACTION;')
    try:
        no_bom = rows("""INSERT dbo.Product(product_name,base_price,product_type,status)
            OUTPUT inserted.product_id VALUES(N'B Stage 3 no-BOM fixture',1,'SINGLE','INACTIVE');""")[0][0]
        order_id = rows("""INSERT dbo.SalesOrder(order_no,customer_id,order_status,fulfillment_method,
            pickup_code,total_amount) OUTPUT inserted.order_id VALUES(?,?,'READY_FOR_PICKUP','PICKUP',?,1);""",
                        'B-S3-' + uuid4().hex, customer, uuid4().hex[:20])[0][0]
        run(conn, """INSERT dbo.SalesOrderItem(order_id,product_id,item_role,quantity,unit_price)
            VALUES(?,?,'SELLABLE',1,1);""", (order_id, no_bom))
        run(conn, "UPDATE dbo.SalesOrder SET order_status='PICKED_UP',completed_at=SYSDATETIME() WHERE order_id=?;", (order_id,))
        assert rows('SELECT order_status FROM dbo.SalesOrder WHERE order_id=?;', order_id) == [('PICKED_UP',)]
    finally:
        run(conn, 'IF @@TRANCOUNT>0 ROLLBACK TRANSACTION;')
    passed('a line without BOM or prior reservations needs no stock movement')

    # Complete real orders first, then pin their completion times in this fixture.
    # These are deliberately straddling midnight; do not rely on the runtime date.
    run(conn, "UPDATE dbo.SalesOrder SET completed_at='2099-01-01T23:59:59' WHERE order_id=?;", (employee,))
    run(conn, "UPDATE dbo.SalesOrder SET completed_at='2099-01-02T00:00:00' WHERE order_id=?;", (delivery,))
    assert rows('SELECT COUNT(*) FROM dbo.v_settled_sales_line WHERE order_id=?;', int(guest[0])) == [(0,)]
    assert rows("""SELECT COUNT(*) FROM dbo.v_settled_sales_line v JOIN dbo.SalesOrderItem i
        ON v.order_id=i.order_id AND v.product_id=i.product_id WHERE i.item_role='COMPONENT'
        AND NOT EXISTS (SELECT 1 FROM dbo.SalesOrderItem s WHERE s.order_id=i.order_id
                       AND s.product_id=i.product_id AND s.item_role='SELLABLE');""") == [(0,)]
    boundary = run(conn, "EXEC dbo.sp_sales_report '20990101','20990101';")
    assert tuple(boundary[0][0]) == (1, 6, amount)
    next_day = run(conn, "EXEC dbo.sp_sales_report '20990102','20990102';")
    assert tuple(next_day[0][0]) == (1, 6, net)
    passed('both terminal states count; midnight boundary and component exclusion')

    day = rows('SELECT CONVERT(DATE,completed_at) FROM dbo.SalesOrder WHERE order_id=?;', employee)[0][0]
    report = run(conn, 'EXEC dbo.sp_sales_report ?,?;', (day, day))
    expected = rows('SELECT * FROM dbo.fn_product_sales_summary(?,?);', day, day)
    assert len(report) == 2 and {tuple(row) for row in report[1]} == set(expected)
    summary = tuple(report[0][0])
    assert summary[1:] == (sum(row[2] for row in expected), sum(row[3] for row in expected))
    passed('reports agree with A summary on the same day')
    daily = rows(expand('sql/stage3/23b_window_queries.sql', name))
    assert len(daily) >= 2 and len({row[0] for row in daily}) == len(daily)
    running = Decimal('0')
    for date, amount, accumulated in daily:
        running += amount
        assert running == accumulated
    assert sum(row[1] for row in daily) == rows('SELECT SUM(net_amount) FROM dbo.v_settled_sales_line;')[0][0]
    passed('daily cumulative net sales preserve day count and reconcile')
    assert count == 21, count
    print(f'RESULT: pass={count} fail=0 total=21')

    query = expand('sql/stage3/24b_recursive_query.sql', name)

    def tree(order_id, item_id=None):
        sql = query.replace('$(OrderId)', str(int(order_id))).replace(
            '$(OrderItemId)', 'NULL' if item_id is None else str(int(item_id)))
        result = rows(sql)
        print(f'24b order={order_id} focus={item_id}: ' + str([
            (row[2], row[3], row[4], row[6], row[9]) for row in result]))
        return result

    combo, = rows("""SELECT TOP (1) p.product_id FROM dbo.Product AS p
        WHERE p.status='ACTIVE' AND p.product_type='COMBO'
          AND EXISTS (SELECT 1 FROM dbo.ComboComponent c WHERE c.combo_product_id=p.product_id)
        ORDER BY p.product_id;""")[0]
    recipe = dict(rows('SELECT child_product_id, quantity FROM dbo.ComboComponent WHERE combo_product_id=?;', combo))
    run(conn, 'BEGIN TRANSACTION;')
    try:
        order_id, _ = make_order(items=f'[{{"product_id":{combo},"quantity":2}}]')
        initial = tree(order_id)
        root = initial[0]
        assert (root[2], root[3], root[5], root[7], root[9], root[11]) == (None, 0, combo, 'SELLABLE', 2, root[10] * 2)
        assert {row[5]: (row[8], row[9]) for row in initial[1:]} == {
            product: (pieces, 2 * pieces) for product, pieces in recipe.items()}
        assert all(row[2] == root[1] and row[3] == 1 and row[11] == 0 for row in initial[1:])
        print('PASS 24b real one-level order uses snapshot quantities without multiplying twice')

        middle = initial[1]
        run(conn, 'UPDATE dbo.SalesOrderItem SET product_id=? WHERE order_item_id=?;', (combo, middle[1]))
        leaf, = rows("""INSERT dbo.SalesOrderItem(order_id,product_id,parent_order_item_id,item_role,quantity,unit_price)
            OUTPUT inserted.order_item_id VALUES(?,?,?,'COMPONENT',?,0);""",
                     order_id, products[0][0], middle[1], middle[9] * 3)[0]
        full_tree = tree(order_id, root[1])
        branch = tree(order_id, middle[1])
        tip = tree(order_id, leaf)
        assert [row[1] for row in branch] == [middle[1], leaf]
        assert len(full_tree) == len(initial) + 1 and full_tree[0] == root
        assert len(tip) == 1 and tip[0] == branch[1]
        assert (tip[0][2], tip[0][3], tip[0][4], tip[0][8], tip[0][9]) == (
            middle[1], 2, f'/{root[1]}/{middle[1]}/{leaf}/', 3, middle[9] * 3)
        assert tree(-1) == [] and tree(order_id, -1) == []
        print('PASS 24b two levels, root/middle/leaf, missing order and missing item')
    finally:
        run(conn, 'IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;')
    assert not rows('SELECT order_id FROM dbo.SalesOrder WHERE order_id=?;', order_id)
    print('PASS 24b fixture rolled back')

    tx_results = run(conn, expand('sql/stage3/25b_tx_order_completion.sql', name))
    for result in tx_results:
        for row in result:
            print('25b', *row, sep=' | ')
    assert [tuple(row) for row in tx_results[-1]] == [('25b PASS', 7, 0)]


def check_concurrency(conn, connection_string, name):
    """Meet a manager's inventory lock with a real PACKER completion, then undo both."""
    order_id, ingredient = run(conn, """SELECT TOP (1) o.order_id, m.ingredient_id
        FROM dbo.SalesOrder o JOIN dbo.InventoryMovement m
        ON m.reference_type='ORDER' AND m.reference_id=o.order_id AND m.movement_type='LOCK'
        WHERE o.order_status='IN_PRODUCTION' AND EXISTS (
            SELECT 1 FROM dbo.SalesOrderItem i WHERE i.order_id=o.order_id AND i.item_role='SELLABLE')
        ORDER BY o.order_id,m.ingredient_id;""")[0][0]
    manager = run(conn, "SELECT employee_id FROM dbo.EmployeeAccount WHERE database_user_name='test_store_manager';")[0][0][0]

    def snapshot():
        return [run(conn, f'SELECT * FROM dbo.{table} ORDER BY {key} FOR JSON PATH, INCLUDE_NULL_VALUES;')[0]
                for table, key in [('Inventory', 'ingredient_id'), ('InventoryMovement', 'inventory_movement_id'),
                                  ('InventoryAudit', 'inventory_audit_id'), ('SalesOrder', 'order_id'),
                                  ('Delivery', 'delivery_id'), ('ReplenishmentSuggestion', 'replenishment_suggestion_id'),
                                  ('PointLedger', 'point_ledger_id'), ('AuditLog', 'audit_log_id')]]

    def complete(timeout, session):
        worker = pyodbc.connect(connection_string, autocommit=True)
        try:
            run(worker, f'USE [{name}]; SET LOCK_TIMEOUT {timeout}; BEGIN TRANSACTION;')
            session.append(run(worker, 'SELECT @@SPID;')[0][0][0])
            started = time.monotonic()
            try:
                with as_user(worker, 'test_packer'):
                    run(worker, 'EXEC dbo.sp_finish_production ?;', (order_id,))
                state = run(worker, 'SELECT order_status FROM dbo.SalesOrder WHERE order_id=?;', (order_id,))[0][0][0]
                return 0, state, round(time.monotonic() - started, 3)
            except pyodbc.Error as exc:
                if '(1222)' not in str(exc):
                    raise
                return 1222, None, round(time.monotonic() - started, 3)
            finally:
                run(worker, 'IF @@TRANCOUNT>0 ROLLBACK TRANSACTION;')
                assert run(worker, 'SELECT @@TRANCOUNT;')[0][0][0] == 0
        finally:
            worker.close()

    for mode, timeout in [('wait', 10000), ('timeout', 1500)]:
        for repeat in range(1, 4):
            before = snapshot()
            run(conn, 'BEGIN TRANSACTION;')
            try:
                with as_user(conn, 'test_store_manager'):
                    run(conn, "EXEC dbo.sp_adjust_inventory ?, 1, ?, 'B order concurrency';", (ingredient, manager))
                blocker = run(conn, 'SELECT @@SPID;')[0][0][0]
                session = []
                with ThreadPoolExecutor(max_workers=1) as pool:
                    task = pool.submit(complete, timeout, session)
                    try:
                        deadline = time.monotonic() + 5
                        waiting = []
                        while time.monotonic() < deadline and not task.done():
                            if session:
                                waiting = run(conn, """SELECT session_id,blocking_session_id,wait_type,wait_resource
                                    FROM sys.dm_exec_requests WHERE session_id=? AND blocking_session_id=?;""",
                                              (session[0], blocker))[0]
                            if waiting:
                                break
                            time.sleep(0.02)
                        assert waiting and waiting[0][2].startswith('LCK_M_'), waiting
                        print('B concurrency', mode, repeat, 'order', order_id, 'ingredient', ingredient, 'DMV', tuple(waiting[0]))
                        if mode == 'wait':
                            run(conn, 'ROLLBACK TRANSACTION;')
                        result = task.result(timeout=15)
                        assert result[0] == (0 if mode == 'wait' else 1222), result
                        if mode == 'wait':
                            assert result[1] in ('READY_FOR_PICKUP', 'READY_FOR_DELIVERY')
                        print('PASS B concurrency', mode, repeat, 'error/status/seconds', result)
                    finally:
                        run(conn, 'IF @@TRANCOUNT>0 ROLLBACK TRANSACTION;')
            finally:
                run(conn, 'IF @@TRANCOUNT>0 ROLLBACK TRANSACTION;')
            assert snapshot() == before
            print('PASS B concurrency exact data restored; transactions=0')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sql-server', required=True)
    parser.add_argument('--verify-all', action='store_true', help='Also run the delivered A/B/C SQL verification entry')
    parser.add_argument('--concurrency', action='store_true', help='Run order completion versus inventory adjustment, six rounds')
    parser.add_argument('--concurrency-v2', action='store_true', help='Run week 13 order/receipt and competing purchases')
    parser.add_argument('--capture-dir', type=Path, help='Save the actual cashier response for report screenshots')
    parser.add_argument('--review-c', action='store_true', help='Rerun the delivered C business deadlock and ordered-lock experiments')
    args = parser.parse_args()
    if not __debug__:
        parser.error('Run without Python optimization so test assertions are enabled.')
    if not args.sql_server or any(char in args.sql_server for char in ';{}'):
        parser.error('Expected a server/instance name')
    name = 'KFC_B_STAGE3_' + uuid4().hex
    assert re.fullmatch(r'KFC_B_STAGE3_[0-9a-f]{32}', name)
    cs = ('DRIVER={ODBC Driver 18 for SQL Server};'
          f'SERVER={args.sql_server};DATABASE=master;Trusted_Connection=yes;TrustServerCertificate=yes;')
    pyodbc.pooling = False
    conn = pyodbc.connect(cs, autocommit=True)
    created = False
    try:
        run(conn, f'CREATE DATABASE [{name}];')
        created = True
        initial = expand('sql/stage1/run_all.sql', name)
        create = expand('sql/stage1/00_create_database.sql', name)
        assert initial.count(create) == 1
        run_batches(conn, initial.replace(create, f'USE [{name}];\nGO\n', 1))
        for path in ('capture_baseline', 'run_migration', 'regression'):
            run_batches(conn, expand(f'sql/stage2/{path}.sql', name))
        check_b(conn, name, args.sql_server, args.capture_dir)
        if args.concurrency:
            check_concurrency(conn, cs, name)
        if args.concurrency_v2:
            from concurrency_v2 import check
            check(conn, cs, name)
        if args.review_c:
            import importlib.util
            spec = importlib.util.spec_from_file_location('c_business', ROOT / 'tests/stage3/c_concurrency/run_c_business_concurrency.py')
            lab = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(lab)
            def connect_lab():
                connection = pyodbc.connect(cs, autocommit=True)
                connection.timeout = 15
                run(connection, f'USE [{name}]; SET LANGUAGE us_english; SET LOCK_TIMEOUT 10000; SET TRANSACTION ISOLATION LEVEL READ COMMITTED;')
                return connection
            for repeat in range(1, 4):
                lab.experiment(connect_lab, ordered=False)
                lab.experiment(connect_lab, ordered=True)
                print('PASS B review of C business deadlock and ordered locks round', repeat)
        if args.verify_all:
            verification = expand('sql/stage3/verify_stage3.sql', name)
            # C's 28c includes 25c with an SQLCMD-local rollback mode.
            verification = re.sub(r'^:setvar Mode rollback\s*$', '', verification, flags=re.M)
            verification = verification.replace('$(Mode)', 'rollback')
            run_batches(conn, verification)
            assert run(conn, 'SELECT @@TRANCOUNT;')[0][0][0] == 0
            print('PASS combined A/B/C verification completed with no open transaction')
    finally:
        conn.close()
        if created:
            cleanup = pyodbc.connect(cs, autocommit=True)
            try:
                run(cleanup, f'ALTER DATABASE [{name}] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;')
                run(cleanup, f'DROP DATABASE [{name}];')
            finally:
                cleanup.close()
            print('PASS isolated database removed')


if __name__ == '__main__':
    main()
