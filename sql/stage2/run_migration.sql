-- ============================================================================
-- run_migration.sql — v0.1 -> v1.0 迁移入口（成员 C；2026-11-03）
-- 前置：已部署 v0.1，capture_baseline.sql 已产生 COMPLETED 批次，应用已停写。
-- 用法（仓库根目录；-b 遇错退出，-I 保证 13b 的 QUOTED_IDENTIFIER 要求）：
--   sqlcmd -S '.\SQLEXPRESS' -E -C -f 65001 -b -I -i sql/stage2/run_migration.sql
-- 顺序：预检 -> 11a -> 11b -> 11c -> 12 -> 事务内检查 -> v1.0 标记 -> COMMIT。
-- 域脚本不得 COMMIT 外层事务；任何失败由 sqlcmd 退出、会话关闭时回滚。
-- 不创建/删除数据库；不恢复备份；不配置服务器登录。
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
-- 1. 预检：版本、摘要、批次、25 张快照的现场行数、应用锁
-- ---------------------------------------------------------------------------
DECLARE @batch_id BIGINT, @schema_digest CHAR(64), @lock_rc INT;
IF OBJECT_ID(N'dbo.SchemaVersion', N'U') IS NULL
   OR OBJECT_ID(N'dbo.MigrationBatch', N'U') IS NULL
    THROW 53500, N'run_migration: migration metadata is missing; run capture_baseline.sql first.', 1;
IF EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE version_code = N'v1.0')
    THROW 53501, N'run_migration: database is already marked v1.0.', 1;
SELECT @batch_id = sv.batch_id, @schema_digest = sv.object_digest
FROM dbo.SchemaVersion AS sv WHERE sv.version_code = N'v0.1';
IF @batch_id IS NULL
    THROW 53502, N'run_migration: SchemaVersion v0.1 is missing.', 1;
IF NOT EXISTS (SELECT 1 FROM dbo.MigrationBatch
               WHERE batch_id = @batch_id AND batch_status = 'COMPLETED')
    THROW 53503, N'run_migration: v0.1 must point to a COMPLETED batch.', 1;
IF OBJECT_ID(N'dbo.fn_stage2_schema_digest', N'FN') IS NULL
    THROW 53504, N'run_migration: fn_stage2_schema_digest is missing.', 1;
IF @schema_digest <> dbo.fn_stage2_schema_digest()
    THROW 53505, N'run_migration: live schema digest differs from the captured v0.1 digest.', 1;
IF (SELECT COUNT(*) FROM dbo.MigrationBaseline WHERE batch_id = @batch_id) <> 25
    THROW 53506, N'run_migration: the v0.1 batch must contain 25 baseline tables.', 1;

DECLARE @tbl SYSNAME, @snap SYSNAME, @live BIGINT, @meta BIGINT, @sql NVARCHAR(MAX);
DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT table_name, snapshot_table FROM dbo.MigrationBaseline
    WHERE batch_id = @batch_id ORDER BY table_name;
OPEN cur;
FETCH NEXT FROM cur INTO @tbl, @snap;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF OBJECT_ID(N'dbo.' + @snap, N'U') IS NULL
        THROW 53507, N'run_migration: a baseline snapshot table is missing.', 1;
    SET @sql = N'SELECT @c = COUNT_BIG(*) FROM dbo.' + QUOTENAME(@snap) + N' WHERE batch_id = @b;';
    EXEC sys.sp_executesql @sql, N'@b BIGINT, @c BIGINT OUTPUT', @batch_id, @meta OUTPUT;
    SET @sql = N'SELECT @c = COUNT_BIG(*) FROM dbo.' + QUOTENAME(@tbl) + N';';
    EXEC sys.sp_executesql @sql, N'@c BIGINT OUTPUT', @live OUTPUT;
    IF @meta <> @live
        THROW 53508, N'run_migration: baseline row count differs from the live table (drift).', 1;
    FETCH NEXT FROM cur INTO @tbl, @snap;
END
CLOSE cur;
DEALLOCATE cur;

EXEC @lock_rc = sys.sp_getapplock @Resource = N'KFC_DB.Stage2Migration',
    @LockMode = 'Exclusive', @LockOwner = 'Session', @LockTimeout = 0;
IF @lock_rc < 0
    THROW 53509, N'run_migration: migration lock is held by another session.', 1;
GO

-- ---------------------------------------------------------------------------
-- 2. 外层事务：固定顺序 11a -> 11b -> 11c -> 12
-- ---------------------------------------------------------------------------
SET NOCOUNT ON;
SET XACT_ABORT ON;
BEGIN TRANSACTION;
:r sql/stage2/11a_master_migration.sql
:r sql/stage2/11b_order_migration.sql
:r sql/stage2/11c_inventory_security_migration.sql
:r sql/stage2/12_permissions.sql

-- ---------------------------------------------------------------------------
-- 3. 事务内只读检查（不运行 13a/13b/13c 的反例）
-- ---------------------------------------------------------------------------
DECLARE @batch_id BIGINT = (SELECT sv.batch_id FROM dbo.SchemaVersion AS sv
                            WHERE sv.version_code = N'v0.1');
IF @batch_id IS NULL
    THROW 53516, N'run_migration: v0.1 batch_id disappeared before the v1.0 marker.', 1;
IF (SELECT COUNT(*) FROM dbo.Permission) <> 57
    THROW 53510, N'run_migration: Permission != 57 after 11c.', 1;
IF (SELECT COUNT(*) FROM dbo.RolePermission) <> 70
    THROW 53511, N'run_migration: RolePermission != 70 after 11c.', 1;
IF (SELECT COUNT(*) FROM sys.key_constraints WHERE name IN
    (N'UQ_MemberLevel_threshold_points', N'UQ_Category_category_name',
     N'UQ_Product_product_name', N'UQ_Ingredient_name_unit',
     N'UQ_MemberLevel_level_name', N'UQ_PurchaseOrder_replenishment_suggestion_id')) <> 6
    THROW 53512, N'run_migration: expected six v1.0 candidate-key constraints.', 1;
IF (SELECT COUNT(*) FROM sys.procedures
    WHERE schema_id = SCHEMA_ID(N'dbo') AND name IN
      (N'sp_list_master_records', N'sp_list_sale_products',
       N'sp_find_customer_for_order', N'sp_register_customer_for_order',
       N'sp_list_orders_for_payment', N'sp_get_order_for_payment',
       N'sp_get_order_operation_status', N'sp_list_orders_for_packing',
       N'sp_list_my_deliveries', N'sp_list_deliveries_available_for_pickup',
       N'sp_get_current_employee_context')) <> 11
    THROW 53513, N'run_migration: expected eleven v1.0 procedures.', 1;
IF (SELECT COUNT(*) FROM sys.crypt_properties WHERE class = 1 AND major_id IN
    (OBJECT_ID(N'dbo.sp_assign_employee_business_role'),
     OBJECT_ID(N'dbo.sp_revoke_employee_business_role'),
     OBJECT_ID(N'dbo.sp_update_employee_status'))) <> 3
    THROW 53514, N'run_migration: role-sync signatures are not three.', 1;
IF DATABASE_PRINCIPAL_ID(N'cust_app') IS NULL
    THROW 53515, N'run_migration: cust_app was not created by 12.', 1;

-- v1.0 标记只能由本入口在全部检查通过后写入
INSERT INTO dbo.SchemaVersion (version_code, object_digest, batch_id, applied_at, note)
VALUES (N'v1.0', dbo.fn_stage2_schema_digest(), @batch_id, SYSDATETIME(),
        N'run_migration 11a-11b-11c-12');
COMMIT TRANSACTION;
GO

-- ---------------------------------------------------------------------------
-- 4. 收尾：释放会话锁（连接结束也会释放）
-- ---------------------------------------------------------------------------
DECLARE @lock_rc INT;
EXEC @lock_rc = sys.sp_releaseapplock @Resource = N'KFC_DB.Stage2Migration', @LockOwner = 'Session';
PRINT N'RESULT: migration committed (v1.0 marker written; 11a/11b/11c/12).';
GO
