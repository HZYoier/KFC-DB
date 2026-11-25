from contextlib import closing
from datetime import date
from pathlib import Path
import re
import sys
from unittest.mock import patch

sys.path.insert(0, str(Path.cwd()))
sys.path.insert(0, str(Path.cwd() / "tests/stage2/orders"))
from check_migration import as_user, expect_error, run
from app import create_app
from app.common import db
from app.common.config import DbConfig
import pyodbc

cfg = DbConfig("ODBC Driver 18 for SQL Server", r".\SQLEXPRESS", "KFC_DB",
               trust_server_certificate="yes", trusted_connection=True)
cs = cfg.connection_string()
pyodbc.pooling = False
accounts = {"test_store_manager", "test_shift_manager", "test_cashier"}
original_connect = db.open_connection

def connect_as_user(session, **kwargs):
    account = session["db_login"]
    assert account in accounts
    conn = original_connect(None, **kwargs)
    run(conn, f"EXECUTE AS USER=N'{account}';")
    return conn

app = create_app(cfg)
def login(account):
    client = app.test_client()
    assert client.post("/login", data={"login": account, "password": "local-fixture"}).status_code == 302
    return client

with closing(pyodbc.connect(cs, autocommit=True, timeout=5)) as conn:
    assert run(conn, """SELECT COUNT(*) FROM dbo.SchemaVersion v JOIN dbo.MigrationBatch b ON b.batch_id=v.batch_id
            WHERE v.version_code='v1.1' AND b.source_baseline='C-Stage3-Disposable';""")[0][0][0] == 1
    start, end = run(conn, "SELECT CONVERT(DATE,MIN(completed_at)),CONVERT(DATE,MAX(completed_at)) FROM dbo.v_settled_sales_line;")[0][0]
    item = run(conn, "SELECT TOP (1) ingredient_id FROM dbo.InventoryAudit WHERE operation_type='UPDATE' ORDER BY inventory_audit_id DESC;")[0][0][0]
    with as_user(conn, "test_store_manager"):
        raw, rows = run(conn, "EXEC dbo.sp_sales_report ?,?;", (start, end))
        assert rows and raw[0][0] == 2, tuple(raw[0])
        sums = tuple(run(conn, "SELECT SUM(sold_qty), SUM(sales_amount) FROM dbo.fn_product_sales_summary(?,?);", (start, end))[0][0])
        assert sums == tuple(raw[0])[1:3]
        expect_error(conn, "UPDATE dbo.InventoryAudit SET delta_on_hand=0 WHERE 1=0;", 229, "UPDATE")
    with as_user(conn, "test_cashier"):
        expect_error(conn, "SELECT * FROM dbo.InventoryAudit;", 229, "SELECT")
        expect_error(conn, "EXEC dbo.sp_sales_report ?,?;", 229, "EXECUTE", params=(start,end))
    print("PASS SQL grants: manager reports and read-only audit; cashier receives 229 on both")
    print("PASS matching report and TVF:", (start,end), tuple(raw[0]), sums)
    with patch.object(db, "open_connection", side_effect=connect_as_user):
        manager = login("test_store_manager")
        assert "/reports/sales" in manager.get("/").get_data(as_text=True)
        response = manager.get(f"/reports/sales?start={start}&end={end}")
        page = response.get_data(as_text=True)
        assert response.status_code == 200 and re.findall(r"<b>([^<]+)</b>", page) == [str(val) for val in raw[0]]
        assert all(row[1] in page for row in rows)
        response = manager.get("/reports/sales?start=2000-01-01&end=2000-01-01")
        page = response.get_data(as_text=True)
        assert response.status_code == 200 and "该区间没有已结算销售" in page
        assert re.findall(r"<b>([^<]+)</b>", page) == ["0", "0", "0.00"]
        assert "/inventory/audit" in manager.get("/inventory/").get_data(as_text=True)
        response = manager.get(f"/inventory/audit?ingredient_id={item}")
        assert response.status_code == 200 and "<td>UPDATE</td>" in response.get_data(as_text=True)
        assert manager.get("/inventory/audit?ingredient_id=bad").status_code == 400
        shift = login("test_shift_manager")
        assert shift.get("/inventory/audit").status_code == 403
        response = shift.get(f"/inventory/replenishment/default?ingredient_id={item}&target_qty=20")
        assert response.status_code == 200 and "数据库建议量" in response.get_data(as_text=True)
        cashier = login("test_cashier")
        assert "/reports/sales" not in cashier.get("/").get_data(as_text=True)
    print("RESULT: Flask reports, empty range, audit read/filter/deny, shift replenishment verified")
