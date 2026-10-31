-- ============================================================================
-- 11c_inventory_security_migration.sql — C 域 v0.1 -> v1.0 迁移（成员 C；2026-10-31）
-- 由 run_migration.sql 在外层事务内 :r 执行：不得 BEGIN/COMMIT/ROLLBACK 外层事务，
-- 不得切连接；失败由入口回滚外层并 THROW。
-- 落实：I-C12 Permission 拆分 + 白名单迁位/扩展（46 -> 53）；
--       I-C13 UQ_PurchaseOrder_replenishment_suggestion_id；
--       v1.0 新增 sp_get_current_employee_context（七个业务角色在 12 授权）。
-- 依据：docs/stage2/migration-guide.md §5/§5.1、refactoring-design.md §7、
--       application-contract.md §2.2、b-freeze-receipt.md §2。
-- ============================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

-- ---------------------------------------------------------------------------
-- 1. 前置校验（v0.1 形状 + 数据可无损拆分）
-- ---------------------------------------------------------------------------
SET NOCOUNT ON;
SET XACT_ABORT ON;
DECLARE @msg NVARCHAR(400);

IF OBJECT_ID(N'dbo.RolePermission', N'U') IS NULL OR OBJECT_ID(N'dbo.BusinessRole', N'U') IS NULL
   OR OBJECT_ID(N'dbo.PurchaseOrder', N'U') IS NULL
    THROW 53200, N'11c: v0.1 C-domain objects are missing.', 1;
IF OBJECT_ID(N'dbo.Permission', N'U') IS NOT NULL
    THROW 53201, N'11c: Permission already exists; 11c must run once on v0.1.', 1;
IF (SELECT COUNT(*) FROM dbo.RolePermission) <> 52
    THROW 53202, N'11c: RolePermission must contain the 52 v0.1 seed rows.', 1;
IF (SELECT COUNT(DISTINCT permission_code) FROM dbo.RolePermission) <> 46
    THROW 53203, N'11c: RolePermission must contain 46 distinct permission codes.', 1;
IF EXISTS (SELECT 1 FROM dbo.RolePermission GROUP BY permission_code HAVING COUNT(DISTINCT permission_name) > 1)
BEGIN
    SET @msg = N'11c: same permission_code has multiple names: '
             + ISNULL((SELECT STRING_AGG(CONVERT(NVARCHAR(MAX), permission_code), N',')
                              WITHIN GROUP (ORDER BY permission_code)
                       FROM (SELECT permission_code FROM dbo.RolePermission
                             GROUP BY permission_code HAVING COUNT(DISTINCT permission_name) > 1) x), N'');
    THROW 53204, @msg, 1;
END;
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints
               WHERE name = N'CK_RolePermission_permission_code'
                 AND parent_object_id = OBJECT_ID(N'dbo.RolePermission'))
    THROW 53205, N'11c: CK_RolePermission_permission_code is missing.', 1;
IF NOT EXISTS (SELECT 1 FROM sys.columns
               WHERE object_id = OBJECT_ID(N'dbo.RolePermission') AND name = N'permission_name')
    THROW 53206, N'11c: RolePermission.permission_name is missing.', 1;
IF (SELECT COUNT(*) FROM dbo.BusinessRole
    WHERE status = N'ACTIVE'
      AND role_code IN (N'cashier', N'store_manager', N'packer', N'rider', N'chef', N'waiter', N'shift_manager')) <> 7
    THROW 53207, N'11c: the seven active business roles are required.', 1;
GO

-- ---------------------------------------------------------------------------
-- 2. Permission 目录（固定枚举白名单 53 码；旧 46 + 新 7）
-- ---------------------------------------------------------------------------
SET NOCOUNT ON;
SET XACT_ABORT ON;
CREATE TABLE dbo.Permission (
    permission_code VARCHAR(50) NOT NULL,
    permission_name NVARCHAR(100) NOT NULL,
    CONSTRAINT PK_Permission PRIMARY KEY (permission_code),
    CONSTRAINT CK_Permission_permission_code CHECK (
        permission_code IN (
            -- v0.1 旧 46 码（原 CK_RolePermission_permission_code 全量迁入）
            'sp_create_category', 'sp_update_category_status',
            'sp_create_ingredient', 'sp_update_ingredient',
            'sp_create_product', 'sp_update_product_price', 'sp_update_product_status',
            'sp_set_product_bom', 'sp_set_combo_component',
            'sp_create_promotion', 'sp_update_promotion_status',
            'sp_add_promotion_product_rule', 'sp_update_promotion_product_rule',
            'sp_create_member_level', 'sp_update_member_level',
            'sp_update_member_level_status',
            'sp_create_customer', 'sp_update_customer_member_level',
            'sp_create_order', 'sp_pay_order', 'sp_start_production',
            'sp_finish_production', 'sp_pick_up_order', 'sp_pick_up_delivery',
            'sp_confirm_delivery', 'sp_cancel_or_refund_order',
            'sp_adjust_inventory', 'sp_create_replenishment_suggestion',
            'sp_update_replenishment_suggestion', 'sp_submit_replenishment_suggestion',
            'sp_approve_replenishment_suggestion', 'sp_reject_replenishment_suggestion',
            'sp_receive_inventory', 'sp_assign_employee_business_role',
            'sp_revoke_employee_business_role', 'sp_update_employee_status',
            'v_active_product_price', 'v_product_bom_detail',
            'v_order_detail', 'v_kitchen_queue', 'v_customer_point_ledger',
            'v_pickup_board', 'v_inventory_available',
            'v_inventory_movement_history', 'v_replenishment_dashboard',
            'v_order_inventory_trace',
            -- v1.0 新增 7 码（六个员工查询 + 身份上下文）
            'sp_list_orders_for_payment', 'sp_get_order_for_payment',
            'sp_get_order_operation_status', 'sp_list_orders_for_packing',
            'sp_list_my_deliveries', 'sp_list_deliveries_available_for_pickup',
            'sp_get_current_employee_context'
        )
    )
);
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
DECLARE @msg NVARCHAR(400);

-- 旧 46 码名称保真：同一码多名已在 §1 拒绝；这里再核对行数
INSERT INTO dbo.Permission (permission_code, permission_name)
SELECT permission_code, MIN(permission_name)
FROM dbo.RolePermission
GROUP BY permission_code;
IF (SELECT COUNT(*) FROM dbo.Permission) <> 46
    THROW 53208, N'11c: Permission seed from RolePermission must produce 46 rows.', 1;

INSERT INTO dbo.Permission (permission_code, permission_name) VALUES
    (N'sp_list_orders_for_payment',                 N'订单支付队列查询'),
    (N'sp_get_order_for_payment',                   N'订单支付详情查询'),
    (N'sp_get_order_operation_status',              N'订单操作状态查询'),
    (N'sp_list_orders_for_packing',                 N'配餐队列查询'),
    (N'sp_list_my_deliveries',                      N'我的配送单查询'),
    (N'sp_list_deliveries_available_for_pickup',    N'可认领配送单查询'),
    (N'sp_get_current_employee_context',            N'当前员工身份上下文');
IF (SELECT COUNT(*) FROM dbo.Permission) <> 53
    THROW 53209, N'11c: Permission must contain 53 codes after extension.', 1;

-- 迁移前确认旧授权行全部能连到目录
IF EXISTS (SELECT 1 FROM dbo.RolePermission rp
           WHERE NOT EXISTS (SELECT 1 FROM dbo.Permission p WHERE p.permission_code = rp.permission_code))
    THROW 53210, N'11c: a RolePermission code is missing from Permission.', 1;

-- 白名单 CHECK 迁位：删旧 CHECK，删名称列，加 FK，再写新角色映射
ALTER TABLE dbo.RolePermission DROP CONSTRAINT CK_RolePermission_permission_code;
ALTER TABLE dbo.RolePermission DROP COLUMN permission_name;
ALTER TABLE dbo.RolePermission WITH CHECK
    ADD CONSTRAINT FK_RolePermission_Permission
        FOREIGN KEY (permission_code) REFERENCES dbo.Permission(permission_code);

-- 14 条新角色映射（B 冻结回执 §2 + C 身份上下文；Roles 已确认 7 个 ACTIVE）
INSERT INTO dbo.RolePermission (business_role_id, permission_code, status)
SELECT br.business_role_id, s.permission_code, N'ACTIVE'
FROM (VALUES
    (N'cashier',        N'sp_list_orders_for_payment'),
    (N'cashier',        N'sp_get_order_for_payment'),
    (N'cashier',        N'sp_get_order_operation_status'),
    (N'store_manager',  N'sp_get_order_operation_status'),
    (N'packer',         N'sp_list_orders_for_packing'),
    (N'rider',          N'sp_list_my_deliveries'),
    (N'rider',          N'sp_list_deliveries_available_for_pickup'),
    (N'chef',           N'sp_get_current_employee_context'),
    (N'cashier',        N'sp_get_current_employee_context'),
    (N'packer',         N'sp_get_current_employee_context'),
    (N'rider',          N'sp_get_current_employee_context'),
    (N'waiter',         N'sp_get_current_employee_context'),
    (N'shift_manager',  N'sp_get_current_employee_context'),
    (N'store_manager',  N'sp_get_current_employee_context')
) AS s(role_code, permission_code)
JOIN dbo.BusinessRole br ON br.role_code = s.role_code AND br.status = N'ACTIVE';
IF (SELECT COUNT(*) FROM dbo.RolePermission) <> 66
    THROW 53211, N'11c: RolePermission must contain 52 + 14 = 66 rows.', 1;

-- I-C13：业务候选码补声明（先输出重复键，不静默保留一行）
IF EXISTS (SELECT 1 FROM sys.key_constraints
           WHERE name = N'UQ_PurchaseOrder_replenishment_suggestion_id'
             AND parent_object_id = OBJECT_ID(N'dbo.PurchaseOrder'))
    THROW 53212, N'11c: UQ_PurchaseOrder_replenishment_suggestion_id already exists.', 1;
IF EXISTS (SELECT 1 FROM dbo.PurchaseOrder
           GROUP BY replenishment_suggestion_id HAVING COUNT(*) > 1)
BEGIN
    SET @msg = N'11c: duplicate PurchaseOrder.replenishment_suggestion_id: '
             + ISNULL((SELECT STRING_AGG(CONVERT(NVARCHAR(MAX), replenishment_suggestion_id), N',')
                              WITHIN GROUP (ORDER BY replenishment_suggestion_id)
                       FROM (SELECT replenishment_suggestion_id FROM dbo.PurchaseOrder
                             GROUP BY replenishment_suggestion_id HAVING COUNT(*) > 1) x), N'');
    THROW 53213, @msg, 1;
END;
ALTER TABLE dbo.PurchaseOrder
    ADD CONSTRAINT UQ_PurchaseOrder_replenishment_suggestion_id
        UNIQUE (replenishment_suggestion_id);
GO

-- ---------------------------------------------------------------------------
-- 3. 身份上下文过程（无员工参数；仅按 USER_NAME() 解析）
-- ---------------------------------------------------------------------------
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
CREATE PROCEDURE dbo.sp_get_current_employee_context
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @employee_id BIGINT, @database_user_name VARCHAR(128),
            @employee_name NVARCHAR(50), @job_code VARCHAR(20);

    SELECT @employee_id = employee_id,
           @database_user_name = database_user_name,
           @employee_name = employee_name,
           @job_code = job_code
    FROM dbo.EmployeeAccount
    WHERE database_user_name = USER_NAME() AND status = N'ACTIVE';

    IF @employee_id IS NULL
        THROW 51004, N'sp_get_current_employee_context: current login is not an active employee.', 1;

    -- RS1：员工头
    SELECT @employee_id AS employee_id,
           @database_user_name AS database_user_name,
           @employee_name AS employee_name,
           @job_code AS job_code;

    -- RS2：业务角色
    SELECT br.business_role_id, br.role_code, br.role_name
    FROM dbo.EmployeeBusinessRole AS ebr
    JOIN dbo.BusinessRole AS br ON br.business_role_id = ebr.business_role_id
    WHERE ebr.employee_id = @employee_id AND br.status = N'ACTIVE'
    ORDER BY br.role_code;

    -- RS3：权限代码（去重；多角色合并）
    SELECT DISTINCT p.permission_code, p.permission_name
    FROM dbo.EmployeeBusinessRole AS ebr
    JOIN dbo.RolePermission AS rp
      ON rp.business_role_id = ebr.business_role_id AND rp.status = N'ACTIVE'
    JOIN dbo.Permission AS p ON p.permission_code = rp.permission_code
    WHERE ebr.employee_id = @employee_id
    ORDER BY p.permission_code;
END;
GO

-- ---------------------------------------------------------------------------
-- 4. 迁移内终态校验（只读；失败由入口回滚）
-- ---------------------------------------------------------------------------
SET NOCOUNT ON;
SET XACT_ABORT ON;
IF (SELECT COUNT(*) FROM dbo.Permission) <> 53
    THROW 53214, N'11c: final Permission count != 53.', 1;
IF (SELECT COUNT(*) FROM dbo.RolePermission) <> 66
    THROW 53215, N'11c: final RolePermission count != 66.', 1;
IF EXISTS (SELECT 1 FROM dbo.RolePermission rp
           WHERE NOT EXISTS (SELECT 1 FROM dbo.Permission p WHERE p.permission_code = rp.permission_code))
    THROW 53216, N'11c: final RolePermission has a code outside Permission.', 1;
IF EXISTS (SELECT 1 FROM sys.columns
           WHERE object_id = OBJECT_ID(N'dbo.RolePermission') AND name = N'permission_name')
    THROW 53217, N'11c: RolePermission.permission_name was not removed.', 1;
IF OBJECT_ID(N'dbo.sp_get_current_employee_context', N'P') IS NULL
    THROW 53218, N'11c: sp_get_current_employee_context was not created.', 1;
GO
