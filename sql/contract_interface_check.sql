/*
  Cross-domain interface contract check.
  This script is read-only: it does not create stubs or alter any object.
  Run after A/C implementations are installed and before running B acceptance.
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
SET NOCOUNT ON;
GO

DECLARE @objects TABLE
(
    object_name SYSNAME NOT NULL,
    object_type CHAR(2) NOT NULL
);
INSERT @objects (object_name, object_type)
VALUES
    (N'dbo.fn_get_effective_product_price', 'IF'),
    (N'dbo.sp_apply_customer_points', 'P'),
    (N'dbo.sp_lock_order_inventory', 'P'),
    (N'dbo.sp_release_order_inventory', 'P'),
    (N'dbo.sp_consume_order_inventory', 'P'),
    (N'dbo.sp_receive_inventory', 'P'),
    (N'dbo.sp_write_audit_log', 'P');

IF EXISTS
(
    SELECT 1
    FROM @objects AS required_object
    WHERE OBJECT_ID(required_object.object_name, required_object.object_type) IS NULL
)
    THROW 52900, 'One or more cross-domain interface objects are missing.', 1;

DECLARE @parameters TABLE
(
    object_name SYSNAME NOT NULL,
    parameter_name SYSNAME NOT NULL,
    parameter_id INT NOT NULL,
    expected_type SYSNAME NOT NULL,
    expected_max_length SMALLINT NOT NULL
);
INSERT @parameters (object_name, parameter_name, parameter_id, expected_type, expected_max_length)
VALUES
    (N'dbo.fn_get_effective_product_price', N'@product_id', 1, N'bigint', 8),
    (N'dbo.fn_get_effective_product_price', N'@at', 2, N'datetime2', 8),
    (N'dbo.sp_apply_customer_points', N'@customer_id', 1, N'bigint', 8),
    (N'dbo.sp_apply_customer_points', N'@delta', 2, N'int', 4),
    (N'dbo.sp_lock_order_inventory', N'@order_id', 1, N'bigint', 8),
    (N'dbo.sp_release_order_inventory', N'@order_id', 1, N'bigint', 8),
    (N'dbo.sp_release_order_inventory', N'@reason', 2, N'varchar', 20),
    (N'dbo.sp_consume_order_inventory', N'@order_id', 1, N'bigint', 8),
    (N'dbo.sp_receive_inventory', N'@purchase_order_id', 1, N'bigint', 8),
    (N'dbo.sp_receive_inventory', N'@employee_id', 2, N'bigint', 8),
    (N'dbo.sp_write_audit_log', N'@employee_id', 1, N'bigint', 8),
    (N'dbo.sp_write_audit_log', N'@action_name', 2, N'varchar', 50),
    (N'dbo.sp_write_audit_log', N'@entity_name', 3, N'varchar', 50),
    (N'dbo.sp_write_audit_log', N'@entity_id', 4, N'bigint', 8),
    (N'dbo.sp_write_audit_log', N'@detail_json', 5, N'nvarchar', -1);

IF EXISTS
(
    SELECT 1
    FROM @parameters AS expected_parameter
    LEFT JOIN sys.parameters AS actual_parameter
      ON actual_parameter.object_id = OBJECT_ID(expected_parameter.object_name)
     AND actual_parameter.parameter_id = expected_parameter.parameter_id
    LEFT JOIN sys.types AS actual_type
      ON actual_type.user_type_id = actual_parameter.user_type_id
    WHERE actual_parameter.name <> expected_parameter.parameter_name
       OR actual_parameter.name IS NULL
       OR actual_type.name <> expected_parameter.expected_type
       OR actual_parameter.max_length <> expected_parameter.expected_max_length
)
    THROW 52901, 'A cross-domain interface has an unexpected parameter name or type.', 1;

IF EXISTS
(
    SELECT expected_parameter.object_name
    FROM @parameters AS expected_parameter
    GROUP BY expected_parameter.object_name
    HAVING COUNT(*) <>
    (
        SELECT COUNT(*)
        FROM sys.parameters AS actual_parameter
        WHERE actual_parameter.object_id = OBJECT_ID(expected_parameter.object_name)
    )
)
    THROW 52902, 'A cross-domain interface has an unexpected parameter count.', 1;

DECLARE @price_function_id INT = OBJECT_ID(N'dbo.fn_get_effective_product_price', N'IF');
IF EXISTS
(
    SELECT expected_column.column_name
    FROM (VALUES
        (N'product_id', N'bigint'),
        (N'effective_price', N'decimal'),
        (N'promotion_id', N'bigint')
    ) AS expected_column(column_name, expected_type)
    LEFT JOIN sys.columns AS actual_column
      ON actual_column.object_id = @price_function_id
     AND actual_column.name = expected_column.column_name
    LEFT JOIN sys.types AS actual_type
      ON actual_type.user_type_id = actual_column.user_type_id
    WHERE actual_column.name IS NULL OR actual_type.name <> expected_column.expected_type
)
    THROW 52903, 'The pricing function must return product_id, effective_price, and promotion_id.', 1;

SELECT N'PASS: cross-domain interface objects and signatures match the frozen contract.' AS result;
