-- 一次性库验收夹具。先跑 v1.1 的第二阶段回归；完成验收后删除测试库。
-- stage1 的两笔已结算种子同日。将自提种子完成时间移至次日，
-- 为 28a 的倒置日期断言提供两个不同的边界。
SET NOCOUNT ON;
SET XACT_ABORT ON;

IF DB_NAME() <> N'KFC_DB' OR NOT EXISTS (
    SELECT 1 FROM dbo.SchemaVersion AS v
    JOIN dbo.MigrationBatch AS b ON b.batch_id = v.batch_id
    WHERE v.version_code = 'v1.1' AND b.source_baseline = 'C-Stage3-Disposable'
)
    THROW 54935, N'Fixtures require the disposable C-Stage3-Disposable v1.1 baseline.', 1;

DECLARE @first DATE, @last DATE;
SELECT @first = MIN(CONVERT(DATE, completed_at)), @last = MAX(CONVERT(DATE, completed_at))
FROM dbo.v_settled_sales_line;
IF @first IS NULL
    THROW 54935, N'No settled sales in the disposable fixture.', 1;

IF @first = @last
BEGIN
    BEGIN TRANSACTION;
    UPDATE dbo.SalesOrder
    SET completed_at = DATEADD(DAY, 1, completed_at)
    WHERE order_status = 'PICKED_UP'
      AND order_id = (SELECT MIN(l.order_id) FROM dbo.v_settled_sales_line AS l
                      JOIN dbo.SalesOrder AS o ON o.order_id = l.order_id
                      WHERE o.order_status = 'PICKED_UP');
    IF @@ROWCOUNT <> 1
        THROW 54935, N'Expected one settled pickup order for the date fixture.', 1;
    COMMIT TRANSACTION;
END;

SELECT MIN(CONVERT(DATE, completed_at)) AS first_date,
       MAX(CONVERT(DATE, completed_at)) AS last_date
FROM dbo.v_settled_sales_line;
PRINT N'RESULT: settled sales fixture ready for distinct date boundaries.';
