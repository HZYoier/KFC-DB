-- =====================================================================
-- 第三阶段 A 域：窗口函数查询（第 11 周）
-- 文件：sql/stage3/23a_window_queries.sql
-- 属主：A
-- 前置：B 的 v_settled_sales_line 已创建（21b），本文件只读，不建对象
-- 口径：docs/stage3/sales-semantics.md §1
-- 说明：两条查询都不减少输入行数——窗口函数在结果行上追加计算列；
--       第一条在最终 SELECT 前用 rk <= 10 取榜单，第二步的截断发生在
--       CTE 之外，原行集仍完整保留在 ranked 中。
-- =====================================================================
USE KFC_DB;
GO
SET NOCOUNT ON;
GO

-- 日期区间不写死：默认取视图里最早/最晚的已结算日期；
-- 正式报表可由调用方改成参数或存储过程入参。
DECLARE @start_date DATE = (SELECT MIN(CAST(l.completed_at AS DATE)) FROM dbo.v_settled_sales_line AS l);
DECLARE @end_date   DATE = (SELECT MAX(CAST(l.completed_at AS DATE)) FROM dbo.v_settled_sales_line AS l);

IF @start_date IS NULL OR @end_date IS NULL
BEGIN
    PRINT N'v_settled_sales_line 为空：先完成至少一笔 PICKED_UP/COMPLETED 订单，再跑窗口查询。';
    RETURN;
END;

PRINT CONCAT(N'窗口查询区间：', CONVERT(VARCHAR(10), @start_date, 120),
             N' 至 ', CONVERT(VARCHAR(10), @end_date, 120));

-- ---------------------------------------------------------------------
-- 查询 1：畅销商品榜（R11-03）
-- 目的：按销售净额降序给商品排名，供陈列与备货参考。
-- 排序：sales_amount DESC；sales_amount 相同则 product_id ASC 保证输出稳定。
-- RANK：并列后跳号（1,1,3）；DENSE_RANK：并列不跳号（1,1,2）；
-- ROW_NUMBER：即使金额相同也给出唯一序号，用于“必须取前 N 行”的场景。
-- 截断：rk <= 10 取前十名；并列第 10 名会一起进入，因此行数可能大于 10。
-- 行数：product_sales 一行一个商品；ranked 与 product_sales 行数相同。
-- ---------------------------------------------------------------------
WITH product_sales AS
(
    SELECT
        l.product_id,
        l.product_name,
        sold_qty     = SUM(l.quantity),
        sales_amount = CAST(SUM(l.net_amount) AS DECIMAL(12,2)),
        order_count  = COUNT(DISTINCT l.order_id)
    FROM dbo.v_settled_sales_line AS l
    WHERE l.completed_at >= @start_date
      AND l.completed_at <  DATEADD(DAY, 1, @end_date)
    GROUP BY l.product_id, l.product_name
),
ranked AS
(
    SELECT
        p.product_id,
        p.product_name,
        p.sold_qty,
        p.sales_amount,
        p.order_count,
        rank_no        = RANK()       OVER (ORDER BY p.sales_amount DESC),
        dense_rank_no  = DENSE_RANK() OVER (ORDER BY p.sales_amount DESC),
        row_no         = ROW_NUMBER() OVER (ORDER BY p.sales_amount DESC, p.product_id ASC)
    FROM product_sales AS p
)
SELECT
    r.rank_no,
    r.dense_rank_no,
    r.row_no,
    r.product_id,
    r.product_name,
    r.sold_qty,
    r.sales_amount,
    r.order_count
FROM ranked AS r
WHERE r.rank_no <= 10
ORDER BY r.rank_no, r.product_id;

-- ---------------------------------------------------------------------
-- 查询 2：商品最近 3 笔销售的移动平均（R11-05）
-- 目的：看单笔销售额的近期趋势，为补货目标量提供参考，不直接回写建议。
-- 排序：PARTITION BY product_id，ORDER BY completed_at, order_id（升序）。
-- 窗口帧：ROWS BETWEEN 2 PRECEDING AND CURRENT ROW，即当前行与前两行；
--         同一商品前两笔只有 1/2 行参与，window_rows 列会显示 1、2、3。
-- 行数：line_sales 一行一条已结算售卖明细；输出行数与 line_sales 相同，
--       窗口函数只追加 moving_avg_3 与 window_rows，不合并行。
-- ---------------------------------------------------------------------
WITH line_sales AS
(
    SELECT
        l.product_id,
        l.product_name,
        l.order_id,
        l.order_no,
        l.completed_at,
        l.net_amount
    FROM dbo.v_settled_sales_line AS l
    WHERE l.completed_at >= @start_date
      AND l.completed_at <  DATEADD(DAY, 1, @end_date)
)
SELECT
    s.product_id,
    s.product_name,
    s.order_id,
    s.order_no,
    s.completed_at,
    s.net_amount,
    moving_avg_3 = CAST(
        AVG(s.net_amount) OVER (
            PARTITION BY s.product_id
            ORDER BY s.completed_at, s.order_id
            ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
        ) AS DECIMAL(12,2)),
    window_rows = COUNT(*) OVER (
        PARTITION BY s.product_id
        ORDER BY s.completed_at, s.order_id
        ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
    )
FROM line_sales AS s
ORDER BY s.product_id, s.completed_at, s.order_id;
GO
