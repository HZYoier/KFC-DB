-- 2 个视图 + 2 条具名查询

SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET QUOTED_IDENTIFIER ON;
SET NUMERIC_ROUNDABORT OFF;
GO

USE KFC_DB;
GO

-- 视图 1：在售商品及当前售价 
CREATE VIEW dbo.v_active_product_price
AS
SELECT
    p.product_id,
    p.product_name,
    p.product_type,
    c.category_id,
    c.category_name,
    p.base_price,
    price.effective_price,
    price.promotion_id
FROM dbo.Product AS p
JOIN dbo.ProductCategory AS pc
  ON pc.product_id = p.product_id
 AND pc.is_primary = 1
JOIN dbo.Category AS c
  ON c.category_id = pc.category_id
CROSS APPLY dbo.fn_get_effective_product_price(p.product_id, SYSDATETIME()) AS price
WHERE p.[status] = 'ACTIVE';
GO


-- 视图 2：BOM 明细（含套餐展开） 
CREATE VIEW dbo.v_product_bom_detail
AS
-- 单品：直接取 ProductBom，用料商品就是商品自身
SELECT
    p.product_id        AS sale_product_id,
    p.product_name      AS sale_product_name,
    p.product_id        AS used_product_id,
    p.product_name      AS used_product_name,
    i.ingredient_id,
    i.ingredient_name,
    i.unit_name,
    b.usage_qty         AS qty_per_sale,
    i.safety_stock_qty
FROM dbo.Product AS p
JOIN dbo.ProductBom AS b
  ON b.product_id = p.product_id
JOIN dbo.Ingredient AS i
  ON i.ingredient_id = b.ingredient_id
WHERE p.product_type = 'SINGLE'
  AND p.[status] = 'ACTIVE'
  AND i.[status] = 'ACTIVE'

UNION ALL

-- 套餐：先经 ComboComponent 展开到子商品，再取子商品 BOM，按（套餐, 子商品, 原料）汇总用量
SELECT
    combo.product_id    AS sale_product_id,
    combo.product_name  AS sale_product_name,
    child.product_id    AS used_product_id,
    child.product_name  AS used_product_name,
    i.ingredient_id,
    i.ingredient_name,
    i.unit_name,
    CAST(SUM(b.usage_qty * cc.quantity) AS DECIMAL(12,3)) AS qty_per_sale,
    i.safety_stock_qty
FROM dbo.Product AS combo
JOIN dbo.ComboComponent AS cc
  ON cc.combo_product_id = combo.product_id
JOIN dbo.Product AS child
  ON child.product_id = cc.child_product_id
JOIN dbo.ProductBom AS b
  ON b.product_id = child.product_id
JOIN dbo.Ingredient AS i
  ON i.ingredient_id = b.ingredient_id
WHERE combo.product_type = 'COMBO'
  AND combo.[status] = 'ACTIVE'
  AND child.product_type = 'SINGLE'
  AND i.[status] = 'ACTIVE'
GROUP BY combo.product_id, combo.product_name,
         child.product_id, child.product_name,
         i.ingredient_id, i.ingredient_name, i.unit_name, i.safety_stock_qty;
GO


-- 具名查询
-- Q-A1 在售商品及当前售价
SELECT
    product_id,
    product_name,
    product_type,
    category_name,
    base_price,
    effective_price,
    promotion_id
FROM dbo.v_active_product_price
ORDER BY category_name, product_name;
GO

-- Q-A2 指定商品的 BOM 明细
DECLARE @product_id BIGINT = 1;   -- 换成要查的商品 ID（套餐或单品）

SELECT
    sale_product_name,
    used_product_name,
    ingredient_name,
    unit_name,
    qty_per_sale,
    safety_stock_qty
FROM dbo.v_product_bom_detail
WHERE sale_product_id = @product_id
ORDER BY used_product_name, ingredient_name;
GO
