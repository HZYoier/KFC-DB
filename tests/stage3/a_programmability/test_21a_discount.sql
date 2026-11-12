-- ============================================================================
-- test_21a_discount.sql — A 域折扣函数测试（成员 A）
-- 运行时机：v1.1 迁移已提交，21a 的 fn_calculate_discount 已存在
-- 运行方式：sqlcmd -S localhost -E -C -f 65001 -b -d KFC_DB -i 本文件
-- 口径：docs/stage3/sales-semantics.md §2
-- 写法：每行期望值与函数实际值逐条比对；缺对象/缺夹具直接 THROW，不跳过。
-- 分母：27（12 个费率+金额用例 ×2，另 3 条性质断言）
-- 断言码：54930 前置不成立、54931 夹具不成立、54998 有失败、54999 分母不足
-- ============================================================================
:on error exit
USE KFC_DB;
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF OBJECT_ID(N'dbo.fn_calculate_discount', N'IF') IS NULL
    THROW 54930, N'缺少 dbo.fn_calculate_discount；请先执行 sql/stage3/21a_master_programmability.sql。', 1;
IF OBJECT_ID(N'dbo.Customer', N'U') IS NULL OR OBJECT_ID(N'dbo.MemberLevel', N'U') IS NULL
    THROW 54930, N'缺少 Customer/MemberLevel，折扣测试无夹具。', 1;

DECLARE @gold BIGINT =
    (SELECT TOP (1) c.customer_id
     FROM dbo.Customer AS c
     JOIN dbo.MemberLevel AS ml ON ml.member_level_id = c.member_level_id
     WHERE c.status = 'ACTIVE' AND ml.status = 'ACTIVE' AND ml.level_name = N'金卡会员'
     ORDER BY c.customer_id);
DECLARE @silver BIGINT =
    (SELECT TOP (1) c.customer_id
     FROM dbo.Customer AS c
     JOIN dbo.MemberLevel AS ml ON ml.member_level_id = c.member_level_id
     WHERE c.status = 'ACTIVE' AND ml.status = 'ACTIVE' AND ml.level_name = N'银卡会员'
     ORDER BY c.customer_id);
DECLARE @ordinary BIGINT =
    (SELECT TOP (1) c.customer_id
     FROM dbo.Customer AS c
     JOIN dbo.MemberLevel AS ml ON ml.member_level_id = c.member_level_id
     WHERE c.status = 'ACTIVE' AND ml.status = 'ACTIVE' AND ml.level_name = N'普通会员'
     ORDER BY c.customer_id);
IF @gold IS NULL OR @silver IS NULL OR @ordinary IS NULL
    THROW 54931, N'种子数据缺少 ACTIVE 的金卡/银卡/普通会员，无法构造折扣夹具。', 1;

IF OBJECT_ID(N'tempdb..#counters_discount') IS NOT NULL DROP TABLE #counters_discount;
CREATE TABLE #counters_discount (pass INT NOT NULL, fail INT NOT NULL);
INSERT INTO #counters_discount (pass, fail) VALUES (0, 0);

CREATE TABLE #expected
(
    case_code VARCHAR(20) NOT NULL PRIMARY KEY,
    rate      DECIMAL(5,4) NOT NULL,
    amt       DECIMAL(10,2) NOT NULL
);
CREATE TABLE #actual
(
    case_code VARCHAR(20) NOT NULL,
    rate      DECIMAL(5,4) NULL,
    amt       DECIMAL(10,2) NULL
);

-- 12 个用例，每个同时断言折扣率与折扣额（共 24 条）
INSERT INTO #expected (case_code, rate, amt) VALUES
    ('gold50',          0.9500,  2.50),
    ('silver50',        0.9800,  1.00),
    ('silver100',       0.9600,  4.00),
    ('gold100',         0.9300,  7.00),
    ('ordinary100',     0.9800,  2.00),
    ('unknown_id',      0.9800,  2.00),
    ('null_customer',   0.9800,  2.00),
    ('null_amount',     1.0000,  0.00),
    ('zero_amount',     1.0000,  0.00),
    ('negative_amount', 1.0000,  0.00),
    ('inactive_level',  1.0000,  0.00),
    ('inactive_customer', 1.0000, 0.00);

INSERT INTO #actual (case_code, rate, amt)
SELECT 'gold50', f.discount_rate, f.discount_amount
FROM dbo.fn_calculate_discount(@gold, CAST(50.00 AS DECIMAL(10,2)), NULL) AS f;
INSERT INTO #actual (case_code, rate, amt)
SELECT 'silver50', f.discount_rate, f.discount_amount
FROM dbo.fn_calculate_discount(@silver, CAST(50.00 AS DECIMAL(10,2)), NULL) AS f;
INSERT INTO #actual (case_code, rate, amt)
SELECT 'silver100', f.discount_rate, f.discount_amount
FROM dbo.fn_calculate_discount(@silver, CAST(100.00 AS DECIMAL(10,2)), NULL) AS f;
INSERT INTO #actual (case_code, rate, amt)
SELECT 'gold100', f.discount_rate, f.discount_amount
FROM dbo.fn_calculate_discount(@gold, CAST(100.00 AS DECIMAL(10,2)), NULL) AS f;
INSERT INTO #actual (case_code, rate, amt)
SELECT 'ordinary100', f.discount_rate, f.discount_amount
FROM dbo.fn_calculate_discount(@ordinary, CAST(100.00 AS DECIMAL(10,2)), NULL) AS f;
INSERT INTO #actual (case_code, rate, amt)
SELECT 'unknown_id', f.discount_rate, f.discount_amount
FROM dbo.fn_calculate_discount(CAST(999999999 AS BIGINT), CAST(100.00 AS DECIMAL(10,2)), NULL) AS f;
INSERT INTO #actual (case_code, rate, amt)
SELECT 'null_customer', f.discount_rate, f.discount_amount
FROM dbo.fn_calculate_discount(NULL, CAST(100.00 AS DECIMAL(10,2)), NULL) AS f;
INSERT INTO #actual (case_code, rate, amt)
SELECT 'null_amount', f.discount_rate, f.discount_amount
FROM dbo.fn_calculate_discount(@gold, CAST(NULL AS DECIMAL(10,2)), NULL) AS f;
INSERT INTO #actual (case_code, rate, amt)
SELECT 'zero_amount', f.discount_rate, f.discount_amount
FROM dbo.fn_calculate_discount(@gold, CAST(0.00 AS DECIMAL(10,2)), NULL) AS f;
INSERT INTO #actual (case_code, rate, amt)
SELECT 'negative_amount', f.discount_rate, f.discount_amount
FROM dbo.fn_calculate_discount(@gold, CAST(-10.00 AS DECIMAL(10,2)), NULL) AS f;

-- 停用等级：事务内改、取数、回滚，临时表在回滚后再写
DECLARE @ir DECIMAL(5,4), @ia DECIMAL(10,2);
BEGIN TRANSACTION;
BEGIN TRY
    UPDATE dbo.MemberLevel SET status = 'INACTIVE' WHERE level_name = N'银卡会员';
    SELECT @ir = f.discount_rate, @ia = f.discount_amount
    FROM dbo.fn_calculate_discount(@silver, CAST(50.00 AS DECIMAL(10,2)), NULL) AS f;
    ROLLBACK TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
INSERT INTO #actual (case_code, rate, amt) VALUES ('inactive_level', @ir, @ia);

-- 停用顾客：同上
DECLARE @cr DECIMAL(5,4), @ca DECIMAL(10,2);
BEGIN TRANSACTION;
BEGIN TRY
    UPDATE dbo.Customer SET status = 'INACTIVE' WHERE customer_id = @gold;
    SELECT @cr = f.discount_rate, @ca = f.discount_amount
    FROM dbo.fn_calculate_discount(@gold, CAST(50.00 AS DECIMAL(10,2)), NULL) AS f;
    ROLLBACK TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
INSERT INTO #actual (case_code, rate, amt) VALUES ('inactive_customer', @cr, @ca);

-- 逐用例计数（每个用例 2 条断言）
INSERT INTO #counters_discount (pass, fail)
SELECT
    SUM(CASE WHEN a.rate = e.rate AND a.amt = e.amt THEN 2 ELSE 0 END),
    SUM(CASE WHEN a.rate = e.rate AND a.amt = e.amt THEN 0 ELSE 2 END)
FROM #expected AS e
LEFT JOIN #actual AS a ON a.case_code = e.case_code;

-- 失败用例明细（有失败才输出结果集）
SELECT
    e.case_code,
    expected_rate = e.rate,
    actual_rate   = a.rate,
    expected_amt  = e.amt,
    actual_amt    = a.amt
FROM #expected AS e
LEFT JOIN #actual AS a ON a.case_code = e.case_code
WHERE a.rate IS NULL OR a.amt IS NULL OR a.rate <> e.rate OR a.amt <> e.amt;

-- 性质 1（25）：分类参数当前无效
IF EXISTS
(
    SELECT 1
    FROM dbo.fn_calculate_discount(@gold, CAST(100.00 AS DECIMAL(10,2)), NULL) AS a
    CROSS JOIN dbo.fn_calculate_discount(@gold, CAST(100.00 AS DECIMAL(10,2)), CAST(1 AS BIGINT)) AS b
    WHERE a.discount_rate = b.discount_rate AND a.discount_amount = b.discount_amount
)
    INSERT INTO #counters_discount VALUES (1, 0);
ELSE
    INSERT INTO #counters_discount VALUES (0, 1);

-- 性质 2（26）：任何等级/金额组合的折扣率都不低于 0.90
IF NOT EXISTS
(
    SELECT 1
    FROM (VALUES (@gold), (@silver), (@ordinary)) AS c(customer_id)
    CROSS JOIN (VALUES (CAST(0.01 AS DECIMAL(10,2))),
                       (CAST(99.99 AS DECIMAL(10,2))),
                       (CAST(100.00 AS DECIMAL(10,2))),
                       (CAST(99999.99 AS DECIMAL(10,2)))) AS v(amount)
    CROSS APPLY dbo.fn_calculate_discount(c.customer_id, v.amount, NULL) AS f
    WHERE f.discount_rate < 0.9000
)
    INSERT INTO #counters_discount VALUES (1, 0);
ELSE
    INSERT INTO #counters_discount VALUES (0, 1);

-- 性质 3（27）：折扣额与折扣率算术自洽（金额 - 折扣 = ROUND(金额 × 率, 2)）
IF EXISTS
(
    SELECT 1
    FROM dbo.fn_calculate_discount(@gold, CAST(123.45 AS DECIMAL(10,2)), NULL) AS f
    WHERE CAST(123.45 AS DECIMAL(10,2)) - f.discount_amount
          = ROUND(CAST(123.45 AS DECIMAL(10,2)) * f.discount_rate, 2)
)
    INSERT INTO #counters_discount VALUES (1, 0);
ELSE
    INSERT INTO #counters_discount VALUES (0, 1);

DECLARE @pass INT = (SELECT SUM(pass) FROM #counters_discount);
DECLARE @fail INT = (SELECT SUM(fail) FROM #counters_discount);
DECLARE @total INT = @pass + @fail;

IF @total <> 27
    THROW 54999, N'折扣测试分母不足：期望 27 条，实际计数不是 27。', 1;

PRINT CONCAT(N'RESULT: a-programmability discount pass=', @pass,
             N' fail=', @fail, N' total=', @total);
IF @fail > 0
    THROW 54998, N'折扣测试存在失败断言，见上方明细。', 1;
GO
