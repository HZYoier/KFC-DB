"""Real order/receipt waiting and competing P x 6 purchases in a disposable DB."""
from concurrent.futures import ThreadPoolExecutor
from threading import Barrier
import time
from uuid import uuid4

import pyodbc

from check_migration import as_user, expand, run


def check(conn, cs, name):
    def scalar(sql, *args):
        return run(conn, sql, args)[0][0][0]

    def step(connection, mode, **values):
        source = expand('sql/stage3/26b_order_concurrency.sql', name)
        variables = dict(Mode=mode, IngredientP=p, OrderId=0, OrderNo='unused', ProductId=product, CustomerId=customer)
        variables.update(values)
        for key, value in variables.items():
            source = source.replace('$(' + key + ')', str(value))
        return run(connection, source)

    customer = scalar("SELECT MIN(customer_id) FROM dbo.Customer WHERE status='ACTIVE';")
    shift = scalar("SELECT employee_id FROM dbo.EmployeeAccount WHERE database_user_name='test_shift_manager';")
    manager = scalar("SELECT employee_id FROM dbo.EmployeeAccount WHERE database_user_name='test_store_manager';")

    def ingredient(label, qty):
        item = scalar("""INSERT dbo.Ingredient(ingredient_name,unit_name,safety_stock_qty,status)
            OUTPUT inserted.ingredient_id VALUES(?,N'piece',0,'ACTIVE');""", label + uuid4().hex)
        run(conn, 'INSERT dbo.Inventory(ingredient_id,on_hand_qty,locked_qty,updated_at) VALUES(?,?,0,SYSDATETIME());', (item, qty))
        return item

    p, q = ingredient('B26-P-', 10), ingredient('B26-Q-', 8)
    product = scalar("""INSERT dbo.Product(product_name,base_price,product_type,status)
        OUTPUT inserted.product_id VALUES(?,10,'SINGLE','ACTIVE');""", 'B26-' + uuid4().hex)
    run(conn, 'INSERT dbo.ProductBom(product_id,ingredient_id,usage_qty) VALUES(?,?,1);', (product, p))

    def order(qty):
        number = 'B26-' + uuid4().hex
        with as_user(conn, 'test_cashier'):
            run(conn, 'EXEC dbo.sp_create_order ?,\'PICKUP\',?,?;',
                (customer, number, f'[{{"product_id":{product},"quantity":{qty}}}]'))
        oid, amount = run(conn, 'SELECT order_id,total_amount FROM dbo.SalesOrder WHERE order_no=?;', (number,))[0][0]
        with as_user(conn, 'test_cashier'):
            run(conn, "EXEC dbo.sp_pay_order ?,'CASH',?,NULL;", (oid, amount))
        with as_user(conn, 'test_chef'):
            run(conn, 'EXEC dbo.sp_start_production ?;', (oid,))
        return oid

    def procurement(item):
        run(conn, "EXECUTE AS USER='test_shift_manager';")
        try:
            run(conn, 'EXEC dbo.sp_create_replenishment_suggestion ?,5,?;', (item, shift))
        finally:
            run(conn, 'REVERT;')
        sid = scalar('SELECT replenishment_suggestion_id FROM dbo.ReplenishmentSuggestion WHERE ingredient_id=?;', item)
        run(conn, "EXECUTE AS USER='test_shift_manager';")
        try:
            run(conn, 'EXEC dbo.sp_submit_replenishment_suggestion ?,?;', (sid, shift))
        finally:
            run(conn, 'REVERT;')
        with as_user(conn, 'test_store_manager'):
            run(conn, 'EXEC dbo.sp_approve_replenishment_suggestion ?,?;', (sid, manager))
        return scalar('SELECT purchase_order_id FROM dbo.PurchaseOrder WHERE replenishment_suggestion_id=?;', sid)

    def connect():
        c = pyodbc.connect(cs, autocommit=True)
        run(c, f'USE [{name}]; SET LOCK_TIMEOUT 10000;')
        return c

    print('26b environment', scalar('SELECT @@VERSION;'), 'RCSI', scalar('SELECT is_read_committed_snapshot_on FROM sys.databases WHERE database_id=DB_ID();'))
    print('26b P/Q', p, q, 'initial 10/8')
    for commit_order, expected in [(True, 13), (False, 15)]:
        for repeat in range(1, 4):
            # Use a fresh P fixture per round; the two original IDs remain the
            # first round's documented P/Q baseline, all data dies with the DB.
            if commit_order is not True or repeat > 1:
                p = ingredient('B26-P-', 10)
                run(conn, 'UPDATE dbo.ProductBom SET ingredient_id=? WHERE product_id=?;', (p, product))
            oid, po = order(2), procurement(p)
            worker = connect()
            observer = connect()
            try:
                blocker = scalar('SELECT @@SPID;')
                worker_id = run(worker, 'SELECT @@SPID;')[0][0][0]
                observer_id = run(observer, 'SELECT @@SPID;')[0][0][0]
                assert len({worker_id, blocker, observer_id}) == 3
                for connection in (conn, worker, observer):
                    print('26b session/isolation', tuple(run(connection,
                          'SELECT session_id,transaction_isolation_level FROM sys.dm_exec_sessions WHERE session_id=@@SPID;')[0][0]))
                run(conn, 'BEGIN TRANSACTION;')
                step(conn, 'finish', OrderId=oid)
                print('26b A1 finish held', oid, 'P', scalar('SELECT on_hand_qty FROM dbo.Inventory WHERE ingredient_id=?;', p))

                def receipt():
                    try:
                        run(worker, "EXECUTE AS USER='test_shift_manager';")
                        try:
                            run(worker, 'EXEC dbo.sp_receive_inventory ?,?,5;', (po, shift))
                        finally:
                            run(worker, 'REVERT;')
                        return run(worker, 'SELECT @@TRANCOUNT;')[0][0][0]
                    finally:
                        run(worker, 'IF @@TRANCOUNT>0 ROLLBACK TRANSACTION;')

                with ThreadPoolExecutor(max_workers=1) as pool:
                    future = pool.submit(receipt)
                    try:
                        deadline = time.monotonic() + 5
                        blocked = []
                        while time.monotonic() < deadline and not future.done():
                            blocked = run(observer, '''SELECT session_id,blocking_session_id,wait_type,wait_resource
                                FROM sys.dm_exec_requests WHERE session_id=? AND blocking_session_id=?;''', (worker_id, blocker))[0]
                            if blocked:
                                break
                            time.sleep(.02)
                        assert blocked, 'Receipt must wait for production completion'
                        print('26b B1 receipt waiting', tuple(blocked[0]))
                    finally:
                        run(conn, 'COMMIT TRANSACTION;' if commit_order else 'ROLLBACK TRANSACTION;')
                    assert future.result(timeout=15) == 0
                qty, locked = run(conn, 'SELECT on_hand_qty,locked_qty FROM dbo.Inventory WHERE ingredient_id=?;', (p,))[0][0]
                status = scalar('SELECT order_status FROM dbo.SalesOrder WHERE order_id=?;', oid)
                assert (qty, locked, status) == (expected, 0 if commit_order else 2, 'READY_FOR_PICKUP' if commit_order else 'IN_PRODUCTION')
                assert scalar('SELECT purchase_status FROM dbo.PurchaseOrder WHERE purchase_order_id=?;', po) == 'CLOSED'
                assert scalar('SELECT on_hand_qty FROM dbo.Inventory WHERE ingredient_id=?;', q) == 8
                print('PASS 26b receipt/order', repeat, 'commit' if commit_order else 'rollback', 'P', qty, 'locked', locked, 'order', status, 'purchase CLOSED; trancount', scalar('SELECT @@TRANCOUNT;'))
            finally:
                run(conn, 'IF @@TRANCOUNT>0 ROLLBACK TRANSACTION;')
                worker.close()
                observer.close()

    for repeat in range(1, 4):
        p = ingredient('B26-BUY-', 10)
        run(conn, 'UPDATE dbo.ProductBom SET ingredient_id=? WHERE product_id=?;', (p, product))
        barrier = Barrier(2)
        numbers = ['B26-' + uuid4().hex for _ in range(2)]

        def buy(number):
            c = connect()
            try:
                spid = run(c, 'SELECT @@SPID;')[0][0][0]
                barrier.wait(timeout=10)
                print('26b buyer starts', spid, number)
                try:
                    step(c, 'buy', OrderNo=number)
                    outcome = 'success'
                except pyodbc.Error as exc:
                    if '(50000)' not in str(exc) or '可用库存不足' not in str(exc):
                        raise
                    outcome = 'insufficient stock'
                assert run(c, 'SELECT @@TRANCOUNT;')[0][0][0] == 0
                print('26b buyer ends', spid, number, outcome, 'trancount 0')
                return outcome
            finally:
                c.close()

        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(buy, numbers))
        assert sorted(results) == ['insufficient stock', 'success']
        orders = run(conn, 'SELECT order_id,order_no,order_status FROM dbo.SalesOrder WHERE order_no IN (?,?);', numbers)[0]
        assert len(orders) == 1 and orders[0][2] == 'READY_FOR_PICKUP'
        assert scalar('SELECT on_hand_qty FROM dbo.Inventory WHERE ingredient_id=?;', p) == 4
        assert scalar('SELECT locked_qty FROM dbo.Inventory WHERE ingredient_id=?;', p) == 0
        assert scalar("SELECT COUNT(*) FROM dbo.InventoryMovement WHERE ingredient_id=? AND movement_type='LOCK';", p) == 1
        assert scalar("SELECT COUNT(*) FROM dbo.InventoryMovement WHERE ingredient_id=? AND movement_type='CONSUME';", p) == 1
        print('PASS 26b competing P x 6', repeat, 'P=4 locked=0; one full order, no failed order header or orphan lines/locks', [tuple(r) for r in orders])
    print('RESULT: 26b business concurrency pass=9 fail=0')
