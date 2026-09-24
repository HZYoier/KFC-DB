-- ============================================================================
-- 06_inventory_constraints_crud.sql
-- 负责人：C（库存、补货、员工权限、审计与总集成）
-- 用途：C 域命名 CHECK 约束；跨域审计过程 sp_write_audit_log；
--       库存人工调整与补货闭环过程；订单库存接口过程（锁库/释放/实扣）；
--       员工业务角色同步过程（分配/撤销/停用）
-- 依赖：01_master_schema.sql、02_order_schema.sql、03_inventory_security_schema.sql
-- 依据：docs/stage1-three-person-implementation-plan.md §2.3、§2.4、§5 C-1、
--       docs/stage1-cross-domain-interface-contract.md §3.4
-- 进度：批次 1 C 域命名 CHECK；批次 2 sp_write_audit_log；批次 3 库存调整与补货闭环；
--       批次 4 锁库/释放/实扣；批次 5 员工业务角色同步（分配/撤销/停用）。
--       批次 5 的三个过程需由 08_roles_permissions.sql 用证书签名授予
--       ALTER ANY ROLE / ALTER ANY USER（§5 C-1 line 303）；改过本文件后必须重跑 08 的签名。
-- 待办：sp_receive_inventory 的签名冲突已记入 plan §8 变更记录 2026-09-24，
--       按 §6.3「三人确认后再改」，确认前不实现。
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

-- ============================================================================
-- 批次 3：库存人工调整与补货闭环过程（§5 C-1）
-- 事务纪律（§2.3）：@@TRANCOUNT = 0 时自行开事务并提交；已处于调用方事务时
--   只建保存点，绝不提交外层，失败回滚到保存点后重新抛出。
-- 过程操作人一律按 USER_NAME() 解析启用员工，不信任传入的员工 ID。
-- ============================================================================
SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET QUOTED_IDENTIFIER ON;
SET NUMERIC_ROUNDABORT OFF;
GO

-- 内部过程：按安全库存线刷新某原料的开放补货建议。
-- 只由本域过程经 dbo 所有权链调用，不在 §5 C-2 授权矩阵中单独授权。
-- 已有 APPROVED 建议表示采购已在途，此时不修改也不新增，待采购单关闭后由收货过程置 CLOSED。
CREATE PROCEDURE dbo.sp_refresh_replenishment_suggestion
    @ingredient_id     BIGINT,
    @actor_employee_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @on_hand_qty DECIMAL(12,3);
    DECLARE @safety_stock_qty DECIMAL(12,3);

    SELECT @on_hand_qty = inv.on_hand_qty,
           @safety_stock_qty = ing.safety_stock_qty
    FROM dbo.Inventory AS inv
    JOIN dbo.Ingredient AS ing
      ON ing.ingredient_id = inv.ingredient_id
    WHERE inv.ingredient_id = @ingredient_id;

    -- 尚未建立库存记录的原料不产生建议
    IF @on_hand_qty IS NULL
        RETURN;

    IF @on_hand_qty < @safety_stock_qty
    BEGIN
        -- 刚好补到安全库存线，保留 3 位小数；本分支保证差值大于 0
        DECLARE @suggested_qty DECIMAL(12,3)
            = CAST(@safety_stock_qty - @on_hand_qty AS DECIMAL(12,3));

        IF EXISTS (SELECT 1
                   FROM dbo.ReplenishmentSuggestion
                   WHERE ingredient_id = @ingredient_id
                     AND suggestion_status IN ('PENDING', 'SUBMITTED'))
        BEGIN
            UPDATE dbo.ReplenishmentSuggestion
               SET current_qty = @on_hand_qty,
                   suggested_qty = @suggested_qty
             WHERE ingredient_id = @ingredient_id
               AND suggestion_status IN ('PENDING', 'SUBMITTED');
        END
        ELSE IF NOT EXISTS (SELECT 1
                            FROM dbo.ReplenishmentSuggestion
                            WHERE ingredient_id = @ingredient_id
                              AND suggestion_status = 'APPROVED')
        BEGIN
            INSERT INTO dbo.ReplenishmentSuggestion
                (ingredient_id, current_qty, suggested_qty, suggestion_status, created_by_employee_id)
            VALUES
                (@ingredient_id, @on_hand_qty, @suggested_qty, 'PENDING', @actor_employee_id);
        END;
    END
    ELSE
    BEGIN
        -- 已回到安全线以上：关闭尚未审批的开放建议
        UPDATE dbo.ReplenishmentSuggestion
           SET suggestion_status = 'CLOSED'
         WHERE ingredient_id = @ingredient_id
           AND suggestion_status IN ('PENDING', 'SUBMITTED');
    END;
END;
GO

-- 库存人工调整（§5 C-1）：仅店长，写 ADJUSTMENT 流水 + 审计日志
CREATE PROCEDURE dbo.sp_adjust_inventory
    @ingredient_id BIGINT,
    @on_hand_delta DECIMAL(12,3),
    @employee_id   BIGINT,
    @reason        VARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @ingredient_id IS NULL OR @on_hand_delta IS NULL OR @employee_id IS NULL
    BEGIN
        THROW 50000, N'sp_adjust_inventory：@ingredient_id、@on_hand_delta、@employee_id 都不能为 NULL。', 1;
    END;

    IF @on_hand_delta = 0
    BEGIN
        THROW 50000, N'sp_adjust_inventory：@on_hand_delta 不能为 0，无变化请勿调整。', 1;
    END;

    IF @reason IS NULL OR LTRIM(RTRIM(@reason)) = ''
    BEGIN
        THROW 50000, N'sp_adjust_inventory：缺少调整原因 @reason。', 1;
    END;

    DECLARE @resolved_employee_id BIGINT;

    SELECT @resolved_employee_id = ea.employee_id
    FROM dbo.EmployeeAccount AS ea
    WHERE ea.database_user_name = USER_NAME()
      AND ea.status = 'ACTIVE';

    IF @resolved_employee_id IS NULL
    BEGIN
        THROW 50000, N'sp_adjust_inventory：当前登录主体未映射到启用员工，拒绝执行。', 1;
    END;

    IF @employee_id <> @resolved_employee_id
    BEGIN
        THROW 50000, N'sp_adjust_inventory：传入员工 ID 与当前登录主体解析出的员工不一致，拒绝执行。', 1;
    END;

    IF NOT EXISTS (SELECT 1
                   FROM dbo.EmployeeBusinessRole AS ebr
                   JOIN dbo.BusinessRole AS br
                     ON br.business_role_id = ebr.business_role_id
                   WHERE ebr.employee_id = @resolved_employee_id
                     AND br.role_code = 'store_manager'
                     AND br.status = 'ACTIVE')
    BEGIN
        THROW 50000, N'sp_adjust_inventory：仅店长可调整库存。', 1;
    END;

    DECLARE @owns_tran BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;

    IF @owns_tran = 1
        BEGIN TRANSACTION;
    ELSE
        SAVE TRANSACTION sp_adjust_inventory;

    BEGIN TRY
        DECLARE @on_hand_qty DECIMAL(12,3);

        SELECT @on_hand_qty = inv.on_hand_qty
        FROM dbo.Inventory AS inv WITH (UPDLOCK, HOLDLOCK)
        WHERE inv.ingredient_id = @ingredient_id;

        IF @on_hand_qty IS NULL
        BEGIN
            THROW 50000, N'sp_adjust_inventory：原料不存在或尚未建立库存记录。', 1;
        END;

        IF @on_hand_qty + @on_hand_delta < 0
        BEGIN
            THROW 50000, N'sp_adjust_inventory：调整后库存不能为负。', 1;
        END;

        UPDATE dbo.Inventory
           SET on_hand_qty = on_hand_qty + @on_hand_delta,
               updated_at = SYSDATETIME()
         WHERE ingredient_id = @ingredient_id;

        INSERT INTO dbo.InventoryMovement
            (ingredient_id, movement_type, on_hand_delta, locked_delta, reference_type, reference_id, moved_at)
        VALUES
            (@ingredient_id, 'ADJUSTMENT', @on_hand_delta, 0, 'ADJUSTMENT', NULL, SYSDATETIME());

        DECLARE @detail_json NVARCHAR(MAX) =
        (
            SELECT @reason AS reason,
                   @on_hand_qty AS on_hand_before,
                   @on_hand_qty + @on_hand_delta AS on_hand_after
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
        );

        EXEC dbo.sp_write_audit_log
             @employee_id = @resolved_employee_id,
             @action_name = 'ADJUST_INVENTORY',
             @entity_name = 'Inventory',
             @entity_id   = @ingredient_id,
             @detail_json = @detail_json;

        EXEC dbo.sp_refresh_replenishment_suggestion
             @ingredient_id     = @ingredient_id,
             @actor_employee_id = @resolved_employee_id;

        IF @owns_tran = 1
            COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @owns_tran = 1 AND XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        ELSE IF @owns_tran = 0 AND XACT_STATE() = 1
            ROLLBACK TRANSACTION sp_adjust_inventory;

        THROW;
    END CATCH;
END;
GO

-- 创建补货建议：值班经理，状态 PENDING；每原料最多一张开放建议
CREATE PROCEDURE dbo.sp_create_replenishment_suggestion
    @ingredient_id BIGINT,
    @suggested_qty DECIMAL(12,3),
    @employee_id   BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @ingredient_id IS NULL OR @suggested_qty IS NULL OR @employee_id IS NULL
    BEGIN
        THROW 50000, N'sp_create_replenishment_suggestion：@ingredient_id、@suggested_qty、@employee_id 都不能为 NULL。', 1;
    END;

    IF @suggested_qty <= 0
    BEGIN
        THROW 50000, N'sp_create_replenishment_suggestion：@suggested_qty 必须大于 0。', 1;
    END;

    DECLARE @resolved_employee_id BIGINT;

    SELECT @resolved_employee_id = ea.employee_id
    FROM dbo.EmployeeAccount AS ea
    WHERE ea.database_user_name = USER_NAME()
      AND ea.status = 'ACTIVE';

    IF @resolved_employee_id IS NULL
    BEGIN
        THROW 50000, N'sp_create_replenishment_suggestion：当前登录主体未映射到启用员工，拒绝执行。', 1;
    END;

    IF @employee_id <> @resolved_employee_id
    BEGIN
        THROW 50000, N'sp_create_replenishment_suggestion：传入员工 ID 与当前登录主体解析出的员工不一致，拒绝执行。', 1;
    END;

    IF NOT EXISTS (SELECT 1
                   FROM dbo.EmployeeBusinessRole AS ebr
                   JOIN dbo.BusinessRole AS br
                     ON br.business_role_id = ebr.business_role_id
                   WHERE ebr.employee_id = @resolved_employee_id
                     AND br.role_code = 'shift_manager'
                     AND br.status = 'ACTIVE')
    BEGIN
        THROW 50000, N'sp_create_replenishment_suggestion：仅值班经理可创建补货建议。', 1;
    END;

    DECLARE @owns_tran BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;

    IF @owns_tran = 1
        BEGIN TRANSACTION;
    ELSE
        SAVE TRANSACTION sp_create_repl_sugg;

    BEGIN TRY
        DECLARE @on_hand_qty DECIMAL(12,3);

        SELECT @on_hand_qty = inv.on_hand_qty
        FROM dbo.Inventory AS inv WITH (UPDLOCK, HOLDLOCK)
        WHERE inv.ingredient_id = @ingredient_id;

        IF @on_hand_qty IS NULL
        BEGIN
            THROW 50000, N'sp_create_replenishment_suggestion：原料不存在或尚未建立库存记录。', 1;
        END;

        IF EXISTS (SELECT 1
                   FROM dbo.ReplenishmentSuggestion
                   WHERE ingredient_id = @ingredient_id
                     AND suggestion_status IN ('PENDING', 'SUBMITTED', 'APPROVED'))
        BEGIN
            THROW 50000, N'sp_create_replenishment_suggestion：该原料已有开放建议，请调整现有建议。', 1;
        END;

        INSERT INTO dbo.ReplenishmentSuggestion
            (ingredient_id, current_qty, suggested_qty, suggestion_status, created_by_employee_id)
        VALUES
            (@ingredient_id, @on_hand_qty, @suggested_qty, 'PENDING', @resolved_employee_id);

        DECLARE @suggestion_id BIGINT = SCOPE_IDENTITY();

        DECLARE @detail_json NVARCHAR(MAX) =
        (
            SELECT @ingredient_id AS ingredient_id,
                   @on_hand_qty AS current_qty,
                   @suggested_qty AS suggested_qty
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
        );

        EXEC dbo.sp_write_audit_log
             @employee_id = @resolved_employee_id,
             @action_name = 'CREATE_REPLENISHMENT_SUGGESTION',
             @entity_name = 'ReplenishmentSuggestion',
             @entity_id   = @suggestion_id,
             @detail_json = @detail_json;

        IF @owns_tran = 1
            COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @owns_tran = 1 AND XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        ELSE IF @owns_tran = 0 AND XACT_STATE() = 1
            ROLLBACK TRANSACTION sp_create_repl_sugg;

        THROW;
    END CATCH;
END;
GO

-- 调整补货建议：值班经理，仅可调整仍处于 PENDING 的建议
CREATE PROCEDURE dbo.sp_update_replenishment_suggestion
    @suggestion_id BIGINT,
    @suggested_qty DECIMAL(12,3),
    @employee_id   BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @suggestion_id IS NULL OR @suggested_qty IS NULL OR @employee_id IS NULL
    BEGIN
        THROW 50000, N'sp_update_replenishment_suggestion：@suggestion_id、@suggested_qty、@employee_id 都不能为 NULL。', 1;
    END;

    IF @suggested_qty <= 0
    BEGIN
        THROW 50000, N'sp_update_replenishment_suggestion：@suggested_qty 必须大于 0。', 1;
    END;

    DECLARE @resolved_employee_id BIGINT;

    SELECT @resolved_employee_id = ea.employee_id
    FROM dbo.EmployeeAccount AS ea
    WHERE ea.database_user_name = USER_NAME()
      AND ea.status = 'ACTIVE';

    IF @resolved_employee_id IS NULL
    BEGIN
        THROW 50000, N'sp_update_replenishment_suggestion：当前登录主体未映射到启用员工，拒绝执行。', 1;
    END;

    IF @employee_id <> @resolved_employee_id
    BEGIN
        THROW 50000, N'sp_update_replenishment_suggestion：传入员工 ID 与当前登录主体解析出的员工不一致，拒绝执行。', 1;
    END;

    IF NOT EXISTS (SELECT 1
                   FROM dbo.EmployeeBusinessRole AS ebr
                   JOIN dbo.BusinessRole AS br
                     ON br.business_role_id = ebr.business_role_id
                   WHERE ebr.employee_id = @resolved_employee_id
                     AND br.role_code = 'shift_manager'
                     AND br.status = 'ACTIVE')
    BEGIN
        THROW 50000, N'sp_update_replenishment_suggestion：仅值班经理可调整补货建议。', 1;
    END;

    DECLARE @owns_tran BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;

    IF @owns_tran = 1
        BEGIN TRANSACTION;
    ELSE
        SAVE TRANSACTION sp_update_repl_sugg;

    BEGIN TRY
        DECLARE @suggestion_status VARCHAR(20);
        DECLARE @old_suggested_qty DECIMAL(12,3);

        SELECT @suggestion_status = rs.suggestion_status,
               @old_suggested_qty = rs.suggested_qty
        FROM dbo.ReplenishmentSuggestion AS rs WITH (UPDLOCK, HOLDLOCK)
        WHERE rs.replenishment_suggestion_id = @suggestion_id;

        IF @suggestion_status IS NULL
        BEGIN
            THROW 50000, N'sp_update_replenishment_suggestion：补货建议不存在。', 1;
        END;

        IF @suggestion_status <> 'PENDING'
        BEGIN
            THROW 50000, N'sp_update_replenishment_suggestion：仅可调整处于 PENDING 的建议。', 1;
        END;

        UPDATE dbo.ReplenishmentSuggestion
           SET suggested_qty = @suggested_qty
         WHERE replenishment_suggestion_id = @suggestion_id;

        DECLARE @detail_json NVARCHAR(MAX) =
        (
            SELECT @old_suggested_qty AS suggested_qty_before,
                   @suggested_qty AS suggested_qty_after
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
        );

        EXEC dbo.sp_write_audit_log
             @employee_id = @resolved_employee_id,
             @action_name = 'UPDATE_REPLENISHMENT_SUGGESTION',
             @entity_name = 'ReplenishmentSuggestion',
             @entity_id   = @suggestion_id,
             @detail_json = @detail_json;

        IF @owns_tran = 1
            COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @owns_tran = 1 AND XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        ELSE IF @owns_tran = 0 AND XACT_STATE() = 1
            ROLLBACK TRANSACTION sp_update_repl_sugg;

        THROW;
    END CATCH;
END;
GO

-- 提交补货建议：值班经理，PENDING -> SUBMITTED
CREATE PROCEDURE dbo.sp_submit_replenishment_suggestion
    @suggestion_id BIGINT,
    @employee_id   BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @suggestion_id IS NULL OR @employee_id IS NULL
    BEGIN
        THROW 50000, N'sp_submit_replenishment_suggestion：@suggestion_id、@employee_id 都不能为 NULL。', 1;
    END;

    DECLARE @resolved_employee_id BIGINT;

    SELECT @resolved_employee_id = ea.employee_id
    FROM dbo.EmployeeAccount AS ea
    WHERE ea.database_user_name = USER_NAME()
      AND ea.status = 'ACTIVE';

    IF @resolved_employee_id IS NULL
    BEGIN
        THROW 50000, N'sp_submit_replenishment_suggestion：当前登录主体未映射到启用员工，拒绝执行。', 1;
    END;

    IF @employee_id <> @resolved_employee_id
    BEGIN
        THROW 50000, N'sp_submit_replenishment_suggestion：传入员工 ID 与当前登录主体解析出的员工不一致，拒绝执行。', 1;
    END;

    IF NOT EXISTS (SELECT 1
                   FROM dbo.EmployeeBusinessRole AS ebr
                   JOIN dbo.BusinessRole AS br
                     ON br.business_role_id = ebr.business_role_id
                   WHERE ebr.employee_id = @resolved_employee_id
                     AND br.role_code = 'shift_manager'
                     AND br.status = 'ACTIVE')
    BEGIN
        THROW 50000, N'sp_submit_replenishment_suggestion：仅值班经理可提交补货建议。', 1;
    END;

    DECLARE @owns_tran BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;

    IF @owns_tran = 1
        BEGIN TRANSACTION;
    ELSE
        SAVE TRANSACTION sp_submit_repl_sugg;

    BEGIN TRY
        DECLARE @suggestion_status VARCHAR(20);

        SELECT @suggestion_status = rs.suggestion_status
        FROM dbo.ReplenishmentSuggestion AS rs WITH (UPDLOCK, HOLDLOCK)
        WHERE rs.replenishment_suggestion_id = @suggestion_id;

        IF @suggestion_status IS NULL
        BEGIN
            THROW 50000, N'sp_submit_replenishment_suggestion：补货建议不存在。', 1;
        END;

        IF @suggestion_status <> 'PENDING'
        BEGIN
            THROW 50000, N'sp_submit_replenishment_suggestion：仅可提交处于 PENDING 的建议。', 1;
        END;

        UPDATE dbo.ReplenishmentSuggestion
           SET suggestion_status = 'SUBMITTED',
               submitted_by_employee_id = @resolved_employee_id
         WHERE replenishment_suggestion_id = @suggestion_id;

        EXEC dbo.sp_write_audit_log
             @employee_id = @resolved_employee_id,
             @action_name = 'SUBMIT_REPLENISHMENT_SUGGESTION',
             @entity_name = 'ReplenishmentSuggestion',
             @entity_id   = @suggestion_id,
             @detail_json = N'{"suggestion_status":"PENDING->SUBMITTED"}';

        IF @owns_tran = 1
            COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @owns_tran = 1 AND XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        ELSE IF @owns_tran = 0 AND XACT_STATE() = 1
            ROLLBACK TRANSACTION sp_submit_repl_sugg;

        THROW;
    END CATCH;
END;
GO

-- 审批补货建议：店长，SUBMITTED -> APPROVED，并在同一事务内生成 APPROVED 采购单与明细
CREATE PROCEDURE dbo.sp_approve_replenishment_suggestion
    @suggestion_id       BIGINT,
    @manager_employee_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @suggestion_id IS NULL OR @manager_employee_id IS NULL
    BEGIN
        THROW 50000, N'sp_approve_replenishment_suggestion：@suggestion_id、@manager_employee_id 都不能为 NULL。', 1;
    END;

    DECLARE @resolved_employee_id BIGINT;

    SELECT @resolved_employee_id = ea.employee_id
    FROM dbo.EmployeeAccount AS ea
    WHERE ea.database_user_name = USER_NAME()
      AND ea.status = 'ACTIVE';

    IF @resolved_employee_id IS NULL
    BEGIN
        THROW 50000, N'sp_approve_replenishment_suggestion：当前登录主体未映射到启用员工，拒绝执行。', 1;
    END;

    IF @manager_employee_id <> @resolved_employee_id
    BEGIN
        THROW 50000, N'sp_approve_replenishment_suggestion：传入员工 ID 与当前登录主体解析出的员工不一致，拒绝执行。', 1;
    END;

    IF NOT EXISTS (SELECT 1
                   FROM dbo.EmployeeBusinessRole AS ebr
                   JOIN dbo.BusinessRole AS br
                     ON br.business_role_id = ebr.business_role_id
                   WHERE ebr.employee_id = @resolved_employee_id
                     AND br.role_code = 'store_manager'
                     AND br.status = 'ACTIVE')
    BEGIN
        THROW 50000, N'sp_approve_replenishment_suggestion：仅店长可审批补货建议。', 1;
    END;

    DECLARE @owns_tran BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;

    IF @owns_tran = 1
        BEGIN TRANSACTION;
    ELSE
        SAVE TRANSACTION sp_approve_repl_sugg;

    BEGIN TRY
        DECLARE @suggestion_status VARCHAR(20);
        DECLARE @ingredient_id BIGINT;
        DECLARE @suggested_qty DECIMAL(12,3);

        SELECT @suggestion_status = rs.suggestion_status,
               @ingredient_id = rs.ingredient_id,
               @suggested_qty = rs.suggested_qty
        FROM dbo.ReplenishmentSuggestion AS rs WITH (UPDLOCK, HOLDLOCK)
        WHERE rs.replenishment_suggestion_id = @suggestion_id;

        IF @suggestion_status IS NULL
        BEGIN
            THROW 50000, N'sp_approve_replenishment_suggestion：补货建议不存在。', 1;
        END;

        IF @suggestion_status <> 'SUBMITTED'
        BEGIN
            THROW 50000, N'sp_approve_replenishment_suggestion：仅可审批处于 SUBMITTED 的建议。', 1;
        END;

        -- 单号：PO + yyyyMMdd + 当日 4 位序号，唯一约束兜底
        DECLARE @order_prefix VARCHAR(20) = 'PO' + CONVERT(VARCHAR(8), SYSDATETIME(), 112);
        DECLARE @next_seq INT;

        SELECT @next_seq = ISNULL(MAX(TRY_CAST(RIGHT(po.purchase_order_no, 4) AS INT)), 0) + 1
        FROM dbo.PurchaseOrder AS po WITH (UPDLOCK, HOLDLOCK)
        WHERE po.purchase_order_no LIKE @order_prefix + '%';

        DECLARE @purchase_order_no VARCHAR(20)
            = @order_prefix + RIGHT('0000' + CAST(@next_seq AS VARCHAR(4)), 4);

        UPDATE dbo.ReplenishmentSuggestion
           SET suggestion_status = 'APPROVED',
               approved_by_employee_id = @resolved_employee_id
         WHERE replenishment_suggestion_id = @suggestion_id;

        INSERT INTO dbo.PurchaseOrder
            (purchase_order_no, replenishment_suggestion_id, purchase_status,
             approved_by_employee_id, approved_at)
        VALUES
            (@purchase_order_no, @suggestion_id, 'APPROVED',
             @resolved_employee_id, SYSDATETIME());

        DECLARE @purchase_order_id BIGINT = SCOPE_IDENTITY();

        INSERT INTO dbo.PurchaseOrderItem
            (purchase_order_id, ingredient_id, ordered_qty, received_qty)
        VALUES
            (@purchase_order_id, @ingredient_id, @suggested_qty, 0);

        DECLARE @detail_json NVARCHAR(MAX) =
        (
            SELECT @purchase_order_no AS purchase_order_no,
                   @ingredient_id AS ingredient_id,
                   @suggested_qty AS ordered_qty
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
        );

        EXEC dbo.sp_write_audit_log
             @employee_id = @resolved_employee_id,
             @action_name = 'APPROVE_REPLENISHMENT_SUGGESTION',
             @entity_name = 'PurchaseOrder',
             @entity_id   = @purchase_order_id,
             @detail_json = @detail_json;

        IF @owns_tran = 1
            COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @owns_tran = 1 AND XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        ELSE IF @owns_tran = 0 AND XACT_STATE() = 1
            ROLLBACK TRANSACTION sp_approve_repl_sugg;

        THROW;
    END CATCH;
END;
GO

-- 驳回补货建议：店长，SUBMITTED -> REJECTED
CREATE PROCEDURE dbo.sp_reject_replenishment_suggestion
    @suggestion_id       BIGINT,
    @manager_employee_id BIGINT,
    @reason              VARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @suggestion_id IS NULL OR @manager_employee_id IS NULL
    BEGIN
        THROW 50000, N'sp_reject_replenishment_suggestion：@suggestion_id、@manager_employee_id 都不能为 NULL。', 1;
    END;

    IF @reason IS NULL OR LTRIM(RTRIM(@reason)) = ''
    BEGIN
        THROW 50000, N'sp_reject_replenishment_suggestion：缺少驳回原因 @reason。', 1;
    END;

    DECLARE @resolved_employee_id BIGINT;

    SELECT @resolved_employee_id = ea.employee_id
    FROM dbo.EmployeeAccount AS ea
    WHERE ea.database_user_name = USER_NAME()
      AND ea.status = 'ACTIVE';

    IF @resolved_employee_id IS NULL
    BEGIN
        THROW 50000, N'sp_reject_replenishment_suggestion：当前登录主体未映射到启用员工，拒绝执行。', 1;
    END;

    IF @manager_employee_id <> @resolved_employee_id
    BEGIN
        THROW 50000, N'sp_reject_replenishment_suggestion：传入员工 ID 与当前登录主体解析出的员工不一致，拒绝执行。', 1;
    END;

    IF NOT EXISTS (SELECT 1
                   FROM dbo.EmployeeBusinessRole AS ebr
                   JOIN dbo.BusinessRole AS br
                     ON br.business_role_id = ebr.business_role_id
                   WHERE ebr.employee_id = @resolved_employee_id
                     AND br.role_code = 'store_manager'
                     AND br.status = 'ACTIVE')
    BEGIN
        THROW 50000, N'sp_reject_replenishment_suggestion：仅店长可驳回补货建议。', 1;
    END;

    DECLARE @owns_tran BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;

    IF @owns_tran = 1
        BEGIN TRANSACTION;
    ELSE
        SAVE TRANSACTION sp_reject_repl_sugg;

    BEGIN TRY
        DECLARE @suggestion_status VARCHAR(20);

        SELECT @suggestion_status = rs.suggestion_status
        FROM dbo.ReplenishmentSuggestion AS rs WITH (UPDLOCK, HOLDLOCK)
        WHERE rs.replenishment_suggestion_id = @suggestion_id;

        IF @suggestion_status IS NULL
        BEGIN
            THROW 50000, N'sp_reject_replenishment_suggestion：补货建议不存在。', 1;
        END;

        IF @suggestion_status <> 'SUBMITTED'
        BEGIN
            THROW 50000, N'sp_reject_replenishment_suggestion：仅可驳回处于 SUBMITTED 的建议。', 1;
        END;

        UPDATE dbo.ReplenishmentSuggestion
           SET suggestion_status = 'REJECTED',
               rejected_by_employee_id = @resolved_employee_id
         WHERE replenishment_suggestion_id = @suggestion_id;

        DECLARE @detail_json NVARCHAR(MAX) =
        (
            SELECT @reason AS reason,
                   'SUBMITTED->REJECTED' AS status_change
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
        );

        EXEC dbo.sp_write_audit_log
             @employee_id = @resolved_employee_id,
             @action_name = 'REJECT_REPLENISHMENT_SUGGESTION',
             @entity_name = 'ReplenishmentSuggestion',
             @entity_id   = @suggestion_id,
             @detail_json = @detail_json;

        IF @owns_tran = 1
            COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @owns_tran = 1 AND XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        ELSE IF @owns_tran = 0 AND XACT_STATE() = 1
            ROLLBACK TRANSACTION sp_reject_repl_sugg;

        THROW;
    END CATCH;
END;
GO

-- ============================================================================
-- 批次 4：订单库存接口过程（§2.3 line 135-137）
-- 这三个过程由 C 实现、B 的订单过程经 dbo 所有权链调用，不在 §5 C-2 授权矩阵中
--   单独授权，因此不校验调用者业务角色；调用方身份由 B 的过程自行把关。
-- 事务纪律：§5 C-1 line 298 要求 SET XACT_ABORT ON；调用方未持事务时自行
--   BEGIN/COMMIT，已持事务时只建保存点、绝不提交外层（§2.3 line 141）。
--   注意 XACT_ABORT ON 下 THROW 会使 XACT_STATE() = -1，保存点分支实际只覆盖
--   非错误路径；失败时由持有外层事务的调用方回滚整个事务（§8 2026-09-24 记录）。
-- 流水数值语义（§2.3 line 143）：LOCK 为 0/+需求量、RELEASE 为 0/−释放量、
--   CONSUME 为 −实扣量/−实扣量；均以 reference_type = 'ORDER' 记本单。
-- ============================================================================
SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET QUOTED_IDENTIFIER ON;
SET NUMERIC_ROUNDABORT OFF;
GO

-- 锁库（§2.3 line 142）：按本单明细展开 BOM 汇总原料用量，校验可用量后增加
-- locked_qty 并写 LOCK 流水；不足时抛错，由调用方回滚订单创建。
CREATE PROCEDURE dbo.sp_lock_order_inventory
    @order_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @order_id IS NULL
    BEGIN
        THROW 50000, N'sp_lock_order_inventory：缺少订单 ID，拒绝锁库。', 1;
    END;

    IF NOT EXISTS (SELECT 1 FROM dbo.SalesOrder WHERE order_id = @order_id)
    BEGIN
        THROW 50000, N'sp_lock_order_inventory：订单不存在，拒绝锁库。', 1;
    END;

    -- 同一订单只锁一次：重复锁库会让 locked_qty 重复计数，使别的订单误判可用量。
    -- 正常重试路径（上一次调用整体回滚）不会留下本单的 LOCK 流水，故不受影响。
    IF EXISTS (SELECT 1
               FROM dbo.InventoryMovement
               WHERE reference_type = 'ORDER'
                 AND reference_id = @order_id
                 AND movement_type IN ('LOCK', 'RELEASE', 'CONSUME'))
    BEGIN
        THROW 50000, N'sp_lock_order_inventory：本订单已有库存流水，拒绝重复锁库。', 1;
    END;

    -- 需展开用料的明细：SELLABLE 单品，加套餐的 COMPONENT 子项。
    -- 套餐父项（SELLABLE 且 product_type = 'COMBO'）不当作有 BOM 的单品，
    -- 其子项已由下单过程按 ComboComponent 写成本单的 COMPONENT 明细（§4 line 254），
    -- 子项自身即为子项商品，数量已含套餐倍数，故此处只需经 ProductBom 展开一次。
    DECLARE @line TABLE
    (
        order_item_id BIGINT PRIMARY KEY,
        product_id    BIGINT NOT NULL,
        item_qty      DECIMAL(12,3) NOT NULL
    );

    INSERT INTO @line (order_item_id, product_id, item_qty)
    SELECT soi.order_item_id, soi.product_id, CAST(soi.quantity AS DECIMAL(12,3))
    FROM dbo.SalesOrderItem AS soi
    JOIN dbo.Product AS p
      ON p.product_id = soi.product_id
    WHERE soi.order_id = @order_id
      AND ((soi.item_role = 'SELLABLE' AND p.product_type = 'SINGLE')
           OR soi.item_role = 'COMPONENT');

    IF NOT EXISTS (SELECT 1 FROM @line)
    BEGIN
        THROW 50000, N'sp_lock_order_inventory：订单没有可展开用料的明细，拒绝锁库。', 1;
    END;

    -- 在售但无用料配置的商品会让 BOM 展开结果为空。必须在此报错：静默锁 0 会让
    -- 一笔"无可制作配置"的订单继续走到制作与实扣（见 §8 2026-09-24 变更记录）。
    IF EXISTS (SELECT 1
               FROM @line AS l
               WHERE NOT EXISTS (SELECT 1
                                 FROM dbo.ProductBom AS b
                                 WHERE b.product_id = l.product_id))
    BEGIN
        THROW 50000, N'sp_lock_order_inventory：订单存在无用料配置的在售商品，拒绝锁库并回滚订单创建。', 1;
    END;

    DECLARE @need TABLE
    (
        ingredient_id BIGINT PRIMARY KEY,
        required_qty  DECIMAL(12,3) NOT NULL
    );

    INSERT INTO @need (ingredient_id, required_qty)
    SELECT b.ingredient_id, SUM(b.usage_qty * l.item_qty)
    FROM @line AS l
    JOIN dbo.ProductBom AS b
      ON b.product_id = l.product_id
    GROUP BY b.ingredient_id;

    -- 用量非正会让 LOCK 流水成为 (0, 0)，撞上 CK_InventoryMovement_delta_not_zero；
    -- 这里先给出可读的报错，而不是让约束名出现在错误里。
    IF EXISTS (SELECT 1 FROM @need WHERE required_qty <= 0)
    BEGIN
        THROW 50000, N'sp_lock_order_inventory：用料配置的用量非正，拒绝锁库。', 1;
    END;

    DECLARE @owns_tran BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;

    IF @owns_tran = 1
        BEGIN TRANSACTION;
    ELSE
        SAVE TRANSACTION sp_lock_order_inventory;

    BEGIN TRY
        -- 一次性锁住本单涉及的库存行，再统一校验可用量，避免逐行检查的竞态
        DECLARE @inventory_rows INT;

        SELECT @inventory_rows = COUNT(*)
        FROM dbo.Inventory AS inv WITH (UPDLOCK, HOLDLOCK)
        JOIN @need AS n
          ON n.ingredient_id = inv.ingredient_id;

        IF @inventory_rows <> (SELECT COUNT(*) FROM @need)
        BEGIN
            THROW 50000, N'sp_lock_order_inventory：存在尚未建立库存记录的原料，拒绝锁库。', 1;
        END;

        IF EXISTS (SELECT 1
                   FROM dbo.Inventory AS inv WITH (UPDLOCK, HOLDLOCK)
                   JOIN @need AS n
                     ON n.ingredient_id = inv.ingredient_id
                   WHERE inv.on_hand_qty - inv.locked_qty < n.required_qty)
        BEGIN
            THROW 50000, N'sp_lock_order_inventory：可用库存不足，拒绝锁库并回滚订单创建。', 1;
        END;

        UPDATE inv
           SET inv.locked_qty = inv.locked_qty + n.required_qty,
               inv.updated_at = SYSDATETIME()
        FROM dbo.Inventory AS inv
        JOIN @need AS n
          ON n.ingredient_id = inv.ingredient_id;

        INSERT INTO dbo.InventoryMovement
            (ingredient_id, movement_type, on_hand_delta, locked_delta, reference_type, reference_id, moved_at)
        SELECT n.ingredient_id, 'LOCK', 0, n.required_qty, 'ORDER', @order_id, SYSDATETIME()
        FROM @need AS n;

        IF @owns_tran = 1
            COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @owns_tran = 1 AND XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        ELSE IF @owns_tran = 0 AND XACT_STATE() = 1
            ROLLBACK TRANSACTION sp_lock_order_inventory;

        THROW;
    END CATCH;
END;
GO

-- 释放锁定量（§2.3 line 144）：只释放尚未实扣的锁定量，写 RELEASE 流水。
CREATE PROCEDURE dbo.sp_release_order_inventory
    @order_id BIGINT,
    @reason   VARCHAR(20)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @order_id IS NULL OR @reason IS NULL
    BEGIN
        THROW 50000, N'sp_release_order_inventory：@order_id 与 @reason 都不能为 NULL。', 1;
    END;

    IF @reason NOT IN ('CANCEL', 'PAYMENT_TIMEOUT', 'REFUND')
    BEGIN
        THROW 50000, N'sp_release_order_inventory：@reason 只能是 CANCEL、PAYMENT_TIMEOUT 或 REFUND。', 1;
    END;

    IF NOT EXISTS (SELECT 1 FROM dbo.SalesOrder WHERE order_id = @order_id)
    BEGIN
        THROW 50000, N'sp_release_order_inventory：订单不存在，拒绝释放锁定量。', 1;
    END;

    DECLARE @owns_tran BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;

    IF @owns_tran = 1
        BEGIN TRANSACTION;
    ELSE
        SAVE TRANSACTION sp_release_order_inventory;

    BEGIN TRY
        -- 尚未实扣的锁定量 = 本单 LOCK / RELEASE / CONSUME 三类流水的 locked_delta 之和
        DECLARE @release TABLE
        (
            ingredient_id BIGINT PRIMARY KEY,
            release_qty   DECIMAL(12,3) NOT NULL
        );

        INSERT INTO @release (ingredient_id, release_qty)
        SELECT m.ingredient_id, SUM(m.locked_delta)
        FROM dbo.InventoryMovement AS m
        WHERE m.reference_type = 'ORDER'
          AND m.reference_id = @order_id
          AND m.movement_type IN ('LOCK', 'RELEASE', 'CONSUME')
        GROUP BY m.ingredient_id
        HAVING SUM(m.locked_delta) > 0;

        IF NOT EXISTS (SELECT 1 FROM @release)
        BEGIN
            THROW 50000, N'sp_release_order_inventory：本订单没有尚未实扣的锁定量，拒绝重复释放。', 1;
        END;

        DECLARE @inventory_rows INT;

        SELECT @inventory_rows = COUNT(*)
        FROM dbo.Inventory AS inv WITH (UPDLOCK, HOLDLOCK)
        JOIN @release AS r
          ON r.ingredient_id = inv.ingredient_id;

        IF @inventory_rows <> (SELECT COUNT(*) FROM @release)
        BEGIN
            THROW 50000, N'sp_release_order_inventory：存在尚未建立库存记录的原料，拒绝释放锁定量。', 1;
        END;

        IF EXISTS (SELECT 1
                   FROM dbo.Inventory AS inv WITH (UPDLOCK, HOLDLOCK)
                   JOIN @release AS r
                     ON r.ingredient_id = inv.ingredient_id
                   WHERE inv.locked_qty < r.release_qty)
        BEGIN
            THROW 50000, N'sp_release_order_inventory：库存锁定量小于本单待释放量，拒绝释放锁定量。', 1;
        END;

        UPDATE inv
           SET inv.locked_qty = inv.locked_qty - r.release_qty,
               inv.updated_at = SYSDATETIME()
        FROM dbo.Inventory AS inv
        JOIN @release AS r
          ON r.ingredient_id = inv.ingredient_id;

        INSERT INTO dbo.InventoryMovement
            (ingredient_id, movement_type, on_hand_delta, locked_delta, reference_type, reference_id, moved_at)
        SELECT r.ingredient_id, 'RELEASE', 0, -r.release_qty, 'ORDER', @order_id, SYSDATETIME()
        FROM @release AS r;

        -- §5 C-1 line 304 未把释放列入必须写审计的动作，@reason 也没有独立的落库字段。
        -- 处理原则：能唯一定位到启用员工就补记一条审计让取消/超时/退款可区分；定位不到
        -- 则不阻断业务动作，也不写 employee_id 为空的审计（AuditLog.employee_id 非空）。
        DECLARE @actor_employee_id BIGINT;

        SELECT @actor_employee_id = ea.employee_id
        FROM dbo.EmployeeAccount AS ea
        WHERE ea.database_user_name = USER_NAME()
          AND ea.status = 'ACTIVE';

        IF @actor_employee_id IS NOT NULL
        BEGIN
            DECLARE @detail_json NVARCHAR(MAX) =
            (
                SELECT @reason AS reason
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
            );

            EXEC dbo.sp_write_audit_log
                 @employee_id = @actor_employee_id,
                 @action_name = 'RELEASE_ORDER_INVENTORY',
                 @entity_name = 'SalesOrder',
                 @entity_id   = @order_id,
                 @detail_json = @detail_json;
        END;

        IF @owns_tran = 1
            COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @owns_tran = 1 AND XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        ELSE IF @owns_tran = 0 AND XACT_STATE() = 1
            ROLLBACK TRANSACTION sp_release_order_inventory;

        THROW;
    END CATCH;
END;
GO

-- 实扣（§2.3 line 145、§5 C-1 line 301）：制作完成时把同等数量从 on_hand_qty 与
-- locked_qty 同时扣减，写 CONSUME 流水，随后按安全库存线刷新补货建议。
CREATE PROCEDURE dbo.sp_consume_order_inventory
    @order_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @order_id IS NULL
    BEGIN
        THROW 50000, N'sp_consume_order_inventory：缺少订单 ID，拒绝实扣。', 1;
    END;

    IF NOT EXISTS (SELECT 1 FROM dbo.SalesOrder WHERE order_id = @order_id)
    BEGIN
        THROW 50000, N'sp_consume_order_inventory：订单不存在，拒绝实扣。', 1;
    END;

    -- 全局约束 line 28：写过程的操作人由 USER_NAME() 解析为启用员工。本过程的实扣会
    -- 触发自动补货建议，而 §5 C-1 line 301 要求其 created_by_employee_id 非空，
    -- 故解析不到时直接拒绝，不写无法归责的库存变化。
    DECLARE @actor_employee_id BIGINT;

    SELECT @actor_employee_id = ea.employee_id
    FROM dbo.EmployeeAccount AS ea
    WHERE ea.database_user_name = USER_NAME()
      AND ea.status = 'ACTIVE';

    IF @actor_employee_id IS NULL
    BEGIN
        THROW 50000, N'sp_consume_order_inventory：当前登录主体未映射到启用员工，拒绝实扣。', 1;
    END;

    DECLARE @owns_tran BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;

    IF @owns_tran = 1
        BEGIN TRANSACTION;
    ELSE
        SAVE TRANSACTION sp_consume_order_inventory;

    BEGIN TRY
        -- 本次实扣量 = 本单尚未实扣的锁定量
        DECLARE @consume TABLE
        (
            ingredient_id BIGINT PRIMARY KEY,
            consume_qty   DECIMAL(12,3) NOT NULL
        );

        INSERT INTO @consume (ingredient_id, consume_qty)
        SELECT m.ingredient_id, SUM(m.locked_delta)
        FROM dbo.InventoryMovement AS m
        WHERE m.reference_type = 'ORDER'
          AND m.reference_id = @order_id
          AND m.movement_type IN ('LOCK', 'RELEASE', 'CONSUME')
        GROUP BY m.ingredient_id
        HAVING SUM(m.locked_delta) > 0;

        IF NOT EXISTS (SELECT 1 FROM @consume)
        BEGIN
            THROW 50000, N'sp_consume_order_inventory：本订单没有待实扣的锁定量，拒绝重复实扣。', 1;
        END;

        DECLARE @inventory_rows INT;

        SELECT @inventory_rows = COUNT(*)
        FROM dbo.Inventory AS inv WITH (UPDLOCK, HOLDLOCK)
        JOIN @consume AS c
          ON c.ingredient_id = inv.ingredient_id;

        IF @inventory_rows <> (SELECT COUNT(*) FROM @consume)
        BEGIN
            THROW 50000, N'sp_consume_order_inventory：存在尚未建立库存记录的原料，拒绝实扣。', 1;
        END;

        -- 实扣同时减少现有量与锁定量，两者都必须够，否则库存会变成负数
        IF EXISTS (SELECT 1
                   FROM dbo.Inventory AS inv WITH (UPDLOCK, HOLDLOCK)
                   JOIN @consume AS c
                     ON c.ingredient_id = inv.ingredient_id
                   WHERE inv.locked_qty < c.consume_qty
                      OR inv.on_hand_qty < c.consume_qty)
        BEGIN
            THROW 50000, N'sp_consume_order_inventory：现有量或锁定量小于待实扣量，拒绝实扣。', 1;
        END;

        UPDATE inv
           SET inv.on_hand_qty = inv.on_hand_qty - c.consume_qty,
               inv.locked_qty   = inv.locked_qty - c.consume_qty,
               inv.updated_at   = SYSDATETIME()
        FROM dbo.Inventory AS inv
        JOIN @consume AS c
          ON c.ingredient_id = inv.ingredient_id;

        INSERT INTO dbo.InventoryMovement
            (ingredient_id, movement_type, on_hand_delta, locked_delta, reference_type, reference_id, moved_at)
        SELECT c.ingredient_id, 'CONSUME', -c.consume_qty, -c.consume_qty, 'ORDER', @order_id, SYSDATETIME()
        FROM @consume AS c;

        -- §5 C-1 line 301：实扣后低于安全库存线的原料生成或更新开放建议。
        -- 待刷新原料逐个取出调用刷新过程，按 ingredient_id 排序以固定加锁顺序。
        DECLARE @pending TABLE (ingredient_id BIGINT PRIMARY KEY);

        INSERT INTO @pending (ingredient_id)
        SELECT c.ingredient_id FROM @consume AS c;

        DECLARE @ingredient_id BIGINT;

        WHILE EXISTS (SELECT 1 FROM @pending)
        BEGIN
            SELECT TOP (1) @ingredient_id = p.ingredient_id
            FROM @pending AS p
            ORDER BY p.ingredient_id;

            DELETE FROM @pending WHERE ingredient_id = @ingredient_id;

            EXEC dbo.sp_refresh_replenishment_suggestion
                 @ingredient_id     = @ingredient_id,
                 @actor_employee_id = @actor_employee_id;
        END;

        IF @owns_tran = 1
            COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @owns_tran = 1 AND XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        ELSE IF @owns_tran = 0 AND XACT_STATE() = 1
            ROLLBACK TRANSACTION sp_consume_order_inventory;

        THROW;
    END CATCH;
END;
GO

-- ============================================================================
-- 批次 5：员工业务角色同步过程（§5 C-1 line 302-303）
-- 职责：把 BusinessRole.role_code 映射为同名数据库角色 role_<code>（§1 line 66 命名
--   约定），同步维护 EmployeeBusinessRole 业务映射与数据库角色成员关系，并写审计。
-- 权限：这三个过程不以 EXECUTE AS OWNER 提权——提权后 USER_NAME() 会变成过程所有者，
--   店长身份就没了——而是在 08_roles_permissions.sql 中由证书用户签名取得
--   ALTER ANY ROLE / ALTER ANY USER（§5 C-1 line 303）。普通店长只持有这三个过程的
--   EXECUTE。⚠ 模块一经 ALTER 签名即失效：改过本批次后必须重跑 08 的 ADD SIGNATURE。
-- 白名单：动态角色名只能来自 7 个固定业务角色。三个过程都先按白名单校验 role_code，
--   再按命名约定拼出 role_<code> 并用 QUOTENAME 包裹，故动态标识符只可能是
--   role_store_manager … role_rider 之一，另有 sys.database_principals 存在性校验兜底。
--   白名单在三个过程里各写一次（SET 批次之间无法共享常量），新增业务角色须三处同改。
-- 边界：过程一律不创建服务器登录名或数据库用户，目标员工必须已由 DBA 建好同名数据库
--   用户；停用员工只撤销数据库角色成员关系与业务映射，不删除员工行本身。
-- 启动引导：09c 让 test_store_manager 用本过程给自己分配 store_manager 业务角色时，
--   业务映射尚未存在；08 已把该用户直接加入 role_store_manager 作为受控引导（§5 C-2
--   line 313、C-3 line 320），故店长身份判定为「已有 store_manager 业务角色 或 已是
--   role_store_manager 数据库角色成员」。
-- 已知操作风险：停用或撤销唯一的店长会让角色同步失去可用入口，计划未要求拦截，故不
--   拦截；恢复只能由 DBA 手工把某个数据库用户加回 role_store_manager。
-- ============================================================================
SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET QUOTED_IDENTIFIER ON;
SET NUMERIC_ROUNDABORT OFF;
GO

-- 分配业务角色（§5 C-1 line 302）：仅对已由 DBA 建立数据库用户的启用员工执行；
-- 目标用户已是该数据库角色成员时不重复 ADD MEMBER，只补业务映射并写审计。
CREATE PROCEDURE dbo.sp_assign_employee_business_role
    @employee_id             BIGINT,
    @business_role_id        BIGINT,
    @assigned_by_employee_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @employee_id IS NULL OR @business_role_id IS NULL OR @assigned_by_employee_id IS NULL
    BEGIN
        THROW 50000, N'sp_assign_employee_business_role：@employee_id、@business_role_id、@assigned_by_employee_id 都不能为 NULL。', 1;
    END;

    -- 店长身份：USER_NAME() 解析为启用员工，且传入的操作人 ID 等于解析结果
    DECLARE @operator_employee_id BIGINT;

    SELECT @operator_employee_id = ea.employee_id
    FROM dbo.EmployeeAccount AS ea
    WHERE ea.database_user_name = USER_NAME()
      AND ea.status = 'ACTIVE';

    IF @operator_employee_id IS NULL
    BEGIN
        THROW 50000, N'sp_assign_employee_business_role：当前登录主体未映射到启用员工，拒绝执行。', 1;
    END;

    IF @assigned_by_employee_id <> @operator_employee_id
    BEGIN
        THROW 50000, N'sp_assign_employee_business_role：传入的授权员工 ID 与当前登录主体解析出的员工不一致，拒绝执行。', 1;
    END;

    IF NOT EXISTS (SELECT 1
                   FROM dbo.EmployeeBusinessRole AS ebr
                   JOIN dbo.BusinessRole AS br
                     ON br.business_role_id = ebr.business_role_id
                   WHERE ebr.employee_id = @operator_employee_id
                     AND br.role_code = 'store_manager'
                     AND br.status = 'ACTIVE')
       AND ISNULL(IS_ROLEMEMBER(N'role_store_manager'), 0) <> 1
    BEGIN
        THROW 50000, N'sp_assign_employee_business_role：仅店长可分配业务角色。', 1;
    END;

    -- 目标员工必须存在、启用，且已由 DBA 建立同名数据库用户
    DECLARE @target_user_name VARCHAR(128), @target_status VARCHAR(20);

    SELECT @target_user_name = ea.database_user_name,
           @target_status    = ea.status
    FROM dbo.EmployeeAccount AS ea
    WHERE ea.employee_id = @employee_id;

    IF @target_user_name IS NULL
    BEGIN
        THROW 50000, N'sp_assign_employee_business_role：目标员工不存在，拒绝分配。', 1;
    END;

    IF @target_status <> 'ACTIVE'
    BEGIN
        THROW 50000, N'sp_assign_employee_business_role：只能为启用员工分配业务角色，请先启用该员工。', 1;
    END;

    IF NOT EXISTS (SELECT 1
                   FROM sys.database_principals AS dp
                   WHERE dp.name = @target_user_name
                     AND dp.type IN ('S', 'U', 'G', 'E'))
    BEGIN
        THROW 50000, N'sp_assign_employee_business_role：目标员工尚未建立同名数据库用户，拒绝分配（本过程不创建登录名或用户，需由 DBA 先建立）。', 1;
    END;

    -- 业务角色必须存在、启用，且其 role_code 在固定白名单内
    DECLARE @role_code VARCHAR(20), @role_status VARCHAR(20);

    SELECT @role_code   = br.role_code,
           @role_status = br.status
    FROM dbo.BusinessRole AS br
    WHERE br.business_role_id = @business_role_id;

    IF @role_code IS NULL
    BEGIN
        THROW 50000, N'sp_assign_employee_business_role：业务角色不存在，拒绝分配。', 1;
    END;

    IF @role_status <> 'ACTIVE'
    BEGIN
        THROW 50000, N'sp_assign_employee_business_role：业务角色已停用，拒绝分配。', 1;
    END;

    IF @role_code NOT IN (N'store_manager', N'shift_manager', N'cashier',
                          N'chef', N'packer', N'waiter', N'rider')
    BEGIN
        THROW 50000, N'sp_assign_employee_business_role：业务角色编码不在权限白名单内，拒绝分配。', 1;
    END;

    DECLARE @db_role_name SYSNAME = N'role_' + @role_code;

    IF NOT EXISTS (SELECT 1
                   FROM sys.database_principals AS dp
                   WHERE dp.name = @db_role_name
                     AND dp.type = 'R')
    BEGIN
        THROW 50000, N'sp_assign_employee_business_role：对应的数据库角色不存在，请先部署 08_roles_permissions.sql。', 1;
    END;

    DECLARE @owns_tran BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;

    IF @owns_tran = 1
        BEGIN TRANSACTION;
    ELSE
        SAVE TRANSACTION sp_assign_employee_business_role;

    BEGIN TRY
        DECLARE @member_added BIT = 0, @mapping_inserted BIT = 0;

        IF NOT EXISTS (SELECT 1
                       FROM sys.database_role_members AS drm
                       JOIN sys.database_principals AS r
                         ON r.principal_id = drm.role_principal_id
                       JOIN sys.database_principals AS m
                         ON m.principal_id = drm.member_principal_id
                       WHERE r.name = @db_role_name
                         AND m.name = @target_user_name)
        BEGIN
            -- EXEC(...) 的括号内不允许出现函数调用，动态语句必须先算进变量
            DECLARE @add_member_sql NVARCHAR(300) =
                N'ALTER ROLE ' + QUOTENAME(@db_role_name)
              + N' ADD MEMBER ' + QUOTENAME(@target_user_name) + N';';

            EXEC (@add_member_sql);
            SET @member_added = 1;
        END;

        IF NOT EXISTS (SELECT 1
                       FROM dbo.EmployeeBusinessRole
                       WHERE employee_id = @employee_id
                         AND business_role_id = @business_role_id)
        BEGIN
            INSERT INTO dbo.EmployeeBusinessRole
                (employee_id, business_role_id, assigned_by_employee_id, assigned_at)
            VALUES
                (@employee_id, @business_role_id, @operator_employee_id, SYSDATETIME());
            SET @mapping_inserted = 1;
        END;

        DECLARE @detail_json NVARCHAR(MAX) =
        (
            SELECT @target_user_name AS employee_database_user,
                   @role_code        AS role_code,
                   @db_role_name     AS database_role,
                   @member_added     AS member_added,
                   @mapping_inserted AS mapping_inserted
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
        );

        EXEC dbo.sp_write_audit_log
             @employee_id = @operator_employee_id,
             @action_name = 'ASSIGN_EMPLOYEE_BUSINESS_ROLE',
             @entity_name = 'EmployeeBusinessRole',
             @entity_id   = @employee_id,
             @detail_json = @detail_json;

        IF @owns_tran = 1
            COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @owns_tran = 1 AND XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        ELSE IF @owns_tran = 0 AND XACT_STATE() = 1
            ROLLBACK TRANSACTION sp_assign_employee_business_role;

        THROW;
    END CATCH;
END;
GO

-- 撤销业务角色（§5 C-1 line 302）：同步 DROP MEMBER 与删除业务映射；
-- 两者都不存在时视为误操作抛错，不做静默成功。
CREATE PROCEDURE dbo.sp_revoke_employee_business_role
    @employee_id          BIGINT,
    @business_role_id     BIGINT,
    @operator_employee_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @employee_id IS NULL OR @business_role_id IS NULL OR @operator_employee_id IS NULL
    BEGIN
        THROW 50000, N'sp_revoke_employee_business_role：@employee_id、@business_role_id、@operator_employee_id 都不能为 NULL。', 1;
    END;

    DECLARE @operator_id BIGINT;

    SELECT @operator_id = ea.employee_id
    FROM dbo.EmployeeAccount AS ea
    WHERE ea.database_user_name = USER_NAME()
      AND ea.status = 'ACTIVE';

    IF @operator_id IS NULL
    BEGIN
        THROW 50000, N'sp_revoke_employee_business_role：当前登录主体未映射到启用员工，拒绝执行。', 1;
    END;

    IF @operator_employee_id <> @operator_id
    BEGIN
        THROW 50000, N'sp_revoke_employee_business_role：传入的操作员工 ID 与当前登录主体解析出的员工不一致，拒绝执行。', 1;
    END;

    IF NOT EXISTS (SELECT 1
                   FROM dbo.EmployeeBusinessRole AS ebr
                   JOIN dbo.BusinessRole AS br
                     ON br.business_role_id = ebr.business_role_id
                   WHERE ebr.employee_id = @operator_id
                     AND br.role_code = 'store_manager'
                     AND br.status = 'ACTIVE')
       AND ISNULL(IS_ROLEMEMBER(N'role_store_manager'), 0) <> 1
    BEGIN
        THROW 50000, N'sp_revoke_employee_business_role：仅店长可撤销业务角色。', 1;
    END;

    DECLARE @target_user_name VARCHAR(128);

    SELECT @target_user_name = ea.database_user_name
    FROM dbo.EmployeeAccount AS ea
    WHERE ea.employee_id = @employee_id;

    IF @target_user_name IS NULL
    BEGIN
        THROW 50000, N'sp_revoke_employee_business_role：目标员工不存在，拒绝撤销。', 1;
    END;

    -- 业务角色允许已停用：停用的角色同样需要清理成员关系，故只校验存在性与白名单
    DECLARE @role_code VARCHAR(20);

    SELECT @role_code = br.role_code
    FROM dbo.BusinessRole AS br
    WHERE br.business_role_id = @business_role_id;

    IF @role_code IS NULL
    BEGIN
        THROW 50000, N'sp_revoke_employee_business_role：业务角色不存在，拒绝撤销。', 1;
    END;

    IF @role_code NOT IN (N'store_manager', N'shift_manager', N'cashier',
                          N'chef', N'packer', N'waiter', N'rider')
    BEGIN
        THROW 50000, N'sp_revoke_employee_business_role：业务角色编码不在权限白名单内，拒绝撤销。', 1;
    END;

    DECLARE @db_role_name SYSNAME = N'role_' + @role_code;

    IF NOT EXISTS (SELECT 1
                   FROM sys.database_principals AS dp
                   WHERE dp.name = @db_role_name
                     AND dp.type = 'R')
    BEGIN
        THROW 50000, N'sp_revoke_employee_business_role：对应的数据库角色不存在，请先部署 08_roles_permissions.sql。', 1;
    END;

    DECLARE @owns_tran BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;

    IF @owns_tran = 1
        BEGIN TRANSACTION;
    ELSE
        SAVE TRANSACTION sp_revoke_employee_business_role;

    BEGIN TRY
        DECLARE @member_dropped BIT = 0, @mapping_deleted BIT = 0;

        IF EXISTS (SELECT 1
                   FROM sys.database_role_members AS drm
                   JOIN sys.database_principals AS r
                     ON r.principal_id = drm.role_principal_id
                   JOIN sys.database_principals AS m
                     ON m.principal_id = drm.member_principal_id
                   WHERE r.name = @db_role_name
                     AND m.name = @target_user_name)
        BEGIN
            -- 同上：动态语句先算进变量，EXEC(...) 括号里不能放函数
            DECLARE @drop_member_sql NVARCHAR(300) =
                N'ALTER ROLE ' + QUOTENAME(@db_role_name)
              + N' DROP MEMBER ' + QUOTENAME(@target_user_name) + N';';

            EXEC (@drop_member_sql);
            SET @member_dropped = 1;
        END;

        IF EXISTS (SELECT 1
                   FROM dbo.EmployeeBusinessRole
                   WHERE employee_id = @employee_id
                     AND business_role_id = @business_role_id)
        BEGIN
            DELETE FROM dbo.EmployeeBusinessRole
            WHERE employee_id = @employee_id
              AND business_role_id = @business_role_id;
            SET @mapping_deleted = 1;
        END;

        IF @member_dropped = 0 AND @mapping_deleted = 0
        BEGIN
            THROW 50000, N'sp_revoke_employee_business_role：该员工并未拥有此业务角色，无可撤销。', 1;
        END;

        DECLARE @detail_json NVARCHAR(MAX) =
        (
            SELECT @target_user_name AS employee_database_user,
                   @role_code        AS role_code,
                   @db_role_name     AS database_role,
                   @member_dropped   AS member_dropped,
                   @mapping_deleted  AS mapping_deleted
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
        );

        EXEC dbo.sp_write_audit_log
             @employee_id = @operator_id,
             @action_name = 'REVOKE_EMPLOYEE_BUSINESS_ROLE',
             @entity_name = 'EmployeeBusinessRole',
             @entity_id   = @employee_id,
             @detail_json = @detail_json;

        IF @owns_tran = 1
            COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @owns_tran = 1 AND XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        ELSE IF @owns_tran = 0 AND XACT_STATE() = 1
            ROLLBACK TRANSACTION sp_revoke_employee_business_role;

        THROW;
    END CATCH;
END;
GO

-- 变更员工状态（§5 C-1 line 302）：停用时必须撤销其全部 role_* 成员关系并清掉业务
-- 映射；重新启用不自动恢复业务角色，需由店长重新分配。
CREATE PROCEDURE dbo.sp_update_employee_status
    @employee_id          BIGINT,
    @status               VARCHAR(20),
    @operator_employee_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @employee_id IS NULL OR @status IS NULL OR @operator_employee_id IS NULL
    BEGIN
        THROW 50000, N'sp_update_employee_status：@employee_id、@status、@operator_employee_id 都不能为 NULL。', 1;
    END;

    IF @status NOT IN ('ACTIVE', 'INACTIVE')
    BEGIN
        THROW 50000, N'sp_update_employee_status：@status 取值不合法，必须符合 CK_EmployeeAccount_status 的允许取值。', 1;
    END;

    DECLARE @operator_id BIGINT;

    SELECT @operator_id = ea.employee_id
    FROM dbo.EmployeeAccount AS ea
    WHERE ea.database_user_name = USER_NAME()
      AND ea.status = 'ACTIVE';

    IF @operator_id IS NULL
    BEGIN
        THROW 50000, N'sp_update_employee_status：当前登录主体未映射到启用员工，拒绝执行。', 1;
    END;

    IF @operator_employee_id <> @operator_id
    BEGIN
        THROW 50000, N'sp_update_employee_status：传入的操作员工 ID 与当前登录主体解析出的员工不一致，拒绝执行。', 1;
    END;

    IF NOT EXISTS (SELECT 1
                   FROM dbo.EmployeeBusinessRole AS ebr
                   JOIN dbo.BusinessRole AS br
                     ON br.business_role_id = ebr.business_role_id
                   WHERE ebr.employee_id = @operator_id
                     AND br.role_code = 'store_manager'
                     AND br.status = 'ACTIVE')
       AND ISNULL(IS_ROLEMEMBER(N'role_store_manager'), 0) <> 1
    BEGIN
        THROW 50000, N'sp_update_employee_status：仅店长可变更员工状态。', 1;
    END;

    DECLARE @target_user_name VARCHAR(128), @status_before VARCHAR(20);

    SELECT @target_user_name = ea.database_user_name,
           @status_before    = ea.status
    FROM dbo.EmployeeAccount AS ea
    WHERE ea.employee_id = @employee_id;

    IF @target_user_name IS NULL
    BEGIN
        THROW 50000, N'sp_update_employee_status：目标员工不存在，拒绝变更。', 1;
    END;

    DECLARE @owns_tran BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;

    IF @owns_tran = 1
        BEGIN TRANSACTION;
    ELSE
        SAVE TRANSACTION sp_update_employee_status;

    BEGIN TRY
        DECLARE @revoked_role_codes VARCHAR(500) = '';

        IF @status = 'INACTIVE'
        BEGIN
            -- 停用即撤销全部 role_* 成员关系；一条动态批次完成，角色名取自白名单 IN 列表
            DECLARE @drop_sql NVARCHAR(MAX) =
            (
                SELECT STRING_AGG(CAST(N'ALTER ROLE ' + QUOTENAME(r.name)
                                       + N' DROP MEMBER ' + QUOTENAME(@target_user_name) + N';' AS NVARCHAR(MAX)), N'')
                FROM sys.database_role_members AS drm
                JOIN sys.database_principals AS r
                  ON r.principal_id = drm.role_principal_id
                JOIN sys.database_principals AS m
                  ON m.principal_id = drm.member_principal_id
                WHERE m.name = @target_user_name
                  AND r.name IN (N'role_store_manager', N'role_shift_manager', N'role_cashier',
                                 N'role_chef', N'role_packer', N'role_waiter', N'role_rider')
            );

            SELECT @revoked_role_codes = ISNULL(STRING_AGG(r.name, N',')
                                                WITHIN GROUP (ORDER BY r.name), '')
            FROM sys.database_role_members AS drm
            JOIN sys.database_principals AS r
              ON r.principal_id = drm.role_principal_id
            JOIN sys.database_principals AS m
              ON m.principal_id = drm.member_principal_id
            WHERE m.name = @target_user_name
              AND r.name IN (N'role_store_manager', N'role_shift_manager', N'role_cashier',
                             N'role_chef', N'role_packer', N'role_waiter', N'role_rider');

            IF @drop_sql IS NOT NULL AND @drop_sql <> N''
                EXEC (@drop_sql);

            DELETE FROM dbo.EmployeeBusinessRole
            WHERE employee_id = @employee_id;
        END;

        -- 审计先于状态更新：sp_write_audit_log 自身要求调用方当前是启用员工，
        -- 若先停用，操作人是在停用自己时就解析不到了；同一事务内先后不影响原子性。
        DECLARE @detail_json NVARCHAR(MAX) =
        (
            SELECT @target_user_name   AS employee_database_user,
                   @status_before      AS status_before,
                   @status             AS status_after,
                   @revoked_role_codes AS revoked_role_codes
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
        );

        EXEC dbo.sp_write_audit_log
             @employee_id = @operator_id,
             @action_name = 'UPDATE_EMPLOYEE_STATUS',
             @entity_name = 'EmployeeAccount',
             @entity_id   = @employee_id,
             @detail_json = @detail_json;

        UPDATE dbo.EmployeeAccount
           SET status = @status
         WHERE employee_id = @employee_id;

        IF @owns_tran = 1
            COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @owns_tran = 1 AND XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        ELSE IF @owns_tran = 0 AND XACT_STATE() = 1
            ROLLBACK TRANSACTION sp_update_employee_status;

        THROW;
    END CATCH;
END;
GO
