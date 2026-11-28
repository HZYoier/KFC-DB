# 第三阶段测试汇总

最新复核于 2026-11-28 基于 `4d3ecb1` 在本机 SQL Server 2025 Express 17.0.1000.7 一次性库验收。依次运行第一阶段部署、v1.0 基线与迁移、正式 `run_stage3.sql`。基线标识为 `C-Stage3-Disposable`。原始输出与复跑顺序见[证据索引](../../result/stage3/README.md)。

| 检查 | 实测结果 |
| --- | --- |
| `regression.sql` | v1.0 与 v1.1 各 38/0，13c 各 15/0 |
| v1.1 权限 | 新增 6 码、7 行。最终 64 码、78 行，实际对象授权逐对一致 |
| 迁移回滚和重入（11 月 25 日） | 缺 27、事务末批语法失败分别回滚至 58/71；已提交 v1.1 上再次执行返回 54401 |
| `verify_stage3.sql` | A 52/0、B 8/0、C 63/0，共 123/0 |
| 25c | 回滚 14/0，提交 18/0 |
| 应用 | 第二阶段七套 118/0，A 报表测试 9/0，C 应用测试 8/0。Stage 3 一键入口三套通过 |
| 正式 v1.1 应用联调 | 店长菜单、销售报表与 SQL 汇总一致、空区间、审计筛选和拒绝、值班经理补货量通过 |
| 第十三周业务并发 | C 四种订单/收货场景各三轮，12/0。B 于 11 月 25 日在正式 v1.1 独立库复跑 9/0。A 的隔离级别采用其已归档的对照。见[并发记录](concurrency.md) |

11 月 25 日的验收曾使用跨日夹具。A 已修复同日种子的倒置日期断言，11 月 28 日以原始种子直接通过三域验收。A 另有主库迁移与合并回归输出。[C 的原始种子复核](../../result/stage3/c-integration-2026-11-28.txt) · [A 的主库验收](../../result/stage3/a-verify-stage3-2026-11-28.txt)

Flask 联调用测试客户端和 Windows 集成连接，在数据库执行 `EXECUTE AS USER` 以分别落到真实数据库角色。

## 一键验收

准备一次性 v1.1 库后，在仓库根目录运行以下命令。入口检查三域 SQL（123/0）、A 报表应用（9/0）和 C 库存应用（8/0）的退出码及固定结果行。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests/stage3/run-all.ps1 -Sqlcmd 'C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\180\Tools\Binn\sqlcmd.exe' -Python 'D:\Miniconda\envs\py_env3.11\python.exe'
```

可用 `-SqlServer` 指定实例，或省略 `-Python` 使用 `-CondaEnv`（默认 `py_env3.11`）。两版 SQL 回归与七套应用仍走原 Stage 2 入口。

## 教学交付名

| 教学交付 | 本仓入口 |
| --- | --- |
| `procedure.sql`、`function.sql` | `sql/stage3/21a_master_programmability.sql`、`21b_order_programmability.sql`、`21c_inventory_programmability.sql` |
| `trigger.sql` | `sql/stage3/22b_order_triggers.sql`、`22c_inventory_triggers.sql` |
| `window_query.sql` | `sql/stage3/23a_window_queries.sql`、`23b_window_queries.sql` |
| `recursive_query.sql` | `sql/stage3/24b_recursive_query.sql` |
| `transaction.sql` | `sql/stage3/25b_tx_order_completion.sql`、`25c_tx_replenishment_receipt.sql` |
| `concurrency.sql` | `sql/stage3/26a_isolation_experiment.sql`、`26b_order_concurrency.sql`、`26c_lock_deadlock_experiment.sql`，以及 `tests/stage3/c_concurrency/run_c_business_concurrency.py` |
| 结构与权限、验收 | `sql/stage3/20_schema_v1_1.sql`、`27_permissions.sql`、`run_stage3.sql`、`verify_stage3.sql` |
