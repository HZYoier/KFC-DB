# C 域权限/库存安全测试入口

本目录对应计划 §7.1 的 `tests/stage2/inventory-security/`。C 的权限与越权断言分两层：

- `sql/stage2/13c_inventory_security_regression.sql`：真实 v1.0 数据库上的 15 条 SQL 断言，覆盖 `Permission`/`RolePermission`/实际 GRANT、`cust_app`、身份上下文、UQ、账本、补货/采购、签名、视图和员工角色正反例。
- `run_inventory_security_tests.py`：调用上面的 SQL 文件并校验 `RESULT: pass=15 fail=0`；需要已迁移到 v1.0 的 `KFC_DB` 和 Windows 身份下的 `sqlcmd`。

`tests/stage2/run-all.ps1` 的六套是不连库的应用测试；本目录的 SQL 安全回归依赖真实数据库，因此单独执行，不并入 `run-all`。

```powershell
py -3 tests/stage2/inventory-security/run_inventory_security_tests.py `
  --server '.\SQLEXPRESS' --database KFC_DB
```

`run_migration.sql` 提交 v1.0 后再运行；未迁移的库会按 13c 自己的前置断言失败，不会被当作通过。
