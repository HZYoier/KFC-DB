-- ============================================================================
-- 09d_inventory_replenishment_seed_data.sql
-- 负责人：C（库存、补货、员工权限、审计与总集成）
-- 用途：订单后的补货与收货数据——先核对 09b 的三笔种子订单已跑出 LOCK / CONSUME /
--       RELEASE 三类库存流水，以及 09c 的压线设计已由实扣触发一张待审建议；
--       随后只经业务过程完成「值班经理提交 → 店长审批 → 值班经理两次收货」：
--       采购单 APPROVED → PARTIALLY_RECEIVED → CLOSED、关联建议随之 CLOSED、
--       现有量回到安全线，共写两组 PURCHASE_ORDER 的 RECEIPT 流水。
-- 依赖：01（A 域原料与安全线）、03（C 域表）、06（补货与收货过程，含批次 6 的
--       sp_receive_inventory）、08（role_* 与 test_* 用户）、09a（A 域主数据）、
--       09b（B 的三笔种子订单，本文件只读校核、不新增不修改）、
--       09c（C 域种子：角色、员工、权限与期初库存——低库存起点来自它的压线设计）。
-- 依据：docs/stage1-three-person-implementation-plan.md §5 C-3 line 321、
--       docs/stage1-cross-domain-interface-contract.md §3.5（收货过程签名）、§3.3（实扣后生成建议）。
-- 说明：① 本文件不直接 INSERT / UPDATE / DELETE 任何表，全部动作经业务过程完成；
--       ② 期望值尽量从数据推导（消耗量取自实扣流水、建议量取自安全线），避免写死；
--       ③ 幂等守卫：若已存在采购单（说明本文件已执行过）则拒绝重跑（THROW 51023）；
--       ④ 两次收货各为「1.000 + 剩余量」，第二次收齐；收齐后才会把建议置 CLOSED；
--       ⑤ 局部变量不跨批次：下面三个批次各自 DECLARE 自己需要的变量（否则报 Msg 137）。
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

-- 前置校验（守卫 51020–51023）：只允许在 09b/09c 之后的、未跑过本文件的库上执行
IF EXISTS (SELECT 1 FROM dbo.PurchaseOrder)
    THROW 51023, N'09d：已存在采购单（本文件可能已执行过），拒绝重跑。', 1;

IF (SELECT COUNT(*) FROM dbo.SalesOrder
    WHERE order_no IN ('B-SEED-PICKUP-001', 'B-SEED-DELIVERY-001', 'B-SEED-CANCEL-001')) <> 3
   OR NOT EXISTS (SELECT 1 FROM dbo.SalesOrder WHERE order_no = 'B-SEED-PICKUP-001'   AND order_status = 'PICKED_UP')
   OR NOT EXISTS (SELECT 1 FROM dbo.SalesOrder WHERE order_no = 'B-SEED-DELIVERY-001' AND order_status = 'COMPLETED')
   OR NOT EXISTS (SELECT 1 FROM dbo.SalesOrder WHERE order_no = 'B-SEED-CANCEL-001'   AND order_status = 'CANCELLED')
    THROW 51020, N'09d：B 的三笔种子订单不齐或终态不符（期望自取完成 / 外送完成 / 未支付取消），请先执行 09b_order_seed_data.sql。', 1;

-- 流水是「每原料一行」：同一订单锁了 4 种原料就有 4 条 LOCK，故这里按单据去重数订单
DECLARE @lock_n INT = (SELECT COUNT(DISTINCT im.reference_id) FROM dbo.InventoryMovement AS im WHERE im.movement_type = 'LOCK'    AND im.reference_type = 'ORDER');
DECLARE @cons_n INT = (SELECT COUNT(DISTINCT im.reference_id) FROM dbo.InventoryMovement AS im WHERE im.movement_type = 'CONSUME' AND im.reference_type = 'ORDER');
DECLARE @rel_n  INT = (SELECT COUNT(DISTINCT im.reference_id) FROM dbo.InventoryMovement AS im WHERE im.movement_type = 'RELEASE' AND im.reference_type = 'ORDER');

IF @lock_n <> 3 OR @cons_n <> 2 OR @rel_n <> 1
    THROW 51021, N'09d：三笔种子订单的库存流水不是「锁定 3 单 / 实扣 2 单 / 释放 1 单」，请核对 09b 的订单流程。', 1;

IF EXISTS (SELECT 1 FROM dbo.InventoryMovement WHERE ingredient_id = 5)
    THROW 51021, N'09d：薯条（ingredient_id = 5）出现了库存流水——种子订单不应消耗薯条，09c 的压线口径需复核。', 1;

-- 期望值全部从数据推导：消耗量取自实扣流水，压线基准取自 A 的安全线
DECLARE @consumed_qty DECIMAL(12,3) =
    (SELECT -SUM(im.on_hand_delta)
     FROM dbo.InventoryMovement AS im
     WHERE im.ingredient_id = 1 AND im.movement_type = 'CONSUME');
DECLARE @safety_qty DECIMAL(12,3) =
    (SELECT i.safety_stock_qty FROM dbo.Ingredient AS i WHERE i.ingredient_id = 1);
DECLARE @packer_id BIGINT =
    (SELECT ea.employee_id FROM dbo.EmployeeAccount AS ea WHERE ea.database_user_name = N'test_packer');

IF @consumed_qty IS NULL OR @consumed_qty <= 0 OR @safety_qty IS NULL
    THROW 51021, N'09d：读不到鸡腿肉的实扣消耗量或安全线，前置状态不成立。', 1;

IF (SELECT COUNT(*) FROM dbo.ReplenishmentSuggestion WHERE suggestion_status = 'PENDING') <> 1
    THROW 51022, N'09d：待审建议不是恰好一张（期望由 09c 的压线 + 09b 的实扣自动生成），前置状态不成立。', 1;

DECLARE @suggestion_id BIGINT;
DECLARE @current_qty DECIMAL(12,3);
DECLARE @suggested_qty DECIMAL(12,3);
DECLARE @sugg_ingredient_id BIGINT;
DECLARE @sugg_created_by BIGINT;

SELECT @suggestion_id      = rs.replenishment_suggestion_id,
       @current_qty        = rs.current_qty,
       @suggested_qty      = rs.suggested_qty,
       @sugg_ingredient_id = rs.ingredient_id,
       @sugg_created_by    = rs.created_by_employee_id
FROM dbo.ReplenishmentSuggestion AS rs
WHERE rs.suggestion_status = 'PENDING';

IF @sugg_ingredient_id <> 1
   OR @current_qty <> @safety_qty - @consumed_qty
   OR @suggested_qty <> @consumed_qty
   OR @sugg_created_by <> @packer_id
    THROW 51022, N'09d：待审建议的原料 / 当前量 / 建议量 / 创建人与期望不符（期望：鸡腿肉、当前量 = 安全线 − 实扣量、建议量 = 实扣量、创建人 = 触发实扣的配餐员）。', 1;
GO

-- 批次 2：业务链路——提交 → 审批 → 两次收货（全部经过程；EXECUTE AS 的收尾顺序见 CATCH）
-- 本批次自带变量：局部变量不跨批次，批次 1 的 @suggestion_id / @suggested_qty 在这里重新取
DECLARE @suggestion_id BIGINT =
    (SELECT rs.replenishment_suggestion_id FROM dbo.ReplenishmentSuggestion AS rs WHERE rs.suggestion_status = 'PENDING');
DECLARE @suggested_qty DECIMAL(12,3) =
    (SELECT rs.suggested_qty FROM dbo.ReplenishmentSuggestion AS rs WHERE rs.replenishment_suggestion_id = @suggestion_id);
DECLARE @shift_manager_id BIGINT =
    (SELECT ea.employee_id FROM dbo.EmployeeAccount AS ea WHERE ea.database_user_name = N'test_shift_manager');
DECLARE @store_manager_id BIGINT =
    (SELECT ea.employee_id FROM dbo.EmployeeAccount AS ea WHERE ea.database_user_name = N'test_store_manager');
DECLARE @impersonating BIT = 0;
DECLARE @purchase_order_id BIGINT;
DECLARE @second_receipt_qty DECIMAL(12,3) = @suggested_qty - 1.000;

IF @suggestion_id IS NULL OR @suggested_qty IS NULL OR @shift_manager_id IS NULL OR @store_manager_id IS NULL
    THROW 51022, N'09d：批次 2 读不到待审建议或测试员工档案，前置状态不成立。', 1;

IF @second_receipt_qty <= 0
    THROW 51022, N'09d：建议量不足 1.000 以上，无法演示两次收货（期望值推导有误）。', 1;

BEGIN TRY
    BEGIN TRANSACTION;

    EXECUTE AS USER = N'test_shift_manager';
    SET @impersonating = 1;
    EXEC dbo.sp_submit_replenishment_suggestion
         @suggestion_id = @suggestion_id,
         @employee_id   = @shift_manager_id;
    REVERT;
    SET @impersonating = 0;

    EXECUTE AS USER = N'test_store_manager';
    SET @impersonating = 1;
    EXEC dbo.sp_approve_replenishment_suggestion
         @suggestion_id       = @suggestion_id,
         @manager_employee_id = @store_manager_id;
    REVERT;
    SET @impersonating = 0;

    SELECT @purchase_order_id = po.purchase_order_id
    FROM dbo.PurchaseOrder AS po
    WHERE po.replenishment_suggestion_id = @suggestion_id;

    EXECUTE AS USER = N'test_shift_manager';
    SET @impersonating = 1;
    EXEC dbo.sp_receive_inventory
         @purchase_order_id = @purchase_order_id,
         @employee_id       = @shift_manager_id,
         @received_qty      = 1.000;
    REVERT;
    SET @impersonating = 0;

    EXECUTE AS USER = N'test_shift_manager';
    SET @impersonating = 1;
    EXEC dbo.sp_receive_inventory
         @purchase_order_id = @purchase_order_id,
         @employee_id       = @shift_manager_id,
         @received_qty      = @second_receipt_qty;
    REVERT;
    SET @impersonating = 0;

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    -- 顺序要紧：必须先 ROLLBACK 再 REVERT（过程内部 SET XACT_ABORT ON 会 doom 外层事务，
    -- 不可提交事务里 REVERT 会被拒 Msg 3930）。见 plan §8 2026-09-27 行与 §8.5 第 21⑦ 条。
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    IF @impersonating = 1 REVERT;
    THROW;
END CATCH;
GO

-- 自查（51024–51029）：收货链终态必须与计划 §5 C-3 line 321 的期望一致
-- 本批次自带变量（不跨批次）：消耗量与安全线在这里重新取
DECLARE @consumed_qty DECIMAL(12,3) =
    (SELECT -SUM(im.on_hand_delta)
     FROM dbo.InventoryMovement AS im
     WHERE im.ingredient_id = 1 AND im.movement_type = 'CONSUME');
DECLARE @safety_qty DECIMAL(12,3) =
    (SELECT i.safety_stock_qty FROM dbo.Ingredient AS i WHERE i.ingredient_id = 1);
IF NOT EXISTS (SELECT 1
               FROM dbo.PurchaseOrder AS po
               JOIN dbo.PurchaseOrderItem AS poi ON poi.purchase_order_id = po.purchase_order_id
               WHERE po.purchase_order_id = (SELECT MAX(purchase_order_id) FROM dbo.PurchaseOrder)
                 AND po.purchase_status = 'CLOSED'
                 AND poi.received_qty = poi.ordered_qty)
    THROW 51024, N'09d：采购单未走到 CLOSED 或未收齐。', 1;

IF (SELECT COUNT(*) FROM dbo.PurchaseOrder) <> 1
    THROW 51024, N'09d：采购单不是恰好一张。', 1;

IF (SELECT COUNT(*) FROM dbo.PurchaseOrderItem) <> 1
    THROW 51025, N'09d：采购单明细不是恰好一条（§6 不变量 4）。', 1;

IF NOT EXISTS (SELECT 1
               FROM dbo.ReplenishmentSuggestion
               WHERE replenishment_suggestion_id = (SELECT MAX(replenishment_suggestion_id) FROM dbo.ReplenishmentSuggestion)
                 AND suggestion_status = 'CLOSED')
    THROW 51026, N'09d：收齐后关联建议没有转为 CLOSED。', 1;

DECLARE @on_hand_after DECIMAL(12,3) = (SELECT i.on_hand_qty FROM dbo.Inventory AS i WHERE i.ingredient_id = 1);

IF @on_hand_after <> @safety_qty
    THROW 51027, N'09d：收货后鸡腿肉现有量没有回到安全线。', 1;

IF (SELECT COUNT(*) FROM dbo.InventoryMovement WHERE movement_type = 'RECEIPT') <> 2
    THROW 51028, N'09d：RECEIPT 流水不是两条（两次收货各一条）。', 1;

IF (SELECT SUM(im.on_hand_delta) FROM dbo.InventoryMovement AS im
    WHERE im.movement_type = 'RECEIPT' AND im.ingredient_id = 1) <> @consumed_qty
    THROW 51028, N'09d：收货总量与实扣消耗量不相等，账实不平。', 1;

IF (SELECT COUNT(*) FROM dbo.AuditLog WHERE action_name = 'RECEIVE_INVENTORY') <> 2
   OR (SELECT COUNT(*) FROM dbo.AuditLog WHERE action_name = 'APPROVE_REPLENISHMENT_SUGGESTION') < 1
   OR (SELECT COUNT(*) FROM dbo.AuditLog WHERE action_name = 'SUBMIT_REPLENISHMENT_SUGGESTION') < 1
    THROW 51029, N'09d：收货 / 审批 / 提交的审计条目不全。', 1;

IF EXISTS (SELECT 1 FROM dbo.ReplenishmentSuggestion WHERE suggestion_status IN ('PENDING', 'SUBMITTED', 'APPROVED'))
    THROW 51029, N'09d：仍有开放建议（收货后应无 PENDING/SUBMITTED/APPROVED）。', 1;
GO

-- 自查结果集：供人工核对（不符时上面的断言已先中止）
SELECT 'purchase_orders'      AS k, COUNT(*) AS n FROM dbo.PurchaseOrder
UNION ALL SELECT 'purchase_order_items', COUNT(*) FROM dbo.PurchaseOrderItem
UNION ALL SELECT 'receipt_flows',        COUNT(*) FROM dbo.InventoryMovement WHERE movement_type = 'RECEIPT'
UNION ALL SELECT 'open_suggestions',     COUNT(*) FROM dbo.ReplenishmentSuggestion WHERE suggestion_status IN ('PENDING', 'SUBMITTED', 'APPROVED')
UNION ALL SELECT 'closed_suggestions',   COUNT(*) FROM dbo.ReplenishmentSuggestion WHERE suggestion_status = 'CLOSED';

-- 完成标记：能打印到这一行即说明守卫（51020–51023）与自查（51024–51029）全部通过、批次未静默作废
PRINT N'09d 完成：采购单 CLOSED 且收齐、关联建议 CLOSED、现有量回到安全线、RECEIPT 两条、审计齐备。';
GO
