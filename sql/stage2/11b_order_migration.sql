-- B migration: eight new procedures, no schema rewrites or role grants.
-- The migration caller owns the outer transaction. Business procedures execute later.
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.sp_list_orders_for_payment
    @take INT = 100
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @actor BIGINT = (SELECT employee_id FROM dbo.EmployeeAccount
        WHERE database_user_name = USER_NAME() AND status = 'ACTIVE' AND job_code = 'CASHIER');
    IF @actor IS NULL
        THROW 52100, 'This operation requires a current active employee in the required job.', 1;
    IF @take IS NULL OR @take NOT BETWEEN 1 AND 200
        THROW 52901, 'take must be between 1 and 200.', 1;
    SELECT TOP (@take) order_id, order_no, total_amount, ordered_at
    FROM dbo.SalesOrder WHERE order_status = 'PENDING_PAYMENT'
    ORDER BY ordered_at, order_id;
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_get_order_for_payment
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
    SELECT i.order_item_id, i.product_id, p.product_name, i.quantity, i.unit_price, i.promotion_id
    FROM @head h JOIN dbo.SalesOrderItem i ON i.order_id = h.order_id
    JOIN dbo.Product p ON p.product_id = i.product_id
    WHERE i.item_role = 'SELLABLE' ORDER BY i.order_item_id;
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_get_order_operation_status
    @order_id BIGINT = NULL, @order_no VARCHAR(50) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @actor BIGINT = (SELECT employee_id FROM dbo.EmployeeAccount
        WHERE database_user_name = USER_NAME() AND status = 'ACTIVE' AND job_code IN ('CASHIER','STORE_MANAGER'));
    IF @actor IS NULL
        THROW 52100, 'This operation requires a current active employee in the required job.', 1;
    IF (@order_id IS NULL AND @order_no IS NULL) OR (@order_id IS NOT NULL AND @order_no IS NOT NULL)
        OR @order_id <= 0
        OR (@order_no IS NOT NULL AND LEN(LTRIM(RTRIM(@order_no))) = 0)
        THROW 52902, 'Supply exactly one valid order locator.', 1;
    SELECT o.order_id, o.order_no, o.order_status, p.payment_status, p.paid_amount, p.refunded_amount,
        CONVERT(BIT, CASE WHEN o.order_status IN ('PICKED_UP','COMPLETED') THEN 1 ELSE 0 END) AS is_completed,
        o.pickup_code
    FROM dbo.SalesOrder o LEFT JOIN dbo.Payment p ON p.order_id = o.order_id
    WHERE o.order_id = @order_id OR o.order_no = @order_no;
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_list_orders_for_packing
    @take INT = 100
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @actor BIGINT = (SELECT employee_id FROM dbo.EmployeeAccount
        WHERE database_user_name = USER_NAME() AND status = 'ACTIVE' AND job_code = 'PACKER');
    IF @actor IS NULL
        THROW 52100, 'This operation requires a current active employee in the required job.', 1;
    IF @take IS NULL OR @take NOT BETWEEN 1 AND 200
        THROW 52901, 'take must be between 1 and 200.', 1;
    DECLARE @head TABLE (order_id BIGINT PRIMARY KEY, order_no VARCHAR(50) NOT NULL,
        order_status VARCHAR(20) NOT NULL, fulfillment_method VARCHAR(20) NOT NULL,
        pickup_code VARCHAR(20) NULL, ordered_at DATETIME2(0) NOT NULL);
    INSERT @head
    SELECT TOP (@take) order_id, order_no, order_status, fulfillment_method, pickup_code, ordered_at
    FROM dbo.SalesOrder WHERE order_status IN ('IN_PRODUCTION','READY_FOR_PICKUP')
    ORDER BY ordered_at, order_id;
    SELECT order_id, order_no, order_status, fulfillment_method, pickup_code
    FROM @head ORDER BY ordered_at, order_id;
    SELECT i.order_id, i.order_item_id, i.parent_order_item_id, i.item_role, i.product_id, p.product_name, i.quantity
    FROM @head h JOIN dbo.SalesOrderItem i ON i.order_id = h.order_id
    JOIN dbo.Product p ON p.product_id = i.product_id
    ORDER BY i.order_id, i.order_item_id;
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_list_my_deliveries
    @take INT = 100
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @actor BIGINT = (SELECT employee_id FROM dbo.EmployeeAccount
        WHERE database_user_name = USER_NAME() AND status = 'ACTIVE' AND job_code = 'RIDER');
    IF @actor IS NULL
        THROW 52100, 'This operation requires a current active employee in the required job.', 1;
    IF @take IS NULL OR @take NOT BETWEEN 1 AND 200
        THROW 52901, 'take must be between 1 and 200.', 1;
    SELECT TOP (@take) d.delivery_id, o.order_id, o.order_no, d.delivery_status, d.picked_up_at
    FROM dbo.Delivery d JOIN dbo.SalesOrder o ON o.order_id = d.order_id
    WHERE d.rider_employee_id = @actor AND d.delivery_status = 'DELIVERING'
    ORDER BY d.picked_up_at, d.delivery_id;
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_list_deliveries_available_for_pickup
    @take INT = 100
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @actor BIGINT = (SELECT employee_id FROM dbo.EmployeeAccount
        WHERE database_user_name = USER_NAME() AND status = 'ACTIVE' AND job_code = 'RIDER');
    IF @actor IS NULL
        THROW 52100, 'This operation requires a current active employee in the required job.', 1;
    IF @take IS NULL OR @take NOT BETWEEN 1 AND 200
        THROW 52901, 'take must be between 1 and 200.', 1;
    SELECT TOP (@take) d.delivery_id, o.order_id, o.order_no, o.production_finished_at
    FROM dbo.Delivery d JOIN dbo.SalesOrder o ON o.order_id = d.order_id
    WHERE o.order_status = 'READY_FOR_DELIVERY' AND d.delivery_status = 'WAITING_PICKUP'
        AND d.rider_employee_id IS NULL
    ORDER BY o.production_finished_at, o.order_id;
END;
GO

-- Same item validation and snapshot rules as stage 1 sp_create_order; no employee impersonation.
CREATE OR ALTER PROCEDURE dbo.sp_customer_place_order
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

CREATE OR ALTER PROCEDURE dbo.sp_customer_list_orders
    @mobile VARCHAR(20), @pickup_code VARCHAR(20)
AS
BEGIN
    SET NOCOUNT ON;
    SET @mobile = LTRIM(RTRIM(@mobile));
    SET @pickup_code = UPPER(LTRIM(RTRIM(@pickup_code)));
    IF @mobile IS NULL OR LEN(@mobile) <> 11 OR @mobile COLLATE Latin1_General_100_BIN2 LIKE '%[^0-9]%'
       OR @pickup_code IS NULL OR LEN(@pickup_code) <> 20 OR @pickup_code COLLATE Latin1_General_100_BIN2 LIKE '%[^0-9A-F]%'
        THROW 53000, 'A valid mobile number and pickup code are required.', 1;
    SELECT o.order_id, o.order_no, o.order_status, o.fulfillment_method, o.total_amount,
        o.ordered_at, o.pickup_code
    FROM dbo.SalesOrder o JOIN dbo.Customer c ON c.customer_id = o.customer_id
    WHERE c.mobile = @mobile AND c.status = 'ACTIVE' AND o.fulfillment_method = 'PICKUP'
        AND o.pickup_code = @pickup_code
    ORDER BY o.ordered_at DESC, o.order_id DESC;
END;
GO
