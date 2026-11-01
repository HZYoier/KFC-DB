-- A baseline snapshot, protocol migration-guide.md 2.5 / 3 (2026-11-01).
-- Called inside capture_baseline.sql's transaction, with @batch_id declared there.
-- No GO, transaction control, connection switch or business-table writes here.
-- All 47 source fields are preserved; snapshot keys include batch_id.

IF OBJECT_ID(N'dbo.Baseline_Category', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.Baseline_Category (
        batch_id BIGINT NOT NULL,
        [category_id] BIGINT NOT NULL,
        [category_name] NVARCHAR(50) NOT NULL,
        [status] VARCHAR(20) NOT NULL,
        CONSTRAINT PK_Baseline_Category PRIMARY KEY (batch_id, [category_id])
    );
END;
DENY SELECT, INSERT, UPDATE, DELETE ON OBJECT::dbo.Baseline_Category TO public;

IF OBJECT_ID(N'dbo.Baseline_MemberLevel', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.Baseline_MemberLevel (
        batch_id BIGINT NOT NULL,
        [member_level_id] BIGINT NOT NULL,
        [level_name] NVARCHAR(50) NOT NULL,
        [point_multiplier] DECIMAL(5,2) NOT NULL,
        [threshold_points] INT NOT NULL,
        [status] VARCHAR(20) NOT NULL,
        CONSTRAINT PK_Baseline_MemberLevel PRIMARY KEY (batch_id, [member_level_id])
    );
END;
DENY SELECT, INSERT, UPDATE, DELETE ON OBJECT::dbo.Baseline_MemberLevel TO public;

IF OBJECT_ID(N'dbo.Baseline_Ingredient', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.Baseline_Ingredient (
        batch_id BIGINT NOT NULL,
        [ingredient_id] BIGINT NOT NULL,
        [ingredient_name] NVARCHAR(50) NOT NULL,
        [unit_name] NVARCHAR(50) NOT NULL,
        [safety_stock_qty] DECIMAL(12,3) NOT NULL,
        [status] VARCHAR(20) NOT NULL,
        CONSTRAINT PK_Baseline_Ingredient PRIMARY KEY (batch_id, [ingredient_id])
    );
END;
DENY SELECT, INSERT, UPDATE, DELETE ON OBJECT::dbo.Baseline_Ingredient TO public;

IF OBJECT_ID(N'dbo.Baseline_Product', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.Baseline_Product (
        batch_id BIGINT NOT NULL,
        [product_id] BIGINT NOT NULL,
        [product_name] NVARCHAR(50) NOT NULL,
        [base_price] DECIMAL(10,2) NOT NULL,
        [product_type] VARCHAR(20) NOT NULL,
        [status] VARCHAR(20) NOT NULL,
        CONSTRAINT PK_Baseline_Product PRIMARY KEY (batch_id, [product_id])
    );
END;
DENY SELECT, INSERT, UPDATE, DELETE ON OBJECT::dbo.Baseline_Product TO public;

IF OBJECT_ID(N'dbo.Baseline_ProductCategory', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.Baseline_ProductCategory (
        batch_id BIGINT NOT NULL,
        [product_id] BIGINT NOT NULL,
        [category_id] BIGINT NOT NULL,
        [is_primary] BIT NOT NULL,
        CONSTRAINT PK_Baseline_ProductCategory PRIMARY KEY (batch_id, [product_id], [category_id])
    );
END;
DENY SELECT, INSERT, UPDATE, DELETE ON OBJECT::dbo.Baseline_ProductCategory TO public;

IF OBJECT_ID(N'dbo.Baseline_Customer', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.Baseline_Customer (
        batch_id BIGINT NOT NULL,
        [customer_id] BIGINT NOT NULL,
        [mobile] VARCHAR(20) NOT NULL,
        [customer_type] VARCHAR(20) NOT NULL,
        [member_level_id] BIGINT NULL,
        [current_points] INT NOT NULL,
        [status] VARCHAR(20) NOT NULL,
        CONSTRAINT PK_Baseline_Customer PRIMARY KEY (batch_id, [customer_id])
    );
END;
DENY SELECT, INSERT, UPDATE, DELETE ON OBJECT::dbo.Baseline_Customer TO public;

IF OBJECT_ID(N'dbo.Baseline_ProductBom', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.Baseline_ProductBom (
        batch_id BIGINT NOT NULL,
        [product_id] BIGINT NOT NULL,
        [ingredient_id] BIGINT NOT NULL,
        [usage_qty] DECIMAL(12,3) NOT NULL,
        CONSTRAINT PK_Baseline_ProductBom PRIMARY KEY (batch_id, [product_id], [ingredient_id])
    );
END;
DENY SELECT, INSERT, UPDATE, DELETE ON OBJECT::dbo.Baseline_ProductBom TO public;

IF OBJECT_ID(N'dbo.Baseline_ComboComponent', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.Baseline_ComboComponent (
        batch_id BIGINT NOT NULL,
        [combo_product_id] BIGINT NOT NULL,
        [child_product_id] BIGINT NOT NULL,
        [quantity] INT NOT NULL,
        CONSTRAINT PK_Baseline_ComboComponent PRIMARY KEY (batch_id, [combo_product_id], [child_product_id])
    );
END;
DENY SELECT, INSERT, UPDATE, DELETE ON OBJECT::dbo.Baseline_ComboComponent TO public;

IF OBJECT_ID(N'dbo.Baseline_Promotion', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.Baseline_Promotion (
        batch_id BIGINT NOT NULL,
        [promotion_id] BIGINT NOT NULL,
        [promotion_name] NVARCHAR(50) NOT NULL,
        [promotion_type] VARCHAR(20) NOT NULL,
        [start_at] DATETIME2(0) NOT NULL,
        [end_at] DATETIME2(0) NOT NULL,
        [status] VARCHAR(20) NOT NULL,
        CONSTRAINT PK_Baseline_Promotion PRIMARY KEY (batch_id, [promotion_id])
    );
END;
DENY SELECT, INSERT, UPDATE, DELETE ON OBJECT::dbo.Baseline_Promotion TO public;

IF OBJECT_ID(N'dbo.Baseline_PromotionProductRule', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.Baseline_PromotionProductRule (
        batch_id BIGINT NOT NULL,
        [promotion_rule_id] BIGINT NOT NULL,
        [promotion_id] BIGINT NOT NULL,
        [product_id] BIGINT NOT NULL,
        [weekday_no] INT NOT NULL,
        [start_time] TIME(0) NOT NULL,
        [end_time] TIME(0) NOT NULL,
        [promo_price] DECIMAL(10,2) NOT NULL,
        [priority] INT NOT NULL,
        CONSTRAINT PK_Baseline_PromotionProductRule PRIMARY KEY (batch_id, [promotion_rule_id])
    );
END;
DENY SELECT, INSERT, UPDATE, DELETE ON OBJECT::dbo.Baseline_PromotionProductRule TO public;

INSERT INTO dbo.Baseline_Category (batch_id, [category_id], [category_name], [status])
SELECT @batch_id, [category_id], [category_name], [status] FROM dbo.Category;

INSERT INTO dbo.Baseline_MemberLevel (batch_id, [member_level_id], [level_name], [point_multiplier], [threshold_points], [status])
SELECT @batch_id, [member_level_id], [level_name], [point_multiplier], [threshold_points], [status] FROM dbo.MemberLevel;

INSERT INTO dbo.Baseline_Ingredient (batch_id, [ingredient_id], [ingredient_name], [unit_name], [safety_stock_qty], [status])
SELECT @batch_id, [ingredient_id], [ingredient_name], [unit_name], [safety_stock_qty], [status] FROM dbo.Ingredient;

INSERT INTO dbo.Baseline_Product (batch_id, [product_id], [product_name], [base_price], [product_type], [status])
SELECT @batch_id, [product_id], [product_name], [base_price], [product_type], [status] FROM dbo.Product;

INSERT INTO dbo.Baseline_ProductCategory (batch_id, [product_id], [category_id], [is_primary])
SELECT @batch_id, [product_id], [category_id], [is_primary] FROM dbo.ProductCategory;

INSERT INTO dbo.Baseline_Customer (batch_id, [customer_id], [mobile], [customer_type], [member_level_id], [current_points], [status])
SELECT @batch_id, [customer_id], [mobile], [customer_type], [member_level_id], [current_points], [status] FROM dbo.Customer;

INSERT INTO dbo.Baseline_ProductBom (batch_id, [product_id], [ingredient_id], [usage_qty])
SELECT @batch_id, [product_id], [ingredient_id], [usage_qty] FROM dbo.ProductBom;

INSERT INTO dbo.Baseline_ComboComponent (batch_id, [combo_product_id], [child_product_id], [quantity])
SELECT @batch_id, [combo_product_id], [child_product_id], [quantity] FROM dbo.ComboComponent;

INSERT INTO dbo.Baseline_Promotion (batch_id, [promotion_id], [promotion_name], [promotion_type], [start_at], [end_at], [status])
SELECT @batch_id, [promotion_id], [promotion_name], [promotion_type], [start_at], [end_at], [status] FROM dbo.Promotion;

INSERT INTO dbo.Baseline_PromotionProductRule (batch_id, [promotion_rule_id], [promotion_id], [product_id], [weekday_no], [start_time], [end_time], [promo_price], [priority])
SELECT @batch_id, [promotion_rule_id], [promotion_id], [product_id], [weekday_no], [start_time], [end_time], [promo_price], [priority] FROM dbo.PromotionProductRule;
