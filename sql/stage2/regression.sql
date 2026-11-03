-- ============================================================================
-- regression.sql — v1.0 域回归汇总入口（成员 C；2026-11-03）
-- 运行时机：run_migration.sql COMMIT 后；在 KFC_DB 上按序执行 13a/13b/13c。
-- 用法（仓库根目录）：
--   sqlcmd -S '.\SQLEXPRESS' -E -C -f 65001 -b -I -i sql/stage2/regression.sql
-- 说明：各域文件自己打印 RESULT 并校验分母；本入口只负责顺序、会话 SET 与
--       总预期数。任一文件失败（THROW/分母不足）都会被 :on error exit 截断，
--       不会继续跑后面的域。B 的 13b baseline 依赖 QUOTED_IDENTIFIER ON；
--       这里显式设置，避免调用者漏 -I。
-- ============================================================================
:on error exit
USE KFC_DB;
GO

SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET QUOTED_IDENTIFIER ON;
SET NUMERIC_ROUNDABORT OFF;
SET XACT_ABORT ON;
GO

PRINT N'=== regression: 13a master ===';
:r sql/stage2/13a_master_regression.sql

PRINT N'=== regression: 13b order baseline ===';
:r sql/stage2/13b_order_baseline_check.sql

PRINT N'=== regression: 13b order write contract ===';
:r sql/stage2/13b_order_write_contract_check.sql

PRINT N'=== regression: 13c inventory security ===';
:r sql/stage2/13c_inventory_security_regression.sql

PRINT N'RESULT: regression files=4 expected_pass=37 fail=0 (13a 10 + 13b 5 + 13b 8 + 13c 14)';
GO
