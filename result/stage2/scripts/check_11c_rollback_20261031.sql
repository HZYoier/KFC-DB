-- 11c rollback test: run inside an outer transaction, then ROLLBACK.
USE KFC_DB;
SET NOCOUNT ON;
SET XACT_ABORT ON;
BEGIN TRANSACTION;
:r D:\DBLab\KFC-DB\sql\stage2\11c_inventory_security_migration.sql
-- inside transaction assertions
IF (SELECT COUNT(*) FROM dbo.Permission) <> 53 THROW 53301, N'permission count != 53 inside txn', 1;
IF (SELECT COUNT(*) FROM dbo.RolePermission) <> 66 THROW 53302, N'rolepermission count != 66 inside txn', 1;
IF OBJECT_ID(N'dbo.sp_get_current_employee_context', N'P') IS NULL THROW 53303, N'context proc missing inside txn', 1;
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = N'FK_RolePermission_Permission') THROW 53304, N'FK missing inside txn', 1;
IF NOT EXISTS (SELECT 1 FROM sys.key_constraints WHERE name = N'UQ_PurchaseOrder_replenishment_suggestion_id') THROW 53305, N'UQ missing inside txn', 1;
PRINT 'PASS: 11c inside outer transaction (53/66/proc/FK/UQ)';
ROLLBACK TRANSACTION;
-- after rollback: v0.1 restored
IF OBJECT_ID(N'dbo.Permission', N'U') IS NOT NULL THROW 53306, N'Permission survived rollback', 1;
IF (SELECT COUNT(*) FROM dbo.RolePermission) <> 52 THROW 53307, N'RolePermission not restored to 52', 1;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'dbo.RolePermission') AND name = N'permission_name')
    THROW 53308, N'permission_name not restored', 1;
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_RolePermission_permission_code')
    THROW 53309, N'old CHECK not restored', 1;
IF OBJECT_ID(N'dbo.sp_get_current_employee_context', N'P') IS NOT NULL THROW 53310, N'context proc survived rollback', 1;
IF EXISTS (SELECT 1 FROM sys.key_constraints WHERE name = N'UQ_PurchaseOrder_replenishment_suggestion_id')
    THROW 53311, N'UQ survived rollback', 1;
PRINT 'PASS: 11c rollback restored v0.1';
