"""Run real order/receipt waits and deadlock comparisons in disposable v1.1."""

import argparse
from concurrent.futures import ThreadPoolExecutor
from contextlib import ExitStack, closing
import json
from pathlib import Path
import sys
import time
from uuid import uuid4

import pyodbc

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tests/stage2/orders"))
from check_migration import run


def scalar(conn, sql, *params):
    return run(conn, sql, params)[0][0][0]


def as_employee(conn, account, sql, *params):
    run(conn, f"EXECUTE AS USER = N'test_{account}';")
    try:
        run(conn, sql, params)
    except pyodbc.Error:
        run(conn, "IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;")
        raise
    finally:
        run(conn, "REVERT;")


def prepare(conn, initial):
    token = uuid4().hex
    ingredient = scalar(conn, """INSERT dbo.Ingredient(ingredient_name,unit_name,safety_stock_qty,status)
        OUTPUT inserted.ingredient_id VALUES(?,N'piece',0,'ACTIVE');""", "C26-" + token)
    run(conn, """INSERT dbo.Inventory(ingredient_id,on_hand_qty,locked_qty,updated_at)
        VALUES(?,?,0,SYSDATETIME());""", (ingredient, initial))
    product = scalar(conn, """INSERT dbo.Product(product_name,base_price,product_type,status)
        OUTPUT inserted.product_id VALUES(?,10,'SINGLE','ACTIVE');""", "C26-" + token)
    run(conn, "INSERT dbo.ProductBom(product_id,ingredient_id,usage_qty) VALUES(?,?,1);", (product, ingredient))

    customer = scalar(conn, "SELECT MIN(customer_id) FROM dbo.Customer WHERE status='ACTIVE' AND member_level_id IS NOT NULL;")
    number = "C26-" + token
    as_employee(conn, "cashier", "EXEC dbo.sp_create_order ?, 'PICKUP', ?, ?;", customer, number,
                json.dumps([{"product_id": product, "quantity": 2}]))
    order, amount = run(conn, "SELECT order_id,total_amount FROM dbo.SalesOrder WHERE order_no=?;", (number,))[0][0]
    as_employee(conn, "cashier", "EXEC dbo.sp_pay_order ?, 'CASH', ?, NULL;", order, amount)
    as_employee(conn, "chef", "EXEC dbo.sp_start_production ?;", order)

    shift = scalar(conn, "SELECT employee_id FROM dbo.EmployeeAccount WHERE database_user_name='test_shift_manager';")
    store = scalar(conn, "SELECT employee_id FROM dbo.EmployeeAccount WHERE database_user_name='test_store_manager';")
    as_employee(conn, "shift_manager", "EXEC dbo.sp_create_replenishment_suggestion ?, 5, ?;", ingredient, shift)
    suggestion = scalar(conn, "SELECT replenishment_suggestion_id FROM dbo.ReplenishmentSuggestion WHERE ingredient_id=?;", ingredient)
    as_employee(conn, "shift_manager", "EXEC dbo.sp_submit_replenishment_suggestion ?, ?;", suggestion, shift)
    as_employee(conn, "store_manager", "EXEC dbo.sp_approve_replenishment_suggestion ?, ?;", suggestion, store)
    purchase = scalar(conn, "SELECT purchase_order_id FROM dbo.PurchaseOrder WHERE replenishment_suggestion_id=?;", suggestion)
    return ingredient, order, purchase, shift


def finish(conn, fixture):
    as_employee(conn, "packer", "EXEC dbo.sp_finish_production ?;", fixture[1])


def receive(conn, fixture):
    as_employee(conn, "shift_manager", "EXEC dbo.sp_receive_inventory ?, ?, 5;", fixture[2], fixture[3])


def lock_in_order(conn, fixtures):
    for ingredient, *_ in fixtures:
        scalar(conn, "SELECT ingredient_id FROM dbo.Inventory WITH (UPDLOCK, ROWLOCK) WHERE ingredient_id=?;", ingredient)


def wait_for_lock(observer, waiting, blocker, work):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline and not work.done():
        rows = run(observer, """SELECT session_id, blocking_session_id, wait_type, wait_resource
            FROM sys.dm_exec_requests WHERE session_id=? AND blocking_session_id=? AND wait_type LIKE 'LCK%';""",
                   (waiting, blocker))[0]
        if rows:
            print("lock wait", tuple(rows[0]), flush=True)
            return
        time.sleep(0.05)
    raise AssertionError(f"No lock wait for {waiting} blocked by {blocker}")


def receipt_wait(connect, order_commits):
    with ExitStack() as stack:
        observer, order_conn, receive_conn = [stack.enter_context(closing(connect())) for _ in range(3)]
        p = prepare(observer, 10)
        ingredient, order, purchase, _ = p
        spids = [scalar(c, "SELECT @@SPID;") for c in (observer, order_conn, receive_conn)]
        assert len(set(spids)) == 3
        _, order_spid, receipt_spid = spids
        print("order commits" if order_commits else "order rolls back", "P", ingredient, "SPIDs", spids)
        run(order_conn, "BEGIN TRANSACTION;")
        try:
            finish(order_conn, p)
            with ThreadPoolExecutor(max_workers=1) as pool:
                task = pool.submit(receive, receive_conn, p)
                try:
                    wait_for_lock(observer, receipt_spid, order_spid, task)
                    run(order_conn, "COMMIT TRANSACTION;" if order_commits else "ROLLBACK TRANSACTION;")
                finally:
                    run(order_conn, "IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;")
                task.result(timeout=15)
        finally:
            run(order_conn, "IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;")

        if order_commits:
            verify(observer, p, 13, receipt_committed=True)
        else:
            stock = tuple(run(observer, "SELECT on_hand_qty,locked_qty FROM dbo.Inventory WHERE ingredient_id=?;", (ingredient,))[0][0])
            status = scalar(observer, "SELECT order_status FROM dbo.SalesOrder WHERE order_id=?;", order)
            po = scalar(observer, "SELECT purchase_status FROM dbo.PurchaseOrder WHERE purchase_order_id=?;", purchase)
            movement = [tuple(row) for row in run(observer, """SELECT movement_type,on_hand_delta,locked_delta
                FROM dbo.InventoryMovement WHERE ingredient_id=? AND movement_type IN ('RECEIPT','CONSUME');""",
                       (ingredient,))[0]]
            assert (stock, status, po, movement) == ((15, 2), "IN_PRODUCTION", "CLOSED", [("RECEIPT", 5, 0)])
            print(f"ingredient={ingredient} order={order} purchase={purchase}", stock, status, po, movement)
        assert all(scalar(c, "SELECT @@TRANCOUNT;") == 0 for c in (observer, order_conn, receive_conn))
        print("transactions open: 0/0/0")


def verify(observer, fixture, expected_qty, receipt_committed):
    ingredient, order, purchase, _ = fixture
    inv = tuple(run(observer, "SELECT on_hand_qty,locked_qty FROM dbo.Inventory WHERE ingredient_id=?;", (ingredient,))[0][0])
    status = scalar(observer, "SELECT order_status FROM dbo.SalesOrder WHERE order_id=?;", order)
    po = tuple(run(observer, """SELECT p.purchase_status, i.received_qty FROM dbo.PurchaseOrder AS p
        JOIN dbo.PurchaseOrderItem AS i ON i.purchase_order_id=p.purchase_order_id WHERE p.purchase_order_id=?;""",
                   (purchase,))[0][0])
    movement = [tuple(row) for row in run(observer, """SELECT movement_type,on_hand_delta,locked_delta
        FROM dbo.InventoryMovement WHERE ingredient_id=?
        AND movement_type IN ('RECEIPT','CONSUME') ORDER BY movement_type;""", (ingredient,))[0]]
    audit = [tuple(row) for row in run(observer, """SELECT delta_on_hand,delta_locked FROM dbo.InventoryAudit
        WHERE ingredient_id=? AND operation_type='UPDATE' AND delta_on_hand<>0 ORDER BY delta_on_hand;""", (ingredient,))[0]]
    assert inv == (expected_qty, 0) and status == "READY_FOR_PICKUP"
    assert po == (("CLOSED", 5) if receipt_committed else ("APPROVED", 0))
    expected_movement = [("CONSUME", -2, -2)]
    expected_audit = [(-2, -2)]
    if receipt_committed:
        expected_movement.append(("RECEIPT", 5, 0))
        expected_audit.append((5, 0))
    assert movement == expected_movement and audit == expected_audit
    print(f"ingredient={ingredient} order={order} purchase={purchase}", inv, status, po, movement, audit)


def experiment(connect, ordered):
    with ExitStack() as stack:
        observer, order_conn, receive_conn = [stack.enter_context(closing(connect())) for _ in range(3)]
        p, q = prepare(observer, 10), prepare(observer, 8)
        assert p[0] < q[0]
        spids = [scalar(c, "SELECT @@SPID;") for c in (observer, order_conn, receive_conn)]
        assert len(set(spids)) == 3
        _, order_spid, receipt_spid = spids
        print("ordered" if ordered else "reverse", "P/Q", p[0], q[0], "observer/order/receipt SPIDs", spids)
        run(order_conn, "BEGIN TRANSACTION;")
        run(receive_conn, "SET DEADLOCK_PRIORITY LOW; BEGIN TRANSACTION;")
        try:
            if ordered:
                lock_in_order(order_conn, (p, q))
                finish(order_conn, p)

                def both_receipts():
                    lock_in_order(receive_conn, (p, q))
                    receive(receive_conn, q)
                    receive(receive_conn, p)
                    run(receive_conn, "COMMIT TRANSACTION;")

                with ThreadPoolExecutor(max_workers=1) as pool:
                    task = pool.submit(both_receipts)
                    try:
                        wait_for_lock(observer, receipt_spid, order_spid, task)
                        finish(order_conn, q)
                        run(order_conn, "COMMIT TRANSACTION;")
                    finally:
                        run(order_conn, "IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;")
                    task.result(timeout=15)
            else:
                finish(order_conn, p)
                receive(receive_conn, q)
                with ThreadPoolExecutor(max_workers=1) as pool:
                    task = pool.submit(finish, order_conn, q)
                    try:
                        wait_for_lock(observer, order_spid, receipt_spid, task)
                        try:
                            receive(receive_conn, p)
                        except pyodbc.Error as exc:
                            if "(1205)" not in str(exc) or "deadlock victim" not in str(exc).lower():
                                raise
                            print("receipt deadlock victim:", exc)
                        else:
                            raise AssertionError("Reverse order failed to produce SQL Server error 1205")
                    finally:
                        run(receive_conn, "IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;")
                    task.result(timeout=15)
                    run(order_conn, "COMMIT TRANSACTION;")
        finally:
            for conn in (order_conn, receive_conn):
                run(conn, "IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;")
        verify(observer, p, 13 if ordered else 8, ordered)
        verify(observer, q, 11 if ordered else 6, ordered)
        assert all(scalar(c, "SELECT @@TRANCOUNT;") == 0 for c in (observer, order_conn, receive_conn))
        print("transactions open: 0/0/0")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sql-server", default=r".\SQLEXPRESS")
    parser.add_argument("--rounds", type=int, default=3)
    args = parser.parse_args()
    if args.rounds < 1:
        parser.error("--rounds must be positive")
    pyodbc.pooling = False

    def connect():
        conn = pyodbc.connect("DRIVER={ODBC Driver 18 for SQL Server};SERVER=" + args.sql_server
                              + ";DATABASE=KFC_DB;Trusted_Connection=Yes;TrustServerCertificate=Yes;",
                              autocommit=True, timeout=5)
        conn.timeout = 15
        run(conn, "SET LANGUAGE us_english; SET LOCK_TIMEOUT 10000; SET TRANSACTION ISOLATION LEVEL READ COMMITTED;")
        return conn

    with closing(connect()) as observer:
        if scalar(observer, """SELECT COUNT(*) FROM dbo.SchemaVersion AS v JOIN dbo.MigrationBatch AS b
            ON b.batch_id=v.batch_id WHERE v.version_code='v1.1' AND b.source_baseline='C-Stage3-Disposable';""") != 1:
            parser.error("KFC_DB must be the disposable C-Stage3-Disposable v1.1 database")
        print(scalar(observer, "SELECT @@VERSION;"))
        print("READ COMMITTED, RCSI =", scalar(observer, "SELECT is_read_committed_snapshot_on FROM sys.databases WHERE database_id=DB_ID();"))
    for _ in range(args.rounds):
        receipt_wait(connect, order_commits=True)
        receipt_wait(connect, order_commits=False)
        experiment(connect, ordered=False)
        experiment(connect, ordered=True)
    print(f"RESULT: stage3-c-business-concurrency pass={4 * args.rounds} fail=0")


if __name__ == "__main__":
    main()
