-- 11c employee-role extension: 58 codes / 71 rows; rollback restores v0.1.
USE KFC_DB;
SET NOCOUNT ON;
SET XACT_ABORT ON;

SELECT business_role_id, permission_code, permission_name, status
INTO #old_rp
FROM dbo.RolePermission;
IF (SELECT COUNT(*) FROM #old_rp) <> 52 THROW 53370, N'pre-drill RolePermission != 52', 1;

BEGIN TRANSACTION;
:r D:\DBLab\KFC-DB\sql\stage2\11a_master_migration.sql
:r D:\DBLab\KFC-DB\sql\stage2\11c_inventory_security_migration.sql

DECLARE @pass INT = 0;
IF (SELECT COUNT(*) FROM dbo.Permission) = 58 SET @pass += 1;
ELSE THROW 53371, N'Permission != 58 inside txn', 1;
IF (SELECT COUNT(*) FROM dbo.RolePermission) = 71 SET @pass += 1;
ELSE THROW 53372, N'RolePermission != 71 inside txn', 1;
IF OBJECT_ID(N'dbo.sp_list_employee_roles', N'P') IS NOT NULL SET @pass += 1;
ELSE THROW 53373, N'employee-role procedure missing', 1;
IF (SELECT COUNT(*) FROM dbo.RolePermission WHERE permission_code = N'sp_list_employee_roles') = 1
   AND EXISTS (SELECT 1 FROM dbo.RolePermission rp
               JOIN dbo.BusinessRole br ON br.business_role_id = rp.business_role_id
               WHERE rp.permission_code = N'sp_list_employee_roles' AND br.role_code = N'store_manager')
    SET @pass += 1;
ELSE THROW 53374, N'employee-role store_manager mapping missing', 1;
IF (SELECT COUNT(*) FROM dbo.RolePermission WHERE permission_code IN
    (N'sp_list_orders_for_payment', N'sp_get_order_for_payment',
     N'sp_get_order_operation_status', N'sp_list_orders_for_packing',
     N'sp_list_my_deliveries', N'sp_list_deliveries_available_for_pickup',
     N'sp_get_current_employee_context', N'sp_list_employee_roles',
     N'sp_list_master_records', N'sp_list_sale_products',
     N'sp_find_customer_for_order', N'sp_register_customer_for_order')) = 19
    SET @pass += 1;
ELSE THROW 53375, N'new RolePermission rows != 19', 1;
IF NOT EXISTS (
    SELECT business_role_id, permission_code, status FROM #old_rp
    EXCEPT
    SELECT business_role_id, permission_code, status FROM dbo.RolePermission
    WHERE permission_code NOT IN
        (N'sp_list_orders_for_payment', N'sp_get_order_for_payment',
         N'sp_get_order_operation_status', N'sp_list_orders_for_packing',
         N'sp_list_my_deliveries', N'sp_list_deliveries_available_for_pickup',
         N'sp_get_current_employee_context', N'sp_list_employee_roles',
         N'sp_list_master_records', N'sp_list_sale_products',
         N'sp_find_customer_for_order', N'sp_register_customer_for_order')
)
AND NOT EXISTS (
    SELECT business_role_id, permission_code, status FROM dbo.RolePermission
    WHERE permission_code NOT IN
        (N'sp_list_orders_for_payment', N'sp_get_order_for_payment',
         N'sp_get_order_operation_status', N'sp_list_orders_for_packing',
         N'sp_list_my_deliveries', N'sp_list_deliveries_available_for_pickup',
         N'sp_get_current_employee_context', N'sp_list_employee_roles',
         N'sp_list_master_records', N'sp_list_sale_products',
         N'sp_find_customer_for_order', N'sp_register_customer_for_order')
    EXCEPT
    SELECT business_role_id, permission_code, status FROM #old_rp
)
    SET @pass += 1;
ELSE THROW 53376, N'old 52 rows not preserved', 1;

ROLLBACK TRANSACTION;
IF OBJECT_ID(N'dbo.Permission', N'U') IS NULL SET @pass += 1;
ELSE THROW 53377, N'Permission survived rollback', 1;
IF (SELECT COUNT(*) FROM dbo.RolePermission) = 52 SET @pass += 1;
ELSE THROW 53378, N'RolePermission not restored', 1;
IF OBJECT_ID(N'dbo.sp_list_employee_roles', N'P') IS NULL SET @pass += 1;
ELSE THROW 53379, N'employee-role proc survived rollback', 1;

PRINT N'RESULT: pass=' + CONVERT(NVARCHAR(10), @pass) + N' fail=0';
IF @pass <> 9 THROW 53380, N'unexpected pass count (expected 9)', 1;
