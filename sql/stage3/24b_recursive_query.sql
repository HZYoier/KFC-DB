-- Run in the order database with sqlcmd -v OrderId=<id> OrderItemId=NULL.
-- Set OrderItemId to an order-item ID to return that item's subtree.
-- Example: 2 combos with 3 pieces each store root quantity 2 and child quantity 6.
-- SalesOrderItem is self-referencing. Each COMPONENT points to its parent item.
-- A root is a SELLABLE line whose parent is NULL. Depth starts at zero.
-- Component quantity is already relative to the whole order (21b snapshots it
-- as parent quantity * pieces per parent). Never reapply the live combo recipe.
-- Current order entry writes one component level. The regression also inserts
-- a temporary second level to exercise recursion without changing that rule.
DECLARE @order_id BIGINT = $(OrderId), @order_item_id BIGINT = $(OrderItemId);

;WITH item_tree AS (
    SELECT i.order_id, i.order_item_id, i.parent_order_item_id, i.product_id,
           i.item_role, i.quantity, i.unit_price, 0 AS depth,
           CAST('/' + CONVERT(VARCHAR(20), i.order_item_id) + '/' AS VARCHAR(256)) AS item_path
    FROM dbo.SalesOrderItem AS i
    WHERE i.order_id = @order_id AND i.parent_order_item_id IS NULL AND i.item_role = 'SELLABLE'

    UNION ALL

    SELECT i.order_id, i.order_item_id, i.parent_order_item_id, i.product_id,
           i.item_role, i.quantity, i.unit_price, t.depth + 1,
           CAST(t.item_path + CONVERT(VARCHAR(20), i.order_item_id) + '/' AS VARCHAR(256))
    FROM item_tree AS t
    JOIN dbo.SalesOrderItem AS i
      ON i.order_id = t.order_id AND i.parent_order_item_id = t.order_item_id
    WHERE i.item_role = 'COMPONENT'
      AND CHARINDEX('/' + CONVERT(VARCHAR(20), i.order_item_id) + '/', t.item_path) = 0
)
SELECT t.order_id, t.order_item_id, t.parent_order_item_id, t.depth, t.item_path,
       t.product_id, p.product_name, t.item_role,
       CONVERT(DECIMAL(21,6), CONVERT(DECIMAL(21,6), t.quantity) / COALESCE(parent.quantity, 1)) AS quantity_per_parent,
       t.quantity AS expanded_quantity, t.unit_price,
       CONVERT(DECIMAL(22,2), t.unit_price * t.quantity) AS line_amount
FROM item_tree AS t
JOIN dbo.Product AS p ON p.product_id = t.product_id
LEFT JOIN dbo.SalesOrderItem AS parent
  ON parent.order_id = t.order_id AND parent.order_item_id = t.parent_order_item_id
WHERE @order_item_id IS NULL
   OR CHARINDEX('/' + CONVERT(VARCHAR(20), @order_item_id) + '/', t.item_path) > 0
ORDER BY t.item_path
OPTION (MAXRECURSION 10);
