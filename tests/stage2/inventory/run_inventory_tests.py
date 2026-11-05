"""app.inventory 测试入口：不连库，分母硬编码并校验。"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

EXPECTED = 12


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
