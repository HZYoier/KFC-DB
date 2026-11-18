-- ============================================================================
-- 25c_tx_replenishment_receipt.sql — 补货入库事务实验（成员 C；2026-11-18）
-- 目的：覆盖“建议 -> 提交 -> 审批生成采购单 -> 两次收货”的提交路径，
--       以及“第二次收货超收 -> 整个事务回滚”的失败路径；补重复收货拒绝。
-- 前置：v1.0 已部署，20_schema_v1_1.sql 与 22c_inventory_triggers.sql 已应用；
--       test_store_manager / test_shift_manager 已分配业务角色。
-- 用法（仓库根目录；Mode 必须显式给出）：
--   提交路径（在临时副本库上执行，会留下本脚本创建的测试原料/采购单）：
--     sqlcmd -S '.\SQLEXPRESS' -E -C -f 65001 -b -d KFC_DB_25C
--       -v Mode=commit -i sql/stage3/25c_tx_replenishment_receipt.sql
--   回滚路径（可在主库执行，最后回滚全部测试数据）：
--     sqlcmd ... -v Mode=rollback -i sql/stage3/25c_tx_replenishment_receipt.sql
-- 不写死原料/员工 ID：每次创建唯一的测试原料；只在事务内改库存。
-- 依据：计划 §6.3、R3-03；week12-handoff §1/§3。
-- 错误码：54930 前置/模式、54931 夹具、54998 有失败、54999 分母不足；
--         sp_receive_inventory 的原始 50000 文案由本脚本断言。
-- ============================================================================
:on error exit
-- 本脚本不写 USE：提交路径要在临时副本库上执行，数据库由 -d 指定。
-- 只允许 KFC_DB 或 KFC_DB_* 临时副本，避免误连 master。
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF DB_NAME() <> N'KFC_DB' AND DB_NAME() NOT LIKE N'KFC_DB[_]%'
    THROW 54930, N'25c: run against KFC_DB or a KFC_DB_* copy (pass -d).', 1;

DECLARE @Mode VARCHAR(10) = LOWER(LTRIM(RTRIM('$(Mode)')));
IF @Mode NOT IN ('commit', 'rollback')
    THROW 54930, N'25c: Mode must be commit or rollback.', 1;

IF OBJECT_ID(N'dbo.sp_create_replenishment_suggestion', N'P') IS NULL
   OR OBJECT_ID(N'dbo.sp_submit_replenishment_suggestion', N'P') IS NULL
   OR OBJECT_ID(N'dbo.sp_approve_replenishment_suggestion', N'P') IS NULL
   OR OBJECT_ID(N'dbo.sp_receive_inventory', N'P') IS NULL
    THROW 54930, N'25c: v1.0 replenishment procedures are missing.', 1;
IF OBJECT_ID(N'dbo.InventoryAudit', N'U') IS NULL
    THROW 54930, N'25c: InventoryAudit is missing; apply 20_schema_v1_1.sql and 22c first.', 1;

DECLARE @emp_store BIGINT =
    (SELECT employee_id FROM dbo.EmployeeAccount
     WHERE database_user_name = N'test_store_manager' AND status = 'ACTIVE');
DECLARE @emp_shift BIGINT =
    (SELECT employee_id FROM dbo.EmployeeAccount
     WHERE database_user_name = N'test_shift_manager' AND status = 'ACTIVE');
IF @emp_store IS NULL OR @emp_shift IS NULL
    THROW 54931, N'25c: test_store_manager/test_shift_manager fixtures are missing.', 1;

DECLARE @suffix VARCHAR(32) = REPLACE(CONVERT(VARCHAR(36), NEWID()), '-', '');
DECLARE @ingredient_id BIGINT, @suggestion_id BIGINT, @purchase_order_id BIGINT;
DECLARE @on_hand_before DECIMAL(12,3) = 100.000;
DECLARE @first_qty DECIMAL(12,3) = 4.000;
DECLARE @second_qty DECIMAL(12,3) = 6.000;
DECLARE @over_qty DECIMAL(12,3) = 7.000;
DECLARE @err INT, @msg NVARCHAR(2048), @imp BIT;
DECLARE @pass INT = 0, @fail INT = 0;
DECLARE @committed BIT = 0, @rolled_back BIT = 0;

BEGIN TRANSACTION;
BEGIN TRY
    INSERT dbo.Ingredient (ingredient_name, unit_name, safety_stock_qty, status)
    VALUES (N'C25-' + @suffix, N'kg', 0.000, 'ACTIVE');
    SET @ingredient_id = SCOPE_IDENTITY();

    INSERT dbo.Inventory (ingredient_id, on_hand_qty, locked_qty, updated_at)
    VALUES (@ingredient_id, @on_hand_before, 0.000, SYSDATETIME());

    -- 1. 夹具库存
    IF EXISTS (SELECT 1 FROM dbo.Inventory
               WHERE ingredient_id = @ingredient_id AND on_hand_qty = @on_hand_before)
        SET @pass += 1;
    ELSE
        SET @fail += 1;

    -- 2. 值班经理创建 PENDING 建议
    EXECUTE AS USER = N'test_shift_manager'; SET @imp = 1;
    EXEC dbo.sp_create_replenishment_suggestion
         @ingredient_id = @ingredient_id, @suggested_qty = 10.000, @employee_id = @emp_shift;
    REVERT; SET @imp = 0;

    SELECT @suggestion_id = MAX(replenishment_suggestion_id)
    FROM dbo.ReplenishmentSuggestion
    WHERE ingredient_id = @ingredient_id AND suggestion_status = 'PENDING';
    IF @suggestion_id IS NOT NULL
        SET @pass += 1;
    ELSE
        SET @fail += 1;

    -- 3. 提交建议
    EXECUTE AS USER = N'test_shift_manager'; SET @imp = 1;
    EXEC dbo.sp_submit_replenishment_suggestion
         @suggestion_id = @suggestion_id, @employee_id = @emp_shift;
    REVERT; SET @imp = 0;
    IF EXISTS (SELECT 1 FROM dbo.ReplenishmentSuggestion
               WHERE replenishment_suggestion_id = @suggestion_id
                 AND suggestion_status = 'SUBMITTED')
        SET @pass += 1;
    ELSE
        SET @fail += 1;

    -- 4. 店长审批，同事务生成 APPROVED 采购单
    EXECUTE AS USER = N'test_store_manager'; SET @imp = 1;
    EXEC dbo.sp_approve_replenishment_suggestion
         @suggestion_id = @suggestion_id, @manager_employee_id = @emp_store;
    REVERT; SET @imp = 0;

    SELECT @purchase_order_id = po.purchase_order_id
    FROM dbo.PurchaseOrder AS po
    WHERE po.replenishment_suggestion_id = @suggestion_id;
    IF @purchase_order_id IS NOT NULL
       AND EXISTS (SELECT 1 FROM dbo.PurchaseOrder
                   WHERE purchase_order_id = @purchase_order_id
                     AND purchase_status = 'APPROVED')
       AND EXISTS (SELECT 1 FROM dbo.ReplenishmentSuggestion
                   WHERE replenishment_suggestion_id = @suggestion_id
                     AND suggestion_status = 'APPROVED')
        SET @pass += 1;
    ELSE
        SET @fail += 1;

    -- 5. 第一次收货 4.000：部分到货
    EXECUTE AS USER = N'test_shift_manager'; SET @imp = 1;
    EXEC dbo.sp_receive_inventory
         @purchase_order_id = @purchase_order_id, @employee_id = @emp_shift,
         @received_qty = @first_qty;
    REVERT; SET @imp = 0;

    IF EXISTS (SELECT 1 FROM dbo.PurchaseOrder
               WHERE purchase_order_id = @purchase_order_id
                 AND purchase_status = 'PARTIALLY_RECEIVED')
        SET @pass += 1;
    ELSE
        SET @fail += 1;

    IF (SELECT on_hand_qty FROM dbo.Inventory WHERE ingredient_id = @ingredient_id)
       = @on_hand_before + @first_qty
        SET @pass += 1;
    ELSE
        SET @fail += 1;

    IF (SELECT received_qty FROM dbo.PurchaseOrderItem
        WHERE purchase_order_id = @purchase_order_id) = @first_qty
        SET @pass += 1;
    ELSE
        SET @fail += 1;

    IF EXISTS (SELECT 1 FROM dbo.InventoryMovement
               WHERE ingredient_id = @ingredient_id
                 AND movement_type = 'RECEIPT'
                 AND on_hand_delta = @first_qty
                 AND reference_type = 'PURCHASE_ORDER'
                 AND reference_id = @purchase_order_id)
        SET @pass += 1;
    ELSE
        SET @fail += 1;

    IF @Mode = N'commit'
    BEGIN
        -- 6. 第二次收货 6.000：全部到货并关闭
        EXECUTE AS USER = N'test_shift_manager'; SET @imp = 1;
        EXEC dbo.sp_receive_inventory
             @purchase_order_id = @purchase_order_id, @employee_id = @emp_shift,
             @received_qty = @second_qty;
        REVERT; SET @imp = 0;

        IF EXISTS (SELECT 1 FROM dbo.PurchaseOrder
                   WHERE purchase_order_id = @purchase_order_id
                     AND purchase_status = 'CLOSED')
            SET @pass += 1;
        ELSE
            SET @fail += 1;

        IF (SELECT on_hand_qty FROM dbo.Inventory WHERE ingredient_id = @ingredient_id)
           = @on_hand_before + @first_qty + @second_qty
            SET @pass += 1;
        ELSE
            SET @fail += 1;

        IF (SELECT received_qty FROM dbo.PurchaseOrderItem
            WHERE purchase_order_id = @purchase_order_id)
           = @first_qty + @second_qty
            SET @pass += 1;
        ELSE
            SET @fail += 1;

        IF EXISTS (SELECT 1 FROM dbo.ReplenishmentSuggestion
                   WHERE replenishment_suggestion_id = @suggestion_id
                     AND suggestion_status = 'CLOSED')
            SET @pass += 1;
        ELSE
            SET @fail += 1;

        IF (SELECT COUNT(*) FROM dbo.AuditLog
            WHERE action_name = 'RECEIVE_INVENTORY' AND entity_id = @purchase_order_id) = 2
            SET @pass += 1;
        ELSE
            SET @fail += 1;

        IF @fail > 0
            THROW 54998, N'25c commit path has failed assertions before COMMIT.', 1;

        COMMIT TRANSACTION;
        SET @committed = 1;
    END
    ELSE
    BEGIN
        -- 7. 回滚路径：第二次收货超收，期望 50000；随后回滚整个外层事务
        SET @err = NULL; SET @msg = NULL; SET @imp = 0;
        BEGIN TRY
            EXECUTE AS USER = N'test_shift_manager'; SET @imp = 1;
            EXEC dbo.sp_receive_inventory
                 @purchase_order_id = @purchase_order_id, @employee_id = @emp_shift,
                 @received_qty = @over_qty;
            REVERT; SET @imp = 0;
        END TRY
        BEGIN CATCH
            SET @err = ERROR_NUMBER(); SET @msg = ERROR_MESSAGE();
            IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
            IF @imp = 1 REVERT;
            SET @imp = 0;
        END CATCH;

        IF @err = 50000 AND @msg LIKE N'%不能超过未收数量%'
            SET @pass += 1;
        ELSE
            SET @fail += 1;

        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        SET @rolled_back = 1;
    END
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    IF @imp = 1 REVERT;
    THROW;
END CATCH;

-- 提交路径的拒绝路径：单据已关闭、单据不存在、数量非正
IF @committed = 1
BEGIN
    SET @err = NULL; SET @msg = NULL; SET @imp = 0;
    BEGIN TRY
        EXECUTE AS USER = N'test_shift_manager'; SET @imp = 1;
        EXEC dbo.sp_receive_inventory @purchase_order_id = @purchase_order_id,
             @employee_id = @emp_shift, @received_qty = NULL;
        REVERT; SET @imp = 0;
    END TRY
    BEGIN CATCH
        SET @err = ERROR_NUMBER(); SET @msg = ERROR_MESSAGE();
        IF @imp = 1 REVERT; SET @imp = 0;
    END CATCH;
    IF @err = 50000 AND @msg LIKE N'%只允许对 APPROVED 或 PARTIALLY_RECEIVED%'
        SET @pass += 1;
    ELSE
        SET @fail += 1;

    IF (SELECT on_hand_qty FROM dbo.Inventory WHERE ingredient_id = @ingredient_id)
       = @on_hand_before + @first_qty + @second_qty
        SET @pass += 1;
    ELSE
        SET @fail += 1;

    SET @err = NULL; SET @msg = NULL; SET @imp = 0;
    BEGIN TRY
        EXECUTE AS USER = N'test_shift_manager'; SET @imp = 1;
        EXEC dbo.sp_receive_inventory @purchase_order_id = 999999999,
             @employee_id = @emp_shift, @received_qty = 1.000;
        REVERT; SET @imp = 0;
    END TRY
    BEGIN CATCH
        SET @err = ERROR_NUMBER(); SET @msg = ERROR_MESSAGE();
        IF @imp = 1 REVERT; SET @imp = 0;
    END CATCH;
    IF @err = 50000 AND @msg LIKE N'%采购单不存在%'
        SET @pass += 1;
    ELSE
        SET @fail += 1;

    SET @err = NULL; SET @msg = NULL; SET @imp = 0;
    BEGIN TRY
        EXECUTE AS USER = N'test_shift_manager'; SET @imp = 1;
        EXEC dbo.sp_receive_inventory @purchase_order_id = @purchase_order_id,
             @employee_id = @emp_shift, @received_qty = 0.000;
        REVERT; SET @imp = 0;
    END TRY
    BEGIN CATCH
        SET @err = ERROR_NUMBER(); SET @msg = ERROR_MESSAGE();
        IF @imp = 1 REVERT; SET @imp = 0;
    END CATCH;
    IF @err = 50000 AND @msg LIKE N'%本次收货量必须大于零%'
        SET @pass += 1;
    ELSE
        SET @fail += 1;

    IF @@TRANCOUNT = 0
        SET @pass += 1;
    ELSE
        SET @fail += 1;
END

-- 回滚路径：部分收货、建议、采购单、库存、流水、审计全部回滚
IF @rolled_back = 1
BEGIN
    IF NOT EXISTS (SELECT 1 FROM dbo.Ingredient WHERE ingredient_id = @ingredient_id)
        SET @pass += 1;
    ELSE
        SET @fail += 1;

    IF NOT EXISTS (SELECT 1 FROM dbo.Inventory WHERE ingredient_id = @ingredient_id)
        SET @pass += 1;
    ELSE
        SET @fail += 1;

    IF NOT EXISTS (SELECT 1 FROM dbo.ReplenishmentSuggestion WHERE ingredient_id = @ingredient_id)
       AND NOT EXISTS (SELECT 1 FROM dbo.PurchaseOrder WHERE purchase_order_id = @purchase_order_id)
        SET @pass += 1;
    ELSE
        SET @fail += 1;

    IF NOT EXISTS (SELECT 1 FROM dbo.InventoryMovement WHERE ingredient_id = @ingredient_id)
       AND NOT EXISTS (SELECT 1 FROM dbo.InventoryAudit WHERE ingredient_id = @ingredient_id)
       AND NOT EXISTS (SELECT 1 FROM dbo.AuditLog WHERE entity_id = @purchase_order_id
                       AND action_name IN ('RECEIVE_INVENTORY'))
        SET @pass += 1;
    ELSE
        SET @fail += 1;

    IF @@TRANCOUNT = 0
        SET @pass += 1;
    ELSE
        SET @fail += 1;
END

DECLARE @total INT = @pass + @fail;
DECLARE @expected INT = CASE WHEN @Mode = N'commit' THEN 18 ELSE 14 END;
PRINT CONCAT(N'RESULT: c-transaction replenishment mode=', @Mode,
             N' pass=', @pass, N' fail=', @fail, N' total=', @total);
IF @total <> @expected
    THROW 54999, N'25c 分母不足：实际断言数与模式预期不一致。', 1;
IF @fail > 0
    THROW 54998, N'25c 补货入库事务存在失败断言。', 1;
GO
