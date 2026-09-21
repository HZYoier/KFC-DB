-- ============================================================================
-- 06_inventory_constraints_crud.sql
-- 负责人：C（库存、补货、员工权限、审计与总集成）
-- 用途：C 域命名 CHECK 约束；跨域审计过程 sp_write_audit_log
-- 依赖：01_master_schema.sql、03_inventory_security_schema.sql
-- 依据：docs/stage1-three-person-implementation-plan.md §2.3、§2.4、§5 C-1、
--       docs/stage1-cross-domain-interface-contract.md §3.4
-- 进度：当前仅包含 P0 第一段（C 域约束 + 审计过程）；
--       四个库存接口过程与库存调整/补货闭环过程属后续阶段，之后在本文件追加。
-- 说明：sp_write_audit_log 在写入前按 USER_NAME() 解析当前登录主体映射的启用员工，
--       并要求传入的员工 ID 与解析结果一致，不信任客户端伪造的主体 ID。
-- ============================================================================

USE KFC_DB;
GO

-- 批次 1：C 域命名 CHECK 约束
SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET QUOTED_IDENTIFIER ON;
SET NUMERIC_ROUNDABORT OFF;

ALTER TABLE dbo.EmployeeAccount WITH CHECK
    ADD CONSTRAINT CK_EmployeeAccount_status
        CHECK (status IN ('ACTIVE', 'INACTIVE'));

ALTER TABLE dbo.BusinessRole WITH CHECK
    ADD CONSTRAINT CK_BusinessRole_status
        CHECK (status IN ('ACTIVE', 'INACTIVE'));

ALTER TABLE dbo.RolePermission WITH CHECK
    ADD CONSTRAINT CK_RolePermission_status
        CHECK (status IN ('ACTIVE', 'INACTIVE'));

-- permission_code 白名单 = 本计划授权矩阵中出现的过程与视图对象名（不含仅由所有权链调用的对象）
ALTER TABLE dbo.RolePermission WITH CHECK
    ADD CONSTRAINT CK_RolePermission_permission_code
        CHECK (
            permission_code IN (
                -- A 域主数据过程（§3 A-2）
                'sp_create_category', 'sp_update_category_status',
                'sp_create_ingredient', 'sp_update_ingredient',
                'sp_create_product', 'sp_update_product_price', 'sp_update_product_status',
                'sp_set_product_bom', 'sp_set_combo_component',
                'sp_create_promotion', 'sp_update_promotion_status',
                'sp_add_promotion_product_rule', 'sp_update_promotion_product_rule',
                'sp_create_member_level', 'sp_update_member_level',
                'sp_update_member_level_status',
                'sp_create_customer', 'sp_update_customer_member_level',
                -- B 域订单过程（§4 B-2）
                'sp_create_order', 'sp_pay_order', 'sp_start_production',
                'sp_finish_production', 'sp_pick_up_order', 'sp_pick_up_delivery',
                'sp_confirm_delivery', 'sp_cancel_or_refund_order',
                -- C 域过程中被授权矩阵显式授予角色的部分（§5 C-2）
                'sp_adjust_inventory', 'sp_create_replenishment_suggestion',
                'sp_update_replenishment_suggestion', 'sp_submit_replenishment_suggestion',
                'sp_approve_replenishment_suggestion', 'sp_reject_replenishment_suggestion',
                'sp_receive_inventory', 'sp_assign_employee_business_role',
                'sp_revoke_employee_business_role', 'sp_update_employee_status',
                -- 视图（§5 C-2 授权矩阵）
                'v_active_product_price', 'v_product_bom_detail',
                'v_order_detail', 'v_kitchen_queue', 'v_customer_point_ledger',
                'v_pickup_board', 'v_inventory_available',
                'v_inventory_movement_history', 'v_replenishment_dashboard',
                'v_order_inventory_trace'
            )
        );

ALTER TABLE dbo.Inventory WITH CHECK
    ADD CONSTRAINT CK_Inventory_on_hand_qty
        CHECK (on_hand_qty >= 0);

ALTER TABLE dbo.Inventory WITH CHECK
    ADD CONSTRAINT CK_Inventory_locked_qty
        CHECK (locked_qty >= 0);

ALTER TABLE dbo.InventoryMovement WITH CHECK
    ADD CONSTRAINT CK_InventoryMovement_movement_type
        CHECK (movement_type IN ('LOCK', 'RELEASE', 'CONSUME', 'RECEIPT', 'ADJUSTMENT'));

ALTER TABLE dbo.InventoryMovement WITH CHECK
    ADD CONSTRAINT CK_InventoryMovement_reference_type
        CHECK (reference_type IN ('ORDER', 'PURCHASE_ORDER', 'ADJUSTMENT'));

-- ORDER 与 PURCHASE_ORDER 必须填写 reference_id；ADJUSTMENT 允许为空
ALTER TABLE dbo.InventoryMovement WITH CHECK
    ADD CONSTRAINT CK_InventoryMovement_reference
        CHECK (
            (reference_type IN ('ORDER', 'PURCHASE_ORDER') AND reference_id IS NOT NULL)
            OR reference_type = 'ADJUSTMENT'
        );

ALTER TABLE dbo.InventoryMovement WITH CHECK
    ADD CONSTRAINT CK_InventoryMovement_delta_not_zero
        CHECK (on_hand_delta <> 0 OR locked_delta <> 0);

ALTER TABLE dbo.ReplenishmentSuggestion WITH CHECK
    ADD CONSTRAINT CK_ReplenishmentSuggestion_suggestion_status
        CHECK (suggestion_status IN ('PENDING', 'SUBMITTED', 'APPROVED', 'REJECTED', 'CLOSED'));

ALTER TABLE dbo.ReplenishmentSuggestion WITH CHECK
    ADD CONSTRAINT CK_ReplenishmentSuggestion_suggested_qty
        CHECK (suggested_qty > 0);

ALTER TABLE dbo.PurchaseOrder WITH CHECK
    ADD CONSTRAINT CK_PurchaseOrder_purchase_status
        CHECK (purchase_status IN ('DRAFT', 'APPROVED', 'PARTIALLY_RECEIVED', 'CLOSED'));

ALTER TABLE dbo.PurchaseOrderItem WITH CHECK
    ADD CONSTRAINT CK_PurchaseOrderItem_ordered_qty
        CHECK (ordered_qty > 0);

ALTER TABLE dbo.PurchaseOrderItem WITH CHECK
    ADD CONSTRAINT CK_PurchaseOrderItem_received_qty
        CHECK (received_qty >= 0 AND received_qty <= ordered_qty);
GO

-- 批次 2：跨域审计过程
-- 静态 SQL + dbo 所有权链：A/B 的过程无需显式授权即可调用；
-- 只写 AuditLog，不记录支付完整报文或密码。
SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET QUOTED_IDENTIFIER ON;
SET NUMERIC_ROUNDABORT OFF;
GO

CREATE PROCEDURE dbo.sp_write_audit_log
    @employee_id BIGINT,
    @action_name VARCHAR(50),
    @entity_name VARCHAR(50),
    @entity_id BIGINT,
    @detail_json NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    IF @employee_id IS NULL
    BEGIN
        THROW 50000, N'sp_write_audit_log：缺少员工 ID，拒绝写入审计日志。', 1;
    END;

    IF @action_name IS NULL OR LTRIM(RTRIM(@action_name)) = N''
    BEGIN
        THROW 50000, N'sp_write_audit_log：缺少操作名称，拒绝写入审计日志。', 1;
    END;

    IF @entity_name IS NULL OR LTRIM(RTRIM(@entity_name)) = N''
    BEGIN
        THROW 50000, N'sp_write_audit_log：缺少实体名称，拒绝写入审计日志。', 1;
    END;

    -- 身份校验：@employee_id 必须等于当前登录主体按 USER_NAME() 解析出的启用员工
    -- EmployeeAccount.database_user_name 有唯一约束，故至多解析出一行
    DECLARE @resolved_employee_id BIGINT;

    SELECT @resolved_employee_id = ea.employee_id
    FROM dbo.EmployeeAccount AS ea
    WHERE ea.database_user_name = USER_NAME()
      AND ea.status = 'ACTIVE';

    IF @resolved_employee_id IS NULL
    BEGIN
        THROW 50000, N'sp_write_audit_log：当前登录主体未映射到启用员工，拒绝写入审计日志。', 1;
    END;

    IF @employee_id <> @resolved_employee_id
    BEGIN
        THROW 50000, N'sp_write_audit_log：传入员工 ID 与当前登录主体解析出的员工不一致，拒绝写入审计日志。', 1;
    END;

    INSERT INTO dbo.AuditLog (employee_id, action_name, entity_name, entity_id, detail_json, logged_at)
    VALUES (@employee_id, @action_name, @entity_name, @entity_id, @detail_json, SYSDATETIME());
END;
GO
