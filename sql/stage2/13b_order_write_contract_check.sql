-- Read-only post-migration check. Run in the target database.
SET NOCOUNT ON;
DECLARE @expected TABLE (proc_name SYSNAME, ordinal INT, param SYSNAME,
    type_name SYSNAME, byte_length SMALLINT, precision_value TINYINT, scale_value TINYINT);
INSERT @expected VALUES
 ('sp_create_order',1,'@customer_id','bigint',8,19,0),
 ('sp_create_order',2,'@fulfillment_method','varchar',20,0,0),
 ('sp_create_order',3,'@order_no','varchar',50,0,0),
 ('sp_create_order',4,'@items_json','nvarchar',-1,0,0),
 ('sp_create_order',5,'@ordered_at','datetime2',6,19,0),
 ('sp_pay_order',1,'@order_id','bigint',8,19,0),
 ('sp_pay_order',2,'@payment_method','varchar',20,0,0),
 ('sp_pay_order',3,'@paid_amount','decimal',9,10,2),
 ('sp_pay_order',4,'@third_party_txn_no','varchar',100,0,0),
 ('sp_start_production',1,'@order_id','bigint',8,19,0),
 ('sp_finish_production',1,'@order_id','bigint',8,19,0),
 ('sp_pick_up_order',1,'@order_id','bigint',8,19,0),
 ('sp_pick_up_delivery',1,'@order_id','bigint',8,19,0),
 ('sp_pick_up_delivery',2,'@rider_employee_id','bigint',8,19,0),
 ('sp_confirm_delivery',1,'@order_id','bigint',8,19,0),
 ('sp_cancel_or_refund_order',1,'@order_id','bigint',8,19,0),
 ('sp_cancel_or_refund_order',2,'@reason','varchar',20,0,0),
 ('sp_cancel_or_refund_order',3,'@operator_employee_id','bigint',8,19,0);

IF EXISTS (
 SELECT * FROM @expected
 EXCEPT
 SELECT o.name, p.parameter_id,p.name,TYPE_NAME(p.user_type_id),p.max_length,p.precision,p.scale
 FROM sys.procedures o JOIN sys.parameters p ON p.object_id=o.object_id
 WHERE o.schema_id=SCHEMA_ID(N'dbo') AND p.is_output=0
)
OR EXISTS (
 SELECT o.name
 FROM sys.procedures o JOIN sys.parameters p ON p.object_id=o.object_id
 WHERE o.schema_id=SCHEMA_ID(N'dbo') AND o.name IN (SELECT proc_name FROM @expected)
 GROUP BY o.name
 HAVING COUNT(*) <> (SELECT COUNT(*) FROM @expected e WHERE e.proc_name=o.name)
)
    THROW 51963, N'13b: existing order write parameter contract changed.', 1;
PRINT N'RESULT 13b write signatures: pass=8 fail=0 total=8';
