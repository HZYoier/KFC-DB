-- ============================================================================
-- run_c_triggers.sql — C 域第三阶段触发器测试入口（成员 C；2026-11-15）
-- 前置：KFC_DB 已部署 v0.1，并已执行 20_schema_v1_1.sql、22c_inventory_triggers.sql。
-- 运行（仓库根目录）：
--   sqlcmd -S '.\SQLEXPRESS' -E -C -f 65001 -b -d KFC_DB -i tests/stage3/c_triggers/run_c_triggers.sql
-- 分母：库存审计 10。
-- ============================================================================
:on error exit
USE KFC_DB;
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

PRINT N'=== c-triggers: InventoryAudit ===';
:r tests/stage3/c_triggers/test_22c_inventory_audit.sql
GO

PRINT N'RESULT: c-triggers files=1 failed=0';
GO
