-- ============================================================================
-- test_23a_windows.sql — A 域窗口查询测试（成员 A，第 11 周）
-- 运行时机：v1.1 迁移已提交，B 的 v_settled_sales_line 已创建
-- 运行方式：sqlcmd -S localhost -E -C -f 65001 -b -d KFC_DB -i 本文件
-- 校验：排名函数的并列语义、行数不变、移动平均的 1/2/3 行窗口帧
-- 分母：10
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
IF NOT EXISTS (SELECT 1 FROM dbo.v_settled_sales_line)
    THROW 54931, N'v_settled_sales_line 为空，窗口测试无夹具。', 1;

IF OBJECT_ID(N'tempdb..#counters_windows') IS NOT NULL DROP TABLE #counters_windows;
CREATE TABLE #counters_windows (pass INT NOT NULL, fail INT NOT NULL);
INSERT INTO #counters_windows (pass, fail) VALUES (0, 0);

DECLARE @start DATE = (SELECT MIN(CAST(completed_at AS DATE)) FROM dbo.v_settled_sales_line);
DECLARE @end   DATE = (SELECT MAX(CAST(completed_at AS DATE)) FROM dbo.v_settled_sales_line);

CREATE TABLE #lines
(
    product_id   BIGINT NOT NULL,
    order_id     BIGINT NOT NULL,
    completed_at DATETIME2(0) NOT NULL,
    net_amount   DECIMAL(12,2) NOT NULL
);
INSERT INTO #lines (product_id, order_id, completed_at, net_amount)
SELECT product_id, order_id, completed_at, net_amount
FROM dbo.v_settled_sales_line
WHERE completed_at >= @start
  AND completed_at <  DATEADD(DAY, 1, @end);

CREATE TABLE #moving
(
    product_id   BIGINT NOT NULL,
    order_id     BIGINT NOT NULL,
    completed_at DATETIME2(0) NOT NULL,
    net_amount   DECIMAL(12,2) NOT NULL,
    seq          INT NOT NULL,
    moving_avg_3 DECIMAL(12,2) NOT NULL,
    window_rows  INT NOT NULL
);
INSERT INTO #moving (product_id, order_id, completed_at, net_amount, seq, moving_avg_3, window_rows)
SELECT
    product_id,
    order_id,
    completed_at,
    net_amount,
    seq = ROW_NUMBER() OVER (PARTITION BY product_id ORDER BY completed_at, order_id),
    moving_avg_3 = CAST(AVG(net_amount) OVER (
        PARTITION BY product_id
        ORDER BY completed_at, order_id
        ROWS BETWEEN 2 PRECEDING AND CURRENT ROW) AS DECIMAL(12,2)),
    window_rows = COUNT(*) OVER (
        PARTITION BY product_id
        ORDER BY completed_at, order_id
        ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)
FROM #lines;

CREATE TABLE #prod
(
    product_id   BIGINT NOT NULL PRIMARY KEY,
    sales_amount DECIMAL(12,2) NOT NULL
);
INSERT INTO #prod (product_id, sales_amount)
SELECT product_id, CAST(SUM(net_amount) AS DECIMAL(12,2))
FROM #lines
GROUP BY product_id;

CREATE TABLE #ranked
(
    product_id   BIGINT NOT NULL PRIMARY KEY,
    sales_amount DECIMAL(12,2) NOT NULL,
    rank_no      INT NOT NULL,
    dense_no     INT NOT NULL,
    row_no       INT NOT NULL
);
INSERT INTO #ranked (product_id, sales_amount, rank_no, dense_no, row_no)
SELECT
    product_id,
    sales_amount,
    rank_no  = RANK()       OVER (ORDER BY sales_amount DESC),
    dense_no = DENSE_RANK() OVER (ORDER BY sales_amount DESC),
    row_no   = ROW_NUMBER() OVER (ORDER BY sales_amount DESC, product_id ASC)
FROM #prod;

-- W-01 窗口函数不减少行数
IF (SELECT COUNT(*) FROM #moving) = (SELECT COUNT(*) FROM #lines)
    INSERT INTO #counters_windows VALUES (1, 0);
ELSE
    INSERT INTO #counters_windows VALUES (0, 1);

-- W-02 每行窗口大小 = MIN(3, 该商品内序号)
IF NOT EXISTS
(
    SELECT 1 FROM #moving
    WHERE window_rows <> CASE WHEN seq < 3 THEN seq ELSE 3 END
)
    INSERT INTO #counters_windows VALUES (1, 0);
ELSE
    INSERT INTO #counters_windows VALUES (0, 1);

-- W-03 第一笔的移动平均等于自身金额
IF NOT EXISTS
(
    SELECT 1 FROM #moving
    WHERE seq = 1 AND moving_avg_3 <> net_amount
)
    INSERT INTO #counters_windows VALUES (1, 0);
ELSE
    INSERT INTO #counters_windows VALUES (0, 1);

-- W-04 第二笔 = 前两笔平均
IF NOT EXISTS
(
    SELECT 1
    FROM #moving AS m
    JOIN #moving AS p ON p.product_id = m.product_id AND p.seq = m.seq - 1
    WHERE m.seq = 2
      AND m.moving_avg_3 <> CAST((p.net_amount + m.net_amount) / 2.0 AS DECIMAL(12,2))
)
    INSERT INTO #counters_windows VALUES (1, 0);
ELSE
    INSERT INTO #counters_windows VALUES (0, 1);

-- W-05 第三笔 = 前三笔平均
IF NOT EXISTS
(
    SELECT 1
    FROM #moving AS m
    JOIN #moving AS p1 ON p1.product_id = m.product_id AND p1.seq = m.seq - 1
    JOIN #moving AS p2 ON p2.product_id = m.product_id AND p2.seq = m.seq - 2
    WHERE m.seq = 3
      AND m.moving_avg_3 <> CAST((p2.net_amount + p1.net_amount + m.net_amount) / 3.0 AS DECIMAL(12,2))
)
    INSERT INTO #counters_windows VALUES (1, 0);
ELSE
    INSERT INTO #counters_windows VALUES (0, 1);

-- W-06 RANK = 1 + 金额严格更高的商品数（并列跳号）
IF NOT EXISTS
(
    SELECT 1 FROM #ranked AS r
    WHERE r.rank_no <> 1 + (SELECT COUNT(*) FROM #prod AS p WHERE p.sales_amount > r.sales_amount)
)
    INSERT INTO #counters_windows VALUES (1, 0);
ELSE
    INSERT INTO #counters_windows VALUES (0, 1);

-- W-07 DENSE_RANK = 1 + 严格更高金额的去重档数（并列不跳号）
IF NOT EXISTS
(
    SELECT 1 FROM #ranked AS r
    WHERE r.dense_no <> 1 + (SELECT COUNT(DISTINCT p.sales_amount)
                             FROM #prod AS p WHERE p.sales_amount > r.sales_amount)
)
    INSERT INTO #counters_windows VALUES (1, 0);
ELSE
    INSERT INTO #counters_windows VALUES (0, 1);

-- W-08 ROW_NUMBER 在整个榜单内唯一且连续（1..N，不按商品分组）
IF NOT EXISTS
(
    SELECT 1
    FROM (SELECT c = COUNT(*), d = COUNT(DISTINCT row_no),
                 lo = MIN(row_no), hi = MAX(row_no)
          FROM #ranked) AS x
    WHERE x.c <> x.d OR x.lo <> 1 OR x.hi <> x.c
)
    INSERT INTO #counters_windows VALUES (1, 0);
ELSE
    INSERT INTO #counters_windows VALUES (0, 1);

-- 并列夹具：真实视图可能恰好没有并列，用合成金额单独验证跳号/不跳号语义
CREATE TABLE #tie_amount
(
    product_id   INT NOT NULL PRIMARY KEY,
    sales_amount DECIMAL(12,2) NOT NULL
);
INSERT INTO #tie_amount (product_id, sales_amount) VALUES (1, 30.00), (2, 30.00), (3, 10.00);

CREATE TABLE #tie_ranked
(
    product_id INT NOT NULL PRIMARY KEY,
    rank_no    INT NOT NULL,
    dense_no   INT NOT NULL
);
INSERT INTO #tie_ranked (product_id, rank_no, dense_no)
SELECT
    product_id,
    rank_no  = RANK()       OVER (ORDER BY sales_amount DESC),
    dense_no = DENSE_RANK() OVER (ORDER BY sales_amount DESC)
FROM #tie_amount;

CREATE TABLE #tie_expect
(
    product_id INT NOT NULL PRIMARY KEY,
    rank_no    INT NOT NULL,
    dense_no   INT NOT NULL
);
INSERT INTO #tie_expect (product_id, rank_no, dense_no) VALUES (1, 1, 1), (2, 1, 1), (3, 3, 2);

-- W-09 两商品并列第一时 RANK 跳号：1,1,3
IF NOT EXISTS
(
    SELECT 1 FROM #tie_ranked AS r
    JOIN #tie_expect AS e ON e.product_id = r.product_id
    WHERE r.rank_no <> e.rank_no
)
    INSERT INTO #counters_windows VALUES (1, 0);
ELSE
    INSERT INTO #counters_windows VALUES (0, 1);

-- W-10 同一并列下 DENSE_RANK 不跳号：1,1,2
IF NOT EXISTS
(
    SELECT 1 FROM #tie_ranked AS r
    JOIN #tie_expect AS e ON e.product_id = r.product_id
    WHERE r.dense_no <> e.dense_no
)
    INSERT INTO #counters_windows VALUES (1, 0);
ELSE
    INSERT INTO #counters_windows VALUES (0, 1);

DECLARE @pass INT = (SELECT SUM(pass) FROM #counters_windows);
DECLARE @fail INT = (SELECT SUM(fail) FROM #counters_windows);
DECLARE @total INT = @pass + @fail;

IF @total <> 10
    THROW 54999, N'窗口测试分母不足：期望 10 条，实际计数不是 10。', 1;

PRINT CONCAT(N'RESULT: a-programmability windows pass=', @pass,
             N' fail=', @fail, N' total=', @total);
IF @fail > 0
    THROW 54998, N'窗口测试存在失败断言。', 1;
GO
