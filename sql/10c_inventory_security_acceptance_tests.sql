-- ============================================================================
-- 10c_inventory_security_acceptance_tests.sql
-- 负责人：C（库存、补货、员工权限、审计与总集成）
-- 用途：C 域与集成的验收断言——覆盖计划 §6.2 的 E2E-01..07 与 §5 C-3 line 322 的
--       最低清单（库存不足下单回滚、取消释放锁、制作完成抛错后订单与库存回滚、
--       库存永不为负、低于安全线生成唯一待审核建议、建议状态迁移、非店长无法审批、
--       两次收货的 APPROVED→PARTIALLY_RECEIVED→CLOSED、收货后库存增加、敏感操作审计、
--       取餐员可查取餐板但查不到含金额视图、EXECUTE AS 下的正反权限）。
-- 依赖：01/02/03（表）、04（A 域过程）、05（B 域过程）、06（C 域 15 个过程）、07c（视图）、
--       08（角色与授权）、09a/09c/09b/09d（四份种子：本文件的所有前置状态由它们建立）。
-- 依据：docs/stage1-three-person-implementation-plan.md §6.2、§5 C-3 line 322、§7；
--       docs/stage1-cross-domain-interface-contract.md §7.4（断言写法六条约定）。
-- 写法（对齐契约 §7.4 与上文经验）：
--   ① 每条断言自成一批、事务包裹、结束一律 ROLLBACK，绝不把夹具或状态留给下一条；
--   ② "故意抛错"只经既有约束或过程守卫注入（不引入测试开关参数）；
--   ③ 失败文案带出 ERROR_NUMBER() 与 ERROR_MESSAGE()（只判"有没有报错"会把 229/201 误当通过）；
--   ④ 期望值尽量从数据推导（安全线、BOM 用量、消耗量），不写死 ID 与行数；
--   ⑤ EXECUTE AS 的收尾一律"先 ROLLBACK 再 REVERT"（不可提交事务里 REVERT 会被拒 Msg 3930）；
--   ⑥ 计数用临时表 #counters 跨批次累计（局部变量不跨批次），收尾打印 RESULT 并校验分母，
--      分母不足即 THROW 51199——用于抓住"某批被静默作废"（-f 65001 缺失、Msg 207 家族）。
-- 错误码：本文件用 51100（前置不成立）与 51101–51115（各条断言失败）、51199（计数分母不足）。
-- ============================================================================

USE KFC_DB;
GO

SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET QUOTED_IDENTIFIER ON;
SET NUMERIC_ROUNDABORT OFF;
GO

IF OBJECT_ID('tempdb..#counters') IS NOT NULL DROP TABLE #counters;
CREATE TABLE #counters (pass INT NOT NULL, fail INT NOT NULL);
INSERT #counters (pass, fail) VALUES (0, 0);
GO

-- T1 E2E-01/E2E-04：三笔种子订单的终态与明细快照（促销价与促销 ID 是成交时快照）
DECLARE @err INT, @msg NVARCHAR(2048), @diag NVARCHAR(400), @n INT, @n2 INT;
BEGIN TRY
    SET @n = (SELECT COUNT(*) FROM dbo.SalesOrder
              WHERE (order_no = 'B-SEED-PICKUP-001'   AND order_status = 'PICKED_UP')
                 OR (order_no = 'B-SEED-DELIVERY-001' AND order_status = 'COMPLETED')
                 OR (order_no = 'B-SEED-CANCEL-001'   AND order_status = 'CANCELLED'));
    IF @n <> 3 THROW 51101, N'T1：三笔种子订单的终态不是「自取完成 / 外送完成 / 未支付取消」。', 1;

    SET @n = (SELECT COUNT(*) FROM dbo.SalesOrderItem AS oi
              JOIN dbo.SalesOrder AS o ON o.order_id = oi.order_id
              WHERE o.order_no = 'B-SEED-PICKUP-001' AND oi.item_role = 'SELLABLE'
                AND oi.promotion_id IS NOT NULL AND oi.unit_price = 9.90);
    IF @n <> 1 THROW 51101, N'T1：促销自取单的成交价快照不是 9.90 或缺少促销 ID。', 1;

    SET @n = (SELECT COUNT(*) FROM dbo.SalesOrderItem AS oi
              JOIN dbo.SalesOrder AS o ON o.order_id = oi.order_id
              WHERE o.order_no = 'B-SEED-CANCEL-001' AND oi.item_role = 'SELLABLE');
    SET @n2 = (SELECT COUNT(*) FROM dbo.Payment AS p JOIN dbo.SalesOrder AS o ON o.order_id = p.order_id
               WHERE o.order_no = 'B-SEED-CANCEL-001');
    IF @n <> 1 OR @n2 <> 0 THROW 51101, N'T1：未支付取消单的明细或支付记录不符合预期（应为 1 条明细、0 条支付）。', 1;

    UPDATE #counters SET pass = pass + 1;
    PRINT 'PASS: T1 E2E-01/04 三笔种子订单终态与成交价/促销快照';
END TRY
BEGIN CATCH
    SET @err = ERROR_NUMBER(); SET @msg = ERROR_MESSAGE();
    UPDATE #counters SET fail = fail + 1;
    PRINT 'FAIL: T1 err=' + ISNULL(CAST(@err AS NVARCHAR(10)), N'') + N' msg=' + ISNULL(@msg, N'');
END CATCH;
GO

-- T2 E2E-01/02/04：库存流水的形状与按单据去重的三类迁移（LOCK 3 单 / CONSUME 2 单 / RELEASE 1 单）
DECLARE @err INT, @msg NVARCHAR(2048), @n INT, @n2 INT;
BEGIN TRY
    SET @n = (SELECT COUNT(DISTINCT im.reference_id) FROM dbo.InventoryMovement AS im WHERE im.movement_type = 'LOCK'    AND im.reference_type = 'ORDER');
    SET @n2 = (SELECT COUNT(DISTINCT im.reference_id) FROM dbo.InventoryMovement AS im WHERE im.movement_type = 'CONSUME' AND im.reference_type = 'ORDER');
    IF @n <> 3 OR @n2 <> 2 THROW 51102, N'T2：三笔种子订单的 LOCK/CONSUME 单据数不是 3/2。', 1;

    SET @n = (SELECT COUNT(DISTINCT im.reference_id) FROM dbo.InventoryMovement AS im WHERE im.movement_type = 'RELEASE' AND im.reference_type = 'ORDER');
    IF @n <> 1 THROW 51102, N'T2：RELEASE 单据数不是 1（未支付取消单一笔）。', 1;

    -- 形状：LOCK 只增锁定、RELEASE 只减锁定、CONSUME 两边同减、RECEIPT 只增现有量
    SET @n = (SELECT COUNT(*) FROM dbo.InventoryMovement
              WHERE (movement_type = 'LOCK'    AND NOT (on_hand_delta = 0 AND locked_delta > 0))
                 OR (movement_type = 'RELEASE' AND NOT (on_hand_delta = 0 AND locked_delta < 0))
                 OR (movement_type = 'CONSUME' AND NOT (on_hand_delta < 0 AND locked_delta = on_hand_delta))
                 OR (movement_type = 'RECEIPT' AND NOT (on_hand_delta > 0 AND locked_delta = 0)));
    IF @n <> 0 THROW 51102, N'T2：存在不符合（on_hand_delta, locked_delta）组合约定的流水。', 1;

    UPDATE #counters SET pass = pass + 1;
    PRINT 'PASS: T2 流水形状合规、三类迁移按单据去重 LOCK 3 / CONSUME 2 / RELEASE 1';
END TRY
BEGIN CATCH
    SET @err = ERROR_NUMBER(); SET @msg = ERROR_MESSAGE();
    UPDATE #counters SET fail = fail + 1;
    PRINT 'FAIL: T2 err=' + ISNULL(CAST(@err AS NVARCHAR(10)), N'') + N' msg=' + ISNULL(@msg, N'');
END CATCH;
GO

-- T3 库存永不为负 + 账本勾稽（locked = Σ locked_delta；on_hand = 期初 + Σ on_hand_delta）
--    期初口径 = 09c 的规则：压线原料 1/5 = 安全线，其余 = 安全线 × 10
DECLARE @err INT, @msg NVARCHAR(2048), @n INT, @n2 INT, @n3 INT;
BEGIN TRY
    SET @n = (SELECT COUNT(*) FROM dbo.Inventory WHERE on_hand_qty < 0 OR locked_qty < 0);
    IF @n <> 0 THROW 51103, N'T3：存在负的现有量或锁定量。', 1;

    SET @n = (SELECT COUNT(*) FROM dbo.Inventory AS inv
              WHERE inv.locked_qty <> ISNULL((SELECT SUM(m.locked_delta) FROM dbo.InventoryMovement AS m
                                              WHERE m.ingredient_id = inv.ingredient_id), 0));
    IF @n <> 0 THROW 51103, N'T3：locked_qty 与 Σ locked_delta 不勾稽。', 1;

    SET @n = (SELECT COUNT(*) FROM dbo.Inventory AS inv
              JOIN dbo.Ingredient AS i ON i.ingredient_id = inv.ingredient_id
              WHERE inv.on_hand_qty <>
                    (CASE WHEN inv.ingredient_id IN (1, 5) THEN i.safety_stock_qty
                          ELSE CAST(i.safety_stock_qty * 10 AS DECIMAL(12,3)) END)
                    + ISNULL((SELECT SUM(m.on_hand_delta) FROM dbo.InventoryMovement AS m
                              WHERE m.ingredient_id = inv.ingredient_id), 0));
    IF @n <> 0 THROW 51103, N'T3：on_hand_qty 与「期初 + Σ on_hand_delta」不勾稽。', 1;

    SET @n = (SELECT COUNT(*) FROM dbo.InventoryMovement WHERE movement_type = 'PURCHASE_ORDER');
    SET @n2 = (SELECT COUNT(*) FROM dbo.InventoryMovement WHERE movement_type IN ('ADJUSTMENT', 'RECEIPT') AND reference_id IS NULL);
    IF @n2 <> 0 THROW 51103, N'T3：ADJUSTMENT/RECEIPT 流水的 reference_id 不符合约定。', 1;

    UPDATE #counters SET pass = pass + 1;
    PRINT 'PASS: T3 库存永不为负，账本双向勾稽（锁定/现有量），流水引用约定成立';
END TRY
BEGIN CATCH
    SET @err = ERROR_NUMBER(); SET @msg = ERROR_MESSAGE();
    UPDATE #counters SET fail = fail + 1;
    PRINT 'FAIL: T3 err=' + ISNULL(CAST(@err AS NVARCHAR(10)), N'') + N' msg=' + ISNULL(@msg, N'');
END CATCH;
GO

-- T4 E2E-02/03：积分两段式的终态——种子订单的积分流水为 EFFECTIVE，且顾客当前积分
--    等于契约 §6 冻结的期初积分 + 本顾客全部 EFFECTIVE 流水的 point_delta
DECLARE @err INT, @msg NVARCHAR(2048), @n INT, @n2 INT;
BEGIN TRY
    SET @n = (SELECT COUNT(*) FROM dbo.PointLedger WHERE ledger_status <> 'EFFECTIVE');
    IF @n <> 0 THROW 51104, N'T4：存在非 EFFECTIVE 的积分流水（种子订单应全部终态）。', 1;

    SET @n2 = (SELECT COUNT(*) FROM dbo.Customer AS c
               JOIN (VALUES (1, 0), (2, 500), (3, 1500)) AS base(customer_id, base_points)
                 ON base.customer_id = c.customer_id
               WHERE c.current_points <> base.base_points
                     + ISNULL((SELECT SUM(pl.point_delta) FROM dbo.PointLedger AS pl
                               WHERE pl.customer_id = c.customer_id AND pl.ledger_status = 'EFFECTIVE'), 0));
    IF @n2 <> 0 THROW 51104, N'T4：顾客当前积分与「期初 + Σ EFFECTIVE 流水」不一致。', 1;

    UPDATE #counters SET pass = pass + 1;
    PRINT 'PASS: T4 E2E-02/03 积分流水全部 EFFECTIVE，顾客积分与流水勾稽';
END TRY
BEGIN CATCH
    SET @err = ERROR_NUMBER(); SET @msg = ERROR_MESSAGE();
    UPDATE #counters SET fail = fail + 1;
    PRINT 'FAIL: T4 err=' + ISNULL(CAST(@err AS NVARCHAR(10)), N'') + N' msg=' + ISNULL(@msg, N'');
END CATCH;
GO

-- T5 E2E-06（上半）：低库存建议唯一且已关闭、采购单 CLOSED 且收齐、RECEIPT 两条
DECLARE @err INT, @msg NVARCHAR(2048), @n INT, @n2 INT, @n3 INT;
BEGIN TRY
    SET @n = (SELECT COUNT(*) FROM dbo.ReplenishmentSuggestion WHERE suggestion_status IN ('PENDING', 'SUBMITTED', 'APPROVED'));
    IF @n <> 0 THROW 51105, N'T5：仍存在开放建议（收货收齐后应无 PENDING/SUBMITTED/APPROVED）。', 1;

    -- 每原料至多一张开放建议（过滤唯一索引的语义断言）
    SET @n = (SELECT COUNT(*) FROM (SELECT ingredient_id FROM dbo.ReplenishmentSuggestion
                                    WHERE suggestion_status IN ('PENDING', 'SUBMITTED', 'APPROVED')
                                    GROUP BY ingredient_id HAVING COUNT(*) > 1) AS dup);
    IF @n <> 0 THROW 51105, N'T5：存在同一原料的多张开放建议。', 1;

    SET @n = (SELECT COUNT(*) FROM dbo.PurchaseOrder WHERE purchase_status = 'CLOSED');
    SET @n2 = (SELECT COUNT(*) FROM dbo.PurchaseOrder AS po
               JOIN dbo.PurchaseOrderItem AS poi ON poi.purchase_order_id = po.purchase_order_id
               WHERE po.purchase_status = 'CLOSED' AND poi.received_qty = poi.ordered_qty AND poi.received_qty > 0);
    SET @n3 = (SELECT COUNT(*) FROM dbo.InventoryMovement WHERE movement_type = 'RECEIPT');
    IF @n <> 1 OR @n2 <> 1 OR @n3 <> 2 THROW 51105, N'T5：采购单终态或 RECEIPT 流水条数不符合预期。', 1;

    SET @n = (SELECT SUM(im.on_hand_delta) FROM dbo.InventoryMovement AS im WHERE im.movement_type = 'RECEIPT');
    SET @n2 = (SELECT rs.suggested_qty FROM dbo.ReplenishmentSuggestion AS rs JOIN dbo.PurchaseOrder AS po
                 ON po.replenishment_suggestion_id = rs.replenishment_suggestion_id WHERE po.purchase_status = 'CLOSED');
    IF @n <> @n2 THROW 51105, N'T5：收货总量与已关闭建议的建议量不相等（账实不平）。', 1;

    UPDATE #counters SET pass = pass + 1;
    PRINT 'PASS: T5 E2E-06 建议已关闭且唯一、采购单 CLOSED 收齐、两张 RECEIPT 与建议量勾稽';
END TRY
BEGIN CATCH
    SET @err = ERROR_NUMBER(); SET @msg = ERROR_MESSAGE();
    UPDATE #counters SET fail = fail + 1;
    PRINT 'FAIL: T5 err=' + ISNULL(CAST(@err AS NVARCHAR(10)), N'') + N' msg=' + ISNULL(@msg, N'');
END CATCH;
GO

-- T6 审计：收货两次各一条、提交与审批各至少一条；审计动作名与实体名符合约定
DECLARE @err INT, @msg NVARCHAR(2048), @n INT, @n2 INT;
BEGIN TRY
    SET @n = (SELECT COUNT(*) FROM dbo.AuditLog WHERE action_name = 'RECEIVE_INVENTORY' AND entity_name = 'PurchaseOrder');
    IF @n <> 2 THROW 51106, N'T6：RECEIVE_INVENTORY 审计不是两条。', 1;

    SET @n = (SELECT COUNT(*) FROM dbo.AuditLog WHERE action_name = 'SUBMIT_REPLENISHMENT_SUGGESTION' AND entity_name = 'ReplenishmentSuggestion');
    SET @n2 = (SELECT COUNT(*) FROM dbo.AuditLog WHERE action_name = 'APPROVE_REPLENISHMENT_SUGGESTION' AND entity_name = 'PurchaseOrder');
    IF @n < 1 OR @n2 < 1 THROW 51106, N'T6：提交或审批的审计缺失。', 1;

    SET @n = (SELECT COUNT(*) FROM dbo.AuditLog WHERE action_name = 'ASSIGN_EMPLOYEE_BUSINESS_ROLE' AND entity_name = 'EmployeeBusinessRole');
    IF @n < 7 THROW 51106, N'T6：角色分配的审计条数少于 7（09c 的七次分配各一条）。', 1;

    SET @n = (SELECT COUNT(*) FROM dbo.AuditLog WHERE employee_id IS NULL OR detail_json IS NULL);
    IF @n <> 0 THROW 51106, N'T6：存在缺少操作人或明细的审计行。', 1;

    UPDATE #counters SET pass = pass + 1;
    PRINT 'PASS: T6 敏感操作（收货/提交/审批/角色分配）审计齐备且字段完整';
END TRY
BEGIN CATCH
    SET @err = ERROR_NUMBER(); SET @msg = ERROR_MESSAGE();
    UPDATE #counters SET fail = fail + 1;
    PRINT 'FAIL: T6 err=' + ISNULL(CAST(@err AS NVARCHAR(10)), N'') + N' msg=' + ISNULL(@msg, N'');
END CATCH;
GO

-- T7 E2E-05（反例）：可用库存不足的下单被拒，且订单/明细/流水零新增
DECLARE @err INT, @msg NVARCHAR(2048), @n INT, @n2 INT, @n3 INT;
DECLARE @imp BIT = 0;
DECLARE @cust BIGINT = (SELECT TOP (1) c.customer_id FROM dbo.Customer AS c
                        JOIN dbo.MemberLevel AS ml ON ml.member_level_id = c.member_level_id
                        WHERE c.status = 'ACTIVE' AND ml.status = 'ACTIVE' AND ml.point_multiplier > 0
                        ORDER BY c.customer_id);
BEGIN TRY
    SET @n  = (SELECT COUNT(*) FROM dbo.SalesOrder);
    SET @n2 = (SELECT COUNT(*) FROM dbo.SalesOrderItem);
    SET @n3 = (SELECT COUNT(*) FROM dbo.InventoryMovement);

    EXECUTE AS USER = 'test_cashier';
    SET @imp = 1;
    -- 薯条(中) 999 份远超薯条可售量：只经既有过程与库存守卫注入，不引入测试开关
    EXEC dbo.sp_create_order @customer_id = @cust, @fulfillment_method = 'PICKUP',
                             @order_no = 'ACC-LOW-STOCK-001',
                             @items_json = N'[{"product_id":3,"quantity":999}]';
    REVERT;
    SET @imp = 0;
    THROW 51107, N'T7：库存不足的下单竟然成功，未按预期拒绝。', 1;
END TRY
BEGIN CATCH
    SET @err = ERROR_NUMBER(); SET @msg = ERROR_MESSAGE();
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    IF @imp = 1 REVERT;

    IF @err = 51107
    BEGIN
        UPDATE #counters SET fail = fail + 1;
        PRINT 'FAIL: T7 ' + @msg;
    END
    ELSE IF @err = 50000 AND @msg LIKE N'%可用库存不足%'
    BEGIN
        IF (SELECT COUNT(*) FROM dbo.SalesOrder) <> @n
           OR (SELECT COUNT(*) FROM dbo.SalesOrderItem) <> @n2
           OR (SELECT COUNT(*) FROM dbo.InventoryMovement) <> @n3
        BEGIN
            UPDATE #counters SET fail = fail + 1;
            PRINT 'FAIL: T7 拒绝了下单但订单/明细/流水有残留。';
        END
        ELSE
        BEGIN
            UPDATE #counters SET pass = pass + 1;
            PRINT 'PASS: T7 E2E-05 库存不足下单被拒（50000：可用库存不足）且订单/明细/流水零新增';
        END
    END
    ELSE
    BEGIN
        UPDATE #counters SET fail = fail + 1;
        PRINT 'FAIL: T7 拒绝原因非预期 err=' + ISNULL(CAST(@err AS NVARCHAR(10)), N'') + N' msg=' + ISNULL(@msg, N'');
    END
END CATCH;
GO

-- T8 E2E-05 的对照：同结构的小数量下单应当成功（写 LOCK 流水，随后整批回滚）
DECLARE @err INT, @msg NVARCHAR(2048), @n INT, @imp BIT = 0;
DECLARE @cust2 BIGINT = (SELECT TOP (1) c.customer_id FROM dbo.Customer AS c
                         JOIN dbo.MemberLevel AS ml ON ml.member_level_id = c.member_level_id
                         WHERE c.status = 'ACTIVE' AND ml.status = 'ACTIVE' AND ml.point_multiplier > 0
                         ORDER BY c.customer_id);
DECLARE @locked_before DECIMAL(12,3) = (SELECT locked_qty FROM dbo.Inventory WHERE ingredient_id = 5);
DECLARE @usage DECIMAL(12,3) = (SELECT b.usage_qty FROM dbo.ProductBom AS b WHERE b.product_id = 3 AND b.ingredient_id = 5);
BEGIN TRY
    BEGIN TRANSACTION;
    EXECUTE AS USER = 'test_cashier';
    SET @imp = 1;
    EXEC dbo.sp_create_order @customer_id = @cust2, @fulfillment_method = 'PICKUP',
                             @order_no = 'ACC-OK-STOCK-001',
                             @items_json = N'[{"product_id":3,"quantity":1}]';
    REVERT;
    SET @imp = 0;

    SET @n = (SELECT COUNT(*) FROM dbo.SalesOrder WHERE order_no = 'ACC-OK-STOCK-001');
    IF @n <> 1 THROW 51108, N'T8：小数量下单没有生成订单。', 1;

    IF @usage IS NULL OR @usage <= 0 THROW 51108, N'T8：读不到 商品3 → 薯条 的 BOM 用量。', 1;

    IF (SELECT locked_qty FROM dbo.Inventory WHERE ingredient_id = 5) <> @locked_before + @usage
        THROW 51108, N'T8：锁定量没有按 BOM 用量增加。', 1;

    -- 计数写在回滚之后：临时表的写入同样受事务控制，写在事务内会被末尾的 ROLLBACK 一起回滚
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    UPDATE #counters SET pass = pass + 1;
    PRINT 'PASS: T8 E2E-05 对照 小数量下单成功并写入 LOCK 流水（锁定量按 BOM 用量增加）';
END TRY
BEGIN CATCH
    SET @err = ERROR_NUMBER(); SET @msg = ERROR_MESSAGE();
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    IF @imp = 1 REVERT;
    UPDATE #counters SET fail = fail + 1;
    PRINT 'FAIL: T8 err=' + ISNULL(CAST(@err AS NVARCHAR(10)), N'') + N' msg=' + ISNULL(@msg, N'');
END CATCH;
IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
GO

-- T9 制作完成时抛错：实扣被库存守卫拒绝，且整批回滚后库回到测试前状态
--    注入＝把薯条现有量调到 0 后触发实扣守卫（只走业务过程，不引入测试开关）。
--    读数一律在"未模拟"的部署登录下完成——被模拟的 packer 对基表没有 SELECT 权限，
--    在被模拟身份下读 SalesOrder 会得 229（本条首跑即因此失败，已改为部署登录读数）。
DECLARE @err INT, @msg NVARCHAR(2048), @status9 VARCHAR(20), @imp BIT = 0;
DECLARE @cust9 BIGINT = (SELECT TOP (1) c.customer_id FROM dbo.Customer AS c
                         JOIN dbo.MemberLevel AS ml ON ml.member_level_id = c.member_level_id
                         WHERE c.status = 'ACTIVE' AND ml.status = 'ACTIVE' AND ml.point_multiplier > 0
                         ORDER BY c.customer_id);
DECLARE @emp_sm9 BIGINT = (SELECT employee_id FROM dbo.EmployeeAccount WHERE database_user_name = 'test_store_manager');
DECLARE @order9 BIGINT, @amount9 DECIMAL(10,2), @on_hand9 DECIMAL(12,3);
DECLARE @usage9 DECIMAL(12,3) = (SELECT b.usage_qty FROM dbo.ProductBom AS b WHERE b.product_id = 3 AND b.ingredient_id = 5);
DECLARE @orders_before9 INT = (SELECT COUNT(*) FROM dbo.SalesOrder);
DECLARE @items_before9  INT = (SELECT COUNT(*) FROM dbo.SalesOrderItem);
DECLARE @movs_before9   INT = (SELECT COUNT(*) FROM dbo.InventoryMovement);
DECLARE @locked_before9 DECIMAL(12,3) = (SELECT locked_qty FROM dbo.Inventory WHERE ingredient_id = 5);
DECLARE @onhand_before9 DECIMAL(12,3) = (SELECT on_hand_qty FROM dbo.Inventory WHERE ingredient_id = 5);
BEGIN TRY
    BEGIN TRANSACTION;

    EXECUTE AS USER = 'test_cashier'; SET @imp = 1;
    EXEC dbo.sp_create_order @customer_id = @cust9, @fulfillment_method = 'PICKUP',
                             @order_no = 'ACC-CONSUME-FAIL-001',
                             @items_json = N'[{"product_id":3,"quantity":1}]';
    REVERT; SET @imp = 0;

    SELECT @order9 = order_id, @amount9 = total_amount FROM dbo.SalesOrder WHERE order_no = 'ACC-CONSUME-FAIL-001';

    EXECUTE AS USER = 'test_cashier'; SET @imp = 1;
    EXEC dbo.sp_pay_order @order_id = @order9, @payment_method = 'CASH',
                          @paid_amount = @amount9, @third_party_txn_no = 'ACC-CONSUME-FAIL-PAY-001';
    REVERT; SET @imp = 0;

    EXECUTE AS USER = 'test_chef'; SET @imp = 1;
    EXEC dbo.sp_start_production @order_id = @order9;
    REVERT; SET @imp = 0;

    -- 失败前（部署登录读）：订单已在制作中，锁定量已按 BOM 用量增加
    SET @status9 = (SELECT order_status FROM dbo.SalesOrder WHERE order_id = @order9);
    IF @usage9 IS NULL OR @usage9 <= 0
        THROW 51109, N'T9：读不到 商品3 → 薯条 的 BOM 用量。', 1;
    IF @status9 <> 'IN_PRODUCTION'
       OR (SELECT locked_qty FROM dbo.Inventory WHERE ingredient_id = 5) <> @locked_before9 + @usage9
        THROW 51109, N'T9：进入制作后订单状态或锁定量不符合预期。', 1;

    -- 注入：把薯条现有量调到 0（调整本身合法：调整后不为负；锁定量的占用留给实扣守卫去挡）
    SELECT @on_hand9 = on_hand_qty FROM dbo.Inventory WHERE ingredient_id = 5;
    DECLARE @delta9 DECIMAL(12,3) = -@on_hand9;   -- EXEC 实参位不接受表达式，先算进变量
    EXECUTE AS USER = 'test_store_manager'; SET @imp = 1;
    EXEC dbo.sp_adjust_inventory @ingredient_id = 5, @on_hand_delta = @delta9,
                                 @employee_id = @emp_sm9, @reason = N'10c T9：制造实扣失败的条件';
    REVERT; SET @imp = 0;

    EXECUTE AS USER = 'test_packer'; SET @imp = 1;
    EXEC dbo.sp_finish_production @order_id = @order9;
    REVERT; SET @imp = 0;
    THROW 51109, N'T9：实扣竟然成功，未按预期被库存守卫拒绝。', 1;
END TRY
BEGIN CATCH
    SET @err = ERROR_NUMBER(); SET @msg = ERROR_MESSAGE();
    -- 先回滚再还原身份（H16），再以部署登录读回滚后的状态
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    IF @imp = 1 REVERT;
    SET @imp = 0;

    IF @err = 51109
    BEGIN
        UPDATE #counters SET fail = fail + 1;
        PRINT 'FAIL: T9 ' + @msg;
    END
    ELSE IF @err = 50000 AND @msg LIKE N'%现有量或锁定量小于待实扣量%'
       AND (SELECT COUNT(*) FROM dbo.SalesOrder) = @orders_before9
       AND (SELECT COUNT(*) FROM dbo.SalesOrderItem) = @items_before9
       AND (SELECT COUNT(*) FROM dbo.InventoryMovement) = @movs_before9
       AND (SELECT locked_qty FROM dbo.Inventory WHERE ingredient_id = 5) = @locked_before9
       AND (SELECT on_hand_qty FROM dbo.Inventory WHERE ingredient_id = 5) = @onhand_before9
    BEGIN
        UPDATE #counters SET pass = pass + 1;
        PRINT 'PASS: T9 制作完成抛错被拒（50000：现有量或锁定量小于待实扣量），整批回滚后订单/明细/流水/锁定量均回到测试前状态';
    END
    ELSE
    BEGIN
        UPDATE #counters SET fail = fail + 1;
        PRINT 'FAIL: T9 err=' + ISNULL(CAST(@err AS NVARCHAR(10)), N'') + N' msg=' + ISNULL(@msg, N'');
    END
END CATCH;
IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
GO
-- T10 建议状态迁移（正向链）：PENDING →（调整）→ 提交 → 驳回（店长），审计齐备
--    正向链里不放"期望失败"的调用：会话带着 02 泄漏的 SET XACT_ABORT ON，
--    任何一次预期失败都会 doom 外层事务（随后的 REVERT 报 3930 并掩盖真错），
--    所以负例一律拆到 T10b / T10c 各自成批（各自的事务与回滚）。
DECLARE @err INT, @msg NVARCHAR(2048), @n INT, @imp BIT = 0;
DECLARE @emp_sm10 BIGINT = (SELECT employee_id FROM dbo.EmployeeAccount WHERE database_user_name = 'test_store_manager');
DECLARE @emp_sh10 BIGINT = (SELECT employee_id FROM dbo.EmployeeAccount WHERE database_user_name = 'test_shift_manager');
DECLARE @sugg10 BIGINT;
BEGIN TRY
    BEGIN TRANSACTION;

    EXECUTE AS USER = 'test_store_manager'; SET @imp = 1;
    EXEC dbo.sp_adjust_inventory @ingredient_id = 5, @on_hand_delta = -100.000,
                                 @employee_id = @emp_sm10, @reason = N'10c T10：制造低库存以产生建议';
    REVERT; SET @imp = 0;

    SET @sugg10 = (SELECT TOP (1) replenishment_suggestion_id FROM dbo.ReplenishmentSuggestion
                   WHERE ingredient_id = 5 AND suggestion_status = 'PENDING' ORDER BY replenishment_suggestion_id DESC);
    IF @sugg10 IS NULL THROW 51110, N'T10：下压库存后没有自动生成待审建议。', 1;

    EXECUTE AS USER = 'test_shift_manager'; SET @imp = 1;
    EXEC dbo.sp_update_replenishment_suggestion @suggestion_id = @sugg10, @suggested_qty = 150.000, @employee_id = @emp_sh10;
    EXEC dbo.sp_submit_replenishment_suggestion @suggestion_id = @sugg10, @employee_id = @emp_sh10;
    REVERT; SET @imp = 0;

    IF (SELECT suggestion_status FROM dbo.ReplenishmentSuggestion WHERE replenishment_suggestion_id = @sugg10) <> 'SUBMITTED'
        THROW 51110, N'T10：建议未进入 SUBMITTED。', 1;

    EXECUTE AS USER = 'test_store_manager'; SET @imp = 1;
    EXEC dbo.sp_reject_replenishment_suggestion @suggestion_id = @sugg10, @manager_employee_id = @emp_sm10,
                                                @reason = N'10c T10：验收驳回';
    REVERT; SET @imp = 0;

    IF (SELECT suggestion_status FROM dbo.ReplenishmentSuggestion WHERE replenishment_suggestion_id = @sugg10) <> 'REJECTED'
        THROW 51110, N'T10：建议未被驳回为 REJECTED。', 1;

    -- 审计：按实体定位，避免只数出种子留下的同动作历史
    SET @n = (SELECT COUNT(*) FROM dbo.AuditLog WHERE action_name = 'ADJUST_INVENTORY' AND entity_name = 'Inventory' AND entity_id = 5);
    IF @n < 1 THROW 51110, N'T10：缺少本次库存调整的审计。', 1;
    SET @n = (SELECT COUNT(*) FROM dbo.AuditLog WHERE action_name = 'REJECT_REPLENISHMENT_SUGGESTION' AND entity_id = @sugg10);
    IF @n < 1 THROW 51110, N'T10：缺少本次驳回的审计。', 1;
    SET @n = (SELECT COUNT(*) FROM dbo.AuditLog
              WHERE action_name IN ('UPDATE_REPLENISHMENT_SUGGESTION', 'SUBMIT_REPLENISHMENT_SUGGESTION')
                AND entity_id = @sugg10);
    IF @n < 2 THROW 51110, N'T10：缺少本次建议调整或提交的审计。', 1;

    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    UPDATE #counters SET pass = pass + 1;
    PRINT 'PASS: T10 建议 PENDING→（调整）→SUBMITTED→REJECTED，调整/建议调整/提交/驳回四类审计齐备';
END TRY
BEGIN CATCH
    SET @err = ERROR_NUMBER(); SET @msg = ERROR_MESSAGE();
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    IF @imp = 1 REVERT;
    UPDATE #counters SET fail = fail + 1;
    PRINT 'FAIL: T10 err=' + ISNULL(CAST(@err AS NVARCHAR(10)), N'') + N' msg=' + ISNULL(@msg, N'');
END CATCH;
IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
GO

-- T10b 越权反例（自成一批，无夹具）：值班经理审批被授权层拒绝（229）
DECLARE @err INT, @msg NVARCHAR(2048), @imp BIT = 0;
DECLARE @emp_sh10b BIGINT = (SELECT employee_id FROM dbo.EmployeeAccount WHERE database_user_name = 'test_shift_manager');
DECLARE @any_sugg BIGINT = (SELECT MAX(replenishment_suggestion_id) FROM dbo.ReplenishmentSuggestion);
BEGIN TRY
    EXECUTE AS USER = 'test_shift_manager'; SET @imp = 1;
    EXEC dbo.sp_approve_replenishment_suggestion @suggestion_id = @any_sugg, @manager_employee_id = @emp_sh10b;
    REVERT; SET @imp = 0;
    THROW 51111, N'T10b：值班经理审批竟然成功，未按预期被授权层拒绝。', 1;
END TRY
BEGIN CATCH
    SET @err = ERROR_NUMBER(); SET @msg = ERROR_MESSAGE();
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    IF @imp = 1 REVERT;
    IF @err = 51111
    BEGIN UPDATE #counters SET fail = fail + 1; PRINT 'FAIL: T10b ' + @msg; END
    ELSE IF @err = 229
    BEGIN UPDATE #counters SET pass = pass + 1; PRINT 'PASS: T10b 值班经理审批被拒（229：EXECUTE 只授给 role_store_manager）'; END
    ELSE
    BEGIN UPDATE #counters SET fail = fail + 1; PRINT 'FAIL: T10b err=' + ISNULL(CAST(@err AS NVARCHAR(10)), N'') + N' msg=' + ISNULL(@msg, N''); END
END CATCH;
GO

-- T10c 状态机反例（自成一批）：对已 SUBMITTED 的建议执行"仅 PENDING 可调整"的调整 → 被状态守卫拒绝
DECLARE @err INT, @msg NVARCHAR(2048), @imp BIT = 0;
DECLARE @emp_sm10c BIGINT = (SELECT employee_id FROM dbo.EmployeeAccount WHERE database_user_name = 'test_store_manager');
DECLARE @emp_sh10c BIGINT = (SELECT employee_id FROM dbo.EmployeeAccount WHERE database_user_name = 'test_shift_manager');
DECLARE @sugg10c BIGINT;
BEGIN TRY
    BEGIN TRANSACTION;

    EXECUTE AS USER = 'test_store_manager'; SET @imp = 1;
    EXEC dbo.sp_adjust_inventory @ingredient_id = 5, @on_hand_delta = -50.000,
                                 @employee_id = @emp_sm10c, @reason = N'10c T10c：制造低库存';
    REVERT; SET @imp = 0;

    SET @sugg10c = (SELECT TOP (1) replenishment_suggestion_id FROM dbo.ReplenishmentSuggestion
                    WHERE ingredient_id = 5 AND suggestion_status = 'PENDING' ORDER BY replenishment_suggestion_id DESC);
    IF @sugg10c IS NULL THROW 51112, N'T10c：未生成待审建议。', 1;

    EXECUTE AS USER = 'test_shift_manager'; SET @imp = 1;
    EXEC dbo.sp_submit_replenishment_suggestion @suggestion_id = @sugg10c, @employee_id = @emp_sh10c;
    REVERT; SET @imp = 0;

    EXECUTE AS USER = 'test_shift_manager'; SET @imp = 1;
    EXEC dbo.sp_update_replenishment_suggestion @suggestion_id = @sugg10c, @suggested_qty = 60.000, @employee_id = @emp_sh10c;
    REVERT; SET @imp = 0;
    THROW 51112, N'T10c：对已提交建议的调整竟然成功，未按预期被状态守卫拒绝。', 1;
END TRY
BEGIN CATCH
    SET @err = ERROR_NUMBER(); SET @msg = ERROR_MESSAGE();
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    IF @imp = 1 REVERT;
    IF @err = 51112
    BEGIN UPDATE #counters SET fail = fail + 1; PRINT 'FAIL: T10c ' + @msg; END
    ELSE IF @err = 50000 AND @msg LIKE N'%仅可调整处于 PENDING 的建议%'
    BEGIN UPDATE #counters SET pass = pass + 1; PRINT 'PASS: T10c 对已提交建议的调整被拒（50000：仅可调整处于 PENDING 的建议）'; END
    ELSE
    BEGIN UPDATE #counters SET fail = fail + 1; PRINT 'FAIL: T10c err=' + ISNULL(CAST(@err AS NVARCHAR(10)), N'') + N' msg=' + ISNULL(@msg, N''); END
END CATCH;
IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
GO
-- T11 E2E-06（完整链，在事务内执行后回滚）：下压 → 建议 → 提交 → 审批 → 两次收货 → CLOSED
DECLARE @err INT, @msg NVARCHAR(2048), @n INT, @imp BIT = 0;
DECLARE @emp_sm11 BIGINT = (SELECT employee_id FROM dbo.EmployeeAccount WHERE database_user_name = 'test_store_manager');
DECLARE @emp_sh11 BIGINT = (SELECT employee_id FROM dbo.EmployeeAccount WHERE database_user_name = 'test_shift_manager');
DECLARE @sugg11 BIGINT, @po11 BIGINT, @sug_qty11 DECIMAL(12,3), @on_hand11 DECIMAL(12,3), @first_qty DECIMAL(12,3) = 1.000;
BEGIN TRY
    BEGIN TRANSACTION;

    DECLARE @before11 DECIMAL(12,3) = (SELECT on_hand_qty FROM dbo.Inventory WHERE ingredient_id = 5);

    EXECUTE AS USER = 'test_store_manager'; SET @imp = 1;
    EXEC dbo.sp_adjust_inventory @ingredient_id = 5, @on_hand_delta = -200.000,
                                 @employee_id = @emp_sm11, @reason = N'10c T11：制造低库存';
    REVERT; SET @imp = 0;

    SET @sugg11 = (SELECT TOP (1) replenishment_suggestion_id FROM dbo.ReplenishmentSuggestion
                   WHERE ingredient_id = 5 AND suggestion_status = 'PENDING' ORDER BY replenishment_suggestion_id DESC);
    SET @sug_qty11 = (SELECT suggested_qty FROM dbo.ReplenishmentSuggestion WHERE replenishment_suggestion_id = @sugg11);
    IF @sugg11 IS NULL OR @sug_qty11 <= @first_qty THROW 51111, N'T11：未生成可分批收货的建议。', 1;

    EXECUTE AS USER = 'test_shift_manager'; SET @imp = 1;
    EXEC dbo.sp_submit_replenishment_suggestion @suggestion_id = @sugg11, @employee_id = @emp_sh11;
    REVERT; SET @imp = 0;

    EXECUTE AS USER = 'test_store_manager'; SET @imp = 1;
    EXEC dbo.sp_approve_replenishment_suggestion @suggestion_id = @sugg11, @manager_employee_id = @emp_sm11;
    REVERT; SET @imp = 0;

    SELECT @po11 = purchase_order_id FROM dbo.PurchaseOrder WHERE replenishment_suggestion_id = @sugg11;
    SET @on_hand11 = (SELECT on_hand_qty FROM dbo.Inventory WHERE ingredient_id = 5);

    EXECUTE AS USER = 'test_shift_manager'; SET @imp = 1;
    EXEC dbo.sp_receive_inventory @purchase_order_id = @po11, @employee_id = @emp_sh11, @received_qty = @first_qty;
    REVERT; SET @imp = 0;

    IF (SELECT purchase_status FROM dbo.PurchaseOrder WHERE purchase_order_id = @po11) <> 'PARTIALLY_RECEIVED'
        THROW 51111, N'T11：首次收货后采购单不是 PARTIALLY_RECEIVED。', 1;
    IF (SELECT on_hand_qty FROM dbo.Inventory WHERE ingredient_id = 5) <> @on_hand11 + @first_qty
        THROW 51111, N'T11：首次收货后现有量没有按收货量增加。', 1;

    DECLARE @rest_qty11 DECIMAL(12,3) = @sug_qty11 - @first_qty;   -- EXEC 实参位不接受表达式
    EXECUTE AS USER = 'test_shift_manager'; SET @imp = 1;
    EXEC dbo.sp_receive_inventory @purchase_order_id = @po11, @employee_id = @emp_sh11, @received_qty = @rest_qty11;
    REVERT; SET @imp = 0;

    IF (SELECT purchase_status FROM dbo.PurchaseOrder WHERE purchase_order_id = @po11) <> 'CLOSED'
        THROW 51111, N'T11：收齐后采购单不是 CLOSED。', 1;
    IF (SELECT suggestion_status FROM dbo.ReplenishmentSuggestion WHERE replenishment_suggestion_id = @sugg11) <> 'CLOSED'
        THROW 51111, N'T11：收齐后关联建议没有 CLOSED。', 1;
    IF (SELECT COUNT(*) FROM dbo.InventoryMovement WHERE movement_type = 'RECEIPT' AND reference_id = @po11) <> 2
        THROW 51111, N'T11：两次收货没有写两条 RECEIPT 流水。', 1;
    IF (SELECT on_hand_qty FROM dbo.Inventory WHERE ingredient_id = 5) <> @before11 - 200.000 + @sug_qty11
        THROW 51111, N'T11：收货后的现有量与「调整后 + 收货量」不一致。', 1;

    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    UPDATE #counters SET pass = pass + 1;
    PRINT 'PASS: T11 E2E-06 下压→建议→提交→审批→两次收货 APPROVED→PARTIALLY_RECEIVED→CLOSED，收货后现有量增加且账实相符';
END TRY
BEGIN CATCH
    SET @err = ERROR_NUMBER(); SET @msg = ERROR_MESSAGE();
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    IF @imp = 1 REVERT;
    UPDATE #counters SET fail = fail + 1;
    PRINT 'FAIL: T11 err=' + ISNULL(CAST(@err AS NVARCHAR(10)), N'') + N' msg=' + ISNULL(@msg, N'');
END CATCH;
IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
GO

-- T12 E2E-07：EXECUTE AS 下的正反权限（取餐员/厨师/收银/值班经理 × 视图与过程）
DECLARE @err INT, @msg NVARCHAR(2048), @n INT, @imp BIT = 0;
DECLARE @err2 INT, @msg2 NVARCHAR(2048), @imp2 BIT = 0;
DECLARE @err3 INT, @msg3 NVARCHAR(2048), @imp3 BIT = 0;
DECLARE @emp_ca12 BIGINT = (SELECT employee_id FROM dbo.EmployeeAccount WHERE database_user_name = 'test_cashier');
BEGIN TRY
    -- 正向：取餐员可查取餐看板
    EXECUTE AS USER = 'test_waiter'; SET @imp = 1;
    SET @n = (SELECT COUNT(*) FROM dbo.v_pickup_board);
    REVERT; SET @imp = 0;
    IF @n IS NULL THROW 51112, N'T12：取餐员读 v_pickup_board 失败。', 1;

    -- 反向：取餐员读含金额的订单视图被拒（229）
    BEGIN TRY
        EXECUTE AS USER = 'test_waiter'; SET @imp2 = 1;
        SET @n = (SELECT COUNT(*) FROM dbo.v_order_detail);
        REVERT; SET @imp2 = 0;
    END TRY
    BEGIN CATCH
        SET @err2 = ERROR_NUMBER(); SET @msg2 = ERROR_MESSAGE();
        IF @imp2 = 1 REVERT;
        SET @imp2 = 0;
    END CATCH;
    IF @err2 IS NULL OR @err2 <> 229 THROW 51112, N'T12：取餐员竟然读到 v_order_detail（期望 229）。', 1;

    -- 正向：厨师可查后厨队列
    EXECUTE AS USER = 'test_chef'; SET @imp = 1;
    SET @n = (SELECT COUNT(*) FROM dbo.v_kitchen_queue);
    REVERT; SET @imp = 0;
    IF @n IS NULL THROW 51112, N'T12：厨师读 v_kitchen_queue 失败。', 1;

    -- 反向：收银员不能调整库存（229）
    BEGIN TRY
        EXECUTE AS USER = 'test_cashier'; SET @imp3 = 1;
        EXEC dbo.sp_adjust_inventory @ingredient_id = 5, @on_hand_delta = 1.000,
                                     @employee_id = @emp_ca12, @reason = N'10c T12：越权尝试';
        REVERT; SET @imp3 = 0;
    END TRY
    BEGIN CATCH
        SET @err3 = ERROR_NUMBER(); SET @msg3 = ERROR_MESSAGE();
        IF @imp3 = 1 REVERT;
        SET @imp3 = 0;
    END CATCH;
    IF @err3 IS NULL OR @err3 <> 229 THROW 51112, N'T12：收银员调整库存没有被授权层拒绝（期望 229）。', 1;

    UPDATE #counters SET pass = pass + 1;
    PRINT 'PASS: T12 E2E-07 取餐员可查取餐板、查不到含金额视图，厨师可查后厨队列，收银员不能调整库存（229）';
END TRY
BEGIN CATCH
    SET @err = ERROR_NUMBER(); SET @msg = ERROR_MESSAGE();
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    IF @imp = 1 REVERT;
    UPDATE #counters SET fail = fail + 1;
    PRINT 'FAIL: T12 err=' + ISNULL(CAST(@err AS NVARCHAR(10)), N'') + N' msg=' + ISNULL(@msg, N'');
END CATCH;
GO

-- T12b E2E-07：收银员不能直接修改商品价格、库存或顾客积分（均应由过程维护）
DECLARE @err_price INT = NULL, @err_inventory INT = NULL, @err_points INT = NULL;
DECLARE @msg NVARCHAR(2048), @imp BIT = 0;
DECLARE @product12b BIGINT = (SELECT MIN(product_id) FROM dbo.Product);
DECLARE @ingredient12b BIGINT = (SELECT MIN(ingredient_id) FROM dbo.Inventory);
DECLARE @customer12b BIGINT = (SELECT MIN(customer_id) FROM dbo.Customer);
BEGIN TRY
    IF @product12b IS NULL OR @ingredient12b IS NULL OR @customer12b IS NULL
        THROW 51114, N'T12b：缺少商品、库存或顾客夹具。', 1;

    BEGIN TRANSACTION;
    BEGIN TRY
        EXECUTE AS USER = 'test_cashier'; SET @imp = 1;
        UPDATE dbo.Product SET base_price = base_price WHERE product_id = @product12b;
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        REVERT; SET @imp = 0;
    END TRY
    BEGIN CATCH
        SET @err_price = ERROR_NUMBER();
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        IF @imp = 1 REVERT;
        SET @imp = 0;
    END CATCH;

    BEGIN TRANSACTION;
    BEGIN TRY
        EXECUTE AS USER = 'test_cashier'; SET @imp = 1;
        UPDATE dbo.Inventory SET on_hand_qty = on_hand_qty WHERE ingredient_id = @ingredient12b;
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        REVERT; SET @imp = 0;
    END TRY
    BEGIN CATCH
        SET @err_inventory = ERROR_NUMBER();
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        IF @imp = 1 REVERT;
        SET @imp = 0;
    END CATCH;

    BEGIN TRANSACTION;
    BEGIN TRY
        EXECUTE AS USER = 'test_cashier'; SET @imp = 1;
        UPDATE dbo.Customer SET current_points = current_points WHERE customer_id = @customer12b;
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        REVERT; SET @imp = 0;
    END TRY
    BEGIN CATCH
        SET @err_points = ERROR_NUMBER();
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        IF @imp = 1 REVERT;
        SET @imp = 0;
    END CATCH;

    IF @err_price IS NULL OR @err_price <> 229
       OR @err_inventory IS NULL OR @err_inventory <> 229
       OR @err_points IS NULL OR @err_points <> 229
        THROW 51114, N'T12b：收银员直接 UPDATE 商品价格、库存或顾客积分未全部以 229 拒绝。', 1;

    UPDATE #counters SET pass = pass + 1;
    PRINT 'PASS: T12b 收银员不能直接修改商品价格、库存或顾客积分';
END TRY
BEGIN CATCH
    SET @msg = ERROR_MESSAGE();
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    IF @imp = 1 REVERT;
    UPDATE #counters SET fail = fail + 1;
    PRINT 'FAIL: T12b err=' + CAST(ERROR_NUMBER() AS NVARCHAR(10)) + N' msg=' + ISNULL(@msg, N'');
END CATCH;
GO

-- T12c E2E-07：骑手不能确认分配给其他员工的配送单
DECLARE @err INT = NULL, @msg NVARCHAR(2048), @imp BIT = 0;
DECLARE @order12c BIGINT = (SELECT order_id FROM dbo.SalesOrder WHERE order_no = 'B-SEED-DELIVERY-001');
DECLARE @other_employee12c BIGINT = (SELECT employee_id FROM dbo.EmployeeAccount WHERE database_user_name = 'test_waiter');
BEGIN TRY
    IF @order12c IS NULL OR @other_employee12c IS NULL
        THROW 51115, N'T12c：缺少外送种子订单或其他员工夹具。', 1;

    BEGIN TRANSACTION;
    UPDATE dbo.SalesOrder
    SET order_status = 'DELIVERING', completed_at = NULL
    WHERE order_id = @order12c;
    UPDATE dbo.Delivery
    SET rider_employee_id = @other_employee12c,
        delivery_status = 'DELIVERING',
        picked_up_at = SYSDATETIME(),
        delivered_at = NULL
    WHERE order_id = @order12c;

    BEGIN TRY
        EXECUTE AS USER = 'test_rider'; SET @imp = 1;
        EXEC dbo.sp_confirm_delivery @order_id = @order12c;
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        REVERT; SET @imp = 0;
    END TRY
    BEGIN CATCH
        SET @err = ERROR_NUMBER(); SET @msg = ERROR_MESSAGE();
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        IF @imp = 1 REVERT;
        SET @imp = 0;
    END CATCH;

    IF @err IS NULL OR @err <> 52702
        THROW 51115, N'T12c：骑手确认分配给其他员工的配送单未以 52702 拒绝。', 1;
    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.SalesOrder AS o
        JOIN dbo.Delivery AS d ON d.order_id = o.order_id
        WHERE o.order_id = @order12c
          AND o.order_status = 'COMPLETED'
          AND d.delivery_status = 'DELIVERED'
          AND d.rider_employee_id = (SELECT employee_id FROM dbo.EmployeeAccount WHERE database_user_name = 'test_rider')
    )
        THROW 51115, N'T12c：越权反例回滚后，外送种子订单未恢复原终态。', 1;

    UPDATE #counters SET pass = pass + 1;
    PRINT 'PASS: T12c 骑手不能确认分配给其他员工的配送单';
END TRY
BEGIN CATCH
    SET @err = ERROR_NUMBER(); SET @msg = ERROR_MESSAGE();
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    IF @imp = 1 REVERT;
    UPDATE #counters SET fail = fail + 1;
    PRINT 'FAIL: T12c err=' + ISNULL(CAST(@err AS NVARCHAR(10)), N'') + N' msg=' + ISNULL(@msg, N'');
END CATCH;
GO

-- T13 收货过程的守卫（E2E-06 的边界）：超量收货与已收齐再收均被拒
DECLARE @err INT, @msg NVARCHAR(2048), @imp BIT = 0;
DECLARE @emp_sh13 BIGINT = (SELECT employee_id FROM dbo.EmployeeAccount WHERE database_user_name = 'test_shift_manager');
DECLARE @po13 BIGINT = (SELECT MAX(purchase_order_id) FROM dbo.PurchaseOrder);
BEGIN TRY
    IF @po13 IS NULL THROW 51113, N'T13：库里没有采购单可供边界断言（09d 未执行？）。', 1;

    BEGIN TRY
        EXECUTE AS USER = 'test_shift_manager'; SET @imp = 1;
        EXEC dbo.sp_receive_inventory @purchase_order_id = @po13, @employee_id = @emp_sh13, @received_qty = 999.000;
        REVERT; SET @imp = 0;
        THROW 51113, N'T13：对已关闭采购单的超量收货竟然成功。', 1;
    END TRY
    BEGIN CATCH
        SET @err = ERROR_NUMBER(); SET @msg = ERROR_MESSAGE();
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        IF @imp = 1 REVERT;
        SET @imp = 0;
    END CATCH;
    IF @err <> 50000 OR @msg NOT LIKE N'%只允许对 APPROVED 或 PARTIALLY_RECEIVED%'
    BEGIN
        -- THROW 的 message 位不接受表达式，先拼进变量再抛
        DECLARE @diag13 NVARCHAR(400) =
            N'T13：已关闭采购单的收货拒绝原因非预期 err=' + ISNULL(CAST(@err AS NVARCHAR(10)), N'')
            + N' msg=' + ISNULL(@msg, N'');
        THROW 51113, @diag13, 1;
    END

    UPDATE #counters SET pass = pass + 1;
    PRINT 'PASS: T13 已关闭采购单再收货被拒（50000：只允许对 APPROVED 或 PARTIALLY_RECEIVED 收货）';
END TRY
BEGIN CATCH
    SET @err = ERROR_NUMBER(); SET @msg = ERROR_MESSAGE();
    UPDATE #counters SET fail = fail + 1;
    PRINT 'FAIL: T13 err=' + ISNULL(CAST(@err AS NVARCHAR(10)), N'') + N' msg=' + ISNULL(@msg, N'');
END CATCH;
GO

-- 收尾：打印 RESULT 并校验分母（17 条）——分母不足说明有批次被静默作废
DECLARE @pass INT = (SELECT pass FROM #counters);
DECLARE @fail INT = (SELECT fail FROM #counters);
PRINT 'RESULT: pass=' + CAST(@pass AS VARCHAR(10)) + ' fail=' + CAST(@fail AS VARCHAR(10));
IF @pass + @fail <> 17
    THROW 51199, N'10c：断言计数不足 17，说明有批次被静默作废（检查 -f 65001 与批次编译错误）。', 1;
IF @fail > 0
    THROW 51198, N'10c：存在失败的验收断言，详见上方 FAIL 行。', 1;
GO
