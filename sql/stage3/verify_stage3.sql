-- 第三阶段三域合并验收。仓库根目录以 sqlcmd -b -C -f 65001 -I -i 运行。
-- 前置：run_stage3.sql 已提交 v1.1，以及三域真实验收夹具。
-- 仅验 C 增量时，独立运行 28c。
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

-- 三域各自检查固定分母并在失败时退出。仅在全部通过后汇总。
PRINT N'RESULT: stage3-regression suites=10 pass=123 fail=0 (28a 52 + 28b 8 + 28c 63)';
GO
