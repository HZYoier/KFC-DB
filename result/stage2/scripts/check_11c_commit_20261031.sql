-- 11c commit test: preserve old RolePermission, run 11c in outer txn, commit, verify.
USE KFC_DB;
SET NOCOUNT ON;
SET XACT_ABORT ON;

-- old 52 rows + old names (before migration)
SELECT business_role_id, permission_code, permission_name, status INTO #old_rp FROM dbo.RolePermission;
IF (SELECT COUNT(*) FROM #old_rp) <> 52 THROW 53320, N'old snapshot != 52', 1;

BEGIN TRANSACTION;
:r D:\DBLab\KFC-DB\sql\stage2\11c_inventory_security_migration.sql
COMMIT TRANSACTION;

-- final shapes
IF (SELECT COUNT(*) FROM dbo.Permission) <> 53 THROW 53321, N'Permission != 53', 1;
IF (SELECT COUNT(*) FROM dbo.RolePermission) <> 66 THROW 53322, N'RolePermission != 66', 1;
IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'dbo.RolePermission') AND name = N'permission_name')
    THROW 53323, N'permission_name still present', 1;
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_Permission_permission_code')
    THROW 53324, N'new CHECK missing', 1;
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_RolePermission_permission_code')
    THROW 53325, N'old CHECK still present', 1;
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = N'FK_RolePermission_Permission')
    THROW 53326, N'FK missing', 1;
IF NOT EXISTS (SELECT 1 FROM sys.key_constraints WHERE name = N'UQ_PurchaseOrder_replenishment_suggestion_id')
    THROW 53327, N'UQ missing', 1;
IF (SELECT COUNT(*) FROM sys.crypt_properties WHERE class = 1 AND major_id IN
    (OBJECT_ID(N'dbo.sp_assign_employee_business_role'), OBJECT_ID(N'dbo.sp_revoke_employee_business_role'),
     OBJECT_ID(N'dbo.sp_update_employee_status'))) <> 3
    THROW 53328, N'signatures changed', 1;

-- old 52 rows preserved (role, code, status)
IF EXISTS (
    SELECT business_role_id, permission_code, status FROM #old_rp
    EXCEPT
    SELECT business_role_id, permission_code, status FROM dbo.RolePermission
) OR EXISTS (
    SELECT business_role_id, permission_code, status FROM dbo.RolePermission
    WHERE permission_code NOT IN (N'sp_list_orders_for_payment', N'sp_get_order_for_payment',
        N'sp_get_order_operation_status', N'sp_list_orders_for_packing', N'sp_list_my_deliveries',
        N'sp_list_deliveries_available_for_pickup', N'sp_get_current_employee_context')
    EXCEPT
    SELECT business_role_id, permission_code, status FROM #old_rp
)
    THROW 53329, N'old 52 rows not preserved', 1;

-- old names preserved via Permission join
IF EXISTS (
    SELECT DISTINCT o.permission_code, o.permission_name FROM #old_rp o
    EXCEPT
    SELECT p.permission_code, p.permission_name FROM dbo.Permission p
) OR EXISTS (
    SELECT p.permission_code, p.permission_name FROM dbo.Permission p
    WHERE p.permission_code NOT IN (N'sp_list_orders_for_payment', N'sp_get_order_for_payment',
        N'sp_get_order_operation_status', N'sp_list_orders_for_packing', N'sp_list_my_deliveries',
        N'sp_list_deliveries_available_for_pickup', N'sp_get_current_employee_context')
    EXCEPT
    SELECT DISTINCT o.permission_code, o.permission_name FROM #old_rp o
)
    THROW 53330, N'old permission names not preserved', 1;

-- exactly 14 new RolePermission rows / 7 context grants
IF (SELECT COUNT(*) FROM dbo.RolePermission WHERE permission_code IN
    (N'sp_list_orders_for_payment', N'sp_get_order_for_payment', N'sp_get_order_operation_status',
     N'sp_list_orders_for_packing', N'sp_list_my_deliveries', N'sp_list_deliveries_available_for_pickup',
     N'sp_get_current_employee_context')) <> 14
    THROW 53331, N'new RolePermission rows != 14', 1;
IF (SELECT COUNT(*) FROM dbo.RolePermission WHERE permission_code = N'sp_get_current_employee_context') <> 7
    THROW 53332, N'context grants != 7 roles', 1;

-- context proc: dbo/unknown -> 51004
DECLARE @err INT = NULL;
BEGIN TRY
    EXEC dbo.sp_get_current_employee_context;
END TRY
BEGIN CATCH
    SET @err = ERROR_NUMBER();
END CATCH;
IF @err IS NULL OR @err <> 51004 THROW 53333, N'context dbo rejection != 51004', 1;

-- positive context as test_cashier (test fixture grant; 12 will grant all 7)
GRANT EXECUTE ON dbo.sp_get_current_employee_context TO role_cashier;
EXECUTE AS USER = N'test_cashier';
PRINT '--- context as test_cashier (3 result sets follow) ---';
EXEC dbo.sp_get_current_employee_context;
REVERT;
REVOKE EXECUTE ON dbo.sp_get_current_employee_context FROM role_cashier;
PRINT 'PASS: 11c commit shape + old rows/names + signatures + context rejection/positive';
