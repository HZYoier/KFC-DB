-- B v1.1 programmability. The caller owns the migration transaction.
-- See docs/stage3/sales-semantics.md; no historical rows are updated here.
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE VIEW dbo.v_settled_sales_line
AS
SELECT o.order_id, o.order_no, o.completed_at, i.product_id,
       CONVERT(NVARCHAR(100), p.product_name) AS product_name, pc.category_id, i.quantity,
       a.gross_amount, CONVERT(DECIMAL(12,2), i.discount_amount) AS discount_amount,
       CONVERT(DECIMAL(12,2), a.gross_amount - i.discount_amount) AS net_amount
FROM dbo.SalesOrder o
JOIN dbo.SalesOrderItem i ON i.order_id = o.order_id
JOIN dbo.Product p ON p.product_id = i.product_id
LEFT JOIN dbo.ProductCategory pc ON pc.product_id = p.product_id AND pc.is_primary = 1
CROSS APPLY (VALUES (CONVERT(DECIMAL(12,2), ROUND(i.unit_price * i.quantity, 2)))) a(gross_amount)
WHERE o.order_status IN ('PICKED_UP','COMPLETED') AND o.completed_at IS NOT NULL
  AND i.item_role = 'SELLABLE' AND i.quantity > 0;
GO

CREATE PROCEDURE dbo.sp_sales_report @start_date DATE, @end_date DATE
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @message NVARCHAR(2048);
    IF @start_date IS NULL OR @end_date IS NULL OR @start_date > @end_date
    BEGIN
        SET @message = CONCAT('Invalid sales date range: ', COALESCE(CONVERT(VARCHAR(10), @start_date, 23), 'NULL'),
            ' through ', COALESCE(CONVERT(VARCHAR(10), @end_date, 23), 'NULL'), '.');
        IF @start_date IS NULL OR @end_date IS NULL THROW 54201, @message, 1;
        THROW 54202, @message, 1;
    END;
    DECLARE @exclusive DATE = DATEADD(DAY, 1, NULLIF(@end_date, CONVERT(DATE, '99991231', 112)));
    SELECT COUNT(DISTINCT order_id) AS order_count,
           COALESCE(SUM(CONVERT(BIGINT, quantity)), 0) AS sold_qty,
           COALESCE(SUM(net_amount), 0) AS sales_amount
    FROM dbo.v_settled_sales_line
    WHERE completed_at >= @start_date AND (@exclusive IS NULL OR completed_at < @exclusive);

    SELECT product_id, product_name, SUM(CONVERT(BIGINT, quantity)) AS sold_qty,
           SUM(net_amount) AS sales_amount, COUNT(DISTINCT order_id) AS order_count
    FROM dbo.v_settled_sales_line
    WHERE completed_at >= @start_date AND (@exclusive IS NULL OR completed_at < @exclusive)
    GROUP BY product_id, product_name
    ORDER BY sales_amount DESC, product_id;
END;
GO

-- v1.1 appends discount snapshots to payment result set 2. Keep the existing
-- signature, role guard, header result set and original six detail columns.
ALTER PROCEDURE dbo.sp_get_order_for_payment
    @order_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @actor BIGINT = (SELECT employee_id FROM dbo.EmployeeAccount
        WHERE database_user_name = USER_NAME() AND status = 'ACTIVE' AND job_code = 'CASHIER');
    IF @actor IS NULL
        THROW 52100, 'This operation requires a current active employee in the required job.', 1;
    DECLARE @head TABLE (order_id BIGINT PRIMARY KEY, order_no VARCHAR(50) NOT NULL,
        total_amount DECIMAL(10,2) NOT NULL, ordered_at DATETIME2(0) NOT NULL, fulfillment_method VARCHAR(20) NOT NULL);
    INSERT @head SELECT order_id, order_no, total_amount, ordered_at, fulfillment_method
    FROM dbo.SalesOrder WHERE order_id = @order_id AND order_status = 'PENDING_PAYMENT';
    IF @@ROWCOUNT = 0
        THROW 52903, 'Order does not exist or is no longer pending payment.', 1;
    SELECT order_id, order_no, total_amount, ordered_at, fulfillment_method FROM @head;
    SELECT i.order_item_id, i.product_id, p.product_name, i.quantity, i.unit_price, i.promotion_id,
           i.discount_rate, i.discount_amount
    FROM @head h JOIN dbo.SalesOrderItem i ON i.order_id = h.order_id
    JOIN dbo.Product p ON p.product_id = i.product_id
    WHERE i.item_role = 'SELLABLE' ORDER BY i.order_item_id;
END;
GO

ALTER PROCEDURE dbo.sp_create_order
    @customer_id BIGINT,
    @fulfillment_method VARCHAR(20),
    @order_no VARCHAR(50),
    @items_json NVARCHAR(MAX),
    @ordered_at DATETIME2(0) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET ANSI_NULLS ON;
    SET ANSI_PADDING ON;
    SET ANSI_WARNINGS ON;
    SET ARITHABORT ON;
    SET CONCAT_NULL_YIELDS_NULL ON;
    SET QUOTED_IDENTIFIER ON;
    SET NUMERIC_ROUNDABORT OFF;
    DECLARE @entry_trancount INT = @@TRANCOUNT, @actor_id BIGINT;
    BEGIN TRY
        IF @entry_trancount = 0 BEGIN TRANSACTION;
        ELSE SAVE TRANSACTION B_create_order;
        SELECT @actor_id = employee_id
        FROM dbo.EmployeeAccount WITH (HOLDLOCK)
        WHERE database_user_name = USER_NAME() AND status = 'ACTIVE' AND job_code = 'CASHIER';
        IF @actor_id IS NULL
            THROW 52100, 'This operation requires the current active CASHIER employee.', 1;

        IF @ordered_at IS NOT NULL AND USER_NAME() NOT LIKE N'test[_]%'
            THROW 52101, 'Only test_ principals may supply ordered_at.', 1;
        IF @customer_id IS NULL OR @customer_id <= 0
           OR NOT EXISTS (SELECT 1 FROM dbo.Customer WITH (HOLDLOCK) WHERE customer_id = @customer_id AND status = 'ACTIVE')
            THROW 52102, 'An active customer is required.', 1;
        IF @fulfillment_method IS NULL OR @fulfillment_method NOT IN ('PICKUP','DELIVERY')
           OR NULLIF(LTRIM(RTRIM(@order_no)), '') IS NULL
            THROW 52103, 'Order number and PICKUP/DELIVERY fulfillment are required.', 1;
        IF ISJSON(@items_json) <> 1 OR @items_json IS NULL
            THROW 52104, 'items_json must be a JSON array.', 1;
        -- Strip every JSON whitespace character before inspecting the root token.
        IF LEFT(LTRIM(REPLACE(REPLACE(REPLACE(@items_json, NCHAR(9), N' '), NCHAR(10), N' '), NCHAR(13), N' ')), 1) <> N'['
            THROW 52104, 'items_json must be a JSON array.', 1;
        IF NOT EXISTS (SELECT 1 FROM OPENJSON(@items_json))
           OR EXISTS (SELECT 1 FROM OPENJSON(@items_json) WHERE type <> 5)
            THROW 52105, 'A nonempty array of product objects is required.', 1;
        -- Whitelist exactly two numeric integer fields; reject duplicate JSON keys,
        -- item_role/parent IDs, submitted prices and caller-authored components.
        IF EXISTS (
            SELECT 1 FROM OPENJSON(@items_json) AS item
            CROSS APPLY OPENJSON(item.value) AS field
            WHERE field.[key] COLLATE Latin1_General_100_BIN2 NOT IN (N'product_id',N'quantity')
               OR field.type <> 2
               OR field.value COLLATE Latin1_General_100_BIN2 LIKE N'%[^0-9]%'
        ) OR EXISTS (
            SELECT 1 FROM OPENJSON(@items_json) AS item
            WHERE (SELECT COUNT(*) FROM OPENJSON(item.value)) <> 2
               OR (SELECT COUNT(*) FROM OPENJSON(item.value) WHERE [key] COLLATE Latin1_General_100_BIN2 = N'product_id') <> 1
               OR (SELECT COUNT(*) FROM OPENJSON(item.value) WHERE [key] COLLATE Latin1_General_100_BIN2 = N'quantity') <> 1
        )
            THROW 52106, 'Each item must contain only integer product_id and quantity.', 1;
        DECLARE @items TABLE (product_id BIGINT NULL, quantity INT NULL);
        INSERT @items (product_id, quantity)
        SELECT TRY_CONVERT(BIGINT, JSON_VALUE(value, '$.product_id')),
               TRY_CONVERT(INT, JSON_VALUE(value, '$.quantity'))
        FROM OPENJSON(@items_json);
        IF EXISTS (SELECT 1 FROM @items WHERE product_id IS NULL OR product_id <= 0 OR quantity IS NULL OR quantity <= 0)
            THROW 52107, 'Product IDs and quantities must be positive and within range.', 1;
        IF EXISTS (SELECT product_id FROM @items GROUP BY product_id HAVING COUNT(*) > 1)
            THROW 52108, 'Duplicate top-level products are not permitted.', 1;
        IF EXISTS (
            SELECT 1 FROM @items AS i LEFT JOIN dbo.Product AS p WITH (HOLDLOCK) ON p.product_id = i.product_id
            WHERE p.product_id IS NULL OR p.status IS NULL OR p.status <> 'ACTIVE'
               OR p.product_type IS NULL OR p.product_type NOT IN ('SINGLE','COMBO')
        )
            THROW 52109, 'Every product must exist and be active with a valid type.', 1;
        IF EXISTS (
            SELECT 1 FROM @items AS parent
            JOIN dbo.ComboComponent AS cc WITH (HOLDLOCK) ON cc.combo_product_id = parent.product_id
            JOIN @items AS child ON child.product_id = cc.child_product_id
        )
            THROW 52110, 'Submit only the combo parent, never its child in the same payload.', 1;
        IF EXISTS (
            SELECT 1 FROM @items AS i JOIN dbo.Product AS p WITH (HOLDLOCK) ON p.product_id = i.product_id
            WHERE (p.product_type = 'SINGLE' AND NOT EXISTS (
                SELECT 1 FROM dbo.ProductBom AS b WITH (HOLDLOCK) WHERE b.product_id = p.product_id))
               OR (p.product_type = 'COMBO' AND NOT EXISTS (
                SELECT 1 FROM dbo.ComboComponent AS cc WITH (HOLDLOCK) WHERE cc.combo_product_id = p.product_id))
        )
            THROW 52111, 'Single products need BOMs and combos need components.', 1;
        IF EXISTS (
            SELECT 1 FROM @items AS i
            JOIN dbo.Product AS parent WITH (HOLDLOCK) ON parent.product_id = i.product_id AND parent.product_type = 'COMBO'
            JOIN dbo.ComboComponent AS cc WITH (HOLDLOCK) ON cc.combo_product_id = i.product_id
            LEFT JOIN dbo.Product AS child WITH (HOLDLOCK) ON child.product_id = cc.child_product_id
            WHERE cc.quantity IS NULL OR cc.quantity <= 0
               OR CONVERT(BIGINT, i.quantity) * cc.quantity > 2147483647
               OR child.product_id IS NULL OR child.status IS NULL OR child.status <> 'ACTIVE'
               OR child.product_type IS NULL OR child.product_type <> 'SINGLE'
               OR NOT EXISTS (SELECT 1 FROM dbo.ProductBom AS b WITH (HOLDLOCK) WHERE b.product_id = child.product_id)
        )
            THROW 52112, 'Combo children must be active SINGLE products with BOM and valid quantities.', 1;

        DECLARE @effective_at DATETIME2(0) = COALESCE(@ordered_at, SYSDATETIME());
        DECLARE @order_id BIGINT, @pickup_code VARCHAR(20);
        -- 80 random bits; the filtered unique index rejects the entire transaction
        -- on the exceptionally rare collision, so no duplicate code can persist.
        SET @pickup_code = CASE WHEN @fulfillment_method = 'PICKUP'
            THEN LEFT(REPLACE(CONVERT(VARCHAR(36), NEWID()), '-', ''), 20) END;
        INSERT dbo.SalesOrder (order_no, customer_id, fulfillment_method, pickup_code, ordered_at)
        VALUES (@order_no, @customer_id, @fulfillment_method, @pickup_code, @effective_at);
        SET @order_id = CONVERT(BIGINT, SCOPE_IDENTITY());
        DECLARE @parents TABLE (order_item_id BIGINT NOT NULL, product_id BIGINT NOT NULL, quantity INT NOT NULL);
        INSERT dbo.SalesOrderItem (order_id, product_id, parent_order_item_id, item_role, quantity, unit_price, promotion_id)
        OUTPUT inserted.order_item_id, inserted.product_id, inserted.quantity INTO @parents
        SELECT @order_id, i.product_id, NULL, 'SELLABLE', i.quantity, price.effective_price, price.promotion_id
        FROM @items AS i
        CROSS APPLY dbo.fn_get_effective_product_price(i.product_id, @effective_at) AS price;
        IF (SELECT COUNT(*) FROM @parents) <> (SELECT COUNT(*) FROM @items)
            THROW 52113, 'Pricing function must return exactly one price per product.', 1;
        INSERT dbo.SalesOrderItem (order_id, product_id, parent_order_item_id, item_role, quantity, unit_price, promotion_id)
        SELECT @order_id, cc.child_product_id, parent.order_item_id, 'COMPONENT',
               parent.quantity * cc.quantity, 0.00, NULL
        FROM @parents AS parent
        JOIN dbo.Product AS p ON p.product_id = parent.product_id AND p.product_type = 'COMBO'
        JOIN dbo.ComboComponent AS cc ON cc.combo_product_id = parent.product_id;
        DECLARE @total DECIMAL(38,2);
        SELECT @total = SUM(CONVERT(DECIMAL(20,2), quantity) * unit_price)
        FROM dbo.SalesOrderItem WHERE order_id = @order_id AND item_role = 'SELLABLE';
        IF @total IS NULL OR @total < 0 OR @total > 99999999.99
            THROW 52114, 'Order amount is outside the supported monetary range.', 1;
        -- v1.1: use A's order-level function once, then distribute the rounded cents.
        -- The procedure body is bound on execution, after 21a creates the function.
        DECLARE @rate DECIMAL(5,4), @discount DECIMAL(10,2), @gross DECIMAL(10,2) = CONVERT(DECIMAL(10,2), @total);
        SELECT @rate = discount_rate, @discount = discount_amount
        FROM dbo.fn_calculate_discount(@customer_id, @gross, NULL);
        IF @rate IS NULL OR @discount IS NULL OR @rate NOT BETWEEN 0.9000 AND 1.0000
           OR @discount NOT BETWEEN 0 AND @gross
            THROW 54203, 'Invalid discount result.', 1;

        IF @gross > 0
        BEGIN
            DECLARE @split TABLE (item_id BIGINT PRIMARY KEY, gross DECIMAL(10,2), share DECIMAL(10,2));
            INSERT @split
            SELECT order_item_id, line.gross, ROUND(@discount * line.gross / @gross, 2)
            FROM dbo.SalesOrderItem
            CROSS APPLY (VALUES (CONVERT(DECIMAL(10,2), ROUND(unit_price * quantity, 2)))) line(gross)
            WHERE order_id = @order_id AND item_role = 'SELLABLE';

            DECLARE @residual DECIMAL(10,2) = @discount - (SELECT SUM(share) FROM @split);
            IF @residual <> 0
            BEGIN
                -- Largest line takes the residual first. If that would take its
                -- share outside [0, gross], use remaining capacity in the same order.
                ;WITH capacity AS (
                    SELECT item_id, gross,
                           CASE WHEN @residual > 0 THEN gross - share ELSE share END AS available
                    FROM @split
                ), ranked AS (
                    SELECT item_id, available, CONVERT(DECIMAL(12,2), COALESCE(
                        SUM(available) OVER (
                            ORDER BY gross DESC, item_id ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
                        ), 0)) AS before_line
                    FROM capacity
                )
                UPDATE s SET share = share + SIGN(@residual) *
                    CASE WHEN ABS(@residual) <= r.before_line THEN 0
                         WHEN ABS(@residual) - r.before_line >= r.available THEN r.available
                         ELSE ABS(@residual) - r.before_line END
                FROM @split s JOIN ranked r ON r.item_id = s.item_id;
            END
            UPDATE i SET discount_rate = @rate, discount_amount = s.share
            FROM dbo.SalesOrderItem i JOIN @split s ON s.item_id = i.order_item_id;
        END
        ELSE
            UPDATE dbo.SalesOrderItem SET discount_rate = @rate, discount_amount = 0
            WHERE order_id = @order_id AND item_role = 'SELLABLE';
        SET @total = @gross - @discount;
        UPDATE dbo.SalesOrder SET total_amount = CONVERT(DECIMAL(10,2), @total), updated_at = SYSDATETIME()
        WHERE order_id = @order_id;
        EXEC dbo.sp_lock_order_inventory @order_id = @order_id;

        IF @entry_trancount = 0 COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @entry_trancount = 0 AND XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        ELSE IF @entry_trancount > 0 AND XACT_STATE() = 1
            ROLLBACK TRANSACTION B_create_order;
        -- XACT_STATE() = -1 belongs to the caller: only a full rollback is legal.
        THROW;
    END CATCH;
END;
GO

-- v1.1: a reservation alone is insufficient when the sellable details are missing.
ALTER PROCEDURE dbo.sp_finish_production
    @order_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET ANSI_NULLS ON;
    SET ANSI_PADDING ON;
    SET ANSI_WARNINGS ON;
    SET ARITHABORT ON;
    SET CONCAT_NULL_YIELDS_NULL ON;
    SET QUOTED_IDENTIFIER ON;
    SET NUMERIC_ROUNDABORT OFF;
    DECLARE @entry_trancount INT = @@TRANCOUNT, @actor_id BIGINT;
    BEGIN TRY
        IF @entry_trancount = 0 BEGIN TRANSACTION;
        ELSE SAVE TRANSACTION B_finish_production;
        SELECT @actor_id = employee_id
        FROM dbo.EmployeeAccount WITH (HOLDLOCK)
        WHERE database_user_name = USER_NAME() AND status = 'ACTIVE' AND job_code = 'PACKER';
        IF @actor_id IS NULL
            THROW 52100, 'This operation requires the current active PACKER employee.', 1;

        DECLARE @status VARCHAR(20), @method VARCHAR(20), @now DATETIME2(0) = SYSDATETIME();
        SELECT @status = order_status, @method = fulfillment_method
        FROM dbo.SalesOrder WITH (UPDLOCK, HOLDLOCK) WHERE order_id = @order_id;
        IF @status IS NULL OR @status <> 'IN_PRODUCTION'
            THROW 52401, 'Only an IN_PRODUCTION order can finish production.', 1;
        IF NOT EXISTS (
            SELECT 1 FROM dbo.SalesOrderItem WITH (HOLDLOCK)
            WHERE order_id = @order_id AND item_role = 'SELLABLE'
        )
            THROW 52402, 'The order must contain a sellable line before production can finish.', 1;
        EXEC dbo.sp_consume_order_inventory @order_id = @order_id;
        UPDATE dbo.SalesOrder SET order_status = CASE WHEN @method = 'PICKUP' THEN 'READY_FOR_PICKUP' ELSE 'READY_FOR_DELIVERY' END,
            production_finished_at = @now, updated_at = @now WHERE order_id = @order_id;
        IF @method = 'DELIVERY'
            INSERT dbo.Delivery (order_id, delivery_status) VALUES (@order_id, 'WAITING_PICKUP');

        IF @entry_trancount = 0 COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @entry_trancount = 0 AND XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        ELSE IF @entry_trancount > 0 AND XACT_STATE() = 1
            ROLLBACK TRANSACTION B_finish_production;
        -- XACT_STATE() = -1 belongs to the caller: only a full rollback is legal.
        THROW;
    END CATCH;
END;
GO

ALTER PROCEDURE dbo.sp_customer_place_order
    @mobile VARCHAR(20), @items_json NVARCHAR(MAX), @fulfillment_method VARCHAR(20) = 'PICKUP',
    @pickup_code VARCHAR(20) = NULL, @order_no VARCHAR(50) = NULL, @ordered_at DATETIME2(0) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET ANSI_NULLS ON;
    SET ANSI_PADDING ON;
    SET ANSI_WARNINGS ON;
    SET ARITHABORT ON;
    SET CONCAT_NULL_YIELDS_NULL ON;
    SET QUOTED_IDENTIFIER ON;
    SET NUMERIC_ROUNDABORT OFF;
    DECLARE @entry_trancount INT = @@TRANCOUNT, @customer_id BIGINT, @customer_status VARCHAR(20);
    SET @mobile = LTRIM(RTRIM(@mobile));
    IF @mobile IS NULL OR LEN(@mobile) <> 11 OR @mobile COLLATE Latin1_General_100_BIN2 LIKE '%[^0-9]%'
       OR @fulfillment_method IS NULL OR @fulfillment_method COLLATE Latin1_General_100_BIN2 <> 'PICKUP'
       OR @order_no IS NOT NULL OR @pickup_code IS NOT NULL OR @ordered_at IS NOT NULL
        THROW 53000, 'Invalid customer order parameters.', 1;
    BEGIN TRY
        IF @entry_trancount = 0 BEGIN TRANSACTION;
        ELSE SAVE TRANSACTION B_guest_order;
        SELECT @customer_id = customer_id, @customer_status = status
        FROM dbo.Customer WITH (HOLDLOCK) WHERE mobile = @mobile;
        IF @customer_id IS NULL THROW 53001, 'Customer is not registered.', 1;
        IF @customer_status <> 'ACTIVE' THROW 53002, 'Customer is inactive.', 1;

        IF ISJSON(@items_json) <> 1 OR @items_json IS NULL
            THROW 52104, 'items_json must be a JSON array.', 1;
        -- Strip every JSON whitespace character before inspecting the root token.
        IF LEFT(LTRIM(REPLACE(REPLACE(REPLACE(@items_json, NCHAR(9), N' '), NCHAR(10), N' '), NCHAR(13), N' ')), 1) <> N'['
            THROW 52104, 'items_json must be a JSON array.', 1;
        IF NOT EXISTS (SELECT 1 FROM OPENJSON(@items_json))
           OR EXISTS (SELECT 1 FROM OPENJSON(@items_json) WHERE type <> 5)
            THROW 52105, 'A nonempty array of product objects is required.', 1;
        -- Whitelist exactly two numeric integer fields; reject duplicate JSON keys,
        -- item_role/parent IDs, submitted prices and caller-authored components.
        IF EXISTS (
            SELECT 1 FROM OPENJSON(@items_json) AS item
            CROSS APPLY OPENJSON(item.value) AS field
            WHERE field.[key] COLLATE Latin1_General_100_BIN2 NOT IN (N'product_id',N'quantity')
               OR field.type <> 2
               OR field.value COLLATE Latin1_General_100_BIN2 LIKE N'%[^0-9]%'
        ) OR EXISTS (
            SELECT 1 FROM OPENJSON(@items_json) AS item
            WHERE (SELECT COUNT(*) FROM OPENJSON(item.value)) <> 2
               OR (SELECT COUNT(*) FROM OPENJSON(item.value) WHERE [key] COLLATE Latin1_General_100_BIN2 = N'product_id') <> 1
               OR (SELECT COUNT(*) FROM OPENJSON(item.value) WHERE [key] COLLATE Latin1_General_100_BIN2 = N'quantity') <> 1
        )
            THROW 52106, 'Each item must contain only integer product_id and quantity.', 1;
        DECLARE @items TABLE (product_id BIGINT NULL, quantity INT NULL);
        INSERT @items (product_id, quantity)
        SELECT TRY_CONVERT(BIGINT, JSON_VALUE(value, '$.product_id')),
               TRY_CONVERT(INT, JSON_VALUE(value, '$.quantity'))
        FROM OPENJSON(@items_json);
        IF EXISTS (SELECT 1 FROM @items WHERE product_id IS NULL OR product_id <= 0 OR quantity IS NULL OR quantity <= 0)
            THROW 52107, 'Product IDs and quantities must be positive and within range.', 1;
        IF EXISTS (SELECT product_id FROM @items GROUP BY product_id HAVING COUNT(*) > 1)
            THROW 52108, 'Duplicate top-level products are not permitted.', 1;
        IF EXISTS (
            SELECT 1 FROM @items AS i LEFT JOIN dbo.Product AS p WITH (HOLDLOCK) ON p.product_id = i.product_id
            WHERE p.product_id IS NULL OR p.status IS NULL OR p.status <> 'ACTIVE'
               OR p.product_type IS NULL OR p.product_type NOT IN ('SINGLE','COMBO')
        )
            THROW 52109, 'Every product must exist and be active with a valid type.', 1;
        IF EXISTS (
            SELECT 1 FROM @items AS parent
            JOIN dbo.ComboComponent AS cc WITH (HOLDLOCK) ON cc.combo_product_id = parent.product_id
            JOIN @items AS child ON child.product_id = cc.child_product_id
        )
            THROW 52110, 'Submit only the combo parent, never its child in the same payload.', 1;
        IF EXISTS (
            SELECT 1 FROM @items AS i JOIN dbo.Product AS p WITH (HOLDLOCK) ON p.product_id = i.product_id
            WHERE (p.product_type = 'SINGLE' AND NOT EXISTS (
                SELECT 1 FROM dbo.ProductBom AS b WITH (HOLDLOCK) WHERE b.product_id = p.product_id))
               OR (p.product_type = 'COMBO' AND NOT EXISTS (
                SELECT 1 FROM dbo.ComboComponent AS cc WITH (HOLDLOCK) WHERE cc.combo_product_id = p.product_id))
        )
            THROW 52111, 'Single products need BOMs and combos need components.', 1;
        IF EXISTS (
            SELECT 1 FROM @items AS i
            JOIN dbo.Product AS parent WITH (HOLDLOCK) ON parent.product_id = i.product_id AND parent.product_type = 'COMBO'
            JOIN dbo.ComboComponent AS cc WITH (HOLDLOCK) ON cc.combo_product_id = i.product_id
            LEFT JOIN dbo.Product AS child WITH (HOLDLOCK) ON child.product_id = cc.child_product_id
            WHERE cc.quantity IS NULL OR cc.quantity <= 0
               OR CONVERT(BIGINT, i.quantity) * cc.quantity > 2147483647
               OR child.product_id IS NULL OR child.status IS NULL OR child.status <> 'ACTIVE'
               OR child.product_type IS NULL OR child.product_type <> 'SINGLE'
               OR NOT EXISTS (SELECT 1 FROM dbo.ProductBom AS b WITH (HOLDLOCK) WHERE b.product_id = child.product_id)
        )
            THROW 52112, 'Combo children must be active SINGLE products with BOM and valid quantities.', 1;

        DECLARE @effective_at DATETIME2(0) = SYSDATETIME(), @order_id BIGINT;
        SET @order_no = UPPER(REPLACE(CONVERT(VARCHAR(36), NEWID()), '-', ''));
        SET @pickup_code = UPPER(LEFT(REPLACE(CONVERT(VARCHAR(36), NEWID()), '-', ''), 20));
        INSERT dbo.SalesOrder (order_no, customer_id, fulfillment_method, pickup_code, ordered_at)
        VALUES (@order_no, @customer_id, @fulfillment_method, @pickup_code, @effective_at);
        SET @order_id = CONVERT(BIGINT, SCOPE_IDENTITY());
        DECLARE @parents TABLE (order_item_id BIGINT NOT NULL, product_id BIGINT NOT NULL, quantity INT NOT NULL);
        INSERT dbo.SalesOrderItem (order_id, product_id, parent_order_item_id, item_role, quantity, unit_price, promotion_id)
        OUTPUT inserted.order_item_id, inserted.product_id, inserted.quantity INTO @parents
        SELECT @order_id, i.product_id, NULL, 'SELLABLE', i.quantity, price.effective_price, price.promotion_id
        FROM @items AS i
        CROSS APPLY dbo.fn_get_effective_product_price(i.product_id, @effective_at) AS price;
        IF (SELECT COUNT(*) FROM @parents) <> (SELECT COUNT(*) FROM @items)
            THROW 52113, 'Pricing function must return exactly one price per product.', 1;
        INSERT dbo.SalesOrderItem (order_id, product_id, parent_order_item_id, item_role, quantity, unit_price, promotion_id)
        SELECT @order_id, cc.child_product_id, parent.order_item_id, 'COMPONENT',
               parent.quantity * cc.quantity, 0.00, NULL
        FROM @parents AS parent
        JOIN dbo.Product AS p ON p.product_id = parent.product_id AND p.product_type = 'COMBO'
        JOIN dbo.ComboComponent AS cc ON cc.combo_product_id = parent.product_id;
        DECLARE @total DECIMAL(38,2);
        SELECT @total = SUM(CONVERT(DECIMAL(20,2), quantity) * unit_price)
        FROM dbo.SalesOrderItem WHERE order_id = @order_id AND item_role = 'SELLABLE';
        IF @total IS NULL OR @total < 0 OR @total > 99999999.99
            THROW 52114, 'Order amount is outside the supported monetary range.', 1;
        -- v1.1: use A's order-level function once, then distribute the rounded cents.
        -- The procedure body is bound on execution, after 21a creates the function.
        DECLARE @rate DECIMAL(5,4), @discount DECIMAL(10,2), @gross DECIMAL(10,2) = CONVERT(DECIMAL(10,2), @total);
        SELECT @rate = discount_rate, @discount = discount_amount
        FROM dbo.fn_calculate_discount(@customer_id, @gross, NULL);
        IF @rate IS NULL OR @discount IS NULL OR @rate NOT BETWEEN 0.9000 AND 1.0000
           OR @discount NOT BETWEEN 0 AND @gross
            THROW 54203, 'Invalid discount result.', 1;

        IF @gross > 0
        BEGIN
            DECLARE @split TABLE (item_id BIGINT PRIMARY KEY, gross DECIMAL(10,2), share DECIMAL(10,2));
            INSERT @split
            SELECT order_item_id, line.gross, ROUND(@discount * line.gross / @gross, 2)
            FROM dbo.SalesOrderItem
            CROSS APPLY (VALUES (CONVERT(DECIMAL(10,2), ROUND(unit_price * quantity, 2)))) line(gross)
            WHERE order_id = @order_id AND item_role = 'SELLABLE';

            DECLARE @residual DECIMAL(10,2) = @discount - (SELECT SUM(share) FROM @split);
            IF @residual <> 0
            BEGIN
                -- Largest line takes the residual first. If that would take its
                -- share outside [0, gross], use remaining capacity in the same order.
                ;WITH capacity AS (
                    SELECT item_id, gross,
                           CASE WHEN @residual > 0 THEN gross - share ELSE share END AS available
                    FROM @split
                ), ranked AS (
                    SELECT item_id, available, CONVERT(DECIMAL(12,2), COALESCE(
                        SUM(available) OVER (
                            ORDER BY gross DESC, item_id ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
                        ), 0)) AS before_line
                    FROM capacity
                )
                UPDATE s SET share = share + SIGN(@residual) *
                    CASE WHEN ABS(@residual) <= r.before_line THEN 0
                         WHEN ABS(@residual) - r.before_line >= r.available THEN r.available
                         ELSE ABS(@residual) - r.before_line END
                FROM @split s JOIN ranked r ON r.item_id = s.item_id;
            END
            UPDATE i SET discount_rate = @rate, discount_amount = s.share
            FROM dbo.SalesOrderItem i JOIN @split s ON s.item_id = i.order_item_id;
        END
        ELSE
            UPDATE dbo.SalesOrderItem SET discount_rate = @rate, discount_amount = 0
            WHERE order_id = @order_id AND item_role = 'SELLABLE';
        SET @total = @gross - @discount;
        UPDATE dbo.SalesOrder SET total_amount = CONVERT(DECIMAL(10,2), @total), updated_at = SYSDATETIME()
        WHERE order_id = @order_id;
        EXEC dbo.sp_lock_order_inventory @order_id = @order_id;

        IF @entry_trancount = 0 COMMIT TRANSACTION;
        SELECT @order_id AS order_id, @order_no AS order_no, @pickup_code AS pickup_code,
            CONVERT(DECIMAL(10,2), @total) AS total_amount, CONVERT(VARCHAR(20), 'PENDING_PAYMENT') AS order_status;
    END TRY
    BEGIN CATCH
        IF @entry_trancount = 0 AND XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        ELSE IF @entry_trancount > 0 AND XACT_STATE() = 1
            ROLLBACK TRANSACTION B_guest_order;
        -- XACT_STATE() = -1 belongs to the caller: only a full rollback is legal.
        THROW;
    END CATCH;
END;
GO
