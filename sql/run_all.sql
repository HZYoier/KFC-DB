-- ============================================================================
-- run_all.sql
-- 负责人：C（库存、补货、员工权限、审计与总集成）
-- 用途：第一阶段唯一部署入口，按冻结顺序执行全部脚本
-- 用法（必须在仓库根目录执行；ODBC Driver 18 必须加 -C，且必须加 -f 65001）：
--     sqlcmd -S <实例> -E -C -f 65001 -i sql/run_all.sql
-- 注意 -f 65001 不可省略：本目录脚本是 UTF-8 无 BOM，不加时 sqlcmd 按代码页 936
--       解码，中文串字面量会吞掉收尾单引号，使该批次被当成未闭合字符串而静默作废
--       （表现为 exit=0、无任何输出、语句根本没执行），比报错更危险。
-- SSMS：打开本文件并启用 SQLCMD Mode 后执行。
-- 注意：官方 VS Code mssql 扩展不支持 SQLCMD 的 :r，不能直接执行本文件。
-- 顺序依据：docs/stage1-three-person-implementation-plan.md 第 1 节
-- 备注：若客户端按“脚本所在目录”解析 :r 相对路径而报找不到文件，
--       把下面每行路径的 sql/ 前缀去掉即可（脚本文件仍放在 sql/ 目录内）。
-- ============================================================================

:on error exit

:r sql/00_create_database.sql
:r sql/01_master_schema.sql
:r sql/02_order_schema.sql
:r sql/03_inventory_security_schema.sql
:r sql/04_master_constraints_crud.sql
:r sql/06_inventory_constraints_crud.sql
:r sql/05_order_constraints_crud.sql
:r sql/07a_master_views_queries.sql
:r sql/07b_order_views_queries.sql
:r sql/07c_inventory_views_queries.sql
:r sql/08_roles_permissions.sql
:r sql/09a_master_seed_data.sql
:r sql/09c_inventory_opening_seed_data.sql
:r sql/09b_order_seed_data.sql
:r sql/09d_inventory_replenishment_seed_data.sql
:r sql/10a_master_acceptance_tests.sql
:r sql/10b_order_acceptance_tests.sql
:r sql/10c_inventory_security_acceptance_tests.sql
