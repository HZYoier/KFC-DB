/*
 B integration seed: run after A master seed and C opening/security seed.
 Execute with sqlcmd -b / stop-on-error as a deployment principal allowed to
 impersonate the test users. Every business call runs under its actual role.
 Creates exactly three fixed orders; a failure rolls back the entire seed.
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
SET NOCOUNT ON;

-- Check deployment dependencies before selecting seed data.
IF EXISTS (
    SELECT 1 FROM (VALUES
        (N'Customer'), (N'MemberLevel'), (N'Product'), (N'Ingredient'),
        (N'ProductBom'), (N'ComboComponent'), (N'Promotion'), (N'PromotionProductRule'),
        (N'EmployeeAccount'), (N'Inventory'), (N'InventoryMovement'),
        (N'SalesOrder'), (N'SalesOrderItem'), (N'Payment'), (N'Delivery'), (N'PointLedger')
    ) AS required(name)
    WHERE OBJECT_ID(N'dbo.' + required.name, N'U') IS NULL
)
    THROW 52900, 'B seed setup: install A/B/C tables, A master seed and C opening/security seed first.', 1;
IF OBJECT_ID(N'dbo.fn_get_effective_product_price', N'IF') IS NULL
 OR EXISTS (
    SELECT 1 FROM (VALUES
        (N'sp_create_order'), (N'sp_pay_order'), (N'sp_start_production'),
        (N'sp_finish_production'), (N'sp_pick_up_order'), (N'sp_pick_up_delivery'),
        (N'sp_confirm_delivery'), (N'sp_cancel_or_refund_order'),
        (N'sp_lock_order_inventory'), (N'sp_consume_order_inventory'),
        (N'sp_release_order_inventory'), (N'sp_apply_customer_points'), (N'sp_write_audit_log')
    ) AS required(name)
    WHERE OBJECT_ID(N'dbo.' + required.name, N'P') IS NULL
 )
    THROW 52900, 'B seed setup: required A/B/C pricing and business procedures are missing.', 1;
IF @@TRANCOUNT <> 0
    THROW 52900, 'B seed setup: run in a session without an existing transaction.', 1;

DECLARE @customer_id BIGINT, @pickup_product_id BIGINT, @single_product_id BIGINT,
        @promotion_id BIGINT, @promo_price DECIMAL(10,2), @thursday_at DATETIME2(0),
        @rider_id BIGINT, @manager_id BIGINT,
        @pickup_id BIGINT, @delivery_id BIGINT, @cancel_id BIGINT,
        @amount DECIMAL(10,2), @pickup_json NVARCHAR(MAX), @single_json NVARCHAR(MAX),
        @impersonated BIT = 0;

BEGIN TRY
    BEGIN TRANSACTION;
    -- Fixed numbers make accidental re-execution explicit, without overwriting data.
    IF EXISTS (
        SELECT 1 FROM dbo.SalesOrder WITH (UPDLOCK, HOLDLOCK)
        WHERE order_no IN ('B-SEED-PICKUP-001', 'B-SEED-DELIVERY-001', 'B-SEED-CANCEL-001')
    )
        THROW 52901, 'B seed already exists: one or more fixed B-SEED order numbers are present.', 1;

    -- Resolve all required database principals and their active C employee rows.
    IF EXISTS (
        SELECT 1 FROM (VALUES
            (N'test_cashier', 'CASHIER'), (N'test_chef', 'CHEF'),
            (N'test_packer', 'PACKER'), (N'test_rider', 'RIDER'),
            (N'test_store_manager', 'STORE_MANAGER')
        ) AS required(user_name, job_code)
        WHERE DATABASE_PRINCIPAL_ID(required.user_name) IS NULL
           OR NOT EXISTS (
                SELECT 1 FROM dbo.EmployeeAccount AS e
                WHERE e.database_user_name = required.user_name
                  AND e.job_code = required.job_code AND e.status = 'ACTIVE'
           )
    )
        THROW 52902, 'B seed setup: C must provide all five test users with matching ACTIVE employee jobs and grants.', 1;
    SELECT @rider_id = employee_id FROM dbo.EmployeeAccount
    WHERE database_user_name = N'test_rider' AND job_code = 'RIDER' AND status = 'ACTIVE';
    SELECT @manager_id = employee_id FROM dbo.EmployeeAccount
    WHERE database_user_name = N'test_store_manager' AND job_code = 'STORE_MANAGER' AND status = 'ACTIVE';

    -- Payment requires an active customer with an active, positive member multiplier.
    SELECT TOP (1) @customer_id = c.customer_id
    FROM dbo.Customer AS c
    JOIN dbo.MemberLevel AS ml ON ml.member_level_id = c.member_level_id
    WHERE c.status = 'ACTIVE' AND ml.status = 'ACTIVE' AND ml.point_multiplier > 0
    ORDER BY c.customer_id;
    IF @customer_id IS NULL
        THROW 52903, 'B seed setup: A must provide an ACTIVE customer with an ACTIVE positive-multiplier member level.', 1;

    -- Discover usable single products and one-level combos without assuming seed IDs.
    -- Invalid/missing BOMs and inactive ingredients are excluded from both paths.
    ;WITH usable_single AS (
        SELECT p.product_id
        FROM dbo.Product AS p
        WHERE p.status = 'ACTIVE' AND p.product_type = 'SINGLE' AND p.base_price > 0
          AND EXISTS (SELECT 1 FROM dbo.ProductBom AS b WHERE b.product_id = p.product_id)
          AND NOT EXISTS (
              SELECT 1 FROM dbo.ProductBom AS b
              LEFT JOIN dbo.Ingredient AS i ON i.ingredient_id = b.ingredient_id
              WHERE b.product_id = p.product_id
                AND (b.usage_qty IS NULL OR b.usage_qty <= 0 OR i.status IS NULL OR i.status <> 'ACTIVE')
          )
    ), usable_product AS (
        SELECT product_id FROM usable_single
        UNION ALL
        SELECT p.product_id FROM dbo.Product AS p
        WHERE p.status = 'ACTIVE' AND p.product_type = 'COMBO' AND p.base_price > 0
          AND EXISTS (SELECT 1 FROM dbo.ComboComponent AS cc WHERE cc.combo_product_id = p.product_id)
          AND NOT EXISTS (
              SELECT 1 FROM dbo.ComboComponent AS cc
              LEFT JOIN usable_single AS child ON child.product_id = cc.child_product_id
              WHERE cc.combo_product_id = p.product_id
                AND (child.product_id IS NULL OR cc.quantity IS NULL OR cc.quantity <= 0)
          )
    )
    SELECT TOP (1) @pickup_product_id = r.product_id, @promotion_id = promo.promotion_id,
           @promo_price = price.effective_price, @thursday_at = candidate.at
    FROM dbo.Promotion AS promo
    JOIN dbo.PromotionProductRule AS r ON r.promotion_id = promo.promotion_id
    JOIN usable_product AS p ON p.product_id = r.product_id
    -- Monday anchor avoids DATEFIRST/language dependence, including dates before 1900.
    CROSS APPLY (VALUES (CONVERT(DATE, promo.start_at))) AS start_day(day_value)
    CROSS APPLY (VALUES (DATEADD(DAY,
        (3 - ((DATEDIFF(DAY, DATEFROMPARTS(1900,1,1), start_day.day_value) % 7 + 7) % 7) + 7) % 7,
        CONVERT(DATETIME2(0), start_day.day_value)))) AS first_thursday(day_value)
    -- If the first Thursday has already passed its rule window, the next can qualify.
    CROSS APPLY (VALUES (0), (7)) AS week_offset(days)
    CROSS APPLY (VALUES (DATEADD(DAY, week_offset.days, first_thursday.day_value))) AS thursday(day_value)
    CROSS APPLY (VALUES (DATEADD(SECOND,
        DATEDIFF(SECOND, CONVERT(TIME(0), '00:00:00'), r.start_time), thursday.day_value))) AS rule_start(at)
    CROSS APPLY (VALUES (CASE WHEN promo.start_at > rule_start.at
        THEN promo.start_at ELSE rule_start.at END)) AS candidate(at)
    CROSS APPLY dbo.fn_get_effective_product_price(r.product_id, candidate.at) AS price
    WHERE promo.status = 'ACTIVE' AND r.weekday_no = 4
      AND r.start_time < r.end_time AND r.promo_price > 0
      AND candidate.at >= promo.start_at AND candidate.at < promo.end_at
      AND CONVERT(DATE, candidate.at) = CONVERT(DATE, thursday.day_value)
      AND CONVERT(TIME(0), candidate.at) >= r.start_time
      AND CONVERT(TIME(0), candidate.at) < r.end_time
      AND price.promotion_id = promo.promotion_id AND price.effective_price = r.promo_price
    ORDER BY promo.promotion_id, r.promotion_rule_id, candidate.at;
    IF @pickup_product_id IS NULL OR @thursday_at IS NULL
        THROW 52904, 'B seed setup: no usable ACTIVE Thursday promotion/product has a valid rule window and winning A price.', 1;

    -- Delivery and unpaid cancellation use an active single product with a valid BOM.
    SELECT TOP (1) @single_product_id = p.product_id
    FROM dbo.Product AS p
    WHERE p.status = 'ACTIVE' AND p.product_type = 'SINGLE' AND p.base_price > 0
      AND EXISTS (SELECT 1 FROM dbo.ProductBom AS b WHERE b.product_id = p.product_id)
      AND NOT EXISTS (
          SELECT 1 FROM dbo.ProductBom AS b
          LEFT JOIN dbo.Ingredient AS i ON i.ingredient_id = b.ingredient_id
          WHERE b.product_id = p.product_id
            AND (b.usage_qty IS NULL OR b.usage_qty <= 0 OR i.status IS NULL OR i.status <> 'ACTIVE')
      )
    ORDER BY p.product_id;
    IF @single_product_id IS NULL
        THROW 52905, 'B seed setup: A must provide an ACTIVE SINGLE product with positive BOM quantities and ACTIVE ingredients.', 1;

    -- Read-only stock preflight covers pickup consumption, delivery consumption and
    -- the final cancellation's temporary lock. C still performs authoritative locking.
    ;WITH selected_products AS (
        SELECT @pickup_product_id AS product_id, 1 AS quantity
        UNION ALL SELECT @single_product_id, 2
    ), singles AS (
        SELECT s.product_id, s.quantity FROM selected_products AS s
        JOIN dbo.Product AS p ON p.product_id = s.product_id AND p.product_type = 'SINGLE'
        UNION ALL
        SELECT cc.child_product_id, s.quantity * cc.quantity FROM selected_products AS s
        JOIN dbo.Product AS p ON p.product_id = s.product_id AND p.product_type = 'COMBO'
        JOIN dbo.ComboComponent AS cc ON cc.combo_product_id = s.product_id
    ), demand AS (
        SELECT b.ingredient_id, SUM(CONVERT(DECIMAL(20,3), s.quantity) * b.usage_qty) AS needed
        FROM singles AS s JOIN dbo.ProductBom AS b ON b.product_id = s.product_id
        GROUP BY b.ingredient_id
    )
    SELECT @amount = CASE WHEN EXISTS (
        SELECT 1 FROM demand AS d LEFT JOIN dbo.Inventory AS inv ON inv.ingredient_id = d.ingredient_id
        WHERE inv.ingredient_id IS NULL OR inv.on_hand_qty - inv.locked_qty < d.needed
           OR inv.on_hand_qty IS NULL OR inv.locked_qty IS NULL
    ) THEN 0 ELSE 1 END;
    IF @amount = 0
        THROW 52906, 'B seed setup: C opening inventory is missing or insufficient for the three selected orders.', 1;

    SET @pickup_json = CONCAT(N'[{"product_id":', @pickup_product_id, N',"quantity":1}]');
    SET @single_json = CONCAT(N'[{"product_id":', @single_product_id, N',"quantity":1}]');

    -- 1. Thursday promotional pickup: cashier -> chef -> packer -> collected.
    EXECUTE AS USER = 'test_cashier';
    SET @impersonated = 1;
    EXEC dbo.sp_create_order @customer_id = @customer_id, @fulfillment_method = 'PICKUP',
        @order_no = 'B-SEED-PICKUP-001', @items_json = @pickup_json, @ordered_at = @thursday_at;
    REVERT;
    SET @impersonated = 0;
    SELECT @pickup_id = order_id, @amount = total_amount FROM dbo.SalesOrder WHERE order_no = 'B-SEED-PICKUP-001';
    EXECUTE AS USER = 'test_cashier';
    SET @impersonated = 1;
    EXEC dbo.sp_pay_order @order_id = @pickup_id, @payment_method = 'CASH',
        @paid_amount = @amount, @third_party_txn_no = 'B-SEED-PICKUP-PAY-001';
    REVERT;
    SET @impersonated = 0;
    EXECUTE AS USER = 'test_chef';
    SET @impersonated = 1;
    EXEC dbo.sp_start_production @order_id = @pickup_id;
    REVERT;
    SET @impersonated = 0;
    EXECUTE AS USER = 'test_packer';
    SET @impersonated = 1;
    EXEC dbo.sp_finish_production @order_id = @pickup_id;
    REVERT;
    SET @impersonated = 0;
    EXECUTE AS USER = 'test_packer';
    SET @impersonated = 1;
    EXEC dbo.sp_pick_up_order @order_id = @pickup_id;
    REVERT;
    SET @impersonated = 0;

    -- 2. Single-product delivery: cashier -> chef -> packer -> assigned rider.
    EXECUTE AS USER = 'test_cashier';
    SET @impersonated = 1;
    EXEC dbo.sp_create_order @customer_id = @customer_id, @fulfillment_method = 'DELIVERY',
        @order_no = 'B-SEED-DELIVERY-001', @items_json = @single_json;
    REVERT;
    SET @impersonated = 0;
    SELECT @delivery_id = order_id, @amount = total_amount FROM dbo.SalesOrder WHERE order_no = 'B-SEED-DELIVERY-001';
    EXECUTE AS USER = 'test_cashier';
    SET @impersonated = 1;
    EXEC dbo.sp_pay_order @order_id = @delivery_id, @payment_method = 'CASH',
        @paid_amount = @amount, @third_party_txn_no = 'B-SEED-DELIVERY-PAY-001';
    REVERT;
    SET @impersonated = 0;
    EXECUTE AS USER = 'test_chef';
    SET @impersonated = 1;
    EXEC dbo.sp_start_production @order_id = @delivery_id;
    REVERT;
    SET @impersonated = 0;
    EXECUTE AS USER = 'test_packer';
    SET @impersonated = 1;
    EXEC dbo.sp_finish_production @order_id = @delivery_id;
    REVERT;
    SET @impersonated = 0;
    EXECUTE AS USER = 'test_rider';
    SET @impersonated = 1;
    EXEC dbo.sp_pick_up_delivery @order_id = @delivery_id, @rider_employee_id = @rider_id;
    REVERT;
    SET @impersonated = 0;
    EXECUTE AS USER = 'test_rider';
    SET @impersonated = 1;
    EXEC dbo.sp_confirm_delivery @order_id = @delivery_id;
    REVERT;
    SET @impersonated = 0;

    -- 3. Unpaid cancellation: cashier creates, store manager releases the lock.
    EXECUTE AS USER = 'test_cashier';
    SET @impersonated = 1;
    EXEC dbo.sp_create_order @customer_id = @customer_id, @fulfillment_method = 'PICKUP',
        @order_no = 'B-SEED-CANCEL-001', @items_json = @single_json;
    REVERT;
    SET @impersonated = 0;
    SELECT @cancel_id = order_id FROM dbo.SalesOrder WHERE order_no = 'B-SEED-CANCEL-001';
    EXECUTE AS USER = 'test_store_manager';
    SET @impersonated = 1;
    EXEC dbo.sp_cancel_or_refund_order @order_id = @cancel_id, @reason = 'CANCEL', @operator_employee_id = @manager_id;
    REVERT;
    SET @impersonated = 0;

    -- Assert the exact fixed set, terminal states and fulfillment timestamps.
    IF (SELECT COUNT(*) FROM dbo.SalesOrder WHERE order_no IN
        ('B-SEED-PICKUP-001', 'B-SEED-DELIVERY-001', 'B-SEED-CANCEL-001')) <> 3
       OR NOT EXISTS (SELECT 1 FROM dbo.SalesOrder WHERE order_id = @pickup_id
            AND order_status = 'PICKED_UP' AND fulfillment_method = 'PICKUP'
            AND ordered_at = @thursday_at AND completed_at IS NOT NULL)
       OR NOT EXISTS (SELECT 1 FROM dbo.SalesOrder WHERE order_id = @delivery_id
            AND order_status = 'COMPLETED' AND fulfillment_method = 'DELIVERY' AND completed_at IS NOT NULL)
       OR NOT EXISTS (SELECT 1 FROM dbo.SalesOrder WHERE order_id = @cancel_id
            AND order_status = 'CANCELLED' AND paid_at IS NULL AND cancelled_at IS NOT NULL)
        THROW 52910, 'B seed assertion: exactly three orders in the expected terminal states are required.', 1;
    IF NOT EXISTS (SELECT 1 FROM dbo.SalesOrderItem WHERE order_id = @pickup_id
        AND item_role = 'SELLABLE' AND product_id = @pickup_product_id
        AND promotion_id = @promotion_id AND unit_price = @promo_price AND quantity = 1)
        THROW 52911, 'B seed assertion: Thursday promotional price and promotion ID were not snapshotted.', 1;
    IF NOT EXISTS (SELECT 1 FROM dbo.Delivery WHERE order_id = @delivery_id
        AND delivery_status = 'DELIVERED' AND rider_employee_id = @rider_id
        AND picked_up_at IS NOT NULL AND delivered_at IS NOT NULL AND delivered_at >= picked_up_at)
        THROW 52912, 'B seed assertion: completed delivery requires its rider and both timestamps.', 1;
    IF (SELECT COUNT(*) FROM dbo.PointLedger WHERE order_id IN (@pickup_id, @delivery_id)
        AND ledger_status = 'EFFECTIVE' AND effective_at IS NOT NULL) <> 2
       OR EXISTS (SELECT 1 FROM dbo.PointLedger WHERE order_id = @cancel_id AND ledger_status = 'EFFECTIVE')
       OR EXISTS (SELECT 1 FROM dbo.Payment WHERE order_id = @cancel_id)
       OR (SELECT COUNT(*) FROM dbo.Payment AS pay JOIN dbo.SalesOrder AS so ON so.order_id = pay.order_id
           WHERE pay.order_id IN (@pickup_id, @delivery_id)
             AND pay.payment_status = 'SUCCESS' AND pay.paid_amount = so.total_amount AND pay.refunded_amount = 0) <> 2
        THROW 52913, 'B seed assertion: completed orders need successful full payments/effective points; cancellation must remain unpaid.', 1;

    -- For every required ingredient, prove LOCK then CONSUME/RELEASE with exact
    -- frozen movement deltas. IDs break ties when DATETIME2(0) timestamps match.
    IF EXISTS (
        SELECT 1 FROM (
            SELECT oi.order_id, b.ingredient_id,
                   SUM(CONVERT(DECIMAL(20,3), oi.quantity) * b.usage_qty) AS needed
            FROM dbo.SalesOrderItem AS oi
            JOIN dbo.Product AS p ON p.product_id = oi.product_id
            JOIN dbo.ProductBom AS b ON b.product_id = oi.product_id
            WHERE oi.order_id IN (@pickup_id, @delivery_id, @cancel_id)
              AND (oi.item_role = 'COMPONENT' OR (oi.item_role = 'SELLABLE' AND p.product_type = 'SINGLE'))
            GROUP BY oi.order_id, b.ingredient_id
        ) AS demand
        WHERE NOT EXISTS (
            SELECT 1 FROM dbo.InventoryMovement AS locked
            JOIN dbo.InventoryMovement AS terminal ON terminal.reference_type = 'ORDER'
              AND terminal.reference_id = locked.reference_id AND terminal.ingredient_id = locked.ingredient_id
            WHERE locked.reference_type = 'ORDER' AND locked.reference_id = demand.order_id
              AND locked.ingredient_id = demand.ingredient_id AND locked.movement_type = 'LOCK'
              AND locked.on_hand_delta = 0 AND locked.locked_delta = demand.needed
              AND terminal.movement_type = CASE WHEN demand.order_id = @cancel_id THEN 'RELEASE' ELSE 'CONSUME' END
              AND terminal.locked_delta = -demand.needed
              AND terminal.on_hand_delta = CASE WHEN demand.order_id = @cancel_id THEN 0 ELSE -demand.needed END
              AND terminal.inventory_movement_id > locked.inventory_movement_id
              AND terminal.moved_at >= locked.moved_at
        )
    ) OR EXISTS (
        SELECT 1 FROM dbo.InventoryMovement WHERE reference_type = 'ORDER'
          AND ((reference_id IN (@pickup_id, @delivery_id) AND movement_type NOT IN ('LOCK', 'CONSUME'))
            OR (reference_id = @cancel_id AND movement_type NOT IN ('LOCK', 'RELEASE')))
    ) OR EXISTS (
        SELECT 1 FROM (VALUES (@pickup_id), (@delivery_id), (@cancel_id)) AS expected(order_id)
        WHERE NOT EXISTS (SELECT 1 FROM dbo.InventoryMovement AS m
            WHERE m.reference_type = 'ORDER' AND m.reference_id = expected.order_id AND m.movement_type = 'LOCK')
    )
        THROW 52914, 'B seed assertion: expected LOCK then CONSUME/RELEASE inventory evidence is missing or incorrect.', 1;

    COMMIT TRANSACTION;
    PRINT 'PASS: B seed orders';
END TRY
BEGIN CATCH
    -- A failed role call skips its normal REVERT; restore the deployment context
    -- before rolling back the transaction (including a doomed XACT_ABORT case).
    IF @impersonated = 1 REVERT;
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
GO
