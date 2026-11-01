-- ============================================================================
-- 13a_master_regression.sql — A 域 v1.0 提交后回归（成员 A；2026-11-01）
-- 运行时机：run_migration.sql 已 COMMIT 并写入 SchemaVersion('v1.0') 之后；
--           本文件独立执行，不依附迁移事务，每条断言自带事务并一律 ROLLBACK。
-- 覆盖：
--   A1–A5  11a 新增五条候选码的反例（直接 DML 被 2627 拒绝，且约束名对得上）；
--   A6–A7  冻结事项 A（a-normalization §4.1 / migration-guide §2.6）：
--          变动对账（current_points − SUM(EFFECTIVE) 与基线相等）与
--          期初登记（逐笔 EFFECTIVE 流水事实不变，不得补造流水抹平 offset）；
--   A8–A9  冻结事项 B（a-normalization §4.2）：等级停用置空、加档/调门槛不回溯；
--   A10    冻结事项 C（a-normalization §3.10）：同窗两档价按 priority DESC, rule_id ASC 取一。
-- 依赖：01/04（表与过程）、09a/09c（种子与 test_store_manager）、
--       stage2/11a（五条候选码）、capture_baseline 的 COMPLETED 批次
--       （Baseline_Customer / Baseline_PointLedger，13a 只读 v1.0 标记指向的那一批）。
-- 写法：对齐 10a/10c——夹具只经既有过程或约束注入、失败带出 ERROR_NUMBER() 与
--       ERROR_MESSAGE()、EXECUTE AS 收尾「先 ROLLBACK 再 REVERT」、计数用 #counters
--       跨批次累计，收尾打印 RESULT 并校验分母（10 条），失败或分母不足均非零退出。
-- 断言码：51930（前置不成立）、51931（夹具不成立）、51998（有失败断言）、51999（分母不足）——属 519xx
--       验收断言码段，不是业务码；具体条目的期望/实际错误号写在 FAIL 行文本里。
-- ============================================================================

USE KFC_DB;
GO

SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET QUOTED_IDENTIFIER ON;
SET NUMERIC_ROUNDABORT OFF;
SET XACT_ABORT ON;
GO

-- 断言计数（局部变量不跨批次，用临时表累计）
IF OBJECT_ID(N'tempdb..#counters') IS NOT NULL DROP TABLE #counters;
CREATE TABLE #counters (pass INT NOT NULL, fail INT NOT NULL);
INSERT INTO #counters (pass, fail) VALUES (0, 0);
GO

-- ---------------------------------------------------------------------------
-- 0. 前置：已升到 v1.0、批次已完成、快照与测试账号在位
-- ---------------------------------------------------------------------------
DECLARE @batch_id BIGINT = (SELECT sv.batch_id FROM dbo.SchemaVersion AS sv
                            WHERE sv.version_code = N'v1.0');

IF OBJECT_ID(N'dbo.SchemaVersion', N'U') IS NULL OR @batch_id IS NULL
    THROW 51930, N'13a：找不到 SchemaVersion(''v1.0'') 或其 batch_id；请先在迁移事务里写入 v1.0 标记。', 1;
IF OBJECT_ID(N'dbo.MigrationBatch', N'U') IS NULL
   OR NOT EXISTS (SELECT 1 FROM dbo.MigrationBatch AS b
                  WHERE b.batch_id = @batch_id AND b.batch_status = 'COMPLETED')
    THROW 51930, N'13a：v1.0 指向的批次不是 COMPLETED；回归不得跨批或读未完成批次。', 1;
IF OBJECT_ID(N'dbo.Baseline_Customer', N'U') IS NULL OR OBJECT_ID(N'dbo.Baseline_PointLedger', N'U') IS NULL
    THROW 51930, N'13a：缺少 Baseline_Customer / Baseline_PointLedger；请先运行 capture_baseline.sql。', 1;
IF NOT EXISTS (SELECT 1 FROM dbo.Baseline_Customer WHERE batch_id = @batch_id)
    THROW 51930, N'13a：该批次没有顾客快照，冻结事项 A 的期初对账无依据。', 1;
IF NOT EXISTS (SELECT 1 FROM dbo.Category) OR NOT EXISTS (SELECT 1 FROM dbo.Product)
   OR NOT EXISTS (SELECT 1 FROM dbo.Ingredient) OR NOT EXISTS (SELECT 1 FROM dbo.MemberLevel)
    THROW 51930, N'13a：A 域主数据为空，反例夹具无从构造；请先执行 09a_master_seed_data.sql。', 1;
IF OBJECT_ID(N'dbo.fn_get_effective_product_price', N'IF') IS NULL
    THROW 51930, N'13a：缺少 fn_get_effective_product_price，冻结事项 C 无从验证。', 1;
IF DATABASE_PRINCIPAL_ID(N'test_store_manager') IS NULL
    THROW 51930, N'13a：缺少 test_store_manager，请先执行 08_roles_permissions.sql。', 1;
IF NOT EXISTS (SELECT 1 FROM dbo.EmployeeAccount
               WHERE database_user_name = N'test_store_manager' AND [status] = 'ACTIVE')
    THROW 51930, N'13a：test_store_manager 没有 ACTIVE 的 EmployeeAccount 行，请先执行 09c。', 1;
GO

-- ---------------------------------------------------------------------------
-- A1 反例：重复 Category.category_name 被 11a 的候选码拒绝
-- ---------------------------------------------------------------------------
DECLARE @err INT = NULL, @errmsg NVARCHAR(2048) = NULL, @fail NVARCHAR(2048) = NULL;

BEGIN TRANSACTION;
BEGIN TRY
    INSERT INTO dbo.Category (category_name, [status])
    SELECT TOP (1) c.category_name, c.[status]
    FROM dbo.Category AS c
    ORDER BY c.category_id;
END TRY
BEGIN CATCH
    SET @err = ERROR_NUMBER();
    SET @errmsg = ERROR_MESSAGE();
END CATCH;

IF XACT_STATE() = -1 ROLLBACK TRANSACTION;
IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

IF @err IS NULL
    SET @fail = N'A1（UQ_Category_category_name）：重复分类名竟被直接插入接受。';
ELSE IF @err <> 2627
    SET @fail = CONCAT(N'A1（UQ_Category_category_name）：期望 2627，实际 ', @err, N'（', @errmsg, N'）。');
ELSE IF @errmsg NOT LIKE N'%UQ_Category_category_name%'
    SET @fail = CONCAT(N'A1（UQ_Category_category_name）：报 2627 但约束名不是它（', @errmsg, N'）。');

IF @fail IS NOT NULL
BEGIN
    UPDATE #counters SET fail = fail + 1;
    PRINT N'FAIL: ' + @fail;
END
ELSE
BEGIN
    UPDATE #counters SET pass = pass + 1;
    PRINT N'PASS: A1 UQ_Category_category_name 拒绝重复';
END;
GO

-- ---------------------------------------------------------------------------
-- A2 反例：重复 Product.product_name 被拒
-- ---------------------------------------------------------------------------
DECLARE @err INT = NULL, @errmsg NVARCHAR(2048) = NULL, @fail NVARCHAR(2048) = NULL;

BEGIN TRANSACTION;
BEGIN TRY
    INSERT INTO dbo.Product (product_name, base_price, product_type, [status])
    SELECT TOP (1) p.product_name, p.base_price, p.product_type, p.[status]
    FROM dbo.Product AS p
    ORDER BY p.product_id;
END TRY
BEGIN CATCH
    SET @err = ERROR_NUMBER();
    SET @errmsg = ERROR_MESSAGE();
END CATCH;

IF XACT_STATE() = -1 ROLLBACK TRANSACTION;
IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

IF @err IS NULL
    SET @fail = N'A2（UQ_Product_product_name）：重复商品名竟被直接插入接受。';
ELSE IF @err <> 2627
    SET @fail = CONCAT(N'A2（UQ_Product_product_name）：期望 2627，实际 ', @err, N'（', @errmsg, N'）。');
ELSE IF @errmsg NOT LIKE N'%UQ_Product_product_name%'
    SET @fail = CONCAT(N'A2（UQ_Product_product_name）：报 2627 但约束名不是它（', @errmsg, N'）。');

IF @fail IS NOT NULL
BEGIN
    UPDATE #counters SET fail = fail + 1;
    PRINT N'FAIL: ' + @fail;
END
ELSE
BEGIN
    UPDATE #counters SET pass = pass + 1;
    PRINT N'PASS: A2 UQ_Product_product_name 拒绝重复';
END;
GO

-- ---------------------------------------------------------------------------
-- A3 反例：重复 Ingredient (ingredient_name, unit_name) 被拒（复合候选码）
-- ---------------------------------------------------------------------------
DECLARE @err INT = NULL, @errmsg NVARCHAR(2048) = NULL, @fail NVARCHAR(2048) = NULL;

BEGIN TRANSACTION;
BEGIN TRY
    INSERT INTO dbo.Ingredient (ingredient_name, unit_name, safety_stock_qty, [status])
    SELECT TOP (1) i.ingredient_name, i.unit_name, i.safety_stock_qty, i.[status]
    FROM dbo.Ingredient AS i
    ORDER BY i.ingredient_id;
END TRY
BEGIN CATCH
    SET @err = ERROR_NUMBER();
    SET @errmsg = ERROR_MESSAGE();
END CATCH;

IF XACT_STATE() = -1 ROLLBACK TRANSACTION;
IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

IF @err IS NULL
    SET @fail = N'A3（UQ_Ingredient_name_unit）：重复「原料名 + 单位」竟被直接插入接受。';
ELSE IF @err <> 2627
    SET @fail = CONCAT(N'A3（UQ_Ingredient_name_unit）：期望 2627，实际 ', @err, N'（', @errmsg, N'）。');
ELSE IF @errmsg NOT LIKE N'%UQ_Ingredient_name_unit%'
    SET @fail = CONCAT(N'A3（UQ_Ingredient_name_unit）：报 2627 但约束名不是它（', @errmsg, N'）。');

IF @fail IS NOT NULL
BEGIN
    UPDATE #counters SET fail = fail + 1;
    PRINT N'FAIL: ' + @fail;
END
ELSE
BEGIN
    UPDATE #counters SET pass = pass + 1;
    PRINT N'PASS: A3 UQ_Ingredient_name_unit 拒绝重复';
END;
GO

-- ---------------------------------------------------------------------------
-- A4 反例：重复 MemberLevel.threshold_points 被拒（等级解析唯一性的前提）
-- ---------------------------------------------------------------------------
DECLARE @err INT = NULL, @errmsg NVARCHAR(2048) = NULL, @fail NVARCHAR(2048) = NULL;

BEGIN TRANSACTION;
BEGIN TRY
    -- 只复用门槛、名字另取，确保命中的就是门槛那一条约束
    INSERT INTO dbo.MemberLevel (level_name, point_multiplier, threshold_points, [status])
    SELECT TOP (1) N'13A-阈值重复', ml.point_multiplier, ml.threshold_points, 'ACTIVE'
    FROM dbo.MemberLevel AS ml
    ORDER BY ml.member_level_id;
END TRY
BEGIN CATCH
    SET @err = ERROR_NUMBER();
    SET @errmsg = ERROR_MESSAGE();
END CATCH;

IF XACT_STATE() = -1 ROLLBACK TRANSACTION;
IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

IF @err IS NULL
    SET @fail = N'A4（UQ_MemberLevel_threshold_points）：重复升级门槛竟被直接插入接受。';
ELSE IF @err <> 2627
    SET @fail = CONCAT(N'A4（UQ_MemberLevel_threshold_points）：期望 2627，实际 ', @err, N'（', @errmsg, N'）。');
ELSE IF @errmsg NOT LIKE N'%UQ_MemberLevel_threshold_points%'
    SET @fail = CONCAT(N'A4（UQ_MemberLevel_threshold_points）：报 2627 但约束名不是它（', @errmsg, N'）。');

IF @fail IS NOT NULL
BEGIN
    UPDATE #counters SET fail = fail + 1;
    PRINT N'FAIL: ' + @fail;
END
ELSE
BEGIN
    UPDATE #counters SET pass = pass + 1;
    PRINT N'PASS: A4 UQ_MemberLevel_threshold_points 拒绝重复';
END;
GO

-- ---------------------------------------------------------------------------
-- A5 反例：重复 MemberLevel.level_name 被拒（门槛取 MAX+1，只撞名字）
-- ---------------------------------------------------------------------------
DECLARE @err INT = NULL, @errmsg NVARCHAR(2048) = NULL, @fail NVARCHAR(2048) = NULL;

BEGIN TRANSACTION;
BEGIN TRY
    INSERT INTO dbo.MemberLevel (level_name, point_multiplier, threshold_points, [status])
    SELECT TOP (1) ml.level_name, 1.00,
           ISNULL((SELECT MAX(x.threshold_points) FROM dbo.MemberLevel AS x), 0) + 1,
           'ACTIVE'
    FROM dbo.MemberLevel AS ml
    ORDER BY ml.member_level_id;
END TRY
BEGIN CATCH
    SET @err = ERROR_NUMBER();
    SET @errmsg = ERROR_MESSAGE();
END CATCH;

IF XACT_STATE() = -1 ROLLBACK TRANSACTION;
IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

IF @err IS NULL
    SET @fail = N'A5（UQ_MemberLevel_level_name）：重复等级名竟被直接插入接受。';
ELSE IF @err <> 2627
    SET @fail = CONCAT(N'A5（UQ_MemberLevel_level_name）：期望 2627，实际 ', @err, N'（', @errmsg, N'）。');
ELSE IF @errmsg NOT LIKE N'%UQ_MemberLevel_level_name%'
    SET @fail = CONCAT(N'A5（UQ_MemberLevel_level_name）：报 2627 但约束名不是它（', @errmsg, N'）。');

IF @fail IS NOT NULL
BEGIN
    UPDATE #counters SET fail = fail + 1;
    PRINT N'FAIL: ' + @fail;
END
ELSE
BEGIN
    UPDATE #counters SET pass = pass + 1;
    PRINT N'PASS: A5 UQ_MemberLevel_level_name 拒绝重复';
END;
GO

-- ---------------------------------------------------------------------------
-- A6 冻结事项 A／变动对账：
--    迁移后 current_points − SUM(EFFECTIVE) 必须等于基线的同一差值（期初 offset）
-- ---------------------------------------------------------------------------
DECLARE @batch_id BIGINT = (SELECT sv.batch_id FROM dbo.SchemaVersion AS sv
                            WHERE sv.version_code = N'v1.0');
DECLARE @base_count INT, @mismatch INT, @sample NVARCHAR(1000);
DECLARE @fail NVARCHAR(2048) = NULL;

IF OBJECT_ID(N'tempdb..#a13_offset') IS NOT NULL DROP TABLE #a13_offset;
CREATE TABLE #a13_offset (customer_id BIGINT NOT NULL, opening BIGINT NULL, now_offset BIGINT NULL);

INSERT INTO #a13_offset (customer_id, opening, now_offset)
SELECT b.customer_id, b.opening, n.now_offset
FROM (
    SELECT c.customer_id,
           CONVERT(BIGINT, c.current_points)
           - ISNULL((SELECT SUM(CONVERT(BIGINT, l.point_delta))
                     FROM dbo.Baseline_PointLedger AS l
                     WHERE l.batch_id = @batch_id
                       AND l.customer_id = c.customer_id
                       AND l.ledger_status = 'EFFECTIVE'), 0) AS opening
    FROM dbo.Baseline_Customer AS c
    WHERE c.batch_id = @batch_id
) AS b
LEFT JOIN (
    SELECT cu.customer_id,
           CONVERT(BIGINT, cu.current_points)
           - ISNULL((SELECT SUM(CONVERT(BIGINT, l.point_delta))
                     FROM dbo.PointLedger AS l
                     WHERE l.customer_id = cu.customer_id
                       AND l.ledger_status = 'EFFECTIVE'), 0) AS now_offset
    FROM dbo.Customer AS cu
) AS n ON n.customer_id = b.customer_id
WHERE n.customer_id IS NULL OR n.now_offset IS NULL OR n.now_offset <> b.opening;

SET @mismatch   = (SELECT COUNT(*) FROM #a13_offset);
SET @base_count = (SELECT COUNT(*) FROM dbo.Baseline_Customer WHERE batch_id = @batch_id);
SET @sample     = (SELECT TOP (5) STRING_AGG(CONCAT(N'#', customer_id,
                                                     N' 基线=', ISNULL(CAST(opening AS NVARCHAR(20)), N'NULL'),
                                                     N' 现=', ISNULL(CAST(now_offset AS NVARCHAR(20)), N'NULL')),
                                             N'；')
                   FROM (SELECT TOP (5) * FROM #a13_offset ORDER BY customer_id) AS x);
DROP TABLE #a13_offset;

IF @mismatch > 0
    SET @fail = CONCAT(N'A6（冻结事项 A／变动对账）：', @mismatch, N'/', @base_count,
                       N' 位顾客的期初 offset 与基线不符——', @sample, N'。');
IF @fail IS NOT NULL
BEGIN
    UPDATE #counters SET fail = fail + 1;
    PRINT N'FAIL: ' + @fail;
END
ELSE
BEGIN
    UPDATE #counters SET pass = pass + 1;
    PRINT CONCAT(N'PASS: A6 期初 offset 与基线一致（', @base_count, N' 位顾客）');
END;
GO

-- ---------------------------------------------------------------------------
-- A7 冻结事项 A／期初登记：
--    基线里的逐笔 EFFECTIVE 流水事实（去向、金额、状态）不得被改动或补造，
--    即 offset 只能靠真实流水或基线本身解释，不许用补造流水抹平
-- ---------------------------------------------------------------------------
DECLARE @batch_id BIGINT = (SELECT sv.batch_id FROM dbo.SchemaVersion AS sv
                            WHERE sv.version_code = N'v1.0');
DECLARE @checked INT, @missing INT, @changed INT;
DECLARE @fail NVARCHAR(2048) = NULL;

SET @checked = (SELECT COUNT(*) FROM dbo.Baseline_PointLedger
                WHERE batch_id = @batch_id AND ledger_status = 'EFFECTIVE');

SET @missing = (SELECT COUNT(*)
                FROM dbo.Baseline_PointLedger AS b
                WHERE b.batch_id = @batch_id
                  AND b.ledger_status = 'EFFECTIVE'
                  AND NOT EXISTS (SELECT 1 FROM dbo.PointLedger AS p
                                  WHERE p.point_ledger_id = b.point_ledger_id));

SET @changed = (SELECT COUNT(*)
                FROM dbo.Baseline_PointLedger AS b
                JOIN dbo.PointLedger AS p ON p.point_ledger_id = b.point_ledger_id
                WHERE b.batch_id = @batch_id
                  AND b.ledger_status = 'EFFECTIVE'
                  AND (p.ledger_status <> b.ledger_status
                       OR p.point_delta <> b.point_delta
                       OR p.customer_id <> b.customer_id
                       OR p.order_id   <> b.order_id));

IF @missing > 0
    SET @fail = CONCAT(N'A7（冻结事项 A／期初登记）：', @missing, N' 笔基线 EFFECTIVE 流水在迁移后消失。');
IF @fail IS NULL AND @changed > 0
    SET @fail = CONCAT(N'A7（冻结事项 A／期初登记）：', @changed, N' 笔 EFFECTIVE 流水的状态/分值/归属被改动。');
IF @fail IS NOT NULL
BEGIN
    UPDATE #counters SET fail = fail + 1;
    PRINT N'FAIL: ' + @fail;
END
ELSE
BEGIN
    UPDATE #counters SET pass = pass + 1;
    PRINT CONCAT(N'PASS: A7 EFFECTIVE 流水事实与基线一致（', @checked, N' 笔）');
END;
GO

-- ---------------------------------------------------------------------------
-- A8 冻结事项 B／停用置空：等级转 INACTIVE 时，挂在该档的顾客 member_level_id 置 NULL
-- ---------------------------------------------------------------------------
DECLARE @impersonating BIT = 0;
DECLARE @err INT = NULL, @errmsg NVARCHAR(2048) = NULL, @fail NVARCHAR(2048) = NULL;
DECLARE @level_id BIGINT, @customer_id BIGINT, @level_after BIGINT;

BEGIN TRANSACTION;
BEGIN TRY
    EXECUTE AS USER = N'test_store_manager';
    SET @impersonating = 1;

    EXEC dbo.sp_create_member_level @level_name = N'13A-停用等级',
                                    @point_multiplier = 1.00,
                                    @threshold_points = 900000;
    -- test_store_manager 没有 MemberLevel 的 SELECT 权限，读回一律先 REVERT 用部署身份做
    REVERT; SET @impersonating = 0;
    SELECT @level_id = ml.member_level_id
    FROM dbo.MemberLevel AS ml
    WHERE ml.threshold_points = 900000 AND ml.[status] = 'ACTIVE';

    EXECUTE AS USER = N'test_store_manager';
    SET @impersonating = 1;
    EXEC dbo.sp_create_customer @mobile = '13900001313', @customer_type = 'GUEST';
    REVERT; SET @impersonating = 0;
    SELECT @customer_id = c.customer_id FROM dbo.Customer AS c WHERE c.mobile = '13900001313';

    IF @level_id IS NULL OR @customer_id IS NULL
        THROW 51931, N'13a A8 夹具：等级或顾客未建成。', 1;

    EXECUTE AS USER = N'test_store_manager';
    SET @impersonating = 1;
    EXEC dbo.sp_update_customer_member_level @customer_id = @customer_id,
                                             @member_level_id = @level_id;
    EXEC dbo.sp_update_member_level_status @member_level_id = @level_id,
                                           @status = 'INACTIVE';
    REVERT; SET @impersonating = 0;

    SELECT @level_after = c.member_level_id
    FROM dbo.Customer AS c
    WHERE c.customer_id = @customer_id;
END TRY
BEGIN CATCH
    SET @err = ERROR_NUMBER();
    SET @errmsg = ERROR_MESSAGE();
END CATCH;

IF XACT_STATE() = -1 ROLLBACK TRANSACTION;
IF @impersonating = 1 BEGIN REVERT; SET @impersonating = 0; END;
IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

IF @err IS NOT NULL
    SET @fail = CONCAT(N'A8（冻结事项 B／停用置空）：夹具抛出 ', @err, N'（', @errmsg, N'）。');
IF @fail IS NULL AND (@level_after IS NOT NULL)
    SET @fail = CONCAT(N'A8（冻结事项 B／停用置空）：等级停用后顾客仍挂着 member_level_id=',
                       @level_after, N'，未置空。');

IF @fail IS NOT NULL
BEGIN
    UPDATE #counters SET fail = fail + 1;
    PRINT N'FAIL: ' + @fail;
END
ELSE
BEGIN
    UPDATE #counters SET pass = pass + 1;
    PRINT N'PASS: A8 等级停用后成员等级置空';
END;
GO

-- ---------------------------------------------------------------------------
-- A9 冻结事项 B／不回溯：调高门槛、新增更高档，都不重算已有顾客的 member_level_id
-- ---------------------------------------------------------------------------
DECLARE @impersonating BIT = 0;
DECLARE @err INT = NULL, @errmsg NVARCHAR(2048) = NULL, @fail NVARCHAR(2048) = NULL;
DECLARE @level_id BIGINT, @customer_id BIGINT, @level_after BIGINT;

BEGIN TRANSACTION;
BEGIN TRY
    EXECUTE AS USER = N'test_store_manager';
    SET @impersonating = 1;

    EXEC dbo.sp_create_member_level @level_name = N'13A-不回溯等级',
                                    @point_multiplier = 1.00,
                                    @threshold_points = 910000;
    -- test_store_manager 没有 MemberLevel 的 SELECT 权限，读回一律先 REVERT 用部署身份做
    REVERT; SET @impersonating = 0;
    SELECT @level_id = ml.member_level_id
    FROM dbo.MemberLevel AS ml
    WHERE ml.threshold_points = 910000 AND ml.[status] = 'ACTIVE';

    EXECUTE AS USER = N'test_store_manager';
    SET @impersonating = 1;
    EXEC dbo.sp_create_customer @mobile = '13900001314', @customer_type = 'GUEST';
    REVERT; SET @impersonating = 0;
    SELECT @customer_id = c.customer_id FROM dbo.Customer AS c WHERE c.mobile = '13900001314';

    IF @level_id IS NULL OR @customer_id IS NULL
        THROW 51931, N'13a A9 夹具：等级或顾客未建成。', 1;

    EXECUTE AS USER = N'test_store_manager';
    SET @impersonating = 1;
    EXEC dbo.sp_update_customer_member_level @customer_id = @customer_id,
                                             @member_level_id = @level_id;

    -- ① 调门槛：把所在档的门槛抬到顾客积分之上，过程不应重算顾客
    EXEC dbo.sp_update_member_level @member_level_id = @level_id,
                                    @level_name = N'13A-不回溯等级',
                                    @point_multiplier = 1.00,
                                    @threshold_points = 910001;

    -- ② 加档：新增一档更高门槛，同样不应回溯
    EXEC dbo.sp_create_member_level @level_name = N'13A-更高等级',
                                    @point_multiplier = 1.00,
                                    @threshold_points = 920000;
    REVERT; SET @impersonating = 0;

    SELECT @level_after = c.member_level_id
    FROM dbo.Customer AS c
    WHERE c.customer_id = @customer_id;
END TRY
BEGIN CATCH
    SET @err = ERROR_NUMBER();
    SET @errmsg = ERROR_MESSAGE();
END CATCH;

IF XACT_STATE() = -1 ROLLBACK TRANSACTION;
IF @impersonating = 1 BEGIN REVERT; SET @impersonating = 0; END;
IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

IF @err IS NOT NULL
    SET @fail = CONCAT(N'A9（冻结事项 B／不回溯）：夹具抛出 ', @err, N'（', @errmsg, N'）。');
IF @fail IS NULL AND (@level_after IS NULL OR @level_after <> @level_id)
    SET @fail = CONCAT(N'A9（冻结事项 B／不回溯）：顾客等级在调门槛/加档后被改成 ',
                       ISNULL(CAST(@level_after AS NVARCHAR(20)), N'NULL'),
                       N'（期望保持 ', @level_id, N'）。');

IF @fail IS NOT NULL
BEGIN
    UPDATE #counters SET fail = fail + 1;
    PRINT N'FAIL: ' + @fail;
END
ELSE
BEGIN
    UPDATE #counters SET pass = pass + 1;
    PRINT N'PASS: A9 调门槛与加档都不回溯已有顾客';
END;
GO

-- ---------------------------------------------------------------------------
-- A10 冻结事项 C：同窗多行合法，定价函数按 priority DESC, rule_id ASC 取一
-- ---------------------------------------------------------------------------
DECLARE @err INT = NULL, @errmsg NVARCHAR(2048) = NULL, @fail NVARCHAR(2048) = NULL;
DECLARE @product_id BIGINT, @promotion_id BIGINT, @weekday_no INT;
DECLARE @rule_count INT, @price DECIMAL(10,2), @promo_found BIGINT;
DECLARE @at DATETIME2(0) = '2026-11-02 12:00:00';

BEGIN TRANSACTION;
BEGIN TRY
    SELECT TOP (1) @product_id = p.product_id
    FROM dbo.Product AS p
    WHERE p.[status] = 'ACTIVE' AND p.product_type = 'SINGLE'
    ORDER BY p.product_id;

    IF @product_id IS NULL
        THROW 51900, N'13a A10 夹具：没有 ACTIVE 的单品可挂促销。', 1;

    -- 与 fn_get_effective_product_price 的星期口径保持一致
    SET @weekday_no = DATEDIFF(DAY, DATEFROMPARTS(1900, 1, 1), CAST(@at AS DATE)) % 7 + 1;

    INSERT INTO dbo.Promotion (promotion_name, promotion_type, start_at, end_at, [status])
    VALUES (N'13A-同窗促销', 'FIXED_PRICE',
            CONVERT(DATETIME2(0), '2026-01-01 00:00:00'),
            CONVERT(DATETIME2(0), '2026-12-31 23:59:59'), 'ACTIVE');
    SET @promotion_id = CAST(SCOPE_IDENTITY() AS BIGINT);

    -- 同活动、同商品、同星期、同窗口的两行：按设计合法，靠 priority 分胜负
    INSERT INTO dbo.PromotionProductRule
        (promotion_id, product_id, weekday_no, start_time, end_time, promo_price, [priority])
    VALUES
        (@promotion_id, @product_id, @weekday_no, '00:00:00', '23:59:59', 7.00, 98),
        (@promotion_id, @product_id, @weekday_no, '00:00:00', '23:59:59', 3.00, 99);

    SET @rule_count = (SELECT COUNT(*) FROM dbo.PromotionProductRule
                       WHERE promotion_id = @promotion_id);

    SELECT @price = ep.effective_price, @promo_found = ep.promotion_id
    FROM dbo.fn_get_effective_product_price(@product_id, @at) AS ep;
END TRY
BEGIN CATCH
    SET @err = ERROR_NUMBER();
    SET @errmsg = ERROR_MESSAGE();
END CATCH;

IF XACT_STATE() = -1 ROLLBACK TRANSACTION;
IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

IF @err IS NOT NULL
    SET @fail = CONCAT(N'A10（冻结事项 C）：夹具抛出 ', @err, N'（', @errmsg, N'）。');
IF @fail IS NULL AND @rule_count <> 2
    SET @fail = CONCAT(N'A10（冻结事项 C）：同窗两档价未能共存，实际规则行数 ', ISNULL(CAST(@rule_count AS NVARCHAR(20)), N'NULL'), N'。');
IF @fail IS NULL AND (@price IS NULL OR @price <> 3.00 OR @promo_found <> @promotion_id)
    SET @fail = CONCAT(N'A10（冻结事项 C）：期望取 priority=99 的 3.00（促销 ', @promotion_id,
                       N'），实际价格=', ISNULL(CAST(@price AS NVARCHAR(20)), N'NULL'),
                       N' 促销=', ISNULL(CAST(@promo_found AS NVARCHAR(20)), N'NULL'), N'。');

IF @fail IS NOT NULL
BEGIN
    UPDATE #counters SET fail = fail + 1;
    PRINT N'FAIL: ' + @fail;
END
ELSE
BEGIN
    UPDATE #counters SET pass = pass + 1;
    PRINT N'PASS: A10 同窗两档价取高优先级';
END;
GO

-- ---------------------------------------------------------------------------
-- 收尾：RESULT 行 + 分母校验（10 条），失败非零退出
-- ---------------------------------------------------------------------------
DECLARE @pass INT = (SELECT pass FROM #counters);
DECLARE @fail INT = (SELECT fail FROM #counters);
PRINT 'RESULT: pass=' + CAST(@pass AS VARCHAR(10)) + ' fail=' + CAST(@fail AS VARCHAR(10));
IF @pass + @fail <> 10
    THROW 51999, N'13a：断言计数不足 10，说明有批次被静默作废（检查 -f 65001 与批次编译错误）。', 1;
IF @fail > 0
    THROW 51998, N'13a：存在失败的域回归断言，详见上方 FAIL 行。', 1;
GO

