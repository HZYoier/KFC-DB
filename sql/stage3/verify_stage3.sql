-- 第三阶段合并验收骨架。仓库根目录以 sqlcmd -b -C -f 65001 -I -i 运行。
-- 前置：run_stage3.sql 已提交 v1.1，以及三域真实验收夹具。
-- 28b 到货前 :r 会报缺文件。仅验 C 增量时，独立运行 28c。
:on error exit
USE KFC_DB;
GO
SET NOCOUNT ON;
GO

IF OBJECT_ID(N'dbo.SchemaVersion', N'U') IS NULL
    THROW 54430, N'verify_stage3: SchemaVersion is missing.', 1;
GO
IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE version_code = N'v1.1')
    THROW 54431, N'verify_stage3: v1.1 marker is missing; run run_stage3.sql first.', 1;
GO

:r sql/stage3/28a_stage3_regression.sql
GO
:r sql/stage3/28b_stage3_regression.sql
GO
:r sql/stage3/28c_stage3_regression.sql
GO

-- 分母汇总待 28b 冻结后补齐；三域各自输出 RESULT 并在失败时中止。
PRINT N'verify_stage3: completed 28a/28b/28c; see individual RESULT lines.';
GO
