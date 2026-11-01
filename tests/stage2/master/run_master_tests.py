"""A 主数据域测试入口：不连库，直接把 ODBC 连接换成假的。

跑法（仓库根目录）：
    .venv\\Scripts\\python tests\\stage2\\master\\run_master_tests.py

分母硬编码并当场核对：用例被误删、被改名漏发现，都算失败而不是「少跑几条还绿」。
有 skip 也判失败——没跑到的断言不算通过（与 B 的入口同口径）。
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

EXPECTED = 36


def main() -> int:
    here = Path(__file__).resolve().parent
    root = here.parents[2]
    sys.path.insert(0, str(root))
    suite = unittest.defaultTestLoader.discover(str(here), pattern="test_*.py")
    if suite.countTestCases() != EXPECTED:
        print("FAIL 用例分母：期望 %d，实际发现 %d" % (EXPECTED, suite.countTestCases()))
        return 1
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    failed = len(result.failures) + len(result.errors)
    print(
        "RESULT: pass=%d fail=%d skip=%d total=%d"
        % (result.testsRun - failed - len(result.skipped), failed, len(result.skipped), result.testsRun)
    )
    ok = result.wasSuccessful() and not result.skipped and result.testsRun == EXPECTED
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
