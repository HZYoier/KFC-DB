-- =====================================================================
-- 第三阶段 A 域：主数据/会员侧可编程对象
-- 文件：sql/stage3/21a_master_programmability.sql
-- 属主：A
-- 前置：SchemaVersion = v1.0；B 的 v_settled_sales_line 已由 21b 创建
-- 口径：docs/stage3/sales-semantics.md（2026-11-12 冻结）
-- 约束：本文件只 CREATE，不 DROP、不重写存量数据；外层事务由 run_stage3.sql 控制
-- 执行顺序：20 → 21b → 21a → 21c → 22b → 22c → 27
-- =====================================================================
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

-- ---------------------------------------------------------------------
-- fn_calculate_discount
-- 作用：按会员等级与订单毛额计算订单级折扣率与折扣额。
-- 入参：@customer_id    顾客主键；NULL/未知/非 ACTIVE 一律无折扣
--       @order_amount   订单毛额（SELLABLE 行 ROUND(unit_price*quantity,2) 之和）
--       @category_id    预留的分类参数，当前不参与计算
--                       注意：表值函数不能省略带默认值的实参，调用方须写
--                       dbo.fn_calculate_discount(@customer_id, @amount, NULL)
--                       或第三位写 DEFAULT，不能只传两个参数（Msg 313）
-- 返回：单行 (discount_rate DECIMAL(5,4), discount_amount DECIMAL(10,2))
-- 规则：金卡 0.95、银卡 0.98、其他 1.00；毛额 >= 100 再减 0.02；下限 0.90
-- 依赖：dbo.Customer、dbo.MemberLevel
-- ---------------------------------------------------------------------
CREATE FUNCTION dbo.fn_calculate_discount
(
    @customer_id BIGINT,
    @order_amount DECIMAL(10,2),
    @category_id BIGINT = NULL
)
RETURNS TABLE
AS
RETURN
(
    SELECT
        discount_rate = CAST(r.rate AS DECIMAL(5,4)),
        discount_amount = CAST(
            CASE
                WHEN @order_amount IS NULL OR @order_amount <= 0 THEN 0.00
                ELSE ROUND(@order_amount * (1.0000 - r.rate), 2)
            END AS DECIMAL(10,2))
    FROM
    (
        SELECT
            member_rate =
                CASE
                    WHEN c.customer_id IS NULL OR c.status <> 'ACTIVE'
                        THEN CAST(1.0000 AS DECIMAL(5,4))
                    WHEN ml.member_level_id IS NULL OR ml.status <> 'ACTIVE'
                        THEN CAST(1.0000 AS DECIMAL(5,4))
                    WHEN ml.level_name = N'金卡会员'
                        THEN CAST(0.9500 AS DECIMAL(5,4))
                    WHEN ml.level_name = N'银卡会员'
                        THEN CAST(0.9800 AS DECIMAL(5,4))
                    ELSE CAST(1.0000 AS DECIMAL(5,4))
                END
        FROM (SELECT @customer_id AS customer_id) AS p
        LEFT JOIN dbo.Customer    AS c  ON c.customer_id     = p.customer_id
        LEFT JOIN dbo.MemberLevel AS ml ON ml.member_level_id = c.member_level_id
    ) AS b
    CROSS APPLY
    (
        SELECT
            rate =
                CASE
                    WHEN @order_amount IS NULL OR @order_amount <= 0
                        THEN CAST(1.0000 AS DECIMAL(5,4))
                    WHEN @order_amount < 100.00
                        THEN b.member_rate
                    WHEN b.member_rate - 0.0200 < 0.9000
                        THEN CAST(0.9000 AS DECIMAL(5,4))
                    ELSE CAST(b.member_rate - 0.0200 AS DECIMAL(5,4))
                END
    ) AS r
);
GO

-- ---------------------------------------------------------------------
-- fn_product_sales_summary
-- 作用：按商品汇总已结算销量、净销售额与订单数。
-- 入参：@start_date / @end_date  DATE 闭区间；NULL 或起止倒置返回空集
-- 返回：(product_id, product_name, sold_qty, sales_amount, order_count)
-- 口径：只读 v_settled_sales_line（终态 PICKED_UP/COMPLETED、SELLABLE、净额）
-- 依赖：dbo.v_settled_sales_line（B，21b）——必须先于本函数创建
-- ---------------------------------------------------------------------
CREATE FUNCTION dbo.fn_product_sales_summary
(
    @start_date DATE,
    @end_date DATE
)
RETURNS TABLE
AS
RETURN
(
    SELECT
        l.product_id,
        l.product_name,
        sold_qty      = SUM(l.quantity),
        sales_amount  = CAST(SUM(l.net_amount) AS DECIMAL(12,2)),
        order_count   = COUNT(DISTINCT l.order_id)
    FROM dbo.v_settled_sales_line AS l
    WHERE @start_date IS NOT NULL
      AND @end_date   IS NOT NULL
      AND @start_date <= @end_date
      AND l.completed_at >= @start_date
      AND l.completed_at <  DATEADD(DAY, 1, @end_date)
    GROUP BY l.product_id, l.product_name
);
GO
