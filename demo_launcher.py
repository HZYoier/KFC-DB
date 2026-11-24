"""KFC-DB 演示一键启动：检测实例与数据库，缺库时建库，然后启动应用并打开浏览器。

用法（仓库根目录）：
    .venv\\Scripts\\python.exe demo_launcher.py
    .venv\\Scripts\\python.exe demo_launcher.py --server .\\SQLEXPRESS --port 5000
    .venv\\Scripts\\python.exe demo_launcher.py --check

边界：
- 不会安装 SQL Server 实例；实例不存在时只打印排查提示。
- 不会替员工设置口令；缺少登录时打印 provision 模板命令。
- 缺 KFC_DB 时会依次执行 stage1 run_all、capture_baseline、run_migration，
  建的是 v1.0；耗时数分钟，需要当前 Windows 身份有建库权限。
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import socket
import subprocess
import sys
import time
import webbrowser
from pathlib import Path

# Git Bash 默认 UTF-8；Windows 控制台在 cmd 里由 start_demo.cmd 先 chcp 65001。
for stream in (sys.stdout, sys.stderr):
    if hasattr(stream, "reconfigure"):
        stream.reconfigure(encoding="utf-8")

ROOT = Path(__file__).resolve().parent
DEFAULT_DB = "KFC_DB"
DEFAULT_SERVER = "localhost"


def find_sqlcmd() -> str | None:
    found = shutil.which("sqlcmd")
    if found:
        return found
    candidates = [
        Path(r"C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\180\Tools\Binn\sqlcmd.exe"),
        Path(r"C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\170\Tools\Binn\sqlcmd.exe"),
    ]
    for path in candidates:
        if path.is_file():
            return str(path)
    return None


def find_python() -> str:
    for relative in (r".venv\Scripts\python.exe", ".venv/bin/python"):
        path = ROOT / relative
        if path.is_file():
            return str(path)
    return sys.executable


def run(args: list[str], *, timeout: int | None = None,
        capture: bool = False) -> subprocess.CompletedProcess:
    kwargs = dict(cwd=ROOT, timeout=timeout, text=True, encoding="utf-8", errors="replace")
    if capture:
        kwargs["capture_output"] = True
    return subprocess.run(args, **kwargs)


def sqlcmd_base(sqlcmd: str, server: str) -> list[str]:
    return [sqlcmd, "-S", server, "-E", "-C", "-f", "65001", "-b"]


def query_scalar(sqlcmd: str, server: str, database: str | None, sql: str) -> tuple[int, str]:
    cmd = sqlcmd_base(sqlcmd, server) + ["-h", "-1", "-W", "-Q", sql]
    if database:
        cmd += ["-d", database]
    try:
        result = run(cmd, timeout=20, capture=True)
    except (OSError, subprocess.TimeoutExpired) as exc:
        return 1, str(exc)
    return result.returncode, (result.stdout or "").strip()


def instance_ok(sqlcmd: str, server: str) -> bool:
    code, _ = query_scalar(sqlcmd, server, None, "SET NOCOUNT ON; SELECT @@SERVERNAME;")
    return code == 0


def database_exists(sqlcmd: str, server: str, database: str) -> bool | None:
    code, output = query_scalar(
        sqlcmd, server, None,
        "SET NOCOUNT ON; SELECT DB_ID(N'%s');" % database.replace("'", "''"),
    )
    if code != 0:
        return None
    numbers = re.findall(r"-?\d+", output)
    return bool(numbers and numbers[-1] != "0")


def run_script(sqlcmd: str, server: str, path: Path, *, database: str | None = None,
               variables: dict[str, str] | None = None, extra: list[str] | None = None) -> int:
    cmd = sqlcmd_base(sqlcmd, server)
    if database:
        cmd += ["-d", database]
    for key, value in (variables or {}).items():
        cmd += ["-v", f"{key}={value}"]
    cmd += extra or []
    cmd += ["-i", str(path)]
    print("[demo] " + " ".join(cmd))
    return run(cmd).returncode


def bootstrap_database(sqlcmd: str, server: str, database: str) -> bool:
    """从空实例建 v0.1，采集基线并迁移到 v1.0。只建库，不删库。"""
    print(f"[demo] 数据库 {database} 不存在，开始按仓库脚本建库（数分钟）...")
    steps = [
        (ROOT / "sql/stage1/run_all.sql", None, None),
        (ROOT / "sql/stage2/capture_baseline.sql", None,
         {"SourceBaseline": "demo-bootstrap", "ConfirmAppStopped": "YES"}),
        (ROOT / "sql/stage2/run_migration.sql", None, None),
    ]
    for script, db, variables in steps:
        if not script.is_file():
            print(f"[demo] 缺少 {script}，停止建库。")
            return False
        extra = ["-I"] if script.name == "run_migration.sql" else None
        if run_script(sqlcmd, server, script, database=db, variables=variables, extra=extra) != 0:
            print(f"[demo] {script.name} 失败，停止。数据库可能停在中间状态，请按文档恢复或重建。")
            return False
    code, output = query_scalar(
        sqlcmd, server, database,
        "SET NOCOUNT ON; SELECT CASE WHEN EXISTS "
        "(SELECT 1 FROM dbo.SchemaVersion WHERE version_code = N'v1.0') "
        "THEN 1 ELSE 0 END;",
    )
    if code != 0 or "1" not in re.findall(r"\d+", output):
        print("[demo] 建库后未读到 v1.0 标记：", output)
        return False
    print("[demo] 建库完成，当前为 v1.0。")
    return True


def employee_login_exists(sqlcmd: str, server: str) -> bool | None:
    code, output = query_scalar(
        sqlcmd, server, None,
        "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.server_principals "
        "WHERE name = N'test_store_manager';",
    )
    if code != 0:
        return None
    numbers = re.findall(r"\d+", output)
    return bool(numbers and int(numbers[-1]) > 0)


def wait_for_port(port: int, timeout: float = 25.0) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
            sock.settimeout(0.5)
            if sock.connect_ex(("127.0.0.1", port)) == 0:
                return True
        time.sleep(0.3)
    return False


def load_customer_credentials(env: dict[str, str]) -> bool:
    """本地演示的 cust_app 凭据（.demo/cust_app.txt，已被 .gitignore 忽略）。"""
    path = ROOT / ".demo/cust_app.txt"
    if not path.is_file():
        return False
    values = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            values[key.strip()] = value.strip()
    if not values.get("login") or not values.get("password"):
        return False
    env.setdefault("KFC_CUST_DB_LOGIN", values["login"])
    env.setdefault("KFC_CUST_DB_PASSWORD", values["password"])
    return True


def start_app(server: str, database: str, port: int, no_browser: bool) -> int:
    env = os.environ.copy()
    env.setdefault("KFC_DB_SERVER", server)
    env.setdefault("KFC_DB_NAME", database)
    env.setdefault("KFC_DB_TRUST_CERT", "yes")
    env.setdefault("KFC_APP_PORT", str(port))
    if load_customer_credentials(env):
        print("[demo] 顾客端共享凭据已加载：/customer 可直接演示。")
    else:
        print("[demo] 未找到 .demo/cust_app.txt；/customer 会按设计 fail closed。")
    python = find_python()

    print(f"[demo] 启动应用：{python} run.py")
    process = subprocess.Popen([python, "run.py"], cwd=ROOT, env=env)
    try:
        if wait_for_port(port):
            url = f"http://127.0.0.1:{port}/"
            print(f"[demo] 已就绪：{url}")
            if not no_browser:
                webbrowser.open(url)
        else:
            print(f"[demo] 端口 {port} 在 25 秒内未就绪；应用仍在运行，请查看上方输出。")
        return process.wait()
    except KeyboardInterrupt:
        print("\n[demo] 收到 Ctrl+C，停止应用。")
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
        return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="KFC-DB demo launcher")
    parser.add_argument("--server", default=os.environ.get("KFC_DB_SERVER", DEFAULT_SERVER))
    parser.add_argument("--database", default=os.environ.get("KFC_DB_NAME", DEFAULT_DB))
    parser.add_argument("--port", type=int, default=int(os.environ.get("KFC_APP_PORT", "5000")))
    parser.add_argument("--check", action="store_true", help="只检测实例/数据库，不启动应用")
    parser.add_argument("--no-bootstrap", action="store_true", help="数据库不存在时不自动建库")
    parser.add_argument("--no-browser", action="store_true", help="不自动打开浏览器")
    args = parser.parse_args()

    sqlcmd = find_sqlcmd()
    if sqlcmd is None:
        print("[demo] 找不到 sqlcmd；请安装 ODBC Driver 18 的客户端工具，或把 sqlcmd 加入 PATH。")
        return 2

    if not instance_ok(sqlcmd, args.server):
        print(f"[demo] 连不上 SQL Server 实例 {args.server}。")
        print("[demo] 本脚本不会安装实例；请先安装/启动 SQL Server，或用 --server 指定实例。")
        print("[demo] 本机可用实例可尝试：sqlcmd -L")
        return 2
    print(f"[demo] 实例可用：{args.server}")

    exists = database_exists(sqlcmd, args.server, args.database)
    if exists is None:
        print("[demo] 无法读取数据库列表，请确认当前 Windows 身份有权限。")
        return 2
    if not exists:
        if args.no_bootstrap:
            print(f"[demo] 数据库 {args.database} 不存在；按文档先跑 sql/stage1/run_all.sql 与 stage2 迁移。")
            return 2
        if not bootstrap_database(sqlcmd, args.server, args.database):
            return 2
    else:
        print(f"[demo] 数据库已存在：{args.database}")

    login = employee_login_exists(sqlcmd, args.server)
    if login is False:
        print("[demo] 注意：服务器登录 test_store_manager 不存在，网页登录会失败。")
        print("[demo] 请先运行（会交互输入口令，不要写进仓库）：")
        print("  powershell -ExecutionPolicy Bypass -File sql/stage2/provision_employee.template.ps1 "
              f"-SqlInstance '{args.server}' -LoginName test_store_manager "
              "-EmployeeName 测试店长 -JobCode STORE_MANAGER -BootstrapStoreManager")
    elif login is None:
        print("[demo] 无法检查员工登录，继续启动。")

    if args.check:
        print("[demo] 检测完成（--check，不启动应用）。")
        return 0

    return start_app(args.server, args.database, args.port, args.no_browser)


if __name__ == "__main__":
    raise SystemExit(main())
