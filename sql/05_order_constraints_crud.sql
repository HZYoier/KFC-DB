/*
 B constraints and business entry points. SQL Server 2016+ / compatibility >= 130.
 Run with sqlcmd -b: a failed prerequisite must stop subsequent GO batches.
 Install 01/02/03 and A's pricing function first; C helper procedures may be
 installed by 06 afterwards (deferred procedure name resolution).
 All writes preserve the caller's transaction; a doomed caller transaction
 cannot roll back to a savepoint and MUST be rolled back by its owner.
*/
USE KFC_DB;
GO
SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET QUOTED_IDENTIFIER ON;
SET NUMERIC_ROUNDABORT OFF;
SET XACT_ABORT ON;
IF EXISTS (
    SELECT 1 FROM (VALUES
        (N'SalesOrder'), (N'SalesOrderItem'), (N'Payment'), (N'Delivery'), (N'PointLedger'),
        (N'Customer'), (N'Product'), (N'ProductBom'), (N'ComboComponent'), (N'Promotion'),
        (N'MemberLevel'), (N'EmployeeAccount')
    ) AS required(name)
    WHERE OBJECT_ID(N'dbo.' + required.name, N'U') IS NULL
)
    THROW 52002, 'Required A/B/C tables are missing; install schemas 01, 02, 03 first.', 1;
IF OBJECT_ID(N'dbo.fn_get_effective_product_price', N'IF') IS NULL
    THROW 52003, 'Install A inline pricing function before B procedures.', 1;
IF (SELECT compatibility_level FROM sys.databases WHERE database_id = DB_ID()) < 130
    THROW 52003, 'OPENJSON requires database compatibility level 130 or newer.', 1;
IF EXISTS (
    SELECT 1 FROM (VALUES
        (N'UQ_SalesOrder_order_no'),
        (N'CK_SalesOrder_order_status'),
        (N'CK_SalesOrder_fulfillment_method'),
        (N'CK_SalesOrder_total_amount'),
        (N'CK_SalesOrder_pickup_code'),
        (N'CK_SalesOrderItem_quantity'),
        (N'CK_SalesOrderItem_unit_price'),
        (N'CK_SalesOrderItem_item_role'),
        (N'UQ_Payment_order_id'),
        (N'CK_Payment_payment_status'),
        (N'CK_Payment_paid_amount'),
        (N'CK_Payment_refunded_amount'),
        (N'UQ_Delivery_order_id'),
        (N'CK_Delivery_delivery_status'),
        (N'UQ_PointLedger_order_id'),
        (N'CK_PointLedger_ledger_status'),
        (N'CK_PointLedger_point_delta'),
        (N'CK_PointLedger_snapshots'),
        (N'sp_create_order'),
        (N'sp_pay_order'),
        (N'sp_start_production'),
        (N'sp_finish_production'),
        (N'sp_pick_up_order'),
        (N'sp_pick_up_delivery'),
        (N'sp_confirm_delivery'),
        (N'sp_cancel_or_refund_order')
    ) AS planned(name)
    WHERE OBJECT_ID(N'dbo.' + planned.name) IS NOT NULL
) OR EXISTS (
    SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.SalesOrder')
    AND name = N'UQ_SalesOrder_pickup_code'
)
OR EXISTS (
    SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.SalesOrderItem')
    AND name = N'IX_SalesOrderItem_order_id'
)
    THROW 52004, 'B constraints or procedures already exist; use a reviewed migration.', 1;
BEGIN TRY
    BEGIN TRANSACTION;
    ALTER TABLE dbo.SalesOrder ADD CONSTRAINT UQ_SalesOrder_order_no UNIQUE (order_no);
    ALTER TABLE dbo.SalesOrder ADD CONSTRAINT CK_SalesOrder_order_status CHECK (order_status IN ('PENDING_PAYMENT','PAID','IN_PRODUCTION','READY_FOR_PICKUP','READY_FOR_DELIVERY','DELIVERING','PICKED_UP','COMPLETED','CANCELLED'));
    ALTER TABLE dbo.SalesOrder ADD CONSTRAINT CK_SalesOrder_fulfillment_method CHECK (fulfillment_method IN ('PICKUP','DELIVERY'));
    ALTER TABLE dbo.SalesOrder ADD CONSTRAINT CK_SalesOrder_total_amount CHECK (total_amount >= 0);
    ALTER TABLE dbo.SalesOrder ADD CONSTRAINT CK_SalesOrder_pickup_code CHECK ((fulfillment_method = 'PICKUP' AND pickup_code IS NOT NULL AND LEN(LTRIM(RTRIM(pickup_code))) > 0) OR (fulfillment_method = 'DELIVERY' AND pickup_code IS NULL));
    ALTER TABLE dbo.SalesOrderItem ADD CONSTRAINT CK_SalesOrderItem_quantity CHECK (quantity > 0);
    ALTER TABLE dbo.SalesOrderItem ADD CONSTRAINT CK_SalesOrderItem_unit_price CHECK (unit_price >= 0);
    ALTER TABLE dbo.SalesOrderItem ADD CONSTRAINT CK_SalesOrderItem_item_role CHECK ((item_role = 'SELLABLE' AND parent_order_item_id IS NULL) OR (item_role = 'COMPONENT' AND parent_order_item_id IS NOT NULL AND parent_order_item_id <> order_item_id AND unit_price = 0 AND promotion_id IS NULL));
    ALTER TABLE dbo.Payment ADD CONSTRAINT UQ_Payment_order_id UNIQUE (order_id);
    ALTER TABLE dbo.Payment ADD CONSTRAINT CK_Payment_payment_status CHECK (payment_status IN ('PENDING','SUCCESS','REFUNDED','VOIDED'));
    ALTER TABLE dbo.Payment ADD CONSTRAINT CK_Payment_paid_amount CHECK (paid_amount > 0);
    ALTER TABLE dbo.Payment ADD CONSTRAINT CK_Payment_refunded_amount CHECK (refunded_amount >= 0 AND refunded_amount <= paid_amount);
    ALTER TABLE dbo.Delivery ADD CONSTRAINT UQ_Delivery_order_id UNIQUE (order_id);
    ALTER TABLE dbo.Delivery ADD CONSTRAINT CK_Delivery_delivery_status CHECK (delivery_status IN ('WAITING_PICKUP','DELIVERING','DELIVERED'));
    ALTER TABLE dbo.PointLedger ADD CONSTRAINT UQ_PointLedger_order_id UNIQUE (order_id);
    ALTER TABLE dbo.PointLedger ADD CONSTRAINT CK_PointLedger_ledger_status CHECK (ledger_status IN ('PENDING','EFFECTIVE','VOIDED'));
    ALTER TABLE dbo.PointLedger ADD CONSTRAINT CK_PointLedger_point_delta CHECK (point_delta >= 0);
    ALTER TABLE dbo.PointLedger ADD CONSTRAINT CK_PointLedger_snapshots CHECK (paid_amount_snapshot > 0 AND point_multiplier_snapshot > 0);
    CREATE UNIQUE INDEX UQ_SalesOrder_pickup_code
        ON dbo.SalesOrder(pickup_code) WHERE pickup_code IS NOT NULL;
    CREATE INDEX IX_SalesOrderItem_order_id ON dbo.SalesOrderItem(order_id, item_role)
        INCLUDE (product_id, parent_order_item_id, quantity, unit_price);
    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
GO

SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET QUOTED_IDENTIFIER ON;
SET NUMERIC_ROUNDABORT OFF;
GO
CREATE PROCEDURE dbo.sp_create_order
    @customer_id BIGINT,
    @fulfillment_method VARCHAR(20),
    @order_no VARCHAR(40),
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

SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET QUOTED_IDENTIFIER ON;
SET NUMERIC_ROUNDABORT OFF;
GO
CREATE PROCEDURE dbo.sp_pay_order
    @order_id BIGINT,
    @payment_method VARCHAR(20),
    @paid_amount DECIMAL(10,2),
    @third_party_txn_no VARCHAR(100)
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
        ELSE SAVE TRANSACTION B_pay_order;
        SELECT @actor_id = employee_id
        FROM dbo.EmployeeAccount WITH (HOLDLOCK)
        WHERE database_user_name = USER_NAME() AND status = 'ACTIVE' AND job_code = 'CASHIER';
        IF @actor_id IS NULL
            THROW 52100, 'This operation requires the current active CASHIER employee.', 1;

        DECLARE @status VARCHAR(20), @total DECIMAL(10,2), @customer_id BIGINT;
        SELECT @status = order_status, @total = total_amount, @customer_id = customer_id
        FROM dbo.SalesOrder WITH (UPDLOCK, HOLDLOCK) WHERE order_id = @order_id;
        IF @status IS NULL OR @status <> 'PENDING_PAYMENT'
            THROW 52201, 'Only a pending-payment order can be paid.', 1;
        IF @paid_amount IS NULL OR @paid_amount <= 0 OR @paid_amount <> @total
            THROW 52202, 'Payment must equal the positive order total.', 1;
        IF NULLIF(LTRIM(RTRIM(@payment_method)), '') IS NULL
            THROW 52203, 'Payment method is required.', 1;
        IF EXISTS (SELECT 1 FROM dbo.Payment WITH (UPDLOCK, HOLDLOCK) WHERE order_id = @order_id)
            THROW 52204, 'An order may have only one payment.', 1;
        DECLARE @multiplier DECIMAL(5,2), @points DECIMAL(20,0), @now DATETIME2(0) = SYSDATETIME();
        SELECT @multiplier = ml.point_multiplier
        FROM dbo.Customer AS c WITH (UPDLOCK, HOLDLOCK)
        JOIN dbo.MemberLevel AS ml WITH (HOLDLOCK) ON ml.member_level_id = c.member_level_id
        WHERE c.customer_id = @customer_id AND c.status = 'ACTIVE' AND ml.status = 'ACTIVE';
        IF @multiplier IS NULL OR @multiplier <= 0
            THROW 52205, 'Customer needs a current active member level with a positive multiplier.', 1;
        SET @points = FLOOR(@paid_amount * @multiplier);
        IF @points > 2147483647
            THROW 52206, 'Calculated points exceed the supported integer range.', 1;
        INSERT dbo.Payment (order_id, payment_method, paid_amount, payment_status, paid_at, third_party_txn_no)
        VALUES (@order_id, @payment_method, @paid_amount, 'SUCCESS', @now, @third_party_txn_no);
        UPDATE dbo.SalesOrder SET order_status = 'PAID', paid_at = @now, updated_at = @now WHERE order_id = @order_id;
        INSERT dbo.PointLedger (order_id, customer_id, paid_amount_snapshot, point_multiplier_snapshot, point_delta, ledger_status, created_at)
        VALUES (@order_id, @customer_id, @paid_amount, @multiplier, CONVERT(INT, @points), 'PENDING', @now);

        IF @entry_trancount = 0 COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @entry_trancount = 0 AND XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        ELSE IF @entry_trancount > 0 AND XACT_STATE() = 1
            ROLLBACK TRANSACTION B_pay_order;
        -- XACT_STATE() = -1 belongs to the caller: only a full rollback is legal.
        THROW;
    END CATCH;
END;
GO

SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET QUOTED_IDENTIFIER ON;
SET NUMERIC_ROUNDABORT OFF;
GO
CREATE PROCEDURE dbo.sp_start_production
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
        ELSE SAVE TRANSACTION B_start_production;
        SELECT @actor_id = employee_id
        FROM dbo.EmployeeAccount WITH (HOLDLOCK)
        WHERE database_user_name = USER_NAME() AND status = 'ACTIVE' AND job_code = 'CHEF';
        IF @actor_id IS NULL
            THROW 52100, 'This operation requires the current active CHEF employee.', 1;

        DECLARE @status VARCHAR(20), @now DATETIME2(0) = SYSDATETIME();
        SELECT @status = order_status FROM dbo.SalesOrder WITH (UPDLOCK, HOLDLOCK) WHERE order_id = @order_id;
        IF @status IS NULL OR @status <> 'PAID'
            THROW 52301, 'Only a PAID order can start production.', 1;
        UPDATE dbo.SalesOrder SET order_status = 'IN_PRODUCTION', production_started_at = @now, updated_at = @now
        WHERE order_id = @order_id;

        IF @entry_trancount = 0 COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @entry_trancount = 0 AND XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        ELSE IF @entry_trancount > 0 AND XACT_STATE() = 1
            ROLLBACK TRANSACTION B_start_production;
        -- XACT_STATE() = -1 belongs to the caller: only a full rollback is legal.
        THROW;
    END CATCH;
END;
GO

SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET QUOTED_IDENTIFIER ON;
SET NUMERIC_ROUNDABORT OFF;
GO
CREATE PROCEDURE dbo.sp_finish_production
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

SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET QUOTED_IDENTIFIER ON;
SET NUMERIC_ROUNDABORT OFF;
GO
CREATE PROCEDURE dbo.sp_pick_up_order
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
        ELSE SAVE TRANSACTION B_pick_up_order;
        SELECT @actor_id = employee_id
        FROM dbo.EmployeeAccount WITH (HOLDLOCK)
        WHERE database_user_name = USER_NAME() AND status = 'ACTIVE' AND job_code = 'PACKER';
        IF @actor_id IS NULL
            THROW 52100, 'This operation requires the current active PACKER employee.', 1;

        DECLARE @status VARCHAR(20), @method VARCHAR(20), @now DATETIME2(0) = SYSDATETIME();
        SELECT @status = order_status, @method = fulfillment_method
        FROM dbo.SalesOrder WITH (UPDLOCK, HOLDLOCK) WHERE order_id = @order_id;
        IF @status IS NULL OR @status <> 'READY_FOR_PICKUP' OR @method <> 'PICKUP'
            THROW 52501, 'Only a READY_FOR_PICKUP pickup order can be collected.', 1;
        UPDATE dbo.SalesOrder SET order_status = 'PICKED_UP', completed_at = @now, updated_at = @now WHERE order_id = @order_id;

        DECLARE @customer_id BIGINT, @delta INT, @ledger_status VARCHAR(20);
        SELECT @customer_id = customer_id, @delta = point_delta, @ledger_status = ledger_status
        FROM dbo.PointLedger WITH (UPDLOCK, HOLDLOCK) WHERE order_id = @order_id;
        IF @ledger_status IS NULL OR @ledger_status <> 'PENDING'
            THROW 52502, 'Exactly one PENDING points ledger is required for completion.', 1;
        UPDATE dbo.PointLedger SET ledger_status = 'EFFECTIVE', effective_at = @now WHERE order_id = @order_id;
        EXEC dbo.sp_apply_customer_points @customer_id = @customer_id, @delta = @delta;

        IF @entry_trancount = 0 COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @entry_trancount = 0 AND XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        ELSE IF @entry_trancount > 0 AND XACT_STATE() = 1
            ROLLBACK TRANSACTION B_pick_up_order;
        -- XACT_STATE() = -1 belongs to the caller: only a full rollback is legal.
        THROW;
    END CATCH;
END;
GO

SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET QUOTED_IDENTIFIER ON;
SET NUMERIC_ROUNDABORT OFF;
GO
CREATE PROCEDURE dbo.sp_pick_up_delivery
    @order_id BIGINT,
    @rider_employee_id BIGINT
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
        ELSE SAVE TRANSACTION B_pick_up_delivery;
        SELECT @actor_id = employee_id
        FROM dbo.EmployeeAccount WITH (HOLDLOCK)
        WHERE database_user_name = USER_NAME() AND status = 'ACTIVE' AND job_code = 'RIDER';
        IF @actor_id IS NULL
            THROW 52100, 'This operation requires the current active RIDER employee.', 1;

        IF @rider_employee_id IS NULL OR @rider_employee_id <> @actor_id
            THROW 52601, 'Rider parameter must identify the current active rider.', 1;
        DECLARE @status VARCHAR(20), @method VARCHAR(20), @delivery_status VARCHAR(20), @assigned_rider BIGINT, @now DATETIME2(0) = SYSDATETIME();
        SELECT @status = order_status, @method = fulfillment_method
        FROM dbo.SalesOrder WITH (UPDLOCK, HOLDLOCK) WHERE order_id = @order_id;
        IF @status IS NULL OR @status <> 'READY_FOR_DELIVERY' OR @method <> 'DELIVERY'
            THROW 52602, 'Order must be READY_FOR_DELIVERY.', 1;
        SELECT @delivery_status = delivery_status, @assigned_rider = rider_employee_id
        FROM dbo.Delivery WITH (UPDLOCK, HOLDLOCK) WHERE order_id = @order_id;
        IF @delivery_status IS NULL OR @delivery_status <> 'WAITING_PICKUP' OR @assigned_rider IS NOT NULL
            THROW 52603, 'Delivery must be unassigned and WAITING_PICKUP.', 1;
        UPDATE dbo.Delivery SET rider_employee_id = @actor_id, delivery_status = 'DELIVERING',
            picked_up_at = @now, updated_at = @now WHERE order_id = @order_id;
        UPDATE dbo.SalesOrder SET order_status = 'DELIVERING', updated_at = @now WHERE order_id = @order_id;

        IF @entry_trancount = 0 COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @entry_trancount = 0 AND XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        ELSE IF @entry_trancount > 0 AND XACT_STATE() = 1
            ROLLBACK TRANSACTION B_pick_up_delivery;
        -- XACT_STATE() = -1 belongs to the caller: only a full rollback is legal.
        THROW;
    END CATCH;
END;
GO

SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET QUOTED_IDENTIFIER ON;
SET NUMERIC_ROUNDABORT OFF;
GO
CREATE PROCEDURE dbo.sp_confirm_delivery
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
        ELSE SAVE TRANSACTION B_confirm_delivery;
        SELECT @actor_id = employee_id
        FROM dbo.EmployeeAccount WITH (HOLDLOCK)
        WHERE database_user_name = USER_NAME() AND status = 'ACTIVE' AND job_code = 'RIDER';
        IF @actor_id IS NULL
            THROW 52100, 'This operation requires the current active RIDER employee.', 1;

        DECLARE @status VARCHAR(20), @method VARCHAR(20), @delivery_status VARCHAR(20), @assigned_rider BIGINT, @now DATETIME2(0) = SYSDATETIME();
        SELECT @status = order_status, @method = fulfillment_method
        FROM dbo.SalesOrder WITH (UPDLOCK, HOLDLOCK) WHERE order_id = @order_id;
        IF @status IS NULL OR @status <> 'DELIVERING' OR @method <> 'DELIVERY'
            THROW 52701, 'Order must be DELIVERING.', 1;
        SELECT @delivery_status = delivery_status, @assigned_rider = rider_employee_id
        FROM dbo.Delivery WITH (UPDLOCK, HOLDLOCK) WHERE order_id = @order_id;
        IF @delivery_status IS NULL OR @delivery_status <> 'DELIVERING'
           OR @assigned_rider IS NULL OR @assigned_rider <> @actor_id
            THROW 52702, 'Only the assigned active rider can complete this delivery.', 1;
        UPDATE dbo.Delivery SET delivery_status = 'DELIVERED', delivered_at = @now, updated_at = @now WHERE order_id = @order_id;
        UPDATE dbo.SalesOrder SET order_status = 'COMPLETED', completed_at = @now, updated_at = @now WHERE order_id = @order_id;

        DECLARE @customer_id BIGINT, @delta INT, @ledger_status VARCHAR(20);
        SELECT @customer_id = customer_id, @delta = point_delta, @ledger_status = ledger_status
        FROM dbo.PointLedger WITH (UPDLOCK, HOLDLOCK) WHERE order_id = @order_id;
        IF @ledger_status IS NULL OR @ledger_status <> 'PENDING'
            THROW 52502, 'Exactly one PENDING points ledger is required for completion.', 1;
        UPDATE dbo.PointLedger SET ledger_status = 'EFFECTIVE', effective_at = @now WHERE order_id = @order_id;
        EXEC dbo.sp_apply_customer_points @customer_id = @customer_id, @delta = @delta;

        IF @entry_trancount = 0 COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @entry_trancount = 0 AND XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        ELSE IF @entry_trancount > 0 AND XACT_STATE() = 1
            ROLLBACK TRANSACTION B_confirm_delivery;
        -- XACT_STATE() = -1 belongs to the caller: only a full rollback is legal.
        THROW;
    END CATCH;
END;
GO

SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET QUOTED_IDENTIFIER ON;
SET NUMERIC_ROUNDABORT OFF;
GO
CREATE PROCEDURE dbo.sp_cancel_or_refund_order
    @order_id BIGINT,
    @reason VARCHAR(20),
    @operator_employee_id BIGINT
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
        ELSE SAVE TRANSACTION B_cancel_or_refund_order;
        SELECT @actor_id = employee_id
        FROM dbo.EmployeeAccount WITH (HOLDLOCK)
        WHERE database_user_name = USER_NAME() AND status = 'ACTIVE' AND job_code = 'STORE_MANAGER';
        IF @actor_id IS NULL
            THROW 52100, 'This operation requires the current active STORE_MANAGER employee.', 1;

        IF @operator_employee_id IS NULL OR @operator_employee_id <> @actor_id
            THROW 52801, 'Operator parameter must identify the current active store manager.', 1;
        DECLARE @status VARCHAR(20), @total DECIMAL(10,2), @finished_at DATETIME2(0),
                @refund DECIMAL(10,2) = 0, @ledger_status VARCHAR(20), @now DATETIME2(0) = SYSDATETIME();
        SELECT @status = order_status, @total = total_amount, @finished_at = production_finished_at
        FROM dbo.SalesOrder WITH (UPDLOCK, HOLDLOCK) WHERE order_id = @order_id;
        IF @status IS NULL OR @status NOT IN ('PENDING_PAYMENT','PAID','IN_PRODUCTION') OR @finished_at IS NOT NULL
            THROW 52802, 'Only unpaid cancellation or full refund before inventory consumption is supported.', 1;
        IF @reason IS NULL
           OR (@status = 'PENDING_PAYMENT' AND @reason NOT IN ('CANCEL','PAYMENT_TIMEOUT'))
           OR (@status IN ('PAID','IN_PRODUCTION') AND @reason <> 'REFUND')
            THROW 52803, 'Reason must match unpaid cancellation or full pre-consume REFUND.', 1;
        IF @status = 'PENDING_PAYMENT'
        BEGIN
            IF EXISTS (SELECT 1 FROM dbo.Payment WITH (UPDLOCK, HOLDLOCK) WHERE order_id = @order_id)
                THROW 52804, 'Unpaid cancellation cannot have a payment.', 1;
        END
        ELSE
        BEGIN
            DECLARE @payment_status VARCHAR(20), @already_refunded DECIMAL(10,2);
            SELECT @refund = paid_amount, @payment_status = payment_status, @already_refunded = refunded_amount
            FROM dbo.Payment WITH (UPDLOCK, HOLDLOCK) WHERE order_id = @order_id;
            IF @payment_status IS NULL OR @payment_status <> 'SUCCESS' OR @already_refunded <> 0 OR @refund <> @total
                THROW 52805, 'Refund requires an untouched successful full payment; partial refunds are unsupported.', 1;
        END;
        SELECT @ledger_status = ledger_status FROM dbo.PointLedger WITH (UPDLOCK, HOLDLOCK) WHERE order_id = @order_id;
        IF (@status IN ('PAID','IN_PRODUCTION') AND (@ledger_status IS NULL OR @ledger_status <> 'PENDING'))
           OR (@ledger_status IS NOT NULL AND @ledger_status <> 'PENDING')
            THROW 52806, 'Only PENDING points can be voided by a refund or cancellation.', 1;
        -- C verifies that no inventory has been consumed, then releases locks.
        -- Any failure, including audit failure below, rolls back all B/C changes.
        EXEC dbo.sp_release_order_inventory @order_id = @order_id, @reason = @reason;
        UPDATE dbo.SalesOrder SET order_status = 'CANCELLED', cancelled_at = @now, updated_at = @now WHERE order_id = @order_id;
        IF @status IN ('PAID','IN_PRODUCTION')
            UPDATE dbo.Payment SET payment_status = 'REFUNDED', refunded_amount = @refund,
                refunded_at = @now, updated_at = @now WHERE order_id = @order_id;
        UPDATE dbo.PointLedger SET ledger_status = 'VOIDED' WHERE order_id = @order_id AND ledger_status = 'PENDING';
        IF @ledger_status IS NOT NULL SET @ledger_status = 'VOIDED';
        DECLARE @detail NVARCHAR(MAX);
        SET @detail = (SELECT @status AS order_status_before, 'CANCELLED' AS order_status_after,
            @reason AS reason, @refund AS refunded_amount, @ledger_status AS ledger_status
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES);
        EXEC dbo.sp_write_audit_log @employee_id = @actor_id, @action_name = 'CANCEL_OR_REFUND_ORDER',
            @entity_name = 'SalesOrder', @entity_id = @order_id, @detail_json = @detail;

        IF @entry_trancount = 0 COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @entry_trancount = 0 AND XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        ELSE IF @entry_trancount > 0 AND XACT_STATE() = 1
            ROLLBACK TRANSACTION B_cancel_or_refund_order;
        -- XACT_STATE() = -1 belongs to the caller: only a full rollback is legal.
        THROW;
    END CATCH;
END;
GO
