-- ============================================================================
-- 13c_inventory_security_regression.sql — C 域 v1.0 提交后回归（成员 C；2026-11-03）
-- 运行时机：run_migration.sql COMMIT 并写入 SchemaVersion('v1.0') 之后。
-- 依赖：11a/11b/11c/12 已完成；baseline_c.sql 的同批快照；08/09c/09d 种子。
-- 断言：C 域账本/建议/采购/审计边界、Permission 白名单/映射/实际 GRANT、
--       A 四接口与 B 六查询的角色映射、cust_app 边界、身份上下文、签名。
-- 写法：对齐 13a/10c——每条自带回滚、错误号与消息都核对、RESULT 收尾并
--       校验分母；失败或分母不足均非零退出。不重写冻结的 v0.1 测试文件。
-- 断言码：51940（前置）、51941（断言失败）、51998（有失败）、51999（分母不足）。
-- ============================================================================

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

IF OBJECT_ID(N'tempdb..#counters') IS NOT NULL DROP TABLE #counters;
CREATE TABLE #counters (pass INT NOT NULL, fail INT NOT NULL);
INSERT INTO #counters (pass, fail) VALUES (0, 0);
GO

-- ---------------------------------------------------------------------------
-- 0. 前置：v1.0、批次、C 基线、目录与角色
-- ---------------------------------------------------------------------------
DECLARE @batch_id BIGINT = (SELECT sv.batch_id FROM dbo.SchemaVersion AS sv
                            WHERE sv.version_code = N'v1.0');
IF OBJECT_ID(N'dbo.SchemaVersion', N'U') IS NULL OR @batch_id IS NULL
    THROW 51940, N'13c：找不到 SchemaVersion(''v1.0'') 或其 batch_id。', 1;
IF NOT EXISTS (SELECT 1 FROM dbo.MigrationBatch AS b
               WHERE b.batch_id = @batch_id AND b.batch_status = 'COMPLETED')
    THROW 51940, N'13c：v1.0 指向的批次不是 COMPLETED。', 1;
IF OBJECT_ID(N'dbo.Baseline_RolePermission', N'U') IS NULL
   OR NOT EXISTS (SELECT 1 FROM dbo.Baseline_RolePermission WHERE batch_id = @batch_id)
    THROW 51940, N'13c：缺少同批 Baseline_RolePermission。', 1;
IF OBJECT_ID(N'dbo.Permission', N'U') IS NULL OR OBJECT_ID(N'dbo.RolePermission', N'U') IS NULL
    THROW 51940, N'13c：Permission/RolePermission 不存在，11c 未完成。', 1;
IF (SELECT COUNT(*) FROM dbo.BusinessRole WHERE status = N'ACTIVE'
      AND role_code IN (N'cashier', N'store_manager', N'packer', N'rider',
                        N'chef', N'waiter', N'shift_manager')) <> 7
    THROW 51940, N'13c：七个 ACTIVE 业务角色不齐。', 1;
GO

-- ---------------------------------------------------------------------------
-- 1. 目录数量与旧数据保真
-- ---------------------------------------------------------------------------
DECLARE @batch_id BIGINT = (SELECT sv.batch_id FROM dbo.SchemaVersion AS sv WHERE sv.version_code = N'v1.0');
DECLARE @new_codes TABLE (permission_code VARCHAR(50) PRIMARY KEY);
INSERT @new_codes VALUES
 (N'sp_list_orders_for_payment'), (N'sp_get_order_for_payment'),
 (N'sp_get_order_operation_status'), (N'sp_list_orders_for_packing'),
 (N'sp_list_my_deliveries'), (N'sp_list_deliveries_available_for_pickup'),
 (N'sp_get_current_employee_context'), (N'sp_list_master_records'),
 (N'sp_list_sale_products'), (N'sp_find_customer_for_order'),
 (N'sp_register_customer_for_order');
BEGIN TRY
    IF (SELECT COUNT(*) FROM dbo.Permission) <> 57
        THROW 51941, N'13c-1：Permission 不是 57 码。', 1;
    IF (SELECT COUNT(*) FROM dbo.RolePermission) <> 70
        THROW 51941, N'13c-1：RolePermission 不是 70 行。', 1;
    IF (SELECT COUNT(*) FROM dbo.Permission
        WHERE permission_code IN (SELECT permission_code FROM @new_codes)) <> 11
        THROW 51941, N'13c-1：新增 11 码未全部进入 Permission。', 1;
    UPDATE #counters SET pass = pass + 1;
    PRINT N'PASS: 13c-1 Permission 57 / RolePermission 70 / 新增码集合一致';
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK;
    UPDATE #counters SET fail = fail + 1;
    PRINT N'FAIL: 13c-1 ' + ERROR_MESSAGE();
END CATCH;
GO

-- 2. 旧 46 个名称保真（Permission ⋈ 基线，仅旧码）
DECLARE @batch_id BIGINT = (SELECT sv.batch_id FROM dbo.SchemaVersion AS sv WHERE sv.version_code = N'v1.0');
DECLARE @new_codes TABLE (permission_code VARCHAR(50) PRIMARY KEY);
INSERT @new_codes VALUES
 (N'sp_list_orders_for_payment'), (N'sp_get_order_for_payment'),
 (N'sp_get_order_operation_status'), (N'sp_list_orders_for_packing'),
 (N'sp_list_my_deliveries'), (N'sp_list_deliveries_available_for_pickup'),
 (N'sp_get_current_employee_context'), (N'sp_list_master_records'),
 (N'sp_list_sale_products'), (N'sp_find_customer_for_order'),
 (N'sp_register_customer_for_order');
BEGIN TRY
    IF EXISTS (
        SELECT DISTINCT permission_code, permission_name FROM dbo.Baseline_RolePermission
        WHERE batch_id = @batch_id AND permission_code NOT IN (SELECT permission_code FROM @new_codes)
        EXCEPT
        SELECT permission_code, permission_name FROM dbo.Permission
    ) OR EXISTS (
        SELECT permission_code, permission_name FROM dbo.Permission
        WHERE permission_code NOT IN (SELECT permission_code FROM @new_codes)
        EXCEPT
        SELECT DISTINCT permission_code, permission_name FROM dbo.Baseline_RolePermission
        WHERE batch_id = @batch_id
    )
        THROW 51941, N'13c-2：旧 46 码的名称未保真。', 1;
    UPDATE #counters SET pass = pass + 1;
    PRINT N'PASS: 13c-2 旧 46 码名称保真';
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK;
    UPDATE #counters SET fail = fail + 1;
    PRINT N'FAIL: 13c-2 ' + ERROR_MESSAGE();
END CATCH;
GO

-- 3. 旧 52 行（角色/码/状态）保真
DECLARE @batch_id BIGINT = (SELECT sv.batch_id FROM dbo.SchemaVersion AS sv WHERE sv.version_code = N'v1.0');
DECLARE @new_codes TABLE (permission_code VARCHAR(50) PRIMARY KEY);
INSERT @new_codes VALUES
 (N'sp_list_orders_for_payment'), (N'sp_get_order_for_payment'),
 (N'sp_get_order_operation_status'), (N'sp_list_orders_for_packing'),
 (N'sp_list_my_deliveries'), (N'sp_list_deliveries_available_for_pickup'),
 (N'sp_get_current_employee_context'), (N'sp_list_master_records'),
 (N'sp_list_sale_products'), (N'sp_find_customer_for_order'),
 (N'sp_register_customer_for_order');
BEGIN TRY
    IF EXISTS (
        SELECT business_role_id, permission_code, status FROM dbo.Baseline_RolePermission
        WHERE batch_id = @batch_id AND permission_code NOT IN (SELECT permission_code FROM @new_codes)
        EXCEPT
        SELECT business_role_id, permission_code, status FROM dbo.RolePermission
        WHERE permission_code NOT IN (SELECT permission_code FROM @new_codes)
    ) OR EXISTS (
        SELECT business_role_id, permission_code, status FROM dbo.RolePermission
        WHERE permission_code NOT IN (SELECT permission_code FROM @new_codes)
        EXCEPT
        SELECT business_role_id, permission_code, status FROM dbo.Baseline_RolePermission
        WHERE batch_id = @batch_id AND permission_code NOT IN (SELECT permission_code FROM @new_codes)
    )
        THROW 51941, N'13c-3：旧 52 行角色/码/状态未保真。', 1;
    UPDATE #counters SET pass = pass + 1;
    PRINT N'PASS: 13c-3 旧 52 行保真';
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK;
    UPDATE #counters SET fail = fail + 1;
    PRINT N'FAIL: 13c-3 ' + ERROR_MESSAGE();
END CATCH;
GO

-- 4. 新增 18 行：context 7、A 四、B 六
DECLARE @new_codes TABLE (permission_code VARCHAR(50) PRIMARY KEY);
INSERT @new_codes VALUES
 (N'sp_list_orders_for_payment'), (N'sp_get_order_for_payment'),
 (N'sp_get_order_operation_status'), (N'sp_list_orders_for_packing'),
 (N'sp_list_my_deliveries'), (N'sp_list_deliveries_available_for_pickup'),
 (N'sp_get_current_employee_context'), (N'sp_list_master_records'),
 (N'sp_list_sale_products'), (N'sp_find_customer_for_order'),
 (N'sp_register_customer_for_order');
BEGIN TRY
    IF (SELECT COUNT(*) FROM dbo.RolePermission WHERE permission_code IN (SELECT permission_code FROM @new_codes)) <> 18
        THROW 51941, N'13c-4：新增 RolePermission 不是 18 行。', 1;
    IF (SELECT COUNT(*) FROM dbo.RolePermission WHERE permission_code = N'sp_get_current_employee_context') <> 7
        THROW 51941, N'13c-4：身份上下文不是 7 个角色。', 1;
    IF (SELECT COUNT(*) FROM dbo.RolePermission WHERE permission_code IN
        (N'sp_list_master_records', N'sp_list_sale_products',
         N'sp_find_customer_for_order', N'sp_register_customer_for_order')) <> 4
        THROW 51941, N'13c-4：A 四接口角色映射不是 4 行。', 1;
    IF NOT EXISTS (SELECT 1 FROM dbo.RolePermission rp JOIN dbo.BusinessRole br
                   ON br.business_role_id = rp.business_role_id
                   WHERE rp.permission_code = N'sp_list_master_records' AND br.role_code = N'store_manager')
       OR (SELECT COUNT(*) FROM dbo.RolePermission rp JOIN dbo.BusinessRole br
                   ON br.business_role_id = rp.business_role_id
                   WHERE rp.permission_code IN (N'sp_list_sale_products',
                         N'sp_find_customer_for_order', N'sp_register_customer_for_order')
                     AND br.role_code = N'cashier') <> 3
        THROW 51941, N'13c-4：A 四接口角色映射与契约 §2.4.5 不符。', 1;
    UPDATE #counters SET pass = pass + 1;
    PRINT N'PASS: 13c-4 新增 18 行（context 7 / A 4 / B 6）';
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK;
    UPDATE #counters SET fail = fail + 1;
    PRINT N'FAIL: 13c-4 ' + ERROR_MESSAGE();
END CATCH;
GO

-- 5. 白名单 = 目录 = RolePermission 码集合
BEGIN TRY
    IF (SELECT COUNT(DISTINCT permission_code) FROM dbo.Permission) <> 57
        THROW 51941, N'13c-5：Permission 去重码不是 57。', 1;
    IF EXISTS (SELECT permission_code FROM dbo.Permission
               EXCEPT SELECT permission_code FROM dbo.RolePermission)
       OR EXISTS (SELECT permission_code FROM dbo.RolePermission
                  EXCEPT SELECT permission_code FROM dbo.Permission)
        THROW 51941, N'13c-5：白名单/目录/RolePermission 码集合不一致。', 1;
    UPDATE #counters SET pass = pass + 1;
    PRINT N'PASS: 13c-5 白名单 = Permission = RolePermission 码集合';
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK;
    UPDATE #counters SET fail = fail + 1;
    PRINT N'FAIL: 13c-5 ' + ERROR_MESSAGE();
END CATCH;
GO

-- 6. 实际 role_* GRANT 与 RolePermission 逐对相等
BEGIN TRY
    DECLARE @expected TABLE (role_name SYSNAME, object_name SYSNAME, permission_name SYSNAME);
    INSERT @expected (role_name, object_name, permission_name)
    SELECT N'role_' + br.role_code, rp.permission_code,
           CASE WHEN o.type = 'V' THEN N'SELECT' ELSE N'EXECUTE' END
    FROM dbo.RolePermission rp
    JOIN dbo.BusinessRole br ON br.business_role_id = rp.business_role_id AND br.status = N'ACTIVE'
    JOIN sys.objects o ON o.name = rp.permission_code AND o.schema_id = SCHEMA_ID(N'dbo')
    WHERE o.type IN ('P', 'V');
    IF (SELECT COUNT(*) FROM @expected) <> 70
        THROW 51941, N'13c-6：RolePermission 对应的期望 GRANT 不是 70 对。', 1;
    IF EXISTS (
        SELECT role_name, object_name, permission_name FROM @expected
        EXCEPT
        SELECT r.name COLLATE DATABASE_DEFAULT,
               OBJECT_NAME(dp.major_id) COLLATE DATABASE_DEFAULT,
               dp.permission_name COLLATE DATABASE_DEFAULT
        FROM sys.database_permissions dp
        JOIN sys.database_principals r ON r.principal_id = dp.grantee_principal_id
        WHERE r.name LIKE N'role[_]%' AND dp.class = 1 AND dp.state = 'G'
          AND dp.permission_name IN (N'EXECUTE', N'SELECT')
    ) OR EXISTS (
        SELECT r.name COLLATE DATABASE_DEFAULT,
               OBJECT_NAME(dp.major_id) COLLATE DATABASE_DEFAULT,
               dp.permission_name COLLATE DATABASE_DEFAULT
        FROM sys.database_permissions dp
        JOIN sys.database_principals r ON r.principal_id = dp.grantee_principal_id
        WHERE r.name LIKE N'role[_]%' AND dp.class = 1 AND dp.state = 'G'
          AND dp.permission_name IN (N'EXECUTE', N'SELECT')
        EXCEPT
        SELECT role_name, object_name, permission_name FROM @expected
    )
        THROW 51941, N'13c-6：实际 role_* GRANT 与 RolePermission 映射不相等。', 1;
    UPDATE #counters SET pass = pass + 1;
    PRINT N'PASS: 13c-6 70 对 role_* GRANT 与映射逐对相等';
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK;
    UPDATE #counters SET fail = fail + 1;
    PRINT N'FAIL: 13c-6 ' + ERROR_MESSAGE();
END CATCH;
GO

-- 7. cust_app：用户存在、只授三个顾客过程、不是角色成员
BEGIN TRY
    IF DATABASE_PRINCIPAL_ID(N'cust_app') IS NULL
        THROW 51941, N'13c-7：cust_app 用户不存在。', 1;
    IF EXISTS (SELECT 1 FROM sys.database_role_members drm
               JOIN sys.database_principals r ON r.principal_id = drm.role_principal_id
               WHERE drm.member_principal_id = DATABASE_PRINCIPAL_ID(N'cust_app'))
        THROW 51941, N'13c-7：cust_app 不应加入任何数据库角色。', 1;
    IF (SELECT COUNT(*) FROM sys.database_permissions
        WHERE grantee_principal_id = DATABASE_PRINCIPAL_ID(N'cust_app')
          AND class = 1 AND state = 'G' AND permission_name = N'EXECUTE'
          AND major_id IN (OBJECT_ID(N'dbo.sp_customer_register'),
                           OBJECT_ID(N'dbo.sp_customer_place_order'),
                           OBJECT_ID(N'dbo.sp_customer_list_orders'))) <> 3
        THROW 51941, N'13c-7：cust_app 的三个顾客过程 EXECUTE 未齐。', 1;
    IF EXISTS (SELECT 1 FROM sys.database_permissions
               WHERE grantee_principal_id = DATABASE_PRINCIPAL_ID(N'cust_app')
                 AND class = 1 AND state = 'G'
                 AND major_id NOT IN (OBJECT_ID(N'dbo.sp_customer_register'),
                                      OBJECT_ID(N'dbo.sp_customer_place_order'),
                                      OBJECT_ID(N'dbo.sp_customer_list_orders')))
        THROW 51941, N'13c-7：cust_app 持有三个顾客过程以外的对象权限。', 1;
    UPDATE #counters SET pass = pass + 1;
    PRINT N'PASS: 13c-7 cust_app 仅三个顾客过程、无角色成员';
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK;
    UPDATE #counters SET fail = fail + 1;
    PRINT N'FAIL: 13c-7 ' + ERROR_MESSAGE();
END CATCH;
GO

-- 8. cust_app 调员工过程/基表均 229
DECLARE @impersonating BIT = 0, @e_proc INT = NULL, @e_table INT = NULL;
DECLARE @ctx_now DATETIME2(0) = SYSDATETIME();
BEGIN TRANSACTION;
BEGIN TRY
    EXECUTE AS USER = N'cust_app';
    SET @impersonating = 1;
    BEGIN TRY
        EXEC dbo.sp_create_order @customer_id = 1, @fulfillment_method = 'PICKUP',
             @order_no = '13C-CUSTAPP', @items_json = N'[]', @ordered_at = @ctx_now;
    END TRY
    BEGIN CATCH
        SET @e_proc = ERROR_NUMBER();
    END CATCH;
    BEGIN TRY
        SELECT COUNT(*) FROM dbo.Inventory;
    END TRY
    BEGIN CATCH
        SET @e_table = ERROR_NUMBER();
    END CATCH;
END TRY
BEGIN CATCH
    SET @e_proc = ERROR_NUMBER();
END CATCH;
-- H16: 229 + XACT_ABORT marks the transaction uncommittable; ROLLBACK before REVERT.
IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
IF @impersonating = 1 BEGIN REVERT; SET @impersonating = 0; END;
BEGIN TRY
    IF @e_proc IS NULL OR @e_proc <> 229 OR @e_table IS NULL OR @e_table <> 229
    BEGIN
        PRINT N'DEBUG 13c-8 e_proc=' + ISNULL(CONVERT(NVARCHAR(20), @e_proc), N'NULL')
            + N' e_table=' + ISNULL(CONVERT(NVARCHAR(20), @e_table), N'NULL');
        THROW 51941, N'13c-8：cust_app 调员工过程/基表未同时返回 229。', 1;
    END;
    UPDATE #counters SET pass = pass + 1;
    PRINT N'PASS: 13c-8 cust_app 直调员工过程/基表均 229';
END TRY
BEGIN CATCH
    UPDATE #counters SET fail = fail + 1;
    PRINT N'FAIL: 13c-8 ' + ERROR_MESSAGE();
END CATCH;
GO

-- 9. dbo 调身份上下文 51004；test_cashier 正例无错
DECLARE @e_ctx INT = NULL;
BEGIN TRY
    EXEC dbo.sp_get_current_employee_context;
END TRY
BEGIN CATCH
    SET @e_ctx = ERROR_NUMBER();
END CATCH;
BEGIN TRY
    IF @e_ctx IS NULL OR @e_ctx <> 51004
        THROW 51941, N'13c-9：dbo 调身份上下文未返回 51004。', 1;
    BEGIN TRANSACTION;
    EXECUTE AS USER = N'test_cashier';
    EXEC dbo.sp_get_current_employee_context;
    REVERT;
    ROLLBACK TRANSACTION;
    UPDATE #counters SET pass = pass + 1;
    PRINT N'PASS: 13c-9 身份上下文 51004 + test_cashier 三结果集正例';
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK;
    IF USER_NAME() <> N'dbo' REVERT;
    UPDATE #counters SET fail = fail + 1;
    PRINT N'FAIL: 13c-9 ' + ERROR_MESSAGE();
END CATCH;
GO

-- 10. PurchaseOrder 建议单唯一（2627/2601）
DECLARE @sug_id BIGINT = (SELECT TOP (1) replenishment_suggestion_id FROM dbo.PurchaseOrder ORDER BY purchase_order_id);
IF @sug_id IS NULL THROW 51940, N'13c-10：没有采购单夹具。', 1;
DECLARE @dup_err INT = NULL, @dup_msg NVARCHAR(2048) = NULL;
BEGIN TRANSACTION;
BEGIN TRY
    INSERT INTO dbo.PurchaseOrder (purchase_order_no, replenishment_suggestion_id, purchase_status)
    VALUES ('13C-DUP-PO', @sug_id, 'APPROVED');
END TRY
BEGIN CATCH
    SET @dup_err = ERROR_NUMBER();
    SET @dup_msg = ERROR_MESSAGE();
END CATCH;
IF XACT_STATE() = -1 ROLLBACK TRANSACTION;
IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
BEGIN TRY
    IF @dup_err IS NULL OR @dup_err NOT IN (2601, 2627)
        THROW 51941, N'13c-10：重复建议单未被 2601/2627 拒绝。', 1;
    IF @dup_msg NOT LIKE N'%UQ_PurchaseOrder_replenishment_suggestion_id%'
        THROW 51941, N'13c-10：重复建议单报错但约束名不对。', 1;
    UPDATE #counters SET pass = pass + 1;
    PRINT N'PASS: 13c-10 同建议单第二张采购单被唯一约束拒绝';
END TRY
BEGIN CATCH
    UPDATE #counters SET fail = fail + 1;
    PRINT N'FAIL: 13c-10 ' + ERROR_MESSAGE();
END CATCH;
GO

-- 11. C 域账本不变量（T3 同口径）
BEGIN TRY
    IF EXISTS (SELECT 1 FROM dbo.Inventory WHERE on_hand_qty < 0 OR locked_qty < 0)
        THROW 51941, N'13c-11：存在负库存。', 1;
    IF EXISTS (SELECT 1 FROM dbo.Inventory inv
               WHERE inv.locked_qty <> ISNULL((SELECT SUM(m.locked_delta) FROM dbo.InventoryMovement m
                                               WHERE m.ingredient_id = inv.ingredient_id), 0))
        THROW 51941, N'13c-11：locked_qty 与流水不勾稽。', 1;
    IF EXISTS (SELECT 1 FROM dbo.Inventory inv
               JOIN dbo.Ingredient i ON i.ingredient_id = inv.ingredient_id
               WHERE inv.on_hand_qty <>
                    (CASE WHEN inv.ingredient_id IN (1, 5) THEN i.safety_stock_qty
                          ELSE CAST(i.safety_stock_qty * 10 AS DECIMAL(12,3)) END)
                    + ISNULL((SELECT SUM(m.on_hand_delta) FROM dbo.InventoryMovement m
                              WHERE m.ingredient_id = inv.ingredient_id), 0))
        THROW 51941, N'13c-11：on_hand_qty 与期初+流水不勾稽。', 1;
    UPDATE #counters SET pass = pass + 1;
    PRINT N'PASS: 13c-11 库存非负、锁定/现有量双向勾稽';
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK;
    UPDATE #counters SET fail = fail + 1;
    PRINT N'FAIL: 13c-11 ' + ERROR_MESSAGE();
END CATCH;
GO

-- 12. 开放建议唯一 / 采购单恰好一条明细
BEGIN TRY
    IF EXISTS (SELECT 1 FROM dbo.ReplenishmentSuggestion
               WHERE suggestion_status IN ('PENDING', 'SUBMITTED', 'APPROVED')
               GROUP BY ingredient_id HAVING COUNT(*) > 1)
        THROW 51941, N'13c-12：同一原料存在多张开放建议。', 1;
    IF EXISTS (SELECT 1 FROM dbo.PurchaseOrder po
               WHERE (SELECT COUNT(*) FROM dbo.PurchaseOrderItem poi
                      WHERE poi.purchase_order_id = po.purchase_order_id) <> 1)
        THROW 51941, N'13c-12：采购单不是恰好一条明细。', 1;
    UPDATE #counters SET pass = pass + 1;
    PRINT N'PASS: 13c-12 开放建议唯一、采购单恰好一条明细';
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK;
    UPDATE #counters SET fail = fail + 1;
    PRINT N'FAIL: 13c-12 ' + ERROR_MESSAGE();
END CATCH;
GO

-- 13. 身份上下文与角色同步签名
BEGIN TRY
    IF (SELECT COUNT(*) FROM sys.crypt_properties cp
        WHERE cp.class = 1 AND cp.major_id IN
          (OBJECT_ID(N'dbo.sp_assign_employee_business_role'),
           OBJECT_ID(N'dbo.sp_revoke_employee_business_role'),
           OBJECT_ID(N'dbo.sp_update_employee_status'))) <> 3
        THROW 51941, N'13c-13：角色同步过程签名不是 3 条。', 1;
    UPDATE #counters SET pass = pass + 1;
    PRINT N'PASS: 13c-13 三个角色同步过程各一条签名';
END TRY
BEGIN CATCH
    UPDATE #counters SET fail = fail + 1;
    PRINT N'FAIL: 13c-13 ' + ERROR_MESSAGE();
END CATCH;
GO

-- 14. C 域四个视图的 SET 选项
BEGIN TRY
    IF (SELECT COUNT(*) FROM sys.sql_modules m
        JOIN sys.objects o ON o.object_id = m.object_id
        WHERE o.schema_id = SCHEMA_ID(N'dbo') AND o.type = 'V'
          AND o.name IN (N'v_inventory_available', N'v_inventory_movement_history',
                         N'v_replenishment_dashboard', N'v_order_inventory_trace')
          AND m.uses_quoted_identifier = 1 AND m.uses_ansi_nulls = 1) <> 4
        THROW 51941, N'13c-14：C 域四个视图的 SET 选项不齐。', 1;
    UPDATE #counters SET pass = pass + 1;
    PRINT N'PASS: 13c-14 C 域四视图 QUOTED_IDENTIFIER/ANSI_NULLS 均为 ON';
END TRY
BEGIN CATCH
    UPDATE #counters SET fail = fail + 1;
    PRINT N'FAIL: 13c-14 ' + ERROR_MESSAGE();
END CATCH;
GO

-- 收尾
DECLARE @pass INT = (SELECT pass FROM #counters);
DECLARE @fail INT = (SELECT fail FROM #counters);
PRINT N'RESULT: pass=' + CONVERT(NVARCHAR(10), @pass) + N' fail=' + CONVERT(NVARCHAR(10), @fail);
IF @pass + @fail <> 14
    THROW 51999, N'13c：断言计数不足 14，说明有批次静默作废。', 1;
IF @fail > 0
    THROW 51998, N'13c：存在失败断言。', 1;
GO
