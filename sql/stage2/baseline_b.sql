-- B baseline snapshot, protocol migration-guide.md 2.5 / 3 (2026-10-30).
-- Called inside capture_baseline.sql's transaction, with @batch_id declared there.
-- No GO, transaction control, connection switch or business-table writes here.
-- All 53 source fields are preserved; snapshot keys include batch_id.

IF OBJECT_ID(N'dbo.Baseline_SalesOrder', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.Baseline_SalesOrder (
        batch_id BIGINT NOT NULL,
        [order_id] BIGINT NOT NULL,
        [order_no] VARCHAR(50) NOT NULL,
        [customer_id] BIGINT NOT NULL,
        [order_status] VARCHAR(20) NOT NULL,
        [fulfillment_method] VARCHAR(20) NOT NULL,
        [pickup_code] VARCHAR(20) NULL,
        [total_amount] DECIMAL(10,2) NOT NULL,
        [ordered_at] DATETIME2(0) NOT NULL,
        [paid_at] DATETIME2(0) NULL,
        [production_started_at] DATETIME2(0) NULL,
        [production_finished_at] DATETIME2(0) NULL,
        [completed_at] DATETIME2(0) NULL,
        [cancelled_at] DATETIME2(0) NULL,
        [created_at] DATETIME2(0) NOT NULL,
        [updated_at] DATETIME2(0) NOT NULL,
        CONSTRAINT PK_Baseline_SalesOrder PRIMARY KEY (batch_id, [order_id])
    );
END;
DENY SELECT, INSERT, UPDATE, DELETE ON OBJECT::dbo.Baseline_SalesOrder TO public;

IF OBJECT_ID(N'dbo.Baseline_SalesOrderItem', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.Baseline_SalesOrderItem (
        batch_id BIGINT NOT NULL,
        [order_item_id] BIGINT NOT NULL,
        [order_id] BIGINT NOT NULL,
        [product_id] BIGINT NOT NULL,
        [parent_order_item_id] BIGINT NULL,
        [item_role] VARCHAR(20) NOT NULL,
        [quantity] INT NOT NULL,
        [unit_price] DECIMAL(10,2) NOT NULL,
        [promotion_id] BIGINT NULL,
        [created_at] DATETIME2(0) NOT NULL,
        [updated_at] DATETIME2(0) NOT NULL,
        CONSTRAINT PK_Baseline_SalesOrderItem PRIMARY KEY (batch_id, [order_item_id])
    );
END;
DENY SELECT, INSERT, UPDATE, DELETE ON OBJECT::dbo.Baseline_SalesOrderItem TO public;

IF OBJECT_ID(N'dbo.Baseline_Payment', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.Baseline_Payment (
        batch_id BIGINT NOT NULL,
        [payment_id] BIGINT NOT NULL,
        [order_id] BIGINT NOT NULL,
        [payment_method] VARCHAR(20) NOT NULL,
        [paid_amount] DECIMAL(10,2) NOT NULL,
        [payment_status] VARCHAR(20) NOT NULL,
        [paid_at] DATETIME2(0) NOT NULL,
        [refunded_amount] DECIMAL(10,2) NOT NULL,
        [refunded_at] DATETIME2(0) NULL,
        [third_party_txn_no] VARCHAR(100) NULL,
        [created_at] DATETIME2(0) NOT NULL,
        [updated_at] DATETIME2(0) NOT NULL,
        CONSTRAINT PK_Baseline_Payment PRIMARY KEY (batch_id, [payment_id])
    );
END;
DENY SELECT, INSERT, UPDATE, DELETE ON OBJECT::dbo.Baseline_Payment TO public;

IF OBJECT_ID(N'dbo.Baseline_Delivery', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.Baseline_Delivery (
        batch_id BIGINT NOT NULL,
        [delivery_id] BIGINT NOT NULL,
        [order_id] BIGINT NOT NULL,
        [rider_employee_id] BIGINT NULL,
        [delivery_status] VARCHAR(20) NOT NULL,
        [picked_up_at] DATETIME2(0) NULL,
        [delivered_at] DATETIME2(0) NULL,
        [created_at] DATETIME2(0) NOT NULL,
        [updated_at] DATETIME2(0) NOT NULL,
        CONSTRAINT PK_Baseline_Delivery PRIMARY KEY (batch_id, [delivery_id])
    );
END;
DENY SELECT, INSERT, UPDATE, DELETE ON OBJECT::dbo.Baseline_Delivery TO public;

IF OBJECT_ID(N'dbo.Baseline_PointLedger', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.Baseline_PointLedger (
        batch_id BIGINT NOT NULL,
        [point_ledger_id] BIGINT NOT NULL,
        [order_id] BIGINT NOT NULL,
        [customer_id] BIGINT NOT NULL,
        [paid_amount_snapshot] DECIMAL(10,2) NOT NULL,
        [point_multiplier_snapshot] DECIMAL(5,2) NOT NULL,
        [point_delta] INT NOT NULL,
        [ledger_status] VARCHAR(20) NOT NULL,
        [created_at] DATETIME2(0) NOT NULL,
        [effective_at] DATETIME2(0) NULL,
        CONSTRAINT PK_Baseline_PointLedger PRIMARY KEY (batch_id, [point_ledger_id])
    );
END;
DENY SELECT, INSERT, UPDATE, DELETE ON OBJECT::dbo.Baseline_PointLedger TO public;

INSERT INTO dbo.Baseline_SalesOrder (batch_id, [order_id], [order_no], [customer_id], [order_status], [fulfillment_method], [pickup_code], [total_amount], [ordered_at], [paid_at], [production_started_at], [production_finished_at], [completed_at], [cancelled_at], [created_at], [updated_at])
SELECT @batch_id, [order_id], [order_no], [customer_id], [order_status], [fulfillment_method], [pickup_code], [total_amount], [ordered_at], [paid_at], [production_started_at], [production_finished_at], [completed_at], [cancelled_at], [created_at], [updated_at] FROM dbo.SalesOrder;

INSERT INTO dbo.Baseline_SalesOrderItem (batch_id, [order_item_id], [order_id], [product_id], [parent_order_item_id], [item_role], [quantity], [unit_price], [promotion_id], [created_at], [updated_at])
SELECT @batch_id, [order_item_id], [order_id], [product_id], [parent_order_item_id], [item_role], [quantity], [unit_price], [promotion_id], [created_at], [updated_at] FROM dbo.SalesOrderItem;

INSERT INTO dbo.Baseline_Payment (batch_id, [payment_id], [order_id], [payment_method], [paid_amount], [payment_status], [paid_at], [refunded_amount], [refunded_at], [third_party_txn_no], [created_at], [updated_at])
SELECT @batch_id, [payment_id], [order_id], [payment_method], [paid_amount], [payment_status], [paid_at], [refunded_amount], [refunded_at], [third_party_txn_no], [created_at], [updated_at] FROM dbo.Payment;

INSERT INTO dbo.Baseline_Delivery (batch_id, [delivery_id], [order_id], [rider_employee_id], [delivery_status], [picked_up_at], [delivered_at], [created_at], [updated_at])
SELECT @batch_id, [delivery_id], [order_id], [rider_employee_id], [delivery_status], [picked_up_at], [delivered_at], [created_at], [updated_at] FROM dbo.Delivery;

INSERT INTO dbo.Baseline_PointLedger (batch_id, [point_ledger_id], [order_id], [customer_id], [paid_amount_snapshot], [point_multiplier_snapshot], [point_delta], [ledger_status], [created_at], [effective_at])
SELECT @batch_id, [point_ledger_id], [order_id], [customer_id], [paid_amount_snapshot], [point_multiplier_snapshot], [point_delta], [ledger_status], [created_at], [effective_at] FROM dbo.PointLedger;
