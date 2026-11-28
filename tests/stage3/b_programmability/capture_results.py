"""Capture actual Flask output and archived SQL output with local headless Edge."""
import argparse
from html import escape
from pathlib import Path
import subprocess
from tempfile import TemporaryDirectory


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--log', type=Path, required=True)
    parser.add_argument('--payment', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    lines = args.log.read_text(encoding='utf-8-sig').splitlines()
    groups = [
        ('01-migration', '正式迁移与旧版回归', lambda x: 'stage3 migration committed' in x or 'RESULT: 27 ' in x or 'RESULT: regression files=' in x or 'PASS 02 ' in x),
        ('03-recursion', '套餐递归查询', lambda x: x.startswith('24b ') or x.startswith('PASS 24b')),
        ('04-commit', '制作完成提交与重复调用', lambda x: x.startswith('25b | commit') or x.startswith('25b | PICKUP') or x.startswith('25b | DELIVERY')),
        ('05-rollback', '写入后强制回滚与拒绝路径', lambda x: x.startswith('25b | forced') or x.startswith('25b | no ') or x.startswith('25b | missing') or x.startswith('25b | insufficient') or '25b PASS' in x),
        ('06-concurrency', '订单与补货等待、两笔并发购买', lambda x: x.startswith('PASS 26b ') or x.startswith('RESULT: 26b ')),
        ('07-permissions', '角色权限核对', lambda x: x.startswith('PASS B permissions') or x.startswith('PASS 02 ')),
        ('08-deadlock-verification', '业务死锁复核与三域验收', lambda x: 'receipt deadlock victim:' in x or 'PASS B review of C' in x or 'RESULT: stage3-' in x or 'PASS isolated database removed' in x),
    ]
    args.output.mkdir(parents=True, exist_ok=True)
    edge = Path('C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe')
    with TemporaryDirectory(prefix='kfc-b-shots-') as scratch:
        directory = Path(scratch)
        pages = [('02-payment', args.payment.read_text(encoding='utf-8'))]
        for name, title, match in groups:
            selected = [line.replace('[Microsoft][ODBC Driver 18 for SQL Server][SQL Server]', '') for line in lines if match(line)]
            if not selected:
                raise AssertionError(f'Missing actual output: {name}')
            body = escape('\n\n'.join(selected))
            pages.append((name, '<!doctype html><meta charset="utf-8"><style>body{margin:36px;font-family:Segoe UI,Microsoft YaHei,sans-serif;color:#17212b}h1{font-size:26px}p{color:#54616d}pre{font:17px/1.65 Consolas,Microsoft YaHei,monospace;white-space:pre-wrap;overflow-wrap:anywhere;background:#f3f5f7;padding:24px;border:1px solid #cbd3da}</style>'
                          f'<h1>{escape(title)}</h1><p>2026-11-28 · 本机 SQL Server 实测输出 · 节选自 {escape(args.log.name)}</p><pre>{body}</pre>'))
        for name, html in pages:
            source = directory / (name + '.html')
            source.write_text(html, encoding='utf-8')
            shot = args.output.resolve() / (name + '.png')
            subprocess.run([str(edge), '--headless=new', '--disable-gpu', '--no-first-run', '--hide-scrollbars',
                            '--force-device-scale-factor=1', '--window-size=1440,1400',
                            f'--user-data-dir={directory / "profile"}', f'--screenshot={shot}', source.as_uri()],
                           capture_output=True, check=True, timeout=45, creationflags=subprocess.CREATE_NO_WINDOW)
            assert shot.read_bytes().startswith(b'\x89PNG') and shot.stat().st_size > 5000
            print('PASS screenshot', shot.name)


if __name__ == '__main__':
    main()
