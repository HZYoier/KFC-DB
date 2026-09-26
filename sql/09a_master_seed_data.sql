
-- 部署种子


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


IF EXISTS (SELECT 1 FROM dbo.Product)            OR EXISTS (SELECT 1 FROM dbo.Category)
   OR EXISTS (SELECT 1 FROM dbo.Ingredient)      OR EXISTS (SELECT 1 FROM dbo.MemberLevel)
   OR EXISTS (SELECT 1 FROM dbo.Customer)        OR EXISTS (SELECT 1 FROM dbo.Promotion)
   OR EXISTS (SELECT 1 FROM dbo.ProductCategory) OR EXISTS (SELECT 1 FROM dbo.ProductBom)
   OR EXISTS (SELECT 1 FROM dbo.ComboComponent)  OR EXISTS (SELECT 1 FROM dbo.PromotionProductRule)
    THROW 51000, N'09a：A 域主数据表非空，本种子只允许在空库上执行。', 1;

BEGIN TRANSACTION;
BEGIN TRY

    -- 商品分类
    SET IDENTITY_INSERT dbo.Category ON;
    INSERT INTO dbo.Category (category_id, category_name, [status]) VALUES
        (1, N'主餐',     'ACTIVE'),
        (2, N'小食饮品', 'ACTIVE');
    SET IDENTITY_INSERT dbo.Category OFF;

    -- 会员等级 
    SET IDENTITY_INSERT dbo.MemberLevel ON;
    INSERT INTO dbo.MemberLevel
        (member_level_id, level_name, point_multiplier, threshold_points, [status]) VALUES
        (1, N'普通会员', 1.00,    0, 'ACTIVE'),
        (2, N'银卡会员', 1.20,  500, 'ACTIVE'),
        (3, N'金卡会员', 1.50, 1500, 'ACTIVE');
    SET IDENTITY_INSERT dbo.MemberLevel OFF;

    -- 原料 
    SET IDENTITY_INSERT dbo.Ingredient ON;
    INSERT INTO dbo.Ingredient
        (ingredient_id, ingredient_name, unit_name, safety_stock_qty, [status]) VALUES
        (1, N'鸡腿肉',   N'片',     40.000, 'ACTIVE'),
        (2, N'汉堡面包', N'片',     40.000, 'ACTIVE'),
        (3, N'生菜',     N'克',    500.000, 'ACTIVE'),
        (4, N'沙拉酱',   N'克',    800.000, 'ACTIVE'),
        (5, N'薯条',     N'克',   1000.000, 'ACTIVE'),
        (6, N'可乐原浆', N'毫升', 2000.000, 'ACTIVE');
    SET IDENTITY_INSERT dbo.Ingredient OFF;

    -- 商品与套餐
    SET IDENTITY_INSERT dbo.Product ON;
    INSERT INTO dbo.Product (product_id, product_name, base_price, product_type, [status]) VALUES
        (1, N'香辣鸡腿堡',   19.00, 'SINGLE', 'ACTIVE'),
        (2, N'劲脆鸡腿堡',   17.50, 'SINGLE', 'ACTIVE'),
        (3, N'薯条(中)',     12.00, 'SINGLE', 'ACTIVE'),
        (4, N'可乐(中)',      9.00, 'SINGLE', 'ACTIVE'),
        (5, N'双人分享餐',   45.00, 'COMBO',  'ACTIVE'),
        (6, N'鲜蔬沙拉',     14.00, 'SINGLE', 'ACTIVE');
    SET IDENTITY_INSERT dbo.Product OFF;

    -- 商品分类关系
    INSERT INTO dbo.ProductCategory (product_id, category_id, is_primary) VALUES
        (1, 1, 1),
        (2, 1, 1),
        (3, 2, 1), (3, 1, 0),
        (4, 2, 1), (4, 1, 0),
        (5, 1, 1),
        (6, 1, 1);

    -- 单品用料 
    INSERT INTO dbo.ProductBom (product_id, ingredient_id, usage_qty) VALUES
        (1, 1,   1.000), (1, 2,   1.000), (1, 3,  30.000), (1, 4,  20.000),
        (2, 1,   1.000), (2, 2,   1.000), (2, 3,  20.000), (2, 4,  25.000),
        (3, 5, 150.000),
        (4, 6, 300.000),
        (6, 3, 120.000), (6, 4,  30.000);

    -- 套餐组成 
    -- 套餐不配直接 BOM；子项均为 SINGLE 且各自已有用料
    -- 1、2 号共用鸡腿肉/汉堡面包/生菜/沙拉酱
    -- 4 号取 2 份（可乐原浆 300.000 × 2 = 600.000，供检验按子项数量缩放）
    INSERT INTO dbo.ComboComponent (combo_product_id, child_product_id, quantity) VALUES
        (5, 1, 1),
        (5, 2, 1),
        (5, 4, 2);

    -- 顾客 
    SET IDENTITY_INSERT dbo.Customer ON;
    INSERT INTO dbo.Customer
        (customer_id, mobile, customer_type, member_level_id, current_points, [status]) VALUES
        (1, '13900000001', 'GUEST', NULL,    0, 'ACTIVE'),
        (2, '13900000002', 'WOW',      2,  500, 'ACTIVE'),
        (3, '13900000003', 'PAID',     3, 1500, 'ACTIVE');
    SET IDENTITY_INSERT dbo.Customer OFF;

    -- 促销：疯狂星期四
    SET IDENTITY_INSERT dbo.Promotion ON;
    INSERT INTO dbo.Promotion
        (promotion_id, promotion_name, promotion_type, start_at, end_at, [status]) VALUES
        (1, N'疯狂星期四', 'FIXED_PRICE',
         CAST('2026-01-01 00:00:00' AS DATETIME2(0)),
         CAST('2030-12-31 23:59:59' AS DATETIME2(0)), 'INACTIVE');
    SET IDENTITY_INSERT dbo.Promotion OFF;

    -- 重叠促销按 priority 取唯一最高优先级
    SET IDENTITY_INSERT dbo.PromotionProductRule ON;
    INSERT INTO dbo.PromotionProductRule
        (promotion_rule_id, promotion_id, product_id, weekday_no,
         start_time, end_time, promo_price, [priority]) VALUES
        (1, 1, 1, 4, CAST('00:00:00' AS TIME(0)), CAST('23:59:59' AS TIME(0)),  9.90, 10),
        (2, 1, 1, 4, CAST('00:00:00' AS TIME(0)), CAST('23:59:59' AS TIME(0)), 12.00,  5);
    SET IDENTITY_INSERT dbo.PromotionProductRule OFF;

    UPDATE dbo.Promotion SET [status] = 'ACTIVE' WHERE promotion_id = 1;

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
GO

-- 自查：商品数、套餐组成行数、促销是否已启用
SELECT 'products' AS k, COUNT(*) AS n FROM dbo.Product
UNION ALL SELECT 'combo_components', COUNT(*) FROM dbo.ComboComponent
UNION ALL SELECT 'bom_rows',        COUNT(*) FROM dbo.ProductBom
UNION ALL SELECT 'active_promotions', COUNT(*) FROM dbo.Promotion WHERE [status] = 'ACTIVE';
GO
