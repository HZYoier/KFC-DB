"""Run C's 13c permission/inventory SQL regression against a migrated v1.0 DB.

This is intentionally separate from tests/stage2/run-all.ps1: the six app suites
use fake DB connections, while this entry needs the real migrated database.
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys

EXPECTED = "RESULT: pass=15 fail=0"
DEFAULT_SQLCMD = r"C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\180\Tools\Binn\sqlcmd.exe"


def _sqlcmd(explicit: str | None) -> str | None:
    for candidate in (explicit, os.environ.get("SQLCMD"), shutil.which("sqlcmd"), DEFAULT_SQLCMD):
        if candidate and Path(candidate).is_file():
            return candidate
    return None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server", default=r".\SQLEXPRESS")
    parser.add_argument("--database", default="KFC_DB")
    parser.add_argument("--sqlcmd", default=None)
    options = parser.parse_args()

    executable = _sqlcmd(options.sqlcmd)
    if executable is None:
        print("FAIL: sqlcmd not found; pass --sqlcmd or set SQLCMD.")
        return 2

    root = Path(__file__).resolve().parents[3]
    script = root / "sql" / "stage2" / "13c_inventory_security_regression.sql"
    if not script.is_file():
        print("FAIL: missing %s" % script)
        return 2

    command = [
        executable,
        "-S", options.server,
        "-E", "-C", "-f", "65001", "-b", "-I",
        "-d", options.database,
        "-i", str(script),
    ]
    result = subprocess.run(
        command,
        cwd=str(root),
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    print(result.stdout, end="")
    if result.stderr:
        print(result.stderr, file=sys.stderr, end="")
    if result.returncode != 0:
        print("FAIL: 13c sqlcmd exit %d" % result.returncode)
        return result.returncode
    if EXPECTED not in result.stdout:
        print("FAIL: 13c did not print %r" % EXPECTED)
        return 1
    print("RESULT: inventory-security files=1 pass=15 fail=0")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
