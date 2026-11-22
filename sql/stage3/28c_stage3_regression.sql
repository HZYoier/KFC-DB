-- 28c — C 域回归。仓库根目录以 sqlcmd -b -C -f 65001 -d KFC_DB -i 运行。
-- 前置：真实 v1.0、20/21c/22c 及 test_store_manager/test_shift_manager 夹具。
-- 可在仅部署 C 增量时独立运行；完整 v1.1 标记由 verify_stage3 检查。
-- 结构 14 + 补货函数 10 + 库存调整 15 + 库存审计 10 + 补货回滚 14 = 63。
:on error exit
USE KFC_DB;
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

:r tests/stage3/c_programmability/run_c_programmability.sql
GO
:r tests/stage3/c_triggers/run_c_triggers.sql
GO
:setvar Mode rollback
:r sql/stage3/25c_tx_replenishment_receipt.sql
GO

-- 各子套件按实际计数检查固定分母与 fail=0，任一失败会在此之前退出。
PRINT N'RESULT: stage3-c-regression suites=5 pass=63 fail=0';
GO
