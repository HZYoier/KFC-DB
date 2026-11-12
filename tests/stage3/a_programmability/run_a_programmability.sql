-- ============================================================================
-- run_a_programmability.sql — A 域第三阶段可编程对象测试入口
-- 运行（仓库根目录）：
--   sqlcmd -S localhost -E -C -f 65001 -b -d KFC_DB -i tests/stage3/a_programmability/run_a_programmability.sql
-- 任一测试 THROW 或 sqlcmd 返回非零即整体失败；两套分母分别为 27 与 15。
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

PRINT N'RESULT: a-programmability files=2 failed=0';
GO
