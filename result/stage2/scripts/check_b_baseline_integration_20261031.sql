-- C-side integration verification: B baseline_b through capture_baseline (2026-10-31)
USE KFC_DB;
SET NOCOUNT ON;
DECLARE @pass INT = 0, @fail INT = 0, @b BIGINT, @cnt INT, @err INT, @deny INT;
DECLARE @meta INT, @total BIGINT, @live BIGINT, @snap BIGINT;

SELECT @b = MAX(batch_id) FROM dbo.MigrationBatch WHERE batch_status = 'COMPLETED';
IF @b = 2 AND (SELECT COUNT(*) FROM dbo.MigrationBatch) = 2
   AND NOT EXISTS (SELECT 1 FROM dbo.MigrationBatch WHERE batch_status = 'CAPTURING')
BEGIN SET @pass += 1; PRINT 'PASS: two real-B batches COMPLETED, no CAPTURING'; END
ELSE BEGIN SET @fail += 1; PRINT 'FAIL: batch state'; END;

IF EXISTS (SELECT 1 FROM dbo.MigrationBatch WHERE batch_id = 2 AND previous_batch_id = 1)
BEGIN SET @pass += 1; PRINT 'PASS: batch 2 previous_batch_id = 1'; END
ELSE BEGIN SET @fail += 1; PRINT 'FAIL: previous_batch_id'; END;

SELECT @meta = COUNT(*), @total = SUM(row_count) FROM dbo.MigrationBaseline WHERE batch_id = @b;
IF @meta = 25 AND @total = 178
BEGIN SET @pass += 1; PRINT 'PASS: real-B batch metadata 25 tables / 178 rows'; END
ELSE BEGIN SET @fail += 1; PRINT 'FAIL: metadata'; END;

-- B row counts in metadata and live tables
IF (SELECT COUNT(*) FROM dbo.MigrationBaseline WHERE batch_id = @b
    AND ((table_name='SalesOrder' AND row_count=3) OR (table_name='SalesOrderItem' AND row_count=3)
      OR (table_name='Payment' AND row_count=2) OR (table_name='Delivery' AND row_count=1)
      OR (table_name='PointLedger' AND row_count=2))) = 5
BEGIN SET @pass += 1; PRINT 'PASS: B metadata row counts 3/3/2/1/2'; END
ELSE BEGIN SET @fail += 1; PRINT 'FAIL: B metadata row counts'; END;

-- exact value equality (batch 2) both directions
SELECT @cnt = COUNT(*) FROM (
    SELECT order_id,order_no,customer_id,order_status,fulfillment_method,pickup_code,total_amount,ordered_at,
           paid_at,production_started_at,production_finished_at,completed_at,cancelled_at,created_at,updated_at
    FROM dbo.Baseline_SalesOrder WHERE batch_id=@b
    EXCEPT
    SELECT order_id,order_no,customer_id,order_status,fulfillment_method,pickup_code,total_amount,ordered_at,
           paid_at,production_started_at,production_finished_at,completed_at,cancelled_at,created_at,updated_at
    FROM dbo.SalesOrder) x;
IF @cnt = 0
BEGIN SET @pass += 1; PRINT 'PASS: Baseline_SalesOrder 15 columns equal source'; END
ELSE BEGIN SET @fail += 1; PRINT 'FAIL: Baseline_SalesOrder values'; END;
SELECT @cnt = COUNT(*) FROM (
    SELECT order_id,order_no,customer_id,order_status,fulfillment_method,pickup_code,total_amount,ordered_at,
           paid_at,production_started_at,production_finished_at,completed_at,cancelled_at,created_at,updated_at
    FROM dbo.SalesOrder
    EXCEPT
    SELECT order_id,order_no,customer_id,order_status,fulfillment_method,pickup_code,total_amount,ordered_at,
           paid_at,production_started_at,production_finished_at,completed_at,cancelled_at,created_at,updated_at
    FROM dbo.Baseline_SalesOrder WHERE batch_id=@b) x;
IF @cnt = 0
BEGIN SET @pass += 1; PRINT 'PASS: SalesOrder reverse set equal'; END
ELSE BEGIN SET @fail += 1; PRINT 'FAIL: SalesOrder reverse set'; END;

SELECT @cnt = COUNT(*) FROM (
    SELECT order_item_id,order_id,product_id,parent_order_item_id,item_role,quantity,unit_price,promotion_id,created_at,updated_at
    FROM dbo.Baseline_SalesOrderItem WHERE batch_id=@b
    EXCEPT
    SELECT order_item_id,order_id,product_id,parent_order_item_id,item_role,quantity,unit_price,promotion_id,created_at,updated_at
    FROM dbo.SalesOrderItem) x;
IF @cnt = 0
BEGIN SET @pass += 1; PRINT 'PASS: Baseline_SalesOrderItem 10 columns equal source'; END
ELSE BEGIN SET @fail += 1; PRINT 'FAIL: Baseline_SalesOrderItem values'; END;
SELECT @cnt = COUNT(*) FROM (
    SELECT order_item_id,order_id,product_id,parent_order_item_id,item_role,quantity,unit_price,promotion_id,created_at,updated_at
    FROM dbo.SalesOrderItem
    EXCEPT
    SELECT order_item_id,order_id,product_id,parent_order_item_id,item_role,quantity,unit_price,promotion_id,created_at,updated_at
    FROM dbo.Baseline_SalesOrderItem WHERE batch_id=@b) x;
IF @cnt = 0
BEGIN SET @pass += 1; PRINT 'PASS: SalesOrderItem reverse set equal'; END
ELSE BEGIN SET @fail += 1; PRINT 'FAIL: SalesOrderItem reverse set'; END;

SELECT @cnt = COUNT(*) FROM (
    SELECT payment_id,order_id,payment_method,paid_amount,payment_status,paid_at,refunded_amount,refunded_at,
           third_party_txn_no,created_at,updated_at
    FROM dbo.Baseline_Payment WHERE batch_id=@b
    EXCEPT
    SELECT payment_id,order_id,payment_method,paid_amount,payment_status,paid_at,refunded_amount,refunded_at,
           third_party_txn_no,created_at,updated_at
    FROM dbo.Payment) x;
IF @cnt = 0
BEGIN SET @pass += 1; PRINT 'PASS: Baseline_Payment 11 columns equal source'; END
ELSE BEGIN SET @fail += 1; PRINT 'FAIL: Baseline_Payment values'; END;
SELECT @cnt = COUNT(*) FROM (
    SELECT payment_id,order_id,payment_method,paid_amount,payment_status,paid_at,refunded_amount,refunded_at,
           third_party_txn_no,created_at,updated_at
    FROM dbo.Payment
    EXCEPT
    SELECT payment_id,order_id,payment_method,paid_amount,payment_status,paid_at,refunded_amount,refunded_at,
           third_party_txn_no,created_at,updated_at
    FROM dbo.Baseline_Payment WHERE batch_id=@b) x;
IF @cnt = 0
BEGIN SET @pass += 1; PRINT 'PASS: Payment reverse set equal'; END
ELSE BEGIN SET @fail += 1; PRINT 'FAIL: Payment reverse set'; END;

SELECT @cnt = COUNT(*) FROM (
    SELECT delivery_id,order_id,rider_employee_id,delivery_status,picked_up_at,delivered_at,created_at,updated_at
    FROM dbo.Baseline_Delivery WHERE batch_id=@b
    EXCEPT
    SELECT delivery_id,order_id,rider_employee_id,delivery_status,picked_up_at,delivered_at,created_at,updated_at
    FROM dbo.Delivery) x;
IF @cnt = 0
BEGIN SET @pass += 1; PRINT 'PASS: Baseline_Delivery 8 columns equal source'; END
ELSE BEGIN SET @fail += 1; PRINT 'FAIL: Baseline_Delivery values'; END;
SELECT @cnt = COUNT(*) FROM (
    SELECT delivery_id,order_id,rider_employee_id,delivery_status,picked_up_at,delivered_at,created_at,updated_at
    FROM dbo.Delivery
    EXCEPT
    SELECT delivery_id,order_id,rider_employee_id,delivery_status,picked_up_at,delivered_at,created_at,updated_at
    FROM dbo.Baseline_Delivery WHERE batch_id=@b) x;
IF @cnt = 0
BEGIN SET @pass += 1; PRINT 'PASS: Delivery reverse set equal'; END
ELSE BEGIN SET @fail += 1; PRINT 'FAIL: Delivery reverse set'; END;

SELECT @cnt = COUNT(*) FROM (
    SELECT point_ledger_id,order_id,customer_id,paid_amount_snapshot,point_multiplier_snapshot,point_delta,
           ledger_status,created_at,effective_at
    FROM dbo.Baseline_PointLedger WHERE batch_id=@b
    EXCEPT
    SELECT point_ledger_id,order_id,customer_id,paid_amount_snapshot,point_multiplier_snapshot,point_delta,
           ledger_status,created_at,effective_at
    FROM dbo.PointLedger) x;
IF @cnt = 0
BEGIN SET @pass += 1; PRINT 'PASS: Baseline_PointLedger 9 columns equal source'; END
ELSE BEGIN SET @fail += 1; PRINT 'FAIL: Baseline_PointLedger values'; END;
SELECT @cnt = COUNT(*) FROM (
    SELECT point_ledger_id,order_id,customer_id,paid_amount_snapshot,point_multiplier_snapshot,point_delta,
           ledger_status,created_at,effective_at
    FROM dbo.PointLedger
    EXCEPT
    SELECT point_ledger_id,order_id,customer_id,paid_amount_snapshot,point_multiplier_snapshot,point_delta,
           ledger_status,created_at,effective_at
    FROM dbo.Baseline_PointLedger WHERE batch_id=@b) x;
IF @cnt = 0
BEGIN SET @pass += 1; PRINT 'PASS: PointLedger reverse set equal'; END
ELSE BEGIN SET @fail += 1; PRINT 'FAIL: PointLedger reverse set'; END;

-- public DENY on B snapshot (229 under a public-only user)
IF USER_ID(N'zz_pub_test') IS NOT NULL DROP USER zz_pub_test;
CREATE USER zz_pub_test WITHOUT LOGIN;
EXECUTE AS USER = N'zz_pub_test';
BEGIN TRY
    SELECT TOP (1) * FROM dbo.Baseline_SalesOrder;
    SET @deny = 0;
END TRY
BEGIN CATCH
    SET @deny = 1; SET @err = ERROR_NUMBER();
END CATCH;
REVERT;
DROP USER zz_pub_test;
IF @deny = 1 AND @err = 229
BEGIN SET @pass += 1; PRINT 'PASS: public cannot SELECT Baseline_SalesOrder (229)'; END
ELSE BEGIN SET @fail += 1; PRINT 'FAIL: public DENY'; END;

IF (SELECT COUNT(*) FROM dbo.SalesOrder) = 3 AND (SELECT COUNT(*) FROM dbo.SalesOrderItem) = 3
   AND (SELECT COUNT(*) FROM dbo.Payment) = 2 AND (SELECT COUNT(*) FROM dbo.Delivery) = 1
   AND (SELECT COUNT(*) FROM dbo.PointLedger) = 2
BEGIN SET @pass += 1; PRINT 'PASS: business tables unchanged by capture'; END
ELSE BEGIN SET @fail += 1; PRINT 'FAIL: business table rows changed'; END;

IF (SELECT object_digest FROM dbo.SchemaVersion WHERE version_code = N'v0.1') = dbo.fn_stage2_schema_digest()
BEGIN SET @pass += 1; PRINT 'PASS: v0.1 digest equals live'; END
ELSE BEGIN SET @fail += 1; PRINT 'FAIL: digest'; END;

PRINT 'RESULT: pass=' + CONVERT(VARCHAR(10), @pass) + ' fail=' + CONVERT(VARCHAR(10), @fail);
IF @fail <> 0 THROW 53191, N'B baseline integration verification failed', 1;
