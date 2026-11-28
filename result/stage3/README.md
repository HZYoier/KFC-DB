# 第三阶段证据索引（result/stage3）

> 属主：C（总集成）。每个文件用字母前缀标属主：`a-` A、`b-` B、`c-` C。本目录只放可复跑的原始输出、说明与脚本，不放数据库口令、连接串或未脱敏日志。

## C 域证据

| 文件 | 内容 | 结果 |
| --- | --- | --- |
| [c-stage3-31-2026-11-15.txt](c-stage3-31-2026-11-15.txt) | 真实 v1.0 上增量执行 20/21c/22c；C 域 3.1 测试、库存审计触发器、10c、13a/13b-write/13c、七套应用 | C 对象测试全绿；七套 118/0；该次记录了后来关闭的 S3-03 |
| [c-transaction-2026-11-18.txt](c-transaction-2026-11-18.txt) | 25c 补货入库事务：回滚路径 14/0、提交路径 18/0、重复/无效收货拒绝 | 一次性 KFC_DB 上完成，测试后整库删除 |
| [scripts/c-programmability-demo-2026-11-15.sql](scripts/c-programmability-demo-2026-11-15.sql) | 输入/预期/实际/错误消息演示；写操作事务内回滚 | 可复跑 |
| [并发实验说明](../../docs/stage3/concurrency.md) | 26c 锁等待、超时、死锁与同序加锁复跑步骤，附 A 的隔离级别证据入口 | 26c 四模式各三轮通过 |
| [c-concurrency-2026-11-22.txt](c-concurrency-2026-11-22.txt) | 26c 等待、超时、死锁 XML、同序加锁、回滚复查；28c 固定分母验收 | 四模式各三轮；28c 63/0；一次性库已清理 |
| [c-integration-2026-11-25.txt](c-integration-2026-11-25.txt) | 正式迁移、权限、两版回归、三域验收、应用联调与清理 | 权限 64/78，回归两版各 38/0，合并 123/0，七套 118/0 |
| [c-business-concurrency-2026-11-25.txt](c-business-concurrency-2026-11-25.txt) | 真实订单和补货的等待、反向死锁、同序加锁、锁图及 B 并发复跑 | C 四模式各三轮 12/0，B 三模式各三轮 9/0 |
| [c-integration-2026-11-28.txt](c-integration-2026-11-28.txt) | 原始同日种子、正式 v1.1、一键验收、应用和 C 并发复核 | 两版各 38/0，三域 123/0，七套 118/0，C 业务并发 12/0 |
| [c-b-handoff-2026-11-28.txt](c-b-handoff-2026-11-28.txt) | 在 `33de726` 复核 B 正式入口、权限与 C 并发回执 | 两版各 38/0，B 专项 21/0、业务并发 9/0，C 死锁对照 6 轮，合并 123/0 |

## B 正式交接

B 的独立演练入口已包含正式 v1.1 迁移。B 个人报告及截图撤回，交付复跑入口、权限及原始输出见[正式收尾与权限回执](b-closeout-2026-11-28.md)。

## 正式 v1.1 复跑

1. 仓库根目录使用 `sqlcmd -S '.\SQLEXPRESS' -E -C -f 65001 -b -I`。在一次性库执行 `sql/stage1/run_all.sql`，执行 `sql/stage2/capture_baseline.sql -v SourceBaseline=C-Stage3-Disposable ConfirmAppStopped=YES`，再执行 `sql/stage2/run_migration.sql`。用 `-i` 指定各脚本。
2. 运行 `sql/stage2/regression.sql`，正式执行 `sql/stage3/run_stage3.sql`，再次运行 `sql/stage2/regression.sql`。两次均需 38/0。
3. 直接运行 [Stage 3 一键验收](../../tests/stage3/run-all.ps1) 核对三域 123/0、A App 9/0、C App 8/0，也可单独运行 `sql/stage3/verify_stage3.sql` 核对三域。参数见[测试报告](../../docs/stage3/test-report.md)。
4. 在同一一次性库以 `-v Mode=commit` 执行 25c 留下审计样例。运行 [应用联调](scripts/c-v11-app-smoke.py) 及 [C 业务并发](../../tests/stage3/c_concurrency/run_c_business_concurrency.py)。按[并发说明](../../docs/stage3/concurrency.md)取图、核对事务数并删除一次性库。

## C 域增量单测复跑前提

1. 从仓库根目录部署 v0.1：`sqlcmd -S '.\SQLEXPRESS' -E -C -f 65001 -b -i sql/stage1/run_all.sql`。
2. 采集并迁移到 v1.0：`capture_baseline.sql`（`-v SourceBaseline=... -v ConfirmAppStopped=YES`）→ `run_migration.sql`。
3. 应用 C 的增量：
   `20_schema_v1_1.sql` → `21c_inventory_programmability.sql` → `22c_inventory_triggers.sql`。
4. 按证据文件中的命令执行 `tests/stage3/c_programmability`、`tests/stage3/c_triggers`、`tests/stage3/c_app`。
5. 补货入库事务：在一次性库上跑 `-v Mode=commit`，在主库上跑 `-v Mode=rollback`；脚本要求 `-d KFC_DB` 或 `-d KFC_DB_*`，不会误连 `master`。

## SHA-256（生成时快照）

```text
db37740fb0e389775c76e507b3a87cc88a41d1058460cf3a086951f9fae0b3b8  sql/stage3/20_schema_v1_1.sql
2d59df37059f6391a04be58a9961d4304fde969ce400f19754788917423a9561  sql/stage3/21c_inventory_programmability.sql
87cbb779e89b83f2350fc338016b66f528489730b21e392d702fe99e09b4e121  sql/stage3/22c_inventory_triggers.sql
d9998ebb38df52837adca6945137a424f911b0b94eb6929642203a9beff43006  sql/stage3/25c_tx_replenishment_receipt.sql
b67c866b9ff3c6e37e9914eddf3f98afec87e722916388d874e89e64ab6c6659  sql/stage3/run_stage3.sql
06b8505e080629c834e5ce1851f3f5d7271764fb7f4ee0c5d2776ac12b81dc1e  sql/stage3/26c_lock_deadlock_experiment.sql
1fe97210936fa358a89c6d21480d1a349c297fee91f607a1531fd44320f3688a  sql/stage3/28c_stage3_regression.sql
1d29940326f2ea1b353eeb0fcc03bd16f91ea72b5f2a4c1f7681851ea68a0803  sql/stage3/verify_stage3.sql
3ef41efb4bde480eda767b917b24610dd54358de5848d0a0fe0256b5acf71246  tests/stage3/c_programmability/test_20_schema_v1_1.sql
8c87cddd1c5997495b6d70bb2cad581f65d238e7b81084e79179d3ceea72e25d  tests/stage3/c_programmability/test_21c_replenishment_qty.sql
b6e955085420767212658a1d208d096aa076c9804bfcb0c1c152afc0b539cb83  tests/stage3/c_programmability/test_21c_adjust_inventory.sql
53410c07686508c5b069aeffa797470680b307d065fdab8cf5b24d06e433e232  tests/stage3/c_programmability/run_c_programmability.sql
6e247f4b58afc850ba2cc1cc6ce66e1cf8d710c94dc1abe0c4f3c8024a2ab31c  tests/stage3/c_triggers/test_22c_inventory_audit.sql
128f922bf71425d4486ff118ea14d45dd4fe1a093416f01e496ec78201d64add  tests/stage3/c_triggers/run_c_triggers.sql
0539b58c4f76fbc6755cf63acc2ca5779e973261e36ba07e18e82de23bc47fe2  tests/stage3/c_app/test_inventory_qty.py
a27aea20a49b938d72c6b54e980f74a36abbdc35a4fb3c476b9f31de7cc5d932  tests/stage3/c_app/run_c_app_tests.py
ca361e5f6a2581e91d28a2caf2820a989469643690a5f57d299d500db8c3aa67  result/stage3/scripts/c-programmability-demo-2026-11-15.sql
c67fd2a597330e3f0e743bc627a257bc05b3e9ec15f388cc927ec7ad49865170  result/stage3/c-stage3-31-2026-11-15.txt
a092a725aa56a45b7c0316f0b548cfa795fd736959468ad3960e1326482c6774  result/stage3/c-transaction-2026-11-18.txt
3ae340066be209b9f79e61bfa31cc67c9c73019a1adf26a82b6ee4830c88d972  result/stage3/c-concurrency-2026-11-22.txt
77a55f1d9d26722749254a59e60f250c8fca5f9136805c098b3652b46c2596fa  sql/stage3/27_permissions.sql
65938de7391e70b7864920d4170f8ad3f3263aa9e8705bc8a9eb1023ef33e7b8  sql/stage2/13c_inventory_security_regression.sql
1d1e196cd20c8ba758ddc28769abbb91f9da03fc7e6dbb8cfcf16ea9fb5f119d  tests/stage3/c_app/test_inventory_audit.py
dd28b8e9b0d06a7caae2bf2b8bf70e60d493f1041715356e3d2608a15037d02c  tests/stage3/c_concurrency/run_c_business_concurrency.py
9eb0a52cf8fd169ce62cd4b11ec53d8c73010cf3e4100d17ccbfc140cba205a4  result/stage3/scripts/c-verify-sales-fixture.sql
c9336d8971abd5f4b907d4d4646f99746052be36e2f0fcc0d7a4ce23553d8e48  result/stage3/scripts/c-v11-app-smoke.py
0bf30c9e6fe4c29d9e9db75944a2dd034374908d1feb0d18c43ba5258bcf966c  result/stage3/c-integration-2026-11-25.txt
b529913eada83be3a9fbb5eb5715b96c525463618a7bbeac0cf433375e934e89  result/stage3/c-business-concurrency-2026-11-25.txt
43863d803b51fb5161130678784e1ff8dcd0bb5585f698fcb2b6ca3e0efe2149  result/stage3/c-integration-2026-11-28.txt
2a7c996541fc12175758ef5c9aeeadba68660cb07fa8aa2d701fb82ce78cd4f8  tests/stage3/run-all.ps1
99b3fa2e00bc0a05912b827c5df0bc0b1bd1f146c683d808a4f30b8dd03cb8b2  result/stage3/c-b-handoff-2026-11-28.txt
```

## 历史证据

- [跨日验收夹具](scripts/c-verify-sales-fixture.sql)用于复现 11 月 25 日的验收流程。新版 28a 已覆盖同日种子，正式流程直接使用原始种子。
- `c-stage3-31` 基于 v1.0 + C 增量。当时的 13b 兼容性问题 S3-03 已在正式 v1.1 关闭。
- 21c 的 543xx 已由 A 映射（S3-01）；22c 的 DELETE 边界见 S3-02。
