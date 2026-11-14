-- ============================================================================
-- run_a_programmability.sql — A 域第三阶段可编程对象测试入口
-- 运行（仓库根目录）：
--   sqlcmd -S localhost -E -C -f 65001 -b -d KFC_DB -i tests/stage3/a_programmability/run_a_programmability.sql
-- 任一测试 THROW 或 sqlcmd 返回非零即整体失败；三套分母分别为 27、15、10。
-- test_21a_sales_summary.sql 与 test_23a_windows.sql 依赖 B 的 v_settled_sales_line（21b）；
-- 视图未建时按前置失败处理，不是跳过。
-- ============================================================================
:on error exit
USE KFC_DB;
GO
SET NOCOUNT ON;
GO

:r tests/stage3/a_programmability/test_21a_discount.sql
GO
:r tests/stage3/a_programmability/test_21a_sales_summary.sql
GO
:r tests/stage3/a_programmability/test_23a_windows.sql
GO

PRINT N'RESULT: a-programmability files=3 failed=0';
GO
