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
/* Each expected THROW can doom the caller transaction because B uses XACT_ABORT ON.
   Roll back that whole test transaction before querying post-failure state. */
DECLARE @customer_id BIGINT, @product_id BIGINT, @inactive_product_id BIGINT, @no_bom_product_id BIGINT;
DECLARE @failed BIT, @error_number INT, @before_count INT, @after_count INT, @before_item_count INT, @after_item_count INT, @order_no VARCHAR(40), @items_json NVARCHAR(MAX);
SELECT TOP (1) @customer_id = c.customer_id FROM dbo.Customer AS c WHERE c.status = 'ACTIVE' ORDER BY c.customer_id;
SELECT TOP (1) @product_id = p.product_id FROM dbo.Product AS p WHERE p.status = 'ACTIVE' AND p.product_type = 'SINGLE' AND EXISTS (SELECT 1 FROM dbo.ProductBom AS b WHERE b.product_id = p.product_id) ORDER BY p.product_id;
IF @customer_id IS NULL OR @product_id IS NULL THROW 51000, 'B acceptance fixture requires an ACTIVE customer and ACTIVE SINGLE product with BOM.', 1;

SELECT @before_count = COUNT(*) FROM dbo.SalesOrder;
SELECT @before_item_count = COUNT(*) FROM dbo.SalesOrderItem;
SET @failed = 0; SET @error_number = NULL; SET @order_no = CONCAT('AT-BADJSON-', LEFT(CONVERT(VARCHAR(36), NEWID()), 12));
BEGIN TRY
    BEGIN TRANSACTION;
    EXECUTE AS USER = 'test_cashier';
    EXEC dbo.sp_create_order @customer_id = @customer_id, @fulfillment_method = 'PICKUP', @order_no = @order_no, @items_json = N'{not-json}';
    REVERT;
    ROLLBACK TRANSACTION;
END TRY
BEGIN CATCH
    SET @failed = 1; SET @error_number = ERROR_NUMBER();
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    IF USER_NAME() = 'test_cashier' REVERT;
END CATCH;
SELECT @after_count = COUNT(*) FROM dbo.SalesOrder;
SELECT @after_item_count = COUNT(*) FROM dbo.SalesOrderItem;
IF @failed = 0 OR @error_number <> 52104 OR @after_count <> @before_count OR @after_item_count <> @before_item_count THROW 51001, 'Invalid JSON was accepted, failed for the wrong reason, or left an order/item.', 1;
PRINT 'PASS: invalid JSON is rejected';

SET @failed = 0; SET @error_number = NULL; SET @order_no = CONCAT('AT-ZERO-', LEFT(CONVERT(VARCHAR(36), NEWID()), 12));
SET @items_json = CONCAT(N'[{"product_id":', @product_id, N',"quantity":0}]');
BEGIN TRY
    BEGIN TRANSACTION;
    EXECUTE AS USER = 'test_cashier';
    EXEC dbo.sp_create_order @customer_id = @customer_id, @fulfillment_method = 'PICKUP', @order_no = @order_no, @items_json = @items_json;
    REVERT;
    ROLLBACK TRANSACTION;
END TRY
BEGIN CATCH
    SET @failed = 1; SET @error_number = ERROR_NUMBER();
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    IF USER_NAME() = 'test_cashier' REVERT;
END CATCH;
SELECT @after_count = COUNT(*) FROM dbo.SalesOrder;
SELECT @after_item_count = COUNT(*) FROM dbo.SalesOrderItem;
IF @failed = 0 OR @error_number <> 52107 OR @after_count <> @before_count OR @after_item_count <> @before_item_count THROW 51002, 'Non-positive quantity was accepted, failed for the wrong reason, or left an order/item.', 1;
PRINT 'PASS: non-positive quantity is rejected';

/* A temporary master-data fixture avoids relying on a particular seed product being inactive/no-BOM. */
SET @failed = 0; SET @error_number = NULL; SET @order_no = CONCAT('AT-INACTIVE-', LEFT(CONVERT(VARCHAR(36), NEWID()), 12));
BEGIN TRY
    BEGIN TRANSACTION;
    INSERT dbo.Product (product_name, base_price, product_type, status)
    VALUES (CONCAT(N'AT inactive ', CONVERT(NVARCHAR(36), NEWID())), 1.00, 'SINGLE', 'INACTIVE');
    SET @inactive_product_id = CONVERT(BIGINT, SCOPE_IDENTITY());
    SET @items_json = CONCAT(N'[{"product_id":', @inactive_product_id, N',"quantity":1}]');
    EXECUTE AS USER = 'test_cashier';
    EXEC dbo.sp_create_order @customer_id = @customer_id, @fulfillment_method = 'PICKUP', @order_no = @order_no, @items_json = @items_json;
    REVERT;
    ROLLBACK TRANSACTION;
END TRY
BEGIN CATCH
    SET @failed = 1; SET @error_number = ERROR_NUMBER();
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    IF USER_NAME() = 'test_cashier' REVERT;
END CATCH;
SELECT @after_count = COUNT(*) FROM dbo.SalesOrder;
SELECT @after_item_count = COUNT(*) FROM dbo.SalesOrderItem;
IF @failed = 0 OR @error_number <> 52109 OR @after_count <> @before_count OR @after_item_count <> @before_item_count THROW 51003, 'Inactive product was accepted, failed for the wrong reason, or left an order/item.', 1;
PRINT 'PASS: inactive product is rejected';

SET @failed = 0; SET @error_number = NULL; SET @order_no = CONCAT('AT-NOBOM-', LEFT(CONVERT(VARCHAR(36), NEWID()), 12));
BEGIN TRY
    BEGIN TRANSACTION;
    INSERT dbo.Product (product_name, base_price, product_type, status)
    VALUES (CONCAT(N'AT no BOM ', CONVERT(NVARCHAR(36), NEWID())), 1.00, 'SINGLE', 'ACTIVE');
    SET @no_bom_product_id = CONVERT(BIGINT, SCOPE_IDENTITY());
    SET @items_json = CONCAT(N'[{"product_id":', @no_bom_product_id, N',"quantity":1}]');
    EXECUTE AS USER = 'test_cashier';
    EXEC dbo.sp_create_order @customer_id = @customer_id, @fulfillment_method = 'PICKUP', @order_no = @order_no, @items_json = @items_json;
    REVERT;
    ROLLBACK TRANSACTION;
END TRY
BEGIN CATCH
    SET @failed = 1; SET @error_number = ERROR_NUMBER();
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    IF USER_NAME() = 'test_cashier' REVERT;
END CATCH;
SELECT @after_count = COUNT(*) FROM dbo.SalesOrder;
SELECT @after_item_count = COUNT(*) FROM dbo.SalesOrderItem;
IF @failed = 0 OR @error_number <> 52111 OR @after_count <> @before_count OR @after_item_count <> @before_item_count THROW 51004, 'Active product without BOM was accepted, failed for the wrong reason, or left an order/item.', 1;
PRINT 'PASS: active product without BOM is rejected';
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
DECLARE @customer_id_2 BIGINT, @product_id_2 BIGINT, @order_id_2 BIGINT, @error_number_2 INT, @order_no_2 VARCHAR(40), @items_json_2 NVARCHAR(MAX);
SELECT TOP (1) @customer_id_2 = customer_id FROM dbo.Customer WHERE status = 'ACTIVE' ORDER BY customer_id;
SELECT TOP (1) @product_id_2 = p.product_id FROM dbo.Product AS p WHERE p.status = 'ACTIVE' AND p.product_type = 'SINGLE' AND EXISTS (SELECT 1 FROM dbo.ProductBom AS b WHERE b.product_id = p.product_id) ORDER BY p.product_id;
SET @order_no_2 = CONCAT('AT-UNPAID-', LEFT(CONVERT(VARCHAR(36), NEWID()), 12));
SET @items_json_2 = CONCAT(N'[{"product_id":', @product_id_2, N',"quantity":1}]');
BEGIN TRY
BEGIN TRANSACTION;
EXECUTE AS USER = 'test_cashier';
EXEC dbo.sp_create_order @customer_id = @customer_id_2, @fulfillment_method = 'PICKUP', @order_no = @order_no_2, @items_json = @items_json_2;
REVERT;
SELECT @order_id_2 = order_id FROM dbo.SalesOrder WHERE order_no = @order_no_2;
EXECUTE AS USER = 'test_chef'; EXEC dbo.sp_start_production @order_id = @order_id_2; REVERT;
SET @error_number_2 = NULL;
END TRY
BEGIN CATCH
    SET @error_number_2 = ERROR_NUMBER();
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    IF USER_NAME() IN ('test_cashier', 'test_chef') REVERT;
END CATCH;
IF @error_number_2 <> 52301 OR EXISTS (SELECT 1 FROM dbo.SalesOrder WHERE order_no = @order_no_2)
    THROW 51005, 'Unpaid order production rejection did not return 52301 and roll back the test order.', 1;
PRINT 'PASS: unpaid order cannot start production';
GO

SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET QUOTED_IDENTIFIER ON;
SET NUMERIC_ROUNDABORT OFF;
GO
/* Wrong payment amount and a second payment are both rejected in independent rollback-only cases. */
DECLARE @customer_id_3 BIGINT, @product_id_3 BIGINT, @order_id_3 BIGINT, @amount_3 DECIMAL(10,2), @mismatch_amount_3 DECIMAL(10,2), @error_number_3 INT, @order_no_3 VARCHAR(40), @items_json_3 NVARCHAR(MAX), @mismatch_txn_3 VARCHAR(50), @success_txn_3 VARCHAR(50), @duplicate_txn_3 VARCHAR(50);
SELECT TOP (1) @customer_id_3 = customer_id FROM dbo.Customer WHERE status = 'ACTIVE' ORDER BY customer_id;
SELECT TOP (1) @product_id_3 = p.product_id FROM dbo.Product AS p WHERE p.status = 'ACTIVE' AND p.product_type = 'SINGLE' AND EXISTS (SELECT 1 FROM dbo.ProductBom AS b WHERE b.product_id = p.product_id) ORDER BY p.product_id;
SET @order_no_3 = CONCAT('AT-PAY-', LEFT(CONVERT(VARCHAR(36), NEWID()), 12));
SET @items_json_3 = CONCAT(N'[{"product_id":', @product_id_3, N',"quantity":1}]');
BEGIN TRY
BEGIN TRANSACTION;
EXECUTE AS USER = 'test_cashier'; EXEC dbo.sp_create_order @customer_id = @customer_id_3, @fulfillment_method = 'PICKUP', @order_no = @order_no_3, @items_json = @items_json_3; REVERT;
SELECT @order_id_3 = order_id, @amount_3 = total_amount FROM dbo.SalesOrder WHERE order_no = @order_no_3;
SET @mismatch_amount_3 = @amount_3 + 0.01;
SET @mismatch_txn_3 = CONCAT('AT-MISMATCH-', LEFT(CONVERT(VARCHAR(36), NEWID()), 12));
EXECUTE AS USER = 'test_cashier'; EXEC dbo.sp_pay_order @order_id = @order_id_3, @payment_method = 'CASH', @paid_amount = @mismatch_amount_3, @third_party_txn_no = @mismatch_txn_3; REVERT;
SET @error_number_3 = NULL;
END TRY
BEGIN CATCH
    SET @error_number_3 = ERROR_NUMBER();
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    IF USER_NAME() = 'test_cashier' REVERT;
END CATCH;
IF @error_number_3 <> 52202 OR EXISTS (SELECT 1 FROM dbo.SalesOrder WHERE order_no = @order_no_3)
    THROW 51006, 'Payment amount mismatch did not return 52202 and roll back the test order.', 1;
PRINT 'PASS: payment amount mismatch is rejected';

SET @order_no_3 = CONCAT('AT-DUPPAY-', LEFT(CONVERT(VARCHAR(36), NEWID()), 12));
SET @items_json_3 = CONCAT(N'[{"product_id":', @product_id_3, N',"quantity":1}]');
BEGIN TRY
BEGIN TRANSACTION;
EXECUTE AS USER = 'test_cashier'; EXEC dbo.sp_create_order @customer_id = @customer_id_3, @fulfillment_method = 'PICKUP', @order_no = @order_no_3, @items_json = @items_json_3; REVERT;
SELECT @order_id_3 = order_id, @amount_3 = total_amount FROM dbo.SalesOrder WHERE order_no = @order_no_3;
SET @success_txn_3 = CONCAT('AT-OK-', LEFT(CONVERT(VARCHAR(36), NEWID()), 12));
EXECUTE AS USER = 'test_cashier'; EXEC dbo.sp_pay_order @order_id = @order_id_3, @payment_method = 'CASH', @paid_amount = @amount_3, @third_party_txn_no = @success_txn_3; REVERT;
SET @duplicate_txn_3 = CONCAT('AT-DUP-', LEFT(CONVERT(VARCHAR(36), NEWID()), 12));
EXECUTE AS USER = 'test_cashier'; EXEC dbo.sp_pay_order @order_id = @order_id_3, @payment_method = 'CASH', @paid_amount = @amount_3, @third_party_txn_no = @duplicate_txn_3; REVERT;
SET @error_number_3 = NULL;
END TRY
BEGIN CATCH
    SET @error_number_3 = ERROR_NUMBER();
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    IF USER_NAME() = 'test_cashier' REVERT;
END CATCH;
IF @error_number_3 <> 52201 OR EXISTS (SELECT 1 FROM dbo.SalesOrder WHERE order_no = @order_no_3)
    THROW 51007, 'A second payment did not return 52201 and roll back the test order.', 1;
PRINT 'PASS: duplicate payment is rejected';
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
DECLARE @customer_id_4 BIGINT, @product_id_4 BIGINT, @order_id_4 BIGINT, @amount_4 DECIMAL(10,2), @failed_4 INT, @order_no_4 VARCHAR(40), @items_json_4 NVARCHAR(MAX), @fault_txn_4 VARCHAR(50);
SELECT TOP (1) @customer_id_4 = customer_id FROM dbo.Customer WHERE status = 'ACTIVE' ORDER BY customer_id;
SELECT TOP (1) @product_id_4 = p.product_id FROM dbo.Product AS p WHERE p.status = 'ACTIVE' AND p.product_type = 'SINGLE' AND EXISTS (SELECT 1 FROM dbo.ProductBom AS b WHERE b.product_id = p.product_id) ORDER BY p.product_id;
SET @order_no_4 = CONCAT('AT-ROLLBACK-', LEFT(CONVERT(VARCHAR(36), NEWID()), 12));
SET @items_json_4 = CONCAT(N'[{"product_id":', @product_id_4, N',"quantity":1}]');
EXECUTE AS USER = 'test_cashier'; EXEC dbo.sp_create_order @customer_id = @customer_id_4, @fulfillment_method = 'PICKUP', @order_no = @order_no_4, @items_json = @items_json_4; REVERT;
SELECT @order_id_4 = order_id, @amount_4 = total_amount FROM dbo.SalesOrder WHERE order_no = @order_no_4;
SET @fault_txn_4 = CONCAT('AT-FAULT-', LEFT(CONVERT(VARCHAR(36), NEWID()), 12));
EXECUTE AS USER = 'test_cashier'; EXEC dbo.sp_pay_order @order_id = @order_id_4, @payment_method = 'CASH', @paid_amount = @amount_4, @third_party_txn_no = @fault_txn_4; REVERT;
END TRY
BEGIN CATCH
    SET @failed_4 = ERROR_NUMBER();
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    IF USER_NAME() = 'test_cashier' REVERT;
END CATCH;
IF @failed_4 <> 547 OR EXISTS (SELECT 1 FROM dbo.SalesOrder WHERE order_no = @order_no_4) OR EXISTS (SELECT 1 FROM dbo.Payment WHERE order_id = @order_id_4) OR EXISTS (SELECT 1 FROM dbo.PointLedger WHERE order_id = @order_id_4)
    THROW 51008, 'Payment FK fault did not return 547 and roll back payment, order, and ledger.', 1;
PRINT 'PASS: payment FK fault rolls back payment order and ledger';
GO

SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET QUOTED_IDENTIFIER ON;
SET NUMERIC_ROUNDABORT OFF;
GO
/* A paid order cannot skip directly to pickup. */
DECLARE @customer_id_5 BIGINT, @product_id_5 BIGINT, @order_id_5 BIGINT, @amount_5 DECIMAL(10,2), @error_number_5 INT, @order_no_5 VARCHAR(40), @items_json_5 NVARCHAR(MAX), @snapshot_txn_5 VARCHAR(50);
SELECT TOP (1) @customer_id_5 = customer_id FROM dbo.Customer WHERE status = 'ACTIVE' ORDER BY customer_id;
SELECT TOP (1) @product_id_5 = p.product_id FROM dbo.Product AS p WHERE p.status = 'ACTIVE' AND p.product_type = 'SINGLE' AND EXISTS (SELECT 1 FROM dbo.ProductBom AS b WHERE b.product_id = p.product_id) ORDER BY p.product_id;
SET @order_no_5 = CONCAT('AT-SNAPSHOT-', LEFT(CONVERT(VARCHAR(36), NEWID()), 12));
SET @items_json_5 = CONCAT(N'[{"product_id":', @product_id_5, N',"quantity":1}]');
BEGIN TRY
BEGIN TRANSACTION;
EXECUTE AS USER = 'test_cashier'; EXEC dbo.sp_create_order @customer_id = @customer_id_5, @fulfillment_method = 'PICKUP', @order_no = @order_no_5, @items_json = @items_json_5; REVERT;
SELECT @order_id_5 = order_id, @amount_5 = total_amount FROM dbo.SalesOrder WHERE order_no = @order_no_5;
SET @snapshot_txn_5 = CONCAT('AT-SNAPSHOT-', LEFT(CONVERT(VARCHAR(36), NEWID()), 12));
EXECUTE AS USER = 'test_cashier'; EXEC dbo.sp_pay_order @order_id = @order_id_5, @payment_method = 'CASH', @paid_amount = @amount_5, @third_party_txn_no = @snapshot_txn_5; REVERT;
EXECUTE AS USER = 'test_packer'; EXEC dbo.sp_pick_up_order @order_id = @order_id_5; REVERT;
SET @error_number_5 = NULL;
END TRY
BEGIN CATCH
    SET @error_number_5 = ERROR_NUMBER();
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    IF USER_NAME() = 'test_packer' REVERT;
    IF USER_NAME() = 'test_cashier' REVERT;
END CATCH;
IF @error_number_5 <> 52501 OR EXISTS (SELECT 1 FROM dbo.SalesOrder WHERE order_no = @order_no_5)
    THROW 51009, 'Invalid PAID to PICKED_UP transition did not return 52501 and roll back the test order.', 1;
PRINT 'PASS: invalid state transition is rejected';
GO

/* Order item price remains a snapshot when current master price changes. */
BEGIN TRY
BEGIN TRANSACTION;
DECLARE @customer_id_5b BIGINT, @product_id_5b BIGINT, @order_id_5b BIGINT, @price_before_5b DECIMAL(10,2), @price_after_5b DECIMAL(10,2), @order_no_5b VARCHAR(40), @items_json_5b NVARCHAR(MAX);
SELECT TOP (1) @customer_id_5b = customer_id FROM dbo.Customer WHERE status = 'ACTIVE' ORDER BY customer_id;
SELECT TOP (1) @product_id_5b = p.product_id FROM dbo.Product AS p WHERE p.status = 'ACTIVE' AND p.product_type = 'SINGLE' AND EXISTS (SELECT 1 FROM dbo.ProductBom AS b WHERE b.product_id = p.product_id) ORDER BY p.product_id;
SET @order_no_5b = CONCAT('AT-SNAPSHOT-', LEFT(CONVERT(VARCHAR(36), NEWID()), 12));
SET @items_json_5b = CONCAT(N'[{"product_id":', @product_id_5b, N',"quantity":1}]');
EXECUTE AS USER = 'test_cashier'; EXEC dbo.sp_create_order @customer_id = @customer_id_5b, @fulfillment_method = 'PICKUP', @order_no = @order_no_5b, @items_json = @items_json_5b; REVERT;
SELECT @order_id_5b = order_id FROM dbo.SalesOrder WHERE order_no = @order_no_5b;
SELECT @price_before_5b = unit_price FROM dbo.SalesOrderItem WHERE order_id = @order_id_5b AND item_role = 'SELLABLE';
UPDATE dbo.Product SET base_price = base_price + 7.00 WHERE product_id = @product_id_5b;
SELECT @price_after_5b = unit_price FROM dbo.SalesOrderItem WHERE order_id = @order_id_5b AND item_role = 'SELLABLE';
IF @order_id_5b IS NULL OR @price_before_5b IS NULL OR @price_after_5b IS NULL OR @price_before_5b <> @price_after_5b
    THROW 51010, 'Order item price snapshot is missing or changed after product price change.', 1;
PRINT 'PASS: item price snapshot survives product price change';
ROLLBACK TRANSACTION;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    IF USER_NAME() LIKE N'test[_]%' REVERT;
    THROW;
END CATCH;
GO

/* Combo parent expansion is shared by B order creation, A BOM view, and C inventory lock. */
BEGIN TRY
BEGIN TRANSACTION;
DECLARE @combo_customer_id BIGINT, @combo_product_id BIGINT, @combo_order_id BIGINT, @combo_qty INT = 2, @combo_parent_item_id BIGINT, @combo_parent_price DECIMAL(10,2), @combo_total DECIMAL(10,2), @combo_order_no VARCHAR(40), @combo_items_json NVARCHAR(MAX), @combo_item_count INT, @combo_expected_component_count INT, @combo_actual_component_count INT;
SELECT TOP (1) @combo_customer_id = customer_id FROM dbo.Customer WHERE status = 'ACTIVE' ORDER BY customer_id;
SELECT TOP (1) @combo_product_id = p.product_id
FROM dbo.Product AS p
WHERE p.product_type = 'COMBO' AND p.status = 'ACTIVE' AND p.base_price > 0
  AND EXISTS (SELECT 1 FROM dbo.ComboComponent AS cc WHERE cc.combo_product_id = p.product_id)
  AND NOT EXISTS (
      SELECT 1
      FROM dbo.ComboComponent AS cc
      LEFT JOIN dbo.Product AS child ON child.product_id = cc.child_product_id
      WHERE cc.combo_product_id = p.product_id
        AND (cc.quantity <= 0 OR child.product_id IS NULL OR child.status <> 'ACTIVE'
             OR child.product_type <> 'SINGLE'
             OR NOT EXISTS (SELECT 1 FROM dbo.ProductBom AS b WHERE b.product_id = child.product_id))
  )
  AND NOT EXISTS (
      SELECT 1
      FROM dbo.ComboComponent AS cc
      JOIN dbo.ProductBom AS b ON b.product_id = cc.child_product_id
      LEFT JOIN dbo.Ingredient AS i ON i.ingredient_id = b.ingredient_id
      WHERE cc.combo_product_id = p.product_id
        AND (b.usage_qty <= 0 OR i.ingredient_id IS NULL OR i.status <> 'ACTIVE'
             OR NOT EXISTS (SELECT 1 FROM dbo.Inventory AS inv WHERE inv.ingredient_id = i.ingredient_id))
  )
  AND NOT EXISTS (
      SELECT demand.ingredient_id
      FROM (
          SELECT b.ingredient_id, SUM(b.usage_qty * cc.quantity * @combo_qty) AS required_qty
          FROM dbo.ComboComponent AS cc
          JOIN dbo.ProductBom AS b ON b.product_id = cc.child_product_id
          WHERE cc.combo_product_id = p.product_id
          GROUP BY b.ingredient_id
      ) AS demand
      LEFT JOIN dbo.Inventory AS inv ON inv.ingredient_id = demand.ingredient_id
      WHERE inv.ingredient_id IS NULL OR inv.on_hand_qty - inv.locked_qty < demand.required_qty
  )
ORDER BY p.product_id;
IF @combo_customer_id IS NULL OR @combo_product_id IS NULL
    THROW 51016, 'Combo integration fixture requires an active customer, a valid combo with active single/BOM ingredients, and sufficient C inventory.', 1;

DECLARE @combo_need TABLE (ingredient_id BIGINT PRIMARY KEY, required_qty DECIMAL(12,3) NOT NULL);
INSERT @combo_need (ingredient_id, required_qty)
SELECT b.ingredient_id, SUM(b.usage_qty * cc.quantity * @combo_qty)
FROM dbo.ComboComponent AS cc
JOIN dbo.ProductBom AS b ON b.product_id = cc.child_product_id
WHERE cc.combo_product_id = @combo_product_id
GROUP BY b.ingredient_id;
SET @combo_order_no = CONCAT('AT-COMBO-', LEFT(CONVERT(VARCHAR(36), NEWID()), 12));
SET @combo_items_json = CONCAT(N'[{"product_id":', @combo_product_id, N',"quantity":', @combo_qty, N'}]');
EXECUTE AS USER = 'test_cashier';
EXEC dbo.sp_create_order @customer_id = @combo_customer_id, @fulfillment_method = 'PICKUP', @order_no = @combo_order_no, @items_json = @combo_items_json;
REVERT;
SELECT @combo_order_id = order_id, @combo_total = total_amount FROM dbo.SalesOrder WHERE order_no = @combo_order_no;
SELECT @combo_item_count = COUNT(*)
FROM dbo.SalesOrderItem
WHERE order_id = @combo_order_id AND product_id = @combo_product_id AND item_role = 'SELLABLE';
SELECT @combo_parent_item_id = MAX(order_item_id), @combo_parent_price = MAX(unit_price)
FROM dbo.SalesOrderItem
WHERE order_id = @combo_order_id AND product_id = @combo_product_id AND item_role = 'SELLABLE' AND quantity = @combo_qty;
IF @combo_item_count <> 1 OR @combo_parent_item_id IS NULL OR @combo_parent_price IS NULL OR @combo_total IS NULL OR @combo_total <> @combo_parent_price * @combo_qty
    THROW 51017, 'Combo parent price/quantity snapshot is incorrect.', 1;
SELECT @combo_expected_component_count = COUNT(*)
FROM dbo.ComboComponent WHERE combo_product_id = @combo_product_id;
SELECT @combo_actual_component_count = COUNT(*)
FROM dbo.SalesOrderItem WHERE order_id = @combo_order_id AND item_role = 'COMPONENT';
IF @combo_actual_component_count <> @combo_expected_component_count
    THROW 51018, 'B did not create exactly one component snapshot row per combo child.', 1;

IF EXISTS (
    SELECT cc.child_product_id, @combo_parent_item_id AS parent_order_item_id, SUM(CONVERT(BIGINT, @combo_qty) * cc.quantity) AS quantity
    FROM dbo.ComboComponent AS cc WHERE cc.combo_product_id = @combo_product_id
    GROUP BY cc.child_product_id
    EXCEPT
    SELECT product_id, parent_order_item_id, SUM(CONVERT(BIGINT, quantity))
    FROM dbo.SalesOrderItem WHERE order_id = @combo_order_id AND item_role = 'COMPONENT'
    GROUP BY product_id, parent_order_item_id
) OR EXISTS (
    SELECT product_id, parent_order_item_id, SUM(CONVERT(BIGINT, quantity))
    FROM dbo.SalesOrderItem WHERE order_id = @combo_order_id AND item_role = 'COMPONENT'
    GROUP BY product_id, parent_order_item_id
    EXCEPT
    SELECT cc.child_product_id, @combo_parent_item_id AS parent_order_item_id, SUM(CONVERT(BIGINT, @combo_qty) * cc.quantity) AS quantity
    FROM dbo.ComboComponent AS cc WHERE cc.combo_product_id = @combo_product_id
    GROUP BY cc.child_product_id
)
    THROW 51019, 'B did not expand the combo into the exact parent-linked component snapshot.', 1;

IF EXISTS (
    SELECT cc.child_product_id, b.ingredient_id, CAST(SUM(b.usage_qty * cc.quantity) AS DECIMAL(12,3)) AS qty_per_sale
    FROM dbo.ComboComponent AS cc
    JOIN dbo.ProductBom AS b ON b.product_id = cc.child_product_id
    WHERE cc.combo_product_id = @combo_product_id
    GROUP BY cc.child_product_id, b.ingredient_id
    EXCEPT
    SELECT used_product_id, ingredient_id, qty_per_sale
    FROM dbo.v_product_bom_detail WHERE sale_product_id = @combo_product_id
) OR EXISTS (
    SELECT used_product_id, ingredient_id, qty_per_sale
    FROM dbo.v_product_bom_detail WHERE sale_product_id = @combo_product_id
    EXCEPT
    SELECT cc.child_product_id, b.ingredient_id, CAST(SUM(b.usage_qty * cc.quantity) AS DECIMAL(12,3)) AS qty_per_sale
    FROM dbo.ComboComponent AS cc
    JOIN dbo.ProductBom AS b ON b.product_id = cc.child_product_id
    WHERE cc.combo_product_id = @combo_product_id
    GROUP BY cc.child_product_id, b.ingredient_id
)
    THROW 51020, 'A v_product_bom_detail does not expose the combo child/BOM expansion expected by B.', 1;

IF EXISTS (
    SELECT ingredient_id, required_qty FROM @combo_need
    EXCEPT
    SELECT ingredient_id, SUM(locked_delta)
    FROM dbo.InventoryMovement
    WHERE reference_type = 'ORDER' AND reference_id = @combo_order_id AND movement_type = 'LOCK'
    GROUP BY ingredient_id
) OR EXISTS (
    SELECT ingredient_id, SUM(locked_delta)
    FROM dbo.InventoryMovement
    WHERE reference_type = 'ORDER' AND reference_id = @combo_order_id AND movement_type = 'LOCK'
    GROUP BY ingredient_id
    EXCEPT
    SELECT ingredient_id, required_qty FROM @combo_need
)
    THROW 51021, 'C sp_lock_order_inventory did not lock the exact combo-expanded BOM quantities.', 1;

PRINT 'PASS: combo order expands through B item snapshot, A BOM view, and C inventory lock';
ROLLBACK TRANSACTION;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    IF USER_NAME() = 'test_cashier' REVERT;
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
DECLARE @customer_id_6 BIGINT, @product_id_6 BIGINT, @order_id_6 BIGINT, @amount_6 DECIMAL(10,2), @multiplier_6 DECIMAL(5,2), @planned_points_6 INT, @expected_level_6 BIGINT, @starting_level_6 BIGINT, @actual_level_6 BIGINT, @actual_points_6 INT, @paid_snapshot_6 DECIMAL(10,2), @multiplier_snapshot_6 DECIMAL(5,2), @threshold_6 INT, @ledger_status_6 VARCHAR(20), @order_no_6 VARCHAR(40), @items_json_6 NVARCHAR(MAX), @points_txn_6 VARCHAR(50);
DECLARE @level_suffix_6 VARCHAR(12) = LEFT(REPLACE(CONVERT(VARCHAR(36), NEWID()), '-', ''), 12), @base_level_6 BIGINT, @mobile_6 VARCHAR(20);
INSERT dbo.MemberLevel (level_name, point_multiplier, threshold_points, status)
VALUES (CONCAT('AT-Base-', @level_suffix_6), 1.00, 0, 'ACTIVE'),
       (CONCAT('AT-Level-10-', @level_suffix_6), 1.00, 10, 'ACTIVE'),
       (CONCAT('AT-Level-20-', @level_suffix_6), 1.00, 20, 'ACTIVE');
SELECT @base_level_6 = member_level_id FROM dbo.MemberLevel WHERE level_name = CONCAT('AT-Base-', @level_suffix_6);
SET @mobile_6 = CONCAT('1', RIGHT(CONCAT('0000000000', CONVERT(VARCHAR(10), ABS(CONVERT(BIGINT, CHECKSUM(NEWID()))))), 10));
INSERT dbo.Customer (mobile, customer_type, member_level_id, current_points, status)
VALUES (@mobile_6, 'WOW', @base_level_6, 0, 'ACTIVE');
SET @customer_id_6 = CONVERT(BIGINT, SCOPE_IDENTITY());
SELECT TOP (1) @product_id_6 = p.product_id FROM dbo.Product AS p WHERE p.status = 'ACTIVE' AND p.product_type = 'SINGLE' AND EXISTS (SELECT 1 FROM dbo.ProductBom AS b WHERE b.product_id = p.product_id) ORDER BY p.product_id;
SET @order_no_6 = CONCAT('AT-POINTS-', LEFT(CONVERT(VARCHAR(36), NEWID()), 12));
SET @items_json_6 = CONCAT(N'[{"product_id":', @product_id_6, N',"quantity":1}]');
EXECUTE AS USER = 'test_cashier'; EXEC dbo.sp_create_order @customer_id = @customer_id_6, @fulfillment_method = 'PICKUP', @order_no = @order_no_6, @items_json = @items_json_6; REVERT;
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
SET @points_txn_6 = CONCAT('AT-POINTS-', LEFT(CONVERT(VARCHAR(36), NEWID()), 12));
EXECUTE AS USER = 'test_cashier'; EXEC dbo.sp_pay_order @order_id = @order_id_6, @payment_method = 'CASH', @paid_amount = @amount_6, @third_party_txn_no = @points_txn_6; REVERT;
SELECT @paid_snapshot_6 = paid_amount_snapshot, @multiplier_snapshot_6 = point_multiplier_snapshot, @actual_points_6 = point_delta FROM dbo.PointLedger WHERE order_id = @order_id_6;
IF @paid_snapshot_6 IS NULL OR @multiplier_snapshot_6 IS NULL OR @actual_points_6 IS NULL
   OR @actual_points_6 <> FLOOR(@paid_snapshot_6 * @multiplier_snapshot_6)
    THROW 51011, 'Point snapshots or delta are missing, or delta is not FLOOR of the persisted snapshots.', 1;
EXECUTE AS USER = 'test_chef'; EXEC dbo.sp_start_production @order_id = @order_id_6; REVERT;
EXECUTE AS USER = 'test_packer'; EXEC dbo.sp_finish_production @order_id = @order_id_6; EXEC dbo.sp_pick_up_order @order_id = @order_id_6; REVERT;
SELECT @ledger_status_6 = ledger_status FROM dbo.PointLedger WHERE order_id = @order_id_6;
SELECT @actual_level_6 = member_level_id FROM dbo.Customer WHERE customer_id = @customer_id_6;
IF @ledger_status_6 IS NULL OR @actual_level_6 IS NULL OR @expected_level_6 IS NULL
   OR @ledger_status_6 <> 'EFFECTIVE' OR @actual_level_6 <> @expected_level_6 OR @actual_level_6 = @starting_level_6
    THROW 51011, 'Known active threshold crossing did not select the expected changed level.', 1;
PRINT 'PASS: pickup makes ledger effective with snapshot FLOOR points and known threshold level change';
ROLLBACK TRANSACTION;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    IF USER_NAME() LIKE N'test[_]%' REVERT;
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
DECLARE @customer_id_7 BIGINT, @product_id_7 BIGINT, @order_id_7 BIGINT, @rider_id_7 BIGINT, @amount_7 DECIMAL(10,2), @ledger_status_7 VARCHAR(20), @order_no_7 VARCHAR(40), @items_json_7 NVARCHAR(MAX), @delivery_txn_7 VARCHAR(50);
SELECT TOP (1) @customer_id_7 = customer_id FROM dbo.Customer WHERE status = 'ACTIVE' ORDER BY customer_id;
SELECT TOP (1) @product_id_7 = p.product_id FROM dbo.Product AS p WHERE p.status = 'ACTIVE' AND p.product_type = 'SINGLE' AND EXISTS (SELECT 1 FROM dbo.ProductBom AS b WHERE b.product_id = p.product_id) ORDER BY p.product_id;
SELECT @rider_id_7 = employee_id FROM dbo.EmployeeAccount WHERE database_user_name = 'test_rider' AND status = 'ACTIVE';
IF @rider_id_7 IS NULL THROW 51012, 'B acceptance fixture requires active test_rider EmployeeAccount.', 1;
SET @order_no_7 = CONCAT('AT-DELIVERY-', LEFT(CONVERT(VARCHAR(36), NEWID()), 12));
SET @items_json_7 = CONCAT(N'[{"product_id":', @product_id_7, N',"quantity":1}]');
EXECUTE AS USER = 'test_cashier'; EXEC dbo.sp_create_order @customer_id = @customer_id_7, @fulfillment_method = 'DELIVERY', @order_no = @order_no_7, @items_json = @items_json_7; REVERT;
SELECT @order_id_7 = order_id, @amount_7 = total_amount FROM dbo.SalesOrder WHERE order_no = @order_no_7;
SET @delivery_txn_7 = CONCAT('AT-DELIVERY-', LEFT(CONVERT(VARCHAR(36), NEWID()), 12));
EXECUTE AS USER = 'test_cashier'; EXEC dbo.sp_pay_order @order_id = @order_id_7, @payment_method = 'CASH', @paid_amount = @amount_7, @third_party_txn_no = @delivery_txn_7; REVERT;
EXECUTE AS USER = 'test_chef'; EXEC dbo.sp_start_production @order_id = @order_id_7; REVERT;
EXECUTE AS USER = 'test_packer'; EXEC dbo.sp_finish_production @order_id = @order_id_7; REVERT;
EXECUTE AS USER = 'test_rider'; EXEC dbo.sp_pick_up_delivery @order_id = @order_id_7, @rider_employee_id = @rider_id_7; EXEC dbo.sp_confirm_delivery @order_id = @order_id_7; REVERT;
SELECT @ledger_status_7 = ledger_status FROM dbo.PointLedger WHERE order_id = @order_id_7;
IF @ledger_status_7 IS NULL OR @ledger_status_7 <> 'EFFECTIVE'
    THROW 51013, 'Delivery completion did not make an existing ledger EFFECTIVE.', 1;
PRINT 'PASS: delivery completion makes ledger effective';
ROLLBACK TRANSACTION;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    IF USER_NAME() LIKE N'test[_]%' REVERT;
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
DECLARE @customer_id_8 BIGINT, @product_id_8 BIGINT, @order_id_8 BIGINT, @manager_id_8 BIGINT, @amount_8 DECIMAL(10,2), @order_status_8 VARCHAR(20), @payment_status_8 VARCHAR(20), @refunded_8 DECIMAL(10,2), @order_no_8 VARCHAR(40), @items_json_8 NVARCHAR(MAX), @refund_txn_8 VARCHAR(50);
SELECT TOP (1) @customer_id_8 = customer_id FROM dbo.Customer WHERE status = 'ACTIVE' ORDER BY customer_id;
SELECT TOP (1) @product_id_8 = p.product_id FROM dbo.Product AS p WHERE p.status = 'ACTIVE' AND p.product_type = 'SINGLE' AND EXISTS (SELECT 1 FROM dbo.ProductBom AS b WHERE b.product_id = p.product_id) ORDER BY p.product_id;
SELECT @manager_id_8 = employee_id FROM dbo.EmployeeAccount WHERE database_user_name = 'test_store_manager' AND status = 'ACTIVE';
IF @manager_id_8 IS NULL THROW 51014, 'B acceptance fixture requires active test_store_manager EmployeeAccount.', 1;
SET @order_no_8 = CONCAT('AT-REFUND-', LEFT(CONVERT(VARCHAR(36), NEWID()), 12));
SET @items_json_8 = CONCAT(N'[{"product_id":', @product_id_8, N',"quantity":1}]');
EXECUTE AS USER = 'test_cashier'; EXEC dbo.sp_create_order @customer_id = @customer_id_8, @fulfillment_method = 'PICKUP', @order_no = @order_no_8, @items_json = @items_json_8; REVERT;
SELECT @order_id_8 = order_id, @amount_8 = total_amount FROM dbo.SalesOrder WHERE order_no = @order_no_8;
SET @refund_txn_8 = CONCAT('AT-REFUND-', LEFT(CONVERT(VARCHAR(36), NEWID()), 12));
EXECUTE AS USER = 'test_cashier'; EXEC dbo.sp_pay_order @order_id = @order_id_8, @payment_method = 'CASH', @paid_amount = @amount_8, @third_party_txn_no = @refund_txn_8; REVERT;
EXECUTE AS USER = 'test_store_manager'; EXEC dbo.sp_cancel_or_refund_order @order_id = @order_id_8, @reason = 'REFUND', @operator_employee_id = @manager_id_8; REVERT;
SELECT @order_status_8 = order_status FROM dbo.SalesOrder WHERE order_id = @order_id_8;
SELECT @payment_status_8 = payment_status, @refunded_8 = refunded_amount FROM dbo.Payment WHERE order_id = @order_id_8;
IF @order_status_8 IS NULL OR @payment_status_8 IS NULL OR @refunded_8 IS NULL OR @amount_8 IS NULL
   OR @order_status_8 <> 'CANCELLED' OR @payment_status_8 <> 'REFUNDED' OR @refunded_8 <> @amount_8
    THROW 51015, 'Full pre-consume refund rows or amounts are missing or incorrect.', 1;
PRINT 'PASS: full pre-consume refund cancels order and refunds paid amount';
ROLLBACK TRANSACTION;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    IF USER_NAME() LIKE N'test[_]%' REVERT;
    THROW;
END CATCH;
GO
