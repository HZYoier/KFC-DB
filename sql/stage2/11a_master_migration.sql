-- ============================================================================
-- 11a_master_migration.sql — A 域 v0.1 -> v1.0 迁移（成员 A；2026-11-01）
-- 由 run_migration.sql 在外层事务内 :r 执行：不得 BEGIN/COMMIT/ROLLBACK 外层事务，
-- 不得切连接；失败由入口回滚外层并 THROW。
-- 落实：a-normalization.md §5 第 1–5 项 —— 五个候选码补声明（UQ_*）。
-- 依据：docs/stage2/a-normalization.md §5、refactoring-design.md §7、
--       migration-guide.md §3（脚本形状与错误码段 533xx）。
-- 不在本文件：契约 §1 的顾客端 sp_customer_register —— §1 尚未冻结，冻结后再补，
--       免得签名一变又要改迁移脚本。
-- ============================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

-- ---------------------------------------------------------------------------
-- 1. 前置校验（v0.1 形状 + 重复值；有重复就报出业务键，不静默留一行）
-- ---------------------------------------------------------------------------
SET NOCOUNT ON;
SET XACT_ABORT ON;
DECLARE @msg NVARCHAR(400);

IF OBJECT_ID(N'dbo.Category', N'U') IS NULL OR OBJECT_ID(N'dbo.MemberLevel', N'U') IS NULL
   OR OBJECT_ID(N'dbo.Ingredient', N'U') IS NULL OR OBJECT_ID(N'dbo.Product', N'U') IS NULL
    THROW 53300, N'11a: v0.1 A-domain tables are missing.', 1;

-- 11a 只在 v0.1 上跑一次：五个约束都还没有
IF EXISTS (SELECT 1 FROM sys.key_constraints
           WHERE name IN (N'UQ_MemberLevel_threshold_points', N'UQ_Category_category_name',
                          N'UQ_Product_product_name', N'UQ_Ingredient_name_unit',
                          N'UQ_MemberLevel_level_name'))
    THROW 53301, N'11a: candidate-key constraints already exist; 11a must run once on v0.1.', 1;

IF EXISTS (SELECT 1 FROM dbo.Category GROUP BY category_name HAVING COUNT(*) > 1)
BEGIN
    SET @msg = N'11a: duplicate Category.category_name: '
             + ISNULL((SELECT STRING_AGG(CONVERT(NVARCHAR(MAX), category_name), N',')
                              WITHIN GROUP (ORDER BY category_name)
                       FROM (SELECT category_name FROM dbo.Category
                             GROUP BY category_name HAVING COUNT(*) > 1) x), N'');
    THROW 53302, @msg, 1;
END;
IF EXISTS (SELECT 1 FROM dbo.Product GROUP BY product_name HAVING COUNT(*) > 1)
BEGIN
    SET @msg = N'11a: duplicate Product.product_name: '
             + ISNULL((SELECT STRING_AGG(CONVERT(NVARCHAR(MAX), product_name), N',')
                              WITHIN GROUP (ORDER BY product_name)
                       FROM (SELECT product_name FROM dbo.Product
                             GROUP BY product_name HAVING COUNT(*) > 1) x), N'');
    THROW 53303, @msg, 1;
END;
IF EXISTS (SELECT 1 FROM dbo.Ingredient GROUP BY ingredient_name, unit_name HAVING COUNT(*) > 1)
BEGIN
    SET @msg = N'11a: duplicate Ingredient (ingredient_name, unit_name): '
             + ISNULL((SELECT STRING_AGG(CONVERT(NVARCHAR(MAX), ingredient_name + N'|' + unit_name), N',')
                              WITHIN GROUP (ORDER BY ingredient_name, unit_name)
                       FROM (SELECT ingredient_name, unit_name FROM dbo.Ingredient
                             GROUP BY ingredient_name, unit_name HAVING COUNT(*) > 1) x), N'');
    THROW 53304, @msg, 1;
END;
IF EXISTS (SELECT 1 FROM dbo.MemberLevel GROUP BY threshold_points HAVING COUNT(*) > 1)
BEGIN
    SET @msg = N'11a: duplicate MemberLevel.threshold_points: '
             + ISNULL((SELECT STRING_AGG(CONVERT(NVARCHAR(MAX), threshold_points), N',')
                              WITHIN GROUP (ORDER BY threshold_points)
                       FROM (SELECT threshold_points FROM dbo.MemberLevel
                             GROUP BY threshold_points HAVING COUNT(*) > 1) x), N'');
    THROW 53305, @msg, 1;
END;
IF EXISTS (SELECT 1 FROM dbo.MemberLevel GROUP BY level_name HAVING COUNT(*) > 1)
BEGIN
    SET @msg = N'11a: duplicate MemberLevel.level_name: '
             + ISNULL((SELECT STRING_AGG(CONVERT(NVARCHAR(MAX), level_name), N',')
                              WITHIN GROUP (ORDER BY level_name)
                       FROM (SELECT level_name FROM dbo.MemberLevel
                             GROUP BY level_name HAVING COUNT(*) > 1) x), N'');
    THROW 53306, @msg, 1;
END;
GO

-- ---------------------------------------------------------------------------
-- 2. 补五个候选码（a-normalization §5 第 1–5 项）
-- ---------------------------------------------------------------------------
SET NOCOUNT ON;
SET XACT_ABORT ON;

ALTER TABLE dbo.MemberLevel
    ADD CONSTRAINT UQ_MemberLevel_threshold_points UNIQUE (threshold_points);

ALTER TABLE dbo.Category
    ADD CONSTRAINT UQ_Category_category_name UNIQUE (category_name);

ALTER TABLE dbo.Product
    ADD CONSTRAINT UQ_Product_product_name UNIQUE (product_name);

ALTER TABLE dbo.Ingredient
    ADD CONSTRAINT UQ_Ingredient_name_unit UNIQUE (ingredient_name, unit_name);

ALTER TABLE dbo.MemberLevel
    ADD CONSTRAINT UQ_MemberLevel_level_name UNIQUE (level_name);
GO

-- ---------------------------------------------------------------------------
-- 3. 迁移内终态校验（只读；失败由入口回滚）
-- ---------------------------------------------------------------------------
SET NOCOUNT ON;
SET XACT_ABORT ON;

IF NOT EXISTS (SELECT 1 FROM sys.key_constraints
               WHERE name = N'UQ_MemberLevel_threshold_points' AND type = N'UQ'
                 AND parent_object_id = OBJECT_ID(N'dbo.MemberLevel'))
    THROW 53310, N'11a: UQ_MemberLevel_threshold_points was not created.', 1;
IF NOT EXISTS (SELECT 1 FROM sys.key_constraints
               WHERE name = N'UQ_Category_category_name' AND type = N'UQ'
                 AND parent_object_id = OBJECT_ID(N'dbo.Category'))
    THROW 53311, N'11a: UQ_Category_category_name was not created.', 1;
IF NOT EXISTS (SELECT 1 FROM sys.key_constraints
               WHERE name = N'UQ_Product_product_name' AND type = N'UQ'
                 AND parent_object_id = OBJECT_ID(N'dbo.Product'))
    THROW 53312, N'11a: UQ_Product_product_name was not created.', 1;
IF NOT EXISTS (SELECT 1 FROM sys.key_constraints
               WHERE name = N'UQ_Ingredient_name_unit' AND type = N'UQ'
                 AND parent_object_id = OBJECT_ID(N'dbo.Ingredient'))
    THROW 53313, N'11a: UQ_Ingredient_name_unit was not created.', 1;
IF NOT EXISTS (SELECT 1 FROM sys.key_constraints
               WHERE name = N'UQ_MemberLevel_level_name' AND type = N'UQ'
                 AND parent_object_id = OBJECT_ID(N'dbo.MemberLevel'))
    THROW 53314, N'11a: UQ_MemberLevel_level_name was not created.', 1;

-- 列契约：名字对了但列绑错一样算没落对
IF NOT EXISTS (SELECT 1 FROM sys.index_columns ic
               JOIN sys.key_constraints kc ON kc.parent_object_id = ic.object_id AND kc.unique_index_id = ic.index_id
               JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
               WHERE kc.name = N'UQ_Ingredient_name_unit'
                 AND c.name IN (N'ingredient_name', N'unit_name'))
    THROW 53315, N'11a: UQ_Ingredient_name_unit does not cover both columns.', 1;
IF (SELECT COUNT(*) FROM sys.index_columns ic
    JOIN sys.key_constraints kc ON kc.parent_object_id = ic.object_id AND kc.unique_index_id = ic.index_id
    WHERE kc.name = N'UQ_Ingredient_name_unit') <> 2
    THROW 53316, N'11a: UQ_Ingredient_name_unit must have exactly two key columns.', 1;
GO
