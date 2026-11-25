-- B order-side steps. The Python lab supplies IDs from its disposable fixture.
-- Mode=finish runs inside the caller's explicit transaction and leaves it open.
-- Mode=buy creates, pays and finishes one P x 6 order atomically, then commits.
-- Mode=lock locks IngredientP first. C can lock Q before B's finish step.
-- The runner, not a WAITFOR guess, observes blocking before releasing a session.
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
IF LEFT(DB_NAME(), 13) <> 'KFC_B_STAGE3_'
    THROW 54240, '26b requires the disposable B lab database.', 1;
DECLARE @mode VARCHAR(10) = '$(Mode)';
IF @mode NOT IN ('finish', 'buy', 'lock') THROW 54240, '26b invalid mode.', 1;
IF @mode IN ('finish', 'lock') AND @@TRANCOUNT <> 1
    THROW 54240, '26b step requires one caller transaction.', 1;
IF @mode = 'lock'
BEGIN
    SELECT ingredient_id, on_hand_qty FROM dbo.Inventory WITH (UPDLOCK, ROWLOCK)
    WHERE ingredient_id = $(IngredientP);
    RETURN;
END;
DECLARE @as_user BIT = 0;
BEGIN TRY
    IF @mode = 'buy'
    BEGIN
        IF @@TRANCOUNT <> 0 THROW 54240, '26b buy requires a fresh transaction.', 1;
        BEGIN TRANSACTION;
        DECLARE @number VARCHAR(50) = '$(OrderNo)', @payload NVARCHAR(MAX) =
            CONCAT(N'[{"product_id":', $(ProductId), N',"quantity":6}]');
        EXECUTE AS USER = 'test_cashier'; SET @as_user = 1;
        EXEC dbo.sp_create_order $(CustomerId), 'PICKUP', @number, @payload;
        REVERT; SET @as_user = 0;
        DECLARE @id BIGINT, @amount DECIMAL(10,2);
        SELECT @id = order_id, @amount = total_amount FROM dbo.SalesOrder WHERE order_no = @number;
        EXECUTE AS USER = 'test_cashier'; SET @as_user = 1;
        EXEC dbo.sp_pay_order @id, 'CASH', @amount, NULL;
        REVERT; SET @as_user = 0;
        EXECUTE AS USER = 'test_chef'; SET @as_user = 1;
        EXEC dbo.sp_start_production @id;
        REVERT; SET @as_user = 0;
    END
    ELSE SET @id = $(OrderId);
    EXECUTE AS USER = 'test_packer'; SET @as_user = 1;
    EXEC dbo.sp_finish_production @id;
    REVERT; SET @as_user = 0;
    IF @mode = 'buy' COMMIT TRANSACTION;
    SELECT @id AS order_id, order_status, @@TRANCOUNT AS transaction_count
    FROM dbo.SalesOrder WHERE order_id = @id;
END TRY
BEGIN CATCH
    IF @mode = 'buy' AND XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    IF @as_user = 1 REVERT;
    THROW;
END CATCH;
