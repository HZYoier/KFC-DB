-- Temporary stubs for testing 12_permissions mechanics only (not B's 11b).
USE KFC_DB;
SET NOCOUNT ON;
GO
CREATE PROCEDURE dbo.sp_list_orders_for_payment @take INT = 100 AS SELECT @take AS take_value;
GO
CREATE PROCEDURE dbo.sp_get_order_for_payment @order_id BIGINT AS SELECT @order_id AS order_id;
GO
CREATE PROCEDURE dbo.sp_get_order_operation_status @order_id BIGINT = NULL, @order_no VARCHAR(50) = NULL AS SELECT @order_id AS order_id;
GO
CREATE PROCEDURE dbo.sp_list_orders_for_packing @take INT = 100 AS SELECT @take AS take_value;
GO
CREATE PROCEDURE dbo.sp_list_my_deliveries @take INT = 100 AS SELECT @take AS take_value;
GO
CREATE PROCEDURE dbo.sp_list_deliveries_available_for_pickup @take INT = 100 AS SELECT @take AS take_value;
GO
CREATE PROCEDURE dbo.sp_customer_register @mobile VARCHAR(20) AS SELECT @mobile AS mobile;
GO
CREATE PROCEDURE dbo.sp_customer_place_order @mobile VARCHAR(20), @items_json NVARCHAR(MAX), @pickup_code VARCHAR(20) AS SELECT @mobile AS mobile;
GO
CREATE PROCEDURE dbo.sp_customer_list_orders @mobile VARCHAR(20), @pickup_code VARCHAR(20) AS SELECT @mobile AS mobile;
GO
PRINT 'stubs created';
