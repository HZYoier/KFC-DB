"""Render real Flask responses from B's disposable migration rehearsal with Edge."""

import argparse
from decimal import Decimal
from pathlib import Path
import re
import subprocess
import sys
from tempfile import TemporaryDirectory
from urllib.parse import urlsplit
from uuid import uuid4

from flask.testing import FlaskClient


HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
sys.path.insert(0, str(ROOT / 'tests/stage2/orders'))
import check_migration as rehearsal


SHOTS = {
    'login': (1, '员工登录', 850),
    'CASHIER': (2, '创建订单', 1120),
    'payment': (3, '支付详情', 1220),
    'CHEF': (4, '开始制作', 500),
    'PACKER': (5, '制作明细', 620),
    'WAITER': (6, '取餐叫号', 490),
    'RIDER': (7, '我的配送', 510),
    'STORE_MANAGER': (8, '可核对的订单', 510),
}


def seed_deliveries(conn, mobile, product):
    """Leave one delivery ready and one in progress for the rider screenshot."""
    if not re.fullmatch(r'[0-9]{11}', mobile):
        raise AssertionError('Unexpected fixture phone shape')
    customer = int(rehearsal.run(conn, f"SELECT customer_id FROM dbo.Customer WHERE mobile='{mobile}';")[0][0][0])
    rider = int(rehearsal.run(conn, "SELECT employee_id FROM dbo.EmployeeAccount WHERE database_user_name='test_rider';")[0][0][0])
    for suffix in ('READY', 'CLAIMED'):
        number = 'B-UI-' + suffix + '-' + uuid4().hex[:8].upper()
        with rehearsal.as_user(conn, 'test_cashier'):
            rehearsal.run(conn, f"""EXEC dbo.sp_create_order {customer}, 'DELIVERY', '{number}',
                N'[{{"product_id":{int(product)},"quantity":1}}]';""")
        row = rehearsal.run(conn, f"SELECT order_id,total_amount FROM dbo.SalesOrder WHERE order_no='{number}';")[0][0]
        order, amount = int(row[0]), Decimal(row[1])
        with rehearsal.as_user(conn, 'test_cashier'):
            rehearsal.run(conn, f"EXEC dbo.sp_pay_order {order}, 'CASH', {amount}, NULL;")
        with rehearsal.as_user(conn, 'test_chef'):
            rehearsal.run(conn, f'EXEC dbo.sp_start_production {order};')
        with rehearsal.as_user(conn, 'test_packer'):
            rehearsal.run(conn, f'EXEC dbo.sp_finish_production {order};')
        if suffix == 'CLAIMED':
            with rehearsal.as_user(conn, 'test_rider'):
                rehearsal.run(conn, f'EXEC dbo.sp_pick_up_delivery {order}, {rider};')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sql-server', required=True)
    parser.add_argument('--edge', required=True, type=Path)
    args = parser.parse_args()
    if not args.edge.is_file():
        parser.error('--edge must point to the installed Edge executable')

    pages = {}
    from app import create_app

    class CapturingClient(FlaskClient):
        def get(self, path, *args, **kwargs):
            response = super().get(path, *args, **kwargs)
            if urlsplit(path).path != '/orders/':
                return response
            if response.status_code == 302 and 'login' not in pages:
                login = super().get(response.location)
                if login.status_code == 200 and 'KFC-DB 员工登录' in login.get_data(as_text=True):
                    pages['login'] = login.get_data(as_text=True)
            if response.status_code == 200:
                html = response.get_data(as_text=True)
                match = re.search(r'岗位：([A-Z_]+)', html)
                if match:
                    key = 'payment' if 'detail=' in path else match[1]
                    if key in SHOTS and SHOTS[key][1] in html:
                        pages.setdefault(key, html)
            return response

    import app

    def capture_app(*positional, **keywords):
        application = create_app(*positional, **keywords)
        application.test_client_class = CapturingClient
        return application

    check_web = rehearsal.check_web

    def capture_web(conn, server, database, mobile, product):
        seed_deliveries(conn, mobile, product)
        return check_web(conn, server, database, mobile, product)

    app.create_app = capture_app
    rehearsal.check_web = capture_web
    sys.argv = [sys.argv[0], '--sql-server', args.sql_server, '--web']
    rehearsal.main()
    if pages.keys() != SHOTS.keys():
        raise AssertionError(f'Missing pages: {sorted(SHOTS.keys() - pages.keys())}')
    assert 'B-UI-READY-' in pages['RIDER'] and 'B-UI-CLAIMED-' in pages['RIDER']
    assert '确认支付' in pages['payment'] and '开始制作' in pages['CHEF']

    with TemporaryDirectory(prefix='kfc-b-render-', ignore_cleanup_errors=True) as scratch:
        directory = Path(scratch)
        for key, (ordinal, _, height) in SHOTS.items():
            name = f'b-orders-ui-{ordinal:02d}-{key.lower().replace("_", "-")}'
            html_path = directory / (name + '.html')
            # Render only HTML; never save request credentials, cookies or hidden form tokens.
            html = re.sub(r'(name="(?:csrf|attempt)" value=")[^"]+', r'\1', pages[key])
            html_path.write_text(html, encoding='utf-8')
            screenshot = directory / (name + '.png')
            subprocess.run([
                str(args.edge.resolve()), '--headless=new', '--disable-gpu', '--no-first-run',
                '--hide-scrollbars', '--force-device-scale-factor=1',
                f'--user-data-dir={directory / "profile"}', f'--window-size=1440,{height}',
                f'--screenshot={screenshot}', html_path.as_uri(),
            ], check=True, timeout=45, capture_output=True, creationflags=subprocess.CREATE_NO_WINDOW)
            data = screenshot.read_bytes()
            if not data.startswith(b'\x89PNG\r\n\x1a\n') or len(data) < 5000:
                raise AssertionError(f'Invalid screenshot: {name}')
            (HERE / screenshot.name).write_bytes(data)
            print(f'PASS screenshot {screenshot.name} ({len(data)} bytes)')


if __name__ == '__main__':
    main()
