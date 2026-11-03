-- 11c extension rollback drill: 11a -> 11c on a real v0.1 database, then rollback.
-- A's four procedures are now included in the Permission whitelist (57 codes / 70 rows).
USE KFC_DB;
SET NOCOUNT ON;
SET XACT_ABORT ON;

SELECT business_role_id, permission_code, permission_name, status
INTO #old_rp
FROM dbo.RolePermission;
IF (SELECT COUNT(*) FROM #old_rp) <> 52 THROW 53340, N'pre-drill RolePermission != 52', 1;

BEGIN TRANSACTION;
:r D:\DBLab\KFC-DB\sql\stage2\11a_master_migration.sql
:r D:\DBLab\KFC-DB\sql\stage2\11c_inventory_security_migration.sql

DECLARE @pass INT = 0;
IF (SELECT COUNT(*) FROM dbo.Permission) = 57 SET @pass += 1;
ELSE THROW 53341, N'Permission != 57 inside txn', 1;
IF (SELECT COUNT(*) FROM dbo.RolePermission) = 70 SET @pass += 1;
ELSE THROW 53342, N'RolePermission != 70 inside txn', 1;

IF (SELECT COUNT(*) FROM dbo.Permission WHERE permission_code IN
    (N'sp_list_master_records', N'sp_list_sale_products',
     N'sp_find_customer_for_order', N'sp_register_customer_for_order')) = 4
    SET @pass += 1;
ELSE THROW 53343, N'A interface codes missing from Permission', 1;

IF (SELECT COUNT(*) FROM dbo.RolePermission WHERE
       (permission_code = N'sp_list_master_records' AND business_role_id =
            (SELECT business_role_id FROM dbo.BusinessRole WHERE role_code = N'store_manager'))
    OR (permission_code = N'sp_list_sale_products' AND business_role_id =
            (SELECT business_role_id FROM dbo.BusinessRole WHERE role_code = N'cashier'))
    OR (permission_code = N'sp_find_customer_for_order' AND business_role_id =
            (SELECT business_role_id FROM dbo.BusinessRole WHERE role_code = N'cashier'))
    OR (permission_code = N'sp_register_customer_for_order' AND business_role_id =
            (SELECT business_role_id FROM dbo.BusinessRole WHERE role_code = N'cashier'))) = 4
    SET @pass += 1;
ELSE THROW 53344, N'A interface role mappings are wrong', 1;

IF (SELECT COUNT(*) FROM dbo.RolePermission WHERE permission_code IN
    (N'sp_list_orders_for_payment', N'sp_get_order_for_payment',
     N'sp_get_order_operation_status', N'sp_list_orders_for_packing',
     N'sp_list_my_deliveries', N'sp_list_deliveries_available_for_pickup',
     N'sp_get_current_employee_context', N'sp_list_master_records',
     N'sp_list_sale_products', N'sp_find_customer_for_order',
     N'sp_register_customer_for_order')) = 18
    SET @pass += 1;
ELSE THROW 53345, N'new RolePermission rows != 18', 1;

IF (SELECT COUNT(*) FROM dbo.RolePermission WHERE permission_code = N'sp_get_current_employee_context') = 7
    SET @pass += 1;
ELSE THROW 53346, N'context grants != 7 roles', 1;

-- old 52 rows preserved
IF NOT EXISTS (
    SELECT business_role_id, permission_code, status FROM #old_rp
    EXCEPT
    SELECT business_role_id, permission_code, status FROM dbo.RolePermission
    WHERE permission_code NOT IN
        (N'sp_list_orders_for_payment', N'sp_get_order_for_payment',
         N'sp_get_order_operation_status', N'sp_list_orders_for_packing',
         N'sp_list_my_deliveries', N'sp_list_deliveries_available_for_pickup',
         N'sp_get_current_employee_context', N'sp_list_master_records',
         N'sp_list_sale_products', N'sp_find_customer_for_order',
         N'sp_register_customer_for_order')
)
AND NOT EXISTS (
    SELECT business_role_id, permission_code, status FROM dbo.RolePermission
    WHERE permission_code NOT IN
        (N'sp_list_orders_for_payment', N'sp_get_order_for_payment',
         N'sp_get_order_operation_status', N'sp_list_orders_for_packing',
         N'sp_list_my_deliveries', N'sp_list_deliveries_available_for_pickup',
         N'sp_get_current_employee_context', N'sp_list_master_records',
         N'sp_list_sale_products', N'sp_find_customer_for_order',
         N'sp_register_customer_for_order')
    EXCEPT
    SELECT business_role_id, permission_code, status FROM #old_rp
)
    SET @pass += 1;
ELSE THROW 53347, N'old 52 RolePermission rows are not preserved', 1;

-- old names preserved via Permission
IF NOT EXISTS (
    SELECT DISTINCT o.permission_code, o.permission_name FROM #old_rp o
    EXCEPT
    SELECT p.permission_code, p.permission_name FROM dbo.Permission p
    WHERE p.permission_code NOT IN
        (N'sp_list_orders_for_payment', N'sp_get_order_for_payment',
         N'sp_get_order_operation_status', N'sp_list_orders_for_packing',
         N'sp_list_my_deliveries', N'sp_list_deliveries_available_for_pickup',
         N'sp_get_current_employee_context', N'sp_list_master_records',
         N'sp_list_sale_products', N'sp_find_customer_for_order',
         N'sp_register_customer_for_order')
)
AND NOT EXISTS (
    SELECT p.permission_code, p.permission_name FROM dbo.Permission p
    WHERE p.permission_code NOT IN
        (N'sp_list_orders_for_payment', N'sp_get_order_for_payment',
         N'sp_get_order_operation_status', N'sp_list_orders_for_packing',
         N'sp_list_my_deliveries', N'sp_list_deliveries_available_for_pickup',
         N'sp_get_current_employee_context', N'sp_list_master_records',
         N'sp_list_sale_products', N'sp_find_customer_for_order',
         N'sp_register_customer_for_order')
    EXCEPT
    SELECT DISTINCT o.permission_code, o.permission_name FROM #old_rp o
)
    SET @pass += 1;
ELSE THROW 53348, N'old permission names are not preserved', 1;

-- 11a objects inside the transaction
IF (SELECT COUNT(*) FROM sys.key_constraints WHERE name IN
    (N'UQ_MemberLevel_threshold_points', N'UQ_Category_category_name',
     N'UQ_Product_product_name', N'UQ_Ingredient_name_unit',
     N'UQ_MemberLevel_level_name')) = 5
    SET @pass += 1;
ELSE THROW 53349, N'11a UQ constraints missing inside txn', 1;
IF OBJECT_ID(N'dbo.sp_list_master_records', N'P') IS NOT NULL
   AND OBJECT_ID(N'dbo.sp_list_sale_products', N'P') IS NOT NULL
   AND OBJECT_ID(N'dbo.sp_find_customer_for_order', N'P') IS NOT NULL
   AND OBJECT_ID(N'dbo.sp_register_customer_for_order', N'P') IS NOT NULL
    SET @pass += 1;
ELSE THROW 53350, N'11a procedures missing inside txn', 1;

-- signatures and context rejection
IF (SELECT COUNT(*) FROM sys.crypt_properties WHERE class = 1 AND major_id IN
    (OBJECT_ID(N'dbo.sp_assign_employee_business_role'), OBJECT_ID(N'dbo.sp_revoke_employee_business_role'),
     OBJECT_ID(N'dbo.sp_update_employee_status'))) = 3
    SET @pass += 1;
ELSE THROW 53351, N'signatures changed inside txn', 1;

-- The dbo/unknown rejection (51004) is deliberately tested outside this outer
-- transaction: THROW + XACT_ABORT would make the transaction uncommittable (H16).
-- Positive context as test_cashier (grant is rolled back with the outer transaction).
GRANT EXECUTE ON dbo.sp_get_current_employee_context TO role_cashier;
EXECUTE AS USER = N'test_cashier';
EXEC dbo.sp_get_current_employee_context;
REVERT;
REVOKE EXECUTE ON dbo.sp_get_current_employee_context FROM role_cashier;
SET @pass += 1;

ROLLBACK TRANSACTION;

-- v0.1 restored
IF OBJECT_ID(N'dbo.Permission', N'U') IS NULL SET @pass += 1;
ELSE THROW 53353, N'Permission survived rollback', 1;
IF (SELECT COUNT(*) FROM dbo.RolePermission) = 52 SET @pass += 1;
ELSE THROW 53354, N'RolePermission not restored to 52', 1;
IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'dbo.RolePermission') AND name = N'permission_name')
    SET @pass += 1;
ELSE THROW 53355, N'permission_name not restored', 1;
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_RolePermission_permission_code')
    SET @pass += 1;
ELSE THROW 53356, N'old CHECK not restored', 1;
IF OBJECT_ID(N'dbo.sp_get_current_employee_context', N'P') IS NULL
   AND OBJECT_ID(N'dbo.sp_list_master_records', N'P') IS NULL
   AND OBJECT_ID(N'dbo.sp_list_sale_products', N'P') IS NULL
   AND OBJECT_ID(N'dbo.sp_find_customer_for_order', N'P') IS NULL
   AND OBJECT_ID(N'dbo.sp_register_customer_for_order', N'P') IS NULL
    SET @pass += 1;
ELSE THROW 53357, N'new procedures survived rollback', 1;
IF NOT EXISTS (SELECT 1 FROM sys.key_constraints WHERE name = N'UQ_PurchaseOrder_replenishment_suggestion_id')
   AND NOT EXISTS (SELECT 1 FROM sys.key_constraints WHERE name = N'UQ_Category_category_name')
    SET @pass += 1;
ELSE THROW 53358, N'new UQ survived rollback', 1;

PRINT N'RESULT: pass=' + CONVERT(NVARCHAR(10), @pass) + N' fail=0';
IF @pass <> 18 THROW 53359, N'unexpected pass count (expected 18)', 1;
