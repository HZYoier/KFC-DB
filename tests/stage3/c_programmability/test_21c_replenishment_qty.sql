-- ============================================================================
-- test_21c_replenishment_qty.sql — C 域补货量函数测试（成员 C；2026-11-15）
-- 运行时机：v0.1 已部署，20_schema_v1_1.sql 与 21c_inventory_programmability.sql 已执行。
-- 运行方式：
--   sqlcmd -S '.\SQLEXPRESS' -E -C -f 65001 -b -d KFC_DB -i 本文件
-- 口径：可售量 = on_hand_qty - locked_qty（与 v_inventory_available 一致）；
--       目标量优先于最低量；达到目标返回 0；原料不存在/目标为负/两者皆空返回 NULL。
-- 分母：10（8 个边界/异常用例 + 目标优先 + 非负性质）。
-- 断言码：54930 前置缺失、54931 夹具不成立、54998 有失败、54999 分母不足。
-- ============================================================================
:on error exit
USE KFC_DB;
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF OBJECT_ID(N'dbo.fn_replenishment_qty', N'FN') IS NULL
    THROW 54930, N'缺少 dbo.fn_replenishment_qty；请先执行 sql/stage3/21c_inventory_programmability.sql。', 1;

DECLARE @ingredient_id BIGINT;
DECLARE @on_hand DECIMAL(12,3), @locked DECIMAL(12,3), @available DECIMAL(12,3);

SELECT TOP (1)
       @ingredient_id = i.ingredient_id,
       @on_hand = inv.on_hand_qty,
       @locked = inv.locked_qty,
       @available = CAST(inv.on_hand_qty - inv.locked_qty AS DECIMAL(12,3))
FROM dbo.Ingredient AS i
JOIN dbo.Inventory AS inv ON inv.ingredient_id = i.ingredient_id
WHERE i.status = 'ACTIVE'
  AND inv.on_hand_qty >= inv.locked_qty
  AND inv.on_hand_qty >= CAST(5.000 AS DECIMAL(12,3))
ORDER BY i.ingredient_id;

IF @ingredient_id IS NULL OR @available IS NULL
    THROW 54931, N'找不到 on_hand >= locked 且 >= 5 的启用原料，无法构造补货量夹具。', 1;

IF OBJECT_ID(N'tempdb..#counters_fn') IS NOT NULL DROP TABLE #counters_fn;
CREATE TABLE #counters_fn (pass INT NOT NULL, fail INT NOT NULL);
INSERT INTO #counters_fn (pass, fail) VALUES (0, 0);

DECLARE @actual DECIMAL(12,3);
DECLARE @high_target DECIMAL(12,3) = @available + CAST(10.000 AS DECIMAL(12,3));
DECLARE @min_target DECIMAL(12,3) = @available + CAST(7.000 AS DECIMAL(12,3));
DECLARE @zero DECIMAL(12,3) = CAST(0.000 AS DECIMAL(12,3));
DECLARE @one DECIMAL(12,3) = CAST(1.000 AS DECIMAL(12,3));

-- 1. 低于目标：返回目标减可售量，保留 3 位小数
SET @actual = dbo.fn_replenishment_qty(@ingredient_id, @high_target, NULL);
IF @actual = CAST(10.000 AS DECIMAL(12,3))
    UPDATE #counters_fn SET pass = pass + 1;
ELSE
    UPDATE #counters_fn SET fail = fail + 1;

-- 2. 刚好达到目标：返回 0
SET @actual = dbo.fn_replenishment_qty(@ingredient_id, @available, NULL);
IF @actual = @zero
    UPDATE #counters_fn SET pass = pass + 1;
ELSE
    UPDATE #counters_fn SET fail = fail + 1;

-- 3. 目标为 0 且可售量不低于 0：返回 0
SET @actual = dbo.fn_replenishment_qty(@ingredient_id, @zero, NULL);
IF @actual = @zero
    UPDATE #counters_fn SET pass = pass + 1;
ELSE
    UPDATE #counters_fn SET fail = fail + 1;

-- 4. 目标为空时使用最低量
SET @actual = dbo.fn_replenishment_qty(@ingredient_id, NULL, @min_target);
IF @actual = CAST(7.000 AS DECIMAL(12,3))
    UPDATE #counters_fn SET pass = pass + 1;
ELSE
    UPDATE #counters_fn SET fail = fail + 1;

-- 5. 目标与最低量都为空：NULL
SET @actual = dbo.fn_replenishment_qty(@ingredient_id, NULL, NULL);
IF @actual IS NULL
    UPDATE #counters_fn SET pass = pass + 1;
ELSE
    UPDATE #counters_fn SET fail = fail + 1;

-- 6. 原料不存在：NULL（不抛错）
SET @actual = dbo.fn_replenishment_qty(CAST(999999999 AS BIGINT), @high_target, NULL);
IF @actual IS NULL
    UPDATE #counters_fn SET pass = pass + 1;
ELSE
    UPDATE #counters_fn SET fail = fail + 1;

-- 7. 目标量为负：按 NULL 处理
SET @actual = dbo.fn_replenishment_qty(@ingredient_id, CAST(-1.000 AS DECIMAL(12,3)), NULL);
IF @actual IS NULL
    UPDATE #counters_fn SET pass = pass + 1;
ELSE
    UPDATE #counters_fn SET fail = fail + 1;

-- 8. 目标为空、最低量为负：仍按 NULL 处理
SET @actual = dbo.fn_replenishment_qty(@ingredient_id, NULL, CAST(-1.000 AS DECIMAL(12,3)));
IF @actual IS NULL
    UPDATE #counters_fn SET pass = pass + 1;
ELSE
    UPDATE #counters_fn SET fail = fail + 1;

-- 9. 目标量优先于最低量：目标为 high_target，最低量再大也不参与
SET @actual = dbo.fn_replenishment_qty(@ingredient_id, @high_target,
                                       @available + CAST(99.000 AS DECIMAL(12,3)));
IF @actual = CAST(10.000 AS DECIMAL(12,3))
    UPDATE #counters_fn SET pass = pass + 1;
ELSE
    UPDATE #counters_fn SET fail = fail + 1;

-- 10. 非负性质：对 0、1、可售量、可售量+10 四个目标，结果都 >= 0
IF NOT EXISTS
(
    SELECT 1
    FROM (VALUES (@zero), (@one), (@available), (@high_target)) AS t(target_qty)
    CROSS APPLY (SELECT dbo.fn_replenishment_qty(@ingredient_id, t.target_qty, NULL) AS qty) AS f
    WHERE f.qty < 0
)
    UPDATE #counters_fn SET pass = pass + 1;
ELSE
    UPDATE #counters_fn SET fail = fail + 1;

DECLARE @pass INT = (SELECT pass FROM #counters_fn);
DECLARE @fail INT = (SELECT fail FROM #counters_fn);
DECLARE @total INT = @pass + @fail;

PRINT CONCAT(N'RESULT: c-programmability replenishment pass=', @pass,
             N' fail=', @fail, N' total=', @total);
IF @total <> 10
    THROW 54999, N'补货量测试分母不足：期望 10 条，实际计数不是 10。', 1;
IF @fail > 0
    THROW 54998, N'补货量测试存在失败断言。', 1;
GO
