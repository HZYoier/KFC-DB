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

create table Category(
    category_id bigint identity(1,1) constraint PK_Category primary key,
    category_name nvarchar(50),
    [status] varchar(20)
)


create table MemberLevel(
    member_level_id bigint identity(1,1) constraint PK_MemberLevel primary key,
    level_name nvarchar(50),
    point_multiplier decimal(5, 2),
    threshold_points int,
    [status] varchar(20)
)

-- 原料
create table Ingredient(
    ingredient_id bigint identity(1,1) constraint PK_Ingredient primary key,
    ingredient_name nvarchar(50),
    unit_name nvarchar(50),
    safety_stock_qty decimal(12, 3),  -- 安全库存量
    [status] varchar(20)
)


create table Product(
    product_id bigint identity(1,1) constraint PK_Product primary key,
    product_name nvarchar(50),
    base_price decimal(10, 2),
    product_type varchar(20),
    [status] varchar(20)
)


create table ProductCategory(
    product_id bigint,
    category_id bigint,
    is_primary bit not NULL
        constraint DF_ProductCategory_is_primary default 0,
    constraint PK_ProductCategory primary key(product_id, category_id),
    constraint FK_ProductCategory_Product
        foreign key(product_id) references Product(product_id),
    constraint FK_ProductCategory_Category
        foreign key(category_id) references Category(category_id)
)

CREATE UNIQUE INDEX UQ_ProductCategory_is_primary
    ON ProductCategory(product_id) WHERE is_primary = 1;



create table Customer(
    customer_id bigint identity(1,1) constraint PK_Customer primary key,
    mobile varchar(20) constraint UQ_Customer_Mobile unique,
    customer_type varchar(20),
    member_level_id bigint,
    current_points int,
    [status] varchar(20),
    constraint FK_Customer_MemberLevel
        foreign key(member_level_id) references MemberLevel(member_level_id)
)


create table ProductBom(
    product_id bigint,
    ingredient_id bigint,
    usage_qty decimal(12, 3),  -- 用量
    constraint PK_ProductBom primary key(product_id, ingredient_id),
    constraint FK_ProductBom_Product
        foreign key(product_id) references Product(product_id),
    constraint FK_ProductBom_Ingredient
        foreign key(ingredient_id) references Ingredient(ingredient_id)
)


create table ComboComponent(
    combo_product_id bigint,
    child_product_id bigint,
    quantity int,
    constraint PK_ComboComponent primary key(combo_product_id, child_product_id),
    constraint FK_ComboComponent_ComboProduct
        foreign key(combo_product_id) references Product(product_id),
    constraint FK_ComboComponent_ChildProduct
        foreign key(child_product_id) references Product(product_id)
)


create table Promotion(
    promotion_id bigint identity(1,1) constraint PK_Promotion primary key,
    promotion_name nvarchar(50),
    promotion_type varchar(20),
    start_at datetime2(0),
    end_at datetime2(0),
    [status] varchar(20)
)


create table PromotionProductRule(
    promotion_rule_id bigint identity(1,1) constraint PK_PromotionProductRule primary key,
    promotion_id bigint,
    product_id bigint,
    weekday_no int,
    start_time time(0),
    end_time time(0),
    promo_price decimal(10, 2),
    [priority] int,
    constraint FK_PromotionProductRule_Promotion
        foreign key(promotion_id) references Promotion(promotion_id),
    constraint FK_PromotionProductRule_Product
        foreign key(product_id) references Product(product_id)
)


