-- ============================================================================
-- run_stage3.sql — v1.0 -> v1.1 增量入口（成员 C；2026-11-15 骨架）
-- 前置：v1.0 已由 run_migration.sql 提交；应用已停写；schema 目录中
--       21b/22b/27 等文件到齐。当前仓库 21b/22b/27 尚未交付时，本入口会
--       在 :r 处报文件不存在并随连接关闭整体回滚——这是有意的“未就绪”状态。
-- 用法（仓库根目录；-b 遇错退出；CRLF/UTF-8）：
--   sqlcmd -S '.\SQLEXPRESS' -E -C -f 65001 -b -I -i sql/stage3/run_stage3.sql
-- 顺序：预检 -> 20 -> 21b -> 21a -> 21c -> 22b -> 22c -> 27 -> 事务内检查
--       -> SchemaVersion('v1.1') -> COMMIT。
-- 约束：不建库/删库/删表/重写存量行；每个域脚本不得自行 COMMIT/ROLLBACK。
-- 依据：docs/stage3/three-person-implementation-plan.md §8.3；sales-semantics F-01—F-04。
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

-- ---------------------------------------------------------------------------
-- 1. 预检：v1.0 标记、v1.1 未应用、应用锁
-- ---------------------------------------------------------------------------
DECLARE @batch_id BIGINT, @lock_rc INT;

IF OBJECT_ID(N'dbo.SchemaVersion', N'U') IS NULL
    THROW 54400, N'run_stage3: SchemaVersion is missing; run capture_baseline/run_migration first.', 1;

IF EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE version_code = N'v1.1')
    THROW 54401, N'run_stage3: database is already marked v1.1; do not apply the increment twice.', 1;

SELECT @batch_id = sv.batch_id
FROM dbo.SchemaVersion AS sv
WHERE sv.version_code = N'v1.0';

IF @batch_id IS NULL
    THROW 54402, N'run_stage3: SchemaVersion v1.0 is missing; run run_migration.sql first.', 1;

EXEC @lock_rc = sys.sp_getapplock @Resource = N'KFC_DB.Stage3Migration',
    @LockMode = 'Exclusive', @LockOwner = 'Session', @LockTimeout = 0;
IF @lock_rc < 0
    THROW 54403, N'run_stage3: another session holds the Stage 3 migration lock.', 1;
GO

-- ---------------------------------------------------------------------------
-- 2. 外层事务：固定顺序 20 -> 21b -> 21a -> 21c -> 22b -> 22c -> 27
--    21b 必须早于 21a：内联表值函数创建时会解析 v_settled_sales_line。
-- ---------------------------------------------------------------------------
SET NOCOUNT ON;
SET XACT_ABORT ON;
BEGIN TRANSACTION;
:r sql/stage3/20_schema_v1_1.sql
:r sql/stage3/21b_order_programmability.sql
:r sql/stage3/21a_master_programmability.sql
:r sql/stage3/21c_inventory_programmability.sql
:r sql/stage3/22b_order_triggers.sql
:r sql/stage3/22c_inventory_triggers.sql
:r sql/stage3/27_permissions.sql

-- ---------------------------------------------------------------------------
-- 3. 事务内只读检查：对象、列、权限计数、触发器
-- ---------------------------------------------------------------------------
DECLARE @missing NVARCHAR(400) = N'';
SELECT @missing = @missing + CASE WHEN @missing = N'' THEN N'' ELSE N', ' END + expected.name
FROM (VALUES
    (N'v_settled_sales_line'),
    (N'sp_sales_report'),
    (N'fn_calculate_discount'),
    (N'fn_product_sales_summary'),
    (N'fn_replenishment_qty'),
    (N'tr_SalesOrder_Complete_Check'),
    (N'tr_Inventory_Audit')
) AS expected(name)
WHERE OBJECT_ID(N'dbo.' + expected.name, N'P') IS NULL
  AND OBJECT_ID(N'dbo.' + expected.name, N'V') IS NULL
  AND OBJECT_ID(N'dbo.' + expected.name, N'FN') IS NULL
  AND OBJECT_ID(N'dbo.' + expected.name, N'IF') IS NULL
  AND OBJECT_ID(N'dbo.' + expected.name, N'TR') IS NULL;

IF @missing <> N''
    THROW 54404, N'run_stage3: required v1.1 objects are missing after domain scripts: ' + @missing, 1;

IF OBJECT_ID(N'dbo.InventoryAudit', N'U') IS NULL
    THROW 54405, N'run_stage3: InventoryAudit is missing.', 1;

IF COL_LENGTH(N'dbo.SalesOrderItem', N'discount_rate') IS NULL
   OR COL_LENGTH(N'dbo.SalesOrderItem', N'discount_amount') IS NULL
    THROW 54406, N'run_stage3: SalesOrderItem discount columns are missing.', 1;

IF (SELECT COUNT(*) FROM dbo.Permission) <> 70
    THROW 54407, N'run_stage3: Permission must contain 70 codes after 27 (v1.0 58 + 12).', 1;
IF (SELECT COUNT(*) FROM dbo.RolePermission) <> 90
    THROW 54408, N'run_stage3: RolePermission must contain 90 rows after 27 (v1.0 71 + 19).', 1;

IF (SELECT COUNT(*) FROM sys.triggers
    WHERE parent_id = OBJECT_ID(N'dbo.Inventory')
      AND name = N'tr_Inventory_Audit') <> 1
    THROW 54409, N'run_stage3: tr_Inventory_Audit is not attached to Inventory.', 1;

IF (SELECT COUNT(*) FROM sys.triggers
    WHERE parent_id = OBJECT_ID(N'dbo.SalesOrder')
      AND name = N'tr_SalesOrder_Complete_Check') <> 1
    THROW 54410, N'run_stage3: tr_SalesOrder_Complete_Check is not attached to SalesOrder.', 1;

DECLARE @v10_batch BIGINT =
    (SELECT sv.batch_id FROM dbo.SchemaVersion AS sv WHERE sv.version_code = N'v1.0');
IF @v10_batch IS NULL
    THROW 54411, N'run_stage3: v1.0 batch id disappeared before the v1.1 marker.', 1;

INSERT INTO dbo.SchemaVersion (version_code, object_digest, batch_id, applied_at, note)
VALUES (N'v1.1', dbo.fn_stage2_schema_digest(), @v10_batch, SYSDATETIME(),
        N'run_stage3 20-21b-21a-21c-22b-22c-27');
COMMIT TRANSACTION;
GO

-- ---------------------------------------------------------------------------
-- 4. 收尾：释放会话锁
-- ---------------------------------------------------------------------------
DECLARE @lock_rc INT;
EXEC @lock_rc = sys.sp_releaseapplock @Resource = N'KFC_DB.Stage3Migration', @LockOwner = 'Session';
PRINT N'RESULT: stage3 migration committed (v1.1 marker written; 20/21b/21a/21c/22b/22c/27).';
GO
