-- 验收

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

-- 部署前提
IF NOT EXISTS (SELECT 1 FROM dbo.Product)
    THROW 51900, N'10a：A 域主数据为空，请先执行 09a_master_seed_data.sql。', 1;
IF DATABASE_PRINCIPAL_ID(N'test_store_manager') IS NULL
    THROW 51900, N'10a：缺少 test_store_manager，请先执行 08_roles_permissions.sql。', 1;
IF NOT EXISTS (SELECT 1 FROM dbo.EmployeeAccount
               WHERE database_user_name = N'test_store_manager' AND [status] = 'ACTIVE')
    THROW 51900, N'10a：test_store_manager 没有 ACTIVE 的 EmployeeAccount 行，请先执行 09c_inventory_opening_seed_data.sql。', 1;
GO


-- A1 反例：重复手机号被拒（sp_create_customer 预检 → 51005）
DECLARE @impersonating BIT = 0;
DECLARE @succeeded     BIT = 0;
DECLARE @err           INT = NULL;
DECLARE @errmsg        NVARCHAR(2048) = NULL;
DECLARE @fail          NVARCHAR(2048) = NULL;

BEGIN TRANSACTION;
BEGIN TRY
    EXECUTE AS USER = N'test_store_manager';
    SET @impersonating = 1;
    EXEC dbo.sp_create_customer @mobile = '13900000001', @customer_type = 'GUEST';
    SET @succeeded = 1;
END TRY
BEGIN CATCH
    SET @err = ERROR_NUMBER();
    SET @errmsg = ERROR_MESSAGE();
END CATCH;

IF @impersonating = 1 BEGIN REVERT; SET @impersonating = 0; END;
IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

IF @succeeded = 1
    SET @fail = N'10a A1（重复手机号被拒）：种子中已存在的手机号竟被再次建档。';
IF @fail IS NULL AND @err <> 51005
    SET @fail = CONCAT(N'10a A1（重复手机号被拒）：期望错误码 51005，实际 ', @err, N'（', @errmsg, N'）。');
IF @fail IS NOT NULL THROW 51901, @fail, 1;

PRINT N'PASS: A1 重复手机号被拒';
GO


-- A2 对照：新手机号可建档，且建档不带初始积分、不带等级
DECLARE @impersonating BIT = 0;
DECLARE @err           INT = NULL;
DECLARE @errmsg        NVARCHAR(2048) = NULL;
DECLARE @fail          NVARCHAR(2048) = NULL;
DECLARE @points        INT;
DECLARE @level_id      BIGINT;
DECLARE @status        VARCHAR(20);

BEGIN TRANSACTION;
BEGIN TRY
    EXECUTE AS USER = N'test_store_manager';
    SET @impersonating = 1;
    EXEC dbo.sp_create_customer @mobile = '13900009999', @customer_type = 'WOW';
END TRY
BEGIN CATCH
    SET @err = ERROR_NUMBER();
    SET @errmsg = ERROR_MESSAGE();
END CATCH;

IF @impersonating = 1 BEGIN REVERT; SET @impersonating = 0; END;

IF @err IS NOT NULL
BEGIN
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    SET @fail = CONCAT(N'10a A2（新手机号可建档）：建档过程抛出 ', @err, N'（', @errmsg, N'）。');
    THROW 51902, @fail, 1;
END;

SELECT @points   = c.current_points,
       @level_id = c.member_level_id,
       @status   = c.status
FROM dbo.Customer AS c
WHERE c.mobile = '13900009999';

IF @points IS NULL
    SET @fail = N'10a A2（新手机号可建档）：建档后查不到该顾客。';
IF @fail IS NULL AND (@points <> 0 OR @level_id IS NOT NULL OR @status <> 'ACTIVE')
    SET @fail = CONCAT(N'10a A2（新手机号可建档）：建档初始状态不符，实际 积分=', @points,
                       N' 等级=', ISNULL(CAST(@level_id AS NVARCHAR(20)), N'NULL'), N' 状态=', @status, N'。');

IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
IF @fail IS NOT NULL THROW 51903, @fail, 1;

PRINT N'PASS: A2 新手机号可建档且不带初始积分';
GO


-- A3 反例：负数价格被拒（sp_update_product_price 参数校验 → 51000）
DECLARE @impersonating BIT = 0;
DECLARE @succeeded     BIT = 0;
DECLARE @err           INT = NULL;
DECLARE @errmsg        NVARCHAR(2048) = NULL;
DECLARE @fail          NVARCHAR(2048) = NULL;

BEGIN TRANSACTION;
BEGIN TRY
    EXECUTE AS USER = N'test_store_manager';
    SET @impersonating = 1;
    EXEC dbo.sp_update_product_price @product_id = 1, @base_price = -1.00;
    SET @succeeded = 1;
END TRY
BEGIN CATCH
    SET @err = ERROR_NUMBER();
    SET @errmsg = ERROR_MESSAGE();
END CATCH;

IF @impersonating = 1 BEGIN REVERT; SET @impersonating = 0; END;
IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

IF @succeeded = 1
    SET @fail = N'10a A3（负数价格被拒）：负数价格竟被接受。';
IF @fail IS NULL AND @err <> 51000
    SET @fail = CONCAT(N'10a A3（负数价格被拒）：期望错误码 51000，实际 ', @err, N'（', @errmsg, N'）。');
IF @fail IS NOT NULL THROW 51904, @fail, 1;

PRINT N'PASS: A3 负数价格被拒';
GO


-- A4 对照：正数价格可改，且改动确实落库
DECLARE @impersonating BIT = 0;
DECLARE @err           INT = NULL;
DECLARE @errmsg        NVARCHAR(2048) = NULL;
DECLARE @fail          NVARCHAR(2048) = NULL;
DECLARE @price_before  DECIMAL(10,2);
DECLARE @new_price     DECIMAL(10,2);
DECLARE @price_after   DECIMAL(10,2);

BEGIN TRANSACTION;
BEGIN TRY
    SELECT @price_before = p.base_price FROM dbo.Product AS p WHERE p.product_id = 2;
    SET @new_price = @price_before + 1.00;

    EXECUTE AS USER = N'test_store_manager';
    SET @impersonating = 1;
    EXEC dbo.sp_update_product_price @product_id = 2, @base_price = @new_price;
END TRY
BEGIN CATCH
    SET @err = ERROR_NUMBER();
    SET @errmsg = ERROR_MESSAGE();
END CATCH;

IF @impersonating = 1 BEGIN REVERT; SET @impersonating = 0; END;

IF @err IS NOT NULL
BEGIN
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    SET @fail = CONCAT(N'10a A4（正数价格可改且落库）：改价过程抛出 ', @err, N'（', @errmsg, N'）。');
    THROW 51905, @fail, 1;
END;

SELECT @price_after = p.base_price FROM dbo.Product AS p WHERE p.product_id = 2;

IF @price_before IS NULL
    SET @fail = N'10a A4（正数价格可改且落库）：读不到 2 号商品的现价。';
IF @fail IS NULL AND @price_after <> @new_price
    SET @fail = CONCAT(N'10a A4（正数价格可改且落库）：库内价格应为 ', @new_price, N'，实际 ', @price_after, N'。');
IF @fail IS NULL AND @price_after = @price_before
    SET @fail = N'10a A4（正数价格可改且落库）：调用前后价格未发生变化，改动没有落库。';

IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
IF @fail IS NOT NULL THROW 51906, @fail, 1;

PRINT N'PASS: A4 正数价格可改且落库';
GO


-- A5 反例：促销结束早于开始被拒（sp_create_promotion 参数校验 → 51000）
DECLARE @impersonating BIT = 0;
DECLARE @succeeded     BIT = 0;
DECLARE @err           INT = NULL;
DECLARE @errmsg        NVARCHAR(2048) = NULL;
DECLARE @fail          NVARCHAR(2048) = NULL;
-- EXEC 的实参位只收常量/变量，不接受 CAST(...)，故先声明
DECLARE @start_late    DATETIME2(0) = CAST('2026-10-10 00:00:00' AS DATETIME2(0));
DECLARE @end_early     DATETIME2(0) = CAST('2026-10-01 00:00:00' AS DATETIME2(0));

BEGIN TRANSACTION;
BEGIN TRY
    EXECUTE AS USER = N'test_store_manager';
    SET @impersonating = 1;
    EXEC dbo.sp_create_promotion
         @promotion_name = N'10a 反例促销',
         @promotion_type = 'FIXED_PRICE',
         @start_at = @start_late,
         @end_at   = @end_early;
    SET @succeeded = 1;
END TRY
BEGIN CATCH
    SET @err = ERROR_NUMBER();
    SET @errmsg = ERROR_MESSAGE();
END CATCH;

IF @impersonating = 1 BEGIN REVERT; SET @impersonating = 0; END;
IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

IF @succeeded = 1
    SET @fail = N'10a A5（促销结束早于开始被拒）：结束早于开始的促销竟被接受。';
IF @fail IS NULL AND @err <> 51000
    SET @fail = CONCAT(N'10a A5（促销结束早于开始被拒）：期望错误码 51000，实际 ', @err, N'（', @errmsg, N'）。');
IF @fail IS NOT NULL THROW 51907, @fail, 1;

PRINT N'PASS: A5 促销结束早于开始被拒';
GO


-- A6 对照：起止合法时可建促销，且建档即 INACTIVE
DECLARE @impersonating BIT = 0;
DECLARE @err           INT = NULL;
DECLARE @errmsg        NVARCHAR(2048) = NULL;
DECLARE @fail          NVARCHAR(2048) = NULL;
DECLARE @promo_status  VARCHAR(20);
DECLARE @start_ok      DATETIME2(0) = CAST('2026-10-01 00:00:00' AS DATETIME2(0));
DECLARE @end_ok        DATETIME2(0) = CAST('2026-10-10 00:00:00' AS DATETIME2(0));

BEGIN TRANSACTION;
BEGIN TRY
    EXECUTE AS USER = N'test_store_manager';
    SET @impersonating = 1;
    EXEC dbo.sp_create_promotion
         @promotion_name = N'10a 对照促销',
         @promotion_type = 'FIXED_PRICE',
         @start_at = @start_ok,
         @end_at   = @end_ok;
END TRY
BEGIN CATCH
    SET @err = ERROR_NUMBER();
    SET @errmsg = ERROR_MESSAGE();
END CATCH;

IF @impersonating = 1 BEGIN REVERT; SET @impersonating = 0; END;

IF @err IS NOT NULL
BEGIN
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    SET @fail = CONCAT(N'10a A6（合法促销可建）：建促销过程抛出 ', @err, N'（', @errmsg, N'）。');
    THROW 51908, @fail, 1;
END;

SELECT @promo_status = p.[status] FROM dbo.Promotion AS p WHERE p.promotion_name = N'10a 对照促销';

IF @promo_status IS NULL
    SET @fail = N'10a A6（合法促销可建）：建完查不到该促销。';
IF @fail IS NULL AND @promo_status <> 'INACTIVE'
    SET @fail = CONCAT(N'10a A6（合法促销可建）：建档状态应为 INACTIVE，实际 ', @promo_status, N'。');

IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
IF @fail IS NOT NULL THROW 51909, @fail, 1;

PRINT N'PASS: A6 合法促销可建且建档即未启用';
GO


-- A7 重叠促销按 priority 取唯一最高优先级
DECLARE @thu        DATETIME2(0) = CAST('2026-10-01 12:00:00' AS DATETIME2(0));  -- 周四
DECLARE @sat        DATETIME2(0) = CAST('2026-10-03 12:00:00' AS DATETIME2(0));  -- 周六
DECLARE @thu_rows   INT;
DECLARE @sat_rows   INT;
DECLARE @thu_price  DECIMAL(10,2);
DECLARE @thu_promo  BIGINT;
DECLARE @sat_price  DECIMAL(10,2);
DECLARE @sat_promo  BIGINT;
DECLARE @fail       NVARCHAR(2048) = NULL;

BEGIN TRANSACTION;
BEGIN TRY
    SELECT @thu_rows = COUNT(*) FROM dbo.fn_get_effective_product_price(1, @thu);
    SELECT @sat_rows = COUNT(*) FROM dbo.fn_get_effective_product_price(1, @sat);
    SELECT TOP (1) @thu_price = effective_price, @thu_promo = promotion_id
    FROM dbo.fn_get_effective_product_price(1, @thu);
    SELECT TOP (1) @sat_price = effective_price, @sat_promo = promotion_id
    FROM dbo.fn_get_effective_product_price(1, @sat);
END TRY
BEGIN CATCH
    ROLLBACK TRANSACTION;
    THROW;
END CATCH;

IF @thu_rows <> 1 OR @sat_rows <> 1
    SET @fail = CONCAT(N'10a A7（重叠促销取唯一最高优先级）：定价函数没有恰返一行，周四 ', @thu_rows, N' 行、周六 ', @sat_rows, N' 行。');
IF @fail IS NULL AND (@thu_price <> 9.90 OR @thu_promo <> 1)
    SET @fail = CONCAT(N'10a A7（重叠促销取唯一最高优先级）：周四应取 priority 最高的规则 1（9.90），实际价=', @thu_price,
                       N' 促销ID=', ISNULL(CAST(@thu_promo AS NVARCHAR(20)), N'NULL'), N'。');
IF @fail IS NULL AND (@sat_price <> 19.00 OR @sat_promo IS NOT NULL)
    SET @fail = CONCAT(N'10a A7（重叠促销取唯一最高优先级）：周六应回标准价且无促销 ID，实际价=', @sat_price,
                       N' 促销ID=', ISNULL(CAST(@sat_promo AS NVARCHAR(20)), N'NULL'), N'。');

ROLLBACK TRANSACTION;
IF @fail IS NOT NULL THROW 51910, @fail, 1;

PRINT N'PASS: A7 重叠促销按 priority 取唯一最高优先级';
GO


-- A8 视图与定价函数在同一时刻返回相同价格与促销 ID
DECLARE @at           DATETIME2(0) = SYSDATETIME();
DECLARE @seed_present INT;
DECLARE @mismatch     INT;
DECLARE @fail         NVARCHAR(2048) = NULL;

BEGIN TRANSACTION;
BEGIN TRY
    SELECT @seed_present = COUNT(*)
    FROM dbo.v_active_product_price
    WHERE product_id IN (1, 2, 3, 4, 5, 6);

    SELECT @mismatch = COUNT(*)
    FROM dbo.v_active_product_price AS v
    CROSS APPLY dbo.fn_get_effective_product_price(v.product_id, @at) AS f
    WHERE v.effective_price <> f.effective_price
       OR ISNULL(v.promotion_id, -1) <> ISNULL(f.promotion_id, -1);
END TRY
BEGIN CATCH
    ROLLBACK TRANSACTION;
    THROW;
END CATCH;

IF @seed_present <> 6
    SET @fail = CONCAT(N'10a A8（视图与函数同价同促销ID）：视图只返回了 ', @seed_present, N' / 6 个种子在售商品，比对会空洞通过。');
IF @fail IS NULL AND @mismatch <> 0
    SET @fail = CONCAT(N'10a A8（视图与函数同价同促销ID）：有 ', @mismatch, N' 行在售商品的价格或促销 ID 与定价函数不一致。');

ROLLBACK TRANSACTION;
IF @fail IS NOT NULL THROW 51911, @fail, 1;

PRINT N'PASS: A8 视图与函数在同一时刻同价同促销 ID';
GO


-- A9 反例：无任何用料的单品不能上架（sp_update_product_status → 51003）
DECLARE @impersonating BIT = 0;
DECLARE @succeeded     BIT = 0;
DECLARE @err           INT = NULL;
DECLARE @errmsg        NVARCHAR(2048) = NULL;
DECLARE @fail          NVARCHAR(2048) = NULL;
DECLARE @no_bom        BIGINT;

BEGIN TRANSACTION;
BEGIN TRY
    -- 夹具（验收期受限例外：直插以取得 ID，并且一插入就是 INACTIVE）
    INSERT INTO dbo.Product (product_name, base_price, product_type, [status])
    VALUES (N'10a 夹具-无用料单品', 1.00, 'SINGLE', 'INACTIVE');
    SET @no_bom = SCOPE_IDENTITY();

    EXECUTE AS USER = N'test_store_manager';
    SET @impersonating = 1;
    EXEC dbo.sp_update_product_status @product_id = @no_bom, @status = 'ACTIVE';
    SET @succeeded = 1;
END TRY
BEGIN CATCH
    SET @err = ERROR_NUMBER();
    SET @errmsg = ERROR_MESSAGE();
END CATCH;

IF @impersonating = 1 BEGIN REVERT; SET @impersonating = 0; END;
IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

IF @succeeded = 1
    SET @fail = N'10a A9（无用料单品不能上架）：无用料单品竟被上架。';
IF @fail IS NULL AND @err <> 51003
    SET @fail = CONCAT(N'10a A9（无用料单品不能上架）：期望错误码 51003，实际 ', @err, N'（', @errmsg, N'）。');
IF @fail IS NOT NULL THROW 51912, @fail, 1;

PRINT N'PASS: A9 无用料单品不能上架';
GO


-- A10 对照：有 BOM 用料的单品可以上架
DECLARE @impersonating BIT = 0;
DECLARE @err           INT = NULL;
DECLARE @errmsg        NVARCHAR(2048) = NULL;
DECLARE @fail          NVARCHAR(2048) = NULL;
DECLARE @with_bom      BIGINT;
DECLARE @status_after  VARCHAR(20);

BEGIN TRANSACTION;
BEGIN TRY
    INSERT INTO dbo.Product (product_name, base_price, product_type, [status])
    VALUES (N'10a 夹具-有用料单品', 1.00, 'SINGLE', 'INACTIVE');
    SET @with_bom = SCOPE_IDENTITY();
    INSERT INTO dbo.ProductBom (product_id, ingredient_id, usage_qty)
    VALUES (@with_bom, 1, 1.000);

    EXECUTE AS USER = N'test_store_manager';
    SET @impersonating = 1;
    EXEC dbo.sp_update_product_status @product_id = @with_bom, @status = 'ACTIVE';
END TRY
BEGIN CATCH
    SET @err = ERROR_NUMBER();
    SET @errmsg = ERROR_MESSAGE();
END CATCH;

IF @impersonating = 1 BEGIN REVERT; SET @impersonating = 0; END;

IF @err IS NOT NULL
BEGIN
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    SET @fail = CONCAT(N'10a A10（有用料单品可上架）：上架过程抛出 ', @err, N'（', @errmsg, N'）。');
    THROW 51913, @fail, 1;
END;

SELECT @status_after = p.[status] FROM dbo.Product AS p WHERE p.product_id = @with_bom;

IF @status_after <> 'ACTIVE'
    SET @fail = CONCAT(N'10a A10（有用料单品可上架）：状态应为 ACTIVE，实际 ', ISNULL(@status_after, N'读不到'), N'。');

IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
IF @fail IS NOT NULL THROW 51914, @fail, 1;

PRINT N'PASS: A10 有用料单品可以上架';
GO


-- A11 反例：套餐存在没有 BOM 的子项时不能上架（sp_update_product_status 第三道门 → 51003）
DECLARE @impersonating BIT = 0;
DECLARE @succeeded     BIT = 0;
DECLARE @err           INT = NULL;
DECLARE @errmsg        NVARCHAR(2048) = NULL;
DECLARE @fail          NVARCHAR(2048) = NULL;
DECLARE @bad_child     BIGINT;
DECLARE @combo         BIGINT;

BEGIN TRANSACTION;
BEGIN TRY
    INSERT INTO dbo.Product (product_name, base_price, product_type, [status])
    VALUES (N'10a 夹具-坏子项', 1.00, 'SINGLE', 'INACTIVE');
    SET @bad_child = SCOPE_IDENTITY();

    INSERT INTO dbo.Product (product_name, base_price, product_type, [status])
    VALUES (N'10a 夹具-坏套餐', 9.00, 'COMBO', 'INACTIVE');
    SET @combo = SCOPE_IDENTITY();

    INSERT INTO dbo.ComboComponent (combo_product_id, child_product_id, quantity)
    VALUES (@combo, @bad_child, 1);

    EXECUTE AS USER = N'test_store_manager';
    SET @impersonating = 1;
    EXEC dbo.sp_update_product_status @product_id = @combo, @status = 'ACTIVE';
    SET @succeeded = 1;
END TRY
BEGIN CATCH
    SET @err = ERROR_NUMBER();
    SET @errmsg = ERROR_MESSAGE();
END CATCH;

IF @impersonating = 1 BEGIN REVERT; SET @impersonating = 0; END;
IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

IF @succeeded = 1
    SET @fail = N'10a A11（子项无用料的套餐不能上架）：竟被上架。';
IF @fail IS NULL AND @err <> 51003
    SET @fail = CONCAT(N'10a A11（子项无用料的套餐不能上架）：期望错误码 51003，实际 ', @err, N'（', @errmsg, N'）。');
IF @fail IS NOT NULL THROW 51915, @fail, 1;

PRINT N'PASS: A11 子项无用料的套餐不能上架';
GO


-- A12 BOM 视图的单品分支：用料商品即商品自身
DECLARE @rows  INT;
DECLARE @self  INT;
DECLARE @fail  NVARCHAR(2048) = NULL;

BEGIN TRANSACTION;
BEGIN TRY
    SELECT @rows = COUNT(*) FROM dbo.v_product_bom_detail WHERE sale_product_id = 1;
    SELECT @self = COUNT(*) FROM dbo.v_product_bom_detail
    WHERE sale_product_id = 1 AND used_product_id = 1;
END TRY
BEGIN CATCH
    ROLLBACK TRANSACTION;
    THROW;
END CATCH;

IF @rows <> 4
    SET @fail = CONCAT(N'10a A12（单品 BOM 视图分支）：1 号商品的用料行数应为 4，实际 ', @rows, N'。');
IF @fail IS NULL AND @self <> @rows
    SET @fail = CONCAT(N'10a A12（单品 BOM 视图分支）：单品的实际用料商品应是商品自身，', @rows, N' 行中只有 ', @self, N' 行是。');

ROLLBACK TRANSACTION;
IF @fail IS NOT NULL THROW 51916, @fail, 1;

PRINT N'PASS: A12 单品 BOM 视图分支';
GO


-- A13 BOM 视图的套餐分支：经子商品展开、用量按子项数量缩放、跨子项合计数正确
-- 期望（数字取自 09a 种子）：套餐 5 = 香辣鸡腿堡×1 + 劲脆鸡腿堡×1 + 可乐(中)×2，
--   3 个子商品 / 9 行；跨子项合计 鸡腿肉 2.000、汉堡面包 2.000、生菜 50.000、
--   沙拉酱 45.000、可乐原浆 600.000（= 300.000 × 2，即按子项数量缩放）
DECLARE @rows          INT;
DECLARE @children      INT;
DECLARE @child_lettuce DECIMAL(12,3);
DECLARE @bad           INT;
DECLARE @fail          NVARCHAR(2048) = NULL;

BEGIN TRANSACTION;
BEGIN TRY
    SELECT @rows     = COUNT(*) FROM dbo.v_product_bom_detail WHERE sale_product_id = 5;
    SELECT @children = COUNT(DISTINCT used_product_id) FROM dbo.v_product_bom_detail WHERE sale_product_id = 5;
    SELECT @child_lettuce = qty_per_sale FROM dbo.v_product_bom_detail
    WHERE sale_product_id = 5 AND used_product_id = 1 AND ingredient_id = 3;

    SELECT @bad = COUNT(*)
    FROM (
        SELECT v.ingredient_id, SUM(v.qty_per_sale) AS qty
        FROM dbo.v_product_bom_detail AS v
        WHERE v.sale_product_id = 5
        GROUP BY v.ingredient_id
    ) AS a
    FULL JOIN (VALUES
        (1, CAST(2.000   AS DECIMAL(12,3))),
        (2, CAST(2.000   AS DECIMAL(12,3))),
        (3, CAST(50.000  AS DECIMAL(12,3))),
        (4, CAST(45.000  AS DECIMAL(12,3))),
        (6, CAST(600.000 AS DECIMAL(12,3)))
    ) AS e (ingredient_id, qty) ON e.ingredient_id = a.ingredient_id
    WHERE a.qty IS NULL OR e.qty IS NULL OR a.qty <> e.qty;
END TRY
BEGIN CATCH
    ROLLBACK TRANSACTION;
    THROW;
END CATCH;

IF @rows <> 9 OR @children <> 3
    SET @fail = CONCAT(N'10a A13（套餐 BOM 视图分支）：行粒度应为（套餐, 子商品, 原料），应 9 行 3 子商品，实际 ',
                       @rows, N' 行 ', @children, N' 子商品。');
IF @fail IS NULL AND @child_lettuce <> 30.000
    SET @fail = CONCAT(N'10a A13（套餐 BOM 视图分支）：每子商品行被误汇总，生菜应为该子项自身的 30.000，实际 ',
                       ISNULL(CAST(@child_lettuce AS NVARCHAR(20)), N'读不到'), N'。');
IF @fail IS NULL AND @bad <> 0
    SET @fail = CONCAT(N'10a A13（套餐 BOM 视图分支）：有 ', @bad, N' 种原料的跨子项合计用量与种子不符。');

ROLLBACK TRANSACTION;
IF @fail IS NOT NULL THROW 51917, @fail, 1;

PRINT N'PASS: A13 套餐 BOM 视图分支（展开、缩放与跨子项合计）';
GO
