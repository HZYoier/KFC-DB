# 第三阶段证据索引（result/stage3）

> 属主：C（总集成）。每个文件用字母前缀标属主：`a-` A、`b-` B、`c-` C。本目录只放可复跑的原始输出、说明与脚本，不放数据库口令、连接串或未脱敏日志。

## C 域本轮证据（2026-11-15）

| 文件 | 内容 | 结果 |
| --- | --- | --- |
| [c-stage3-31-2026-11-15.txt](c-stage3-31-2026-11-15.txt) | 真实 v1.0 上增量执行 20/21c/22c；C 域 3.1 测试、库存审计触发器、10c、13a/13b-write/13c、七套应用 | C 对象测试全绿；七套 118/0；13b baseline 形状待 B 按 S3-03 更新 |
| [scripts/c-programmability-demo-2026-11-15.sql](scripts/c-programmability-demo-2026-11-15.sql) | 输入/预期/实际/错误消息演示；写操作事务内回滚 | 可复跑 |

## 复跑前提

1. 从仓库根目录部署 v0.1：`sqlcmd -S '.\SQLEXPRESS' -E -C -f 65001 -b -i sql/stage1/run_all.sql`。
2. 采集并迁移到 v1.0：`capture_baseline.sql`（`-v SourceBaseline=... -v ConfirmAppStopped=YES`）→ `run_migration.sql`。
3. 应用 C 的增量：
   `20_schema_v1_1.sql` → `21c_inventory_programmability.sql` → `22c_inventory_triggers.sql`。
4. 按证据文件中的命令执行 `tests/stage3/c_programmability`、`tests/stage3/c_triggers`、`tests/stage3/c_app`。

## SHA-256（生成时快照）

```text
db37740fb0e389775c76e507b3a87cc88a41d1058460cf3a086951f9fae0b3b8  sql/stage3/20_schema_v1_1.sql
2d59df37059f6391a04be58a9961d4304fde969ce400f19754788917423a9561  sql/stage3/21c_inventory_programmability.sql
87cbb779e89b83f2350fc338016b66f528489730b21e392d702fe99e09b4e121  sql/stage3/22c_inventory_triggers.sql
63d0d33edcdedffa69ae1d2eecffd57d6a6901cb58b5ac1a0e648b1cfc97cefe  sql/stage3/run_stage3.sql
3ef41efb4bde480eda767b917b24610dd54358de5848d0a0fe0256b5acf71246  tests/stage3/c_programmability/test_20_schema_v1_1.sql
8c87cddd1c5997495b6d70bb2cad581f65d238e7b81084e79179d3ceea72e25d  tests/stage3/c_programmability/test_21c_replenishment_qty.sql
b6e955085420767212658a1d208d096aa076c9804bfcb0c1c152afc0b539cb83  tests/stage3/c_programmability/test_21c_adjust_inventory.sql
53410c07686508c5b069aeffa797470680b307d065fdab8cf5b24d06e433e232  tests/stage3/c_programmability/run_c_programmability.sql
6e247f4b58afc850ba2cc1cc6ce66e1cf8d710c94dc1abe0c4f3c8024a2ab31c  tests/stage3/c_triggers/test_22c_inventory_audit.sql
128f922bf71425d4486ff118ea14d45dd4fe1a093416f01e496ec78201d64add  tests/stage3/c_triggers/run_c_triggers.sql
0539b58c4f76fbc6755cf63acc2ca5779e973261e36ba07e18e82de23bc47fe2  tests/stage3/c_app/test_inventory_qty.py
861c7b16cf65895b324c6efabb3c48ac10d4542f7fbfe78b1f302a5f3d3f5ac7  tests/stage3/c_app/run_c_app_tests.py
ca361e5f6a2581e91d28a2caf2820a989469643690a5f57d299d500db8c3aa67  result/stage3/scripts/c-programmability-demo-2026-11-15.sql
c67fd2a597330e3f0e743bc627a257bc05b3e9ec15f388cc927ec7ad49865170  result/stage3/c-stage3-31-2026-11-15.txt
```

## 边界

- `c-stage3-31` 的证据是 **v1.0 + C 增量**，不是 v1.1 已提交；B 的 21b/22b/27 到齐前 `run_stage3.sql` 只作骨架。
- 13b baseline 因 `SalesOrderItem` 新增两列而失败（S3-03）；C 不代改 B 的文件，完整 `regression` 38/0 仍未达成。
- 21c 的 543xx 尚未被 A 的 `app/common/errors.py` 映射（S3-01）；22c 的 DELETE 边界见 S3-02。
