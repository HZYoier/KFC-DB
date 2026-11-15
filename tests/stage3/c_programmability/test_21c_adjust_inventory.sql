-- ============================================================================
-- test_21c_adjust_inventory.sql — C 域库存调整过程测试（成员 C；2026-11-15）
-- 运行时机：v0.1 已部署，20_schema_v1_1.sql 与 21c_inventory_programmability.sql 已执行。
-- 运行方式：
--   sqlcmd -S '.\SQLEXPRESS' -E -C -f 65001 -b -d KFC_DB -i 本文件
-- 覆盖：NULL 参数、零增量、空原因、未映射主体、员工不匹配、非店长、原料不存在、
--       调整后为负、失败不落半条数据、成功写库存/流水/审计、连续两次基于新值。
-- 分母：15。每个反例同时核对 ERROR_NUMBER() 与 ERROR_MESSAGE()（H6）。
-- 断言码：54930 前置缺失、54931 夹具不成立、54998 有失败、54999 分母不足。
-- ============================================================================
:on error exit
USE KFC_DB;
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF OBJECT_ID(N'dbo.sp_adjust_inventory', N'P') IS NULL
    THROW 54930, N'缺少 dbo.sp_adjust_inventory；请先部署 v0.1。', 1;
IF OBJECT_ID(N'dbo.InventoryAudit', N'U') IS NULL
    THROW 54930, N'缺少 dbo.InventoryAudit；请先执行 sql/stage3/20_schema_v1_1.sql。', 1;
IF OBJECT_ID(N'dbo.fn_replenishment_qty', N'FN') IS NULL
    THROW 54930, N'缺少 dbo.fn_replenishment_qty；请先执行 sql/stage3/21c_inventory_programmability.sql。', 1;

DECLARE @emp_store BIGINT =
    (SELECT employee_id FROM dbo.EmployeeAccount
     WHERE database_user_name = N'test_store_manager' AND status = 'ACTIVE');
DECLARE @emp_shift BIGINT =
    (SELECT employee_id FROM dbo.EmployeeAccount
     WHERE database_user_name = N'test_shift_manager' AND status = 'ACTIVE');
DECLARE @success_ingredient BIGINT;
DECLARE @success_on_hand DECIMAL(12,3);

SELECT TOP (1)
       @success_ingredient = inv.ingredient_id,
       @success_on_hand = inv.on_hand_qty
FROM dbo.Inventory AS inv
JOIN dbo.Ingredient AS i ON i.ingredient_id = inv.ingredient_id
WHERE i.status = 'ACTIVE'
  AND inv.on_hand_qty >= CAST(10.000 AS DECIMAL(12,3))
ORDER BY inv.ingredient_id;

IF @emp_store IS NULL OR @emp_shift IS NULL OR @success_ingredient IS NULL
    THROW 54931, N'测试夹具不成立：缺少 test_store_manager/test_shift_manager 或库存 >= 10 的原料。', 1;

IF OBJECT_ID(N'tempdb..#counters_adj') IS NOT NULL DROP TABLE #counters_adj;
CREATE TABLE #counters_adj (pass INT NOT NULL, fail INT NOT NULL);
INSERT INTO #counters_adj (pass, fail) VALUES (0, 0);

DECLARE @err INT, @msg NVARCHAR(2048), @imp BIT;
DECLARE @missing_id BIGINT = CAST(999999999 AS BIGINT);
DECLARE @insufficient_delta DECIMAL(12,3) =
    -(@success_on_hand + CAST(1.000 AS DECIMAL(12,3)));
DECLARE @step DECIMAL(12,3) = CAST(5.000 AS DECIMAL(12,3));
DECLARE @zero DECIMAL(12,3) = CAST(0.000 AS DECIMAL(12,3));

-- 1. NULL 原料：54301
SET @err = NULL; SET @msg = NULL; SET @imp = 0;
BEGIN TRY
    EXECUTE AS USER = N'test_store_manager'; SET @imp = 1;
    EXEC dbo.sp_adjust_inventory @ingredient_id = NULL, @on_hand_delta = @step,
                                 @employee_id = @emp_store, @reason = N'21c null ingredient';
    REVERT; SET @imp = 0;
END TRY
BEGIN CATCH
    SET @err = ERROR_NUMBER(); SET @msg = ERROR_MESSAGE();
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    IF @imp = 1 REVERT;
    SET @imp = 0;
END CATCH;
IF @err = 54301 AND @msg LIKE N'%ingredient_id%不能为 NULL%'
    UPDATE #counters_adj SET pass = pass + 1;
ELSE
    UPDATE #counters_adj SET fail = fail + 1;

-- 2. NULL 增量：54301
SET @err = NULL; SET @msg = NULL; SET @imp = 0;
BEGIN TRY
    EXECUTE AS USER = N'test_store_manager'; SET @imp = 1;
    EXEC dbo.sp_adjust_inventory @ingredient_id = @success_ingredient, @on_hand_delta = NULL,
                                 @employee_id = @emp_store, @reason = N'21c null delta';
    REVERT; SET @imp = 0;
END TRY
BEGIN CATCH
    SET @err = ERROR_NUMBER(); SET @msg = ERROR_MESSAGE();
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    IF @imp = 1 REVERT;
    SET @imp = 0;
END CATCH;
IF @err = 54301 AND @msg LIKE N'%on_hand_delta%不能为 NULL%'
    UPDATE #counters_adj SET pass = pass + 1;
ELSE
    UPDATE #counters_adj SET fail = fail + 1;

-- 3. NULL 员工：54301
SET @err = NULL; SET @msg = NULL; SET @imp = 0;
BEGIN TRY
    EXECUTE AS USER = N'test_store_manager'; SET @imp = 1;
    EXEC dbo.sp_adjust_inventory @ingredient_id = @success_ingredient, @on_hand_delta = @step,
                                 @employee_id = NULL, @reason = N'21c null employee';
    REVERT; SET @imp = 0;
END TRY
BEGIN CATCH
    SET @err = ERROR_NUMBER(); SET @msg = ERROR_MESSAGE();
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    IF @imp = 1 REVERT;
    SET @imp = 0;
END CATCH;
IF @err = 54301 AND @msg LIKE N'%employee_id%不能为 NULL%'
    UPDATE #counters_adj SET pass = pass + 1;
ELSE
    UPDATE #counters_adj SET fail = fail + 1;

-- 4. 零增量：54302
SET @err = NULL; SET @msg = NULL; SET @imp = 0;
BEGIN TRY
    EXECUTE AS USER = N'test_store_manager'; SET @imp = 1;
    EXEC dbo.sp_adjust_inventory @ingredient_id = @success_ingredient, @on_hand_delta = @zero,
                                 @employee_id = @emp_store, @reason = N'21c zero delta';
    REVERT; SET @imp = 0;
END TRY
BEGIN CATCH
    SET @err = ERROR_NUMBER(); SET @msg = ERROR_MESSAGE();
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    IF @imp = 1 REVERT;
    SET @imp = 0;
END CATCH;
IF @err = 54302 AND @msg LIKE N'%不能为 0%'
    UPDATE #counters_adj SET pass = pass + 1;
ELSE
    UPDATE #counters_adj SET fail = fail + 1;

-- 5. 空白原因：54303
SET @err = NULL; SET @msg = NULL; SET @imp = 0;
BEGIN TRY
    EXECUTE AS USER = N'test_store_manager'; SET @imp = 1;
    EXEC dbo.sp_adjust_inventory @ingredient_id = @success_ingredient, @on_hand_delta = @step,
                                 @employee_id = @emp_store, @reason = '   ';
    REVERT; SET @imp = 0;
END TRY
BEGIN CATCH
    SET @err = ERROR_NUMBER(); SET @msg = ERROR_MESSAGE();
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    IF @imp = 1 REVERT;
    SET @imp = 0;
END CATCH;
IF @err = 54303 AND @msg LIKE N'%缺少调整原因%'
    UPDATE #counters_adj SET pass = pass + 1;
ELSE
    UPDATE #counters_adj SET fail = fail + 1;

-- 6. dbo 主体未映射员工：54304
SET @err = NULL; SET @msg = NULL;
BEGIN TRY
    EXEC dbo.sp_adjust_inventory @ingredient_id = @success_ingredient, @on_hand_delta = @step,
                                 @employee_id = @emp_store, @reason = N'21c unmapped dbo';
END TRY
BEGIN CATCH
    SET @err = ERROR_NUMBER(); SET @msg = ERROR_MESSAGE();
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
END CATCH;
IF @err = 54304 AND @msg LIKE N'%未映射到启用员工%'
    UPDATE #counters_adj SET pass = pass + 1;
ELSE
    UPDATE #counters_adj SET fail = fail + 1;

-- 7. 传入员工与主体解析员工不一致：54305
SET @err = NULL; SET @msg = NULL; SET @imp = 0;
BEGIN TRY
    EXECUTE AS USER = N'test_store_manager'; SET @imp = 1;
    EXEC dbo.sp_adjust_inventory @ingredient_id = @success_ingredient, @on_hand_delta = @step,
                                 @employee_id = @emp_shift, @reason = N'21c employee mismatch';
    REVERT; SET @imp = 0;
END TRY
BEGIN CATCH
    SET @err = ERROR_NUMBER(); SET @msg = ERROR_MESSAGE();
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    IF @imp = 1 REVERT;
    SET @imp = 0;
END CATCH;
IF @err = 54305 AND @msg LIKE N'%员工不一致%'
    UPDATE #counters_adj SET pass = pass + 1;
ELSE
    UPDATE #counters_adj SET fail = fail + 1;

-- 8. 非店长：先临时授 EXECUTE，再以值班经理身份调用；得到 54306
GRANT EXECUTE ON dbo.sp_adjust_inventory TO role_shift_manager;
SET @err = NULL; SET @msg = NULL; SET @imp = 0;
BEGIN TRY
    EXECUTE AS USER = N'test_shift_manager'; SET @imp = 1;
    EXEC dbo.sp_adjust_inventory @ingredient_id = @success_ingredient, @on_hand_delta = @step,
                                 @employee_id = @emp_shift, @reason = N'21c wrong role';
    REVERT; SET @imp = 0;
END TRY
BEGIN CATCH
    SET @err = ERROR_NUMBER(); SET @msg = ERROR_MESSAGE();
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    IF @imp = 1 REVERT;
    SET @imp = 0;
END CATCH;
REVOKE EXECUTE ON dbo.sp_adjust_inventory FROM role_shift_manager;
IF @err = 54306 AND @msg LIKE N'%仅店长可调整库存%'
    UPDATE #counters_adj SET pass = pass + 1;
ELSE
    UPDATE #counters_adj SET fail = fail + 1;

-- 9. 原料不存在：54307
SET @err = NULL; SET @msg = NULL; SET @imp = 0;
BEGIN TRY
    EXECUTE AS USER = N'test_store_manager'; SET @imp = 1;
    EXEC dbo.sp_adjust_inventory @ingredient_id = @missing_id, @on_hand_delta = @step,
                                 @employee_id = @emp_store, @reason = N'21c missing ingredient';
    REVERT; SET @imp = 0;
END TRY
BEGIN CATCH
    SET @err = ERROR_NUMBER(); SET @msg = ERROR_MESSAGE();
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    IF @imp = 1 REVERT;
    SET @imp = 0;
END CATCH;
IF @err = 54307 AND @msg LIKE N'%原料不存在或尚未建立库存记录%'
    UPDATE #counters_adj SET pass = pass + 1;
ELSE
    UPDATE #counters_adj SET fail = fail + 1;

-- 10. 调整后为负：54308，并验证失败不落半条数据
DECLARE @before_on_hand DECIMAL(12,3), @before_movements BIGINT, @before_audits BIGINT;
SELECT @before_on_hand = on_hand_qty FROM dbo.Inventory WHERE ingredient_id = @success_ingredient;
SELECT @before_movements = COUNT_BIG(*) FROM dbo.InventoryMovement
WHERE ingredient_id = @success_ingredient AND movement_type = 'ADJUSTMENT';
SELECT @before_audits = COUNT_BIG(*) FROM dbo.AuditLog
WHERE action_name = 'ADJUST_INVENTORY' AND entity_id = @success_ingredient;

SET @err = NULL; SET @msg = NULL; SET @imp = 0;
BEGIN TRY
    EXECUTE AS USER = N'test_store_manager'; SET @imp = 1;
    EXEC dbo.sp_adjust_inventory @ingredient_id = @success_ingredient, @on_hand_delta = @insufficient_delta,
                                 @employee_id = @emp_store, @reason = N'21c insufficient';
    REVERT; SET @imp = 0;
END TRY
BEGIN CATCH
    SET @err = ERROR_NUMBER(); SET @msg = ERROR_MESSAGE();
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    IF @imp = 1 REVERT;
    SET @imp = 0;
END CATCH;
IF @err = 54308 AND @msg LIKE N'%调整后库存不能为负%'
    UPDATE #counters_adj SET pass = pass + 1;
ELSE
    UPDATE #counters_adj SET fail = fail + 1;

-- 11. 失败后库存、调整流水、审计均未变化
IF (SELECT on_hand_qty FROM dbo.Inventory WHERE ingredient_id = @success_ingredient) = @before_on_hand
   AND (SELECT COUNT_BIG(*) FROM dbo.InventoryMovement
        WHERE ingredient_id = @success_ingredient AND movement_type = 'ADJUSTMENT') = @before_movements
   AND (SELECT COUNT_BIG(*) FROM dbo.AuditLog
        WHERE action_name = 'ADJUST_INVENTORY' AND entity_id = @success_ingredient) = @before_audits
    UPDATE #counters_adj SET pass = pass + 1;
ELSE
    UPDATE #counters_adj SET fail = fail + 1;

-- 12—15. 成功路径与重复调用；在事务内做，最后回滚，断言位在回滚后计数
DECLARE @ok_on_hand BIT = 0, @ok_movements BIT = 0, @ok_audits BIT = 0, @ok_repeat BIT = 0;
DECLARE @after_two DECIMAL(12,3), @after_movements BIGINT, @after_audits BIGINT;
DECLARE @before_movements2 BIGINT, @before_audits2 BIGINT;
SELECT @before_movements2 = COUNT_BIG(*) FROM dbo.InventoryMovement
WHERE ingredient_id = @success_ingredient AND movement_type = 'ADJUSTMENT';
SELECT @before_audits2 = COUNT_BIG(*) FROM dbo.AuditLog
WHERE action_name = 'ADJUST_INVENTORY' AND entity_id = @success_ingredient;

BEGIN TRANSACTION;
BEGIN TRY
    EXECUTE AS USER = N'test_store_manager'; SET @imp = 1;
    EXEC dbo.sp_adjust_inventory @ingredient_id = @success_ingredient, @on_hand_delta = @step,
                                 @employee_id = @emp_store, @reason = N'21c success first';
    EXEC dbo.sp_adjust_inventory @ingredient_id = @success_ingredient, @on_hand_delta = @step,
                                 @employee_id = @emp_store, @reason = N'21c success second';
    REVERT; SET @imp = 0;

    SELECT @after_two = on_hand_qty FROM dbo.Inventory WHERE ingredient_id = @success_ingredient;
    SELECT @after_movements = COUNT_BIG(*) FROM dbo.InventoryMovement
    WHERE ingredient_id = @success_ingredient AND movement_type = 'ADJUSTMENT';
    SELECT @after_audits = COUNT_BIG(*) FROM dbo.AuditLog
    WHERE action_name = 'ADJUST_INVENTORY' AND entity_id = @success_ingredient;

    IF @after_two = @before_on_hand + CAST(10.000 AS DECIMAL(12,3))
        SET @ok_repeat = 1;
    IF @after_two = @before_on_hand + CAST(10.000 AS DECIMAL(12,3))
       AND @after_movements = @before_movements2 + 2
        SET @ok_movements = 1;
    IF @after_audits = @before_audits2 + 2
       AND EXISTS (SELECT 1 FROM dbo.AuditLog
                   WHERE action_name = 'ADJUST_INVENTORY' AND entity_id = @success_ingredient
                     AND detail_json LIKE N'%21c success first%')
       AND EXISTS (SELECT 1 FROM dbo.AuditLog
                   WHERE action_name = 'ADJUST_INVENTORY' AND entity_id = @success_ingredient
                     AND detail_json LIKE N'%21c success second%')
        SET @ok_audits = 1;
    IF EXISTS (SELECT 1 FROM dbo.InventoryMovement
               WHERE ingredient_id = @success_ingredient
                 AND movement_type = 'ADJUSTMENT'
                 AND on_hand_delta = @step
                 AND locked_delta = 0
                 AND reference_type = 'ADJUSTMENT'
                 AND reference_id IS NULL)
        SET @ok_on_hand = 1;

    ROLLBACK TRANSACTION;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    IF @imp = 1 REVERT;
    THROW;
END CATCH;

IF @ok_repeat = 1 UPDATE #counters_adj SET pass = pass + 1;
ELSE UPDATE #counters_adj SET fail = fail + 1;
IF @ok_movements = 1 UPDATE #counters_adj SET pass = pass + 1;
ELSE UPDATE #counters_adj SET fail = fail + 1;
IF @ok_audits = 1 UPDATE #counters_adj SET pass = pass + 1;
ELSE UPDATE #counters_adj SET fail = fail + 1;
IF @ok_on_hand = 1 UPDATE #counters_adj SET pass = pass + 1;
ELSE UPDATE #counters_adj SET fail = fail + 1;

DECLARE @pass INT = (SELECT pass FROM #counters_adj);
DECLARE @fail INT = (SELECT fail FROM #counters_adj);
DECLARE @total INT = @pass + @fail;

PRINT CONCAT(N'RESULT: c-programmability adjust_inventory pass=', @pass,
             N' fail=', @fail, N' total=', @total);
IF @total <> 15
    THROW 54999, N'库存调整测试分母不足：期望 15 条，实际计数不是 15。', 1;
IF @fail > 0
    THROW 54998, N'库存调整测试存在失败断言。', 1;
GO
