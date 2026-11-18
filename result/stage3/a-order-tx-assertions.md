# 25b 订单完成事务：A 提供的金额与库存断言素材

> 属主：A。用途：给 B 写 `sql/stage3/25b_tx_order_completion.sql` 直接取用；A 不改 B 的文件。
> 口径依据：`docs/stage3/three-person-implementation-plan.md` §6.2、`docs/stage3/sales-semantics.md` §2.4。
> 事务主体：`sp_finish_production`（制作完成）；库存实扣只经 `sp_consume_order_inventory`。取餐/送达终态**不再扣库存**。

## 1. 前置与夹具

1. 数据库已应用 v1.1（`20` + `21b` + `21a` 等），`SalesOrderItem.discount_rate / discount_amount` 已存在。
2. 执行者必须是启用 **PACKER** 员工：`sp_finish_production` 开头用 `USER_NAME()` 查 `job_code = 'PACKER'`，店长/收银身份会直接 `52100`。
3. 选一笔已支付、`order_status = 'IN_PRODUCTION'` 的测试订单；订单至少有一条 `SELLABLE` 明细，且创建时已成功锁库（`InventoryMovement` 里有本单 `LOCK` 行）。
4. 记录事务前快照；测试结束回滚或重置夹具。

```sql
DECLARE @order_id BIGINT = <测试订单>;

-- 事务前：订单头、明细净额、库存、本单已有流水
SELECT order_id, order_status, fulfillment_method, total_amount, production_finished_at
INTO #order_before
FROM dbo.SalesOrder WHERE order_id = @order_id;

SELECT i.ingredient_id, i.on_hand_qty, i.locked_qty
INTO #inv_before
FROM dbo.Inventory AS i
WHERE i.ingredient_id IN (
    SELECT m.ingredient_id FROM dbo.InventoryMovement AS m
    WHERE m.reference_type = 'ORDER' AND m.reference_id = @order_id);

SELECT COUNT(*) AS movement_rows_before
INTO #movement_count_before
FROM dbo.InventoryMovement
WHERE reference_type = 'ORDER' AND reference_id = @order_id;
```

## 2. 提交路径

```sql
BEGIN TRANSACTION;

EXEC dbo.sp_finish_production @order_id = @order_id;

-- (1) 状态与时间：PICKUP -> READY_FOR_PICKUP；DELIVERY -> READY_FOR_DELIVERY
IF NOT EXISTS (
    SELECT 1 FROM dbo.SalesOrder
    WHERE order_id = @order_id
      AND production_finished_at IS NOT NULL
      AND order_status = CASE fulfillment_method
                             WHEN 'PICKUP' THEN 'READY_FOR_PICKUP'
                             ELSE 'READY_FOR_DELIVERY' END)
    THROW 54130, N'25b 断言失败：制作完成后状态或 production_finished_at 不正确。', 1;

-- (2) 金额：total_amount 必须等于明细净额之和（v1.1 折扣列）
IF EXISTS (
    SELECT 1
    FROM dbo.SalesOrder AS o
    JOIN (
        SELECT order_id,
               net_amount = SUM(CAST(ROUND(unit_price * quantity, 2) AS DECIMAL(12,2)) - discount_amount)
        FROM dbo.SalesOrderItem
        WHERE order_id = @order_id AND item_role = 'SELLABLE'
        GROUP BY order_id
    ) AS x ON x.order_id = o.order_id
    WHERE o.order_id = @order_id AND o.total_amount <> x.net_amount)
    THROW 54131, N'25b 断言失败：total_amount 与明细净额之和不一致。', 1;

-- (3) 至少有一条 CONSUME 流水；没有就说明制作完成没有实扣
IF NOT EXISTS (
    SELECT 1 FROM dbo.InventoryMovement
    WHERE reference_type = 'ORDER' AND reference_id = @order_id AND movement_type = 'CONSUME')
    THROW 54132, N'25b 断言失败：制作完成后没有 CONSUME 流水。', 1;

-- (3b) 每条原料：现有量与锁定量同减，差值等于本单 CONSUME 量
IF EXISTS (
    SELECT 1
    FROM #inv_before AS b
    JOIN dbo.Inventory AS a ON a.ingredient_id = b.ingredient_id
    JOIN (
        SELECT ingredient_id, consume_qty = -SUM(on_hand_delta)
        FROM dbo.InventoryMovement
        WHERE reference_type = 'ORDER' AND reference_id = @order_id AND movement_type = 'CONSUME'
        GROUP BY ingredient_id
    ) AS c ON c.ingredient_id = b.ingredient_id
    WHERE b.on_hand_qty - a.on_hand_qty <> c.consume_qty
       OR b.locked_qty   - a.locked_qty   <> c.consume_qty)
    THROW 54132, N'25b 断言失败：库存现有量/锁定量与 CONSUME 流水不一致。', 1;

-- (4) CONSUME 流水：每条原料一行，on_hand_delta 与 locked_delta 都为负且相等
IF EXISTS (
    SELECT 1
    FROM dbo.InventoryMovement
    WHERE reference_type = 'ORDER' AND reference_id = @order_id AND movement_type = 'CONSUME'
    GROUP BY ingredient_id
    HAVING COUNT(*) <> 1
        OR SUM(on_hand_delta) <> SUM(locked_delta)
        OR SUM(on_hand_delta) >= 0)
    THROW 54133, N'25b 断言失败：CONSUME 流水形状不正确。', 1;

-- (5) 外送订单必须恰好一行 Delivery；自取订单不生成
IF EXISTS (
    SELECT 1 FROM dbo.SalesOrder
    WHERE order_id = @order_id AND fulfillment_method = 'DELIVERY')
   AND (SELECT COUNT(*) FROM dbo.Delivery WHERE order_id = @order_id) <> 1
    THROW 54134, N'25b 断言失败：外送订单的 Delivery 行数不是 1。', 1;
IF EXISTS (
    SELECT 1 FROM dbo.SalesOrder
    WHERE order_id = @order_id AND fulfillment_method = 'PICKUP')
   AND EXISTS (SELECT 1 FROM dbo.Delivery WHERE order_id = @order_id)
    THROW 54135, N'25b 断言失败：自取订单不应生成 Delivery 行。', 1;

COMMIT TRANSACTION;
```

提交后重新查询确认 `order_status`、`production_finished_at`、库存与 `CONSUME` 流水仍在。

## 3. 拒绝与重复调用

```sql
-- 3.1 重复制作完成：第二次必须被状态守卫拒绝（52401），库存不得再变
BEGIN TRY
    EXEC dbo.sp_finish_production @order_id = @order_id;
    THROW 54136, N'25b 断言失败：第二次制作完成没有被拒绝。', 1;
END TRY
BEGIN CATCH
    IF ERROR_NUMBER() <> 52401
        THROW;
END CATCH;

-- 3.2 不存在订单：52401
BEGIN TRY
    EXEC dbo.sp_finish_production @order_id = -1;
    THROW 54137, N'25b 断言失败：不存在的订单没有被拒绝。', 1;
END TRY
BEGIN CATCH
    IF ERROR_NUMBER() <> 52401
        THROW;
END CATCH;

-- 3.3 无锁定量/库存不足：sp_consume_order_inventory 拒绝（50000）
--     夹具：在回滚事务里直接删除本单 LOCK 流水，或把 locked_qty 调到小于待实扣量
```

非 PACKER 身份调用应返回 `52100`；无明细或没有待实扣锁定量时，`sp_consume_order_inventory` 返回 `50000`。B 可在 25b 脚本里先做可读性预检，但不要为此改 v1.0 过程。

## 4. 回滚路径

```sql
BEGIN TRY
    BEGIN TRANSACTION;
    EXEC dbo.sp_finish_production @order_id = @order_id;
    THROW 54138, N'25b 回滚路径：制作完成后主动失败。', 1;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;
    -- 这里不要 THROW，先做下面的回滚断言；断言失败再抛
END CATCH;

-- 回滚后断言：
-- 1) @@TRANCOUNT = 0
-- 2) SalesOrder 的 order_status / production_finished_at 回到 #order_before
-- 3) Inventory 的 on_hand_qty / locked_qty 回到 #inv_before
-- 4) 本单 InventoryMovement 行数回到 #movement_count_before
-- 5) Delivery 不残留本单新行
```

回滚后逐项比对快照；不要只看报错文本。脚本结束打印 `@@TRANCOUNT`，非 0 判失败。

## 5. 边界提醒

- **不要**在 25b 里再调 `sp_pick_up_order` / `sp_confirm_delivery` 来“完成扣库存”：这两个过程不扣库存，实扣已在制作完成发生；终态只改状态与积分。
- 金额断言对 v1.0 存量订单同样成立：两列折扣为 0，`total_amount` 等于毛额之和。
- 库存断言只覆盖本单锁过库的原料；不要用全表库存变化做比较，避免别的会话干扰。
- 失败用例必须发生在已写入部分数据之后（例如 `sp_finish_production` 成功后再 `THROW`），只在执行前拒绝参数不能证明回滚。
- 25b 的断言码建议从 `542xx` 段取，本文的 `541xx` 只是示意；最终以 B 的脚本为准。
