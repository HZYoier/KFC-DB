-- ============================================================================
-- test_21a_sales_summary.sql — A 域商品销售汇总函数测试（成员 A）
-- 运行时机：v1.1 迁移已提交；B 的 21b 已创建 v_settled_sales_line；21a 已建函数
-- 运行方式：sqlcmd -S localhost -E -C -f 65001 -b -d KFC_DB -i 本文件
-- 口径：docs/stage3/sales-semantics.md §1
-- 写法：函数结果与"直接聚合视图"逐商品比对；缺视图/缺数据直接 THROW，不跳过。
-- 分母：15
-- 断言码：54930 前置不成立、54931 夹具不成立、54998 有失败、54999 分母不足
-- ============================================================================
:on error exit
USE KFC_DB;
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF OBJECT_ID(N'dbo.v_settled_sales_line', N'V') IS NULL
    THROW 54930, N'缺少 dbo.v_settled_sales_line；请先执行 B 的 sql/stage3/21b_order_programmability.sql。', 1;
IF OBJECT_ID(N'dbo.fn_product_sales_summary', N'IF') IS NULL
    THROW 54930, N'缺少 dbo.fn_product_sales_summary；请先执行 sql/stage3/21a_master_programmability.sql。', 1;

DECLARE @start DATE = (SELECT MIN(CAST(l.completed_at AS DATE)) FROM dbo.v_settled_sales_line AS l);
DECLARE @end   DATE = (SELECT MAX(CAST(l.completed_at AS DATE)) FROM dbo.v_settled_sales_line AS l);
IF @start IS NULL OR @end IS NULL
    THROW 54931, N'v_settled_sales_line 没有已结算行，销售汇总无夹具；先跑通订单完成路径。', 1;

IF OBJECT_ID(N'tempdb..#counters_summary') IS NOT NULL DROP TABLE #counters_summary;
CREATE TABLE #counters_summary (pass INT NOT NULL, fail INT NOT NULL);
INSERT INTO #counters_summary (pass, fail) VALUES (0, 0);

CREATE TABLE #expected
(
    product_id   BIGINT NOT NULL,
    product_name NVARCHAR(100) NOT NULL,
    sold_qty     INT NOT NULL,
    sales_amount DECIMAL(12,2) NOT NULL,
    order_count  INT NOT NULL
);
CREATE TABLE #actual
(
    product_id   BIGINT NOT NULL,
    product_name NVARCHAR(100) NOT NULL,
    sold_qty     INT NOT NULL,
    sales_amount DECIMAL(12,2) NOT NULL,
    order_count  INT NOT NULL
);

INSERT INTO #expected (product_id, product_name, sold_qty, sales_amount, order_count)
SELECT
    l.product_id,
    l.product_name,
    SUM(l.quantity),
    CAST(SUM(l.net_amount) AS DECIMAL(12,2)),
    COUNT(DISTINCT l.order_id)
FROM dbo.v_settled_sales_line AS l
WHERE l.completed_at >= @start
  AND l.completed_at <  DATEADD(DAY, 1, @end)
GROUP BY l.product_id, l.product_name;

INSERT INTO #actual (product_id, product_name, sold_qty, sales_amount, order_count)
SELECT f.product_id, f.product_name, f.sold_qty, f.sales_amount, f.order_count
FROM dbo.fn_product_sales_summary(@start, @end) AS f;

-- S-01 函数结果没有多出商品
IF NOT EXISTS
(
    SELECT product_id, product_name, sold_qty, sales_amount, order_count FROM #actual
    EXCEPT
    SELECT product_id, product_name, sold_qty, sales_amount, order_count FROM #expected
)
    INSERT INTO #counters_summary VALUES (1, 0);
ELSE
    INSERT INTO #counters_summary VALUES (0, 1);

-- S-02 函数结果没有漏掉商品
IF NOT EXISTS
(
    SELECT product_id, product_name, sold_qty, sales_amount, order_count FROM #expected
    EXCEPT
    SELECT product_id, product_name, sold_qty, sales_amount, order_count FROM #actual
)
    INSERT INTO #counters_summary VALUES (1, 0);
ELSE
    INSERT INTO #counters_summary VALUES (0, 1);

-- S-03 总销量一致
IF (SELECT SUM(sold_qty) FROM #actual) = (SELECT SUM(quantity) FROM dbo.v_settled_sales_line
                                          WHERE completed_at >= @start
                                            AND completed_at < DATEADD(DAY, 1, @end))
    INSERT INTO #counters_summary VALUES (1, 0);
ELSE
    INSERT INTO #counters_summary VALUES (0, 1);

-- S-04 总净额一致
IF (SELECT SUM(sales_amount) FROM #actual) = (SELECT CAST(SUM(net_amount) AS DECIMAL(12,2))
                                              FROM dbo.v_settled_sales_line
                                              WHERE completed_at >= @start
                                                AND completed_at < DATEADD(DAY, 1, @end))
    INSERT INTO #counters_summary VALUES (1, 0);
ELSE
    INSERT INTO #counters_summary VALUES (0, 1);

-- S-05 视图净额 = 毛额 - 折扣额
IF NOT EXISTS
(
    SELECT 1 FROM dbo.v_settled_sales_line AS l
    WHERE l.net_amount <> l.gross_amount - l.discount_amount
)
    INSERT INTO #counters_summary VALUES (1, 0);
ELSE
    INSERT INTO #counters_summary VALUES (0, 1);

-- S-06 视图行数 = 已结算订单的 SELLABLE 明细行数（套餐子项不得进入）
IF (SELECT COUNT(*) FROM dbo.v_settled_sales_line) =
   (SELECT COUNT(*)
    FROM dbo.SalesOrderItem AS i
    JOIN dbo.SalesOrder AS o ON o.order_id = i.order_id
    WHERE o.order_status IN ('PICKED_UP', 'COMPLETED')
      AND o.completed_at IS NOT NULL
      AND i.item_role = 'SELLABLE'
      AND i.quantity > 0)
    INSERT INTO #counters_summary VALUES (1, 0);
ELSE
    INSERT INTO #counters_summary VALUES (0, 1);

-- S-07 两种终态都有订单进入视图
IF EXISTS (SELECT 1 FROM dbo.v_settled_sales_line AS l JOIN dbo.SalesOrder AS o ON o.order_id = l.order_id
           WHERE o.order_status = 'PICKED_UP')
   AND EXISTS (SELECT 1 FROM dbo.v_settled_sales_line AS l JOIN dbo.SalesOrder AS o ON o.order_id = l.order_id
               WHERE o.order_status = 'COMPLETED')
    INSERT INTO #counters_summary VALUES (1, 0);
ELSE
    INSERT INTO #counters_summary VALUES (0, 1);

-- S-08 区间末日单独查询仍有结果（completed_at 带时分秒）
IF EXISTS (SELECT 1 FROM dbo.fn_product_sales_summary(@end, @end))
    INSERT INTO #counters_summary VALUES (1, 0);
ELSE
    INSERT INTO #counters_summary VALUES (0, 1);

-- S-09 区间末日当天销量与直接聚合一致（验证 >= 当天、< 次日）
IF (SELECT SUM(sold_qty) FROM dbo.fn_product_sales_summary(@end, @end))
   = (SELECT SUM(quantity) FROM dbo.v_settled_sales_line
      WHERE completed_at >= @end AND completed_at < DATEADD(DAY, 1, @end))
    INSERT INTO #counters_summary VALUES (1, 0);
ELSE
    INSERT INTO #counters_summary VALUES (0, 1);

-- S-10 起始日之前一天返回空集
IF NOT EXISTS (SELECT 1 FROM dbo.fn_product_sales_summary(DATEADD(DAY, -1, @start), DATEADD(DAY, -1, @start)))
    INSERT INTO #counters_summary VALUES (1, 0);
ELSE
    INSERT INTO #counters_summary VALUES (0, 1);

-- S-11 起止倒置返回空集
IF NOT EXISTS (SELECT 1 FROM dbo.fn_product_sales_summary(@end, @start))
    INSERT INTO #counters_summary VALUES (1, 0);
ELSE
    INSERT INTO #counters_summary VALUES (0, 1);

-- S-12 起始日为 NULL 返回空集
IF NOT EXISTS (SELECT 1 FROM dbo.fn_product_sales_summary(NULL, @end))
    INSERT INTO #counters_summary VALUES (1, 0);
ELSE
    INSERT INTO #counters_summary VALUES (0, 1);

-- S-13 结束日为 NULL 返回空集
IF NOT EXISTS (SELECT 1 FROM dbo.fn_product_sales_summary(@start, NULL))
    INSERT INTO #counters_summary VALUES (1, 0);
ELSE
    INSERT INTO #counters_summary VALUES (0, 1);

-- S-14 指标非负且非零
IF NOT EXISTS
(
    SELECT 1 FROM dbo.fn_product_sales_summary(@start, @end)
    WHERE sold_qty <= 0 OR sales_amount < 0 OR order_count <= 0
)
    INSERT INTO #counters_summary VALUES (1, 0);
ELSE
    INSERT INTO #counters_summary VALUES (0, 1);

-- S-15 单日结果只包含当天有销售的商品
IF NOT EXISTS
(
    SELECT product_id FROM dbo.fn_product_sales_summary(@end, @end)
    EXCEPT
    SELECT product_id FROM dbo.v_settled_sales_line
    WHERE completed_at >= @end AND completed_at < DATEADD(DAY, 1, @end)
)
    INSERT INTO #counters_summary VALUES (1, 0);
ELSE
    INSERT INTO #counters_summary VALUES (0, 1);

DECLARE @pass INT = (SELECT SUM(pass) FROM #counters_summary);
DECLARE @fail INT = (SELECT SUM(fail) FROM #counters_summary);
DECLARE @total INT = @pass + @fail;

IF @total <> 15
    THROW 54999, N'销售汇总测试分母不足：期望 15 条，实际计数不是 15。', 1;

PRINT CONCAT(N'RESULT: a-programmability sales-summary pass=', @pass,
             N' fail=', @fail, N' total=', @total);
IF @fail > 0
    THROW 54998, N'销售汇总测试存在失败断言，见上方结果集与计数。', 1;
GO
