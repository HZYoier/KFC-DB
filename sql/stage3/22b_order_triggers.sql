-- B: validate completion for all orders in the statement; no business writes.
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
CREATE TRIGGER dbo.tr_SalesOrder_Complete_Check ON dbo.SalesOrder
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT UPDATE(order_status) RETURN;

    IF EXISTS (
        SELECT 1 FROM inserted i JOIN deleted d ON i.order_id = d.order_id
        WHERE d.order_status IN ('PICKED_UP','COMPLETED')
          AND i.order_status IN ('PICKED_UP','COMPLETED')
    )
        THROW 54210, 'An order cannot be completed twice.', 1;

    DECLARE @finished TABLE (order_id BIGINT PRIMARY KEY);
    INSERT @finished SELECT i.order_id
    FROM inserted i JOIN deleted d ON i.order_id = d.order_id
    WHERE d.order_status NOT IN ('PICKED_UP','COMPLETED')
      AND i.order_status IN ('PICKED_UP','COMPLETED');

    IF EXISTS (
        SELECT 1 FROM @finished f JOIN inserted i ON i.order_id = f.order_id
        JOIN deleted d ON i.order_id = d.order_id
        WHERE i.completed_at IS NULL OR NOT (
            (i.fulfillment_method = 'PICKUP' AND d.order_status = 'READY_FOR_PICKUP' AND i.order_status = 'PICKED_UP')
            OR (i.fulfillment_method = 'DELIVERY' AND d.order_status = 'DELIVERING' AND i.order_status = 'COMPLETED')
        )
    )
        THROW 54211, 'Completion requires the corresponding prior state and completed_at.', 1;

    IF EXISTS (
        SELECT 1 FROM @finished f
        WHERE NOT EXISTS (
            SELECT 1 FROM dbo.SalesOrderItem l WHERE l.order_id = f.order_id AND l.item_role = 'SELLABLE'
        )
        OR EXISTS (
            SELECT 1 FROM dbo.SalesOrderItem l LEFT JOIN dbo.Product p ON p.product_id = l.product_id
            WHERE l.order_id = f.order_id AND l.item_role = 'SELLABLE'
              AND (p.product_id IS NULL OR l.quantity <= 0 OR l.unit_price < 0 OR l.discount_amount < 0
                   OR l.discount_amount > ROUND(l.unit_price * l.quantity, 2))
        )
    )
        THROW 54212, 'A completed order must have valid sellable lines.', 1;

    IF EXISTS (
        SELECT 1 FROM @finished f JOIN inserted i ON i.order_id = f.order_id
        CROSS APPLY (
            SELECT SUM(ROUND(l.unit_price * l.quantity, 2) - l.discount_amount) AS net
            FROM dbo.SalesOrderItem l WHERE l.order_id = f.order_id AND l.item_role = 'SELLABLE'
        ) a WHERE a.net <> i.total_amount
    )
        THROW 54213, 'Order total must equal the sum of net sellable lines.', 1;

    -- Check the ingredients reserved for this order. The live BOM may have
    -- changed after reservation. A BOM-backed order without reservations must
    -- still have consumption evidence; lines without BOM need none.
    DECLARE @required TABLE (order_id BIGINT, ingredient_id BIGINT,
                             PRIMARY KEY (order_id, ingredient_id));
    INSERT @required (order_id, ingredient_id)
        SELECT f.order_id, m.ingredient_id
        FROM @finished f JOIN dbo.InventoryMovement m
          ON m.reference_type = 'ORDER' AND m.reference_id = f.order_id AND m.movement_type = 'LOCK'
        UNION
        SELECT f.order_id, b.ingredient_id
        FROM @finished f JOIN dbo.SalesOrderItem l ON l.order_id = f.order_id
        JOIN dbo.Product p ON p.product_id = l.product_id
        JOIN dbo.ProductBom b ON b.product_id = l.product_id
        WHERE (l.item_role = 'COMPONENT' OR (l.item_role = 'SELLABLE' AND p.product_type = 'SINGLE'))
          AND NOT EXISTS (
              SELECT 1 FROM dbo.InventoryMovement m
              WHERE m.reference_type = 'ORDER' AND m.reference_id = f.order_id
                AND m.movement_type = 'LOCK'
          );

    IF EXISTS (
        SELECT 1
        FROM @required r LEFT JOIN dbo.Inventory inv ON inv.ingredient_id = r.ingredient_id
        WHERE inv.ingredient_id IS NULL OR inv.on_hand_qty < 0 OR NOT EXISTS (
              SELECT 1 FROM dbo.InventoryMovement m
              WHERE m.reference_type = 'ORDER' AND m.reference_id = r.order_id
                AND m.ingredient_id = r.ingredient_id AND m.movement_type = 'CONSUME'
          )
    )
        THROW 54214, 'Order ingredients must have recorded consumption and valid stock.', 1;
END;
GO
