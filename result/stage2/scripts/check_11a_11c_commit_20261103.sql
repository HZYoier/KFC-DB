-- Partial migration drill: real 11a -> 11c, commit, v1.0 marker, then A/B post-migration checks.
-- B's 11b and C's 12/13c are not part of this drill; this is explicitly a partial path.
USE KFC_DB;
SET NOCOUNT ON;
SET XACT_ABORT ON;

IF EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE version_code = N'v1.0')
    THROW 53360, N'drill precondition: v1.0 already exists', 1;
IF (SELECT COUNT(*) FROM dbo.RolePermission) <> 52
    THROW 53361, N'drill precondition: RolePermission != 52', 1;

BEGIN TRANSACTION;
:r D:\DBLab\KFC-DB\sql\stage2\11a_master_migration.sql
:r D:\DBLab\KFC-DB\sql\stage2\11c_inventory_security_migration.sql

IF (SELECT COUNT(*) FROM dbo.Permission) <> 57
    THROW 53362, N'Permission != 57 before commit', 1;
IF (SELECT COUNT(*) FROM dbo.RolePermission) <> 70
    THROW 53363, N'RolePermission != 70 before commit', 1;
IF (SELECT COUNT(*) FROM sys.crypt_properties WHERE class = 1 AND major_id IN
    (OBJECT_ID(N'dbo.sp_assign_employee_business_role'), OBJECT_ID(N'dbo.sp_revoke_employee_business_role'),
     OBJECT_ID(N'dbo.sp_update_employee_status'))) <> 3
    THROW 53364, N'signatures changed before commit', 1;

DECLARE @batch_id BIGINT = (SELECT batch_id FROM dbo.SchemaVersion WHERE version_code = N'v0.1');
IF @batch_id IS NULL
    THROW 53365, N'v0.1 batch missing', 1;
INSERT INTO dbo.SchemaVersion (version_code, object_digest, batch_id, applied_at, note)
VALUES (N'v1.0', dbo.fn_stage2_schema_digest(), @batch_id, SYSDATETIME(),
        N'partial drill 11a+11c (11b/12/13c not run)');
COMMIT TRANSACTION;

IF (SELECT COUNT(*) FROM dbo.Permission) = 57
   AND (SELECT COUNT(*) FROM dbo.RolePermission) = 70
   AND (SELECT COUNT(*) FROM sys.key_constraints WHERE name IN
        (N'UQ_MemberLevel_threshold_points', N'UQ_Category_category_name',
         N'UQ_Product_product_name', N'UQ_Ingredient_name_unit',
         N'UQ_MemberLevel_level_name', N'UQ_PurchaseOrder_replenishment_suggestion_id')) = 6
    PRINT N'PASS: partial v1.0 shape (57/70, six UQs)';
ELSE
    THROW 53366, N'partial v1.0 shape check failed', 1;

-- dbo/unknown context rejection is now safe: no outer transaction is open.
DECLARE @err INT = NULL;
BEGIN TRY
    EXEC dbo.sp_get_current_employee_context;
END TRY
BEGIN CATCH
    SET @err = ERROR_NUMBER();
END CATCH;
IF @err = 51004
    PRINT N'PASS: context dbo rejection = 51004';
ELSE
    THROW 53367, N'context dbo rejection != 51004', 1;

PRINT N'RESULT: partial-migration pass=2 fail=0';
