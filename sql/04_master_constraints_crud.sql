-- 04_master_constraints_crud.sql —— 22 条命名 CHECK + 2 个接口 + 18 个 CRUD 过程

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


CREATE FUNCTION dbo.fn_get_effective_product_price
(
    @product_id BIGINT,
    @at DATETIME2(0)
)
RETURNS TABLE
AS 
RETURN
(
   SELECT
        i.product_id,
        COALESCE(promo_rule.promo_price, p.base_price) AS effective_price,
        promo_rule.promotion_id
    FROM (VALUES (@product_id)) AS i (product_id)
    LEFT JOIN dbo.Product AS p
           ON p.product_id = i.product_id
    -- 别名不能取名为 rule：RULE 是 T-SQL 保留字（遗留 CREATE RULE），裸用会报 Msg 156
    OUTER APPLY
    (
        SELECT TOP (1)
               r.promo_price,
               r.promotion_id
        FROM dbo.PromotionProductRule AS r
        JOIN dbo.Promotion AS pr
          ON pr.promotion_id = r.promotion_id
        WHERE r.product_id = i.product_id
          AND pr.status = 'ACTIVE'
          AND @at BETWEEN pr.start_at AND pr.end_at
          AND r.weekday_no = DATEDIFF(DAY, DATEFROMPARTS(1900, 1, 1), CAST(@at AS DATE)) % 7 + 1
          AND CAST(@at AS TIME(0)) >= r.start_time
          AND CAST(@at AS TIME(0)) <  r.end_time
        ORDER BY r.priority DESC, r.promotion_rule_id ASC
    ) AS promo_rule
);
GO


-- 积分入账
CREATE PROCEDURE dbo.sp_apply_customer_points
    @customer_id BIGINT,
    @delta       INT
AS
BEGIN
    SET NOCOUNT ON;

    IF @delta IS NULL OR @delta < 0
        THROW 51000, N'sp_apply_customer_points：@delta 不能为 NULL 或负数。', 1;

    DECLARE @owns_tran BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;
    IF @owns_tran = 1
        BEGIN TRANSACTION;
    ELSE
        SAVE TRANSACTION sp_apply_customer_points;

    BEGIN TRY
        DECLARE @current_points INT,
                @status         VARCHAR(20);

        -- 先锁定顾客行再读，避免两个并发入账基于同一旧值各加一次
        SELECT @current_points = c.current_points,
               @status         = c.status
        FROM dbo.Customer AS c WITH (UPDLOCK, HOLDLOCK)
        WHERE c.customer_id = @customer_id;

        IF @current_points IS NULL
            THROW 51001, N'sp_apply_customer_points：客户不存在。', 1;
        IF @status <> 'ACTIVE'
            THROW 51002, N'sp_apply_customer_points：客户已停用，拒绝入账。', 1;

        DECLARE @new_points INT = @current_points + @delta;

        UPDATE dbo.Customer
        SET current_points  = @new_points,
            member_level_id = (
                SELECT TOP (1) ml.member_level_id
                FROM dbo.MemberLevel AS ml
                WHERE ml.status = 'ACTIVE'
                  AND ml.threshold_points <= @new_points
                ORDER BY ml.threshold_points DESC, ml.member_level_id ASC
            )
        WHERE customer_id = @customer_id;

        IF @owns_tran = 1
            COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @owns_tran = 1 AND XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        ELSE IF @owns_tran = 0 AND XACT_STATE() = 1
            ROLLBACK TRANSACTION sp_apply_customer_points;
        THROW;
    END CATCH;
END
GO


-- 正数 / 非负
ALTER TABLE dbo.Product              WITH CHECK ADD CONSTRAINT CK_Product_base_price              CHECK (base_price > 0);
ALTER TABLE dbo.ProductBom           WITH CHECK ADD CONSTRAINT CK_ProductBom_usage_qty           CHECK (usage_qty > 0);
ALTER TABLE dbo.ComboComponent       WITH CHECK ADD CONSTRAINT CK_ComboComponent_quantity         CHECK (quantity > 0);
ALTER TABLE dbo.PromotionProductRule WITH CHECK ADD CONSTRAINT CK_PromotionProductRule_promo_price CHECK (promo_price > 0);
ALTER TABLE dbo.Ingredient           WITH CHECK ADD CONSTRAINT CK_Ingredient_safety_stock_qty     CHECK (safety_stock_qty >= 0);
ALTER TABLE dbo.PromotionProductRule WITH CHECK ADD CONSTRAINT CK_PromotionProductRule_priority   CHECK (priority >= 0);
ALTER TABLE dbo.MemberLevel          WITH CHECK ADD CONSTRAINT CK_MemberLevel_threshold_points    CHECK (threshold_points >= 0);
ALTER TABLE dbo.Customer             WITH CHECK ADD CONSTRAINT CK_Customer_current_points         CHECK (current_points >= 0);
ALTER TABLE dbo.MemberLevel          WITH CHECK ADD CONSTRAINT CK_MemberLevel_point_multiplier    CHECK (point_multiplier > 0);

-- 时间与星期
ALTER TABLE dbo.Promotion            WITH CHECK ADD CONSTRAINT CK_Promotion_end_at              CHECK (end_at > start_at);
ALTER TABLE dbo.PromotionProductRule WITH CHECK ADD CONSTRAINT CK_PromotionProductRule_end_time CHECK (end_time > start_time);
ALTER TABLE dbo.PromotionProductRule WITH CHECK ADD CONSTRAINT CK_PromotionProductRule_weekday_no CHECK (weekday_no BETWEEN 1 AND 7);

-- 枚举
ALTER TABLE dbo.Category     WITH CHECK ADD CONSTRAINT CK_Category_status     CHECK ([status] IN ('ACTIVE','INACTIVE'));
ALTER TABLE dbo.Product      WITH CHECK ADD CONSTRAINT CK_Product_status      CHECK ([status] IN ('ACTIVE','INACTIVE'));
ALTER TABLE dbo.Ingredient   WITH CHECK ADD CONSTRAINT CK_Ingredient_status   CHECK ([status] IN ('ACTIVE','INACTIVE'));
ALTER TABLE dbo.Promotion    WITH CHECK ADD CONSTRAINT CK_Promotion_status    CHECK ([status] IN ('ACTIVE','INACTIVE'));
ALTER TABLE dbo.MemberLevel  WITH CHECK ADD CONSTRAINT CK_MemberLevel_status  CHECK ([status] IN ('ACTIVE','INACTIVE'));
ALTER TABLE dbo.Customer     WITH CHECK ADD CONSTRAINT CK_Customer_status     CHECK ([status] IN ('ACTIVE','INACTIVE'));
ALTER TABLE dbo.Product      WITH CHECK ADD CONSTRAINT CK_Product_product_type   CHECK (product_type IN ('SINGLE','COMBO'));
ALTER TABLE dbo.Customer     WITH CHECK ADD CONSTRAINT CK_Customer_customer_type CHECK (customer_type IN ('GUEST','WOW','PAID'));
ALTER TABLE dbo.Promotion    WITH CHECK ADD CONSTRAINT CK_Promotion_promotion_type CHECK (promotion_type = 'FIXED_PRICE');

-- 手机号（要放真号不只是 TEMP-）
ALTER TABLE dbo.Customer WITH CHECK ADD CONSTRAINT CK_Customer_mobile CHECK (
       (mobile NOT LIKE 'TEMP-%' AND LEN(mobile) = 11 AND mobile NOT LIKE '%[^0-9]%')
    OR (mobile LIKE 'TEMP-%' AND LEN(mobile) = 16 AND SUBSTRING(mobile, 6, 11) NOT LIKE '%[^0-9]%')
);
GO



-- 18 个 CRUD 过程
SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET QUOTED_IDENTIFIER ON;
SET NUMERIC_ROUNDABORT OFF;
GO


-- 1/18 分类
CREATE PROCEDURE dbo.sp_create_category
    @category_name NVARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;

    IF @category_name IS NULL OR LTRIM(RTRIM(@category_name)) = N''
        THROW 51000, N'sp_create_category：@category_name 不能为空。', 1;

    DECLARE @employee_id BIGINT;

    SELECT @employee_id = ea.employee_id
    FROM dbo.EmployeeAccount AS ea
    WHERE ea.database_user_name = USER_NAME()
      AND ea.status = 'ACTIVE';

    IF @employee_id IS NULL
        THROW 51004, N'sp_create_category：当前登录主体未映射到启用员工，拒绝执行。', 1;

    DECLARE @owns_tran BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;

    IF @owns_tran = 1
        BEGIN TRANSACTION;
    ELSE
        SAVE TRANSACTION sp_create_category;

    BEGIN TRY
        -- 分类无"配置未完成"的前置条件，建档即可用
        INSERT INTO dbo.Category (category_name, [status])
        VALUES (LTRIM(RTRIM(@category_name)), 'ACTIVE');

        IF @owns_tran = 1
            COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @owns_tran = 1 AND XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        ELSE IF @owns_tran = 0 AND XACT_STATE() = 1
            ROLLBACK TRANSACTION sp_create_category;
        THROW;
    END CATCH;
END
GO


-- 2/18 分类状态
CREATE PROCEDURE dbo.sp_update_category_status
    @category_id BIGINT,
    @status      VARCHAR(20)
AS
BEGIN
    SET NOCOUNT ON;

    IF @category_id IS NULL OR @status IS NULL OR @status NOT IN ('ACTIVE', 'INACTIVE')
        THROW 51000, N'sp_update_category_status：@category_id 不能为 NULL，@status 只能是 ACTIVE 或 INACTIVE。', 1;

    DECLARE @employee_id BIGINT;

    SELECT @employee_id = ea.employee_id
    FROM dbo.EmployeeAccount AS ea
    WHERE ea.database_user_name = USER_NAME()
      AND ea.status = 'ACTIVE';

    IF @employee_id IS NULL
        THROW 51004, N'sp_update_category_status：当前登录主体未映射到启用员工，拒绝执行。', 1;

    DECLARE @owns_tran BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;

    IF @owns_tran = 1
        BEGIN TRANSACTION;
    ELSE
        SAVE TRANSACTION sp_update_category_status;

    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.Category AS c WHERE c.category_id = @category_id)
            THROW 51001, N'sp_update_category_status：分类不存在。', 1;

        UPDATE dbo.Category
        SET [status] = @status
        WHERE category_id = @category_id;

        IF @owns_tran = 1
            COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @owns_tran = 1 AND XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        ELSE IF @owns_tran = 0 AND XACT_STATE() = 1
            ROLLBACK TRANSACTION sp_update_category_status;
        THROW;
    END CATCH;
END
GO


-- 3/18 原料
CREATE PROCEDURE dbo.sp_create_ingredient
    @ingredient_name  NVARCHAR(50),
    @unit_name        NVARCHAR(50),
    @safety_stock_qty DECIMAL(12,3)
AS
BEGIN
    SET NOCOUNT ON;

    IF @ingredient_name IS NULL OR LTRIM(RTRIM(@ingredient_name)) = N''
       OR @unit_name IS NULL OR LTRIM(RTRIM(@unit_name)) = N''
       OR @safety_stock_qty IS NULL OR @safety_stock_qty < 0
        THROW 51000, N'sp_create_ingredient：名称与单位不能为空，@safety_stock_qty 不能为 NULL 或负数。', 1;

    DECLARE @employee_id BIGINT;

    SELECT @employee_id = ea.employee_id
    FROM dbo.EmployeeAccount AS ea
    WHERE ea.database_user_name = USER_NAME()
      AND ea.status = 'ACTIVE';

    IF @employee_id IS NULL
        THROW 51004, N'sp_create_ingredient：当前登录主体未映射到启用员工，拒绝执行。', 1;

    DECLARE @owns_tran BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;

    IF @owns_tran = 1
        BEGIN TRANSACTION;
    ELSE
        SAVE TRANSACTION sp_create_ingredient;

    BEGIN TRY
        -- 18 个过程里没有 sp_update_ingredient_status，建档必须给 ACTIVE，否则该原料再无启用入口
        INSERT INTO dbo.Ingredient (ingredient_name, unit_name, safety_stock_qty, [status])
        VALUES (LTRIM(RTRIM(@ingredient_name)), LTRIM(RTRIM(@unit_name)), @safety_stock_qty, 'ACTIVE');

        IF @owns_tran = 1
            COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @owns_tran = 1 AND XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        ELSE IF @owns_tran = 0 AND XACT_STATE() = 1
            ROLLBACK TRANSACTION sp_create_ingredient;
        THROW;
    END CATCH;
END
GO


-- 4/18 原料（含状态：本表没有独立的状态过程，故并入本过程）
CREATE PROCEDURE dbo.sp_update_ingredient
    @ingredient_id    BIGINT,
    @ingredient_name  NVARCHAR(50),
    @unit_name        NVARCHAR(50),
    @safety_stock_qty DECIMAL(12,3),
    @status           VARCHAR(20)
AS
BEGIN
    SET NOCOUNT ON;

    IF @ingredient_id IS NULL
       OR @ingredient_name IS NULL OR LTRIM(RTRIM(@ingredient_name)) = N''
       OR @unit_name IS NULL OR LTRIM(RTRIM(@unit_name)) = N''
       OR @safety_stock_qty IS NULL OR @safety_stock_qty < 0
       OR @status IS NULL OR @status NOT IN ('ACTIVE', 'INACTIVE')
        THROW 51000, N'sp_update_ingredient：名称与单位不能为空，@safety_stock_qty 不能为 NULL 或负数，@status 只能是 ACTIVE 或 INACTIVE。', 1;

    DECLARE @employee_id BIGINT;

    SELECT @employee_id = ea.employee_id
    FROM dbo.EmployeeAccount AS ea
    WHERE ea.database_user_name = USER_NAME()
      AND ea.status = 'ACTIVE';

    IF @employee_id IS NULL
        THROW 51004, N'sp_update_ingredient：当前登录主体未映射到启用员工，拒绝执行。', 1;

    DECLARE @owns_tran BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;

    IF @owns_tran = 1
        BEGIN TRANSACTION;
    ELSE
        SAVE TRANSACTION sp_update_ingredient;

    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.Ingredient AS i WHERE i.ingredient_id = @ingredient_id)
            THROW 51001, N'sp_update_ingredient：原料不存在。', 1;

        UPDATE dbo.Ingredient
        SET ingredient_name  = LTRIM(RTRIM(@ingredient_name)),
            unit_name        = LTRIM(RTRIM(@unit_name)),
            safety_stock_qty = @safety_stock_qty,
            [status]         = @status
        WHERE ingredient_id = @ingredient_id;

        IF @owns_tran = 1
            COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @owns_tran = 1 AND XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        ELSE IF @owns_tran = 0 AND XACT_STATE() = 1
            ROLLBACK TRANSACTION sp_update_ingredient;
        THROW;
    END CATCH;
END
GO


-- 5/18 商品（建档同时写主分类关系）
CREATE PROCEDURE dbo.sp_create_product
    @product_name NVARCHAR(50),
    @base_price   DECIMAL(10,2),
    @product_type VARCHAR(20),
    @category_id  BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    IF @product_name IS NULL OR LTRIM(RTRIM(@product_name)) = N''
       OR @base_price IS NULL OR @base_price <= 0
       OR @product_type IS NULL OR @product_type NOT IN ('SINGLE', 'COMBO')
       OR @category_id IS NULL
        THROW 51000, N'sp_create_product：名称不能为空，@base_price 必须大于 0，@product_type 只能是 SINGLE 或 COMBO，@category_id 不能为 NULL。', 1;

    DECLARE @employee_id BIGINT;

    SELECT @employee_id = ea.employee_id
    FROM dbo.EmployeeAccount AS ea
    WHERE ea.database_user_name = USER_NAME()
      AND ea.status = 'ACTIVE';

    IF @employee_id IS NULL
        THROW 51004, N'sp_create_product：当前登录主体未映射到启用员工，拒绝执行。', 1;

    DECLARE @owns_tran BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;

    IF @owns_tran = 1
        BEGIN TRANSACTION;
    ELSE
        SAVE TRANSACTION sp_create_product;

    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.Category AS c
                       WHERE c.category_id = @category_id AND c.[status] = 'ACTIVE')
            THROW 51003, N'sp_create_product：@category_id 不存在或已停用，不能作为主分类。', 1;

        DECLARE @product_id BIGINT;

        -- 固定 ACTIVE：BOM/子项配置按计划 §3 A-2 line 227 要求商品为 ACTIVE，建档若为 INACTIVE 会互锁
        -- （详见字典 §11 第 9 项）。配齐用料仍由 sp_update_product_status 控制上下架。
        INSERT INTO dbo.Product (product_name, base_price, product_type, [status])
        VALUES (LTRIM(RTRIM(@product_name)), @base_price, @product_type, 'ACTIVE');

        SET @product_id = SCOPE_IDENTITY();

        -- 字典 §5：v_active_product_price 靠 is_primary = 1 取展示分类，建档必须同时写主分类，
        -- 否则商品在视图里隐身。一张商品至多一个主分类由 UQ_ProductCategory_is_primary 保证。
        INSERT INTO dbo.ProductCategory (product_id, category_id, is_primary)
        VALUES (@product_id, @category_id, 1);

        DECLARE @detail_json NVARCHAR(MAX) =
            (SELECT @product_id    AS product_id,
                    LTRIM(RTRIM(@product_name)) AS product_name,
                    @product_type  AS product_type,
                    @base_price    AS base_price,
                    @category_id   AS primary_category_id,
                    'ACTIVE'       AS [status]
             FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC dbo.sp_write_audit_log
             @employee_id = @employee_id,
             @action_name = 'CREATE_PRODUCT',
             @entity_name = 'Product',
             @entity_id   = @product_id,
             @detail_json = @detail_json;

        IF @owns_tran = 1
            COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @owns_tran = 1 AND XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        ELSE IF @owns_tran = 0 AND XACT_STATE() = 1
            ROLLBACK TRANSACTION sp_create_product;
        THROW;
    END CATCH;
END
GO


-- 6/18 商品标准价
CREATE PROCEDURE dbo.sp_update_product_price
    @product_id BIGINT,
    @base_price DECIMAL(10,2)
AS
BEGIN
    SET NOCOUNT ON;

    IF @product_id IS NULL OR @base_price IS NULL OR @base_price <= 0
        THROW 51000, N'sp_update_product_price：@product_id 不能为 NULL，@base_price 必须大于 0。', 1;

    DECLARE @employee_id BIGINT;

    SELECT @employee_id = ea.employee_id
    FROM dbo.EmployeeAccount AS ea
    WHERE ea.database_user_name = USER_NAME()
      AND ea.status = 'ACTIVE';

    IF @employee_id IS NULL
        THROW 51004, N'sp_update_product_price：当前登录主体未映射到启用员工，拒绝执行。', 1;

    DECLARE @owns_tran BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;

    IF @owns_tran = 1
        BEGIN TRANSACTION;
    ELSE
        SAVE TRANSACTION sp_update_product_price;

    BEGIN TRY
        DECLARE @base_price_before DECIMAL(10,2);

        SELECT @base_price_before = p.base_price
        FROM dbo.Product AS p WITH (UPDLOCK, HOLDLOCK)
        WHERE p.product_id = @product_id;

        IF @base_price_before IS NULL
            THROW 51001, N'sp_update_product_price：商品不存在。', 1;

        UPDATE dbo.Product
        SET base_price = @base_price
        WHERE product_id = @product_id;

        DECLARE @detail_json NVARCHAR(MAX) =
            (SELECT @product_id          AS product_id,
                    @base_price_before   AS base_price_before,
                    @base_price          AS base_price_after
             FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC dbo.sp_write_audit_log
             @employee_id = @employee_id,
             @action_name = 'UPDATE_PRODUCT_PRICE',
             @entity_name = 'Product',
             @entity_id   = @product_id,
             @detail_json = @detail_json;

        IF @owns_tran = 1
            COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @owns_tran = 1 AND XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        ELSE IF @owns_tran = 0 AND XACT_STATE() = 1
            ROLLBACK TRANSACTION sp_update_product_price;
        THROW;
    END CATCH;
END
GO


-- 7/18 商品上架 / 下架
CREATE PROCEDURE dbo.sp_update_product_status
    @product_id BIGINT,
    @status     VARCHAR(20)
AS
BEGIN
    SET NOCOUNT ON;

    IF @product_id IS NULL OR @status IS NULL OR @status NOT IN ('ACTIVE', 'INACTIVE')
        THROW 51000, N'sp_update_product_status：@product_id 不能为 NULL，@status 只能是 ACTIVE 或 INACTIVE。', 1;

    DECLARE @employee_id BIGINT;

    SELECT @employee_id = ea.employee_id
    FROM dbo.EmployeeAccount AS ea
    WHERE ea.database_user_name = USER_NAME()
      AND ea.status = 'ACTIVE';

    IF @employee_id IS NULL
        THROW 51004, N'sp_update_product_status：当前登录主体未映射到启用员工，拒绝执行。', 1;

    DECLARE @owns_tran BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;

    IF @owns_tran = 1
        BEGIN TRANSACTION;
    ELSE
        SAVE TRANSACTION sp_update_product_status;

    BEGIN TRY
        DECLARE @product_type   VARCHAR(20),
                @status_before  VARCHAR(20);

        SELECT @product_type  = p.product_type,
               @status_before = p.[status]
        FROM dbo.Product AS p WITH (UPDLOCK, HOLDLOCK)
        WHERE p.product_id = @product_id;

        IF @product_type IS NULL
            THROW 51001, N'sp_update_product_status：商品不存在。', 1;

       
        IF @status = 'ACTIVE' AND @status_before <> 'ACTIVE'
        BEGIN
            IF @product_type = 'SINGLE'
               AND NOT EXISTS (SELECT 1 FROM dbo.ProductBom AS b WHERE b.product_id = @product_id)
                THROW 51003, N'sp_update_product_status：单品没有任何 BOM 用料，不能上架。', 1;

            IF @product_type = 'COMBO'
               AND NOT EXISTS (SELECT 1 FROM dbo.ComboComponent AS c WHERE c.combo_product_id = @product_id)
                THROW 51003, N'sp_update_product_status：套餐没有任何子项，不能上架。', 1;

            IF @product_type = 'COMBO'
               AND EXISTS (SELECT 1
                           FROM dbo.ComboComponent AS c
                           WHERE c.combo_product_id = @product_id
                             AND NOT EXISTS (SELECT 1 FROM dbo.ProductBom AS b
                                             WHERE b.product_id = c.child_product_id))
                THROW 51003, N'sp_update_product_status：套餐存在没有 BOM 的子项，不能上架。', 1;
        END;

        UPDATE dbo.Product
        SET [status] = @status
        WHERE product_id = @product_id;

        IF @owns_tran = 1
            COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @owns_tran = 1 AND XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        ELSE IF @owns_tran = 0 AND XACT_STATE() = 1
            ROLLBACK TRANSACTION sp_update_product_status;
        THROW;
    END CATCH;
END
GO


-- 8/18 单品 BOM（整体替换：@bom_json 是 [{"ingredient_id":1,"usage_qty":0.5}]，[] 表示清空）
CREATE PROCEDURE dbo.sp_set_product_bom
    @product_id BIGINT,
    @bom_json   NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    IF @product_id IS NULL OR @bom_json IS NULL
        THROW 51000, N'sp_set_product_bom：@product_id 与 @bom_json 都不能为 NULL；清空请传 []。', 1;

    IF LEFT(LTRIM(@bom_json), 1) <> N'[' OR ISJSON(@bom_json) <> 1
        THROW 51000, N'sp_set_product_bom：@bom_json 必须是合法 JSON 数组，形如 [{"ingredient_id":1,"usage_qty":0.5}]。', 1;

    DECLARE @employee_id BIGINT;

    SELECT @employee_id = ea.employee_id
    FROM dbo.EmployeeAccount AS ea
    WHERE ea.database_user_name = USER_NAME()
      AND ea.status = 'ACTIVE';

    IF @employee_id IS NULL
        THROW 51004, N'sp_set_product_bom：当前登录主体未映射到启用员工，拒绝执行。', 1;

    DECLARE @owns_tran BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;

    IF @owns_tran = 1
        BEGIN TRANSACTION;
    ELSE
        SAVE TRANSACTION sp_set_product_bom;

    BEGIN TRY
        DECLARE @product_type VARCHAR(20);
        DECLARE @product_status VARCHAR(20);

        SELECT @product_type   = p.product_type,
               @product_status = p.[status]
        FROM dbo.Product AS p WITH (UPDLOCK, HOLDLOCK)
        WHERE p.product_id = @product_id;

        IF @product_type IS NULL
            THROW 51001, N'sp_set_product_bom：商品不存在。', 1;
        IF @product_status <> 'ACTIVE'
            THROW 51002, N'sp_set_product_bom：商品已停用，不能再改配方。', 1;
        IF @product_type <> 'SINGLE'
            THROW 51003, N'sp_set_product_bom：只有 SINGLE 单品能配 BOM，套餐请用 sp_set_combo_component。', 1;

        DECLARE @bom TABLE (ingredient_id BIGINT, usage_qty DECIMAL(12,3));

        INSERT INTO @bom (ingredient_id, usage_qty)
        SELECT j.ingredient_id, j.usage_qty
        FROM OPENJSON(@bom_json)
             WITH (ingredient_id BIGINT        '$.ingredient_id',
                   usage_qty     DECIMAL(12,3) '$.usage_qty') AS j;

        IF EXISTS (SELECT 1 FROM @bom WHERE ingredient_id IS NULL OR usage_qty IS NULL)
            THROW 51000, N'sp_set_product_bom：数组每一项都必须带 ingredient_id 与 usage_qty。', 1;
        IF EXISTS (SELECT 1 FROM @bom WHERE usage_qty <= 0)
            THROW 51000, N'sp_set_product_bom：usage_qty 必须大于 0。', 1;
        -- 先查重再落库
        IF EXISTS (SELECT 1 FROM @bom GROUP BY ingredient_id HAVING COUNT(*) > 1)
            THROW 51005, N'sp_set_product_bom：同一份 JSON 里 ingredient_id 重复。', 1;
        IF EXISTS (SELECT 1 FROM @bom AS b
                   WHERE NOT EXISTS (SELECT 1 FROM dbo.Ingredient AS i
                                     WHERE i.ingredient_id = b.ingredient_id))
            THROW 51003, N'sp_set_product_bom：数组里有不存在的 ingredient_id。', 1;

        DECLARE @bom_before NVARCHAR(MAX) =
            (SELECT b.ingredient_id, b.usage_qty
             FROM dbo.ProductBom AS b
             WHERE b.product_id = @product_id
             ORDER BY b.ingredient_id
             FOR JSON PATH);

        DELETE FROM dbo.ProductBom WHERE product_id = @product_id;

        INSERT INTO dbo.ProductBom (product_id, ingredient_id, usage_qty)
        SELECT @product_id, b.ingredient_id, b.usage_qty
        FROM @bom AS b;

        DECLARE @detail_json NVARCHAR(MAX) =
            (SELECT @product_id                        AS product_id,
                    JSON_QUERY(ISNULL(@bom_before, N'[]')) AS bom_before,
                    JSON_QUERY(@bom_json)              AS bom_after
             FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC dbo.sp_write_audit_log
             @employee_id = @employee_id,
             @action_name = 'SET_PRODUCT_BOM',
             @entity_name = 'ProductBom',
             @entity_id   = @product_id,
             @detail_json = @detail_json;

        IF @owns_tran = 1
            COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @owns_tran = 1 AND XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        ELSE IF @owns_tran = 0 AND XACT_STATE() = 1
            ROLLBACK TRANSACTION sp_set_product_bom;
        THROW;
    END CATCH;
END
GO


-- 9/18 套餐组成（整体替换：@component_json 是 [{"child_product_id":3,"quantity":1}]）
CREATE PROCEDURE dbo.sp_set_combo_component
    @product_id     BIGINT,
    @component_json NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    IF @product_id IS NULL OR @component_json IS NULL
        THROW 51000, N'sp_set_combo_component：@product_id 与 @component_json 都不能为 NULL；清空请传 []。', 1;

    IF LEFT(LTRIM(@component_json), 1) <> N'[' OR ISJSON(@component_json) <> 1
        THROW 51000, N'sp_set_combo_component：@component_json 必须是合法 JSON 数组，形如 [{"child_product_id":3,"quantity":1}]。', 1;

    DECLARE @employee_id BIGINT;

    SELECT @employee_id = ea.employee_id
    FROM dbo.EmployeeAccount AS ea
    WHERE ea.database_user_name = USER_NAME()
      AND ea.status = 'ACTIVE';

    IF @employee_id IS NULL
        THROW 51004, N'sp_set_combo_component：当前登录主体未映射到启用员工，拒绝执行。', 1;

    DECLARE @owns_tran BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;

    IF @owns_tran = 1
        BEGIN TRANSACTION;
    ELSE
        SAVE TRANSACTION sp_set_combo_component;

    BEGIN TRY
        DECLARE @product_type VARCHAR(20);
        DECLARE @product_status VARCHAR(20);

        SELECT @product_type   = p.product_type,
               @product_status = p.[status]
        FROM dbo.Product AS p WITH (UPDLOCK, HOLDLOCK)
        WHERE p.product_id = @product_id;

        IF @product_type IS NULL
            THROW 51001, N'sp_set_combo_component：套餐商品不存在。', 1;
        IF @product_status <> 'ACTIVE'
            THROW 51002, N'sp_set_combo_component：套餐已停用，不能再改组成。', 1;
        IF @product_type <> 'COMBO'
            THROW 51003, N'sp_set_combo_component：父项必须是 COMBO 套餐，单品请用 sp_set_product_bom。', 1;

        DECLARE @cmp TABLE (child_product_id BIGINT, quantity INT);

        INSERT INTO @cmp (child_product_id, quantity)
        SELECT j.child_product_id, j.quantity
        FROM OPENJSON(@component_json)
             WITH (child_product_id BIGINT '$.child_product_id',
                   quantity         INT    '$.quantity') AS j;

        IF EXISTS (SELECT 1 FROM @cmp WHERE child_product_id IS NULL OR quantity IS NULL)
            THROW 51000, N'sp_set_combo_component：数组每一项都必须带 child_product_id 与 quantity。', 1;
        IF EXISTS (SELECT 1 FROM @cmp WHERE quantity <= 0)
            THROW 51000, N'sp_set_combo_component：quantity 必须大于 0。', 1;
        IF EXISTS (SELECT 1 FROM @cmp WHERE child_product_id = @product_id)
            THROW 51003, N'sp_set_combo_component：子项不能是套餐自身。', 1;
        IF EXISTS (SELECT 1 FROM @cmp GROUP BY child_product_id HAVING COUNT(*) > 1)
            THROW 51005, N'sp_set_combo_component：同一份 JSON 里 child_product_id 重复。', 1;
        IF EXISTS (SELECT 1 FROM @cmp AS c
                   WHERE NOT EXISTS (SELECT 1 FROM dbo.Product AS p
                                     WHERE p.product_id = c.child_product_id
                                       AND p.product_type = 'SINGLE'
                                       AND p.[status] = 'ACTIVE'))
            THROW 51003, N'sp_set_combo_component：子项必须存在、为 SINGLE 且在售；第一阶段不支持嵌套套餐。', 1;

        DECLARE @cmp_before NVARCHAR(MAX) =
            (SELECT c.child_product_id, c.quantity
             FROM dbo.ComboComponent AS c
             WHERE c.combo_product_id = @product_id
             ORDER BY c.child_product_id
             FOR JSON PATH);

        DELETE FROM dbo.ComboComponent WHERE combo_product_id = @product_id;

        INSERT INTO dbo.ComboComponent (combo_product_id, child_product_id, quantity)
        SELECT @product_id, c.child_product_id, c.quantity
        FROM @cmp AS c;

        DECLARE @detail_json NVARCHAR(MAX) =
            (SELECT @product_id                            AS combo_product_id,
                    JSON_QUERY(ISNULL(@cmp_before, N'[]')) AS component_before,
                    JSON_QUERY(@component_json)            AS component_after
             FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC dbo.sp_write_audit_log
             @employee_id = @employee_id,
             @action_name = 'SET_COMBO_COMPONENT',
             @entity_name = 'ComboComponent',
             @entity_id   = @product_id,
             @detail_json = @detail_json;

        IF @owns_tran = 1
            COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @owns_tran = 1 AND XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        ELSE IF @owns_tran = 0 AND XACT_STATE() = 1
            ROLLBACK TRANSACTION sp_set_combo_component;
        THROW;
    END CATCH;
END
GO


-- 10/18 促销活动
CREATE PROCEDURE dbo.sp_create_promotion
    @promotion_name NVARCHAR(50),
    @promotion_type VARCHAR(20),
    @start_at       DATETIME2(0),
    @end_at         DATETIME2(0)
AS
BEGIN
    SET NOCOUNT ON;

    IF @promotion_name IS NULL OR LTRIM(RTRIM(@promotion_name)) = N''
       OR @promotion_type IS NULL OR @promotion_type <> 'FIXED_PRICE'
       OR @start_at IS NULL OR @end_at IS NULL OR @end_at <= @start_at
        THROW 51000, N'sp_create_promotion：名称不能为空，@promotion_type 只能是 FIXED_PRICE，@end_at 必须晚于 @start_at。', 1;

    DECLARE @employee_id BIGINT;

    SELECT @employee_id = ea.employee_id
    FROM dbo.EmployeeAccount AS ea
    WHERE ea.database_user_name = USER_NAME()
      AND ea.status = 'ACTIVE';

    IF @employee_id IS NULL
        THROW 51004, N'sp_create_promotion：当前登录主体未映射到启用员工，拒绝执行。', 1;

    DECLARE @owns_tran BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;

    IF @owns_tran = 1
        BEGIN TRANSACTION;
    ELSE
        SAVE TRANSACTION sp_create_promotion;

    BEGIN TRY
        DECLARE @promotion_id BIGINT;
        INSERT INTO dbo.Promotion (promotion_name, promotion_type, start_at, end_at, [status])
        VALUES (LTRIM(RTRIM(@promotion_name)), @promotion_type, @start_at, @end_at, 'INACTIVE');

        SET @promotion_id = SCOPE_IDENTITY();

        DECLARE @detail_json NVARCHAR(MAX) =
            (SELECT @promotion_id        AS promotion_id,
                    LTRIM(RTRIM(@promotion_name)) AS promotion_name,
                    @promotion_type      AS promotion_type,
                    CONVERT(VARCHAR(19), @start_at, 120) AS start_at,
                    CONVERT(VARCHAR(19), @end_at,   120) AS end_at,
                    'INACTIVE'           AS [status]
             FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC dbo.sp_write_audit_log
             @employee_id = @employee_id,
             @action_name = 'CREATE_PROMOTION',
             @entity_name = 'Promotion',
             @entity_id   = @promotion_id,
             @detail_json = @detail_json;

        IF @owns_tran = 1
            COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @owns_tran = 1 AND XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        ELSE IF @owns_tran = 0 AND XACT_STATE() = 1
            ROLLBACK TRANSACTION sp_create_promotion;
        THROW;
    END CATCH;
END
GO


-- 11/18 促销上线 / 下线
CREATE PROCEDURE dbo.sp_update_promotion_status
    @promotion_id BIGINT,
    @status       VARCHAR(20)
AS
BEGIN
    SET NOCOUNT ON;

    IF @promotion_id IS NULL OR @status IS NULL OR @status NOT IN ('ACTIVE', 'INACTIVE')
        THROW 51000, N'sp_update_promotion_status：@promotion_id 不能为 NULL，@status 只能是 ACTIVE 或 INACTIVE。', 1;

    DECLARE @employee_id BIGINT;

    SELECT @employee_id = ea.employee_id
    FROM dbo.EmployeeAccount AS ea
    WHERE ea.database_user_name = USER_NAME()
      AND ea.status = 'ACTIVE';

    IF @employee_id IS NULL
        THROW 51004, N'sp_update_promotion_status：当前登录主体未映射到启用员工，拒绝执行。', 1;

    DECLARE @owns_tran BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;

    IF @owns_tran = 1
        BEGIN TRANSACTION;
    ELSE
        SAVE TRANSACTION sp_update_promotion_status;

    BEGIN TRY
        DECLARE @status_before VARCHAR(20);

        SELECT @status_before = pr.[status]
        FROM dbo.Promotion AS pr WITH (UPDLOCK, HOLDLOCK)
        WHERE pr.promotion_id = @promotion_id;

        IF @status_before IS NULL
            THROW 51001, N'sp_update_promotion_status：促销活动不存在。', 1;

        UPDATE dbo.Promotion
        SET [status] = @status
        WHERE promotion_id = @promotion_id;

        DECLARE @detail_json NVARCHAR(MAX) =
            (SELECT @promotion_id   AS promotion_id,
                    @status_before  AS status_before,
                    @status         AS status_after
             FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC dbo.sp_write_audit_log
             @employee_id = @employee_id,
             @action_name = 'UPDATE_PROMOTION_STATUS',
             @entity_name = 'Promotion',
             @entity_id   = @promotion_id,
             @detail_json = @detail_json;

        IF @owns_tran = 1
            COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @owns_tran = 1 AND XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        ELSE IF @owns_tran = 0 AND XACT_STATE() = 1
            ROLLBACK TRANSACTION sp_update_promotion_status;
        THROW;
    END CATCH;
END
GO


-- 12/18 新增促销规则
CREATE PROCEDURE dbo.sp_add_promotion_product_rule
    @promotion_id BIGINT,
    @product_id   BIGINT,
    @weekday_no   INT,
    @start_time   TIME(0),
    @end_time     TIME(0),
    @promo_price  DECIMAL(10,2),
    @priority     INT
AS
BEGIN
    SET NOCOUNT ON;

    IF @promotion_id IS NULL OR @product_id IS NULL OR @weekday_no IS NULL
       OR @start_time IS NULL OR @end_time IS NULL
       OR @promo_price IS NULL OR @promo_price <= 0
       OR @priority IS NULL OR @priority < 0
        THROW 51000, N'sp_add_promotion_product_rule：@promo_price 必须大于 0，@priority 不能为负，且各参数不能为 NULL。', 1;
    IF @weekday_no NOT BETWEEN 1 AND 7
        THROW 51000, N'sp_add_promotion_product_rule：@weekday_no 只能是 1~7（1 = 周一）。', 1;
    IF @end_time <= @start_time
        THROW 51000, N'sp_add_promotion_product_rule：@end_time 必须晚于 @start_time。', 1;

    DECLARE @employee_id BIGINT;

    SELECT @employee_id = ea.employee_id
    FROM dbo.EmployeeAccount AS ea
    WHERE ea.database_user_name = USER_NAME()
      AND ea.status = 'ACTIVE';

    IF @employee_id IS NULL
        THROW 51004, N'sp_add_promotion_product_rule：当前登录主体未映射到启用员工，拒绝执行。', 1;

    DECLARE @owns_tran BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;

    IF @owns_tran = 1
        BEGIN TRANSACTION;
    ELSE
        SAVE TRANSACTION sp_add_promotion_product_rule;

    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.Promotion AS pr WHERE pr.promotion_id = @promotion_id)
            THROW 51003, N'sp_add_promotion_product_rule：促销活动不存在。', 1;
        IF NOT EXISTS (SELECT 1 FROM dbo.Product AS p WHERE p.product_id = @product_id)
            THROW 51003, N'sp_add_promotion_product_rule：商品不存在。', 1;

        DECLARE @promotion_rule_id BIGINT;

        INSERT INTO dbo.PromotionProductRule
            (promotion_id, product_id, weekday_no, start_time, end_time, promo_price, [priority])
        VALUES
            (@promotion_id, @product_id, @weekday_no, @start_time, @end_time, @promo_price, @priority);

        SET @promotion_rule_id = SCOPE_IDENTITY();

        DECLARE @detail_json NVARCHAR(MAX) =
            (SELECT @promotion_rule_id AS promotion_rule_id,
                    @promotion_id      AS promotion_id,
                    @product_id        AS product_id,
                    @weekday_no        AS weekday_no,
                    CONVERT(VARCHAR(8), @start_time, 108) AS start_time,
                    CONVERT(VARCHAR(8), @end_time,   108) AS end_time,
                    @promo_price       AS promo_price,
                    @priority          AS [priority]
             FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC dbo.sp_write_audit_log
             @employee_id = @employee_id,
             @action_name = 'ADD_PROMOTION_RULE',
             @entity_name = 'PromotionProductRule',
             @entity_id   = @promotion_rule_id,
             @detail_json = @detail_json;

        IF @owns_tran = 1
            COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @owns_tran = 1 AND XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        ELSE IF @owns_tran = 0 AND XACT_STATE() = 1
            ROLLBACK TRANSACTION sp_add_promotion_product_rule;
        THROW;
    END CATCH;
END
GO


-- 13/18 修改促销规则（只改星期/时段/一口价/优先级）
CREATE PROCEDURE dbo.sp_update_promotion_product_rule
    @promotion_rule_id BIGINT,
    @weekday_no        INT,
    @start_time        TIME(0),
    @end_time          TIME(0),
    @promo_price       DECIMAL(10,2),
    @priority          INT
AS
BEGIN
    SET NOCOUNT ON;

    IF @promotion_rule_id IS NULL OR @weekday_no IS NULL
       OR @start_time IS NULL OR @end_time IS NULL
       OR @promo_price IS NULL OR @promo_price <= 0
       OR @priority IS NULL OR @priority < 0
        THROW 51000, N'sp_update_promotion_product_rule：@promo_price 必须大于 0，@priority 不能为负，且各参数不能为 NULL。', 1;
    IF @weekday_no NOT BETWEEN 1 AND 7
        THROW 51000, N'sp_update_promotion_product_rule：@weekday_no 只能是 1~7（1 = 周一）。', 1;
    IF @end_time <= @start_time
        THROW 51000, N'sp_update_promotion_product_rule：@end_time 必须晚于 @start_time。', 1;

    DECLARE @employee_id BIGINT;

    SELECT @employee_id = ea.employee_id
    FROM dbo.EmployeeAccount AS ea
    WHERE ea.database_user_name = USER_NAME()
      AND ea.status = 'ACTIVE';

    IF @employee_id IS NULL
        THROW 51004, N'sp_update_promotion_product_rule：当前登录主体未映射到启用员工，拒绝执行。', 1;

    DECLARE @owns_tran BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;

    IF @owns_tran = 1
        BEGIN TRANSACTION;
    ELSE
        SAVE TRANSACTION sp_update_promotion_product_rule;

    BEGIN TRY
        DECLARE @promo_price_before DECIMAL(10,2),
                @priority_before    INT;

        SELECT @promo_price_before = r.promo_price,
               @priority_before    = r.[priority]
        FROM dbo.PromotionProductRule AS r WITH (UPDLOCK, HOLDLOCK)
        WHERE r.promotion_rule_id = @promotion_rule_id;

        IF @promo_price_before IS NULL
            THROW 51001, N'sp_update_promotion_product_rule：促销规则不存在。', 1;

        UPDATE dbo.PromotionProductRule
        SET weekday_no  = @weekday_no,
            start_time  = @start_time,
            end_time    = @end_time,
            promo_price = @promo_price,
            [priority]  = @priority
        WHERE promotion_rule_id = @promotion_rule_id;

        DECLARE @detail_json NVARCHAR(MAX) =
            (SELECT @promotion_rule_id  AS promotion_rule_id,
                    @weekday_no         AS weekday_no,
                    CONVERT(VARCHAR(8), @start_time, 108) AS start_time,
                    CONVERT(VARCHAR(8), @end_time,   108) AS end_time,
                    @promo_price_before AS promo_price_before,
                    @promo_price        AS promo_price_after,
                    @priority_before    AS priority_before,
                    @priority           AS priority_after
             FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC dbo.sp_write_audit_log
             @employee_id = @employee_id,
             @action_name = 'UPDATE_PROMOTION_RULE',
             @entity_name = 'PromotionProductRule',
             @entity_id   = @promotion_rule_id,
             @detail_json = @detail_json;

        IF @owns_tran = 1
            COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @owns_tran = 1 AND XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        ELSE IF @owns_tran = 0 AND XACT_STATE() = 1
            ROLLBACK TRANSACTION sp_update_promotion_product_rule;
        THROW;
    END CATCH;
END
GO


-- 14/18 会员等级
CREATE PROCEDURE dbo.sp_create_member_level
    @level_name       NVARCHAR(50),
    @point_multiplier DECIMAL(5,2),
    @threshold_points INT
AS
BEGIN
    SET NOCOUNT ON;

    IF @level_name IS NULL OR LTRIM(RTRIM(@level_name)) = N''
       OR @point_multiplier IS NULL OR @point_multiplier <= 0
       OR @threshold_points IS NULL OR @threshold_points < 0
        THROW 51000, N'sp_create_member_level：等级名不能为空，@point_multiplier 必须大于 0，@threshold_points 不能为 NULL 或负数。', 1;

    DECLARE @employee_id BIGINT;

    SELECT @employee_id = ea.employee_id
    FROM dbo.EmployeeAccount AS ea
    WHERE ea.database_user_name = USER_NAME()
      AND ea.status = 'ACTIVE';

    IF @employee_id IS NULL
        THROW 51004, N'sp_create_member_level：当前登录主体未映射到启用员工，拒绝执行。', 1;

    DECLARE @owns_tran BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;

    IF @owns_tran = 1
        BEGIN TRANSACTION;
    ELSE
        SAVE TRANSACTION sp_create_member_level;

    BEGIN TRY
        IF EXISTS (SELECT 1 FROM dbo.MemberLevel AS ml WITH (UPDLOCK, HOLDLOCK)
                   WHERE ml.threshold_points = @threshold_points)
            THROW 51005, N'sp_create_member_level：已存在相同 threshold_points 的等级。', 1;

        DECLARE @member_level_id BIGINT;

        INSERT INTO dbo.MemberLevel (level_name, point_multiplier, threshold_points, [status])
        VALUES (LTRIM(RTRIM(@level_name)), @point_multiplier, @threshold_points, 'ACTIVE');

        SET @member_level_id = SCOPE_IDENTITY();

        DECLARE @detail_json NVARCHAR(MAX) =
            (SELECT @member_level_id     AS member_level_id,
                    LTRIM(RTRIM(@level_name)) AS level_name,
                    @point_multiplier    AS point_multiplier,
                    @threshold_points    AS threshold_points,
                    'ACTIVE'             AS [status]
             FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC dbo.sp_write_audit_log
             @employee_id = @employee_id,
             @action_name = 'CREATE_MEMBER_LEVEL',
             @entity_name = 'MemberLevel',
             @entity_id   = @member_level_id,
             @detail_json = @detail_json;

        IF @owns_tran = 1
            COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @owns_tran = 1 AND XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        ELSE IF @owns_tran = 0 AND XACT_STATE() = 1
            ROLLBACK TRANSACTION sp_create_member_level;
        THROW;
    END CATCH;
END
GO


-- 15/18 修改会员等级
CREATE PROCEDURE dbo.sp_update_member_level
    @member_level_id  BIGINT,
    @level_name       NVARCHAR(50),
    @point_multiplier DECIMAL(5,2),
    @threshold_points INT
AS
BEGIN
    SET NOCOUNT ON;

    IF @member_level_id IS NULL
       OR @level_name IS NULL OR LTRIM(RTRIM(@level_name)) = N''
       OR @point_multiplier IS NULL OR @point_multiplier <= 0
       OR @threshold_points IS NULL OR @threshold_points < 0
        THROW 51000, N'sp_update_member_level：@member_level_id 不能为 NULL，等级名不能为空，@point_multiplier 必须大于 0，@threshold_points 不能为负。', 1;

    DECLARE @employee_id BIGINT;

    SELECT @employee_id = ea.employee_id
    FROM dbo.EmployeeAccount AS ea
    WHERE ea.database_user_name = USER_NAME()
      AND ea.status = 'ACTIVE';

    IF @employee_id IS NULL
        THROW 51004, N'sp_update_member_level：当前登录主体未映射到启用员工，拒绝执行。', 1;

    DECLARE @owns_tran BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;

    IF @owns_tran = 1
        BEGIN TRANSACTION;
    ELSE
        SAVE TRANSACTION sp_update_member_level;

    BEGIN TRY
        DECLARE @threshold_before INT;

        SELECT @threshold_before = ml.threshold_points
        FROM dbo.MemberLevel AS ml WITH (UPDLOCK, HOLDLOCK)
        WHERE ml.member_level_id = @member_level_id;

        IF @threshold_before IS NULL
            THROW 51001, N'sp_update_member_level：会员等级不存在。', 1;

        IF EXISTS (SELECT 1 FROM dbo.MemberLevel AS ml WITH (UPDLOCK, HOLDLOCK)
                   WHERE ml.threshold_points = @threshold_points
                     AND ml.member_level_id <> @member_level_id)
            THROW 51005, N'sp_update_member_level：已存在相同 threshold_points 的其他等级。', 1;

        UPDATE dbo.MemberLevel
        SET level_name       = LTRIM(RTRIM(@level_name)),
            point_multiplier = @point_multiplier,
            threshold_points = @threshold_points
        WHERE member_level_id = @member_level_id;

        DECLARE @detail_json NVARCHAR(MAX) =
            (SELECT @member_level_id  AS member_level_id,
                    LTRIM(RTRIM(@level_name)) AS level_name,
                    @point_multiplier AS point_multiplier,
                    @threshold_before  AS threshold_points_before,
                    @threshold_points  AS threshold_points_after
             FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC dbo.sp_write_audit_log
             @employee_id = @employee_id,
             @action_name = 'UPDATE_MEMBER_LEVEL',
             @entity_name = 'MemberLevel',
             @entity_id   = @member_level_id,
             @detail_json = @detail_json;

        IF @owns_tran = 1
            COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @owns_tran = 1 AND XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        ELSE IF @owns_tran = 0 AND XACT_STATE() = 1
            ROLLBACK TRANSACTION sp_update_member_level;
        THROW;
    END CATCH;
END
GO


-- 16/18 会员等级状态
CREATE PROCEDURE dbo.sp_update_member_level_status
    @member_level_id BIGINT,
    @status          VARCHAR(20)
AS
BEGIN
    SET NOCOUNT ON;

    IF @member_level_id IS NULL OR @status IS NULL OR @status NOT IN ('ACTIVE', 'INACTIVE')
        THROW 51000, N'sp_update_member_level_status：@member_level_id 不能为 NULL，@status 只能是 ACTIVE 或 INACTIVE。', 1;

    DECLARE @employee_id BIGINT;

    SELECT @employee_id = ea.employee_id
    FROM dbo.EmployeeAccount AS ea
    WHERE ea.database_user_name = USER_NAME()
      AND ea.status = 'ACTIVE';

    IF @employee_id IS NULL
        THROW 51004, N'sp_update_member_level_status：当前登录主体未映射到启用员工，拒绝执行。', 1;

    DECLARE @owns_tran BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;

    IF @owns_tran = 1
        BEGIN TRANSACTION;
    ELSE
        SAVE TRANSACTION sp_update_member_level_status;

    BEGIN TRY
        DECLARE @status_before VARCHAR(20);

        SELECT @status_before = ml.[status]
        FROM dbo.MemberLevel AS ml WITH (UPDLOCK, HOLDLOCK)
        WHERE ml.member_level_id = @member_level_id;

        IF @status_before IS NULL
            THROW 51001, N'sp_update_member_level_status：会员等级不存在。', 1;

        UPDATE dbo.MemberLevel
        SET [status] = @status
        WHERE member_level_id = @member_level_id;

        DECLARE @customers_cleared INT = 0;

        IF @status = 'INACTIVE'
        BEGIN
            UPDATE dbo.Customer
            SET member_level_id = NULL
            WHERE member_level_id = @member_level_id;

            SET @customers_cleared = @@ROWCOUNT;
        END;

        DECLARE @detail_json NVARCHAR(MAX) =
            (SELECT @member_level_id  AS member_level_id,
                    @status_before    AS status_before,
                    @status           AS status_after,
                    @customers_cleared AS customers_cleared
             FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC dbo.sp_write_audit_log
             @employee_id = @employee_id,
             @action_name = 'UPDATE_MEMBER_LEVEL_STATUS',
             @entity_name = 'MemberLevel',
             @entity_id   = @member_level_id,
             @detail_json = @detail_json;

        IF @owns_tran = 1
            COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @owns_tran = 1 AND XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        ELSE IF @owns_tran = 0 AND XACT_STATE() = 1
            ROLLBACK TRANSACTION sp_update_member_level_status;
        THROW;
    END CATCH;
END
GO


-- 17/18 顾客建档
CREATE PROCEDURE dbo.sp_create_customer
    @mobile        VARCHAR(20),
    @customer_type VARCHAR(20)
AS
BEGIN
    SET NOCOUNT ON;

    IF @mobile IS NULL OR LTRIM(RTRIM(@mobile)) = ''
       OR @customer_type IS NULL OR @customer_type NOT IN ('GUEST', 'WOW', 'PAID')
        THROW 51000, N'sp_create_customer：@mobile 不能为空，@customer_type 只能是 GUEST、WOW 或 PAID。', 1;

    DECLARE @employee_id BIGINT;

    SELECT @employee_id = ea.employee_id
    FROM dbo.EmployeeAccount AS ea
    WHERE ea.database_user_name = USER_NAME()
      AND ea.status = 'ACTIVE';

    IF @employee_id IS NULL
        THROW 51004, N'sp_create_customer：当前登录主体未映射到启用员工，拒绝执行。', 1;

    DECLARE @owns_tran BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;

    IF @owns_tran = 1
        BEGIN TRANSACTION;
    ELSE
        SAVE TRANSACTION sp_create_customer;

    BEGIN TRY
        IF EXISTS (SELECT 1 FROM dbo.Customer AS c WITH (UPDLOCK, HOLDLOCK)
                   WHERE c.mobile = LTRIM(RTRIM(@mobile)))
            THROW 51005, N'sp_create_customer：该手机号已建档。', 1;

        INSERT INTO dbo.Customer (mobile, customer_type, member_level_id, current_points, [status])
        VALUES (LTRIM(RTRIM(@mobile)), @customer_type, NULL, 0, 'ACTIVE');

        IF @owns_tran = 1
            COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @owns_tran = 1 AND XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        ELSE IF @owns_tran = 0 AND XACT_STATE() = 1
            ROLLBACK TRANSACTION sp_create_customer;
        THROW;
    END CATCH;
END
GO


-- 18/18 手工指定顾客等级（@member_level_id 传 NULL 表示清空）
CREATE PROCEDURE dbo.sp_update_customer_member_level
    @customer_id     BIGINT,
    @member_level_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    IF @customer_id IS NULL
        THROW 51000, N'sp_update_customer_member_level：@customer_id 不能为 NULL。', 1;

    DECLARE @employee_id BIGINT;

    SELECT @employee_id = ea.employee_id
    FROM dbo.EmployeeAccount AS ea
    WHERE ea.database_user_name = USER_NAME()
      AND ea.status = 'ACTIVE';

    IF @employee_id IS NULL
        THROW 51004, N'sp_update_customer_member_level：当前登录主体未映射到启用员工，拒绝执行。', 1;

    DECLARE @owns_tran BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;

    IF @owns_tran = 1
        BEGIN TRANSACTION;
    ELSE
        SAVE TRANSACTION sp_update_customer_member_level;

    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.Customer AS c WHERE c.customer_id = @customer_id)
            THROW 51001, N'sp_update_customer_member_level：顾客不存在。', 1;

        IF @member_level_id IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM dbo.MemberLevel AS ml
                           WHERE ml.member_level_id = @member_level_id
                             AND ml.[status] = 'ACTIVE')
            THROW 51003, N'sp_update_customer_member_level：@member_level_id 不存在或已停用。', 1;

        UPDATE dbo.Customer
        SET member_level_id = @member_level_id
        WHERE customer_id = @customer_id;

        IF @owns_tran = 1
            COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @owns_tran = 1 AND XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        ELSE IF @owns_tran = 0 AND XACT_STATE() = 1
            ROLLBACK TRANSACTION sp_update_customer_member_level;
        THROW;
    END CATCH;
END
GO

