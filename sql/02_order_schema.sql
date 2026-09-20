/*
 B-owned schema. Execute with sqlcmd -b (or another stop-on-error runner).
 Requires A's Customer, Product and Promotion; C later adds the rider FK.
 This is a create-once deployment: never drop or silently reuse existing objects.
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
IF OBJECT_ID(N'dbo.Customer', N'U') IS NULL
 OR OBJECT_ID(N'dbo.Product', N'U') IS NULL
 OR OBJECT_ID(N'dbo.Promotion', N'U') IS NULL
    THROW 52000, 'Install A master tables before B order schema.', 1;
IF OBJECT_ID(N'dbo.SalesOrder') IS NOT NULL
 OR OBJECT_ID(N'dbo.SalesOrderItem') IS NOT NULL
 OR OBJECT_ID(N'dbo.Payment') IS NOT NULL
 OR OBJECT_ID(N'dbo.Delivery') IS NOT NULL
 OR OBJECT_ID(N'dbo.PointLedger') IS NOT NULL
    THROW 52001, 'B schema already exists; use a reviewed migration.', 1;

BEGIN TRY
    BEGIN TRANSACTION;
    CREATE TABLE dbo.SalesOrder (
        order_id BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_SalesOrder PRIMARY KEY,
        order_no VARCHAR(50) NOT NULL,
        customer_id BIGINT NOT NULL,
        order_status VARCHAR(20) NOT NULL CONSTRAINT DF_SalesOrder_order_status DEFAULT ('PENDING_PAYMENT'),
        fulfillment_method VARCHAR(20) NOT NULL,
        pickup_code VARCHAR(20) NULL,
        total_amount DECIMAL(10,2) NOT NULL CONSTRAINT DF_SalesOrder_total_amount DEFAULT (0.00),
        ordered_at DATETIME2(0) NOT NULL CONSTRAINT DF_SalesOrder_ordered_at DEFAULT (SYSDATETIME()),
        paid_at DATETIME2(0) NULL,
        production_started_at DATETIME2(0) NULL,
        production_finished_at DATETIME2(0) NULL,
        completed_at DATETIME2(0) NULL,
        cancelled_at DATETIME2(0) NULL,
        created_at DATETIME2(0) NOT NULL CONSTRAINT DF_SalesOrder_created_at DEFAULT (SYSDATETIME()),
        updated_at DATETIME2(0) NOT NULL CONSTRAINT DF_SalesOrder_updated_at DEFAULT (SYSDATETIME()),
        CONSTRAINT FK_SalesOrder_Customer FOREIGN KEY (customer_id) REFERENCES dbo.Customer(customer_id)
    );
    CREATE TABLE dbo.SalesOrderItem (
        order_item_id BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_SalesOrderItem PRIMARY KEY,
        order_id BIGINT NOT NULL,
        product_id BIGINT NOT NULL,
        parent_order_item_id BIGINT NULL,
        item_role VARCHAR(20) NOT NULL,
        quantity INT NOT NULL,
        unit_price DECIMAL(10,2) NOT NULL,
        promotion_id BIGINT NULL,
        created_at DATETIME2(0) NOT NULL CONSTRAINT DF_SalesOrderItem_created_at DEFAULT (SYSDATETIME()),
        updated_at DATETIME2(0) NOT NULL CONSTRAINT DF_SalesOrderItem_updated_at DEFAULT (SYSDATETIME()),
        CONSTRAINT FK_SalesOrderItem_SalesOrder FOREIGN KEY (order_id) REFERENCES dbo.SalesOrder(order_id),
        CONSTRAINT FK_SalesOrderItem_Product FOREIGN KEY (product_id) REFERENCES dbo.Product(product_id),
        CONSTRAINT FK_SalesOrderItem_Parent FOREIGN KEY (parent_order_item_id) REFERENCES dbo.SalesOrderItem(order_item_id),
        CONSTRAINT FK_SalesOrderItem_Promotion FOREIGN KEY (promotion_id) REFERENCES dbo.Promotion(promotion_id)
    );
    CREATE TABLE dbo.Payment (
        payment_id BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Payment PRIMARY KEY,
        order_id BIGINT NOT NULL,
        payment_method VARCHAR(20) NOT NULL,
        paid_amount DECIMAL(10,2) NOT NULL,
        payment_status VARCHAR(20) NOT NULL CONSTRAINT DF_Payment_payment_status DEFAULT ('SUCCESS'),
        paid_at DATETIME2(0) NOT NULL CONSTRAINT DF_Payment_paid_at DEFAULT (SYSDATETIME()),
        refunded_amount DECIMAL(10,2) NOT NULL CONSTRAINT DF_Payment_refunded_amount DEFAULT (0.00),
        refunded_at DATETIME2(0) NULL,
        third_party_txn_no VARCHAR(100) NULL,
        created_at DATETIME2(0) NOT NULL CONSTRAINT DF_Payment_created_at DEFAULT (SYSDATETIME()),
        updated_at DATETIME2(0) NOT NULL CONSTRAINT DF_Payment_updated_at DEFAULT (SYSDATETIME()),
        CONSTRAINT FK_Payment_SalesOrder FOREIGN KEY (order_id) REFERENCES dbo.SalesOrder(order_id)
    );
    CREATE TABLE dbo.Delivery (
        delivery_id BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Delivery PRIMARY KEY,
        order_id BIGINT NOT NULL,
        rider_employee_id BIGINT NULL,
        delivery_status VARCHAR(20) NOT NULL CONSTRAINT DF_Delivery_delivery_status DEFAULT ('WAITING_PICKUP'),
        picked_up_at DATETIME2(0) NULL,
        delivered_at DATETIME2(0) NULL,
        created_at DATETIME2(0) NOT NULL CONSTRAINT DF_Delivery_created_at DEFAULT (SYSDATETIME()),
        updated_at DATETIME2(0) NOT NULL CONSTRAINT DF_Delivery_updated_at DEFAULT (SYSDATETIME()),
        CONSTRAINT FK_Delivery_SalesOrder FOREIGN KEY (order_id) REFERENCES dbo.SalesOrder(order_id)
    );
    CREATE TABLE dbo.PointLedger (
        point_ledger_id BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_PointLedger PRIMARY KEY,
        order_id BIGINT NOT NULL,
        customer_id BIGINT NOT NULL,
        paid_amount_snapshot DECIMAL(10,2) NOT NULL,
        point_multiplier_snapshot DECIMAL(5,2) NOT NULL,
        point_delta INT NOT NULL,
        ledger_status VARCHAR(20) NOT NULL CONSTRAINT DF_PointLedger_ledger_status DEFAULT ('PENDING'),
        created_at DATETIME2(0) NOT NULL CONSTRAINT DF_PointLedger_created_at DEFAULT (SYSDATETIME()),
        effective_at DATETIME2(0) NULL,
        CONSTRAINT FK_PointLedger_SalesOrder FOREIGN KEY (order_id) REFERENCES dbo.SalesOrder(order_id),
        CONSTRAINT FK_PointLedger_Customer FOREIGN KEY (customer_id) REFERENCES dbo.Customer(customer_id)
    );
    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
GO
