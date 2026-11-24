-- B domain regression. Run after v1.1 migration as deployer from a fresh session.
-- sqlcmd -S localhost -E -C -f 65001 -b -d KFC_DB -i sql/stage3/28b_stage3_regression.sql
-- 2 sales date errors + 5 completion trigger errors + 1 batch/settled view check.
-- All fixtures roll back. Use a migrated test copy to avoid identity gaps in live data.
:on error exit
USE KFC_DB;
GO
SET NOCOUNT ON;

IF @@TRANCOUNT <> 0 OR (@@OPTIONS & 2) <> 0
    THROW 54233, '28b requires a fresh session with no implicit or open transaction.', 1;
IF OBJECT_ID(N'dbo.SchemaVersion', N'U') IS NULL
    THROW 54233, '28b requires the v1.1 schema version table.', 1;
IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE version_code = N'v1.1')
   OR OBJECT_ID(N'dbo.v_settled_sales_line', N'V') IS NULL
   OR OBJECT_ID(N'dbo.sp_sales_report', N'P') IS NULL
   OR NOT EXISTS (SELECT 1 FROM sys.triggers WHERE name = N'tr_SalesOrder_Complete_Check'
                  AND parent_id = OBJECT_ID(N'dbo.SalesOrder') AND is_disabled = 0)
   OR COL_LENGTH(N'dbo.SalesOrderItem', N'discount_amount') IS NULL
    THROW 54233, '28b requires the v1.1 marker and active B sales/trigger objects.', 1;

SET XACT_ABORT ON;
DECLARE @pass INT = 0, @case INT = 1, @actual INT, @expected INT;
DECLARE @start DATE, @end DATE;
WHILE @case <= 2
BEGIN
    SET @expected = 54200 + @case;
    SELECT @start = CASE WHEN @case = 2 THEN CONVERT(DATE, '20261119', 112) END,
           @end = CONVERT(DATE, '20261118', 112), @actual = NULL;
    BEGIN TRY
        EXEC dbo.sp_sales_report @start, @end;
    END TRY
    BEGIN CATCH
        SET @actual = ERROR_NUMBER();
        IF @actual <> @expected THROW;
    END CATCH;
    IF @actual IS NULL THROW 54234, '28b sales report accepted an invalid date range.', 1;
    PRINT CONCAT(N'PASS 28b sales report date guard ', @actual);
    SET @pass += 1;
    SET @case += 1;
END;

DECLARE @customer BIGINT = (SELECT MIN(customer_id) FROM dbo.Customer),
        @stock_product BIGINT = (SELECT MIN(product_id) FROM dbo.ProductBom);
IF @customer IS NULL OR @stock_product IS NULL
    THROW 54233, '28b requires a customer and a stock-backed product from the migration fixture.', 1;

DECLARE @fixture VARCHAR(36), @product BIGINT, @order BIGINT, @other BIGINT, @item BIGINT,
        @finish DATETIME2(0) = '2099-01-01T23:59:59';
SET @case = 0;
WHILE @case <= 5
BEGIN
    SET @fixture = CONVERT(VARCHAR(36), NEWID());
    SELECT @actual = NULL, @expected = CASE WHEN @case > 0 THEN 54209 + @case END;
    BEGIN TRY
        BEGIN TRANSACTION;
        -- A no-BOM product isolates state/amount guards from stock validation.
        -- The missing-consumption case uses a stock-backed product instead.
        INSERT dbo.Product(product_name, base_price, product_type, status)
        VALUES (N'B28-' + @fixture, 10, 'SINGLE', 'INACTIVE');
        SET @product = CONVERT(BIGINT, SCOPE_IDENTITY());

        INSERT dbo.SalesOrder(order_no, customer_id, order_status, fulfillment_method, pickup_code, total_amount)
        VALUES ('B28-' + @fixture, @customer,
                CASE @case WHEN 1 THEN 'PICKED_UP' WHEN 2 THEN 'IN_PRODUCTION' ELSE 'READY_FOR_PICKUP' END,
                'PICKUP', LEFT(@fixture, 18) + '-A', CASE @case WHEN 4 THEN 19.01 ELSE 19.00 END);
        SET @order = CONVERT(BIGINT, SCOPE_IDENTITY());

        IF @case <> 3
        BEGIN
            INSERT dbo.SalesOrderItem(order_id, product_id, item_role, quantity, unit_price, discount_rate, discount_amount)
            VALUES (@order, CASE WHEN @case = 5 THEN @stock_product ELSE @product END, 'SELLABLE', 2, 10, 0.95, 1.00);
            SET @item = CONVERT(BIGINT, SCOPE_IDENTITY());
        END;

        IF @case = 0
        BEGIN
            INSERT dbo.SalesOrder(order_no, customer_id, order_status, fulfillment_method, pickup_code, total_amount)
            VALUES ('B28-' + @fixture + '-B', @customer, 'READY_FOR_PICKUP', 'PICKUP', LEFT(@fixture, 18) + '-B', 9.50);
            SET @other = CONVERT(BIGINT, SCOPE_IDENTITY());
            INSERT dbo.SalesOrderItem(order_id, product_id, item_role, quantity, unit_price, discount_rate, discount_amount)
            VALUES (@other, @product, 'SELLABLE', 1, 10, 0.95, 0.50);
            INSERT dbo.SalesOrderItem(order_id, product_id, parent_order_item_id, item_role, quantity, unit_price)
            VALUES (@order, @product, @item, 'COMPONENT', 2, 0);

            IF EXISTS (SELECT 1 FROM dbo.v_settled_sales_line WHERE order_id IN (@order, @other))
                THROW 54235, '28b settled view included unfinished orders.', 1;
            UPDATE dbo.SalesOrder SET order_status = 'PICKED_UP', completed_at = @finish WHERE order_id IN (@order, @other);
            IF (SELECT COUNT(*) FROM dbo.v_settled_sales_line WHERE order_id IN (@order, @other)) <> 2
               OR NOT EXISTS (SELECT 1 FROM dbo.v_settled_sales_line WHERE order_id = @order
                              AND quantity = 2 AND gross_amount = 20 AND discount_amount = 1 AND net_amount = 19)
               OR NOT EXISTS (SELECT 1 FROM dbo.v_settled_sales_line WHERE order_id = @other
                              AND quantity = 1 AND gross_amount = 10 AND discount_amount = 0.50 AND net_amount = 9.50)
                THROW 54235, '28b settled view did not return the two expected net sellable lines.', 1;
        END
        ELSE
            UPDATE dbo.SalesOrder SET order_status = 'PICKED_UP', completed_at = @finish WHERE order_id = @order;

        ROLLBACK TRANSACTION;
    END TRY
    BEGIN CATCH
        SET @actual = ERROR_NUMBER();
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        IF @expected IS NULL OR @actual <> @expected THROW;
    END CATCH;

    IF @expected IS NOT NULL AND @actual IS NULL
        THROW 54236, '28b completion trigger accepted an invalid update.', 1;
    IF @@TRANCOUNT <> 0 OR EXISTS (SELECT 1 FROM dbo.SalesOrder WHERE order_no IN ('B28-' + @fixture, 'B28-' + @fixture + '-B'))
       OR EXISTS (SELECT 1 FROM dbo.Product WHERE product_name = N'B28-' + @fixture)
        THROW 54237, '28b fixture was not rolled back.', 1;
    PRINT CASE WHEN @case = 0 THEN N'PASS 28b batch completion and settled net lines'
               ELSE CONCAT(N'PASS 28b completion trigger guard ', @actual) END;
    SET @pass += 1;
    SET @case += 1;
END;

IF @pass <> 8 THROW 54238, '28b pass count must be 8.', 1;
PRINT N'RESULT: stage3-b-regression suites=2 pass=8 fail=0';
GO
