/* B 域验收契约：须在 02/03/04/05/06/08/09a/09c 之后执行。所有业务写入仅经 B/C/A 过程。 */
USE KFC_DB;
GO
SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET QUOTED_IDENTIFIER ON;
SET NUMERIC_ROUNDABORT OFF;
GO

/*
  部署验收夹具裁定：计划未冻结 A 的 sp_create_product/sp_update_product_price 签名，
  故仅在部署主体、外层事务且最终回滚的本段直接写 Product/Customer。它不绕过任何 B 写入，
  只构造“停用”“无 BOM”、价格快照和确定性积分阈值反例；生产业务角色不得执行这些 DML。
*/
/* 每个反例应由 sp_create_order 拒绝，且不产生订单或明细。 */
BEGIN TRY
BEGIN TRANSACTION;
DECLARE @customer_id BIGINT, @product_id BIGINT, @inactive_product_id BIGINT, @no_bom_product_id BIGINT;
DECLARE @failed BIT, @before_count INT, @after_count INT, @before_item_count INT, @after_item_count INT, @order_no VARCHAR(50);
SELECT TOP (1) @customer_id = c.customer_id FROM dbo.Customer AS c WHERE c.status = 'ACTIVE' ORDER BY c.customer_id;
SELECT TOP (1) @product_id = p.product_id FROM dbo.Product AS p WHERE p.status = 'ACTIVE' AND p.product_type = 'SINGLE' AND EXISTS (SELECT 1 FROM dbo.ProductBom AS b WHERE b.product_id = p.product_id) ORDER BY p.product_id;
IF @customer_id IS NULL OR @product_id IS NULL THROW 51000, 'B acceptance fixture requires an ACTIVE customer and ACTIVE SINGLE product with BOM.', 1;
SELECT @before_count = COUNT(*) FROM dbo.SalesOrder;
SELECT @before_item_count = COUNT(*) FROM dbo.SalesOrderItem;
SET @failed = 0; SET @order_no = CONCAT('AT-BADJSON-', CONVERT(VARCHAR(36), NEWID()));
BEGIN TRY
    EXECUTE AS USER = 'test_cashier';
    EXEC dbo.sp_create_order @customer_id = @customer_id, @fulfillment_method = 'PICKUP', @order_no = @order_no, @items_json = N'{not-json}';
    REVERT;
END TRY
BEGIN CATCH
    IF USER_NAME() = 'test_cashier' REVERT;
    SET @failed = 1;
END CATCH;
SELECT @after_count = COUNT(*) FROM dbo.SalesOrder;
SELECT @after_item_count = COUNT(*) FROM dbo.SalesOrderItem;
IF @failed = 0 OR @after_count <> @before_count OR @after_item_count <> @before_item_count THROW 51001, 'Invalid JSON was accepted or left an order/item.', 1;
PRINT 'PASS: invalid JSON is rejected';

SET @failed = 0; SET @order_no = CONCAT('AT-ZERO-', CONVERT(VARCHAR(36), NEWID()));
BEGIN TRY
    EXECUTE AS USER = 'test_cashier';
    EXEC dbo.sp_create_order @customer_id = @customer_id, @fulfillment_method = 'PICKUP', @order_no = @order_no, @items_json = CONCAT(N'[{"product_id":', @product_id, N',"quantity":0}]');
    REVERT;
END TRY
BEGIN CATCH
    IF USER_NAME() = 'test_cashier' REVERT;
    SET @failed = 1;
END CATCH;
SELECT @after_count = COUNT(*) FROM dbo.SalesOrder;
SELECT @after_item_count = COUNT(*) FROM dbo.SalesOrderItem;
IF @failed = 0 OR @after_count <> @before_count OR @after_item_count <> @before_item_count THROW 51002, 'Non-positive quantity was accepted or left an order/item.', 1;
PRINT 'PASS: non-positive quantity is rejected';

/* A temporary master-data fixture avoids relying on a particular seed product being inactive/no-BOM. */
INSERT dbo.Product (product_name, base_price, product_type, status)
VALUES (CONCAT(N'AT inactive ', CONVERT(NVARCHAR(36), NEWID())), 1.00, 'SINGLE', 'INACTIVE');
SET @inactive_product_id = CONVERT(BIGINT, SCOPE_IDENTITY());
SET @failed = 0; SET @order_no = CONCAT('AT-INACTIVE-', CONVERT(VARCHAR(36), NEWID()));
BEGIN TRY
    EXECUTE AS USER = 'test_cashier';
    EXEC dbo.sp_create_order @customer_id = @customer_id, @fulfillment_method = 'PICKUP', @order_no = @order_no, @items_json = CONCAT(N'[{"product_id":', @inactive_product_id, N',"quantity":1}]');
    REVERT;
END TRY
BEGIN CATCH
    IF USER_NAME() = 'test_cashier' REVERT;
    SET @failed = 1;
END CATCH;
SELECT @after_count = COUNT(*) FROM dbo.SalesOrder;
SELECT @after_item_count = COUNT(*) FROM dbo.SalesOrderItem;
IF @failed = 0 OR @after_count <> @before_count OR @after_item_count <> @before_item_count THROW 51003, 'Inactive product was accepted or left an order/item.', 1;
PRINT 'PASS: inactive product is rejected';

INSERT dbo.Product (product_name, base_price, product_type, status)
VALUES (CONCAT(N'AT no BOM ', CONVERT(NVARCHAR(36), NEWID())), 1.00, 'SINGLE', 'ACTIVE');
SET @no_bom_product_id = CONVERT(BIGINT, SCOPE_IDENTITY());
SET @failed = 0; SET @order_no = CONCAT('AT-NOBOM-', CONVERT(VARCHAR(36), NEWID()));
BEGIN TRY
    EXECUTE AS USER = 'test_cashier';
    EXEC dbo.sp_create_order @customer_id = @customer_id, @fulfillment_method = 'PICKUP', @order_no = @order_no, @items_json = CONCAT(N'[{"product_id":', @no_bom_product_id, N',"quantity":1}]');
    REVERT;
END TRY
BEGIN CATCH
    IF USER_NAME() = 'test_cashier' REVERT;
    SET @failed = 1;
END CATCH;
SELECT @after_count = COUNT(*) FROM dbo.SalesOrder;
SELECT @after_item_count = COUNT(*) FROM dbo.SalesOrderItem;
IF @failed = 0 OR @after_count <> @before_count OR @after_item_count <> @before_item_count THROW 51004, 'Active product without BOM was accepted or left an order/item.', 1;
PRINT 'PASS: active product without BOM is rejected';
ROLLBACK TRANSACTION;
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
/* An unpaid order cannot enter production. */
BEGIN TRY
BEGIN TRANSACTION;
DECLARE @customer_id_2 BIGINT, @product_id_2 BIGINT, @order_id_2 BIGINT, @failed_2 BIT, @order_no_2 VARCHAR(50);
SELECT TOP (1) @customer_id_2 = customer_id FROM dbo.Customer WHERE status = 'ACTIVE' ORDER BY customer_id;
SELECT TOP (1) @product_id_2 = p.product_id FROM dbo.Product AS p WHERE p.status = 'ACTIVE' AND p.product_type = 'SINGLE' AND EXISTS (SELECT 1 FROM dbo.ProductBom AS b WHERE b.product_id = p.product_id) ORDER BY p.product_id;
SET @order_no_2 = CONCAT('AT-UNPAID-', CONVERT(VARCHAR(36), NEWID()));
EXECUTE AS USER = 'test_cashier';
EXEC dbo.sp_create_order @customer_id = @customer_id_2, @fulfillment_method = 'PICKUP', @order_no = @order_no_2, @items_json = CONCAT(N'[{"product_id":', @product_id_2, N',"quantity":1}]');
REVERT;
SELECT @order_id_2 = order_id FROM dbo.SalesOrder WHERE order_no = @order_no_2;
SET @failed_2 = 0;
BEGIN TRY
    EXECUTE AS USER = 'test_chef'; EXEC dbo.sp_start_production @order_id = @order_id_2; REVERT;
END TRY
BEGIN CATCH
    IF USER_NAME() = 'test_chef' REVERT;
    SET @failed_2 = 1;
END CATCH;
IF @failed_2 = 0 THROW 51005, 'Unpaid order started production.', 1;
PRINT 'PASS: unpaid order cannot start production';
ROLLBACK TRANSACTION;
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
/* Wrong payment amount and a second payment are both rejected. */
BEGIN TRY
BEGIN TRANSACTION;
DECLARE @customer_id_3 BIGINT, @product_id_3 BIGINT, @order_id_3 BIGINT, @amount_3 DECIMAL(10,2), @failed_3 BIT, @order_no_3 VARCHAR(50);
SELECT TOP (1) @customer_id_3 = customer_id FROM dbo.Customer WHERE status = 'ACTIVE' ORDER BY customer_id;
SELECT TOP (1) @product_id_3 = p.product_id FROM dbo.Product AS p WHERE p.status = 'ACTIVE' AND p.product_type = 'SINGLE' AND EXISTS (SELECT 1 FROM dbo.ProductBom AS b WHERE b.product_id = p.product_id) ORDER BY p.product_id;
SET @order_no_3 = CONCAT('AT-PAY-', CONVERT(VARCHAR(36), NEWID()));
EXECUTE AS USER = 'test_cashier'; EXEC dbo.sp_create_order @customer_id = @customer_id_3, @fulfillment_method = 'PICKUP', @order_no = @order_no_3, @items_json = CONCAT(N'[{"product_id":', @product_id_3, N',"quantity":1}]'); REVERT;
SELECT @order_id_3 = order_id, @amount_3 = total_amount FROM dbo.SalesOrder WHERE order_no = @order_no_3;
SET @failed_3 = 0;
BEGIN TRY
    EXECUTE AS USER = 'test_cashier'; EXEC dbo.sp_pay_order @order_id = @order_id_3, @payment_method = 'CASH', @paid_amount = @amount_3 + 0.01, @third_party_txn_no = CONCAT('AT-MISMATCH-', CONVERT(VARCHAR(36), NEWID())); REVERT;
END TRY
BEGIN CATCH
    IF USER_NAME() = 'test_cashier' REVERT;
    SET @failed_3 = 1;
END CATCH;
IF @failed_3 = 0 THROW 51006, 'Payment amount mismatch was accepted.', 1;
PRINT 'PASS: payment amount mismatch is rejected';
EXECUTE AS USER = 'test_cashier'; EXEC dbo.sp_pay_order @order_id = @order_id_3, @payment_method = 'CASH', @paid_amount = @amount_3, @third_party_txn_no = CONCAT('AT-OK-', CONVERT(VARCHAR(36), NEWID())); REVERT;
SET @failed_3 = 0;
BEGIN TRY
    EXECUTE AS USER = 'test_cashier'; EXEC dbo.sp_pay_order @order_id = @order_id_3, @payment_method = 'CASH', @paid_amount = @amount_3, @third_party_txn_no = CONCAT('AT-DUP-', CONVERT(VARCHAR(36), NEWID())); REVERT;
END TRY
BEGIN CATCH
    IF USER_NAME() = 'test_cashier' REVERT;
    SET @failed_3 = 1;
END CATCH;
IF @failed_3 = 0 THROW 51007, 'Duplicate payment was accepted.', 1;
PRINT 'PASS: duplicate payment is rejected';
ROLLBACK TRANSACTION;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
GO

/* Create a rollback-only FK fault at PointLedger insertion; no production injection parameter is added. */
SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET QUOTED_IDENTIFIER ON;
SET NUMERIC_ROUNDABORT OFF;
GO
BEGIN TRY
BEGIN TRANSACTION;
/* Dynamic DDL keeps the test-only trigger and its cleanup in this outer TRY/CATCH transaction. */
EXEC(N'CREATE TRIGGER dbo.tr_AT_payment_ledger_fk_fault ON dbo.PointLedger AFTER INSERT AS
BEGIN
    SET NOCOUNT ON;
    INSERT dbo.Delivery (order_id, delivery_status) VALUES (-1, ''WAITING_PICKUP'');
END;');
DECLARE @customer_id_4 BIGINT, @product_id_4 BIGINT, @order_id_4 BIGINT, @amount_4 DECIMAL(10,2), @failed_4 BIT, @order_no_4 VARCHAR(50);
SELECT TOP (1) @customer_id_4 = customer_id FROM dbo.Customer WHERE status = 'ACTIVE' ORDER BY customer_id;
SELECT TOP (1) @product_id_4 = p.product_id FROM dbo.Product AS p WHERE p.status = 'ACTIVE' AND p.product_type = 'SINGLE' AND EXISTS (SELECT 1 FROM dbo.ProductBom AS b WHERE b.product_id = p.product_id) ORDER BY p.product_id;
SET @order_no_4 = CONCAT('AT-ROLLBACK-', CONVERT(VARCHAR(36), NEWID()));
EXECUTE AS USER = 'test_cashier'; EXEC dbo.sp_create_order @customer_id = @customer_id_4, @fulfillment_method = 'PICKUP', @order_no = @order_no_4, @items_json = CONCAT(N'[{"product_id":', @product_id_4, N',"quantity":1}]'); REVERT;
SELECT @order_id_4 = order_id, @amount_4 = total_amount FROM dbo.SalesOrder WHERE order_no = @order_no_4;
SET @failed_4 = 0;
BEGIN TRY
    EXECUTE AS USER = 'test_cashier'; EXEC dbo.sp_pay_order @order_id = @order_id_4, @payment_method = 'CASH', @paid_amount = @amount_4, @third_party_txn_no = CONCAT('AT-FAULT-', CONVERT(VARCHAR(36), NEWID())); REVERT;
END TRY
BEGIN CATCH
    IF USER_NAME() = 'test_cashier' REVERT;
    SET @failed_4 = 1;
END CATCH;
IF @failed_4 = 0 OR EXISTS (SELECT 1 FROM dbo.Payment WHERE order_id = @order_id_4) OR EXISTS (SELECT 1 FROM dbo.PointLedger WHERE order_id = @order_id_4) OR EXISTS (SELECT 1 FROM dbo.SalesOrder WHERE order_id = @order_id_4 AND order_status <> 'PENDING_PAYMENT')
    THROW 51008, 'Payment FK fault did not roll back payment, order, and ledger.', 1;
PRINT 'PASS: payment FK fault rolls back payment order and ledger';
ROLLBACK TRANSACTION;
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
/* A paid order cannot skip directly to pickup; item price remains a snapshot. */
BEGIN TRY
BEGIN TRANSACTION;
DECLARE @customer_id_5 BIGINT, @product_id_5 BIGINT, @order_id_5 BIGINT, @amount_5 DECIMAL(10,2), @price_before DECIMAL(10,2), @price_after DECIMAL(10,2), @failed_5 BIT, @order_no_5 VARCHAR(50);
SELECT TOP (1) @customer_id_5 = customer_id FROM dbo.Customer WHERE status = 'ACTIVE' ORDER BY customer_id;
SELECT TOP (1) @product_id_5 = p.product_id FROM dbo.Product AS p WHERE p.status = 'ACTIVE' AND p.product_type = 'SINGLE' AND EXISTS (SELECT 1 FROM dbo.ProductBom AS b WHERE b.product_id = p.product_id) ORDER BY p.product_id;
SET @order_no_5 = CONCAT('AT-SNAPSHOT-', CONVERT(VARCHAR(36), NEWID()));
EXECUTE AS USER = 'test_cashier'; EXEC dbo.sp_create_order @customer_id = @customer_id_5, @fulfillment_method = 'PICKUP', @order_no = @order_no_5, @items_json = CONCAT(N'[{"product_id":', @product_id_5, N',"quantity":1}]'); REVERT;
SELECT @order_id_5 = order_id, @amount_5 = total_amount FROM dbo.SalesOrder WHERE order_no = @order_no_5;
EXECUTE AS USER = 'test_cashier'; EXEC dbo.sp_pay_order @order_id = @order_id_5, @payment_method = 'CASH', @paid_amount = @amount_5, @third_party_txn_no = CONCAT('AT-SNAPSHOT-', CONVERT(VARCHAR(36), NEWID())); REVERT;
SET @failed_5 = 0;
BEGIN TRY
    EXECUTE AS USER = 'test_packer'; EXEC dbo.sp_pick_up_order @order_id = @order_id_5; REVERT;
END TRY
BEGIN CATCH
    IF USER_NAME() = 'test_packer' REVERT;
    SET @failed_5 = 1;
END CATCH;
IF @failed_5 = 0 THROW 51009, 'Invalid PAID to PICKED_UP transition was accepted.', 1;
PRINT 'PASS: invalid state transition is rejected';
SELECT @price_before = unit_price FROM dbo.SalesOrderItem WHERE order_id = @order_id_5 AND item_role = 'SELLABLE';
UPDATE dbo.Product SET base_price = base_price + 7.00 WHERE product_id = @product_id_5;
SELECT @price_after = unit_price FROM dbo.SalesOrderItem WHERE order_id = @order_id_5 AND item_role = 'SELLABLE';
IF @price_before <> @price_after THROW 51010, 'Order item price changed after product price change.', 1;
PRINT 'PASS: item price snapshot survives product price change';
ROLLBACK TRANSACTION;
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
/*
  Deterministic threshold-crossing fixture.  Like the Product fixture above, this is
  deployment-only master-data setup inside the outer rollback because no frozen A test
  fixture process exists.  It never runs under a business role and does not persist.
*/
/* Pickup terminal transition: verify snapshot arithmetic, known threshold crossing, and EFFECTIVE ledger. */
BEGIN TRY
BEGIN TRANSACTION;
DECLARE @customer_id_6 BIGINT, @product_id_6 BIGINT, @order_id_6 BIGINT, @amount_6 DECIMAL(10,2), @multiplier_6 DECIMAL(5,2), @planned_points_6 INT, @expected_level_6 BIGINT, @starting_level_6 BIGINT, @actual_level_6 BIGINT, @actual_points_6 INT, @paid_snapshot_6 DECIMAL(10,2), @multiplier_snapshot_6 DECIMAL(5,2), @threshold_6 INT, @ledger_status_6 VARCHAR(20), @order_no_6 VARCHAR(50);
SELECT TOP (1) @customer_id_6 = c.customer_id FROM dbo.Customer AS c WHERE c.status = 'ACTIVE' ORDER BY c.customer_id;
SELECT TOP (1) @product_id_6 = p.product_id FROM dbo.Product AS p WHERE p.status = 'ACTIVE' AND p.product_type = 'SINGLE' AND EXISTS (SELECT 1 FROM dbo.ProductBom AS b WHERE b.product_id = p.product_id) ORDER BY p.product_id;
SET @order_no_6 = CONCAT('AT-POINTS-', CONVERT(VARCHAR(36), NEWID()));
EXECUTE AS USER = 'test_cashier'; EXEC dbo.sp_create_order @customer_id = @customer_id_6, @fulfillment_method = 'PICKUP', @order_no = @order_no_6, @items_json = CONCAT(N'[{"product_id":', @product_id_6, N',"quantity":1}]'); REVERT;
SELECT @order_id_6 = order_id, @amount_6 = total_amount FROM dbo.SalesOrder WHERE order_no = @order_no_6;
SELECT @starting_level_6 = c.member_level_id, @multiplier_6 = ml.point_multiplier FROM dbo.Customer AS c INNER JOIN dbo.MemberLevel AS ml ON ml.member_level_id = c.member_level_id WHERE c.customer_id = @customer_id_6;
SET @planned_points_6 = FLOOR(@amount_6 * @multiplier_6);
IF @planned_points_6 <= 0 THROW 51011, 'Threshold fixture requires a positive one-order point delta.', 1;
SELECT TOP (1) @expected_level_6 = ml.member_level_id, @threshold_6 = ml.threshold_points
FROM dbo.MemberLevel AS ml
WHERE ml.status = 'ACTIVE'
  AND ml.threshold_points > (SELECT threshold_points FROM dbo.MemberLevel WHERE member_level_id = @starting_level_6)
  AND ml.threshold_points >= @planned_points_6
ORDER BY ml.threshold_points ASC, ml.member_level_id ASC;
IF @expected_level_6 IS NULL THROW 51011, 'Threshold fixture requires a distinct ACTIVE member level reachable by one order.', 1;
UPDATE dbo.Customer SET current_points = @threshold_6 - @planned_points_6 WHERE customer_id = @customer_id_6;
EXECUTE AS USER = 'test_cashier'; EXEC dbo.sp_pay_order @order_id = @order_id_6, @payment_method = 'CASH', @paid_amount = @amount_6, @third_party_txn_no = CONCAT('AT-POINTS-', CONVERT(VARCHAR(36), NEWID())); REVERT;
SELECT @paid_snapshot_6 = paid_amount_snapshot, @multiplier_snapshot_6 = point_multiplier_snapshot, @actual_points_6 = point_delta FROM dbo.PointLedger WHERE order_id = @order_id_6;
IF @actual_points_6 <> FLOOR(@paid_snapshot_6 * @multiplier_snapshot_6) THROW 51011, 'Point delta is not FLOOR of its persisted snapshots.', 1;
EXECUTE AS USER = 'test_chef'; EXEC dbo.sp_start_production @order_id = @order_id_6; REVERT;
EXECUTE AS USER = 'test_packer'; EXEC dbo.sp_finish_production @order_id = @order_id_6; EXEC dbo.sp_pick_up_order @order_id = @order_id_6; REVERT;
SELECT @ledger_status_6 = ledger_status FROM dbo.PointLedger WHERE order_id = @order_id_6;
SELECT @actual_level_6 = member_level_id FROM dbo.Customer WHERE customer_id = @customer_id_6;
IF @ledger_status_6 <> 'EFFECTIVE' OR @actual_level_6 <> @expected_level_6 OR @actual_level_6 = @starting_level_6 THROW 51011, 'Known active threshold crossing did not select the expected changed level.', 1;
PRINT 'PASS: pickup makes ledger effective with snapshot FLOOR points and known threshold level change';
ROLLBACK TRANSACTION;
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
/* Delivery terminal transition makes the pending ledger effective. */
BEGIN TRY
BEGIN TRANSACTION;
DECLARE @customer_id_7 BIGINT, @product_id_7 BIGINT, @order_id_7 BIGINT, @rider_id_7 BIGINT, @amount_7 DECIMAL(10,2), @ledger_status_7 VARCHAR(20), @order_no_7 VARCHAR(50);
SELECT TOP (1) @customer_id_7 = customer_id FROM dbo.Customer WHERE status = 'ACTIVE' ORDER BY customer_id;
SELECT TOP (1) @product_id_7 = p.product_id FROM dbo.Product AS p WHERE p.status = 'ACTIVE' AND p.product_type = 'SINGLE' AND EXISTS (SELECT 1 FROM dbo.ProductBom AS b WHERE b.product_id = p.product_id) ORDER BY p.product_id;
SELECT @rider_id_7 = employee_id FROM dbo.EmployeeAccount WHERE database_user_name = 'test_rider' AND status = 'ACTIVE';
IF @rider_id_7 IS NULL THROW 51012, 'B acceptance fixture requires active test_rider EmployeeAccount.', 1;
SET @order_no_7 = CONCAT('AT-DELIVERY-', CONVERT(VARCHAR(36), NEWID()));
EXECUTE AS USER = 'test_cashier'; EXEC dbo.sp_create_order @customer_id = @customer_id_7, @fulfillment_method = 'DELIVERY', @order_no = @order_no_7, @items_json = CONCAT(N'[{"product_id":', @product_id_7, N',"quantity":1}]'); REVERT;
SELECT @order_id_7 = order_id, @amount_7 = total_amount FROM dbo.SalesOrder WHERE order_no = @order_no_7;
EXECUTE AS USER = 'test_cashier'; EXEC dbo.sp_pay_order @order_id = @order_id_7, @payment_method = 'CASH', @paid_amount = @amount_7, @third_party_txn_no = CONCAT('AT-DELIVERY-', CONVERT(VARCHAR(36), NEWID())); REVERT;
EXECUTE AS USER = 'test_chef'; EXEC dbo.sp_start_production @order_id = @order_id_7; REVERT;
EXECUTE AS USER = 'test_packer'; EXEC dbo.sp_finish_production @order_id = @order_id_7; REVERT;
EXECUTE AS USER = 'test_rider'; EXEC dbo.sp_pick_up_delivery @order_id = @order_id_7, @rider_employee_id = @rider_id_7; EXEC dbo.sp_confirm_delivery @order_id = @order_id_7; REVERT;
SELECT @ledger_status_7 = ledger_status FROM dbo.PointLedger WHERE order_id = @order_id_7;
IF @ledger_status_7 <> 'EFFECTIVE' THROW 51013, 'Delivery completion did not make the ledger EFFECTIVE.', 1;
PRINT 'PASS: delivery completion makes ledger effective';
ROLLBACK TRANSACTION;
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
/* Full refund before inventory consumption cancels the order and refunds exactly the payment. */
BEGIN TRY
BEGIN TRANSACTION;
DECLARE @customer_id_8 BIGINT, @product_id_8 BIGINT, @order_id_8 BIGINT, @manager_id_8 BIGINT, @amount_8 DECIMAL(10,2), @order_status_8 VARCHAR(20), @payment_status_8 VARCHAR(20), @refunded_8 DECIMAL(10,2), @order_no_8 VARCHAR(50);
SELECT TOP (1) @customer_id_8 = customer_id FROM dbo.Customer WHERE status = 'ACTIVE' ORDER BY customer_id;
SELECT TOP (1) @product_id_8 = p.product_id FROM dbo.Product AS p WHERE p.status = 'ACTIVE' AND p.product_type = 'SINGLE' AND EXISTS (SELECT 1 FROM dbo.ProductBom AS b WHERE b.product_id = p.product_id) ORDER BY p.product_id;
SELECT @manager_id_8 = employee_id FROM dbo.EmployeeAccount WHERE database_user_name = 'test_store_manager' AND status = 'ACTIVE';
IF @manager_id_8 IS NULL THROW 51014, 'B acceptance fixture requires active test_store_manager EmployeeAccount.', 1;
SET @order_no_8 = CONCAT('AT-REFUND-', CONVERT(VARCHAR(36), NEWID()));
EXECUTE AS USER = 'test_cashier'; EXEC dbo.sp_create_order @customer_id = @customer_id_8, @fulfillment_method = 'PICKUP', @order_no = @order_no_8, @items_json = CONCAT(N'[{"product_id":', @product_id_8, N',"quantity":1}]'); REVERT;
SELECT @order_id_8 = order_id, @amount_8 = total_amount FROM dbo.SalesOrder WHERE order_no = @order_no_8;
EXECUTE AS USER = 'test_cashier'; EXEC dbo.sp_pay_order @order_id = @order_id_8, @payment_method = 'CASH', @paid_amount = @amount_8, @third_party_txn_no = CONCAT('AT-REFUND-', CONVERT(VARCHAR(36), NEWID())); REVERT;
EXECUTE AS USER = 'test_store_manager'; EXEC dbo.sp_cancel_or_refund_order @order_id = @order_id_8, @reason = 'REFUND', @operator_employee_id = @manager_id_8; REVERT;
SELECT @order_status_8 = order_status FROM dbo.SalesOrder WHERE order_id = @order_id_8;
SELECT @payment_status_8 = payment_status, @refunded_8 = refunded_amount FROM dbo.Payment WHERE order_id = @order_id_8;
IF @order_status_8 <> 'CANCELLED' OR @payment_status_8 <> 'REFUNDED' OR @refunded_8 <> @amount_8 THROW 51015, 'Full pre-consume refund result is incorrect.', 1;
PRINT 'PASS: full pre-consume refund cancels order and refunds paid amount';
ROLLBACK TRANSACTION;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
GO
