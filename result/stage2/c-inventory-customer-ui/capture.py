"""Render C's v1.0 employee/customer pages with a real SQL login and Edge.

Prerequisite: KFC_DB is already migrated to v1.0. The script temporarily maps
test_store_manager and cust_app to random SQL logins, captures HTML pages from
Flask's test client, renders PNGs with Edge headless, then restores the users to
WITHOUT LOGIN and drops the temporary logins. Passwords are never printed.
"""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import re
import secrets
import string
import subprocess
import sys
import time
from tempfile import TemporaryDirectory

import pyodbc

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
sys.path.insert(0, str(ROOT))
DRIVER = "ODBC Driver 18 for SQL Server"
SERVER = r".\SQLEXPRESS"
DATABASE = "KFC_DB"
CUSTOMER_PROCS = (
    "sp_customer_register",
    "sp_customer_place_order",
    "sp_customer_list_orders",
)
ADMIN_MASTER = (
    f"DRIVER={{{DRIVER}}};SERVER={SERVER};DATABASE=master;"
    "Trusted_Connection=yes;Encrypt=yes;TrustServerCertificate=yes;"
)
ADMIN_DB = (
    f"DRIVER={{{DRIVER}}};SERVER={SERVER};DATABASE={DATABASE};"
    "Trusted_Connection=yes;Encrypt=yes;TrustServerCertificate=yes;"
)
SHOTS = [
    ("01-login", "员工登录", 820),
    ("02-identity-store", "店长身份首页（含 C/B 入口）", 820),
    ("03-inventory-dashboard", "库存看板与操作区", 2100),
    ("04-inventory-roles", "员工角色页（仅店长）", 1500),
    ("05-customer-home", "顾客自助三表单", 950),
    ("06-customer-order", "顾客下单结果（订单号/取餐码）", 1000),
    ("07-customer-orders", "顾客用双要素查回订单", 950),
]


def ident(name: str) -> str:
    return "[" + name.replace("]", "]]") + "]"


def literal(value: str) -> str:
    return "N'" + value.replace("'", "''") + "'"


def new_password() -> str:
    alphabet = string.ascii_letters + string.digits
    return "".join(secrets.choice(alphabet) for _ in range(24))


def app_user(db, login: str, user: str, role: str | None = None) -> None:
    db.execute(f"IF DATABASE_PRINCIPAL_ID({literal(user)}) IS NOT NULL DROP USER {ident(user)};")
    db.execute(f"CREATE USER {ident(user)} FOR LOGIN {ident(login)};")
    if role:
        db.execute(f"ALTER ROLE {ident(role)} ADD MEMBER {ident(user)};")


def restore_user(db, user: str, role: str | None = None) -> None:
    db.execute(f"IF DATABASE_PRINCIPAL_ID({literal(user)}) IS NOT NULL DROP USER {ident(user)};")
    db.execute(f"CREATE USER {ident(user)} WITHOUT LOGIN;")
    if role:
        db.execute(f"ALTER ROLE {ident(role)} ADD MEMBER {ident(user)};")


def drop_login(admin, login: str) -> None:
    if admin is None:
        return
    rows = admin.execute(
        "SELECT session_id FROM sys.dm_exec_sessions WHERE login_name = ?", login
    ).fetchall()
    for row in rows:
        admin.execute(f"KILL {int(row[0])};")
    admin.execute(f"IF SUSER_ID({literal(login)}) IS NOT NULL DROP LOGIN {ident(login)};")


def restore_customer(db) -> None:
    db.execute("IF DATABASE_PRINCIPAL_ID(N'cust_app') IS NOT NULL DROP USER cust_app;")
    db.execute("CREATE USER cust_app WITHOUT LOGIN;")
    db.execute("GRANT CONNECT TO cust_app;")
    for proc in CUSTOMER_PROCS:
        db.execute(f"GRANT EXECUTE ON dbo.{proc} TO cust_app;")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--browser", type=Path,
                        default=Path(r"C:\Program Files\Google\Chrome\Application\chrome.exe"))
    options = parser.parse_args()
    if not options.browser.is_file():
        parser.error("Chrome executable not found; pass --browser")
    for name, _, _ in SHOTS:
        target = HERE / f"c-inventory-customer-ui-{name}.png"
        if target.exists():
            target.unlink()

    store_login = "c_ui_store"
    cust_login = "c_ui_cust"
    password = new_password()
    cust_password = new_password()
    admin = db = None
    pages: dict[str, tuple[str, int]] = {}
    try:
        admin = pyodbc.connect(ADMIN_MASTER, autocommit=True)
        db = pyodbc.connect(ADMIN_DB, autocommit=True)
        for login in (store_login, cust_login):
            drop_login(admin, login)
        admin.execute(
            f"CREATE LOGIN {ident(store_login)} WITH PASSWORD={literal(password)}, CHECK_POLICY=OFF;"
        )
        admin.execute(
            f"CREATE LOGIN {ident(cust_login)} WITH PASSWORD={literal(cust_password)}, CHECK_POLICY=OFF;"
        )
        app_user(db, store_login, "test_store_manager", "role_store_manager")
        db.execute("IF DATABASE_PRINCIPAL_ID(N'cust_app') IS NOT NULL DROP USER cust_app;")
        db.execute(f"CREATE USER cust_app FOR LOGIN {ident(cust_login)};")
        db.execute("GRANT CONNECT TO cust_app;")
        for proc in CUSTOMER_PROCS:
            db.execute(f"GRANT EXECUTE ON dbo.{proc} TO cust_app;")

        os.environ.update(
            KFC_DB_SERVER=SERVER,
            KFC_DB_NAME=DATABASE,
            KFC_DB_DRIVER=DRIVER,
            KFC_DB_ENCRYPT="yes",
            KFC_DB_TRUST_CERT="yes",
            KFC_DB_TRUSTED_CONNECTION="no",
            KFC_CUST_DB_LOGIN=cust_login,
            KFC_CUST_DB_PASSWORD=cust_password,
            KFC_SECRET_KEY="c-ui-capture-only",
        )
        pyodbc.pooling = False
        from app import create_app
        from app.common.config import DbConfig

        app = create_app(DbConfig(driver=DRIVER, server=SERVER, database=DATABASE,
                                  encrypt="yes", trust_server_certificate="yes"))
        app.config.update(TESTING=True)

        login_client = app.test_client()
        pages["01-login"] = (login_client.get("/login").get_data(as_text=True), 820)

        client = app.test_client()
        response = client.post(
            "/login",
            data={"login": store_login, "password": password, "next": "/"},
            follow_redirects=True,
        )
        assert response.status_code == 200, response.status_code
        pages["02-identity-store"] = (response.get_data(as_text=True), 820)
        for key, path, height in (
            ("03-inventory-dashboard", "/inventory/", 2100),
            ("04-inventory-roles", "/inventory/roles", 1500),
        ):
            response = client.get(path)
            assert response.status_code == 200, f"{path}: {response.status_code}"
            pages[key] = (response.get_data(as_text=True), height)

        customer = app.test_client()
        response = customer.get("/customer")
        assert response.status_code == 200
        pages["05-customer-home"] = (response.get_data(as_text=True), 950)
        mobile = "139" + "".join(secrets.choice(string.digits) for _ in range(8))
        response = customer.post("/customer/register", data={"mobile": mobile})
        assert response.status_code == 200 and "建档结果" in response.get_data(as_text=True)
        response = customer.post("/customer/order", data={"mobile": mobile, "items": "1 1"})
        assert response.status_code == 200, response.status_code
        order_html = response.get_data(as_text=True)
        pickup = re.search(r"取餐码：<strong>([0-9A-F]{20})</strong>", order_html)
        assert pickup, "pickup code not found"
        pages["06-customer-order"] = (order_html, 1000)
        response = customer.post(
            "/customer/orders",
            data={"mobile": mobile, "pickup": pickup.group(1)},
        )
        assert response.status_code == 200
        pages["07-customer-orders"] = (response.get_data(as_text=True), 950)

        with TemporaryDirectory(prefix="kfc-c-ui-", ignore_cleanup_errors=True) as scratch:
            scratch = Path(scratch)
            for key, (html, height) in pages.items():
                html_path = scratch / f"{key}.html"
                html_path.write_text(html, encoding="utf-8")
                png = HERE / f"c-inventory-customer-ui-{key}.png"
                result = subprocess.run([
                    str(options.browser.resolve()), "--headless=new", "--disable-gpu",
                    "--no-first-run", "--hide-scrollbars", "--force-device-scale-factor=1",
                    f"--user-data-dir={scratch / 'profile'}", f"--window-size=1440,{height}",
                    f"--screenshot={png}", html_path.as_uri(),
                ], check=True, timeout=45, capture_output=True, text=True)
                for _ in range(40):
                    if png.is_file():
                        break
                    time.sleep(0.25)
                if not png.is_file():
                    raise RuntimeError("browser did not write %s: %s" % (png.name, (result.stderr or result.stdout)[:300]))
                data = png.read_bytes()
                assert data.startswith(b"\x89PNG\r\n\x1a\n") and len(data) > 5000, key
                print(f"PASS screenshot {png.name} ({len(data)} bytes)")
        return 0
    finally:
        try:
            if admin is not None:
                for login in (store_login, cust_login):
                    drop_login(admin, login)
            if db is not None:
                restore_user(db, "test_store_manager", "role_store_manager")
                restore_customer(db)
        except Exception as exc:  # noqa: BLE001 - cleanup report
            print(f"WARN: cleanup: {type(exc).__name__}: {str(exc)[:200]}")
        for obj in (db, admin):
            try:
                if obj is not None:
                    obj.close()
            except Exception:
                pass


if __name__ == "__main__":
    raise SystemExit(main())
