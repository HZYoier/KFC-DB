"""B's complete test entry. Explicit opt-in server; no skipped SQL tests reported as pass."""
import argparse
import os
from pathlib import Path
import sys
import unittest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sql-server', required=True, help='SQL Server for a uniquely owned disposable test DB; Windows authentication')
    options = parser.parse_args()
    os.environ['B_TEST_SQL_SERVER'] = options.sql_server
    root = Path(__file__).resolve().parents[3]
    sys.path.insert(0, str(root))
    suite = unittest.defaultTestLoader.discover(str(Path(__file__).parent), pattern='test_*.py')
    expected = 18
    if suite.countTestCases() != expected:
        print('FAIL test denominator: expected=%d discovered=%d' % (expected, suite.countTestCases()))
        return 1
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    failed = len(result.failures) + len(result.errors)
    print('RESULT: pass=%d fail=%d skip=%d total=%d' % (result.testsRun-failed-len(result.skipped), failed, len(result.skipped), result.testsRun))
    return 0 if result.wasSuccessful() and not result.skipped and result.testsRun == expected else 1


if __name__ == '__main__':
    raise SystemExit(main())
