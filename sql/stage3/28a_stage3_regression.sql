-- ============================================================================
-- 28a_stage3_regression.sql — A 域 v1.1 回归（成员 A）
-- 运行时机：run_stage3.sql 已提交 v1.1；B 的 v_settled_sales_line 已存在
-- 运行方式：仓库根目录
--   sqlcmd -S localhost -E -C -f 65001 -b -d KFC_DB -i sql/stage3/28a_stage3_regression.sql
-- 内容：21a 折扣 27 条 + 汇总 15 条 + 窗口 10 条；先查对象与列是否存在。
-- 分母：52；任一测试 THROW 或 sqlcmd 非零即失败。
-- 断言码：54110 对象缺失、54111 折扣列缺失、54112 v1.1 未应用。
-- ============================================================================
:on error exit
USE KFC_DB;
GO
SET NOCOUNT ON;
GO

IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE version_code = N'v1.1')
    THROW 54112, N'28a: v1.1 marker is missing; run run_stage3.sql first.', 1;
IF OBJECT_ID(N'dbo.v_settled_sales_line', N'V') IS NULL
    THROW 54110, N'28a: dbo.v_settled_sales_line is missing; B''s 21b is not applied.', 1;
IF OBJECT_ID(N'dbo.fn_calculate_discount', N'IF') IS NULL
   OR OBJECT_ID(N'dbo.fn_product_sales_summary', N'IF') IS NULL
    THROW 54110, N'28a: A functions are missing; run 21a_master_programmability.sql.', 1;
IF COL_LENGTH(N'dbo.SalesOrderItem', N'discount_rate') IS NULL
   OR COL_LENGTH(N'dbo.SalesOrderItem', N'discount_amount') IS NULL
    THROW 54111, N'28a: SalesOrderItem discount columns are missing; run 20_schema_v1_1.sql.', 1;
GO

:r tests/stage3/a_programmability/test_21a_discount.sql
GO
:r tests/stage3/a_programmability/test_21a_sales_summary.sql
GO
:r tests/stage3/a_programmability/test_23a_windows.sql
GO

PRINT N'RESULT: stage3-a-regression suites=3 pass=52 fail=0';
GO
