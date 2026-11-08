-- 10张表+外键+主键
USE KFC_DB
GO

-- 过滤唯一索引要求这些 SET 选项为 ON；sqlcmd/ODBC 默认 QUOTED_IDENTIFIER 为 OFF
SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET QUOTED_IDENTIFIER ON;
SET NUMERIC_ROUNDABORT OFF;
GO


-- 商品分类
create table Category(
    category_id bigint identity(1,1) constraint PK_Category primary key,  -- 分类ID
    category_name nvarchar(50) not null,  -- 分类名称
    [status] varchar(20) not null  -- 分类状态
)


-- 会员等级与积分倍率
create table MemberLevel(
    member_level_id bigint identity(1,1) constraint PK_MemberLevel primary key,
    level_name nvarchar(50) not null,  -- 等级名
    point_multiplier decimal(5, 2) not null,  -- 积分倍率
    threshold_points int not null,  -- 升级门槛
    [status] varchar(20) not null  -- 等级状态
)

-- 原料
create table Ingredient(
    ingredient_id bigint identity(1,1) constraint PK_Ingredient primary key,
    ingredient_name nvarchar(50) not null,  -- 原料名
    unit_name nvarchar(50) not null,  -- 计量单位，如：片，克
    safety_stock_qty decimal(12, 3) not null,  -- 安全库存线
    [status] varchar(20) not null  -- 原料状态
)


-- 商品与套餐
create table Product(
    product_id bigint identity(1,1) constraint PK_Product primary key,
    product_name nvarchar(50) not null,  -- 商品名
    base_price decimal(10, 2) not null,  -- 标准价
    product_type varchar(20) not null,  -- 商品类型：单品 / 套餐
    [status] varchar(20) not null  -- 商品状态
)


-- 商品分类关系表
create table ProductCategory(
    product_id bigint,  -- 商品
    category_id bigint,  -- 分类
    is_primary bit not NULL  -- 是否主分类
        constraint DF_ProductCategory_is_primary default 0,
    constraint PK_ProductCategory primary key(product_id, category_id),
    constraint FK_ProductCategory_Product
        foreign key(product_id) references Product(product_id),
    constraint FK_ProductCategory_Category
        foreign key(category_id) references Category(category_id)
)

CREATE UNIQUE INDEX UQ_ProductCategory_is_primary
    ON ProductCategory(product_id) WHERE is_primary = 1;
-- v_active_product_price 靠 is_primary = 1 取展示分类


-- 顾客
create table Customer(
    customer_id bigint identity(1,1) NOT NULL 
    constraint PK_Customer primary key,  -- 顾客ID
    mobile varchar(20) not null constraint UQ_Customer_Mobile unique,  -- 手机号
    customer_type varchar(20) not null,  -- 顾客类型：散客 / WOW会员 / 付费会员
    member_level_id bigint,  -- 当前会员等级
    current_points int not null,  -- 当前累计积分
    [status] varchar(20) not null,  -- 顾客状态
    constraint FK_Customer_MemberLevel
        foreign key(member_level_id) references MemberLevel(member_level_id)
)


-- 商品用料表
create table ProductBom(
    product_id bigint,  -- 用料商品
    ingredient_id bigint, -- 消耗的原料
    usage_qty decimal(12, 3) not null,  -- 每个销售单位消耗的原料量
    constraint PK_ProductBom primary key(product_id, ingredient_id),
    constraint FK_ProductBom_Product
        foreign key(product_id) references Product(product_id),
    constraint FK_ProductBom_Ingredient
        foreign key(ingredient_id) references Ingredient(ingredient_id)
)


-- 套餐组成
create table ComboComponent(
    combo_product_id bigint,  -- 套餐父项
    child_product_id bigint,  -- 子项商品
    quantity int not null,  -- 套餐中子项商品的数量
    constraint PK_ComboComponent primary key(combo_product_id, child_product_id),
    constraint FK_ComboComponent_ComboProduct
        foreign key(combo_product_id) references Product(product_id),
    constraint FK_ComboComponent_ChildProduct
        foreign key(child_product_id) references Product(product_id)
)


-- 促销活动
create table Promotion(
    promotion_id bigint identity(1,1) constraint PK_Promotion primary key,  -- 促销活动ID
    promotion_name nvarchar(50) not null,  -- 促销活动名称
    promotion_type varchar(20) not null,  -- 促销类型
    start_at datetime2(0) not null,  -- 促销起始时间
    end_at datetime2(0) not null,  -- 促销结束时间
    [status] varchar(20) not null  -- 促销活动状态
)


-- 促销活动明细
create table PromotionProductRule(
    promotion_rule_id bigint identity(1,1) constraint PK_PromotionProductRule primary key,  -- 促销规则ID
    promotion_id bigint not null,  -- 促销活动ID
    product_id bigint not null,  -- 适用商品
    weekday_no int not null,  -- 适用于星期几
    start_time time(0) not null,  -- 促销开始时间
    end_time time(0) not null,  -- 促销结束时间
    promo_price decimal(10, 2) not null,  -- 促销价格
    [priority] int not null,  -- 优先级，数字越大优先级越高
    constraint FK_PromotionProductRule_Promotion
        foreign key(promotion_id) references Promotion(promotion_id),
    constraint FK_PromotionProductRule_Product
        foreign key(product_id) references Product(product_id)
)


