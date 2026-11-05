-- ============================================================================
-- 12_permissions.sql — v1.0 授权重建与角色同步过程重签（成员 C；2026-11-03）
-- 由 run_migration.sql 在 11a -> 11b -> 11c 之后、外层事务内 :r 执行：
-- 不得 BEGIN/COMMIT/ROLLBACK 外层事务、不得切连接；失败由入口回滚并 THROW。
-- 依据：计划 §5.1、§7.1；migration-guide.md §5/§5.1/§7；
--       application-contract.md §1.5/§2.4.5；OI-10/OI-13。
-- 本文件只做授权/签名/核对，不改 11c 的约束与目录种子。
-- ============================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

-- ---------------------------------------------------------------------------
-- 1. 前置：v1.0 目录/角色/对象齐备（缺 11b 对象时明确失败，不静默跳过）
-- ---------------------------------------------------------------------------
SET NOCOUNT ON;
SET XACT_ABORT ON;
IF OBJECT_ID(N'dbo.Permission', N'U') IS NULL
   OR OBJECT_ID(N'dbo.RolePermission', N'U') IS NULL
    THROW 53400, N'12: Permission/RolePermission is missing; run 11c first.', 1;
IF (SELECT COUNT(*) FROM dbo.Permission) <> 58
    THROW 53401, N'12: Permission must contain 58 v1.0 codes.', 1;
IF (SELECT COUNT(*) FROM dbo.RolePermission) <> 71
    THROW 53402, N'12: RolePermission must contain 71 v1.0 rows.', 1;
IF (SELECT COUNT(*) FROM dbo.BusinessRole WHERE status = N'ACTIVE'
      AND role_code IN (N'cashier', N'store_manager', N'packer', N'rider',
                        N'chef', N'waiter', N'shift_manager')) <> 7
    THROW 53403, N'12: the seven active business roles are required.', 1;

DECLARE @missing NVARCHAR(400) = N'';
SELECT @missing = @missing + CASE WHEN @missing = N'' THEN N'' ELSE N', ' END + name
FROM (VALUES
    (N'sp_list_master_records'), (N'sp_list_sale_products'),
    (N'sp_find_customer_for_order'), (N'sp_register_customer_for_order'),
    (N'sp_list_orders_for_payment'), (N'sp_get_order_for_payment'),
    (N'sp_get_order_operation_status'), (N'sp_list_orders_for_packing'),
    (N'sp_list_my_deliveries'), (N'sp_list_deliveries_available_for_pickup'),
    (N'sp_get_current_employee_context'), (N'sp_list_employee_roles')
) AS x(name)
WHERE OBJECT_ID(N'dbo.' + name, N'P') IS NULL;
IF @missing <> N''
BEGIN
    DECLARE @missing_msg NVARCHAR(400) =
        N'12: required v1.0 procedures are missing (11a/11b/11c incomplete): ' + @missing;
    THROW 53404, @missing_msg, 1;
END;
GO

-- ---------------------------------------------------------------------------
-- 2. 员工侧授权：只授 v1.0 新增的 19 对（旧 52 对由 08 保留）
-- ---------------------------------------------------------------------------
SET NOCOUNT ON;
SET XACT_ABORT ON;

GRANT EXECUTE ON dbo.sp_list_master_records          TO role_store_manager;

GRANT EXECUTE ON dbo.sp_list_sale_products           TO role_cashier;
GRANT EXECUTE ON dbo.sp_find_customer_for_order      TO role_cashier;
GRANT EXECUTE ON dbo.sp_register_customer_for_order  TO role_cashier;

GRANT EXECUTE ON dbo.sp_list_orders_for_payment      TO role_cashier;
GRANT EXECUTE ON dbo.sp_get_order_for_payment        TO role_cashier;
GRANT EXECUTE ON dbo.sp_get_order_operation_status   TO role_cashier;
GRANT EXECUTE ON dbo.sp_get_order_operation_status   TO role_store_manager;
GRANT EXECUTE ON dbo.sp_list_orders_for_packing      TO role_packer;
GRANT EXECUTE ON dbo.sp_list_my_deliveries           TO role_rider;
GRANT EXECUTE ON dbo.sp_list_deliveries_available_for_pickup TO role_rider;

GRANT EXECUTE ON dbo.sp_get_current_employee_context TO role_chef;
GRANT EXECUTE ON dbo.sp_get_current_employee_context TO role_cashier;
GRANT EXECUTE ON dbo.sp_get_current_employee_context TO role_packer;
GRANT EXECUTE ON dbo.sp_get_current_employee_context TO role_rider;
GRANT EXECUTE ON dbo.sp_get_current_employee_context TO role_waiter;
GRANT EXECUTE ON dbo.sp_get_current_employee_context TO role_shift_manager;
GRANT EXECUTE ON dbo.sp_get_current_employee_context TO role_store_manager;
GRANT EXECUTE ON dbo.sp_list_employee_roles TO role_store_manager;
GO

-- ---------------------------------------------------------------------------
-- 3. cust_app：WITHOUT LOGIN；三个顾客过程存在才授（13c 会断言缺失）
-- ---------------------------------------------------------------------------
SET NOCOUNT ON;
SET XACT_ABORT ON;
IF DATABASE_PRINCIPAL_ID(N'cust_app') IS NULL
    CREATE USER cust_app WITHOUT LOGIN;

IF OBJECT_ID(N'dbo.sp_customer_register', N'P') IS NOT NULL
   AND OBJECT_ID(N'dbo.sp_customer_place_order', N'P') IS NOT NULL
   AND OBJECT_ID(N'dbo.sp_customer_list_orders', N'P') IS NOT NULL
BEGIN
    GRANT EXECUTE ON dbo.sp_customer_register     TO cust_app;
    GRANT EXECUTE ON dbo.sp_customer_place_order  TO cust_app;
    GRANT EXECUTE ON dbo.sp_customer_list_orders  TO cust_app;
    PRINT N'12: cust_app grants applied (3 customer procedures).';
END
ELSE
    PRINT N'12: WARNING: customer procedures absent; cust_app grants skipped (13c must fail until OI-10 delivery).';
GO

-- ---------------------------------------------------------------------------
-- 4. 角色同步过程重签：证书存在；先移除本证书旧签名再重签（成功路径不省略）
-- ---------------------------------------------------------------------------
SET NOCOUNT ON;
SET XACT_ABORT ON;
DECLARE @cert_thumbprint VARBINARY(32) =
    (SELECT c.thumbprint FROM sys.certificates AS c WHERE c.name = N'cert_role_sync');
IF @cert_thumbprint IS NULL
    THROW 53405, N'12: cert_role_sync is missing; run 08 first.', 1;

IF EXISTS (SELECT 1 FROM sys.crypt_properties AS cp
           WHERE cp.class = 1
             AND cp.major_id IN (OBJECT_ID(N'dbo.sp_assign_employee_business_role'),
                                 OBJECT_ID(N'dbo.sp_revoke_employee_business_role'),
                                 OBJECT_ID(N'dbo.sp_update_employee_status'))
             AND cp.thumbprint <> @cert_thumbprint)
    THROW 53406, N'12: a role-sync procedure is signed by a different certificate.', 1;

IF EXISTS (SELECT 1 FROM sys.crypt_properties AS cp
           WHERE cp.class = 1 AND cp.thumbprint = @cert_thumbprint
             AND cp.major_id = OBJECT_ID(N'dbo.sp_assign_employee_business_role'))
    DROP SIGNATURE FROM dbo.sp_assign_employee_business_role BY CERTIFICATE cert_role_sync;
ADD SIGNATURE TO dbo.sp_assign_employee_business_role BY CERTIFICATE cert_role_sync;

IF EXISTS (SELECT 1 FROM sys.crypt_properties AS cp
           WHERE cp.class = 1 AND cp.thumbprint = @cert_thumbprint
             AND cp.major_id = OBJECT_ID(N'dbo.sp_revoke_employee_business_role'))
    DROP SIGNATURE FROM dbo.sp_revoke_employee_business_role BY CERTIFICATE cert_role_sync;
ADD SIGNATURE TO dbo.sp_revoke_employee_business_role BY CERTIFICATE cert_role_sync;

IF EXISTS (SELECT 1 FROM sys.crypt_properties AS cp
           WHERE cp.class = 1 AND cp.thumbprint = @cert_thumbprint
             AND cp.major_id = OBJECT_ID(N'dbo.sp_update_employee_status'))
    DROP SIGNATURE FROM dbo.sp_update_employee_status BY CERTIFICATE cert_role_sync;
ADD SIGNATURE TO dbo.sp_update_employee_status BY CERTIFICATE cert_role_sync;
GO

-- ---------------------------------------------------------------------------
-- 5. 授权核对：新增 19 对实际 GRANT 全在位；重签仍为 3 条
-- ---------------------------------------------------------------------------
SET NOCOUNT ON;
SET XACT_ABORT ON;
DECLARE @expected TABLE (role_name SYSNAME NOT NULL, object_name SYSNAME NOT NULL);
INSERT @expected (role_name, object_name) VALUES
    (N'role_store_manager', N'sp_list_master_records'),
    (N'role_cashier', N'sp_list_sale_products'),
    (N'role_cashier', N'sp_find_customer_for_order'),
    (N'role_cashier', N'sp_register_customer_for_order'),
    (N'role_cashier', N'sp_list_orders_for_payment'),
    (N'role_cashier', N'sp_get_order_for_payment'),
    (N'role_cashier', N'sp_get_order_operation_status'),
    (N'role_store_manager', N'sp_get_order_operation_status'),
    (N'role_packer', N'sp_list_orders_for_packing'),
    (N'role_rider', N'sp_list_my_deliveries'),
    (N'role_rider', N'sp_list_deliveries_available_for_pickup'),
    (N'role_chef', N'sp_get_current_employee_context'),
    (N'role_cashier', N'sp_get_current_employee_context'),
    (N'role_packer', N'sp_get_current_employee_context'),
    (N'role_rider', N'sp_get_current_employee_context'),
    (N'role_waiter', N'sp_get_current_employee_context'),
    (N'role_shift_manager', N'sp_get_current_employee_context'),
    (N'role_store_manager', N'sp_get_current_employee_context'),
    (N'role_store_manager', N'sp_list_employee_roles');

IF EXISTS (
    SELECT e.role_name, e.object_name
    FROM @expected AS e
    EXCEPT
    SELECT r.name, OBJECT_NAME(dp.major_id)
    FROM sys.database_permissions AS dp
    JOIN sys.database_principals AS r ON r.principal_id = dp.grantee_principal_id
    WHERE r.name LIKE N'role[_]%'
      AND dp.state = 'G'
      AND dp.permission_name = N'EXECUTE'
)
    THROW 53407, N'12: an expected v1.0 employee-side GRANT is missing.', 1;

IF (SELECT COUNT(*) FROM sys.crypt_properties WHERE class = 1 AND major_id IN
    (OBJECT_ID(N'dbo.sp_assign_employee_business_role'),
     OBJECT_ID(N'dbo.sp_revoke_employee_business_role'),
     OBJECT_ID(N'dbo.sp_update_employee_status'))) <> 3
    THROW 53408, N'12: role-sync signatures are not exactly 3 after re-sign.', 1;

PRINT N'12: employee grants, cust_app, and role-sync signatures verified.';
GO
