-- Transaction exercise. Run through tests/stage3/b_programmability/run_b_stage3.py.
-- The runner creates and removes a disposable migrated database. This script
-- commits test orders and stock consumption, so never run it on the business DB.
SET NOCOUNT ON;
SET XACT_ABORT ON;

IF LEN(DB_NAME()) <> 45 OR LEFT(DB_NAME(), 13) <> N'KFC_B_STAGE3_'
   OR SUBSTRING(DB_NAME(), 14, 32) COLLATE Latin1_General_100_BIN2 LIKE N'%[^0-9a-f]%'
    THROW 54220, '25b requires a disposable KFC_B_STAGE3 database.', 1;
IF @@TRANCOUNT <> 0 OR (@@OPTIONS & 2) <> 0
    THROW 54220, '25b requires a fresh session without an open or implicit transaction.', 1;

DECLARE @customer BIGINT = (
    SELECT TOP (1) c.customer_id FROM dbo.Customer AS c
    JOIN dbo.MemberLevel AS m ON m.member_level_id = c.member_level_id
    WHERE c.status = 'ACTIVE' AND m.status = 'ACTIVE' AND m.level_name = N'金卡会员'
    ORDER BY c.customer_id
);
DECLARE @product BIGINT = (
    SELECT TOP (1) p.product_id FROM dbo.Product AS p
    WHERE p.status = 'ACTIVE' AND p.product_type = 'SINGLE'
      AND EXISTS (SELECT 1 FROM dbo.ProductBom AS b WHERE b.product_id = p.product_id)
    ORDER BY p.product_id
);
DECLARE @rider BIGINT = (SELECT employee_id FROM dbo.EmployeeAccount WHERE database_user_name = 'test_rider');
IF @customer IS NULL OR @product IS NULL OR @rider IS NULL
    THROW 54221, '25b requires the seeded customer, stock-backed product and rider.', 1;

DECLARE @cases TABLE (
    id INT PRIMARY KEY, test_case VARCHAR(40), method VARCHAR(20), expected_error INT NULL
);
INSERT @cases VALUES
    (1, 'commit pickup', 'PICKUP', NULL),
    (2, 'commit delivery', 'DELIVERY', NULL),
    (3, 'forced rollback after writes', 'DELIVERY', 54222),
    (4, 'missing order', 'PICKUP', 52401),
    (5, 'no sellable lines', 'PICKUP', 52402),
    (6, 'no outstanding reservation', 'PICKUP', 50000),
    (7, 'insufficient locked quantity', 'PICKUP', 50000);

-- Compare values, not just counts. Stock includes audit and replenishment side
-- effects so both rollback and final pickup/delivery checks catch partial writes.
DECLARE @snapshot NVARCHAR(MAX) = N'
SELECT @stock = (
    SELECT (SELECT * FROM dbo.Inventory ORDER BY ingredient_id FOR JSON PATH, INCLUDE_NULL_VALUES) AS inventory,
           (SELECT * FROM dbo.InventoryMovement ORDER BY inventory_movement_id FOR JSON PATH, INCLUDE_NULL_VALUES) AS movements,
           (SELECT * FROM dbo.InventoryAudit ORDER BY inventory_audit_id FOR JSON PATH, INCLUDE_NULL_VALUES) AS audit,
           (SELECT * FROM dbo.ReplenishmentSuggestion ORDER BY replenishment_suggestion_id FOR JSON PATH, INCLUDE_NULL_VALUES) AS suggestions
    FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
);
SELECT @state = (
    SELECT (SELECT * FROM dbo.SalesOrder WHERE order_id = @id FOR JSON PATH, INCLUDE_NULL_VALUES) AS order_header,
           (SELECT * FROM dbo.SalesOrderItem WHERE order_id = @id ORDER BY order_item_id FOR JSON PATH, INCLUDE_NULL_VALUES) AS lines,
           (SELECT * FROM dbo.Delivery WHERE order_id = @id FOR JSON PATH, INCLUDE_NULL_VALUES) AS delivery,
           (SELECT * FROM dbo.PointLedger WHERE order_id = @id FOR JSON PATH, INCLUDE_NULL_VALUES) AS points,
           (SELECT current_points, member_level_id FROM dbo.Customer WHERE customer_id = @customer FOR JSON PATH) AS customer
    FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
);';
DECLARE @snapshot_args NVARCHAR(150) = N'@id BIGINT, @customer BIGINT, @stock NVARCHAR(MAX) OUTPUT, @state NVARCHAR(MAX) OUTPUT';

DECLARE @i INT = 1, @test_case VARCHAR(40), @method VARCHAR(20), @expected INT,
        @observed INT, @order_id BIGINT, @target BIGINT, @order_no VARCHAR(50),
        @total DECIMAL(10,2), @gross DECIMAL(22,2), @discount DECIMAL(22,2),
        @ready VARCHAR(20), @finished DATETIME2(0), @entered_as_user BIT = 0,
        @payload NVARCHAR(MAX) = CONCAT(N'[{"product_id":', @product, N',"quantity":2}]'),
        @before_stock NVARCHAR(MAX), @before_state NVARCHAR(MAX),
        @call_stock NVARCHAR(MAX), @call_state NVARCHAR(MAX),
        @after_stock NVARCHAR(MAX), @after_state NVARCHAR(MAX);
DECLARE @reserved TABLE (ingredient_id BIGINT PRIMARY KEY, qty DECIMAL(12,3),
                         on_hand_before DECIMAL(12,3), locked_before DECIMAL(12,3));

BEGIN TRY
    -- Give this product a known stock margin in the disposable fixture.
    -- Earlier regression cases may already have reserved the opening stock.
    UPDATE s SET on_hand_qty = s.locked_qty + 100
    FROM dbo.Inventory AS s JOIN dbo.ProductBom AS b ON b.ingredient_id = s.ingredient_id
    WHERE b.product_id = @product AND s.on_hand_qty < s.locked_qty + 100;

    WHILE @i <= (SELECT COUNT(*) FROM @cases)
    BEGIN
        SELECT @test_case = test_case, @method = method, @expected = expected_error FROM @cases WHERE id = @i;
        SELECT @observed = NULL, @order_id = NULL, @total = NULL, @finished = NULL;
        SET @order_no = 'B25-' + CONVERT(VARCHAR(36), NEWID());

        -- Commit a fresh paid fixture first. The experiment's rollback can
        -- then prove it reinstated the exact paid, IN_PRODUCTION state.
        BEGIN TRANSACTION;
        EXECUTE AS USER = 'test_cashier';
        SET @entered_as_user = 1;
        EXEC dbo.sp_create_order @customer, @method, @order_no, @payload;
        REVERT;
        SET @entered_as_user = 0;
        SELECT @order_id = order_id, @total = total_amount FROM dbo.SalesOrder WHERE order_no = @order_no;
        IF @order_id IS NULL OR @total <= 0
            THROW 54224, '25b failed to create a payable fixture.', 1;
        EXECUTE AS USER = 'test_cashier';
        SET @entered_as_user = 1;
        EXEC dbo.sp_pay_order @order_id, 'CASH', @total, NULL;
        REVERT;
        SET @entered_as_user = 0;
        EXECUTE AS USER = 'test_chef';
        SET @entered_as_user = 1;
        EXEC dbo.sp_start_production @order_id;
        REVERT;
        SET @entered_as_user = 0;
        COMMIT TRANSACTION;

        SET @target = CASE WHEN @i = 4 THEN -1 ELSE @order_id END;
        DELETE FROM @reserved;
        INSERT @reserved
        SELECT m.ingredient_id, SUM(m.locked_delta), s.on_hand_qty, s.locked_qty
        FROM dbo.InventoryMovement AS m JOIN dbo.Inventory AS s ON s.ingredient_id = m.ingredient_id
        WHERE m.reference_type = 'ORDER' AND m.reference_id = @order_id AND m.movement_type = 'LOCK'
        GROUP BY m.ingredient_id, s.on_hand_qty, s.locked_qty;
        IF NOT EXISTS (SELECT 1 FROM @reserved)
           OR NOT EXISTS (SELECT 1 FROM dbo.Payment WHERE order_id = @order_id AND payment_status = 'SUCCESS' AND paid_amount = @total)
           OR NOT EXISTS (SELECT 1 FROM dbo.SalesOrder WHERE order_id = @order_id AND order_status = 'IN_PRODUCTION'
                          AND production_finished_at IS NULL AND paid_at IS NOT NULL)
            THROW 54224, '25b fixture must have payment, reservations and an unfinished IN_PRODUCTION order.', 1;

        EXEC sys.sp_executesql @snapshot, @snapshot_args, @order_id, @customer, @before_stock OUTPUT, @before_state OUTPUT;
        BEGIN TRANSACTION;
        IF @i = 5 DELETE FROM dbo.SalesOrderItem WHERE order_id = @order_id;
        IF @i = 6 DELETE FROM dbo.InventoryMovement WHERE reference_type = 'ORDER' AND reference_id = @order_id;
        IF @i = 7
            UPDATE s SET locked_qty = r.qty - 0.001
            FROM dbo.Inventory AS s JOIN @reserved AS r ON s.ingredient_id = r.ingredient_id;
        BEGIN TRY
            IF @i <= 3
            BEGIN
                SELECT @gross = SUM(ROUND(unit_price * quantity, 2)), @discount = SUM(discount_amount)
                FROM dbo.SalesOrderItem WHERE order_id = @target AND item_role = 'SELLABLE';
                IF @gross IS NULL THROW 54223, '25b order must have a sellable line.', 1;
                IF @total <> @gross - @discount THROW 54225, '25b total disagrees with the net line amounts.', 1;
            END;

            EXECUTE AS USER = 'test_packer';
            SET @entered_as_user = 1;
            EXEC dbo.sp_finish_production @target;
            REVERT;
            SET @entered_as_user = 0;

            SET @ready = CASE WHEN @method = 'PICKUP' THEN 'READY_FOR_PICKUP' ELSE 'READY_FOR_DELIVERY' END;
            SELECT @finished = production_finished_at FROM dbo.SalesOrder WHERE order_id = @order_id AND order_status = @ready;
            IF @finished IS NULL OR @@TRANCOUNT <> 1
                THROW 54226, '25b finish did not set status/time or preserve its caller transaction.', 1;
            IF EXISTS (
                SELECT 1 FROM @reserved AS r LEFT JOIN dbo.Inventory AS s ON s.ingredient_id = r.ingredient_id
                WHERE s.ingredient_id IS NULL OR s.on_hand_qty <> r.on_hand_before - r.qty
                   OR s.locked_qty <> r.locked_before - r.qty
            ) OR EXISTS (
                SELECT ingredient_id, -qty, -qty FROM @reserved
                EXCEPT
                SELECT ingredient_id, on_hand_delta, locked_delta FROM dbo.InventoryMovement
                WHERE reference_type = 'ORDER' AND reference_id = @order_id AND movement_type = 'CONSUME'
            ) OR (SELECT COUNT(*) FROM dbo.InventoryMovement
                  WHERE reference_type = 'ORDER' AND reference_id = @order_id AND movement_type = 'CONSUME') <> (SELECT COUNT(*) FROM @reserved)
                THROW 54227, '25b stock or CONSUME movements differ from the reservations.', 1;
            IF (@method = 'PICKUP' AND EXISTS (SELECT 1 FROM dbo.Delivery WHERE order_id = @order_id))
               OR (@method = 'DELIVERY' AND NOT EXISTS (SELECT 1 FROM dbo.Delivery WHERE order_id = @order_id AND delivery_status = 'WAITING_PICKUP'))
                THROW 54228, '25b delivery row does not match the fulfillment method.', 1;

            SELECT @test_case AS test_case, @order_id AS order_id, @ready AS status_in_transaction,
                   @finished AS production_finished_at, @gross AS gross, @discount AS discount, @total AS net,
                   (SELECT COUNT(*) FROM dbo.Delivery WHERE order_id = @order_id) AS delivery_rows,
                   @@TRANCOUNT AS transaction_count;
            SELECT r.ingredient_id, r.on_hand_before, s.on_hand_qty AS on_hand_after,
                   r.locked_before, s.locked_qty AS locked_after, m.on_hand_delta, m.locked_delta
            FROM @reserved AS r JOIN dbo.Inventory AS s ON s.ingredient_id = r.ingredient_id
            JOIN dbo.InventoryMovement AS m ON m.ingredient_id = r.ingredient_id
            WHERE m.reference_type = 'ORDER' AND m.reference_id = @order_id AND m.movement_type = 'CONSUME'
            ORDER BY r.ingredient_id;

            IF @i = 3 THROW 54222, '25b injected error after successful production and inventory writes.', 1;
            IF @expected IS NOT NULL THROW 54229, '25b negative case unexpectedly succeeded.', 1;
            EXEC sys.sp_executesql @snapshot, @snapshot_args, @order_id, @customer, @call_stock OUTPUT, @call_state OUTPUT;
            COMMIT TRANSACTION;
        END TRY
        BEGIN CATCH
            SET @observed = ERROR_NUMBER();
            IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
            IF @entered_as_user = 1
            BEGIN
                REVERT;
                SET @entered_as_user = 0;
            END;
            IF @expected IS NULL OR @observed <> @expected THROW;
            SET @call_stock = @before_stock;
            SET @call_state = @before_state;
        END CATCH;

        EXEC sys.sp_executesql @snapshot, @snapshot_args, @order_id, @customer, @after_stock OUTPUT, @after_state OUTPUT;
        IF @@TRANCOUNT <> 0 OR @after_stock <> @call_stock OR @after_state <> @call_state
            THROW 54230, '25b persisted state differs from the expected commit or rollback snapshot.', 1;
        SELECT @test_case AS test_case, @observed AS observed_error, o.order_status, o.production_finished_at,
               (SELECT COUNT(*) FROM dbo.Delivery WHERE order_id = @order_id) AS delivery_rows,
               (SELECT COUNT(*) FROM dbo.InventoryMovement WHERE reference_type = 'ORDER'
                AND reference_id = @order_id AND movement_type = 'CONSUME') AS consume_rows,
               @@TRANCOUNT AS transaction_count
        FROM dbo.SalesOrder AS o WHERE o.order_id = @order_id;
        IF @observed IS NOT NULL
            SELECT r.ingredient_id, r.on_hand_before, s.on_hand_qty AS on_hand_restored,
                   r.locked_before, s.locked_qty AS locked_restored
            FROM @reserved AS r JOIN dbo.Inventory AS s ON s.ingredient_id = r.ingredient_id
            ORDER BY r.ingredient_id;

        IF @expected IS NULL
        BEGIN
            -- Probe both ready and terminal states. Each must reject another
            -- finish, and real pickup/delivery must leave the stock unchanged.
            DECLARE @repeat INT = 0, @repeat_error INT;
            WHILE @repeat <= 1
            BEGIN
                EXEC sys.sp_executesql @snapshot, @snapshot_args, @order_id, @customer, @call_stock OUTPUT, @call_state OUTPUT;
                SET @repeat_error = NULL;
                EXECUTE AS USER = 'test_packer';
                SET @entered_as_user = 1;
                BEGIN TRY
                    EXEC dbo.sp_finish_production @order_id;
                END TRY
                BEGIN CATCH
                    SET @repeat_error = ERROR_NUMBER();
                    IF @repeat_error <> 52401 THROW;
                END CATCH;
                REVERT;
                SET @entered_as_user = 0;
                EXEC sys.sp_executesql @snapshot, @snapshot_args, @order_id, @customer, @after_stock OUTPUT, @after_state OUTPUT;
                IF @repeat_error IS NULL OR @@TRANCOUNT <> 0 OR @after_stock <> @call_stock OR @after_state <> @call_state
                    THROW 54231, '25b duplicate finish was not rejected without changes.', 1;
                SELECT @method AS fulfillment_method, @repeat_error AS observed_error, order_status, @@TRANCOUNT AS transaction_count
                FROM dbo.SalesOrder WHERE order_id = @order_id;

                IF @repeat = 0
                BEGIN
                    IF @method = 'PICKUP'
                    BEGIN
                        EXECUTE AS USER = 'test_packer';
                        SET @entered_as_user = 1;
                        EXEC dbo.sp_pick_up_order @order_id;
                    END
                    ELSE
                    BEGIN
                        EXECUTE AS USER = 'test_rider';
                        SET @entered_as_user = 1;
                        EXEC dbo.sp_pick_up_delivery @order_id, @rider;
                        EXEC dbo.sp_confirm_delivery @order_id;
                    END;
                    REVERT;
                    SET @entered_as_user = 0;
                    EXEC sys.sp_executesql @snapshot, @snapshot_args, @order_id, @customer, @after_stock OUTPUT, @after_state OUTPUT;
                    IF @@TRANCOUNT <> 0 OR @after_stock <> @call_stock OR NOT EXISTS (
                        SELECT 1 FROM dbo.SalesOrder AS o JOIN dbo.PointLedger AS p ON p.order_id = o.order_id
                        WHERE o.order_id = @order_id AND o.completed_at IS NOT NULL AND p.ledger_status = 'EFFECTIVE'
                          AND o.order_status = CASE WHEN @method = 'PICKUP' THEN 'PICKED_UP' ELSE 'COMPLETED' END
                    ) THROW 54232, '25b terminal fulfillment changed stock or failed to settle the order.', 1;
                END;
                SET @repeat += 1;
            END;
        END;
        SET @i += 1;
    END;
END TRY
BEGIN CATCH
    DECLARE @failed_line INT = ERROR_LINE(), @failed_number INT = ERROR_NUMBER();
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    IF @entered_as_user = 1 REVERT;
    RAISERROR('25b failed in case %d, SQL line %d, error %d.', 10, 1, @i, @failed_line, @failed_number) WITH NOWAIT;
    THROW;
END CATCH;

SELECT '25b PASS' AS result, @i - 1 AS scenarios, @@TRANCOUNT AS transaction_count;
