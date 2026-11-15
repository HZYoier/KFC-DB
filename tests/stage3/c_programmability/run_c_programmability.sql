-- ============================================================================
-- run_c_programmability.sql — C 域第三阶段 3.1 测试入口（成员 C；2026-11-15）
-- 前置：KFC_DB 已部署 v0.1，并已按顺序执行：
--       sql/stage3/20_schema_v1_1.sql
--       sql/stage3/21c_inventory_programmability.sql
-- 运行（仓库根目录）：
--   sqlcmd -S '.\SQLEXPRESS' -E -C -f 65001 -b -d KFC_DB -i tests/stage3/c_programmability/run_c_programmability.sql
-- 三套分母：结构 14、补货量 10、库存调整 15；任一文件 THROW 即整体失败。
-- ============================================================================
:on error exit
USE KFC_DB;
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

PRINT N'=== c-programmability: schema v1.1 ===';
:r tests/stage3/c_programmability/test_20_schema_v1_1.sql
GO

PRINT N'=== c-programmability: fn_replenishment_qty ===';
:r tests/stage3/c_programmability/test_21c_replenishment_qty.sql
GO

PRINT N'=== c-programmability: sp_adjust_inventory ===';
:r tests/stage3/c_programmability/test_21c_adjust_inventory.sql
GO

PRINT N'RESULT: c-programmability files=3 failed=0';
GO
