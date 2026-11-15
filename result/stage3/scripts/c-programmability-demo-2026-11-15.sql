-- ============================================================================
-- c-programmability-demo-2026-11-15.sql — C 域 3.1 证据演示（成员 C）
-- 前置：KFC_DB 已部署 v0.1，并已执行 20_schema_v1_1.sql、21c_inventory_programmability.sql、
--       22c_inventory_triggers.sql。
-- 运行：
--   sqlcmd -S '.\SQLEXPRESS' -E -C -f 65001 -b -W -d KFC_DB -i result/stage3/scripts/c-programmability-demo-2026-11-15.sql
-- 说明：只演示输入/预期/实际/错误消息；写操作在事务内回滚，不留业务数据。
-- ============================================================================
:on error exit
USE KFC_DB;
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

DECLARE @ingredient_id BIGINT, @on_hand DECIMAL(12,3), @locked DECIMAL(12,3), @available DECIMAL(12,3);
DECLARE @emp_store BIGINT, @emp_shift BIGINT;

SELECT TOP (1)
       @ingredient_id = inv.ingredient_id,
       @on_hand = inv.on_hand_qty,
       @locked = inv.locked_qty,
       @available = CAST(inv.on_hand_qty - inv.locked_qty AS DECIMAL(12,3))
FROM dbo.Inventory AS inv
JOIN dbo.Ingredient AS i ON i.ingredient_id = inv.ingredient_id
WHERE i.status = 'ACTIVE'
  AND inv.on_hand_qty >= inv.locked_qty
  AND inv.on_hand_qty >= 10.000
ORDER BY inv.ingredient_id;

SELECT @emp_store = employee_id FROM dbo.EmployeeAccount
WHERE database_user_name = 'test_store_manager' AND status = 'ACTIVE';
SELECT @emp_shift = employee_id FROM dbo.EmployeeAccount
WHERE database_user_name = 'test_shift_manager' AND status = 'ACTIVE';

IF @ingredient_id IS NULL OR @emp_store IS NULL OR @emp_shift IS NULL
    THROW 54931, N'演示夹具不成立：缺少库存原料或测试员工。', 1;

PRINT N'--- fn_replenishment_qty：可售量口径与目标量 ---';
SELECT
    case_name = N'可售量 + 10',
    ingredient_id = @ingredient_id,
    on_hand_qty = @on_hand,
    locked_qty = @locked,
    available_qty = @available,
    target_qty = @available + 10.000,
    actual_qty = dbo.fn_replenishment_qty(@ingredient_id, @available + 10.000, NULL)
UNION ALL
SELECT N'刚好达到目标', @ingredient_id, @on_hand, @locked, @available, @available,
       dbo.fn_replenishment_qty(@ingredient_id, @available, NULL)
UNION ALL
SELECT N'原料不存在', 999999999, NULL, NULL, NULL, 10.000,
       dbo.fn_replenishment_qty(999999999, 10.000, NULL)
UNION ALL
SELECT N'目标量为负按 NULL', @ingredient_id, @on_hand, @locked, @available, -1.000,
       dbo.fn_replenishment_qty(@ingredient_id, -1.000, NULL);

PRINT N'--- sp_adjust_inventory：反例的 ERROR_NUMBER / ERROR_MESSAGE ---';
DECLARE @err INT, @msg NVARCHAR(2048), @imp BIT;
DECLARE @missing_id BIGINT = 999999999;
DECLARE @insufficient_delta DECIMAL(12,3) = -(@on_hand + 1.000);

SET @err = NULL; SET @msg = NULL; SET @imp = 0;
BEGIN TRY
    EXECUTE AS USER = N'test_store_manager'; SET @imp = 1;
    EXEC dbo.sp_adjust_inventory @ingredient_id = @missing_id, @on_hand_delta = 1.000,
                                 @employee_id = @emp_store, @reason = N'demo missing';
    REVERT; SET @imp = 0;
END TRY
BEGIN CATCH
    SET @err = ERROR_NUMBER(); SET @msg = ERROR_MESSAGE();
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    IF @imp = 1 REVERT;
    SET @imp = 0;
END CATCH;
SELECT case_name = N'原料不存在', expected_error = 54307, actual_error = @err, actual_message = @msg;

SET @err = NULL; SET @msg = NULL; SET @imp = 0;
BEGIN TRY
    EXECUTE AS USER = N'test_store_manager'; SET @imp = 1;
    EXEC dbo.sp_adjust_inventory @ingredient_id = @ingredient_id, @on_hand_delta = @insufficient_delta,
                                 @employee_id = @emp_store, @reason = N'demo insufficient';
    REVERT; SET @imp = 0;
END TRY
BEGIN CATCH
    SET @err = ERROR_NUMBER(); SET @msg = ERROR_MESSAGE();
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    IF @imp = 1 REVERT;
    SET @imp = 0;
END CATCH;
SELECT case_name = N'调整后为负', expected_error = 54308, actual_error = @err, actual_message = @msg;

SET @err = NULL; SET @msg = NULL; SET @imp = 0;
BEGIN TRY
    EXECUTE AS USER = N'test_store_manager'; SET @imp = 1;
    EXEC dbo.sp_adjust_inventory @ingredient_id = @ingredient_id, @on_hand_delta = 1.000,
                                 @employee_id = @emp_shift, @reason = N'demo mismatch';
    REVERT; SET @imp = 0;
END TRY
BEGIN CATCH
    SET @err = ERROR_NUMBER(); SET @msg = ERROR_MESSAGE();
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    IF @imp = 1 REVERT;
    SET @imp = 0;
END CATCH;
SELECT case_name = N'员工不匹配', expected_error = 54305, actual_error = @err, actual_message = @msg;

PRINT N'--- sp_adjust_inventory：连续两次成功调用（事务内回滚） ---';
DECLARE @before DECIMAL(12,3), @after DECIMAL(12,3), @movements INT, @audits INT;
DECLARE @step DECIMAL(12,3) = 5.000;
BEGIN TRANSACTION;
BEGIN TRY
    SELECT @before = on_hand_qty FROM dbo.Inventory WHERE ingredient_id = @ingredient_id;
    EXECUTE AS USER = N'test_store_manager'; SET @imp = 1;
    EXEC dbo.sp_adjust_inventory @ingredient_id = @ingredient_id, @on_hand_delta = @step,
                                 @employee_id = @emp_store, @reason = N'demo success first';
    EXEC dbo.sp_adjust_inventory @ingredient_id = @ingredient_id, @on_hand_delta = @step,
                                 @employee_id = @emp_store, @reason = N'demo success second';
    REVERT; SET @imp = 0;
    SELECT @after = on_hand_qty FROM dbo.Inventory WHERE ingredient_id = @ingredient_id;
    SELECT @movements = COUNT(*) FROM dbo.InventoryMovement
    WHERE ingredient_id = @ingredient_id AND movement_type = 'ADJUSTMENT'
      AND reference_type = 'ADJUSTMENT' AND reference_id IS NULL
      AND on_hand_delta = @step;
    SELECT @audits = COUNT(*) FROM dbo.AuditLog
    WHERE action_name = 'ADJUST_INVENTORY' AND entity_id = @ingredient_id
      AND detail_json LIKE N'%demo success%';
    ROLLBACK TRANSACTION;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    IF @imp = 1 REVERT;
    THROW;
END CATCH;
SELECT case_name = N'连续两次 +5', before_on_hand = @before, after_on_hand = @after,
       delta_on_hand = @after - @before, two_step_movements = @movements, two_step_audits = @audits;
GO
